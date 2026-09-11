import XCTest
@testable import CaptureCore

final class UpdateRelaunchTests: XCTestCase {
    func testSuccessfulActivationDrainsReleasesThenLaunchesExactlyOnce() {
        let finished = expectation(description: "completed")
        var order: [String] = []
        var drain: UpdateRelaunch.Completion?
        let owner = UpdateRelaunch(drain: { done in
            order.append("drain"); drain = done; return {}
        }, release: { done in
            order.append("release"); done(.success(())); return {}
        }, launch: { done in
            order.append("launch"); done(.success(())); return {}
        }, changed: { _, _ in }, finished: { success in
            XCTAssertTrue(success); order.append("terminate"); finished.fulfill()
        })
        XCTAssertTrue(owner.start()); XCTAssertFalse(owner.start())
        XCTAssertEqual(order, ["drain"])
        drain?(.success(())); drain?(.success(()))
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(order, ["drain", "release", "launch", "terminate"])
        XCTAssertEqual(owner.state, .completed); XCTAssertFalse(owner.start())
    }
    func testEveryNeverResolvingStepFailsAndCancelsOwnedWork() {
        for stalled in 0..<3 {
            let finished = expectation(description: "step \(stalled) timed out")
            var calls = 0, cancelled = 0
            var errorMessage: String?
            let operation: UpdateRelaunch.Operation = { done in
                let index = calls; calls += 1
                if index != stalled { done(.success(())) }
                return { cancelled += 1 }
            }
            let owner = UpdateRelaunch(drain: operation, release: operation, launch: operation,
                limits: [0.03, 0.03, 0.03], overallLimit: 1,
                changed: { _, message in errorMessage = message },
                finished: { success in XCTAssertFalse(success); finished.fulfill() })
            owner.start(); wait(for: [finished], timeout: 2)
            XCTAssertEqual(owner.state, .failed); XCTAssertFalse(owner.running)
            XCTAssertEqual(calls, stalled + 1); XCTAssertEqual(cancelled, 1)
            XCTAssertTrue(errorMessage?.contains("timed out during") == true)
        }
    }
    func testConcreteFailureKeepsOldProcessAndRetryIgnoresLostWorkerCallback() {
        let failed = expectation(description: "failed")
        let completed = expectation(description: "retry completed")
        var prior: UpdateRelaunch.Completion?
        var drains = 0, launches = 0, recoveries = 0, terminations = 0
        var message: String?
        let owner = UpdateRelaunch(drain: { done in
            drains += 1
            if drains == 1 { prior = done; done(.failure(NSError(domain: "test", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Provider lost final words"]))) }
            else { done(.success(())) }
            return {}
        }, release: { done in done(.success(())); return {} },
        launch: { done in launches += 1; done(.success(())); return {} },
        changed: { _, error in if let error { message = error } },
        finished: { success in
            if success { terminations += 1; completed.fulfill() }
            else { recoveries += 1; failed.fulfill() }
        })
        owner.start(); wait(for: [failed], timeout: 2)
        XCTAssertEqual(terminations, 0); XCTAssertEqual(launches, 0)
        XCTAssertTrue(message?.contains("Provider lost final words") == true)
        XCTAssertTrue(owner.start()); prior?(.success(()))
        wait(for: [completed], timeout: 2)
        XCTAssertEqual(recoveries, 1); XCTAssertEqual(launches, 1); XCTAssertEqual(terminations, 1)
    }
    func testOverallDeadlineAndCancellationIgnoreDelayedLaunch() {
        let failed = expectation(description: "overall deadline")
        let late = expectation(description: "late callback ignored")
        var doneLaunching: UpdateRelaunch.Completion?
        var completions = 0, abandoned = 0
        let owner = UpdateRelaunch(drain: { done in done(.success(())); return {} },
            release: { done in done(.success(())); return {} },
            launch: { done in doneLaunching = done; return { abandoned += 1 } },
            limits: [1, 1, 1], overallLimit: 0.03,
            changed: { _, _ in }, finished: { success in
                XCTAssertFalse(success); completions += 1; failed.fulfill()
            })
        owner.start(); wait(for: [failed], timeout: 2)
        owner.cancel("cancel again"); doneLaunching?(.success(()))
        DispatchQueue.main.async { late.fulfill() }
        wait(for: [late], timeout: 2)
        XCTAssertEqual(completions, 1); XCTAssertEqual(abandoned, 1); XCTAssertEqual(owner.state, .failed)
    }
    func testSleepOrQuitCancelsDrainWithoutAdvancing() {
        var recoveries = 0, abandoned = 0
        let owner = UpdateRelaunch(drain: { _ in return { abandoned += 1 } },
            release: { _ in XCTFail("must not release"); return {} },
            launch: { _ in XCTFail("must not launch"); return {} },
            changed: { _, _ in }, finished: { success in XCTAssertFalse(success); recoveries += 1 })
        owner.start(); owner.cancel("sleep"); owner.cancel("sleep")
        XCTAssertEqual(owner.state, .failed); XCTAssertEqual(recoveries, 1); XCTAssertEqual(abandoned, 1)
    }
}
