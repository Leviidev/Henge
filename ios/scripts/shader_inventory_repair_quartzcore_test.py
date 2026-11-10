#!/usr/bin/env python3
import os
import copy,json,struct,tempfile,unittest
from pathlib import Path
from shader_inventory_repair_quartzcore import metadata
from shader_inventory_device_quartzcore_review import review
ROOT=Path(os.environ.get('HENGE_TEST_ARTIFACTS', '/nonexistent-henge-test-artifacts'))/'shader-inventory/quartzcore-150-01'

class MetadataTests(unittest.TestCase):
    def test_both_length_conventions_preserve_payload(self):
        f={'offsets':{'public_metadata':0}};r={'header':{'sections':{'public_metadata':{'offset':0,'size':8}}},'functions':[f]}
        for n in [4,8]:self.assertEqual(metadata(struct.pack('<I',n)+b'ENDT',r,f,'public_metadata')[4:],b'ENDT')
    def test_bad_bound_rejected(self):
        f={'offsets':{'public_metadata':0}};r={'header':{'sections':{'public_metadata':{'offset':0,'size':8}}},'functions':[f]}
        with self.assertRaises(ValueError):metadata(struct.pack('<I',999)+b'ENDT',r,f,'public_metadata')
    @unittest.skipUnless(ROOT.exists(), 'optional retained evidence absent; set HENGE_TEST_ARTIFACTS')
    def test_original_and_candidate_oracle(self):
        for v in ['original','candidate']:
            p=ROOT/(v+'-render');m=(ROOT/(v+'-assets/quartzcore-jobs.json')).read_bytes();r=json.loads((p/'quartzcore-report.json').read_text());self.assertEqual(review(m,r,p)['issues'],[])
            for field in ['library_loaded','vertex_specialized','fragment_specialized','pipeline_created']:
                bad=copy.deepcopy(r);bad[field]=False;self.assertTrue(review(m,bad,p)['issues'])
            bad=copy.deepcopy(r);bad['cases']=bad['cases'][:2];self.assertTrue(review(m,bad,p)['issues'])
            bad=copy.deepcopy(r);bad['descriptor']['stride']=32;self.assertTrue(review(m,bad,p)['issues'])
            bad=copy.deepcopy(r);bad['cases'][0]['vertex_bytes_sha256']='0'*64;self.assertTrue(review(m,bad,p)['issues'])
    @unittest.skipUnless(ROOT.exists(), 'optional retained evidence absent; set HENGE_TEST_ARTIFACTS')
    def test_all_modules_payloads_preserved(self):
        rows=json.loads((ROOT/'module-results.json').read_text());self.assertEqual(len(rows),150)
        for row in rows:
            self.assertEqual(row['status'],'module_inventory_preserved')
            for f in row['metadata']:
                for k in ['public_metadata','private_metadata']:self.assertTrue(f[k]['payload_bytes_equal'])
if __name__=='__main__':unittest.main()
