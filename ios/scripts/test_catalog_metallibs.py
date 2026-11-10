#!/usr/bin/env python3
"""Structural catalog tests; tiny payloads do not claim valid AIR semantics."""
import hashlib
import struct
import tempfile
from pathlib import Path
import unittest

from catalog_metallibs import catalog, inspect_metallib


def tag(name, value):
    return name + struct.pack("<H", len(value)) + value


def fixture(types=(0, 1), shared=False, extra=b""):
    modules = [struct.pack("<5I", 0x0B17C0DE, 0, 20, 4, 0xFFFFFFFF) + b"BC\xc0\xde"]
    if not shared:
        modules *= len(types)
    functions = []
    for index, kind in enumerate(types):
        module = modules[0]
        fields = tag(b"NAME", f"function_{index}".encode() + b"\0")
        if kind is not None:
            fields += tag(b"TYPE", bytes([kind]))
        fields += tag(b"HASH", hashlib.sha256(module).digest())
        fields += tag(b"OFFT", struct.pack("<3Q", 0, 0, 0 if shared else index * len(module)))
        fields += tag(b"MDSZ", struct.pack("<Q", len(module)))
        fields += tag(b"VERS", struct.pack("<4H", 2, 6, 2, 3)) + b"ENDT"
        functions.append(struct.pack("<I", len(fields) + 4) + fields)
    function_list = struct.pack("<I", len(functions)) + b"".join(functions)
    public_offset = 88 + len(function_list)
    private_offset = public_offset + 8
    bitcode_offset = private_offset + 8
    payload = b"".join(modules) + extra
    header = b"MTLB" + struct.pack("<HHHBBHH", 0x8001, 2, 7, 0, 0x81, 14, 6)
    header += struct.pack("<9Q", bitcode_offset + len(payload), 88, len(function_list) - 4,
                          public_offset, 8, private_offset, 8, bitcode_offset, len(payload))
    return header + function_list + (struct.pack("<I", 8) + b"ENDT") * 2 + payload


class CatalogTests(unittest.TestCase):
    def test_multiple_modules_are_distinct(self):
        result = inspect_metallib(fixture())
        self.assertEqual(result["malformed_records"], [])
        self.assertEqual(result["air_region_count"], 2)
        self.assertFalse(result["single_payload_extraction_valid"])
        self.assertEqual([f["shader_stage"] for f in result["functions"]], ["vertex", "fragment"])

    def test_shared_module_is_not_duplicated(self):
        result = inspect_metallib(fixture(shared=True))
        self.assertEqual(result["air_region_count"], 1)
        self.assertEqual(result["air_regions"][0]["function_indices"], [0, 1])
        self.assertTrue(result["single_payload_extraction_valid"])

    def test_uncovered_payload_is_not_single_module(self):
        result = inspect_metallib(fixture((2,), extra=b"unparsed"))
        self.assertTrue(result["uncovered_bitcode_ranges"])
        self.assertFalse(result["single_payload_extraction_valid"])

    def test_stage_unknown_when_missing_or_unrecognized(self):
        for kind in (None, 255):
            result = inspect_metallib(fixture((kind,)))
            self.assertIsNone(result["functions"][0]["shader_stage"])
            self.assertIsNone(result["functions"][0]["stage_evidence"])

    def test_truncation_and_section_bounds(self):
        data = bytearray(fixture())
        struct.pack_into("<Q", data, 72, len(data) + 1)
        for sample in (b"MTLB", fixture()[:-1], data):
            result = inspect_metallib(sample)
            self.assertEqual(result["status"], "malformed")
            self.assertFalse(result["single_payload_extraction_valid"])

    def test_unknown_format_is_unsupported_not_corrupt(self):
        for sample in (b"", b"another container"):
            result = inspect_metallib(sample)
            self.assertEqual(result["status"], "unsupported")
            self.assertEqual(result["malformed_records"], [])

    def test_fat_container_retains_opaque_slice_and_absolute_offsets(self):
        library = fixture((0,))
        offset = 48
        other = b"\xcf\xfa\xed\xfe" + bytes(28)
        second_offset = (offset + len(library) + 15) & ~15
        header = b"\xca\xfe\xba\xbe" + struct.pack(">I", 2)
        header += struct.pack(">5I", 0x1000017, 10, offset, len(library), 4)
        header += struct.pack(">5I", 0x1000013, 0x113, second_offset, len(other), 4)
        data = header + library + bytes(second_offset - offset - len(library)) + other
        result = inspect_metallib(data)
        self.assertEqual(result["format"], "fat_container")
        self.assertEqual(result["malformed_records"], [])
        self.assertEqual(len(result["slices"]), 2)
        self.assertEqual(result["slices"][1]["format"], "mach_o_64")
        self.assertEqual(result["air_regions"][0]["offset"], inspect_metallib(library)["air_regions"][0]["offset"] + offset)
        self.assertEqual(result["functions"][0]["shader_stage"], "vertex")
        self.assertFalse(result["single_payload_extraction_valid"])
        corrupted = bytearray(data)
        struct.pack_into(">I", corrupted, 36, 16)  # Second slice offset overlaps the header.
        self.assertEqual(inspect_metallib(corrupted)["status"], "malformed")

    def test_runtime_symbols_are_not_assumed_to_be_functions(self):
        module = struct.pack("<5I", 0x0B17C0DE, 0, 20, 4, 0xFFFFFFFF) + b"BC\xc0\xde"
        names = [b"global_table\0", b"fragment_named_but_unknown\0"]
        offset = 4 + sum(len(name) + 4 for name in names)
        table = struct.pack("<I", 2)
        for name in names:
            table += name + struct.pack("<I", offset)
            offset += 4 + len(module)
        data = table + (struct.pack("<I", len(module)) + module) * 2
        result = inspect_metallib(data)
        self.assertEqual(result["format"], "agx_runtime_symbol_table")
        self.assertEqual(result["air_region_count"], 2)
        self.assertEqual(result["functions"], [])
        self.assertTrue(all(s["shader_stage"] is None for s in result["symbols"]))
        self.assertFalse(result["single_payload_extraction_valid"])
        self.assertEqual(inspect_metallib(data[:-1])["status"], "unsupported")

    def test_bad_tag_size_is_structural_failure(self):
        data = bytearray(fixture())
        struct.pack_into("<H", data, data.index(b"NAME") + 4, 0xFFFF)
        self.assertEqual(inspect_metallib(data)["status"], "malformed")

    def test_hash_mismatch_retains_all_subsequent_records(self):
        data = bytearray(fixture((0, 1, 2)))
        hash_offset = data.index(b"HASH") + 6
        data[hash_offset] ^= 1
        result = inspect_metallib(data)
        self.assertEqual(result["status"], "parsed_with_integrity_mismatches")
        self.assertEqual(result["malformed_records"], [])
        self.assertEqual(len(result["functions"]), 3)
        self.assertEqual(result["air_region_count"], 3)
        self.assertEqual([f["air_hash_matches"] for f in result["functions"]], [False, True, True])
        self.assertEqual(len(result["integrity_mismatches"]), 1)
        mismatch = result["integrity_mismatches"][0]
        self.assertEqual(mismatch["function_index"], 0)
        self.assertEqual(mismatch["declared_sha256"], data[hash_offset:hash_offset + 32].hex())
        self.assertEqual(mismatch["actual_sha256"], result["air_regions"][0]["sha256"])
        self.assertEqual(mismatch["offset"], result["air_regions"][0]["offset"])

    def test_single_payload_flag_does_not_imply_integrity(self):
        data = bytearray(fixture((5,)))
        data[data.index(b"HASH") + 6] ^= 1
        result = inspect_metallib(data)
        self.assertTrue(result["single_payload_extraction_valid"])
        self.assertEqual(result["status"], "parsed_with_integrity_mismatches")
        self.assertFalse(result["functions"][0]["air_hash_matches"])

    def test_second_wrapper_inside_one_declared_region_is_not_single(self):
        data = bytearray(fixture((2,)))
        offset, size = struct.unpack_from("<QQ", data, 72)
        data.extend(data[offset:offset + size])
        struct.pack_into("<Q", data, 16, len(data))
        struct.pack_into("<Q", data, 80, size * 2)
        struct.pack_into("<Q", data, data.index(b"MDSZ") + 6, size * 2)
        hash_offset = data.index(b"HASH") + 6
        data[hash_offset:hash_offset + 32] = hashlib.sha256(data[offset:]).digest()
        result = inspect_metallib(data)
        self.assertEqual(result["malformed_records"], [])
        self.assertFalse(result["single_payload_extraction_valid"])
        self.assertTrue(result["unsupported_records"])

    def test_duplicate_sources_preserve_aliases(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "a.metallib").write_bytes(fixture())
            (root / "b.metallib").write_bytes(fixture())
            result = catalog([root])
            self.assertEqual(result["summary"]["files_seen"], 2)
            self.assertEqual(result["summary"]["unique_libraries"], 1)
            self.assertEqual(len(result["libraries"][0]["source_paths"]), 2)


if __name__ == "__main__":
    unittest.main()
