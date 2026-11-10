import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from compare_video_pixels import compare


def fixture(root, pixel=b'\x10\x20\x30\xff', timestamp=0):
    root.mkdir()
    plane = b'\x10\x20\x30\xff'
    (root/'frame.rgba').write_bytes(pixel)
    (root/'plane.bin').write_bytes(plane)
    row = dict(index=0,pts_value=timestamp,pts_scale=30,width=1,height=1,format='BGRA',
               planes=[dict(plane=0,width=1,height=1,row_bytes=4,sha256=hashlib.sha256(plane).hexdigest(),file='plane.bin')],
               rgba_sha256=hashlib.sha256(pixel).hexdigest(),rgba_file='frame.rgba')
    value = dict(source_sha256='a'*64,requested_format='BGRA',expected_frames=1,frames=[row],
                 session_status=0,reader_status=2,errors=[],os='fixture')
    (root/'result.json').write_text(json.dumps(value))


class VideoPixelTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.reference, self.candidate = self.root/'reference', self.root/'candidate'
        fixture(self.reference)

    def tearDown(self):
        self.temp.cleanup()

    def test_exact_pixels_and_planes(self):
        fixture(self.candidate)
        result = compare(self.reference,self.candidate)
        self.assertEqual(result['status'],'exact_match')
        self.assertEqual(result['saved_full_resolution_comparisons'],1)

    def test_blank_render_is_not_hidden_by_successful_decode(self):
        fixture(self.candidate,pixel=b'\0\0\0\xff')
        result = compare(self.reference,self.candidate)
        self.assertEqual(result['decoded_plane_matches'],1)
        self.assertEqual(result['frames'][0]['status'],'blank_render')
        self.assertEqual(result['status'],'review')

    def test_tampered_saved_evidence_rejected(self):
        fixture(self.candidate)
        (self.candidate/'frame.rgba').write_bytes(b'\0'*4)
        with self.assertRaisesRegex(ValueError,'hash mismatch'):
            compare(self.reference,self.candidate)

    def test_different_timestamp_cannot_pass_by_matching_frame_index(self):
        fixture(self.candidate,timestamp=1)
        result = compare(self.reference,self.candidate)
        self.assertFalse(result['complete_frame_sets'])
        self.assertTrue(all(r['status']=='missing_frame' for r in result['frames']))

    def test_empty_plane_inventory_is_not_an_exact_decode_match(self):
        fixture(self.candidate)
        path=self.candidate/'result.json';value=json.loads(path.read_text());value['frames'][0]['planes']=[]
        path.write_text(json.dumps(value))
        result=compare(self.reference,self.candidate)
        self.assertEqual(result['frames'][0]['status'],'invalid_plane_count')


if __name__=='__main__':
    unittest.main()
