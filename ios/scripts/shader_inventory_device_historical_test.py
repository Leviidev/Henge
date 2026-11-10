import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
import os
from shader_inventory_device_historical_review import review,expected_bgra


class HistoricalOracleTests(unittest.TestCase):
    def setUp(self):
        self.root=Path(os.environ.get('HENGE_TEST_ARTIFACTS', '/nonexistent-henge-test-artifacts'))/'shader-inventory/historical-6964-01';p=self.root/'native-reviewed.json'
        if not p.exists():self.skipTest('retained historical native oracle absent')
        self.mb=(self.root/'NativeResources/historical-render-jobs.json').read_bytes();self.report_path=Path(json.loads(p.read_text())['report']);self.r=json.loads(self.report_path.read_text())
    def test_exact_pixels_keep_historical_descriptor_unknown(self):
        r=review(self.mb,self.r,self.report_path.parent);self.assertFalse(r['issues']);self.assertEqual(r['pixels_checked'],768);self.assertFalse(r['exact_historical_descriptor_verified'])
    def test_unchanged_clear_rejected(self):
        self.r['cases'][0].update(actual_sha256=hashlib.sha256(bytes([0,0,255,255])*256).hexdigest(),first_pixel_bgra8=[0,0,255,255]);self.assertTrue(review(self.mb,self.r)['issues'])
    def test_wrong_uniform_layout_rejected(self):
        self.r['cases'][0]['uniform_bytes_sha256']='0'*64;self.assertTrue(review(self.mb,self.r)['issues'])
    def test_missing_blend_case_rejected(self):
        self.r['cases'].pop();self.assertTrue(review(self.mb,self.r)['issues'])
    def test_substituted_function_rejected(self):
        self.r['fragment_function']='BvcmA2Xhfcu';self.assertTrue(review(self.mb,self.r)['issues'])
    def test_pipeline_load_alone_rejected(self):
        self.r['cases'][0]['draw_encoded']=False;self.assertTrue(review(self.mb,self.r)['issues'])
    def test_historical_attribution_claim_rejected(self):
        self.r['exact_historical_descriptor_verified']=True;self.assertTrue(review(self.mb,self.r)['issues'])
    def test_independent_cpu_half_coverage_math(self):
        m=json.loads(self.mb);self.assertEqual(expected_bgra(m['cases'][2]),[128,0,128,255])


if __name__=='__main__':unittest.main()
