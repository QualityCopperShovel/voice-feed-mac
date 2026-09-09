import Foundation

/// Small synchronous writes survive a sudden process exit. Never pass audio,
/// transcripts, credentials, or arbitrary provider responses to this journal.
public final class DiagnosticJournal: @unchecked Sendable {
    public let directory: URL
    private let lock = NSLock()
    private let maxBytes: Int
    private let copies: Int
    private let sessionID = UUID().uuidString
    private let version: String
    private var marker: URL { directory.appendingPathComponent("active-session.json") }
    private var log: URL { directory.appendingPathComponent("events.jsonl") }

    public init(directory: URL, version: String, maxBytes: Int = 512 * 1024, copies: Int = 4) throws {
        guard maxBytes > 0, copies > 0 else { throw CocoaError(.fileWriteInvalidFileName) }
        self.directory = directory; self.version = version
        self.maxBytes = maxBytes; self.copies = copies
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }
    public func begin() throws {
        if FileManager.default.fileExists(atPath: marker.path) {
            try record("previous_unclean_exit")
        }
        let data = try JSONSerialization.data(withJSONObject: ["session": sessionID, "version": version])
        try data.write(to: marker, options: .atomic)
        try record("process_started")
    }
    public func end() throws {
        try record("process_exiting")
        if FileManager.default.fileExists(atPath: marker.path) { try FileManager.default.removeItem(at: marker) }
    }
    public func snapshot() throws -> [[String: String]] {
        lock.lock(); defer { lock.unlock() }
        var rows: [[String: String]] = []
        for index in stride(from: copies, through: 0, by: -1) {
            let file = index == 0 ? log : directory.appendingPathComponent("events.\(index).jsonl")
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            let data = try Data(contentsOf: file)
            for line in data.split(separator: 10) {
                if let row = try JSONSerialization.jsonObject(with: Data(line)) as? [String: String] {
                    rows.append(DiagnosticEvidence.sanitized(row))
                }
            }
        }
        return rows
    }
    public func record(_ event: String, fields: [String: String] = [:]) throws {
        lock.lock(); defer { lock.unlock() }
        var row = fields.mapValues { String($0.prefix(160)) }
        row["event"] = String(event.prefix(80)); row["session"] = sessionID
        row["version"] = version; row["timestamp"] = ISO8601DateFormatter().string(from: Date())
        var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        data.append(10)
        let manager = FileManager.default
        let size = (try? manager.attributesOfItem(atPath: log.path)[.size] as? NSNumber)?.intValue ?? 0
        if size + data.count > maxBytes {
            for index in stride(from: copies, through: 1, by: -1) {
                let target = directory.appendingPathComponent("events.\(index).jsonl")
                let source = index == 1 ? log : directory.appendingPathComponent("events.\(index - 1).jsonl")
                if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
                if manager.fileExists(atPath: source.path) { try manager.moveItem(at: source, to: target) }
            }
        }
        if !manager.fileExists(atPath: log.path) {
            guard manager.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: data); try handle.synchronize()
    }
}
