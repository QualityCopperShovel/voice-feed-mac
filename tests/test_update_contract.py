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

    def test_release_workflow_signs_notarizes_and_publishes(self):
        workflow = (ROOT / '.github/workflows/build-release.yml').read_text()
        self.assertIn('name: Build signed and notarized macOS release', workflow)
        self.assertIn('APPLE_DEVELOPER_ID_P12_BASE64:', workflow)
        self.assertIn('codesign --force --deep --options runtime --timestamp', workflow)
        self.assertIn('run_with_timeout.py 1000 xcrun notarytool submit', workflow)
        self.assertIn('run_with_timeout.py 180 xcrun stapler staple', workflow)
        self.assertIn('run_with_timeout.py 180 spctl --assess', workflow)
        self.assertIn('name: voice-feed-signed-notarized', workflow)
        self.assertIn('run_with_timeout.py 60 gh release create', workflow)
        self.assertNotIn('Voice-Feed-unsigned.zip', workflow)


if __name__ == '__main__':
    unittest.main()
