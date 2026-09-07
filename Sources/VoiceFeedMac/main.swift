import AppKit
import AVFoundation
import CryptoKit
import Security
import OSLog

// Voice Feed streams continuous microphone audio over an authenticated WebSocket.
// It retains no recordings and drains final transcription before stopping.
let baseURL = URL(string: "https://voice-feed.aisloppy.com")!
let clientVersion = "1.4.0"
let captureLog = Logger(subsystem: "com.aisloppy.voice-feed", category: "capture")
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

// Updates are announced by Voice Feed's own HTTPS origin. Only the published,
// notarized app archive is accepted, after its SHA-256 and Apple signature are
// verified. The bundle is replaced with rollback and Keychain data is untouched.
final class AutoUpdater {
    struct Manifest: Decodable { let version: String; let download_url: String; let download_sha256: String; let notarized: Bool }
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
    func check(announce: Bool = false) {
        var request = URLRequest(url: URL(string: "/client-version.json", relativeTo: baseURL)!); request.timeoutInterval = 15
        session.dataTask(with: request) { data, response, error in
            guard error == nil, (response as? HTTPURLResponse)?.statusCode == 200, let data, let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { if announce { self.status("Update check failed") }; return }
            guard self.isNewer(manifest.version) else { if announce { self.status("Voice Feed is up to date") }; return }
            guard manifest.notarized, let downloadURL = URL(string: manifest.download_url), downloadURL.scheme == "https" else { self.status("Update manifest is invalid"); return }
            var downloadRequest = URLRequest(url: downloadURL); downloadRequest.timeoutInterval = 30
            self.session.dataTask(with: downloadRequest) { payload, downloadResponse, downloadError in
                guard downloadError == nil, (downloadResponse as? HTTPURLResponse)?.statusCode == 200, let payload else { self.status("Update download failed"); return }
                let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
                guard digest == manifest.download_sha256.lowercased() else { self.status("Update verification failed"); return }
                let archive = FileManager.default.temporaryDirectory.appendingPathComponent("voice-feed-update-\(UUID().uuidString).zip")
                do { try payload.write(to: archive, options: .atomic); self.install(archive) } catch { self.status("Update could not be saved") }
            }.resume()
        }.resume()
    }
    private func run(_ executable: String, _ arguments: [String], deadline: TimeInterval = 120) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        let output = Pipe(); process.standardOutput = output; process.standardError = output
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + deadline, execute: timeout)
        process.waitUntilExit(); timeout.cancel()
        guard process.terminationStatus == 0 else {
            let detail = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.split(whereSeparator: { $0.isNewline }).last.map(String.init)
            throw NSError(domain: "VoiceFeedUpdate", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: detail ?? "Verification failed"])
        }
    }
    private func install(_ archive: URL) {
        DispatchQueue.main.async { self.status("Installing Voice Feed update…") }
        DispatchQueue.global(qos: .userInitiated).async {
            let manager = FileManager.default
            let work = manager.temporaryDirectory.appendingPathComponent("voice-feed-update-\(UUID().uuidString)", isDirectory: true)
            let staged = work.appendingPathComponent("Voice Feed.app", isDirectory: true)
            let target = Bundle.main.bundleURL
            let backup = target.deletingLastPathComponent().appendingPathComponent("Voice Feed.previous.app", isDirectory: true)
            defer { try? manager.removeItem(at: archive); try? manager.removeItem(at: work) }
            do {
                try manager.createDirectory(at: work, withIntermediateDirectories: true)
                try self.run("/usr/bin/ditto", ["-x", "-k", archive.path, work.path])
                guard manager.fileExists(atPath: staged.appendingPathComponent("Contents/MacOS/VoiceFeedMac").path) else { throw NSError(domain: "VoiceFeedUpdate", code: 2, userInfo: [NSLocalizedDescriptionKey: "Downloaded app is incomplete"]) }
                try self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged.path])
                try self.run("/usr/sbin/spctl", ["--assess", "--type", "execute", staged.path])
                if manager.fileExists(atPath: backup.path) { try manager.removeItem(at: backup) }
                if manager.fileExists(atPath: target.path) { try manager.moveItem(at: target, to: backup) }
                do { try manager.moveItem(at: staged, to: target) } catch {
                    if manager.fileExists(atPath: backup.path) { try? manager.moveItem(at: backup, to: target) }
                    throw error
                }
                try? manager.removeItem(at: backup)
                let relaunch = Process(); relaunch.executableURL = URL(fileURLWithPath: "/bin/sh"); relaunch.arguments = ["-c", "sleep 1; /usr/bin/open \"$1\"", "voice-feed-relaunch", target.path]
                try relaunch.run(); DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
            } catch {
                self.status("Update failed: \(error.localizedDescription)")
            }
        }
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

}

// AppDelegate owns the menu-bar UI, account pairing, exclusive capture lease,
// microphone permission, and the bounded recording loop.
final class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    let api = API(), keychain = Keychain(), statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    var live: LiveCapture?, leaseTimer: Timer?, reconnectWorkItem: DispatchWorkItem?
    var connectionID = UUID().uuidString.replacingOccurrences(of: "-", with: ""), listening = false, desiredListening = false, leaseRenewalInFlight = false, hasEstablishedLease = false, reconnectAttempt = 0, statusRevision = 0
    var quitting = false, rotating = false
    let status = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: ""), connect = NSMenuItem(title: "Connect this Mac…", action: #selector(connectDevice), keyEquivalent: ""), start = NSMenuItem(title: "Start listening", action: #selector(startListening), keyEquivalent: ""), stop = NSMenuItem(title: "Stop listening", action: #selector(stopListening), keyEquivalent: ""), update = NSMenuItem(title: "Check for updates", action: #selector(checkForUpdates), keyEquivalent: ""), version = NSMenuItem(title: "Version \(clientVersion)", action: nil, keyEquivalent: "")
    lazy var updater = AutoUpdater { [weak self] message in self?.setUpdateStatus(message) }
    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem.button?.image = voiceFeedStatusImage()
        statusItem.button?.image?.accessibilityDescription = "Voice Feed"
        let devices = NSMenuItem(title: "Open Devices…", action: #selector(openDevices), keyEquivalent: ""), quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        [status, connect, start, stop, update, devices, quitItem].forEach { $0.target = self }
        status.action = #selector(dismissStatus)
        let menu = NSMenu(); [status, .separator(), connect, start, stop, .separator(), devices, update, version, quitItem].forEach(menu.addItem); statusItem.menu = menu
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
    func applyStatus(_ text: String) { statusRevision += 1; let oneLine = text.replacingOccurrences(of: "\n", with: " "), limit = 56; status.title = oneLine.count > limit ? String(oneLine.prefix(limit - 1)) + "…" : oneLine; refreshMenu() }
    func setStatus(_ text: String) { DispatchQueue.main.async { self.applyStatus(text) } }
    func setUpdateStatus(_ text: String) { DispatchQueue.main.async {
        self.applyStatus(text)
        if text.hasPrefix("Checking") || text.hasPrefix("Installing") {
            self.update.title = text; self.update.isEnabled = false
        } else if text.lowercased().contains("failed") || text.lowercased().contains("could not") {
            self.update.title = "Update failed — click to retry"; self.update.isEnabled = true
        } else {
            self.update.title = text; self.update.isEnabled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                if self.update.title == text { self.update.title = "Check for updates" }
            }
        }
    } }
    func setTransientStatus(_ text: String) { DispatchQueue.main.async { self.applyStatus(text); let revision = self.statusRevision; DispatchQueue.main.asyncAfter(deadline: .now() + 8) { if revision == self.statusRevision && self.desiredListening { self.applyStatus("Listening") } } } }
    @objc func dismissStatus() { setStatus(desiredListening ? "Listening" : "Paused") }
    @objc func checkForUpdates() { setUpdateStatus("Checking for update…"); updater.check(announce: true) }
    func refreshMenu() { connect.isHidden = api.token != nil; start.isHidden = api.token == nil || desiredListening; stop.isHidden = !desiredListening }
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
        guard api.token != nil, !desiredListening else { return }
        desiredListening = true; reconnectAttempt = 0; reconnectWorkItem?.cancel(); refreshMenu(); setStatus("Requesting microphone…")
        AVCaptureDevice.requestAccess(for: .audio) { allowed in DispatchQueue.main.async { if allowed { self.enableAndLease() } else { self.desiredListening = false; self.setStatus("Microphone access denied") } } }
    }
    // The renewable server lease prevents two devices from owning one account's
    // microphone feed simultaneously. Transient server and network failures
    // stop local capture, then reacquire the lease with bounded backoff.
    func enableAndLease() {
        guard desiredListening, !listening else { return }
        api.request("/api/device/preference", method: "PUT", json: ["enabled": true]) { result in
            DispatchQueue.main.async {
                guard self.desiredListening else { return }
                if case .failure(let error) = result { self.scheduleReconnect(after: error); return }
                self.api.request("/api/device/lease", method: "POST", json: ["connection_id": self.connectionID]) { lease in
                    DispatchQueue.main.async {
                        guard self.desiredListening else { return }
                        switch lease {
                        case .failure(let error): self.scheduleReconnect(after: error)
                        case .success:
                            self.reconnectWorkItem?.cancel(); self.reconnectWorkItem = nil; self.reconnectAttempt = 0; self.listening = true; self.hasEstablishedLease = true
                            self.setStatus("Listening"); self.leaseTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in self.renewLease() }; self.startLiveCapture()
                        }
                    }
                }
            }
        }
    }
    func renewLease() {
        guard listening, !leaseRenewalInFlight else { return }
        leaseRenewalInFlight = true
        api.request("/api/device/lease/\(connectionID)", method: "PUT") { result in
            DispatchQueue.main.async {
                self.leaseRenewalInFlight = false
                if case .failure(let error) = result { self.scheduleReconnect(after: error) }
            }
        }
    }
    func scheduleReconnect(after error: Error) {
        guard desiredListening else { return }
        let failure = error as NSError
        if failure.domain == "VoiceFeed" && [401, 403, 410, 422].contains(failure.code) {
            desiredListening = false; stopCapture(); setStatus(error.localizedDescription); return
        }
        stopCapture(); reconnectWorkItem?.cancel(); reconnectAttempt += 1
        let delay = min(pow(2.0, Double(reconnectAttempt - 1)), 30.0)
        if hasEstablishedLease {
            setStatus("\(error.localizedDescription). Retrying in \(Int(delay))s…")
        } else if reconnectAttempt <= 2 {
            setStatus("Connecting… retrying in \(Int(delay))s")
        } else {
            setStatus("Connection unavailable. Retrying in \(Int(delay))s…")
        }
        let work = DispatchWorkItem { [weak self] in self?.enableAndLease() }
        reconnectWorkItem = work; DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    func startLiveCapture() {
        guard let token=api.token else { return }
        setStatus("Connecting live transcription…")
        live=LiveCapture(token:token,connectionID:connectionID,
            onReady: { self.setStatus("Listening") },
            onFailure: { error in
                if self.desiredListening { self.scheduleReconnect(after:error) }
                else { self.finishStop(error:error) }
            },
            onComplete: {
                if self.rotating && self.desiredListening {
                    self.rotating=false; self.live=nil; self.startLiveCapture()
                } else { self.finishStop() }
            },
            onRotate: { self.rotating=true; self.setStatus("Finishing words before reconnecting…") })
        live?.start()
    }
    @objc func stopListening() {
        desiredListening=false; reconnectAttempt=0; reconnectWorkItem?.cancel(); reconnectWorkItem=nil; refreshMenu()
        if let live {
            setStatus("Finishing last words…"); live.stop()
        } else { finishStop() }
    }
    func finishStop(error:Error? = nil) {
        stopCapture()
        api.request("/api/device/lease/\(connectionID)",method:"DELETE") { _ in }
        setStatus(error?.localizedDescription ?? "Paused")
        if quitting { NSApplication.shared.terminate(nil) }
    }
    func stopCapture() {
        live?.cancel(); live=nil; listening=false; rotating=false
        leaseTimer?.invalidate(); leaseTimer=nil; refreshMenu()
    }
    @objc func quit() { quitting=true; stopListening() }
}
