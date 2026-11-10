import copy
import hashlib
import json
import struct
import unittest
from shader_inventory_device_firstuse_review import review


class FirstUseTests(unittest.TestCase):
    def setUp(self):
        self.m={'nonce':'freshnonce','nonce_value':123,'allowed_cases':['tile'],'cases':{'tile':{'file':'tile.metallib','route':'library_bytes'}},'asset_sha256':{'tile.metallib':'hash'},'names':{'tile':'tile_freshnonce'}};self.mb=json.dumps(self.m).encode();pixels=b''.join(struct.pack('<I',123^((i*0x045d9f3b)&0xffffffff)) for i in range(256))
        self.e={'pipeline_created':True,'dispatch_api':'dispatchThreadsPerTile','tile_dispatch_encoded':True,'dispatch_completed':True,'width':16,'height':16,'pixel_format':'RGBA8Unorm','pixels_checked':256,'bytes_checked':1024,'actual_sha256':hashlib.sha256(pixels).hexdigest(),'mismatched_bytes':0,'clear_sentinel_pixels':0}
        self.r={'selected_case':'tile','manifest_sha256':hashlib.sha256(self.mb).hexdigest(),'nonce':'freshnonce','status':'complete_results_require_review','shipped_kernels_dispatched':False,'conversion_route':'unknown_requires_host_receipts','result':{'id':'tile','library_route':'library_bytes','asset_hash_matches':True,'input_sha256':'hash','library_loaded':True,'function_names':['tile_freshnonce'],'results':[{'key':'tile','mode':0,'name':'tile_freshnonce','function_type':3,'function_created':True,'tile_execution':self.e}]}}
    def test_exact_tile_remains_conversion_unknown(self):
        r=review(self.mb,self.r);self.assertFalse(r['issues']);self.assertFalse(r['uncached_conversion_proven'])
    def test_clear_only_cannot_pass(self):
        self.e.update(actual_sha256=hashlib.sha256(bytes([255,0,255,255])*256).hexdigest(),clear_sentinel_pixels=256);self.assertTrue(review(self.mb,self.r)['issues'])
    def test_pipeline_only_cannot_pass(self):
        self.e.pop('tile_dispatch_encoded');self.assertTrue(review(self.mb,self.r)['issues'])
    def test_wrong_pixels_rejected(self):
        self.e['actual_sha256']='0'*64;self.assertTrue(review(self.mb,self.r)['issues'])
    def test_missing_case_rejected(self):
        self.r['result']['results']=[];self.assertTrue(review(self.mb,self.r)['issues'])
    def test_nonce_mismatch_rejected(self):
        self.r['nonce']='oldnonce';self.assertTrue(review(self.mb,self.r)['issues'])
    def test_runtime_cannot_claim_uncached_conversion(self):
        self.r['conversion_route']='uncached_conversion_proven';self.assertTrue(review(self.mb,self.r)['issues'])


if __name__=='__main__':unittest.main()
