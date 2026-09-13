import Foundation
import Darwin
import CaptureCore
import AudioRecoveryProtocol

/// Root-owned, single-operation helper. It never receives shell text or audio.
final class AudioRecoveryService: NSObject, NSXPCListenerDelegate, AudioRecoveryProtocol {
    private let queue = DispatchQueue(label: "voice-feed.audio-service-reset")
    private var running = false
    private let checkpoint = URL(fileURLWithPath: "/var/db/com.aisloppy.voice-feed.audio-recovery/last-attempt")
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // The framework validates the peer's code identity on its XPC messages;
        // a recycled PID or claimed bundle identifier cannot authorize a caller.
        connection.setCodeSigningRequirement(AudioRecoveryIdentity.appRequirement)
        connection.exportedInterface = NSXPCInterface(with: AudioRecoveryProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }
    func restartAudio(withReply reply: @escaping (Bool, String) -> Void) {
        queue.async {
            guard !self.running else { reply(false, "An audio-service restart is already running."); return }
            do {
                let manager = FileManager.default
                let directory = self.checkpoint.deletingLastPathComponent()
                try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let last: TimeInterval?
                if manager.fileExists(atPath: self.checkpoint.path) {
                    guard let value = Double(try String(contentsOf: self.checkpoint)), value.isFinite else {
                        reply(false, "Audio recovery cooldown data is invalid; restart refused."); return
                    }
                    last = value
                } else { last = nil }
                let now = Date().timeIntervalSince1970
                guard AudioRestartCooldown.allowed(lastAttempt: last, now: now) else {
                    reply(false, "Audio recovery is limited to one attempt every 30 minutes."); return
                }
                try String(now).write(to: self.checkpoint, atomically: true, encoding: .utf8)
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.checkpoint.path)
                self.running = true
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
                process.arguments = ["-9", "coreaudiod"]
                process.environment = ["PATH": "/usr/bin:/bin"]
                process.currentDirectoryURL = URL(fileURLWithPath: "/")
                process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                var finished = false
                func finish(_ ok: Bool, _ message: String) {
                    guard !finished else { return }; finished = true; self.running = false; reply(ok, message)
                }
                process.terminationHandler = { task in self.queue.async {
                    finish(task.terminationStatus == 0, task.terminationStatus == 0
                           ? "Audio-service restart requested; waiting for microphone callbacks."
                           : "Audio-service restart failed (exit \(task.terminationStatus)).")
                } }
                try process.run()
                self.queue.asyncAfter(deadline: .now() + 5) {
                    guard !finished else { return }
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    finish(false, "Audio-service restart command timed out after 5 seconds.")
                }
            } catch {
                self.running = false
                reply(false, "Audio-service restart could not run: \(error.localizedDescription)")
            }
        }
    }
}

guard geteuid() == 0 else { fputs("Audio recovery must be launched by macOS as an approved daemon.\n", stderr); exit(77) }
let service = AudioRecoveryService()
let listener = NSXPCListener(machServiceName: AudioRecoveryIdentity.service)
listener.delegate = service
listener.resume()
RunLoop.current.run()
