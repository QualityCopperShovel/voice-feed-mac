import plistlib
import struct
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class AppIconTests(unittest.TestCase):
    def test_bundle_icon_contains_standard_and_retina_png_representations(self):
        metadata = plistlib.loads((ROOT / 'Info.plist').read_bytes())
        icon = metadata['CFBundleIconFile']
        data = (ROOT / 'Resources' / icon).read_bytes()
        self.assertEqual(data[:4], b'icns')
        self.assertEqual(struct.unpack('>I', data[4:8])[0], len(data))
        offset = 8
        sizes = {}
        while offset < len(data):
            kind = data[offset:offset + 4]
            length = struct.unpack('>I', data[offset + 4:offset + 8])[0]
            self.assertGreater(length, 32)
            payload = data[offset + 8:offset + length]
            self.assertEqual(payload[:8], b'\x89PNG\r\n\x1a\n')
            width, height = struct.unpack('>II', payload[16:24])
            self.assertEqual(width, height)
            sizes[kind] = width
            offset += length
        self.assertEqual(offset, len(data))
        self.assertEqual(sizes, {b'icp4': 16, b'icp5': 32, b'icp6': 64,
            b'ic07': 128, b'ic08': 256, b'ic09': 512, b'ic10': 1024,
            b'ic11': 32, b'ic12': 64, b'ic13': 256, b'ic14': 512})
        for recipe in ['install.sh', 'release.sh', '.github/workflows/build-release.yml']:
            text = (ROOT / recipe).read_text()
            self.assertIn('Resources/' + icon, text, recipe)
            self.assertIn('Contents/Resources/' + icon, text, recipe)


if __name__ == '__main__':
    unittest.main()
