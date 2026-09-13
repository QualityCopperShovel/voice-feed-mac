import pathlib
import plistlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]

class AudioRecoveryContractTests(unittest.TestCase):
    def test_daemon_is_on_demand_and_embedded(self):
        with (ROOT / 'Resources/LaunchDaemons/com.aisloppy.voice-feed.audio-recovery.plist').open('rb') as source:
            config = plistlib.load(source)
        self.assertEqual(config['UserName'], 'root')
        self.assertEqual(config['BundleProgram'], 'Contents/Library/HelperTools/VoiceFeedAudioRecovery')
        self.assertEqual(config['MachServices'], {config['Label']: True})
        self.assertNotIn('RunAtLoad', config)
        self.assertNotIn('KeepAlive', config)
        self.assertNotIn('ProgramArguments', config)

    def test_privileged_operation_has_no_caller_supplied_command(self):
        protocol = (ROOT / 'Sources/AudioRecoveryProtocol/AudioRecoveryProtocol.swift').read_text()
        helper = (ROOT / 'Sources/VoiceFeedAudioRecovery/main.swift').read_text()
        self.assertIn('func restartAudio(withReply reply:', protocol)
        self.assertIn('process.arguments = ["-9", "coreaudiod"]', helper)
        self.assertIn('"/usr/bin/killall"', helper)
        self.assertNotIn('/bin/sh', helper)
        self.assertIn('setCodeSigningRequirement(AudioRecoveryIdentity.appRequirement)', helper)
        self.assertIn('guard geteuid() == 0', helper)
        self.assertLess(helper.index('String(now).write'), helper.index('try process.run()'))
        self.assertIn('.now() + 5', helper)
        client = (ROOT / 'Sources/VoiceFeedMac/AudioServiceRecoveryClient.swift').read_text()
        self.assertIn('setCodeSigningRequirement(AudioRecoveryIdentity.helperRequirement)', client)
        self.assertIn('.now() + 10', client)
        self.assertIn('guard approved, signedRelease', client)

    def test_every_packager_includes_the_same_privileged_helper(self):
        for file in ['install.sh','release.sh','.github/workflows/build-release.yml']:
            source = (ROOT / file).read_text()
            self.assertIn('Contents/Library/HelperTools/VoiceFeedAudioRecovery', source)
            self.assertIn('Resources/LaunchDaemons/com.aisloppy.voice-feed.audio-recovery.plist', source)
            self.assertIn('--identifier com.aisloppy.voice-feed.audio-recovery', source)
