import Foundation

/// Only structured lifecycle fields and crash metadata may leave the Mac.
public enum DiagnosticEvidence {
    public static let fields: Set<String> = ["event", "session", "version", "timestamp", "os", "sample_rate", "channels", "listening", "desired", "domain", "code", "exception_type", "signal", "termination_namespace", "termination_code", "frames"]
    public static func sanitized(_ row: [String: String]) -> [String: String] {
        row.filter { fields.contains($0.key) }.mapValues { value in
            let lower = value.lowercased()
            if ["vf_capture_", "vf_access_", "vf_refresh_", "bearer ", "/users/", "https://", "http://"].contains(where: lower.contains) { return "[redacted]" }
            return String(value.prefix(6000))
        }
    }
    public static func crash(_ data: Data) throws -> [String: String]? {
        // Apple's .ips files contain a one-line header followed by a JSON body.
        guard let newline = data.firstIndex(of: 10),
              let header = try JSONSerialization.jsonObject(with: data[..<newline]) as? [String: Any],
              let body = try JSONSerialization.jsonObject(with: data[data.index(after: newline)...]) as? [String: Any] else { return nil }
        guard body["procName"] as? String == "VoiceFeedMac" else { return nil }
        let exception = body["exception"] as? [String: Any] ?? [:]
        let termination = body["termination"] as? [String: Any] ?? [:]
        let threads = body["threads"] as? [[String: Any]] ?? []
        let images = body["usedImages"] as? [[String: Any]] ?? []
        let fault = threads.first(where: { $0["triggered"] as? Bool == true })
        let frames = (fault?["frames"] as? [[String: Any]] ?? []).prefix(24).map { frame -> String in
            let index = frame["imageIndex"] as? Int ?? -1
            let image = images.indices.contains(index) ? images[index] : [:]
            // No paths, registers, application messages, environment or memory.
            return [image["name"], image["uuid"], frame["symbol"], frame["symbolLocation"], frame["imageOffset"]]
                .compactMap { $0.map { String(describing: $0) } }.joined(separator: " · ")
        }.joined(separator: "\n")
        var row = ["event": "crash_report", "session": header["incident_id"] as? String ?? "unknown",
                   "version": header["app_version"] as? String ?? "unknown",
                   "timestamp": header["timestamp"] as? String ?? "",
                   "exception_type": exception["type"] as? String ?? "unknown",
                   "signal": exception["signal"] as? String ?? "unknown",
                   "termination_namespace": termination["namespace"] as? String ?? "unknown",
                   "termination_code": termination["code"].map { String(describing: $0) } ?? "unknown", "frames": frames]
        // Normalize Apple's timestamp for the shared ISO8601 contract.
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSS Z"
        if let date = formatter.date(from: row["timestamp"]!) { row["timestamp"] = ISO8601DateFormatter().string(from: date) }
        return sanitized(row)
    }
}
