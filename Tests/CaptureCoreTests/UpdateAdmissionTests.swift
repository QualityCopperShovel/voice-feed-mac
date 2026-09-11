import XCTest
@testable import CaptureCore
final class UpdateAdmissionTests: XCTestCase {
    func testDuplicateChecksAndNextLaunchInstallation() {
        let updates = UpdateAdmission(currentVersion: "1.4.9")
        XCTAssertTrue(updates.begin()); XCTAssertFalse(updates.begin())
        XCTAssertTrue(updates.isNewer("1.4.10"))
        updates.installed("1.4.10"); updates.finish()
        XCTAssertEqual(updates.stagedVersion, "1.4.10")
        XCTAssertTrue(updates.begin()); XCTAssertFalse(updates.isNewer("1.4.10"))
        XCTAssertFalse(updates.isNewer("1.4.9")); XCTAssertTrue(updates.isNewer("1.5.0"))
        updates.finish(); XCTAssertTrue(updates.begin())
    }
}
