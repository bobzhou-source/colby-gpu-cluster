import Foundation
import XCTest
@testable import ColbyGPUCluster

final class ClusterSnapshotTests: XCTestCase {
    func testEmptySnapshotMenuBarSummaryUsesDashAndNoTowers() {
        XCTAssertEqual(ClusterSnapshot.empty.menuBarSummary.text, "—")
        XCTAssertTrue(ClusterSnapshot.empty.menuBarSummary.towers.isEmpty)
    }

    func testNewerMatchingSnapshotReplacesRenderedState() {
        var gate = ServiceSnapshotGate()
        let now = Date(timeIntervalSince1970: 10_000)
        let first = ServiceStatusSnapshot(
            sourceID: "colby-webui",
            attemptID: "attempt-1",
            sequence: 2,
            observedAt: now,
            staleAfter: now.addingTimeInterval(30),
            refreshState: .fresh,
            errors: []
        )
        let stale = ServiceStatusSnapshot(
            sourceID: "colby-webui",
            attemptID: "attempt-1",
            sequence: 1,
            observedAt: now.addingTimeInterval(1),
            staleAfter: now.addingTimeInterval(31),
            refreshState: .fresh,
            errors: []
        )

        XCTAssertTrue(gate.accept(first, now: now))
        XCTAssertFalse(gate.accept(stale, now: now))
        XCTAssertEqual(gate.snapshot?.sequence, 2)
    }

    func testWrongAttemptCannotOverwriteCurrentService() {
        var gate = ServiceSnapshotGate()
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertTrue(gate.accept(ServiceStatusSnapshot(
            sourceID: "colby-webui", attemptID: "attempt-1", sequence: 1,
            observedAt: now, staleAfter: now.addingTimeInterval(30), refreshState: .fresh, errors: []
        ), now: now))
        XCTAssertFalse(gate.accept(ServiceStatusSnapshot(
            sourceID: "colby-webui", attemptID: "attempt-2", sequence: 2,
            observedAt: now, staleAfter: now.addingTimeInterval(30), refreshState: .fresh, errors: []
        ), now: now))
    }

    func testSnapshotBecomesStaleWithoutFetching() {
        var gate = ServiceSnapshotGate()
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertTrue(gate.accept(ServiceStatusSnapshot(
            sourceID: "colby-webui", attemptID: "attempt-1", sequence: 1,
            observedAt: now, staleAfter: now.addingTimeInterval(5), refreshState: .fresh, errors: []
        ), now: now))
        XCTAssertEqual(gate.freshness(at: now.addingTimeInterval(6)), .stale)
    }
}
