import AppKit
import AVFoundation
import Security

// Voice Feed is a menu-bar-only microphone client. It records five-second
// windows, discards local silence, uploads speech over HTTPS, and immediately
// deletes each temporary recording after upload. It never reads transcripts.
let baseURL = URL(string: "https://voice-feed.aisloppy.com")!

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
final class AppDelegate: NSObject, NSApplicationDelegate, AVAudioRecorderDelegate {
    let api = API(), keychain = Keychain(), statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    var recorder: AVAudioRecorder?, leaseTimer: Timer?, recordTimer: Timer?, connectionID = UUID().uuidString.replacingOccurrences(of: "-", with: ""), heardSpeech = false, listening = false
    let status = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: ""), connect = NSMenuItem(title: "Connect this Mac…", action: #selector(connectDevice), keyEquivalent: ""), start = NSMenuItem(title: "Start listening", action: #selector(startListening), keyEquivalent: ""), stop = NSMenuItem(title: "Stop listening", action: #selector(stopListening), keyEquivalent: "")
    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Voice Feed")
        let devices = NSMenuItem(title: "Open Devices…", action: #selector(openDevices), keyEquivalent: ""), quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        [connect, start, stop, devices, quitItem].forEach { $0.target = self }
        let menu = NSMenu(); [status, .separator(), connect, start, stop, .separator(), devices, quitItem].forEach(menu.addItem); statusItem.menu = menu
        api.token = keychain.load(); refreshMenu()
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
        do { recorder = try AVAudioRecorder(url: file, settings: settings); recorder?.isMeteringEnabled = true; recorder?.record(); heardSpeech = false; recordTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in self.recorder?.updateMeters(); if (self.recorder?.peakPower(forChannel: 0) ?? -160) > -42 { self.heardSpeech = true } }; DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.finishWindow(file) } } catch { setStatus(error.localizedDescription); stopLocal() }
    }
    func finishWindow(_ file: URL) { guard listening else { try? FileManager.default.removeItem(at: file); return }; recorder?.stop(); recordTimer?.invalidate(); let send = heardSpeech; recorder = nil; if send { api.upload(file, connectionID: connectionID) { result in if case .failure(let error) = result { self.setStatus(error.localizedDescription) } } } else { try? FileManager.default.removeItem(at: file) }; recordWindow() }
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
