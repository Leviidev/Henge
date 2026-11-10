import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import struct
import tempfile
import unittest
import zipfile

spec=importlib.util.spec_from_file_location('ipad_update',Path(__file__).with_name('ipad_update.py'))
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)

def binary(code=b'12345678',signature=b'oldsign!'):
    header=struct.pack('<8I',0xfeedfacf,0x100000c,0,2,2,88,0,0)
    segment=struct.pack('<II16sQQQQIIII',0x19,72,b'__LINKEDIT',0,4096,128,len(signature),0,0,0,0)
    cs=struct.pack('<4I',0x1d,16,128,len(signature))
    return header+segment+cs+code+signature

class Tests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup);self.root=Path(self.tmp.name)
    def package(self,name='candidate.tipa',bundle='org.example.henge'):
        p=self.root/name
        with zipfile.ZipFile(p,'w')as z:
            z.writestr('Payload/Henge.app/Info.plist',plistlib.dumps({'CFBundleIdentifier':bundle,'CFBundleExecutable':'Henge'}))
            z.writestr('Payload/Henge.app/Henge',binary())
        return p
    def test_signature_changes_preserve_code_identity(self):
        self.assertEqual(m.normalized_macho(binary()),m.normalized_macho(binary(signature=b'longer-new-signature')))
        self.assertNotEqual(m.normalized_macho(binary()),m.normalized_macho(binary(code=b'changed!')))
    def test_archive_traversal_rejected_before_any_transport(self):
        p=self.package()
        with zipfile.ZipFile(p,'a')as z:z.writestr('../escape',b'x')
        with self.assertRaisesRegex(ValueError,'Unsafe'):m.package_identity(p)
    def setup_update(self,stale=False,wrong_aux=False,changed_disk=False):
        package=self.package();rollback=self.package('old.tipa');plan=self.root/'plan';plan.mkdir()
        config={'host':'root@operator-ipad','bundle_id':'org.example.henge'}
        state={'bundle_id':config['bundle_id'],'model':'test','os':'17.0','os_build':'test','data_container':'/data','machine_directory':'/data/machine','storage':{'auxiliary.bin':{'sha256':hashlib.sha256(b'aux').hexdigest()},'disk.img':{'inode':1}},'normalized_executable_sha256':m.normalized_macho(binary())}
        (plan/'target.json').write_text(json.dumps(config));(plan/'preflight.json').write_text(json.dumps(state));calls=[]
        class Remote:
            installed=False
            def __init__(self,c):pass
            def state(self,c):
                result=copy.deepcopy(state)
                if stale or(changed_disk and self.installed):result['storage']['disk.img']['inode']=2
                return result
            def read(self,p):return b'wrong'if wrong_aux else b'aux'
            def upload(self,*a):calls.append('upload')
            def install(self,*a):calls.append('install');self.installed=True;return {'installer_exit':0}
        return plan,package,rollback,self.root/'receipt',Remote,calls
    def test_stale_preflight_never_uploads_or_installs(self):
        args=self.setup_update(stale=True)
        with self.assertRaisesRegex(ValueError,'changed'):m.update(*args[:-1])
        self.assertEqual(args[-1],[])
    def test_aux_backup_mismatch_never_uploads_or_installs(self):
        args=self.setup_update(wrong_aux=True)
        with self.assertRaisesRegex(ValueError,'Auxiliary'):m.update(*args[:-1])
        self.assertEqual(args[-1],[])
    def test_success_separates_app_and_storage_receipts(self):
        args=self.setup_update();m.update(*args[:-1]);self.assertEqual(args[-1],['upload','install'])
        self.assertTrue(json.loads((args[3]/'data-preservation.json').read_text())['unchanged'])
        self.assertTrue((args[3]/'rollback.tipa').is_file())
    def test_disk_identity_change_is_not_silently_repaired(self):
        args=self.setup_update(changed_disk=True)
        with self.assertRaisesRegex(RuntimeError,'Storage'):m.update(*args[:-1])
        self.assertFalse(json.loads((args[3]/'data-preservation.json').read_text())['unchanged'])
    def test_remote_program_compiles_without_execution(self):
        compile(m.REMOTE_STATE.replace('CONFIG',repr({})),'remote','exec')
if __name__=='__main__':unittest.main()
