import AppKit
import CaptureCore
import OSLog
import CryptoKit

final class MacDiagnostics: @unchecked Sendable {
    static let shared = MacDiagnostics()
    let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Voice Feed", isDirectory: true)
    private var journal: DiagnosticJournal?
    private let logger = Logger(subsystem: "com.aisloppy.voice-feed", category: "diagnostics")
    private init() {
        do {
            journal = try DiagnosticJournal(directory: directory, version: clientVersion)
            try journal?.begin()
        } catch { logger.error("Cannot initialize diagnostic log: \(error.localizedDescription, privacy: .public)") }
    }
    func record(_ event: String, fields: [String: String] = [:]) {
        do { try journal?.record(event, fields: fields) }
        catch { logger.error("Cannot write diagnostic log: \(error.localizedDescription, privacy: .public)") }
    }
    func failure(_ event: String, _ error: Error) {
        let error = error as NSError
        record(event, fields: ["domain": error.domain, "code": String(error.code)])
    }
    private var uploadAttempt = DiagnosticUploadAttempt()
    private let worker = DispatchQueue(label: "voice-feed.diagnostics-upload")
    func sync(api: API, status: @escaping (String) -> Void) {
        guard api.token != nil, let attempt = uploadAttempt.begin() else { return }
        status("Diagnostics: syncing…")
        // API's resource timeout is 40 seconds; bound collection plus upload too.
        DispatchQueue.main.asyncAfter(deadline: .now() + 50) {
            guard self.uploadAttempt.expire(attempt) else { return }
            status("Diagnostics: timed out; retries automatically")
        }
        worker.async {
            do {
                let checkpoint = self.directory.appendingPathComponent("uploaded-events.json")
                var acknowledged = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: checkpoint))) ?? []
                let known = Set(acknowledged)
                var rows = try self.journal?.snapshot() ?? []
                let reports = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
                let files = (try? FileManager.default.contentsOfDirectory(at: reports, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
                for file in files.filter({ $0.pathExtension == "ips" && $0.lastPathComponent.hasPrefix("VoiceFeedMac") }).sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).prefix(20) {
                    let values = try file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                    guard (values.fileSize ?? 0) <= 5_000_000, let modified = values.contentModificationDate, modified > Date().addingTimeInterval(-30*86400) else { continue }
                    if let row = try DiagnosticEvidence.crash(Data(contentsOf: file)) { rows.append(row) }
                }
                var batch: [[String: String]] = []
                for var row in rows {
                    let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
                    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    guard !known.contains(digest) else { continue }
                    row["event_hash"] = digest; batch.append(row)
                    if batch.count == 100 { break }
                }
                let upload = batch
                DispatchQueue.main.async {
                    guard self.uploadAttempt.id == attempt else { return }
                    guard !upload.isEmpty else { self.uploadAttempt.finish(attempt, success: true); status("Diagnostics: synced"); return }
                    api.request("/api/device/diagnostics", method: "POST", json: ["events": upload]) { result in
                        self.worker.async {
                            do {
                                let reply = try result.get()
                                let expected = upload.compactMap { $0["event_hash"] }
                                guard let accepted = reply["accepted"] as? [String], accepted == expected else {
                                    throw NSError(domain: "VoiceFeedDiagnostics", code: 1)
                                }
                                acknowledged.append(contentsOf: accepted)
                                try JSONEncoder().encode(Array(acknowledged.suffix(10000))).write(to: checkpoint, options: .atomic)
                                DispatchQueue.main.async {
                                    guard self.uploadAttempt.id == attempt else { return }
                                    self.uploadAttempt.finish(attempt, success: true); status("Diagnostics: synced")
                                }
                            } catch {
                                DispatchQueue.main.async {
                                    guard self.uploadAttempt.id == attempt else { return }
                                    self.uploadAttempt.finish(attempt, success: false)
                                    status("Diagnostics: upload failed (\((error as NSError).domain) \((error as NSError).code)); retries automatically")
                                }
                            }
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.uploadAttempt.id == attempt else { return }
                    self.uploadAttempt.finish(attempt, success: false)
                    status("Diagnostics: collection failed (\((error as NSError).code)); retries automatically")
                }
            }
        }
    }
    func finish() {
        do { try journal?.end() }
        catch { logger.error("Cannot finish diagnostic log: \(error.localizedDescription, privacy: .public)") }
    }
}
