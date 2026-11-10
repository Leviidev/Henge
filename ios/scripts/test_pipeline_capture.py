import base64
import hashlib
import json
import struct
import unittest

from collect_pipeline_audit import validate_capture


def fixture(source):
    blob=struct.pack('<4I',0xe,20,7,4)+b'data'
    refs={'12':{'library_identity':source,'name':'shader','function_type':2}}
    bindings=json.dumps(refs,sort_keys=True,separators=(',',':')).encode()
    blob_hash=hashlib.sha256(blob).hexdigest()
    identity=hashlib.sha256((blob_hash+'\n').encode()+bindings).hexdigest()
    return blob,{'schema':2,'sha256':identity,'blob_sha256':blob_hash,'byte_size':len(blob),
        'tag':0xe,'function_refs':refs,'bindings_data_base64':base64.b64encode(bindings).decode()}


class PipelineCaptureTests(unittest.TestCase):
    def test_reused_numeric_refs_with_different_shaders_remain_distinct(self):
        a,one=fixture('a'*64);b,two=fixture('b'*64)
        self.assertEqual(a,b)
        self.assertNotEqual(one['sha256'],two['sha256'])
        validate_capture(a,one,one['sha256'])
        validate_capture(b,two,two['sha256'])

    def test_mutated_binding_is_rejected(self):
        blob,meta=fixture('a'*64)
        meta['function_refs']['12']['name']='different shader'
        with self.assertRaisesRegex(ValueError,'binding'):validate_capture(blob,meta,meta['sha256'])

    def test_mutated_blob_is_rejected(self):
        blob,meta=fixture('a'*64)
        with self.assertRaises(ValueError):validate_capture(blob[:-1]+b'X',meta,meta['sha256'])


if __name__=='__main__':unittest.main()
