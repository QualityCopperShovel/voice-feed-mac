import XCTest
@testable import CaptureCore

final class DiagnosticEvidenceTests: XCTestCase {
    func testAllowlistRemovesPayloadAndCredentials() {
        let row = DiagnosticEvidence.sanitized(["event":"capture_failed", "audio":"secret", "token":"secret", "domain":"vf_capture_secret"])
        XCTAssertNil(row["audio"]); XCTAssertNil(row["token"])
        XCTAssertEqual(row["domain"], "[redacted]")
    }
    func testCrashSummaryKeepsFaultSymbolsWithoutMemoryOrPaths() throws {
        let header: [String: Any] = ["incident_id":"incident", "app_version":"1.4.5", "timestamp":"2026-09-09 16:18:09.0000 +0000"]
        let body: [String: Any] = ["procName":"VoiceFeedMac", "procPath":"/Users/private/VoiceFeedMac", "exception":["type":"EXC_BAD_ACCESS", "signal":"SIGSEGV"], "threads":[["triggered":true, "frames":[["imageIndex":0,"symbol":"LiveCapture.capture", "imageOffset":123]],"registers":"private"]], "usedImages":[["name":"VoiceFeedMac","uuid":"image-id","path":"/Users/private/app"]]]
        var data = try JSONSerialization.data(withJSONObject:header); data.append(10)
        data.append(try JSONSerialization.data(withJSONObject:body))
        let row = try XCTUnwrap(DiagnosticEvidence.crash(data))
        XCTAssertEqual(row["exception_type"],"EXC_BAD_ACCESS")
        XCTAssertEqual(row["timestamp"],"2026-09-09T16:18:09Z")
        XCTAssertTrue(row["frames"]!.contains("LiveCapture.capture"))
        XCTAssertFalse(String(describing:row).contains("private"))
    }
    func testTruncatedCrashTimeJournalDoesNotBlockEarlierEvidence() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:dir) }
        let journal = try DiagnosticJournal(directory:dir,version:"1.4.6")
        try journal.begin(); try journal.record("capture_failed")
        let handle = try FileHandle(forWritingTo:dir.appendingPathComponent("events.jsonl"))
        try handle.seekToEnd(); try handle.write(contentsOf:Data("{broken".utf8)); try handle.close()
        let rows = try journal.snapshot()
        XCTAssertTrue(rows.contains { $0["event"] == "capture_failed" })
        XCTAssertTrue(rows.contains { $0["event"] == "journal_record_unreadable" })
    }
    func testLongAssertionSurvivesJournalAndSensitiveValuesAreRedacted() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:dir) }
        let journal = try DiagnosticJournal(directory:dir,version:"1.4.8")
        let reason = String(repeating:"hardware format mismatch; ",count:20) + "vf_capture_secret /Users/private/device https://private.example/a token=secret person@example.com"
        try journal.record("capture_failed", fields:["exception_name":"com.apple.coreaudio.avfaudio", "exception_reason":reason])
        let row = try XCTUnwrap(journal.snapshot().first)
        XCTAssertGreaterThan(row["exception_reason"]!.count,160)
        XCTAssertTrue(row["exception_reason"]!.contains("hardware format mismatch"))
        XCTAssertFalse(String(describing:row).contains("private"))
        XCTAssertFalse(String(describing:row).contains("secret"))
        XCTAssertFalse(String(describing:row).contains("person@"))
    }
    func testCrashIncludesApplicationMessageAndOriginalExceptionFrames() throws {
        let header:[String:Any] = ["incident_id":"incident", "app_version":"1.4.5", "timestamp":"2026-09-09 16:18:09.0000 +0000"]
        let body:[String:Any] = ["procName":"VoiceFeedMac", "exception":["message":"native exception message"],
            "asi":["AVFAudio":["required condition is false: format.sampleRate == hwFormat.sampleRate at /Users/private/file"], "unrelated":["secret payload"]],
            "lastExceptionBacktrace":[["imageIndex":0,"symbol":"OriginalThrowSite"]], "usedImages":[["name":"AVFAudio"]]]
        var data = try JSONSerialization.data(withJSONObject:header); data.append(10); data.append(try JSONSerialization.data(withJSONObject:body))
        let row = try XCTUnwrap(DiagnosticEvidence.crash(data))
        XCTAssertEqual(row["exception_message"],"native exception message")
        XCTAssertTrue(row["application_info"]!.contains("format.sampleRate == hwFormat.sampleRate"))
        XCTAssertTrue(row["exception_frames"]!.contains("OriginalThrowSite"))
        XCTAssertFalse(String(describing:row).contains("private")); XCTAssertFalse(String(describing:row).contains("secret payload"))
        XCTAssertEqual(row["exception_detail_status"],"available")
    }
    func testJournalSnapshotIncludesEarlierRunsAndRotations() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:dir) }
        let journal = try DiagnosticJournal(directory:dir,version:"1",maxBytes:500)
        try journal.begin(); try journal.record("capture_failed",fields:["domain":"test","code":"1"])
        let relaunched = try DiagnosticJournal(directory:dir,version:"2",maxBytes:500)
        try relaunched.begin()
        let rows = try relaunched.snapshot()
        XCTAssertTrue(rows.contains { $0["event"] == "capture_failed" })
        XCTAssertTrue(rows.contains { $0["event"] == "previous_unclean_exit" })
    }
}

final class DiagnosticUploadAttemptTests: XCTestCase {
    func testNeverResolvingUploadTimesOutAndAllowsRetry() throws {
        var owner = DiagnosticUploadAttempt(); let now = Date()
        let first = try XCTUnwrap(owner.begin(now: now))
        XCTAssertNil(owner.begin(now: now))
        XCTAssertFalse(owner.expire(first, now: now.addingTimeInterval(49)))
        XCTAssertTrue(owner.expire(first, now: now.addingTimeInterval(50)))
        XCTAssertEqual(owner.state, "timed_out")
        let retry = try XCTUnwrap(owner.begin(now: now.addingTimeInterval(60)))
        XCTAssertFalse(owner.finish(first, success: true))
        XCTAssertTrue(owner.finish(retry, success: false)); XCTAssertEqual(owner.state,"failed")
        let next = try XCTUnwrap(owner.begin()); XCTAssertTrue(owner.finish(next, success: true))
        XCTAssertEqual(owner.state,"completed")
    }
}
