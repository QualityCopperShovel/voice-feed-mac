import AVFoundation
import Foundation
import CaptureCore

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
    private var converter: AVAudioConverter?
    private var timer: DispatchSourceTimer?
    private var packets: [[String: Any]] = []
    private var gate = SpeechGate()
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
        let input=engine.inputNode
        let format=input.outputFormat(forBus:0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let output=AVAudioFormat(commonFormat:.pcmFormatInt16,sampleRate:24000,channels:1,interleaved:true),
              let converter=AVAudioConverter(from:format,to:output) else {
            throw NSError(domain:"VoiceFeed",code:1,userInfo:[NSLocalizedDescriptionKey:"Microphone audio format is unavailable"])
        }
        MacDiagnostics.shared.record("audio_format", fields: ["sample_rate": String(format.sampleRate), "channels": String(format.channelCount)])
        self.converter=converter
        input.installTap(onBus:0,bufferSize:4096,format:format) { buffer, _ in
            // Conversion consumes this tap buffer synchronously; only owned bytes leave the callback.
            let capacity=AVAudioFrameCount(Double(buffer.frameLength)*24000/format.sampleRate)+64
            guard let pcm=AVAudioPCMBuffer(pcmFormat:output,frameCapacity:capacity) else { return }
            var consumed=false
            var error:NSError?
            let result=converter.convert(to:pcm,error:&error) { _, state in
                if consumed { state.pointee = .noDataNow; return nil }
                consumed=true; state.pointee = .haveData; return buffer
            }
            if result == .error || error != nil {
                self.queue.async { self.fail(error ?? NSError(domain:"VoiceFeed",code:2,userInfo:[NSLocalizedDescriptionKey:"Microphone audio conversion failed"])) }
                return
            }
            guard pcm.frameLength > 0, let samples=pcm.int16ChannelData?[0] else { return }
            let audio=Data(bytes:samples,count:Int(pcm.frameLength)*2)
            self.queue.async {
                guard !self.terminal, self.drainStarted == nil else { return }
                if self.packets.count >= 100 { self.failMessage("Audio upload stalled; microphone stopped before its buffer overflowed"); return }
                for event in self.gate.consume(audio) {
                    switch event {
                    case .audio(let data): self.packets.append(["type":"input_audio_buffer.append","audio":data.base64EncodedString()])
                    case .pause: self.packets.append(["type":"capture.pause"])
                    }
                }
                self.pump()
            }
        }
        tapped=true; engine.prepare(); try engine.start()
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
        engine.stop()
        if tapped { engine.inputNode.removeTap(onBus:0); tapped=false }
    }
    private func finish() {
        guard !terminal else { return }; terminal=true
        stopEngine(); timer?.cancel(); timer=nil; packets.removeAll()
        socket?.cancel(with:.normalClosure,reason:nil); session.invalidateAndCancel()
    }
    private func failMessage(_ message:String) { fail(NSError(domain:"VoiceFeed",code:3,userInfo:[NSLocalizedDescriptionKey:message])) }
    private func fail(_ error:Error) {
        guard !terminal else { return }; MacDiagnostics.shared.failure("capture_failed", error); finish(); DispatchQueue.main.async { self.onFailure(error) }
    }
    private func checkDeadline() {
        let now=Date()
        if !ready && now.timeIntervalSince(started)>20 { failMessage("Live transcription did not connect within 20 seconds"); return }
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
