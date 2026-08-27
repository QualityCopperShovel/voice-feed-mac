import plistlib
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class UpdateContractTests(unittest.TestCase):
    def test_notarized_archive_replaces_script_updater(self):
        source = (ROOT / 'Sources/VoiceFeedMac/main.swift').read_text()
        self.assertIn('let clientVersion = "1.3.10"', source)
        self.assertIn('let download_url: String', source)
        self.assertIn('let download_sha256: String', source)
        self.assertIn('guard manifest.notarized', source)
        self.assertIn('SHA256.hash(data: payload)', source)
        self.assertIn('"/usr/bin/codesign"', source)
        self.assertIn('"/usr/sbin/spctl"', source)
        self.assertIn('manager.moveItem(at: backup, to: target)', source)
        self.assertNotIn('installer_url', source)
        self.assertNotIn('VOICE_FEED_AUTO_UPDATE', source)

    def test_bundle_and_runtime_versions_match(self):
        with (ROOT / 'Info.plist').open('rb') as metadata:
            self.assertEqual(plistlib.load(metadata)['CFBundleShortVersionString'], '1.3.10')

    def test_capture_windows_use_sustained_average_power_and_bounded_chunks(self):
        source = (ROOT / 'Sources/VoiceFeedMac/main.swift').read_text()
        self.assertIn('let speechStartSamples = 2', source)
        self.assertIn('let speechTailSeconds: TimeInterval = 0.9', source)
        self.assertIn('let maximumWindowSeconds: TimeInterval = 8', source)
        self.assertIn('averagePower(forChannel: 0)', source)
        self.assertIn('self.loudSamples >= speechStartSamples', source)
        self.assertNotIn('peakPower(forChannel: 0)', source)


if __name__ == '__main__':
    unittest.main()
