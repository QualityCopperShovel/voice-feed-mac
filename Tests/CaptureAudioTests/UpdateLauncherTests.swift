import AppKit
import XCTest
@testable import CaptureAudio

final class UpdateLauncherTests: XCTestCase {
    func testMissingApplicationReturnsConcreteFailure() {
        let failed = expectation(description: "LaunchServices failure")
        let cancel = UpdateLauncher.launch(at: URL(fileURLWithPath: "/nonexistent/Voice Feed.app")) { result in
            if case .success = result { XCTFail("missing app must not count as a launch") }
            if case .failure(let error) = result { XCTAssertFalse(error.localizedDescription.isEmpty) }
            failed.fulfill()
        }
        wait(for: [failed], timeout: 15); cancel()
    }
    func testLaunchServicesStartsOwnedAppAndCancellationClosesIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = directory.appendingPathComponent("Activation Probe.app")
        let contents = app.appendingPathComponent("Contents")
        let bin = contents.appendingPathComponent("MacOS")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let identifier = "com.voicefeed.activation-probe." + UUID().uuidString.lowercased()
        let metadata: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleExecutable": "probe",
            "CFBundleName": "Activation Probe", "CFBundlePackageType": "APPL", "LSUIElement": true]
        try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let source = directory.appendingPathComponent("probe.swift")
        try Data("import AppKit\nlet app = NSApplication.shared\napp.setActivationPolicy(.accessory)\napp.run()\n".utf8).write(to: source)
        let compiler = Process(); compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compiler.arguments = ["swiftc", source.path, "-o", bin.appendingPathComponent("probe").path]
        try compiler.run()
        let deadline = DispatchWorkItem { if compiler.isRunning { compiler.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: deadline)
        compiler.waitUntilExit(); deadline.cancel()
        XCTAssertEqual(compiler.terminationStatus, 0)
        let started = expectation(description: "new process launched")
        let cancel = UpdateLauncher.launch(at: app) { result in
            if case .failure(let error) = result { XCTFail(error.localizedDescription) }
            started.fulfill()
        }
        wait(for: [started], timeout: 15)
        let application = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first)
        XCTAssertFalse(application.isTerminated)
        cancel()
        let stopped = expectation(for: NSPredicate { _, _ in application.isTerminated }, evaluatedWith: nil)
        wait(for: [stopped], timeout: 10)
    }
}
