#!/usr/bin/env python3
import os
import hashlib,json,struct,unittest
from pathlib import Path
from shader_inventory_repair_expansion import target_for
from shader_inventory_repair_pack import pack
ROOT=Path(os.environ.get('HENGE_TEST_ARTIFACTS', '/nonexistent-henge-test-artifacts'))/'shader-inventory/inventory-expansion-02'

class ExpansionTests(unittest.TestCase):
    def test_supported_version_architecture_pairs(self):
        self.assertEqual(target_for((2,2)),'air64_v22-apple-ios13.0.0')
        self.assertEqual(target_for((2,5)),'air64_v25-apple-ios16.0.0')
        self.assertEqual(target_for((2,6)),'air64_v26-apple-ios17.0.0')
        with self.assertRaises(KeyError):target_for((2,9))
    @unittest.skipUnless(ROOT.exists(), 'optional retained evidence absent; set HENGE_TEST_ARTIFACTS')
    def test_legacy_profile_is_explicit(self):
        p=next(ROOT.glob('dcf*/legacy-macos-control/0000.metallib'))
        with self.assertRaisesRegex(ValueError,'explicit'):pack([p])
        blob,e=pack([p],allowed_format_versions=((2,4),))
        self.assertEqual(e['function_count'],1)
        with self.assertRaisesRegex(ValueError,'unreviewed'):pack([p],allowed_format_versions=((2,9),))
    @unittest.skipUnless(ROOT.exists(), 'optional retained evidence absent; set HENGE_TEST_ARTIFACTS')
    def test_version_repairs_preserve_metadata(self):
        rows=json.loads((ROOT/'matched-air-version-results.json').read_text());self.assertEqual(sum(len(r['modules'])for r in rows),271)
        for r in rows:
            self.assertEqual(r['status'],'matched_air_version_candidate_structurally_preserved')
            for m in r['modules']:
                for f in m['metadata']:
                    for k in ['public_metadata','private_metadata']:self.assertTrue(f[k]['payload_equal'])
    @unittest.skipUnless(ROOT.exists(), 'optional retained evidence absent; set HENGE_TEST_ARTIFACTS')
    def test_native_platform_failure_remains_visible(self):
        rows=json.loads((ROOT/'matched-air-version-native-reviews.json').read_text());vfx=next(x for x in rows if x['sha256'].startswith('049'));old=next(x for x in rows if x['sha256'].startswith('dcf'));self.assertTrue(vfx['native_inventory_equal']);self.assertFalse(old['both_loaded']);self.assertTrue(json.loads(next(ROOT.glob('dcf*/legacy-macos-control/result.json')).read_text())['native_metadata_equal_to_original'])
    @unittest.skipUnless(ROOT.exists(), 'optional retained evidence absent; set HENGE_TEST_ARTIFACTS')
    def test_radar_raw_oracle(self):
        folder=next(ROOT.glob('9056*'));mask=[0,.015625,.03125,1];alpha=[1,.5,.25,1];color=[.0625,.03125,0,.5];expected=[]
        for m,a in zip(mask,alpha):expected.extend([*color[:3],a*color[3]]if m>.02 else[0,0,0,0])
        raw=struct.pack('<16f',*expected)
        for role in ['source','candidate']:
            p=folder/(role+'-radar-oracle.json');r=json.loads(p.read_text());self.assertTrue(r['output_created']);self.assertEqual(p.with_suffix('.json.rgba32f').read_bytes(),raw);self.assertEqual(r['actual_sha256'],hashlib.sha256(raw).hexdigest())
if __name__=='__main__':unittest.main()
