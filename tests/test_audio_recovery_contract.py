import pathlib
import plistlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]

class AudioRecoveryContractTests(unittest.TestCase):
    def test_route_rebuild_retires_old_graph_without_replacing_network(self):
        source = (ROOT / 'Sources/VoiceFeedMac/LiveCapture.swift').read_text()
        rebuild = source.split('case .rebuild:', 1)[1].split('private func enqueue', 1)[0]
        self.assertLess(rebuild.index('stopEngine(invalidateCallbacks: true)'), rebuild.index('engine = AVAudioEngine()'))
        self.assertLess(rebuild.index('engine = AVAudioEngine()'), rebuild.index('try capture()'))
        self.assertNotIn('socket', rebuild)
        self.assertNotIn('session', rebuild)
        handler = source.split('forName: .AVAudioEngineConfigurationChange', 1)[1].split('defaultMicrophoneObserver =', 1)[0]
        self.assertIn('self.queue.async', handler)
        self.assertIn('generation == self.hardwareGeneration', handler)
        self.assertNotIn('engine = AVAudioEngine()', handler)

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

    def test_explicit_capture_start_resets_old_failure_evidence(self):
        source = (ROOT / 'Sources/VoiceFeedMac/main.swift').read_text()
        start = source[source.index('@objc func startListening()'):source.index('func enableAndLease()')]
        self.assertIn('audioRecoveryPolicy.reset()', start)

    def test_source_install_preserves_hardened_runtime_microphone_entitlement(self):
        source = (ROOT / 'install.sh').read_text()
        self.assertIn('Info.plist Entitlements.plist Resources/', source)
        self.assertIn('--entitlements "$BUILD_DIR/Entitlements.plist"', source)
        with (ROOT / 'Entitlements.plist').open('rb') as file:
            self.assertTrue(plistlib.load(file)['com.apple.security.device.audio-input'])
