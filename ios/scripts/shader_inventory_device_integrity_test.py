import copy
import hashlib
import json
from pathlib import Path
import struct
import unittest
import os
from shader_inventory_device_integrity_audit import frame_embedded_section
from shader_inventory_device_integrity_review import review


class IntegrityEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.root=Path(os.environ.get('HENGE_TEST_ARTIFACTS', '/nonexistent-henge-test-artifacts'))/'shader-inventory/inventory-integrity-03';p=self.root/'native-ci-results.json'
        if not p.exists():self.skipTest('retained integrity evidence absent')
        self.mb=(self.root/'device-kit/AuditAssets/integrity-jobs.json').read_bytes();self.manifest=json.loads(self.mb);self.native=json.loads(p.read_text());self.set_case('0df5b6')
    def set_case(self,prefix):
        j=next(j for j in self.manifest['jobs'] if j['source_sha256'].startswith(prefix));n=next(n for n in self.native if n['source_sha256']==j['source_sha256'] and n['label']=='converted');self.r={'manifest_sha256':hashlib.sha256(self.mb).hexdigest(),'status':'completed_requires_review','source_sha256':j['source_sha256'],'asset_hash_matches':True,'output_sha256':j['sha256'],'inspection':copy.deepcopy(n['report']),'shipped_full_library_execution_verified':False}
    def test_native_subset_keeps_hash_semantics_unresolved(self):
        r=review(self.mb,self.r);self.assertFalse(r['issues']);self.assertFalse(r['hash_semantics_resolved']);self.assertFalse(r['full_library_execution_verified']);self.assertEqual(r['integrity_mismatch_records_retained'],17)
    def test_pixel_tamper_rejected(self):
        self.r['inspection']['oracle_cases'][0]['actual_sha256']='0'*64;self.assertTrue(review(self.mb,self.r)['issues'])
    def test_missing_zero_scale_rejected(self):
        self.r['inspection']['oracle_cases'].pop();self.assertTrue(review(self.mb,self.r)['issues'])
    def test_name_inventory_loss_rejected(self):
        self.r['inspection']['ci_names'].pop();self.assertTrue(review(self.mb,self.r)['issues'])
    def test_unknown_constructor_failure_rejected(self):
        self.r['inspection']['constructor_samples'][0].update(resolved=False,error='unsupported');self.assertTrue(review(self.mb,self.r)['issues'])
    def test_original_abi_failure_explicitly_retained(self):
        self.set_case('823620');r=review(self.mb,self.r);self.assertFalse(r['issues']);self.assertEqual(r['constructor_rejections'][0]['name'],'__PQ_EOTF');self.assertEqual(r['constructor_rejections'][0]['classification'],'same_original_CI_ABI_rejection')
    def test_full_library_claim_rejected(self):
        self.r['shipped_full_library_execution_verified']=True;self.assertTrue(review(self.mb,self.r)['issues'])
    def test_embedded_bounded_framing(self):
        data=next(self.root.glob('embedded-metallib-section-*.bin')).read_bytes();records=frame_embedded_section(data);self.assertEqual(len(records),321);self.assertEqual(sum(r['air_region_count'] for r in records),0)
    def test_embedded_oversized_record_rejected(self):
        data=bytearray(next(self.root.glob('embedded-metallib-section-*.bin')).read_bytes());struct.pack_into('<Q',data,16,len(data)+1)
        with self.assertRaisesRegex(ValueError,'exceeds enclosing'):frame_embedded_section(data)
    def test_embedded_nonzero_padding_rejected(self):
        data=bytearray(next(self.root.glob('embedded-metallib-section-*.bin')).read_bytes());r=next(r for r in frame_embedded_section(data) if r['alignment_padding_bytes']);data[r['section_offset']+r['byte_size']]=1
        with self.assertRaisesRegex(ValueError,'nonzero alignment'):frame_embedded_section(data)


if __name__=='__main__':unittest.main()
