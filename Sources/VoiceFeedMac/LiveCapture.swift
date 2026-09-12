import AVFoundation
import Foundation
import CaptureCore
import CaptureAudio
import AudioSafety

/// Continuous audio packets share one provider transcription context.
final class LiveCapture: @unchecked Sendable {
    private let queue = DispatchQueue(label: "voice-feed.audio")
    private let engine = AVAudioEngine()
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 1250
        return URLSession(configuration: c)
    }()
    private var socket: URLSessionWebSocketTask?
    private let socketRequest: URLRequest
    private var socketGeneration = UUID()
    private var rotating = false
    private var stopping = false
    private var recoveryAudio: RecoveryAudio?
    private var rotationBuffer = RotationBuffer()
    private var rotationStarted: Date?
    private var configurationObserver: NSObjectProtocol?
    private var defaultMicrophoneObserver: DefaultMicrophoneObserver?
    private var hardwareGeneration = UUID()
    private var reconfiguration = MicrophoneReconfiguration()
    private var lastBuffer = Date()
    private var timer: DispatchSourceTimer?
    private var packets: [[String: Any]] = []
    private var gate = SpeechGate()
    private let captureID = UUID().uuidString
    private var lastDiagnostic = Date()
    private var maxAudioGapMs = 0
    private var maxSendMs = 0
    private var maxQueuePackets = 0
    private func recordDiagnostics(_ stage: String) {
        var fields = gate.diagnostics()
        fields["capture_id"] = captureID; fields["stage"] = stage
        fields["audio_gap_ms"] = String(maxAudioGapMs)
        fields["send_delay_ms"] = String(maxSendMs)
        fields["queue_packets_max"] = String(maxQueuePackets)
        MacDiagnostics.shared.record("capture_sample", fields: fields)
        maxAudioGapMs = 0; maxSendMs = 0; maxQueuePackets = 0; lastDiagnostic = Date()
    }
    private var lastHeartbeat = Date()
    private var sending = false
    private var sendStarted = Date()
    private var started = Date()
    private var drainStarted: Date?
    private var ready = false
    private var microphoneHealth = MicrophoneReadiness()
    private var failureReporting = false
    private var finishFailure: (() -> Void)?
    private var terminal = false
    private var stopSent = false
    private var tapped = false
    private var lastPing = Date()
    private var pingStarted: Date?
    private let onReady: () -> Void
    private let onFailure: (Error) -> Void
    private let onComplete: () -> Void
    private let onRotate: () -> Void
    private let onReconfigure: () -> Void

    init(token: String, connectionID: String, onReady: @escaping () -> Void,
         onFailure: @escaping (Error) -> Void, onComplete: @escaping () -> Void,
         onRotate: @escaping () -> Void, onReconfigure: @escaping () -> Void) {
        self.onReady=onReady; self.onFailure=onFailure; self.onComplete=onComplete; self.onRotate=onRotate; self.onReconfigure=onReconfigure
        var request=URLRequest(url: URL(string: "wss://voice-feed.aisloppy.com/api/device/live")!)
        request.timeoutInterval=15
        request.setValue(captureID, forHTTPHeaderField: "X-Voice-Capture-ID")
        request.setValue("gated", forHTTPHeaderField: "X-Voice-Capture-Mode")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(connectionID, forHTTPHeaderField: "X-Voice-Connection")
        socketRequest = request
        socket=session.webSocketTask(with: request)
    }
    func start() {
        MacDiagnostics.shared.record("capture_start")
        queue.async {
            self.started=Date(); self.socket?.resume(); self.receive()
            let timer=DispatchSource.makeTimerSource(queue:self.queue)
            timer.schedule(deadline:.now()+1,repeating:1)
            timer.setEventHandler { self.checkDeadline() }; self.timer=timer; timer.resume()
        }
    }
    static let recoveryDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Voice Feed/Recovery Audio", isDirectory: true)
    private func capture() throws {
        var input: AVAudioInputNode?
        var startError: Error?
        let converter = MicrophoneConverter()
        if recoveryAudio == nil { recoveryAudio = try RecoveryAudio(directory: Self.recoveryDirectory) }
        let generation = hardwareGeneration
        let nativeError = VFAudioPerform {
            let node = self.engine.inputNode; input = node
            do {
                _ = try MicrophoneInput.prepare(SystemMicrophoneDevice(node: node)) { fields in
                    MacDiagnostics.shared.record("audio_format", fields: fields.merging(["capture_id": self.captureID]) { _, new in new })
                }
            } catch { startError = error; return }
            // Do not force a cached output format back onto changing hardware.
            node.installTap(onBus:0, bufferSize:4096, format:nil) { buffer, _ in
                do {
                    // Consume borrowed hardware samples before the callback returns.
                    let audio = try converter.convert(buffer)
                    self.queue.async {
                        guard !self.terminal, !self.failureReporting, generation == self.hardwareGeneration else { return }
                        self.maxAudioGapMs = max(self.maxAudioGapMs, Int(Date().timeIntervalSince(self.lastBuffer) * 1000))
                        self.lastBuffer = Date()
                        guard !audio.isEmpty else { return }
                        do { try self.recoveryAudio?.append(audio) }
                        catch { self.fail(NSError(domain: "VoiceFeedRecovery", code: 4, userInfo: [NSLocalizedDescriptionKey: "Could not preserve microphone audio locally. Capture stopped to avoid unprotected recording."])); return }
                        if self.reconfiguration.expired(now: ProcessInfo.processInfo.systemUptime) {
                            self.reconfigureMicrophone(); return
                        }
                        let first = self.microphoneHealth.receive(pcm: audio)
                        if self.rotating {
                            do { try self.rotationBuffer.append(audio) } catch { self.fail(error) }
                            return
                        }
                        guard self.drainStarted == nil else { return }
                        if first {
                            self.reconfiguration.receivedAudio(now: ProcessInfo.processInfo.systemUptime)
                            self.packets.append(["type": "capture.heartbeat"])
                            DispatchQueue.main.async(execute: self.onReady)
                        }
                        self.enqueue(audio)

                    }
                } catch { self.queue.async { if generation == self.hardwareGeneration { self.fail(error) } } }
            }
            self.tapped = true
            self.engine.prepare()
            do { try self.engine.start() } catch { startError = error }
        }
        if let error = (nativeError as Error?) ?? startError { throw error }
        guard input != nil else { throw NSError(domain:"VoiceFeedAudio", code:2) }
        lastBuffer = Date()
        microphoneHealth = MicrophoneReadiness()
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                guard generation == self.hardwareGeneration else { return }
                self.reconfigureMicrophone()
            }
        }
        defaultMicrophoneObserver = try DefaultMicrophoneObserver(queue: queue) { [weak self] in
            guard let self, generation == self.hardwareGeneration else { return }
            self.reconfigureMicrophone()
        }
        MacDiagnostics.shared.record("audio_engine_started")
    }
    private func reconfigureMicrophone() {
        guard !terminal, !failureReporting, !stopping, drainStarted == nil else { return }
        switch reconfiguration.changed(now: ProcessInfo.processInfo.systemUptime) {
        case .waiting: return
        case .failed:
            fail(NSError(domain: "VoiceFeedAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: "Microphone configuration did not stabilize. Check the selected input; reconnecting."]))
        case .rebuild:
            DispatchQueue.main.async(execute: onReconfigure)
            // This runs on our queue, never Apple's notification callback queue.
            // Keep the socket, queued packets, gate and recovery recording intact.
            stopEngine(invalidateCallbacks: true)
            do { try capture() } catch { fail(error) }
        }
    }
    private func enqueue(_ audio: Data) {
        if packets.count >= 600 { failMessage("Audio upload stalled; microphone stopped before its buffer overflowed"); return }
        for event in gate.consume(audio) {
            switch event {
            case .audio(let data): packets.append(["type": "input_audio_buffer.append", "audio": data.base64EncodedString()])
            case .pause: packets.append(["type": "capture.pause"])
            }
        }
        maxQueuePackets = max(maxQueuePackets, packets.count)
        pump()
    }
    /// Network rotation never owns the hardware lifetime.
    private func rotate() {
        guard !rotating, drainStarted == nil, !terminal else { return }
        rotating = true; rotationStarted = Date(); drainStarted = Date()
        MacDiagnostics.shared.record("capture_rotation", fields: ["capture_id": captureID])
        DispatchQueue.main.async(execute: onRotate)
        pump()
    }
    private func reconnectSocket() {
        socket?.cancel(with: .normalClosure, reason: nil)
        socketGeneration = UUID()
        ready = false; drainStarted = nil; stopSent = false; sending = false
        started = Date(); lastPing = Date(); pingStarted = nil
        socket = session.webSocketTask(with: socketRequest)
        socket?.resume(); receive()
    }
    private func pump() {
        guard !terminal, !failureReporting, !sending else { return }
        let event:[String:Any]
        if !packets.isEmpty {
            event=packets.removeFirst()
        } else if drainStarted != nil && !stopSent {
            stopSent=true; event=["type":"stop"]
        } else { return }
        do {
            let bytes=try JSONSerialization.data(withJSONObject:event)
            sending=true; sendStarted=Date()
            let generation = socketGeneration
            socket?.send(.string(String(decoding:bytes,as:UTF8.self))) { error in
                self.queue.async {
                    guard !self.terminal, generation == self.socketGeneration else { return }
                    self.maxSendMs = max(self.maxSendMs, Int(Date().timeIntervalSince(self.sendStarted) * 1000))
                    self.sending=false
                    if let error { self.fail(error) } else { self.pump() }
                }
            }
        } catch { fail(error) }
    }
    private func receive() {
        let generation = socketGeneration
        socket?.receive { result in
            self.queue.async {
                guard !self.terminal, generation == self.socketGeneration else { return }
                do {
                    let message=try result.get()
                    let data:Data
                    switch message {
                    case .string(let text): data=Data(text.utf8)
                    case .data(let bytes): data=bytes
                    @unknown default: self.failMessage("Unknown live transcription message"); return
                    }
                    guard let event=try JSONSerialization.jsonObject(with:data) as? [String:Any],let type=event["type"] as? String else {
                        self.failMessage("Invalid live transcription response"); return
                    }
                    if type == "ready" && !self.ready {
                        self.ready = true
                        if self.rotating {
                            self.rotating = false; self.rotationStarted = nil
                            if self.microphoneHealth.confirmed { self.packets.append(["type": "capture.heartbeat"]) }
                            for frame in self.rotationBuffer.take() { self.enqueue(frame) }
                            if self.microphoneHealth.confirmed && !self.stopping { DispatchQueue.main.async(execute: self.onReady) }
                            if self.stopping { self.drainStarted = Date() }
                            self.pump()
                        } else if self.drainStarted == nil { try self.capture() }
                    } else if type == "capture.failure_received" && self.failureReporting {
                        self.finishFailure?(); return
                    } else if type == "completed" {
                        if self.rotating { self.reconnectSocket(); return }
                        self.finish(); DispatchQueue.main.async(execute:self.onComplete); return
                    } else if type == "error" {
                        self.failMessage((event["error"] as? [String:Any])?["message"] as? String ?? "Live transcription failed"); return
                    }
                    self.receive()
                } catch { self.fail(error) }
            }
        }
    }
    func stop() {
        queue.async {
            guard !self.terminal else { return }
            self.stopping = true
            self.stopEngine()
            // Finish the old stream, then deliver buffered frames on the next
            // stream before acknowledging a user stop during rotation.
            if self.rotating { return }
            guard self.drainStarted == nil else { return }
            // Drain owned tap buffers already enqueued before sending stop.
            self.queue.async { self.drainStarted=Date(); self.pump() }
        }
    }
    func cancel() { queue.async { self.finish() } }
    private func stopEngine(invalidateCallbacks: Bool = false) {
        if invalidateCallbacks { hardwareGeneration = UUID() }
        defaultMicrophoneObserver?.stop(); defaultMicrophoneObserver = nil
        MacDiagnostics.shared.record("audio_engine_stopping")
        if let observer = configurationObserver { NotificationCenter.default.removeObserver(observer); configurationObserver = nil }
        if let error = VFAudioPerform({ self.engine.stop() }) { MacDiagnostics.shared.failure("capture_failed", error) }
        if tapped {
            if let error = VFAudioPerform({ self.engine.inputNode.removeTap(onBus:0) }) { MacDiagnostics.shared.failure("capture_failed", error) }
            tapped = false
        }
    }
    private func finish() {
        guard !terminal else { return }; terminal=true; finishFailure=nil
        recordDiagnostics("capture_end")
        stopEngine(); timer?.cancel(); timer=nil; packets.removeAll()
        do { try recoveryAudio?.close() } catch { MacDiagnostics.shared.failure("capture_failed", error) }
        recoveryAudio = nil
        socket?.cancel(with:.normalClosure,reason:nil); session.invalidateAndCancel()
    }
    private func failMessage(_ message:String) { fail(NSError(domain:"VoiceFeed",code:3,userInfo:[NSLocalizedDescriptionKey:message])) }
    private func fail(_ error:Error) {
        guard !terminal, !failureReporting else { return }
        var fields = DiagnosticEvidence.failure(error)
        fields["capture_id"] = captureID
        MacDiagnostics.shared.record("capture_failed", fields: fields)
        let failure = error as NSError
        // Report an allowlisted code, never arbitrary NSError text, before closing.
        if ready && failure.domain == "VoiceFeedAudio" && [1, 2, 4, 5, 6].contains(failure.code) {
            failureReporting = true
            stopEngine()
            let report = "{\"type\":\"capture.failed\",\"code\":\"audio_\(failure.code)\"}"
            let complete = {
                guard !self.terminal else { return }
                self.finishFailure = nil
                self.finish()
                DispatchQueue.main.async { self.onFailure(error) }
            }
            finishFailure = complete
            socket?.send(.string(report)) { sendError in
                if sendError != nil { self.queue.async(execute: complete) }
            }
            queue.asyncAfter(deadline: .now() + 2, execute: complete)
        } else {
            finish(); DispatchQueue.main.async { self.onFailure(error) }
        }
    }
    private func checkDeadline() {
        guard !terminal, !failureReporting else { return }
        let now=Date()
        if reconfiguration.expired(now: ProcessInfo.processInfo.systemUptime) {
            fail(NSError(domain: "VoiceFeedAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: "Microphone configuration changed and audio did not return within 10 seconds. Check the selected input; reconnecting."]))
            return
        }
        if ready && now.timeIntervalSince(lastDiagnostic) >= 30 { recordDiagnostics("periodic") }
        if !ready && now.timeIntervalSince(started)>20 { failMessage("Live transcription did not connect within 20 seconds"); return }
        if tapped && microphoneHealth.digitalSilence {
            fail(NSError(domain: "VoiceFeedAudio", code: 6, userInfo: [NSLocalizedDescriptionKey: "Microphone is supplying only digital silence. Open the MacBook lid if using its built-in microphone, or check the selected input and mute state."])); return
        }
        if let rotationStarted, now.timeIntervalSince(rotationStarted) > 45 { failMessage("Connection renewal timed out; capture stopped"); return }
        if tapped && microphoneHealth.expired() {
            fail(NSError(domain: "VoiceFeedAudio", code: 5, userInfo: [NSLocalizedDescriptionKey: microphoneHealth.confirmed ? "Microphone stopped producing audio for 30 seconds" : "The selected microphone produced no audio within 10 seconds"]))
            return
        }
        if sending && now.timeIntervalSince(sendStarted)>10 { failMessage("Audio upload timed out"); return }
        if let drainStarted,now.timeIntervalSince(drainStarted)>25 { failMessage("Final words did not finish within 25 seconds"); return }
        if let pingStarted,now.timeIntervalSince(pingStarted)>10 { failMessage("Live transcription disconnected"); return }
        if ready && drainStarted == nil && now.timeIntervalSince(started)>1140 {
            rotate(); return
        }
        if ready && !rotating && microphoneHealth.confirmed && drainStarted == nil && now.timeIntervalSince(lastHeartbeat)>5 {
            lastHeartbeat=now
            packets.append(["type":"capture.heartbeat"]); pump()
        }
        if pingStarted == nil && now.timeIntervalSince(lastPing)>10 {
            lastPing=now; pingStarted=now
            let generation = socketGeneration
            socket?.sendPing { error in self.queue.async {
                guard !self.terminal, generation == self.socketGeneration else { return }
                self.pingStarted=nil; if let error { self.fail(error) }
            } }
        }
    }
}
