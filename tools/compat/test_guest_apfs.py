"""Bounded native APFS metadata traversal; synthetic GPT/object-map fixtures.

Real authored System/Data images are a separate qualification gate.
"""
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
import uuid
import test_guest_disk as gpt

ROOT = Path(__file__).resolve().parents[2]


def checksum(block):
    a = b = 0
    modulus = 0xffffffff
    for (word,) in struct.iter_unpack('<I', block[8:]):
        a = (a + word) % modulus
        b = (b + a) % modulus
    lo = modulus - (a + b) % modulus
    return struct.pack('<II', lo, modulus - (a + lo) % modulus)


def object_block(oid, xid, kind, subtype=0):
    block = bytearray(4096)
    struct.pack_into('<QQII', block, 8, oid, xid, kind, subtype)
    return block


def node(root, leaf, records):
    block = object_block(4 if root else 7, 2, 0x40000002 if root else 0x40000003, 11)
    struct.pack_into('<HHIHH', block, 32, 4 | int(root) | (2 if leaf else 0),
                     0 if leaf else 1, len(records), 0, len(records) * 4)
    keybase = 56 + len(records) * 4
    end = 4096 - (40 if root else 0)
    for i, (oid, value) in enumerate(records):
        vo = (i + 1) * len(value)
        struct.pack_into('<HH', block, 56 + i * 4, i * 16, vo)
        struct.pack_into('<QQ', block, keybase + i * 16, oid, 2)
        block[end - vo:end - vo + len(value)] = value
    return block


@unittest.skipUnless(sys.platform == 'darwin', 'Darwin image lease controls')
class GuestAPFSTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.compiler = tempfile.TemporaryDirectory(prefix='henge-apfs-control-')
        cls.addClassCleanup(cls.compiler.cleanup)
        cls.control = Path(cls.compiler.name) / 'control'
        native = ROOT / 'compat/guest-provisioning'
        subprocess.run(['xcrun', 'clang', '-Wall', '-Wextra', '-Werror',
                        '-fsanitize=address,undefined', '-fno-omit-frame-pointer',
                        '-I', str(native), str(ROOT / 'tools/compat/guest_apfs_control.c'),
                        str(native / 'HGGuestAPFS.c'), str(native / 'HGGuestDisk.c'),
                        '-lz', '-o', str(cls.control)], check=True)

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='henge-apfs-fixture-')
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / 'authored.img'
        self.blocks = {}
        for index, xid in ((0, 1), (1, 2)):
            b = object_block(1, xid, 0x80000001)
            b[32:36] = b'NXSB'
            struct.pack_into('<IQ', b, 36, 4096, 16)
            struct.pack_into('<Q', b, 64, 2)
            b[72:88] = uuid.UUID(int=14).bytes
            struct.pack_into('<I', b, 104, 2)
            struct.pack_into('<Q', b, 112, 1)
            struct.pack_into('<Q', b, 160, 3)
            struct.pack_into('<IQQ', b, 180, 2, 101 if index else 0, 102 if index else 0)
            self.blocks[index] = b
        omap = object_block(3, 2, 0x4000000b)
        struct.pack_into('<I', omap, 40, 0x40000002)
        struct.pack_into('<Q', omap, 48, 4)
        self.blocks[3] = omap
        self.blocks[4] = node(True, True, [(oid, struct.pack('<IIQ', 0, 4096, address))
                                         for oid, address in ((101, 5), (102, 6))])
        for index, oid, role in ((5, 101, 1), (6, 102, 64)):
            b = object_block(oid, 2, 13)
            b[32:36] = b'APSB'
            b[240:256] = uuid.UUID(int=oid).bytes
            struct.pack_into('<Q', b, 264, 1)
            struct.pack_into('<H', b, 964, role)
            b[1008:1024] = uuid.UUID(int=13).bytes
            self.blocks[index] = b

    def emit(self, corrupt=None):
        image = gpt.GuestDiskTests(methodName='runTest')
        image.path, image.sectors = self.path, 4096
        image.entries = bytearray(128 * 128)
        image.entry(0, gpt.APFS, 40, image.sectors - 40)
        image.emit()
        with self.path.open('r+b') as stream:
            for index, original in self.blocks.items():
                block = bytearray(original)
                block[:8] = checksum(block)
                if index == corrupt:
                    block[-1] ^= 1
                stream.seek(40 * 512 + index * 4096)
                stream.write(block)

    def inspect(self, valid=False, catalog=False):
        command = [str(self.control), str(self.path)] + (['--catalog'] if catalog else [])
        r = subprocess.run(command, capture_output=True, timeout=5)
        self.assertEqual(r.returncode, 0 if valid else 1, r.stderr)
        report = json.loads(r.stdout)
        self.assertEqual(report['passed'], valid)
        if not valid:
            self.assertEqual(report['volumes'], [])
        return report

    def test_latest_checkpoint_roles_identity_and_no_writes(self):
        self.emit()
        before = hashlib.sha256(self.path.read_bytes()).hexdigest()
        r = self.inspect(True)
        self.assertEqual(r['checkpoint_xid'], 2)
        self.assertEqual([v['role'] for v in r['volumes']], [1, 64])
        self.assertEqual([v['physical_block'] for v in r['volumes']], [5, 6])
        self.assertEqual(before, hashlib.sha256(self.path.read_bytes()).hexdigest())

    def test_interior_object_map_descent(self):
        self.blocks[4] = node(True, False, [(101, struct.pack('<Q', 7))])
        self.blocks[7] = node(False, True, [(oid, struct.pack('<IIQ', 0, 4096, address))
                                          for oid, address in ((101, 5), (102, 6))])
        self.emit()
        self.inspect(True)

    def test_checksums_at_every_metadata_layer(self):
        for index in (0, 1, 3, 4, 5, 6):
            with self.subTest(index=index):
                self.emit(corrupt=index)
                self.assertEqual(self.inspect()['error'], 'apfs-object-checksum')

    def test_conflicting_same_transaction_checkpoint_is_not_selected(self):
        struct.pack_into('<Q', self.blocks[0], 16, 2)
        struct.pack_into('<Q', self.blocks[1], 160, 9)
        self.emit()
        self.assertEqual(self.inspect()['error'], 'ambiguous-apfs-checkpoint')

    def test_catalog_includes_empty_old_checkpoint_and_deduplicates_exact_copies(self):
        self.emit()
        r = self.inspect(True, catalog=True)
        self.assertEqual(r['checkpoint_count'], 2)
        self.assertEqual(len(r['volumes']), 2)
        self.blocks[0] = self.blocks[1][:]
        self.emit()
        self.assertEqual(self.inspect(True, catalog=True)['checkpoint_count'], 1)

    def test_catalog_deduplicates_shared_records_across_transactions(self):
        struct.pack_into('<Q', self.blocks[0], 16, 2)
        struct.pack_into('<QQ', self.blocks[0], 184, 101, 102)
        struct.pack_into('<Q', self.blocks[1], 16, 3)
        self.emit()
        r = self.inspect(True, catalog=True)
        self.assertEqual(r['checkpoint_count'], 2)
        self.assertEqual(len(r['volumes']), 2)
        for volume in r['volumes']:
            self.assertEqual(volume['first_checkpoint_xid'], 2)
            self.assertEqual(volume['last_checkpoint_xid'], 3)

    def test_catalog_does_not_skip_unresolvable_old_populated_checkpoint(self):
        struct.pack_into('<QQ', self.blocks[0], 184, 101, 102)
        self.emit()
        self.inspect(True)
        self.inspect(catalog=True)

    def test_catalog_rejects_conflicting_historical_transaction_even_when_latest_is_valid(self):
        struct.pack_into('<Q', self.blocks[0], 16, 2)
        struct.pack_into('<Q', self.blocks[1], 16, 3)
        self.blocks[2] = self.blocks[1][:]
        struct.pack_into('<Q', self.blocks[2], 16, 2)
        self.emit()
        self.inspect(True)
        self.assertEqual(self.inspect(catalog=True)['error'], 'ambiguous-apfs-checkpoint')

    def test_catalog_retains_historical_roles_in_different_physical_records(self):
        struct.pack_into('<Q', self.blocks[0], 16, 2)
        struct.pack_into('<QQ', self.blocks[0], 184, 101, 102)
        struct.pack_into('<Q', self.blocks[1], 16, 3)
        struct.pack_into('<Q', self.blocks[1], 160, 8)
        struct.pack_into('<H', self.blocks[6], 964, 0)
        self.blocks[8] = object_block(8, 3, 0x4000000b)
        struct.pack_into('<I', self.blocks[8], 40, 0x40000002)
        struct.pack_into('<Q', self.blocks[8], 48, 9)
        self.blocks[9] = node(True, True, [(101, struct.pack('<IIQ', 0, 4096, 5)),
                                          (102, struct.pack('<IIQ', 0, 4096, 10))])
        struct.pack_into('<QQ', self.blocks[9], 8, 9, 3)
        struct.pack_into('<Q', self.blocks[9], 88, 3)
        self.blocks[10] = self.blocks[6][:]
        struct.pack_into('<Q', self.blocks[10], 16, 3)
        struct.pack_into('<H', self.blocks[10], 964, 64)
        self.emit()
        r = self.inspect(True, catalog=True)
        self.assertEqual(r['checkpoint_count'], 2)
        self.assertEqual(sorted(v['role'] for v in r['volumes']), [0, 1, 64])

    def test_geometry_and_feature_profile_refusal(self):
        for index, offset, fmt, value in ((0, 36, '<I', 8193), (0, 64, '<Q', 3),
                                         (0, 104, '<I', 4097), (0, 112, '<Q', 16),
                                         (1, 180, '<I', 101), (3, 48, '<Q', 99)):
            with self.subTest(offset=offset, value=value):
                original = self.blocks[index][:]
                struct.pack_into(fmt, self.blocks[index], offset, value)
                self.emit()
                self.inspect()
                self.blocks[index] = original

    def test_object_map_bad_offsets_flags_and_physical_addresses(self):
        end = 4096 - 40
        for offset, fmt, value in ((56, '<H', 65535), (58, '<H', 65535),
                                   (28, '<I', 99), (end - 16, '<I', 4),
                                   (end - 12, '<I', 8192), (end - 8, '<Q', 99),
                                   (64 + 16, '<Q', 100)):
            with self.subTest(offset=offset, value=value):
                original = self.blocks[4][:]
                struct.pack_into(fmt, self.blocks[4], offset, value)
                self.emit()
                self.inspect()
                self.blocks[4] = original

    def test_cycles_and_volume_identity_mismatches(self):
        original = self.blocks[4][:]
        self.blocks[4] = node(True, False, [(101, struct.pack('<Q', 4))])
        self.emit()
        self.inspect()
        self.blocks[4] = original
        for offset, value in ((8, 999), (16, 3)):
            original = self.blocks[5][:]
            struct.pack_into('<Q', self.blocks[5], offset, value)
            self.emit()
            self.inspect()
            self.blocks[5] = original


if __name__ == '__main__':
    unittest.main()
