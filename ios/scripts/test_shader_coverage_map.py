"""Evidence must follow exact library identities, not coincidentally equal names."""
import copy
import json
import hashlib
from pathlib import Path
import tempfile
import unittest

from build_shader_coverage_map import build, device_evidence, render_evidence
from catalog_metallibs import inspect_metallib
from test_catalog_metallibs import fixture


class CoverageMapTests(unittest.TestCase):
    def test_render_pass_requires_exact_complete_bindings(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);manifest=root/'manifest.json';report=root/'report.json'
            refs={ref:{'library_identity':'source:converted','name':'fragment'} for ref in ['1','2']}
            manifest.write_text(json.dumps({'jobs':[{'source_sha256':'source','sha256':'output'}],
                'render_cases':[{'sha256':'case','function_refs':refs}]}))
            value={'status':'complete','manifest_sha256':hashlib.sha256(manifest.read_bytes()).hexdigest(),
                'render_cases':[{'sha256':'case','status':'pipeline_created','bindings':[
                    {'ref':ref,'source_sha256':'source','name':'fragment','output_sha256':'output'} for ref in refs]}]}
            def save():report.write_text(json.dumps(value))
            save()
            self.assertEqual(render_evidence(report,manifest)[1][('source','fragment')],['case'])
            value['render_cases'][0]['bindings'][0]['output_sha256']='wrong';save()
            with self.assertRaisesRegex(ValueError,'shader identity'):render_evidence(report,manifest)
            value['render_cases'][0]['bindings'][0]['output_sha256']='output'
            value['render_cases'][0]['bindings'].pop();save()
            with self.assertRaisesRegex(ValueError,'Incomplete'):render_evidence(report,manifest)
            value['manifest_sha256']='wrong';save()
            with self.assertRaisesRegex(ValueError,'stale'):render_evidence(report,manifest)

    def test_device_results_require_matching_manifest_and_shader_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);manifest=root/'manifest.json';report=root/'report.json'
            manifest.write_text(json.dumps({'jobs':[{'source_sha256':'source','sha256':'bytes',
                'functions':[{'name':'kernel','type_raw':2}]}]}))
            value={'status':'complete','manifest_sha256':hashlib.sha256(manifest.read_bytes()).hexdigest(),
                'results':[{'source_sha256':'source','sha256':'bytes',
                    'functions':[{'name':'kernel','declared_type':2,'status':'function_created'}]}]}
            report.write_text(json.dumps(value))
            self.assertEqual(len(device_evidence(report,manifest)[1]),1)
            value['results'][0]['sha256']='different bytes';report.write_text(json.dumps(value))
            with self.assertRaisesRegex(ValueError,'shader bytes'):device_evidence(report,manifest)
            value['manifest_sha256']='stale manifest';report.write_text(json.dumps(value))
            with self.assertRaisesRegex(ValueError,'another manifest'):device_evidence(report,manifest)

    def test_names_and_cache_do_not_imply_execution_or_pixels(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / 'inventory'
            def write(path, value):
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(json.dumps(value))
            shipped = inspect_metallib(fixture((2,)))
            shipped['source_paths'] = ['shipped.metallib']
            captured = copy.deepcopy(shipped)
            captured['sha256'] = 'b' * 64
            captured['source_paths'] = ['captured.metallib']
            write(root/'shipped/catalog.json', {'libraries': [shipped], 'summary': {'format_counts': {'metallib': 1}}})
            write(root/'shipped/shipped-libraries.json', {'os': 'test', 'device': 'test', 'files': ['shipped'],
                  'libraries': [{'sha256': shipped['sha256'], 'paths': ['shipped'], 'function_names': ['function_0']}]})
            write(root/'runtime-current/catalog.json', {'libraries': [captured]})
            write(root/'device-conversions.json', {'libraries': [{'source_sha256': captured['sha256']}]})
            (root/'shipped/shader-search-errors.txt').write_text('permission denied\n')
            (root/'current-runtime.log').write_text(f"compute completed function=function_0 library={captured['sha256']}:0\n")
            for name in ('comparison', 'repeatability'):
                write(root.parent/f'image-effects-audit/guest-final/{name}.json',
                      {'reference_os': 'test', 'candidate_os': 'test', 'results': [{'status': 'match'}]})
            result = build(root)
            first, second = result['entries']
            self.assertEqual(first['compute_observed'], [])
            self.assertEqual(second['compute_observed'], ['completed'])
            self.assertEqual(second['same_name_shipped_candidates'], [shipped['sha256']])
            self.assertFalse(first['pixel_verified'])
            self.assertFalse(second['pixel_verified'])
            self.assertEqual(result['summary']['exact_container_overlap'], 0)
            self.assertEqual(result['verification']['image_effects']['cases'], 1)


if __name__ == '__main__':
    unittest.main()
