import plistlib
import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class UpdateContractTests(unittest.TestCase):
    def test_notarized_archive_replaces_script_updater(self):
        source = (ROOT / 'Sources/VoiceFeedMac/main.swift').read_text()
        self.assertIn('let download_url: String', source)
        self.assertIn('let download_sha256: String', source)
        self.assertIn('guard manifest.notarized', source)
        self.assertIn('SHA256.hash(data: payload)', source)
        self.assertIn('"/usr/bin/codesign"', source)
        self.assertIn('"/usr/sbin/spctl"', source)
        self.assertIn('manager.moveItem(at: backup, to: target)', source)
        self.assertNotIn('installer_url', source)
        self.assertNotIn('VOICE_FEED_AUTO_UPDATE', source)

    def test_application_bootstraps_appkit(self):
        source = (ROOT / 'Sources/VoiceFeedMac/main.swift').read_text()
        bootstrap = source[source.rfind('let app = NSApplication.shared'):]
        self.assertIn('let delegate = AppDelegate()', bootstrap)
        self.assertIn('app.delegate = delegate', bootstrap)
        self.assertIn('app.setActivationPolicy(.accessory)', bootstrap)
        self.assertIn('app.run()', bootstrap)
        workflow = (ROOT / '.github/workflows/build-release.yml').read_text()
        self.assertIn('python3 tests/check_launch.py "$binary"', workflow)

    def test_app_registers_itself_as_login_item_on_every_launch(self):
        source = (ROOT / 'Sources/VoiceFeedMac/main.swift').read_text()
        self.assertIn('import ServiceManagement', source)
        launch = source[source.find('func applicationDidFinishLaunching'):source.find('func showFirstRunGuide')]
        self.assertIn('ensureLoginItem()', launch)
        self.assertIn('if service.status != .enabled {', source)
        self.assertIn('try service.register()', source)
        self.assertIn('if service.status == .enabled { removeLegacyLaunchAgent() }', source)
        self.assertIn('SMAppService.openSystemSettingsLoginItems()', source)
        self.assertIn('"Open at login is off — click to enable"', source)
        self.assertIn('Library/LaunchAgents/com.aisloppy.voice-feed.plist', source)
        installer = (ROOT / 'install.sh').read_text()
        self.assertNotIn('RunAtLoad', installer)
        self.assertIn('launchctl bootout', installer)

    def test_bundle_and_runtime_versions_match(self):
        with (ROOT / 'Info.plist').open('rb') as metadata:
            version = plistlib.load(metadata)['CFBundleShortVersionString']
        source = (ROOT / 'Sources/VoiceFeedMac/main.swift').read_text()
        runtime = re.search(r'let clientVersion = "([^" ]+)"', source).group(1)
        self.assertEqual(version, runtime)

    def test_continuous_capture_is_bounded_and_drains_before_stop(self):
        source = (ROOT / 'Sources/VoiceFeedMac/LiveCapture.swift').read_text()
        main = (ROOT / 'Sources/VoiceFeedMac/main.swift').read_text()
        self.assertIn('AVAudioEngine()', source)
        # Real PCM conversion across formats is exercised by MicrophoneRecoveryTests.
        self.assertIn('let converter = MicrophoneConverter()', source)
        self.assertIn('format:nil', source)
        self.assertIn('packets.count >= 100', source)
        self.assertIn('timeIntervalSince(sendStarted)>10', source)
        self.assertIn('timeIntervalSince(drainStarted)>25', source)
        self.assertIn('timeIntervalSince(pingStarted)>10', source)
        self.assertIn('event=["type":"stop"]', source)
        self.assertIn('if !packets.isEmpty', source)
        self.assertNotIn('AVAudioRecorder', main)
        self.assertNotIn('maximumWindowSeconds', main)
        self.assertIn('Finishing last words', main)
        self.assertIn('onComplete:', main)

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
