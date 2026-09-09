import XCTest
@testable import CaptureCore

final class DiagnosticJournalTests: XCTestCase {
    func testUncleanExitSurvivesRestartAndCleanExitClearsMarker() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try DiagnosticJournal(directory: dir, version: "test")
        try first.begin(); try first.record("capture_start")
        let second = try DiagnosticJournal(directory: dir, version: "test")
        try second.begin(); try second.end()
        let third = try DiagnosticJournal(directory: dir, version: "test")
        try third.begin(); try third.end()
        let text = try String(contentsOf: dir.appendingPathComponent("events.jsonl"))
        XCTAssertEqual(text.components(separatedBy: "previous_unclean_exit").count - 1, 1)
        XCTAssertTrue(text.contains("capture_start"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("active-session.json").path))
    }
    func testRotationIsBoundedAndKeepsValidJSON() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = try DiagnosticJournal(directory: dir, version: "test", maxBytes: 600, copies: 2)
        for _ in 0..<100 { try journal.record("heartbeat") }
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 3)
        for file in files {
            let data = try Data(contentsOf: file)
            XCTAssertLessThanOrEqual(data.count, 600)
            for line in data.split(separator: 10) { XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(line))) }
        }
    }
}
