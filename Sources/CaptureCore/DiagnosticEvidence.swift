import Foundation

/// Only structured lifecycle fields and crash metadata may leave the Mac.
public enum DiagnosticEvidence {
    public static let fields: Set<String> = ["capture_id", "stage", "gate_input_ms", "gate_output_ms", "gate_discarded_ms", "gate_buffer_ms", "gate_open_count", "gate_pause_count", "gate_peak_dbfs", "gate_idle_peak_dbfs", "gate_preroll_ms", "gate_active", "audio_gap_ms", "send_delay_ms", "queue_packets_max", "event", "session", "version", "timestamp", "os", "sample_rate", "channels", "listening", "desired", "domain", "code", "exception_type", "signal", "termination_namespace", "termination_code", "frames", "exception_name", "exception_reason", "exception_message", "exception_frames", "application_info", "exception_detail_status"]
    public static func limit(_ key: String) -> Int {
        if ["frames", "exception_frames"].contains(key) { return 6000 }
        if ["exception_reason", "exception_message", "application_info"].contains(key) { return 2048 }
        return 160
    }
    public static func sanitized(_ row: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in row where fields.contains(key) {
            var text = String(value.prefix(20000))
            // Preserve the assertion around a sensitive token/path instead of dropping it all.
            for pattern in [#"(?i)vf_(?:capture|access|refresh)_[^\s'"<>]+"#,
                            #"(?i)bearer\s+[^\s'"<>]+"#,
                            #"(?i)https?://[^\s'"<>]+"#,
                            #"(?i)/(?:Users|home)/[^\s'"<>]+"#,
                            #"(?i)[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
                            #"(?i)(?:password|secret|api[_-]?key|token)\s*[:=]\s*[^\s,;'"]+"#] {
                text = text.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
            }
            result[key] = String(text.prefix(limit(key)))
        }
        return result
    }
    public static func failure(_ error: Error) -> [String: String] {
        let error = error as NSError
        var row = ["domain":error.domain, "code":String(error.code)]
        // Only the native audio boundary supplies these structured fields.
        if error.domain == "VoiceFeedAudio" {
            for key in ["exception_name", "exception_reason", "exception_frames"] {
                if let value = error.userInfo[key] as? String { row[key] = value }
            }
        }
        return sanitized(row)
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
        func stack(_ frames: [[String: Any]]) -> String {
            frames.prefix(24).map { frame -> String in
                let index = frame["imageIndex"] as? Int ?? -1
                let image = images.indices.contains(index) ? images[index] : [:]
                return [image["name"], image["uuid"], frame["symbol"], frame["symbolLocation"], frame["imageOffset"]]
                    .compactMap { $0.map { String(describing: $0) } }.joined(separator: " · ")
            }.joined(separator: "\n")
        }
        let frames = stack(fault?["frames"] as? [[String: Any]] ?? [])
        var row = ["event": "crash_report", "session": header["incident_id"] as? String ?? "unknown",
                   "version": header["app_version"] as? String ?? "unknown",
                   "timestamp": header["timestamp"] as? String ?? "",
                   "exception_type": exception["type"] as? String ?? "unknown",
                   "signal": exception["signal"] as? String ?? "unknown",
                   "termination_namespace": termination["namespace"] as? String ?? "unknown",
                   "termination_code": termination["code"].map { String(describing: $0) } ?? "unknown", "frames": frames]
        if let message = exception["message"] as? String { row["exception_message"] = message }
        if let backtrace = body["lastExceptionBacktrace"] as? [[String:Any]] {
            row["exception_frames"] = stack(backtrace)
        } else if let backtrace = body["lastExceptionBacktrace"] as? String {
            row["exception_frames"] = backtrace
        }
        let asi = body["asi"] as? [String:Any] ?? [:]
        let modules = ["AVFAudio", "AVFoundation", "VoiceFeedMac", "libc++abi.dylib", "libobjc.A.dylib", "libsystem_c.dylib"]
        var messages: [String] = []
        for module in modules {
            let lines = asi[module] as? [String] ?? (asi[module] as? String).map { [$0] } ?? []
            messages.append(contentsOf: lines.prefix(8).map { "\(module): \(String($0.prefix(2048)))" })
        }
        if !messages.isEmpty { row["application_info"] = messages.joined(separator:"\n") }
        row["exception_detail_status"] = row["application_info"] == nil && row["exception_message"] == nil ? "not_supplied" : "available"
        // Normalize Apple's timestamp for the shared ISO8601 contract.
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSS Z"
        if let date = formatter.date(from: row["timestamp"]!) { row["timestamp"] = ISO8601DateFormatter().string(from: date) }
        return sanitized(row)
    }
}
