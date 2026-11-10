#!/usr/bin/env python3
import os
import copy,json,tempfile,shutil,unittest
from pathlib import Path
from shader_inventory_device_expansion_review import review
ROOT=Path(os.environ.get('HENGE_TEST_ARTIFACTS', '/nonexistent-henge-test-artifacts'))/'shader-inventory/inventory-expansion-ipad-03'

@unittest.skipUnless(ROOT.exists(), 'optional retained evidence absent; set HENGE_TEST_ARTIFACTS')
class ReviewTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.manifest=(ROOT/'AuditAssets/expansion-jobs.json').read_bytes();cls.rows=json.loads((ROOT/'native-review-summary.json').read_text())
    def case(self,prefix):
        row=next(r for r in self.rows if r['id'].startswith(prefix));p=Path(row['report']);return json.loads(p.read_text()),p.parent
    def test_native_passes_and_legacy_failure_explicit(self):
        self.assertEqual(len(self.rows),32)
        for row in self.rows:
            p=Path(row['report']);r=review(self.manifest,json.loads(p.read_text()),p.parent,'macos')
            self.assertEqual(bool(r['issues']),row['id'].startswith('dcf7'))
    def test_constant_delta_rejected(self):
        r,p=self.case('8db3');bad=copy.deepcopy(r);c=next(c for f in bad['functions']for c in f['constants']);c['required']=not c['required'];self.assertTrue(review(self.manifest,bad,p)['issues'])
    def test_report_platform_and_asset_binding(self):
        r,p=self.case('8db3');self.assertTrue(review(self.manifest,r,p,'ios')['issues']);r['candidate_sha256']='0'*64;self.assertTrue(review(self.manifest,r,p)['issues'])
    def test_cannot_hide_failed_load(self):
        r,p=self.case('8db3');r['library_loaded']=False;self.assertTrue(review(self.manifest,r,p)['issues'])
    def test_CI_raw_readback_required(self):
        r,p=self.case('9056')
        with tempfile.TemporaryDirectory()as d:
            q=Path(d);data=bytearray((p/'radar-oracle.json.rgba32f').read_bytes());data[0]^=1;(q/'radar-oracle.json.rgba32f').write_bytes(data);self.assertTrue(review(self.manifest,r,q)['issues'])
if __name__=='__main__':unittest.main()
