import Foundation
import XCTest
@testable import MeshBarCore

final class RefreshGateTests: XCTestCase {
    func testIdleRequestStartsImmediately() {
        var gate = RefreshGate()
        XCTAssertEqual(gate.request(forceBackhaul: true, userInitiated: true), .start(forceBackhaul: true, userInitiated: true))
        XCTAssertTrue(gate.inFlight)
        XCTAssertNil(gate.finish())
        XCTAssertFalse(gate.inFlight)
    }

    func testManualRefreshDuringAutomaticPollRunsRightAfter() {
        var gate = RefreshGate()
        XCTAssertEqual(gate.request(), .start(forceBackhaul: false, userInitiated: false))
        // User clicks Refresh while the timer poll is still running.
        XCTAssertEqual(gate.request(forceBackhaul: true, userInitiated: true), .queued)
        XCTAssertTrue(gate.queued)
        // The click is not dropped: the follow-up keeps its manual flags.
        XCTAssertEqual(gate.finish(), .start(forceBackhaul: true, userInitiated: true))
        XCTAssertTrue(gate.inFlight, "the follow-up poll holds the gate")
        XCTAssertFalse(gate.queued)
        XCTAssertNil(gate.finish())
        XCTAssertFalse(gate.inFlight)
    }

    func testBurstOfRequestsCollapsesIntoOneFollowUp() {
        var gate = RefreshGate()
        _ = gate.request()
        for _ in 0..<10 {
            XCTAssertEqual(gate.request(forceBackhaul: false, userInitiated: true), .queued)
        }
        XCTAssertEqual(gate.finish(), .start(forceBackhaul: false, userInitiated: true))
        XCTAssertNil(gate.finish(), "ten clicks make one extra poll, not ten")
    }

    func testQueuedFlagsMerge() {
        var gate = RefreshGate()
        _ = gate.request()
        _ = gate.request(forceBackhaul: true, userInitiated: false)
        _ = gate.request(forceBackhaul: false, userInitiated: true)
        XCTAssertEqual(gate.finish(), .start(forceBackhaul: true, userInitiated: true))
    }

    func testFinishWhenIdleIsHarmless() {
        var gate = RefreshGate()
        XCTAssertNil(gate.finish())
        XCTAssertEqual(gate.request(), .start(forceBackhaul: false, userInitiated: false))
    }

    func testBackhaulRefreshPolicy() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertTrue(RefreshGate.shouldRefreshBackhaul(force: false, last: nil, now: now))
        XCTAssertFalse(RefreshGate.shouldRefreshBackhaul(force: false, last: now.addingTimeInterval(-60), now: now))
        XCTAssertTrue(RefreshGate.shouldRefreshBackhaul(force: true, last: now.addingTimeInterval(-5), now: now), "manual refresh always re-measures")
        XCTAssertTrue(RefreshGate.shouldRefreshBackhaul(force: false, last: now.addingTimeInterval(-301), now: now))
    }

    func testAgoNeverSaysInTheFuture() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertEqual(RefreshClock.ago(now.addingTimeInterval(0.4), now: now), "just now")
        XCTAssertEqual(RefreshClock.ago(now.addingTimeInterval(-2), now: now), "just now")
        XCTAssertEqual(RefreshClock.ago(now.addingTimeInterval(-12), now: now), "12s ago")
        XCTAssertEqual(RefreshClock.ago(now.addingTimeInterval(-190), now: now), "3m ago")
        XCTAssertEqual(RefreshClock.ago(now.addingTimeInterval(-7200), now: now), "2h ago")
    }
}
