#!/usr/bin/env python3
"""Bounded regression tests for the experimental container packer."""
from pathlib import Path
import struct
import tempfile
import unittest

from catalog_metallibs import inspect_metallib
from shader_inventory_repair_pack import pack
from test_catalog_metallibs import fixture


class PackTests(unittest.TestCase):
    def run_pack(self, blobs):
        with tempfile.TemporaryDirectory() as temp:
            paths=[]
            for i,blob in enumerate(blobs):
                p=Path(temp)/f'{i}.metallib';p.write_bytes(blob);paths.append(p)
            return pack(paths)

    def test_modules_and_duplicate_name_multiplicity_are_preserved(self):
        original=fixture((2,))
        data,manifest=self.run_pack([original,original])
        parsed=inspect_metallib(data)
        self.assertEqual(len(parsed['functions']),2)
        self.assertEqual(parsed['air_region_count'],2)
        self.assertEqual([f['name'] for f in parsed['functions']],['function_0','function_0'])
        self.assertNotEqual(parsed['functions'][0]['air_offset'],parsed['functions'][1]['air_offset'])
        self.assertEqual([r['sha256'] for r in parsed['air_regions']],
                         [inspect_metallib(original)['air_regions'][0]['sha256']]*2)
        self.assertEqual(manifest['function_count'],2)

    def test_sha_mismatch_rejected_even_when_structurally_valid(self):
        bad=bytearray(fixture((2,)));bad[bad.index(b'HASH')+6]^=1
        with self.assertRaisesRegex(ValueError,'integrity'):
            self.run_pack([bytes(bad)])

    def test_platform_disagreement_rejected(self):
        a=fixture((2,));b=bytearray(a);struct.pack_into('<H',b,4,1);b[11]=0x82
        with self.assertRaisesRegex(ValueError,'disagreement'):
            self.run_pack([a,bytes(b)])

    def test_unrecognized_trailing_data_rejected(self):
        blob=bytearray(fixture((2,)));blob+=b'unrecognized';struct.pack_into('<Q',blob,16,len(blob))
        with self.assertRaisesRegex(ValueError,'trailing sections'):
            self.run_pack([bytes(blob)])

    def test_dynamic_library_cannot_be_silently_flattened(self):
        blob=bytearray(fixture((3,)));blob[10]=2
        with self.assertRaisesRegex(ValueError,'executable'):
            self.run_pack([bytes(blob)])


if __name__=='__main__':unittest.main()
