#!/usr/bin/env python3
import struct,unittest
from shader_inventory_repair_binary_boundary import macho

class BoundsTests(unittest.TestCase):
    def test_empty_64bit_header(self):
        b=struct.pack('<8I',0xfeedfacf,0x100000c,0,6,0,0,0,0)
        self.assertEqual(macho(lambda o,n:b[o:o+n])['sections'],[])
    def test_empty_32bit_header(self):
        b=struct.pack('<7I',0xfeedface,12,0,6,0,0,0)
        self.assertEqual(macho(lambda o,n:b[o:o+n])['sections'],[])
    def test_truncated_command(self):
        b=struct.pack('<8I',0xfeedfacf,0x100000c,0,6,1,8,0,0)+struct.pack('<II',0x19,72)
        with self.assertRaisesRegex(ValueError,'length'):macho(lambda o,n:b[o:o+n])
    def test_truncated_section_array(self):
        seg=struct.pack('<II16s4Q4I',0x19,72,b'__TEXT',0,0,0,0,0,0,1,0)
        b=struct.pack('<8I',0xfeedfacf,0x100000c,0,6,1,72,0,0)+seg
        with self.assertRaisesRegex(ValueError,'section array'):macho(lambda o,n:b[o:o+n])
    def test_unsupported_header_explicit(self):
        with self.assertRaisesRegex(ValueError,'unsupported'):macho(lambda o,n:b'MTLB'+bytes(28))
if __name__=='__main__':unittest.main()
