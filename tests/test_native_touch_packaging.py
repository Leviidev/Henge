"""Validate the archive path/ownership boundary used by the real packager."""
import importlib.util
from pathlib import Path
import tarfile
import unittest
spec=importlib.util.spec_from_file_location('packaging',Path(__file__).resolve().parents[1]/'tools/package_native_touch.py')
packaging=importlib.util.module_from_spec(spec);spec.loader.exec_module(packaging)
class PackagingChecks(unittest.TestCase):
    def test_regular_signed_bundle_paths(self):
        for root in packaging.ROOTS:
            for suffix in ['/Contents/Info.plist','/Contents/MacOS/henge-touch-agent','/Contents/_CodeSignature/CodeResources']:
                packaging.validate_members([tarfile.TarInfo(root+suffix)])
    def test_reject_escape_other_bundle_and_links(self):
        for name in ['/tmp/escape','../escape','Henge Touch Agent.app/../../escape','Other.app/Contents/MacOS/other']:
            with self.subTest(name=name),self.assertRaises(ValueError):packaging.validate_members([tarfile.TarInfo(name)])
        for kind in [tarfile.SYMTYPE,tarfile.LNKTYPE,tarfile.CHRTYPE,tarfile.FIFOTYPE]:
            member=tarfile.TarInfo('Henge Touch Agent.app/Contents/link');member.type=kind
            with self.assertRaises(ValueError):packaging.validate_members([member])
if __name__=='__main__':unittest.main()
