import XCTest
@testable import CaptureCore

final class RecoveryAudioTests: XCTestCase {
    func testAudioIsReadableBeforeCleanShutdownAndPrivate() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try RecoveryAudio(directory: directory)
        let pcm = Data([1,0,2,0,3,0])
        try writer.append(pcm)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let bytes = try Data(contentsOf: file)
        XCTAssertEqual(String(data: bytes.prefix(4), encoding: .utf8), "RIFF")
        XCTAssertEqual(bytes.dropFirst(44), pcm)
        XCTAssertEqual(bytes[40], 6)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        try writer.close()
    }
    func testSegmentRolloverPreservesAllSamplesAndRetentionIsBounded() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try RecoveryAudio(directory: directory, maxFiles: 2, segmentBytes: 4)
        try writer.append(Data([1,0,2,0,3,0,4,0])); try writer.close()
        var files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(try files.flatMap { Array(try Data(contentsOf: $0).dropFirst(44)) }, [1,0,2,0,3,0,4,0])
        try writer.append(Data([5,0,6,0])); try writer.close()
        files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 2)
    }
    func testUnwritableDestinationFailsRatherThanClaimingBackupExists() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data([1]).write(to: file)
        XCTAssertThrowsError(try RecoveryAudio(directory: file))
    }
}
