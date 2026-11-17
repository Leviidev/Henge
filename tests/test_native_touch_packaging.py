#!/usr/bin/env python3
"""Check the authorization boundaries before a helper claims a restricted entitlement."""
import copy
import datetime
import importlib.util
from pathlib import Path
import unittest
import sys
sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location('packaging', Path(__file__).resolve().parents[1] / 'tools/package_native_touch.py')
packaging = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packaging)


class ProfileTests(unittest.TestCase):
    def setUp(self):
        self.profile = {
            'Platform': ['OSX'], 'ProvisionsAllDevices': True,
            'ExpirationDate': datetime.datetime.now() + datetime.timedelta(days=1),
            'TeamIdentifier': ['TEAM'], 'ApplicationIdentifierPrefix': ['PREFIX'],
            'DeveloperCertificates': [b'test certificate'],
            'Entitlements': {
                packaging.HID: True,
                packaging.APP_ID: 'PREFIX.dev.henge.touch-agent',
                packaging.TEAM_ID: 'TEAM',
                'unrelated-entitlement': True,
            },
        }

    def validate(self, **options):
        return packaging.profile_entitlements(self.profile, 'dev.henge.touch-agent', **options)

    def test_only_claim_authorized_required_entitlements(self):
        claims = self.validate()
        self.assertEqual(set(claims), {packaging.HID, packaging.APP_ID, packaging.TEAM_ID})
        self.assertEqual(claims[packaging.APP_ID], 'PREFIX.dev.henge.touch-agent')

    def test_reject_invalid_profiles(self):
        original = copy.deepcopy(self.profile)
        mutations = [
            lambda p: p.update(Platform=['iOS']),
            lambda p: p.update(ExpirationDate=datetime.datetime.now() - datetime.timedelta(seconds=1)),
            lambda p: p.pop('ExpirationDate'),
            lambda p: p.update(ProvisionsAllDevices=False, ProvisionedDevices=['test-mac']),
            lambda p: p['Entitlements'].update({packaging.APP_ID: 'PREFIX.other.app'}),
            lambda p: p['Entitlements'].update({packaging.APP_ID: 'PREFIX.*'}),
            lambda p: p['Entitlements'].update({packaging.TEAM_ID: 'OTHER'}),
            lambda p: p['Entitlements'].update({packaging.HID: False}),
            lambda p: p.update(DeveloperCertificates=[]),
        ]
        for mutate in mutations:
            with self.subTest(mutate=mutate):
                self.profile = copy.deepcopy(original)
                mutate(self.profile)
                with self.assertRaises(ValueError):
                    self.validate()

    def test_development_requires_explicit_opt_in_and_registered_devices(self):
        self.profile.pop('ProvisionsAllDevices')
        self.profile['ProvisionedDevices'] = ['test-mac']
        with self.assertRaises(ValueError):
            self.validate()
        self.assertTrue(self.validate(development=True)[packaging.HID])
        self.profile['ProvisionedDevices'] = []
        with self.assertRaises(ValueError):
            self.validate(development=True)


if __name__ == '__main__':
    unittest.main()
