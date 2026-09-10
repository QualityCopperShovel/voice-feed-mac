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
    private var configurationObserver: NSObjectProtocol?
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
    private var terminal = false
    private var stopSent = false
    private var tapped = false
    private var lastPing = Date()
    private var pingStarted: Date?
    private let onReady: () -> Void
    private let onFailure: (Error) -> Void
    private let onComplete: () -> Void
    private let onRotate: () -> Void

    init(token: String, connectionID: String, onReady: @escaping () -> Void,
         onFailure: @escaping (Error) -> Void, onComplete: @escaping () -> Void,
         onRotate: @escaping () -> Void) {
        self.onReady=onReady; self.onFailure=onFailure; self.onComplete=onComplete; self.onRotate=onRotate
        var request=URLRequest(url: URL(string: "wss://voice-feed.aisloppy.com/api/device/live")!)
        request.timeoutInterval=15
        request.setValue(captureID, forHTTPHeaderField: "X-Voice-Capture-ID")
        request.setValue("gated", forHTTPHeaderField: "X-Voice-Capture-Mode")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(connectionID, forHTTPHeaderField: "X-Voice-Connection")
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
    private func capture() throws {
        var input: AVAudioInputNode?
        var startError: Error?
        let converter = MicrophoneConverter()
        let nativeError = VFAudioPerform {
            let node = self.engine.inputNode; input = node
            let format = node.inputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                startError = NSError(domain:"VoiceFeedAudio", code:2, userInfo:[NSLocalizedDescriptionKey:"Microphone audio format is unavailable"]); return
            }
            MacDiagnostics.shared.record("audio_format", fields:["sample_rate":String(format.sampleRate), "channels":String(format.channelCount)])
            // Do not force a cached output format back onto changing hardware.
            node.installTap(onBus:0, bufferSize:4096, format:nil) { buffer, _ in
                do {
                    // Consume borrowed hardware samples before the callback returns.
                    let audio = try converter.convert(buffer)
                    self.queue.async {
                        guard !self.terminal, self.drainStarted == nil else { return }
                        self.maxAudioGapMs = max(self.maxAudioGapMs, Int(Date().timeIntervalSince(self.lastBuffer) * 1000))
                        self.lastBuffer = Date()
                        guard !audio.isEmpty else { return }
                        if self.packets.count >= 100 { self.failMessage("Audio upload stalled; microphone stopped before its buffer overflowed"); return }
                        for event in self.gate.consume(audio) {
                            switch event {
                            case .audio(let data): self.packets.append(["type":"input_audio_buffer.append", "audio":data.base64EncodedString()])
                            case .pause: self.packets.append(["type":"capture.pause"])
                            }
                        }
                        self.maxQueuePackets = max(self.maxQueuePackets, self.packets.count)
                        self.pump()
                    }
                } catch { self.queue.async { self.fail(error) } }
            }
            self.tapped = true
            self.engine.prepare()
            do { try self.engine.start() } catch { startError = error }
        }
        if let error = (nativeError as Error?) ?? startError { throw error }
        guard input != nil else { throw NSError(domain:"VoiceFeedAudio", code:2) }
        lastBuffer = Date()
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                guard !self.terminal, self.drainStarted == nil else { return }
                self.failMessage("Microphone configuration changed; reconnecting")
            }
        }
        MacDiagnostics.shared.record("audio_engine_started")
    }
    private func pump() {
        guard !terminal, !sending else { return }
        let event:[String:Any]
        if !packets.isEmpty {
            event=packets.removeFirst()
        } else if drainStarted != nil && !stopSent {
            stopSent=true; event=["type":"stop"]
        } else { return }
        do {
            let bytes=try JSONSerialization.data(withJSONObject:event)
            sending=true; sendStarted=Date()
            socket?.send(.string(String(decoding:bytes,as:UTF8.self))) { error in
                self.queue.async {
                    self.maxSendMs = max(self.maxSendMs, Int(Date().timeIntervalSince(self.sendStarted) * 1000))
                    self.sending=false
                    if let error { self.fail(error) } else { self.pump() }
                }
            }
        } catch { fail(error) }
    }
    private func receive() {
        socket?.receive { result in
            self.queue.async {
                guard !self.terminal else { return }
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
                        self.ready=true; if self.drainStarted == nil { try self.capture(); DispatchQueue.main.async(execute:self.onReady) }
                    } else if type == "completed" {
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
            guard !self.terminal,self.drainStarted == nil else { return }
            self.stopEngine()
            // Drain owned tap buffers already enqueued before sending stop.
            self.queue.async { self.drainStarted=Date(); self.pump() }
        }
    }
    func cancel() { queue.async { self.finish() } }
    private func stopEngine() {
        MacDiagnostics.shared.record("audio_engine_stopping")
        if let observer = configurationObserver { NotificationCenter.default.removeObserver(observer); configurationObserver = nil }
        if let error = VFAudioPerform({ self.engine.stop() }) { MacDiagnostics.shared.failure("capture_failed", error) }
        if tapped {
            if let error = VFAudioPerform({ self.engine.inputNode.removeTap(onBus:0) }) { MacDiagnostics.shared.failure("capture_failed", error) }
            tapped = false
        }
    }
    private func finish() {
        guard !terminal else { return }; terminal=true
        recordDiagnostics("capture_end")
        stopEngine(); timer?.cancel(); timer=nil; packets.removeAll()
        socket?.cancel(with:.normalClosure,reason:nil); session.invalidateAndCancel()
    }
    private func failMessage(_ message:String) { fail(NSError(domain:"VoiceFeed",code:3,userInfo:[NSLocalizedDescriptionKey:message])) }
    private func fail(_ error:Error) {
        guard !terminal else { return }; MacDiagnostics.shared.failure("capture_failed", error); finish(); DispatchQueue.main.async { self.onFailure(error) }
    }
    private func checkDeadline() {
        let now=Date()
        if ready && now.timeIntervalSince(lastDiagnostic) >= 30 { recordDiagnostics("periodic") }
        if !ready && now.timeIntervalSince(started)>20 { failMessage("Live transcription did not connect within 20 seconds"); return }
        if ready && drainStarted == nil && now.timeIntervalSince(lastBuffer)>30 { failMessage("Microphone stopped producing audio for 30 seconds"); return }
        if sending && now.timeIntervalSince(sendStarted)>10 { failMessage("Audio upload timed out"); return }
        if let drainStarted,now.timeIntervalSince(drainStarted)>25 { failMessage("Final words did not finish within 25 seconds"); return }
        if let pingStarted,now.timeIntervalSince(pingStarted)>10 { failMessage("Live transcription disconnected"); return }
        if ready && drainStarted == nil && now.timeIntervalSince(started)>1140 {
            stop(); DispatchQueue.main.async(execute:onRotate); return
        }
        if ready && drainStarted == nil && now.timeIntervalSince(lastHeartbeat)>5 {
            lastHeartbeat=now
            packets.append(["type":"capture.heartbeat"]); pump()
        }
        if pingStarted == nil && now.timeIntervalSince(lastPing)>10 {
            lastPing=now; pingStarted=now
            socket?.sendPing { error in self.queue.async {
                self.pingStarted=nil; if let error { self.fail(error) }
            } }
        }
    }
}
