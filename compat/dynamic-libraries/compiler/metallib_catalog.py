#!/usr/bin/env python3
"""Catalog metallib bytes without loading Metal or assuming one AIR module.

Usage: catalog_metallibs.py DIR [FILE ...] --output catalog.json
       --alias-report sync-report.json

The JSON deduplicates by SHA-256; paths and report aliases remain provenance,
not inferred app ownership. Layout references (reverse-engineered, not an Apple
format contract): https://github.com/YuAo/MetalLibraryArchive and
https://llvm.org/docs/BitCodeFormat.html#bitcode-wrapper-format.
Only declared function tags, ranges, hashes, and LLVM wrapper headers are parsed.
Bitcode instructions, reflection, public/private metadata and extension payloads
are not decoded. No shader stage is inferred from names.

Also inventories standard FAT containers (Apple mach-o/fat.h layout) and a
strict observed AGX runtime profile: count, NUL-terminated symbol/offset pairs,
then contiguous length-prefixed LLVM wrappers. Runtime symbols are not assumed
to be functions. GPU Mach-O slices are retained without decoding their code.
"""

import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import struct


PLATFORMS = {0x8001: "macOS", 1: "iOS"}
OPERATING_SYSTEMS = {0: "unknown", 0x81: "macOS", 0x82: "iOS", 0x83: "tvOS",
                     0x84: "watchOS", 0x86: "macCatalyst", 0x87: "iOS Simulator",
                     0x88: "tvOS Simulator", 0x89: "watchOS Simulator"}
FUNCTION_TYPES = {0: "vertex", 1: "fragment", 2: "kernel", 3: "unqualified",
                  4: "visible", 5: "extern", 6: "intersection"}
WRAPPER_MAGIC = b"\xde\xc0\x17\x0b"
BITCODE_MAGIC = b"BC\xc0\xde"
FAT_MAGIC = b"\xca\xfe\xba\xbe"


class FormatError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise FormatError(message)


def tags_at(data, start, end):
    """Read length-delimited tags; ENDT has no length field."""
    tags = []
    pos = start
    while pos + 4 <= end:
        tag = data[pos:pos + 4]
        if tag == b"ENDT":
            return tags, pos + 4
        require(pos + 6 <= end, f"truncated tag header at {pos}")
        size = struct.unpack_from("<H", data, pos + 4)[0]
        require(pos + 6 + size <= end, f"tag at {pos} exceeds its container")
        tags.append({"tag": tag.decode("ascii", errors="backslashreplace"),
                     "offset": pos, "size": size, "data": data[pos + 6:pos + 6 + size]})
        pos += 6 + size
    raise FormatError(f"missing ENDT at {start}")


def opaque(tag, scope):
    return {"scope": scope, "tag": tag["tag"], "offset": tag["offset"],
            "size": tag["size"], "data_hex": tag["data"].hex(),
            "reason": "tag payload semantics not decoded"}


def decode_function(data, index, pos, end, unsupported):
    require(pos + 4 <= end, f"truncated function {index}")
    size = struct.unpack_from("<I", data, pos)[0]
    require(size >= 8 and pos + size <= end, f"invalid function group size at {pos}: {size}")
    tags, stop = tags_at(data, pos + 4, pos + size)
    require(stop == pos + size, f"function group size/ENDT mismatch at {pos}")
    function = {"index": index, "record_offset": pos, "record_size": size,
                "name": None, "type_raw": None, "function_type": None, "shader_stage": None,
                "stage_evidence": None, "offsets": None, "air_size": None,
                "declared_air_sha256": None, "air_version": None, "language_version": None}
    seen = set()
    lengths = {"TYPE": 1, "OFFT": 24, "MDSZ": 8, "HASH": 32, "VERS": 8}
    for tag in tags:
        key, value = tag["tag"], tag["data"]
        require(key not in seen, f"duplicate {key} in function {index}")
        seen.add(key)
        if key in lengths:
            require(len(value) == lengths[key], f"invalid {key} length in function {index}")
        if key == "NAME":
            require(value.endswith(b"\0") and b"\0" not in value[:-1], f"invalid NAME in function {index}")
            try:
                function["name"] = value[:-1].decode("utf-8")
            except UnicodeDecodeError as error:
                raise FormatError(f"non-UTF8 NAME in function {index}") from error
        elif key == "TYPE":
            raw = value[0]
            function["type_raw"] = raw
            function["function_type"] = FUNCTION_TYPES.get(raw)
            if raw in (0, 1, 2, 6):
                function["shader_stage"] = FUNCTION_TYPES[raw]
                function["stage_evidence"] = {"tag": "TYPE", "offset": tag["offset"], "value": raw}
            elif raw not in FUNCTION_TYPES:
                unsupported.append(opaque(tag, f"function[{index}]"))
        elif key == "OFFT":
            function["offsets"] = dict(zip(("public_metadata", "private_metadata", "bitcode"),
                                           struct.unpack("<QQQ", value)))
        elif key == "MDSZ":
            function["air_size"] = struct.unpack("<Q", value)[0]
        elif key == "HASH":
            function["declared_air_sha256"] = value.hex()
        elif key == "VERS":
            version = struct.unpack("<HHHH", value)
            function["air_version"] = list(version[:2])
            function["language_version"] = list(version[2:])
        else:
            unsupported.append(opaque(tag, f"function[{index}]"))
    return function, stop


def inspect_air(data, offset, size):
    """Validate a declared AIR range, without claiming bitcode semantic validity."""
    region = {"offset": offset, "size": size, "sha256": hashlib.sha256(data[offset:offset + size]).hexdigest(),
              "format": "unknown", "wrapper": None, "structurally_valid_wrapper": False}
    payload = data[offset:offset + size]
    if payload[:4] == WRAPPER_MAGIC:
        require(size >= 20, f"truncated AIR wrapper at {offset}")
        _, version, relative, length, cpu = struct.unpack_from("<IIIII", payload)
        require(relative >= 20 and length >= 4 and relative + length <= size,
                f"AIR wrapper payload out of range at {offset}")
        require(payload[relative:relative + 4] == BITCODE_MAGIC, f"missing LLVM bitcode magic at {offset + relative}")
        trailing = payload[relative + length:]
        region.update(format="llvm_bitcode_wrapper", wrapper={"version": version, "cpu_type": cpu,
                      "bitcode_offset": offset + relative, "bitcode_size": length,
                      "trailing_bytes": len(trailing), "trailing_all_zero": not any(trailing)})
        # LLVM wrappers may have zero padding to a 16-byte boundary. Anything
        # larger/nonzero can contain another module and must remain unsupported.
        region["structurally_valid_wrapper"] = version == 0 and len(trailing) < 16 and not any(trailing)
    elif payload[:4] == BITCODE_MAGIC:
        region["format"] = "raw_llvm_bitcode"
    return region


def empty_record(data):
    return {"sha256": hashlib.sha256(data).hexdigest(), "byte_size": len(data),
              "format": "unknown", "symbols": [], "slices": [],
              "header": None, "functions": [], "air_regions": [], "air_region_count": 0,
              "integrity_mismatches": [],
              "malformed_records": [], "unsupported_records": [], "uncovered_bitcode_ranges": [],
              "single_payload_extraction_valid": False}


def parsed_status(record):
    if record["malformed_records"]:
        return "malformed"
    if record["integrity_mismatches"]:
        return "parsed_with_integrity_mismatches"
    if record["unsupported_records"]:
        return "parsed_with_opaque_records"
    return "parsed"


def inspect_runtime_table(data):
    """Recognize only the complete observed profile; no magic/name heuristics.

An unrecognized non-MTLB file is unsupported, not necessarily corrupt. Exact
table/range coverage and valid LLVM wrappers are mandatory for this profile.
"""
    record = empty_record(data)
    require(len(data) >= 4, "too short for runtime symbol count")
    count = struct.unpack_from("<I", data)[0]
    require(0 < count <= (len(data) - 4) // 6, "runtime symbol count outside profile")
    pos = 4
    symbols = []
    for index in range(count):
        end = data.find(b"\0", pos)
        require(end > pos and end + 5 <= len(data), "runtime symbol record outside profile")
        name = data[pos:end]
        require(all(32 <= byte < 127 for byte in name), "non-ASCII runtime symbol outside profile")
        offset = struct.unpack_from("<I", data, end + 1)[0]
        symbols.append({"index": index, "name": name.decode("ascii"), "record_offset": pos,
                        "payload_record_offset": offset, "shader_stage": None,
                        "classification": "symbol; function/global role unknown"})
        pos = end + 5
    record["symbol_table_end"] = pos
    for symbol in symbols:
        offset = symbol["payload_record_offset"]
        require(offset == pos and offset + 4 <= len(data), "non-contiguous runtime payload outside profile")
        size = struct.unpack_from("<I", data, offset)[0]
        require(size > 0 and offset + 4 + size <= len(data), "runtime payload size outside profile")
        region = inspect_air(data, offset + 4, size)
        require(region["structurally_valid_wrapper"], "runtime payload is not a supported LLVM wrapper")
        region["symbol_indices"] = [symbol["index"]]
        region["function_indices"] = []
        record["air_regions"].append(region)
        symbol["air_offset"] = offset + 4
        symbol["air_size"] = size
        pos = offset + 4 + size
    require(pos == len(data), "runtime payloads do not cover the file")
    record.update(format="agx_runtime_symbol_table", symbols=symbols,
                  air_region_count=len(record["air_regions"]), status="parsed_with_opaque_records")
    record["format_evidence"] = "Observed structural profile: bounded symbol/offset table and complete contiguous length-prefixed LLVM wrapper coverage. No version/platform fields established."
    record["unsupported_records"].append({"scope": "runtime_symbols",
        "reason": "symbol role, shader stage, platform/version, and bitcode semantics are not established"})
    return record


def inspect_fat(data):
    """Parse FAT_MAGIC/fat_arch layout; retain CPU values without GPU guesses."""
    record = empty_record(data)
    record["format"] = "fat_container"
    try:
        require(len(data) >= 8, "truncated FAT header")
        count = struct.unpack_from(">I", data, 4)[0]
        require(count > 0 and 8 + count * 20 <= len(data), "FAT architecture count out of bounds")
        record["declared_slice_count"] = count
        ranges = []
        for index in range(count):
            cpu, subtype, offset, size, alignment = struct.unpack_from(">5I", data, 8 + index * 20)
            require(offset >= 8 + count * 20 and size > 0 and offset + size <= len(data),
                    f"FAT slice {index} out of bounds")
            require(alignment < 64 and offset % (1 << alignment) == 0, f"FAT slice {index} alignment invalid")
            ranges.append((offset, offset + size))
            payload = data[offset:offset + size]
            slice_record = {"index": index, "cpu_type_raw": cpu, "cpu_subtype_raw": subtype,
                            "offset": offset, "size": size, "alignment_power": alignment,
                            "sha256": hashlib.sha256(payload).hexdigest(), "magic_hex": payload[:4].hex(),
                            "format": "unknown"}
            record["slices"].append(slice_record)
            if payload[:4] == b"MTLB":
                child = inspect_metallib(payload)
                slice_record.update(format="metallib", metallib=child)
                for function in child["functions"]:
                    function = dict(function, slice_index=index)
                    function["record_offset"] += offset
                    if "air_offset" in function:
                        function["air_offset"] += offset
                    if function["stage_evidence"] is not None:
                        function["stage_evidence"] = dict(function["stage_evidence"])
                        function["stage_evidence"]["offset"] += offset
                    record["functions"].append(function)
                for region in child["air_regions"]:
                    region = dict(region, slice_index=index, offset=region["offset"] + offset)
                    if region["wrapper"] is not None:
                        region["wrapper"] = dict(region["wrapper"])
                        region["wrapper"]["bitcode_offset"] += offset
                    record["air_regions"].append(region)
                for problem in child["malformed_records"]:
                    record["malformed_records"].append(dict(problem, slice_index=index))
                for mismatch in child["integrity_mismatches"]:
                    record["integrity_mismatches"].append(dict(mismatch, slice_index=index,
                        offset=mismatch["offset"] + offset))
                for problem in child["unsupported_records"]:
                    record["unsupported_records"].append(dict(problem, slice_index=index,
                        offset_basis="relative to slice; see slices[].metallib"))
            elif payload[:4] in (b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf"):
                slice_record["format"] = "mach_o_64"
                record["unsupported_records"].append({"scope": "fat_slice", "slice_index": index,
                    "offset": offset, "size": size, "reason": "Mach-O GPU code and symbols not decoded; no AIR/stage assumption"})
            else:
                record["unsupported_records"].append({"scope": "fat_slice", "slice_index": index,
                    "offset": offset, "size": size, "reason": "slice format not decoded"})
        ranges.sort()
        for previous, current in zip(ranges, ranges[1:]):
            require(previous[1] <= current[0], "FAT slices overlap")
        record["air_region_count"] = len(record["air_regions"])
        record["offset_basis"] = "Top-level function/AIR offsets are file absolute; nested slices[].metallib offsets are slice relative. Function indices are local to each slice."
    except FormatError as error:
        record["malformed_records"].append({"reason": str(error)})
    record["status"] = parsed_status(record)
    return record


def inspect_metallib(data):
    if data[:4] == FAT_MAGIC:
        return inspect_fat(data)
    if data[:4] != b"MTLB":
        try:
            return inspect_runtime_table(data)
        except FormatError:
            record = empty_record(data)
            record["status"] = "unsupported"
            record["unsupported_records"].append({"scope": "file", "magic_hex": data[:16].hex(),
                "reason": "unrecognized container; not evidence of corruption"})
            return record
    record = empty_record(data)
    record["format"] = "metallib"
    try:
        require(len(data) >= 88 and data[:4] == b"MTLB", "missing or truncated MTLB header")
        platform, major, minor, kind, os_id, os_major, os_minor = struct.unpack_from("<HHHBBHH", data, 4)
        declared_size = struct.unpack_from("<Q", data, 16)[0]
        sections = {}
        for index, name in enumerate(("functions", "public_metadata", "private_metadata", "bitcode")):
            offset, size = struct.unpack_from("<QQ", data, 24 + 16 * index)
            sections[name] = {"offset": offset, "size": size}
            extent = size + 4 if name == "functions" else size
            require(offset >= 88 and offset + extent <= len(data), f"{name} section out of bounds")
        extents = sorted((s["offset"], s["offset"] + s["size"] + (4 if name == "functions" else 0), name)
                         for name, s in sections.items() if s["size"] or name == "functions")
        for previous, current in zip(extents, extents[1:]):
            require(previous[1] <= current[0], f"{previous[2]} and {current[2]} sections overlap")
        record["header"] = {"platform_raw": platform, "platform": PLATFORMS.get(platform),
                            "format_version": [major, minor], "library_type_raw": kind,
                            "target_os_raw": os_id, "target_os": OPERATING_SYSTEMS.get(os_id),
                            "target_os_version": [os_major, os_minor], "declared_file_size": declared_size,
                            "sections": sections}
        require(declared_size == len(data), "declared file size does not match bytes")
        if platform not in PLATFORMS or os_id not in OPERATING_SYSTEMS or major != 2 or kind > 3:
            record["unsupported_records"].append({"scope": "header", "reason": "unrecognized header enum or major version"})
        start, size = sections["functions"].values()
        end = start + size + 4
        count = struct.unpack_from("<I", data, start)[0]
        record["declared_function_count"] = count
        require(count <= (end - start - 4) // 8, "function count exceeds available records")
        pos = start + 4
        for index in range(count):
            function, pos = decode_function(data, index, pos, end, record["unsupported_records"])
            record["functions"].append(function)
        require(pos == end, "function records do not fill declared function section")
        extension_end = sections["public_metadata"]["offset"]
        require(end <= extension_end, "function list overlaps public metadata")
        if end < extension_end:
            extension, stop = tags_at(data, end, extension_end)
            require(stop == extension_end, "header extension does not fill its range")
            record["unsupported_records"].extend(opaque(tag, "header_extension") for tag in extension)
        bitcode = sections["bitcode"]
        regions = {}
        for function in record["functions"]:
            index = function["index"]
            if function["offsets"] is None or function["air_size"] is None:
                record["unsupported_records"].append({"scope": f"function[{index}]", "reason": "OFFT or MDSZ missing; AIR extent not guessed"})
                continue
            relative, length = function["offsets"]["bitcode"], function["air_size"]
            require(length > 0 and relative + length <= bitcode["size"], f"function {index} AIR range exceeds bitcode section")
            for name in ("public_metadata", "private_metadata"):
                require(function["offsets"][name] < sections[name]["size"], f"function {index} {name} offset out of range")
            absolute = bitcode["offset"] + relative
            key = (absolute, length)
            if key not in regions:
                region = inspect_air(data, absolute, length)
                region["function_indices"] = []
                regions[key] = region
            region = regions[key]
            region["function_indices"].append(index)
            function["air_offset"] = absolute
            expected = function["declared_air_sha256"]
            function["actual_air_sha256"] = region["sha256"]
            function["air_hash_matches"] = region["sha256"] == expected if expected is not None else None
            if function["air_hash_matches"] is False:
                # Current Apple tools can emit CI extern archives with HASH
                # differing from their serialized AIR, including an authored
                # sampler control that native Core Image loads/renders exactly.
                # Keep the byte discrepancy without conflating it with bad
                # structure or claiming it is safe for another runtime.
                record["integrity_mismatches"].append({"scope": "function", "function_index": index,
                    "offset": absolute, "size": length, "declared_sha256": expected,
                    "actual_sha256": region["sha256"], "reason": "HASH differs from serialized AIR SHA-256"})
        record["air_regions"] = sorted(regions.values(), key=lambda r: r["offset"])
        record["air_region_count"] = len(regions)
        cursor = bitcode["offset"]
        for region in record["air_regions"]:
            require(region["offset"] >= cursor, "distinct AIR ranges overlap")
            if region["offset"] > cursor:
                record["uncovered_bitcode_ranges"].append({"offset": cursor, "size": region["offset"] - cursor})
            cursor = region["offset"] + region["size"]
            if not region["structurally_valid_wrapper"]:
                record["unsupported_records"].append({"scope": "air_region", "offset": region["offset"],
                    "reason": "not a single supported LLVM wrapper with bounded zero padding; bitcode not decoded"})
        if cursor < bitcode["offset"] + bitcode["size"]:
            record["uncovered_bitcode_ranges"].append({"offset": cursor, "size": bitcode["offset"] + bitcode["size"] - cursor})
        record["single_payload_extraction_valid"] = (len(regions) == 1 and not record["uncovered_bitcode_ranges"]
            and record["air_regions"][0]["structurally_valid_wrapper"])
    except FormatError as error:
        record["malformed_records"].append({"reason": str(error)})
    record["status"] = parsed_status(record)
    return record


def catalog(paths, alias_reports=()):
    aliases = {}
    for report in alias_reports:
        content = json.loads(report.read_text())
        for entry in content.get("libraries", []):
            for source in entry.get("sources", []):
                aliases.setdefault(entry["sha256"], []).append({"alias": source, "report": str(report.resolve())})
    files = set()
    for path in paths:
        if path.is_dir():
            files.update(path.rglob("*.metallib"))
        else:
            files.add(path)
    libraries, failures = {}, []
    for path in sorted(files):
        try:
            data = path.read_bytes()
        except OSError as error:
            failures.append({"path": str(path.absolute()), "error": str(error)})
            continue
        digest = hashlib.sha256(data).hexdigest()
        if digest not in libraries:
            libraries[digest] = inspect_metallib(data)
            libraries[digest]["source_paths"] = []
            libraries[digest]["source_aliases"] = aliases.get(digest, [])
        libraries[digest]["source_paths"].append(str(path.absolute()))
    records = sorted(libraries.values(), key=lambda r: r["sha256"])
    return {"schema_version": 1, "inputs": [str(p.absolute()) for p in paths],
            "coverage": "Only supplied local artifacts; no app attribution or runtime compilation validation.",
            "limitations": ["AIR bitcode instructions and internal module metadata are not decoded.",
                "Public/private metadata and header extension payloads remain opaque.",
                "Unknown/missing TYPE stays null; names never determine shader stage.",
                "Missing MDSZ is unsupported; no extent is inferred from another function.",
                "Runtime table symbols may denote functions or globals; their stages remain unknown.",
                "FAT Mach-O GPU slices are retained but not decoded; no AIR/function counts are inferred.",
                "Integrity mismatches are independent of structural validity; single_payload_extraction_valid does not imply hash or runtime acceptance."],
            "summary": {"files_seen": len(files), "unique_libraries": len(records), "read_errors": len(failures),
                "format_counts": dict(Counter(r["format"] for r in records)),
                "status_counts": dict(Counter(r["status"] for r in records)),
                "libraries_with_integrity_mismatches": sum(bool(r["integrity_mismatches"]) for r in records),
                "integrity_mismatch_count": sum(len(r["integrity_mismatches"]) for r in records),
                "stage_counts": dict(Counter(f["shader_stage"] or "unknown" for r in records for f in r["functions"])),
                "runtime_symbol_count": sum(len(r["symbols"]) for r in records),
                "air_region_count_distribution": dict(Counter(str(r["air_region_count"]) for r in records)),
                "single_payload_extraction_valid": sum(r["single_payload_extraction_valid"] for r in records)},
            "read_errors": failures, "libraries": records}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sources", type=Path, nargs="+")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--alias-report", type=Path, action="append", default=[])
    args = parser.parse_args()
    result = catalog(args.sources, args.alias_report)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result["summary"], indent=2))


if __name__ == "__main__":
    main()
