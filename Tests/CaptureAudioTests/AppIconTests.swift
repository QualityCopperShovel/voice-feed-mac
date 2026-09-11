import AppKit
import XCTest

final class AppIconTests: XCTestCase {
    func testMacOSDecodesTheBundledIcon() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let icon = try XCTUnwrap(NSImage(contentsOf: root.appendingPathComponent("Resources/AppIcon.icns")))
        XCTAssertTrue(icon.isValid)
        XCTAssertGreaterThanOrEqual(icon.representations.map(\.pixelsWide).max() ?? 0, 1024)
        for size in [16, 32, 128, 512] {
            var rect = NSRect(x: 0, y: 0, width: size, height: size)
            XCTAssertNotNil(icon.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        }
    }
}
