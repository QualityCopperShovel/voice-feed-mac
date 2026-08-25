import AppKit
import AVFoundation
import CryptoKit
import Security

// Voice Feed is a menu-bar-only microphone client. It records speech-shaped
// windows, discards local silence, uploads speech over HTTPS, and immediately
// deletes each temporary recording after upload. It never reads transcripts.
let baseURL = URL(string: "https://voice-feed.aisloppy.com")!
let clientVersion = "1.2.4"

// A compact template rendering of the Voice Feed microphone-and-text mark.
// Drawing it locally keeps the menu-bar asset crisp at native scale and lets
// macOS tint it correctly in both light and dark appearances.
func voiceFeedStatusImage() -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18))
    image.lockFocus()
    NSColor.black.setFill(); NSColor.black.setStroke()
    NSBezierPath(roundedRect: NSRect(x: 4.5, y: 6, width: 5.2, height: 9), xRadius: 2.6, yRadius: 2.6).fill()
    let cradle = NSBezierPath(); cradle.move(to: NSPoint(x: 2.8, y: 9.2)); cradle.curve(to: NSPoint(x: 8, y: 3.8), controlPoint1: NSPoint(x: 2.8, y: 5.8), controlPoint2: NSPoint(x: 5, y: 3.8)); cradle.lineWidth = 1.5; cradle.lineCapStyle = .round; cradle.stroke()
    NSBezierPath(roundedRect: NSRect(x: 7.25, y: 1.9, width: 1.5, height: 2.5), xRadius: 0.75, yRadius: 0.75).fill()
    NSBezierPath(roundedRect: NSRect(x: 5.7, y: 1.4, width: 4.6, height: 1.5), xRadius: 0.75, yRadius: 0.75).fill()
    for (x, y, width) in [(11.1, 13.2, 4.1), (11.1, 10.3, 2.8), (11.1, 7.4, 4.8), (11.1, 4.5, 3.5)] { NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: 1.4), xRadius: 0.7, yRadius: 0.7).fill() }
    image.unlockFocus(); image.isTemplate = true
    return image
}

// Updates are announced by Voice Feed's own HTTPS origin. The installer is
// accepted only when its SHA-256 matches that manifest, then runs with a
// five-minute deadline and relaunches the app without replacing Keychain data.
final class AutoUpdater {
    struct Manifest: Decodable { let version: String; let installer_url: String; let installer_sha256: String }
    private let session: URLSession = { let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 45; return URLSession(configuration: config) }()
    private let status: (String) -> Void
    private var timer: Timer?
    init(status: @escaping (String) -> Void) { self.status = status }
    func start() { check(); timer?.invalidate(); timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.check() } }
    private func isNewer(_ candidate: String) -> Bool {
        let left = candidate.split(separator: ".").map { Int($0) ?? 0 }, right = clientVersion.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) { let a = index < left.count ? left[index] : 0, b = index < right.count ? right[index] : 0; if a != b { return a > b } }
        return false
    }
    func check() {
        var request = URLRequest(url: URL(string: "/client-version.json", relativeTo: baseURL)!); request.timeoutInterval = 15
        session.dataTask(with: request) { data, response, error in
            guard error == nil, (response as? HTTPURLResponse)?.statusCode == 200, let data, let manifest = try? JSONDecoder().decode(Manifest.self, from: data), self.isNewer(manifest.version), let installerURL = URL(string: manifest.installer_url) else { return }
            var installerRequest = URLRequest(url: installerURL); installerRequest.timeoutInterval = 30
            self.session.dataTask(with: installerRequest) { payload, installerResponse, installerError in
                guard installerError == nil, (installerResponse as? HTTPURLResponse)?.statusCode == 200, let payload else { self.status("Update download failed"); return }
                let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
                guard digest == manifest.installer_sha256.lowercased() else { self.status("Update verification failed"); return }
                let script = FileManager.default.temporaryDirectory.appendingPathComponent("voice-feed-update-\(UUID().uuidString).sh")
                do { try payload.write(to: script, options: .atomic); self.install(script) } catch { self.status("Update could not be saved") }
            }.resume()
        }.resume()
    }
    private func install(_ script: URL) {
        DispatchQueue.main.async { self.status("Installing Voice Feed update…") }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/bash"); process.arguments = [script.path]
        var environment = ProcessInfo.processInfo.environment; environment["VOICE_FEED_AUTO_UPDATE"] = "1"; process.environment = environment
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate(); self.status("Update timed out") } }
        process.terminationHandler = { completed in
            deadline.cancel(); try? FileManager.default.removeItem(at: script)
            guard completed.terminationStatus == 0 else { self.status("Update failed"); return }
            let relaunch = Process(); relaunch.executableURL = URL(fileURLWithPath: "/bin/sh"); relaunch.arguments = ["-c", "sleep 1; /usr/bin/open \"$HOME/Applications/Voice Feed.app\""]
            try? relaunch.run(); DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
        }
        do { try process.run(); DispatchQueue.global().asyncAfter(deadline: .now() + 300, execute: deadline) } catch { try? FileManager.default.removeItem(at: script); status("Update could not start") }
    }
}

// Capture credentials are kept in the user's macOS Keychain rather than a
// preferences file. The token is scoped by the server to microphone capture.
final class Keychain {
    private let service = "com.aisloppy.voice-feed"
    func load() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    func save(_ token: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        let values = [kSecValueData as String: Data(token.utf8)]
        if SecItemUpdate(query as CFDictionary, values as CFDictionary) == errSecItemNotFound {
            var insert = query; insert[kSecValueData as String] = Data(token.utf8); SecItemAdd(insert as CFDictionary, nil)
        }
    }
    func delete() { SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary) }
}

// All server traffic uses an ephemeral URLSession, explicit deadlines, and the
// one fixed Voice Feed origin above. The session does not retain a URL cache.
final class API {
    private let session: URLSession = { let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 40; return URLSession(configuration: config) }()
    var token: String?
    func request(_ path: String, method: String = "GET", json: [String: Any]? = nil, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        var request = URLRequest(url: URL(string: path, relativeTo: baseURL)!); request.httpMethod = method; request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type"); if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let json { request.httpBody = try? JSONSerialization.data(withJSONObject: json) }
        session.dataTask(with: request) { data, response, error in
            if let error { completion(.failure(error)); return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let object = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
            if !(200..<300).contains(status) { completion(.failure(NSError(domain: "VoiceFeed", code: status, userInfo: [NSLocalizedDescriptionKey: object["error"] as? String ?? "HTTP \(status)"]))); return }
            completion(.success(object))
        }.resume()
    }
    // Audio is sent as one multipart request. The defer block removes the local
    // recording after every terminal network result, including server errors.
    func upload(_ file: URL, connectionID: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let audio = try? Data(contentsOf: file) else { completion(.failure(NSError(domain: "VoiceFeed", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not read recording."]))); return }
        let boundary = UUID().uuidString
        var body = Data(); body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"audio\"; filename=\"voice.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n".data(using: .utf8)!); body.append(audio); body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        var request = URLRequest(url: URL(string: "/api/device/transcribe", relativeTo: baseURL)!); request.httpMethod = "POST"; request.timeoutInterval = 40; request.httpBody = body
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type"); request.setValue("Bearer \(token ?? "")", forHTTPHeaderField: "Authorization"); request.setValue(connectionID, forHTTPHeaderField: "X-Voice-Connection")
        session.dataTask(with: request) { data, response, error in
            defer { try? FileManager.default.removeItem(at: file) }
            if let error { completion(.failure(error)); return }; let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { let object = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]); completion(.failure(NSError(domain: "VoiceFeed", code: status, userInfo: [NSLocalizedDescriptionKey: object?["error"] as? String ?? "HTTP \(status)"]))); return }
            completion(.success(()))
        }.resume()
    }
}

// AppDelegate owns the menu-bar UI, account pairing, exclusive capture lease,
// microphone permission, and the bounded recording loop.
final class AppDelegate: NSObject, NSApplicationDelegate, AVAudioRecorderDelegate, @unchecked Sendable {
    let api = API(), keychain = Keychain(), statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    var recorder: AVAudioRecorder?, leaseTimer: Timer?, recordTimer: Timer?, connectionID = UUID().uuidString.replacingOccurrences(of: "-", with: ""), heardSpeech = false, listening = false, recordingID = 0, windowStartedAt = Date(), lastSpeechAt = Date()
    let status = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: ""), connect = NSMenuItem(title: "Connect this Mac…", action: #selector(connectDevice), keyEquivalent: ""), start = NSMenuItem(title: "Start listening", action: #selector(startListening), keyEquivalent: ""), stop = NSMenuItem(title: "Stop listening", action: #selector(stopListening), keyEquivalent: "")
    lazy var updater = AutoUpdater { [weak self] message in self?.setStatus(message) }
    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.image = voiceFeedStatusImage()
        statusItem.button?.image?.accessibilityDescription = "Voice Feed"
        let devices = NSMenuItem(title: "Open Devices…", action: #selector(openDevices), keyEquivalent: ""), quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        [connect, start, stop, devices, quitItem].forEach { $0.target = self }
        let menu = NSMenu(); [status, .separator(), connect, start, stop, .separator(), devices, quitItem].forEach(menu.addItem); statusItem.menu = menu
        api.token = keychain.load(); refreshMenu()
        updater.start()
        if api.token != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.startListening() } }
        else { DispatchQueue.main.async { self.showFirstRunGuide() } }
    }
    func showFirstRunGuide() {
        guard !UserDefaults.standard.bool(forKey: "didShowConnectionGuide") else { return }
        UserDefaults.standard.set(true, forKey: "didShowConnectionGuide")
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Voice Feed is ready"
        alert.informativeText = "Look for the waveform icon in your menu bar. Connect this Mac once, then Voice Feed will listen automatically."
        alert.addButton(withTitle: "Connect This Mac")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn { connectDevice() }
    }
    func setStatus(_ text: String) { DispatchQueue.main.async { self.status.title = text; self.refreshMenu() } }
    func refreshMenu() { connect.isHidden = api.token != nil; start.isHidden = api.token == nil || listening; stop.isHidden = !listening }
    @objc func openDevices() { NSWorkspace.shared.open(URL(string: "https://voice-feed.aisloppy.com/")!) }
    // Pairing opens Voice Feed in the browser so account approval never occurs
    // inside this native client. The one-time request expires after ten minutes.
    @objc func connectDevice() {
        setStatus("Creating secure connection…"); api.request("/api/devices/start", method: "POST", json: ["device_name": Host.current().localizedName ?? "Mac"]) { result in
            switch result { case .failure(let error): self.setStatus(error.localizedDescription)
            case .success(let data): guard let id = data["connection_id"] as? String, let secret = data["device_secret"] as? String, let urlText = data["verification_url"] as? String, let url = URL(string: urlText) else { self.setStatus("Invalid connection response"); return }; DispatchQueue.main.async { NSWorkspace.shared.open(url) }; self.poll(id: id, secret: secret, deadline: Date().addingTimeInterval(600)) }
        }
    }
    func poll(id: String, secret: String, deadline: Date) {
        guard Date() < deadline else { setStatus("Connection timed out"); return }
        api.request("/api/devices/status", method: "POST", json: ["connection_id": id, "device_secret": secret]) { result in
            switch result { case .failure(let error): self.setStatus(error.localizedDescription)
            case .success(let data): let state = data["status"] as? String ?? ""; if state == "connected", let token = data["capture_token"] as? String { self.keychain.save(token); self.api.token = token; self.setStatus("Connected"); DispatchQueue.main.async { self.startListening() } } else if state == "pending" || state == "approved" { DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.poll(id: id, secret: secret, deadline: deadline) } } else { self.setStatus("Connection \(state)") } }
        }
    }
    // macOS presents its standard microphone consent dialog before capture.
    @objc func startListening() {
        guard api.token != nil, !listening else { return }; setStatus("Requesting microphone…")
        AVCaptureDevice.requestAccess(for: .audio) { allowed in DispatchQueue.main.async { if allowed { self.enableAndLease() } else { self.setStatus("Microphone access denied") } } }
    }
    // The renewable server lease prevents two devices from owning one account's
    // microphone feed simultaneously. Failure stops capture instead of guessing.
    func enableAndLease() { api.request("/api/device/preference", method: "PUT", json: ["enabled": true]) { result in if case .failure(let error) = result { self.setStatus(error.localizedDescription); return }; self.api.request("/api/device/lease", method: "POST", json: ["connection_id": self.connectionID]) { lease in switch lease { case .failure(let error): self.setStatus(error.localizedDescription); case .success: DispatchQueue.main.async { self.listening = true; self.setStatus("Listening"); self.leaseTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in self.renewLease() }; self.recordWindow() } } } } }
    func renewLease() { api.request("/api/device/lease/\(connectionID)", method: "PUT") { result in if case .failure(let error) = result { DispatchQueue.main.async { self.stopLocal(); self.setStatus(error.localizedDescription) } } } }
    // Record a compact AAC window and sample its local power meter. Windows that
    // never cross the speech threshold are deleted without leaving the Mac.
    func recordWindow() {
        guard listening else { return }; let file = FileManager.default.temporaryDirectory.appendingPathComponent("voice-feed-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32000]
        do { recordingID += 1; let activeID = recordingID; windowStartedAt = Date(); lastSpeechAt = windowStartedAt; recorder = try AVAudioRecorder(url: file, settings: settings); recorder?.isMeteringEnabled = true; recorder?.record(); heardSpeech = false; recordTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in self.recorder?.updateMeters(); let now = Date(); if (self.recorder?.peakPower(forChannel: 0) ?? -160) > -30 { self.heardSpeech = true; self.lastSpeechAt = now } else if self.heardSpeech && now.timeIntervalSince(self.windowStartedAt) > 0.8 && now.timeIntervalSince(self.lastSpeechAt) > 0.55 { self.finishWindow(file, recordingID: activeID) } }; DispatchQueue.main.asyncAfter(deadline: .now() + 12) { self.finishWindow(file, recordingID: activeID) } } catch { setStatus(error.localizedDescription); stopLocal() }
    }
    func finishWindow(_ file: URL, recordingID activeID: Int) { guard activeID == recordingID, recorder != nil else { return }; guard listening else { try? FileManager.default.removeItem(at: file); return }; recorder?.stop(); recordTimer?.invalidate(); let send = heardSpeech; recorder = nil; if send { api.upload(file, connectionID: connectionID) { result in if case .failure(let error) = result { self.setStatus(error.localizedDescription) } } } else { try? FileManager.default.removeItem(at: file) }; recordWindow() }
    @objc func stopListening() { stopLocal(); api.request("/api/device/lease/\(connectionID)", method: "DELETE") { _ in }; setStatus("Paused") }
    func stopLocal() { listening = false; recorder?.stop(); recorder = nil; leaseTimer?.invalidate(); recordTimer?.invalidate(); leaseTimer = nil; recordTimer = nil; refreshMenu() }
    @objc func quit() { stopListening(); NSApplication.shared.terminate(nil) }
}

// LSUIElement in Info.plist keeps this process out of the Dock; AppKit still
// supplies the menu-bar item and a normal application lifecycle.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
