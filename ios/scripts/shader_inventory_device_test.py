import copy
import hashlib
import json
from pathlib import Path
import struct
import tempfile
import unittest

from shader_inventory_device_review import review
from shader_inventory_device_verify import verify


class ReviewTests(unittest.TestCase):
    def setUp(self):
        self.manifest=json.dumps({'allowed_stages':['controls','libraries','pipelines'],'jobs':[]}).encode()
        self.report={'manifest_sha256':hashlib.sha256(self.manifest).hexdigest(),'status':'complete_results_require_review','shipped_kernels_dispatched':False,'stage':'controls'}
        cases=[]
        def execution(values):return {'dispatch_completed':True,'elements_checked':256,'mismatches':0,'actual_sha256':hashlib.sha256(b''.join(struct.pack('<I',v) for v in values)).hexdigest()}
        for name,base in [('alpha',1000),('beta',2000)]:
            for mode in (0,1):cases.append({'name':name,'mode':mode,'function_created':True,'pipeline_created':True,'execution':execution(base+100*mode+i for i in range(256))})
        self.report['packed_control']={'asset_hash_matches':True,'library_loaded':True,'cases':cases}
        self.report['dynamic_control']={key:True for key in ('asset_hash_matches','supports_dynamic_libraries','library_loaded','dynamic_created','consumer_library_created','consumer_function_created','consumer_pipeline_created')}
        self.report['dynamic_control']['execution']=execution(i*7+19 for i in range(256))
    def test_exact_controls_pass(self):self.assertEqual(review(self.manifest,self.report)['status'],'authored_controls_exact')
    def test_claimed_success_cannot_hide_wrong_readback(self):
        self.report['packed_control']['cases'][0]['execution']['actual_sha256']='0'*64
        self.assertTrue(review(self.manifest,self.report)['issues'])
    def test_load_is_not_dynamic_link_success(self):
        del self.report['dynamic_control']['consumer_pipeline_created']
        self.assertTrue(review(self.manifest,self.report)['issues'])
    def test_missing_specialization_rejected(self):
        self.report['packed_control']['cases'].pop()
        self.assertTrue(review(self.manifest,self.report)['issues'])
    def test_wrong_manifest_rejected(self):
        self.report['manifest_sha256']='0'*64
        self.assertTrue(review(self.manifest,self.report)['issues'])
    def test_false_capability_is_unsupported_not_dynamic_success(self):
        self.report['dynamic_control']={'asset_hash_matches':True,'supports_dynamic_libraries':False}
        result=review(self.manifest,self.report)
        self.assertFalse(result['issues']);self.assertEqual(result['status'],'authored_packed_control_exact_dynamic_unsupported');self.assertTrue(result['open_checks'])
    def test_explicit_unadvertised_success_does_not_upgrade_capability(self):
        self.report['dynamic_control']['supports_dynamic_libraries']=False
        self.report['dynamic_control']['attempt_unadvertised_dynamic']=True
        result=review(self.manifest,self.report)
        self.assertFalse(result['issues']);self.assertEqual(result['status'],'authored_controls_exact_unadvertised_dynamic');self.assertTrue(result['open_checks'])
    def test_explicit_unadvertised_rejection_stays_separate(self):
        self.report['dynamic_control']={'asset_hash_matches':True,'supports_dynamic_libraries':False,'attempt_unadvertised_dynamic':True,'dynamic_created':False,'dynamic_error':'Unsupported API'}
        result=review(self.manifest,self.report)
        self.assertTrue(result['issues']);self.assertEqual(result['status'],'unadvertised_dynamic_attempt_rejected_or_failed')
    def test_library_load_pass_keeps_execution_open(self):
        manifest=json.dumps({'allowed_stages':['controls','libraries','pipelines'],'jobs':[{'id':'abc','sha256':'def','source_sha256':'123','library_type':0,'expected_functions':[{'name':'kernel','type_raw':2}],'pipeline_samples':[]}]}).encode()
        report={'manifest_sha256':hashlib.sha256(manifest).hexdigest(),'status':'complete_results_require_review','shipped_kernels_dispatched':False,'stage':'libraries','selection':'abc','jobs':[{'id':'abc','sha256':'def','source_sha256':'123','asset_hash_matches':True,'library_loaded':True,'actual_library_type':0,'actual_function_names':['kernel'],'execution_status':'not_tested_no_argument_contract','pixel_verified':False}]}
        result=review(manifest,report)
        self.assertFalse(result['issues']);self.assertTrue(result['open_checks']);self.assertFalse(result['shipped_execution_verified'])
        report['jobs'][0]['pixel_verified']=True
        self.assertTrue(review(manifest,report)['issues'])

    def test_packaged_auditassets_checked_and_stale_resources_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);app=root/'Helper.app';assets=app/'AuditAssets';assets.mkdir(parents=True)
            payload=b'asset bytes';manifest=json.dumps({'jobs':[{'file':'test.metallib','sha256':hashlib.sha256(payload).hexdigest()}],'controls':{}}).encode()
            source=root/'manifest.json';source.write_bytes(manifest);(assets/'inventory-jobs.json').write_bytes(manifest);(assets/'test.metallib').write_bytes(payload)
            self.assertEqual(verify(app,source)['assets_checked'],1)
            (app/'Resources').mkdir()
            with self.assertRaisesRegex(ValueError,'Stale top-level Resources'):verify(app,source)

    def test_packaged_asset_change_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);app=root/'Helper.app';assets=app/'AuditAssets';assets.mkdir(parents=True)
            manifest=json.dumps({'jobs':[{'file':'test.metallib','sha256':'0'*64}],'controls':{}}).encode()
            source=root/'manifest.json';source.write_bytes(manifest);(assets/'inventory-jobs.json').write_bytes(manifest);(assets/'test.metallib').write_bytes(b'changed')
            with self.assertRaisesRegex(ValueError,'Asset changed'):verify(app,source)


if __name__=='__main__':unittest.main()
