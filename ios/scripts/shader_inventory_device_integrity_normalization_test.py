import copy,json
from pathlib import Path
import unittest
import os
from shader_inventory_device_integrity_normalization_review import review


class NormalizationOracleTests(unittest.TestCase):
    def setUp(self):
        p=Path(os.environ.get('HENGE_TEST_ARTIFACTS', '/nonexistent-henge-test-artifacts'))/'shader-inventory/inventory-integrity-03/normalization-gate/retarget-and-run.json'
        if not p.exists():self.skipTest('retained native normalization fixture absent')
        self.rows=[json.loads(r['stdout']) for r in json.loads(p.read_text()) if r['command'][0].endswith('native-normalization')];self.r=copy.deepcopy(self.rows[-1])
    def test_both_original_and_converted_exact(self):
        self.assertEqual(len(self.rows),2)
        for r in self.rows:self.assertFalse(review(r)['issues']);self.assertFalse(review(r)['CI_archive_reflection_semantics_verified'])
    def test_fixed_mode_cannot_pass_both(self):
        self.r['cases'][1]['actual_float4_pixels']=self.r['cases'][0]['actual_float4_pixels'];self.r['cases'][1]['actual_sha256']=self.r['cases'][0]['actual_sha256'];self.assertTrue(review(self.r)['issues'])
    def test_missing_specialization_rejected(self):
        self.r['cases'].pop();self.assertTrue(review(self.r)['issues'])
    def test_wrong_constant_index_rejected(self):
        self.r['constants'][0]['index']=0;self.assertTrue(review(self.r)['issues'])
    def test_no_dispatch_rejected(self):
        self.r['cases'][0]['dispatch_completed']=False;self.assertTrue(review(self.r)['issues'])


if __name__=='__main__':unittest.main()
