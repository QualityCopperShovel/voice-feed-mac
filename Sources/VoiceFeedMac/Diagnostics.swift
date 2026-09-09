import AppKit
import CaptureCore
import OSLog

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
    func finish() {
        do { try journal?.end() }
        catch { logger.error("Cannot finish diagnostic log: \(error.localizedDescription, privacy: .public)") }
    }
}
