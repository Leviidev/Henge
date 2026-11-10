"""Check that the offline audit cannot silently omit modules or declarations."""
import unittest

from audit_shader_conversion import eligible_modules, function_delta
from catalog_metallibs import inspect_metallib
from test_catalog_metallibs import fixture


class ConversionAuditTests(unittest.TestCase):
    def test_all_modules_preserved_even_with_identical_content(self):
        record = inspect_metallib(fixture())
        modules = eligible_modules(record)
        self.assertEqual(len(modules), 2)
        self.assertEqual(modules[0]['sha256'], modules[1]['sha256'])
        self.assertNotEqual(modules[0]['offset'], modules[1]['offset'])

    def test_shared_module_accounted_once(self):
        self.assertEqual(len(eligible_modules(inspect_metallib(fixture(shared=True)))), 1)

    def test_unaccounted_payload_rejected(self):
        with self.assertRaisesRegex(ValueError, 'unaccounted'):
            eligible_modules(inspect_metallib(fixture(extra=b'other module')))

    def test_missing_and_changed_stage_detected(self):
        before = inspect_metallib(fixture())
        after = inspect_metallib(fixture((2,)))
        delta = function_delta(before, after)
        self.assertEqual(len(delta['missing']), 2)
        self.assertEqual(delta['added'][0]['type_raw'], 2)

    def test_missing_module_mapping_rejected(self):
        record = inspect_metallib(fixture())
        record['air_regions'].pop()
        with self.assertRaisesRegex(ValueError, 'not all function records'):
            eligible_modules(record)


if __name__ == '__main__':
    unittest.main()
