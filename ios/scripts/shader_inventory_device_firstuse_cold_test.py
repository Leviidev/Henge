"""Evidence-backed negative controls; skipped when retained fixture is absent."""
import base64
import hashlib
import json
from pathlib import Path
import shutil
import tempfile
import unittest
import os
from shader_inventory_device_firstuse_cold_audit import audit


class ColdEvidenceTests(unittest.TestCase):
    def setUp(self):
        workspace=Path(os.environ.get('HENGE_TEST_ARTIFACTS', '/nonexistent-henge-test-artifacts'));self.original=workspace/'shader-inventory/inventory-firstuse-04/6a0c8311bf36494a8eda760b9a3dd86d';results=workspace/'video-audit/results';prefix='guest-firstuse04-results-tile_7F82A5CE-493B-431B-A952-938655CE449B_'
        if not (self.original/'live-evidence/device-after-cold.json').exists():self.skipTest('retained cold fixture absent')
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup);self.root=Path(self.temp.name)/'kit';self.root.mkdir();self.live=self.root/'live-evidence';self.live.mkdir()
        for name in ['device-before.json','host-before.json','capture-start.json','device-after-cold.json','cold.log']:shutil.copyfile(self.original/'live-evidence'/name,self.live/name)
        for name in ['device-artifacts']:shutil.copytree(self.original/'live-evidence'/name,self.live/name)
        for name in ['NativeResources','guest-results']:shutil.copytree(self.original/name,self.root/name)
        self.tile=self.root/'tile-report.json';self.raw=self.root/'tile-readback.rgba8';shutil.copyfile(results/(prefix+'firstuse-report.json'),self.tile);shutil.copyfile(results/(prefix+'tile-readback.rgba8'),self.raw)
    def run_audit(self):return audit(self.root,self.tile,self.raw)
    def test_original_chain(self):self.assertEqual(self.run_audit()['issues'],[])
    def test_prior_cache_entry_invalidates_cold_claim(self):
        p=self.live/'host-before.json';j=json.loads(p.read_text());ident=json.loads((self.live/'device-after-cold.json').read_text())['source_ids'][0];j['files'].append({'path':'recipe/'+ident+'.metallib'});p.write_text(json.dumps(j));r=self.run_audit();self.assertTrue(any('existed before' in x for x in r['issues']))
    def test_internally_hashed_wrong_owner_rejected(self):
        p=next((self.live/'device-artifacts/shader-requests-v2').glob('*.json'));j=json.loads(p.read_text());j['owner']='00000000-0000-0000-0000-000000000000';data=json.dumps(j).encode();p.write_bytes(data);after=self.live/'device-after-cold.json';a=json.loads(after.read_text());f=next(f for f in a['files'] if f['path']==str(p.relative_to(self.live/'device-artifacts')));f.update(sha256=hashlib.sha256(data).hexdigest(),size=len(data),data_base64=base64.b64encode(data).decode());after.write_text(json.dumps(a));r=self.run_audit();self.assertTrue(any('owner mismatch' in x or 'request identity mismatch' in x for x in r['issues']))
    def test_raw_tile_tamper_rejected_despite_report_pass(self):
        raw=bytearray(self.raw.read_bytes());raw[0]^=1;self.raw.write_bytes(raw);r=self.run_audit();self.assertTrue(any('raw guest tile readback' in x for x in r['issues']))
    def test_missing_gpu_completed_event_rejected(self):
        p=self.live/'cold.log';s=p.read_text();s='\n'.join(l for l in s.split('\n') if 'compute completed function=basic_' not in l);p.write_text(s);after=self.live/'device-after-cold.json';a=json.loads(after.read_text());a['log']=s;after.write_text(json.dumps(a));r=self.run_audit();self.assertTrue(any('compute completed route missing' in x for x in r['issues']))


if __name__=='__main__':unittest.main()
