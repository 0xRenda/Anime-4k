import contextlib
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import struct
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('verify_ipa', ROOT / 'tools/verify_ipa.py')
verify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify)
MANIFEST = json.loads((ROOT / 'vlc-ios-master/Resources/RoxyAnime4K/manifest.json').read_text())


def fixture(path, architecture=0x0100000C, families=None, omit_shader=False, signature=False):
    # Synthetic ZIP structure only: this is not an executable IPA and is never
    # delivered. It tests rejection paths without requiring Apple's compiler.
    app = 'Payload/Roxy Player.app/'
    with zipfile.ZipFile(path, 'w') as archive:
        archive.writestr(app + 'Info.plist', plistlib.dumps({'CFBundleDisplayName': 'Roxy Player',
                          'CFBundleExecutable': 'Roxy Player', 'UIDeviceFamily': families or [1, 2]}))
        archive.writestr(app + 'Roxy Player', b'\xcf\xfa\xed\xfe' + struct.pack('<I', architecture))
        archive.writestr(app + 'RoxyAnime4K/manifest.json', json.dumps(MANIFEST))
        shaders = MANIFEST['shaders'][:-1] if omit_shader else MANIFEST['shaders']
        for shader in shaders: archive.writestr(app + 'RoxyAnime4K/' + shader['name'] + '.metallib', b'MTLBfixture')
        if signature:
            archive.writestr(app + '_CodeSignature/CodeResources', b'fixture')
            archive.writestr(app + 'embedded.mobileprovision', b'fixture')


class PackagingTests(unittest.TestCase):
    def test_accepts_expected_structure(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'fixture-unsigned.ipa'
            fixture(path)
            with contextlib.redirect_stdout(io.StringIO()): verify.verify(path)

    def test_rejects_simulator_binary(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'fixture-unsigned.ipa'
            fixture(path, architecture=0x01000007)
            with self.assertRaisesRegex(ValueError, 'arm64'): verify.verify(path)

    def test_rejects_missing_shader(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'fixture-unsigned.ipa'
            fixture(path, omit_shader=True)
            with self.assertRaises(KeyError): verify.verify(path)

    def test_rejects_unsigned_file_labeled_signed(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'fixture-signed.ipa'
            fixture(path)
            with self.assertRaisesRegex(ValueError, 'signature'): verify.verify(path)

    def test_rejects_iphone_only_build(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'fixture-unsigned.ipa'
            fixture(path, families=[1])
            with self.assertRaisesRegex(ValueError, 'iPhone and iPad'): verify.verify(path)


if __name__ == '__main__': unittest.main()
