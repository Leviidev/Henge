import copy
import hashlib
import json
import unittest

from shader_inventory_device_review import review
import shader_inventory_device_test as base_tests


class PathReviewTests(unittest.TestCase):
    def setUp(self):
        base=base_tests.ReviewTests();base.setUp();self.report=copy.deepcopy(base.report);self.report['jobs']=[]
        specs=[{'id':ident,'kind':kind,'gate':gate} for ident,kind,gate in [('relative_source_baseline','relative_source','diagnostic_preserve_failure_or_success'),('loader_file_consumer','loader_file','native_qualified_oracle'),('absolute_serialized_source_consumer','absolute_source','native_qualified_oracle'),('undefined_allowed_preloaded_only','preloaded_only','native_qualified_oracle')]]
        manifest={'control_route':'path_resolution_matrix_v4','allowed_stages':['controls'],'jobs':[],'asset_sha256':{'asset.metallib':'sha'},'controls':{'dynamic':{'cases':specs}}}
        self.manifest=json.dumps(manifest).encode();self.report['manifest_sha256']=hashlib.sha256(self.manifest).hexdigest();self.report['asset_verification']={'asset.metallib':True}
        rows=[]
        for spec in specs:
            row=copy.deepcopy(base.report['dynamic_control']);row.update(spec);row.update(shared_origin='file_url',consumer_origin='runtime_source',preloaded_library_count=1,dynamic_status='authored_readback_exact',compile_library_count=1)
            if spec['kind']=='loader_file':row.update(consumer_origin='file_url',install_name='@loader_path/dynamic-loader.metallib',preloaded_library_count=0)
            if spec['kind']=='absolute_source':row.update(shared_origin='runtime_source',serialized=True,serialized_sha256='a'*64,install_name='/run/dynamic.metallib',requested_install_name='/run/dynamic.metallib',preloaded_library_count=0)
            if spec['kind']=='preloaded_only':row.update(compile_library_count=0,allow_undefined_symbols=True)
            rows.append(row)
        self.report['dynamic_control']={'control_route':'path_resolution_matrix_v4','supports_dynamic_libraries':True,'cases':rows}
    def result(self):return review(self.manifest,self.report)
    def fail_pipeline(self,index):
        row=self.report['dynamic_control']['cases'][index];row.update(consumer_pipeline_created=False,dynamic_status='consumer_pipeline_rejected',pipeline_error='MTLDynamicLibraryDomain Code=3: <no URL>');row.pop('execution')
    def test_matrix_success(self):self.assertEqual(self.result()['status'],'all_authored_path_oracles_exact')
    def test_baseline_failure_is_explicit_observation(self):
        self.fail_pipeline(0);result=self.result();self.assertFalse(result['issues']);self.assertEqual(result['status'],'qualified_paths_exact_with_observed_baseline_failure');self.assertEqual(len(result['observed_failures']),1);self.assertIn('<no URL>',result['observed_failures'][0]['evidence']['pipeline_error'])
    def test_positive_path_failure_cannot_hide(self):
        self.fail_pipeline(1);result=self.result();self.assertTrue(result['issues']);self.assertEqual(result['status'],'failed_or_incomplete');self.assertEqual(len(result['observed_failures']),1)
    def test_baseline_wrong_execution_cannot_hide(self):
        self.report['dynamic_control']['cases'][0]['execution']['actual_sha256']='0'*64;self.assertTrue(self.result()['issues'])
    def test_baseline_early_failure_cannot_hide(self):
        self.fail_pipeline(0);self.report['dynamic_control']['cases'][0]['dynamic_created']=False;self.assertTrue(self.result()['issues'])
    def test_missing_case(self):
        self.report['dynamic_control']['cases'].pop();self.assertTrue(self.result()['issues'])
    def test_duplicate_case(self):
        self.report['dynamic_control']['cases'].append(copy.deepcopy(self.report['dynamic_control']['cases'][0]));self.assertTrue(self.result()['issues'])
    def test_wrong_route(self):
        self.report['dynamic_control']['cases'][1]['consumer_origin']='runtime_source';self.assertTrue(self.result()['issues'])
    def test_missing_asset_verification(self):
        self.report['asset_verification']={};self.assertTrue(self.result()['issues'])
    def test_unsupported_remains_gap(self):
        self.report['dynamic_control'].update(supports_dynamic_libraries=False,cases=[],dynamic_status='not_attempted_advertised_unsupported');result=self.result();self.assertFalse(result['issues']);self.assertEqual(result['status'],'packed_exact_dynamic_unsupported')
    def test_unadvertised_attempt_remains_explicit(self):
        self.report['dynamic_control'].update(supports_dynamic_libraries=False,attempt_unadvertised_dynamic=True);result=self.result();self.assertFalse(result['issues']);self.assertEqual(result['status'],'unadvertised_all_authored_path_oracles_exact')
    def test_old_url_shape_not_accepted_as_matrix(self):
        base=base_tests.ReviewTests();base.setUp();self.report['dynamic_control']=base.report['dynamic_control'];self.assertTrue(self.result()['issues'])


if __name__=='__main__':unittest.main()
