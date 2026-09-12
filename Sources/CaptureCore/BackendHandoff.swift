import Foundation

/// A ready socket identifies its backend; lease reads discover the routed successor.
/// Request start times exclude replies issued before the latest socket became ready.
public struct BackendHandoff {
    public private(set) var currentRevision: String?
    public private(set) var pendingRevision: String?
    private var connectedAt: TimeInterval = 0
    public init() {}
    public static func revision(in response: [String: Any]) throws -> String? {
        guard let value = response["backend_revision"], !(value is NSNull) else { return nil }
        guard let revision = value as? String,
              revision.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil else {
            throw NSError(domain: "VoiceFeed", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid backend revision in capture response."])
        }
        return revision
    }
    public mutating func connected(revision: String?, at time: TimeInterval) {
        currentRevision = revision; connectedAt = time; pendingRevision = nil
    }
    public mutating func observe(revision: String?, requestStarted: TimeInterval) -> Bool {
        guard let revision, let currentRevision, revision != currentRevision,
              requestStarted >= connectedAt, pendingRevision == nil else { return false }
        pendingRevision = revision
        return true
    }
}
