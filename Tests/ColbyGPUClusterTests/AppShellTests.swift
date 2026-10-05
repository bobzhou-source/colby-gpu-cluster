import Foundation
import XCTest
@testable import ColbyGPUCluster

@MainActor
final class AppShellTests: XCTestCase {
    func testSendableFetchClosureRecordsTrimmedHostThroughActor() async throws {
        let recorder = FetchHostRecorder()
        let fetch: @Sendable (ClusterSource) async throws -> ClusterSnapshot = { source in
            await recorder.record(source.identity)
            return .empty
        }
        let store = ClusterStore(fetchSnapshot: fetch)

        await store.refresh(host: "  colby  ")

        let hosts = await recorder.hosts
        XCTAssertEqual(hosts, ["ssh:colby"])
    }

    func testFailedRefreshKeepsLastGoodSnapshotAndExposesStaleWarning() async {
        let expected = try! SlurmParser.parseSnapshot("""
        ===SINFO===
        n7|idle|gpu:L4:1|gpu:L4:0(IDX:N/A)
        ===SQUEUE===
        ===RC=== 0 0
        """, now: Date(timeIntervalSince1970: 1_000))
        let store = ClusterStore(fetchSnapshot: { _ in expected })
        await store.refresh(host: "colby")

        store.fetchSnapshot = { _ in throw ClusterClientError.sshFailed(code: 255, message: "unreachable") }
        await store.refresh(host: "colby")

        XCTAssertEqual(store.snapshot.freeGPUs, 1)
        XCTAssertEqual(store.snapshot.totalGPUs, 1)
        XCTAssertNotNil(store.lastErrorAt)
        XCTAssertEqual(store.refreshState(at: Date(timeIntervalSince1970: 1_100), staleAfter: 500), .stale)
        XCTAssertEqual(MenuBarStatusPresentation(store: store).text, "1/1")
        XCTAssertEqual(MenuBarStatusPresentation(store: store).symbolName, "exclamationmark.triangle")
    }

    func testWakeRefreshUsesTrimmedConfiguredHost() async {
        let recorder = FetchHostRecorder()
        let store = ClusterStore(fetchSnapshot: { source in
            await recorder.record(source.identity)
            return .empty
        })

        await store.refreshAfterWake(host: "  colby  ")

        let hosts = await recorder.hosts
        XCTAssertEqual(hosts, ["ssh:colby"])
    }

    func testRefreshQueuesLatestHostWhileCurrentFetchIsInFlight() async {
        let recorder = FetchHostRecorder()
        let releaseGate = FetchReleaseGate()
        let store = ClusterStore(fetchSnapshot: { source in
            await recorder.record(source.identity)
            if source.identity == "ssh:a" {
                await releaseGate.wait()
            }
            return .empty
        })

        let refreshTask = Task {
            await store.refresh(host: "a")
        }

        await recorder.waitForCount(1)
        await store.refresh(host: "intermediate")
        await store.refresh(host: "  b  ")
        var receivedHosts = await recorder.hosts
        XCTAssertEqual(receivedHosts, ["ssh:a"])

        await releaseGate.release()
        await refreshTask.value

        receivedHosts = await recorder.hosts
        XCTAssertEqual(receivedHosts, ["ssh:a", "ssh:b"])
    }

    func testWindowVisibilityDefaultsToVisible() {
        XCTAssertTrue(WindowVisibilityState().isVisible)
    }

    func testEmptyHostRefreshPolicyFetchesOnceWithoutScheduling() {
        XCTAssertEqual(
            RefreshLoopPolicy(configuration: RefreshConfiguration(host: "", enabled: true, interval: 20)),
            .refreshOnce
        )
    }

    func testStoredRefreshIntervalBelowMinimumClampsToSixtySeconds() {
        XCTAssertEqual(RefreshLoopPolicy.effectiveInterval(1), 60)
        XCTAssertEqual(RefreshLoopPolicy.effectiveInterval(5), 60)
        XCTAssertEqual(RefreshLoopPolicy.effectiveInterval(59), 60)
        XCTAssertEqual(RefreshLoopPolicy.effectiveInterval(60), 60)
        XCTAssertEqual(RefreshLoopPolicy.effectiveInterval(90), 90)
        XCTAssertEqual(RefreshLoopPolicy.effectiveInterval(600), 600)
        XCTAssertEqual(RefreshLoopPolicy.minimumInterval, 60)
        XCTAssertEqual(RefreshLoopPolicy.maximumInterval, 600)
    }

    func testAutomaticDelayDoublesPerFailureAndCapsAtFifteenMinutes() {
        XCTAssertEqual(RefreshLoopPolicy.automaticDelay(interval: 60, consecutiveFailures: 0), 60)
        XCTAssertEqual(RefreshLoopPolicy.automaticDelay(interval: 60, consecutiveFailures: 1), 120)
        XCTAssertEqual(RefreshLoopPolicy.automaticDelay(interval: 60, consecutiveFailures: 2), 240)
        XCTAssertEqual(RefreshLoopPolicy.automaticDelay(interval: 60, consecutiveFailures: 3), 480)
        XCTAssertEqual(RefreshLoopPolicy.automaticDelay(interval: 60, consecutiveFailures: 4), 900)
        XCTAssertEqual(RefreshLoopPolicy.automaticDelay(interval: 60, consecutiveFailures: 40), 900)
        XCTAssertEqual(RefreshLoopPolicy.automaticDelay(interval: 600, consecutiveFailures: 1), 900)
        // A stored value below the minimum backs off from the clamped base, not the raw one.
        XCTAssertEqual(RefreshLoopPolicy.automaticDelay(interval: 5, consecutiveFailures: 1), 120)
    }

    func testConsecutiveSnapshotFailuresGrowOnFailureAndResetOnSuccess() async {
        let shouldFail = FetchFailureSwitch()
        let store = ClusterStore(
            fetchSnapshot: { _ in
                if await shouldFail.value {
                    throw ClusterClientError.sshFailed(code: 255, message: "unreachable")
                }
                return .empty
            },
            slurmDataCollector: RecordingSlurmCollector()
        )

        await store.refresh(host: "colby")
        XCTAssertEqual(store.consecutiveSnapshotFailures, 0)

        await shouldFail.set(true)
        await store.refresh(host: "colby")
        XCTAssertEqual(store.consecutiveSnapshotFailures, 1)
        await store.refresh(host: "colby")
        XCTAssertEqual(store.consecutiveSnapshotFailures, 2)

        await shouldFail.set(false)
        await store.refresh(host: "colby")
        XCTAssertEqual(store.consecutiveSnapshotFailures, 0)
    }

    func testFailedSnapshotLaunchesNoSlurmDomainCollection() async {
        let collector = RecordingSlurmCollector()
        let shouldFail = FetchFailureSwitch()
        let store = ClusterStore(
            fetchSnapshot: { _ in
                if await shouldFail.value {
                    throw ClusterClientError.sshFailed(code: 255, message: "unreachable")
                }
                return .empty
            },
            slurmDataCollector: collector
        )

        await shouldFail.set(true)
        await store.refresh(host: "colby")

        XCTAssertEqual(store.consecutiveSnapshotFailures, 1)
        let fetchesWhileFailing = await collector.fetches
        XCTAssertEqual(fetchesWhileFailing, 0, "a failed snapshot must not fan out into domain SSH commands")

        await shouldFail.set(false)
        await store.refresh(host: "colby")
        await collector.waitForFetches(1)
        let fetchesAfterSuccess = await collector.fetches
        XCTAssertEqual(fetchesAfterSuccess, 1)
    }

    func testFailedStatusPageFetchLaunchesNoSlurmDomainCollection() async {
        let collector = RecordingSlurmCollector()
        let store = ClusterStore(
            fetchSnapshot: { _ in throw StatusFeedError.badStatus(503) },
            slurmDataCollector: collector
        )

        await store.refresh(source: .statusPage(url: "https://example.edu/status.json"))

        XCTAssertEqual(store.consecutiveSnapshotFailures, 1)
        XCTAssertNotNil(store.errorMessage)
        let fetchesWhileFailing = await collector.fetches
        XCTAssertEqual(fetchesWhileFailing, 0)
    }

    func testSucceededStatusPageFetchNeverFansOutIntoSlurmCommands() async {
        let collector = RecordingSlurmCollector()
        let store = ClusterStore(
            fetchSnapshot: { _ in .empty },
            slurmDataCollector: collector
        )

        await store.refresh(source: .statusPage(url: "https://example.edu/status.json"))

        XCTAssertNil(store.errorMessage)
        let fetches = await collector.fetches
        XCTAssertEqual(fetches, 0, "a published feed has no SSH session to run domain commands in")
    }

    func testStatusPageWithoutAURLReportsItsOwnConfigurationError() async {
        let recorder = FetchHostRecorder()
        let store = ClusterStore(fetchSnapshot: { source in
            await recorder.record(source.identity)
            return .empty
        })

        await store.refresh(source: .statusPage(url: "   "))

        XCTAssertEqual(store.errorMessage, "No status page URL configured — set one in Settings.")
        XCTAssertTrue(store.hasLoaded)
        let hosts = await recorder.hosts
        XCTAssertTrue(hosts.isEmpty)
    }

    func testBlankHostRefreshFinishesWithoutSpinnerAndReportsConfigurationError() async {
        let recorder = FetchHostRecorder()
        let store = ClusterStore(fetchSnapshot: { source in
            await recorder.record(source.identity)
            return .empty
        })

        await store.refresh(host: "  \n ")

        let hosts = await recorder.hosts
        XCTAssertTrue(hosts.isEmpty)
        XCTAssertTrue(store.hasLoaded)
        XCTAssertFalse(store.isRefreshing)
        XCTAssertEqual(store.refreshState(at: .now, staleAfter: 60), .unavailable)
        XCTAssertEqual(store.errorMessage, "No SSH host configured — set one in Settings.")
    }

    func testHiddenWindowUsesFrozenCanvasPolicy() {
        XCTAssertEqual(CityRenderUpdatePolicy(isWindowVisible: false), .frozenCanvases)
        XCTAssertEqual(CityRenderUpdatePolicy(isWindowVisible: true), .liveTimelines)
    }

    func testLaunchAtLoginKeepsToggleOnWhileApprovalIsPending() {
        XCTAssertEqual(
            LaunchAtLoginToggleState(serviceStatus: .requiresApproval),
            .approvalPending
        )
        XCTAssertTrue(LaunchAtLoginToggleState(serviceStatus: .requiresApproval).isOn)
    }

    func testShellTimestampLabelsDistinguishFailuresFromSuccessfulUpdates() {
        XCTAssertEqual(AppShellTimestampLabel.failurePrefix, "Failed ")
        XCTAssertEqual(AppShellTimestampLabel.successPrefix, "Last updated ")
    }
}

private actor FetchHostRecorder {
    private var recordedHosts: [String] = []
    private var waiters: [HostCountWaiter] = []

    var hosts: [String] {
        recordedHosts
    }

    func record(_ host: String) {
        recordedHosts.append(host)
        resumeReadyWaiters()
    }

    func waitForCount(_ count: Int) async {
        guard recordedHosts.count < count else { return }
        await withCheckedContinuation { continuation in
            waiters.append(HostCountWaiter(count: count, continuation: continuation))
        }
    }

    private func resumeReadyWaiters() {
        var pending: [HostCountWaiter] = []
        for waiter in waiters {
            if recordedHosts.count >= waiter.count {
                waiter.continuation.resume()
            } else {
                pending.append(waiter)
            }
        }
        waiters = pending
    }

    private struct HostCountWaiter {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }
}

private actor FetchReleaseGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

private actor FetchFailureSwitch {
    private var shouldFail = false

    var value: Bool { shouldFail }

    func set(_ fail: Bool) {
        shouldFail = fail
    }
}

/// Counts collection attempts so a test can prove that a failed snapshot never reaches
/// the collector, and that a success does.
private actor RecordingSlurmCollector: SlurmDataCollecting {
    private(set) var fetches = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func fetch(host: String, force: Bool, now: Date) async -> SlurmDataSnapshot {
        fetches += 1
        let pending = waiters
        waiters = []
        for waiter in pending {
            waiter.resume()
        }
        return .empty
    }

    func waitForFetches(_ count: Int) async {
        while fetches < count {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
    }
}
