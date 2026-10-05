import Foundation
import XCTest
@testable import ColbyGPUCluster

final class GPUTelemetryParsingTests: XCTestCase {
    /// A state ledger shaped as `telemetry.last_poll.result.samples`, with a
    /// device that reported no utilization and devices that legitimately reported zero.
    private let ledgerJSON = """
    {
      "run_id": "example-poll",
      "schema_version": 1,
      "updated_at": 1788968455.64473,
      "telemetry": {
        "poll_count": 41,
        "last_poll": {
          "observed_at": 1787701369.510228,
          "outcome": "success",
          "result": {
            "sample_count": 1,
            "samples": [
              {
                "timestamp": "2026-08-25T23:42:49.503911+00:00",
                "gpu_count": 4,
                "node_count": 2,
                "nodes": [
                  {
                    "node": "n1",
                    "gpu_count": 2,
                    "gpus": [
                      {"index": 0, "name": "NVIDIA A100 80GB PCIe", "utilization_percent": 0.0,
                       "memory_used_mib": 39913.0, "memory_total_mib": 81920.0,
                       "power_draw_watts": 66.75, "temperature_celsius": 44.0},
                      {"index": 1, "name": "NVIDIA A100 80GB PCIe", "utilization_percent": 0.0,
                       "memory_used_mib": 0.0, "memory_total_mib": 81920.0,
                       "power_draw_watts": 47.25, "temperature_celsius": 51.0}
                    ]
                  },
                  {
                    "node": "n10",
                    "gpu_count": 2,
                    "gpus": [
                      {"index": 0, "name": "NVIDIA A100 80GB PCIe", "utilization_percent": null,
                       "memory_used_mib": 136.0, "memory_total_mib": 81920.0,
                       "power_draw_watts": 41.59, "temperature_celsius": 23.0},
                      {"index": 1, "name": "NVIDIA A100 80GB PCIe", "utilization_percent": 98.0,
                       "memory_used_mib": 80585.0, "memory_total_mib": 81920.0,
                       "power_draw_watts": 309.62, "temperature_celsius": 64.0}
                    ]
                  }
                ]
              }
            ]
          }
        }
      }
    }
    """

    func testNestedLedgerProjectionParsesSampleTimestampAndNodes() throws {
        let snapshot = try GPUTelemetryReader.snapshot(
            from: Data(ledgerJSON.utf8),
            sourcePath: "/tmp/example-telemetry.json"
        )

        // The sample's own timestamp, not the ledger's much newer `updated_at`.
        XCTAssertEqual(
            snapshot.sampledAt?.timeIntervalSince1970 ?? .nan,
            1_787_701_369.503911,
            accuracy: 0.0005
        )
        XCTAssertEqual(snapshot.nodes.keys.sorted(), ["n1", "n10"])
        XCTAssertNil(snapshot.readError)
    }

    func testReportedZeroUtilizationIsMeasuredNotMissing() throws {
        let snapshot = try GPUTelemetryReader.snapshot(from: Data(ledgerJSON.utf8), sourcePath: nil)
        let node = try XCTUnwrap(snapshot.nodes["n1"])

        XCTAssertEqual(node.utilizationPercent, 0)
        XCTAssertEqual(node.reportingDeviceCount, 2)
        XCTAssertFalse(node.isPartial)
        // A device sitting at 0 MiB used is a measurement, not an absent reading.
        XCTAssertEqual(node.devices[1].memoryUsedMiB, 0)
        XCTAssertEqual(node.memoryUsedMiB, 39_913)
        XCTAssertEqual(node.memoryTotalMiB, 163_840)
    }

    func testNullUtilizationIsExcludedFromMeanAndFlaggedPartial() throws {
        let snapshot = try GPUTelemetryReader.snapshot(from: Data(ledgerJSON.utf8), sourcePath: nil)
        let node = try XCTUnwrap(snapshot.nodes["n10"])

        XCTAssertNil(node.devices[0].utilizationPercent)
        XCTAssertEqual(node.utilizationPercent, 98)
        XCTAssertEqual(node.reportingDeviceCount, 1)
        XCTAssertEqual(node.deviceCount, 2)
        XCTAssertTrue(node.isPartial)
        // Memory and power coverage is complete even though utilization coverage is not.
        XCTAssertEqual(node.memoryUsedMiB, 80_721)
        XCTAssertEqual(try XCTUnwrap(node.powerDrawWatts), 351.21, accuracy: 0.001)
        XCTAssertEqual(node.temperatureCelsius, 64)
    }

    func testIncompleteMetricCoverageWithholdsSumsInsteadOfTreatingNullAsZero() {
        let node = GPUNodeTelemetry(
            name: "n7",
            devices: [
                GPUDeviceTelemetry(
                    index: 0,
                    name: "L4",
                    utilizationPercent: 10,
                    memoryUsedMiB: 100,
                    memoryTotalMiB: 23_034,
                    powerDrawWatts: 15.8,
                    temperatureCelsius: 27
                ),
                GPUDeviceTelemetry(
                    index: 1,
                    name: "L4",
                    utilizationPercent: 30,
                    memoryUsedMiB: 200,
                    memoryTotalMiB: nil,
                    powerDrawWatts: nil,
                    temperatureCelsius: nil
                ),
            ]
        )

        XCTAssertEqual(node.utilizationPercent, 20)
        XCTAssertFalse(node.isPartial)
        XCTAssertNil(node.memoryUsedMiB)
        XCTAssertNil(node.memoryTotalMiB)
        XCTAssertNil(node.powerDrawWatts)
        // A maximum stays meaningful under partial coverage.
        XCTAssertEqual(node.temperatureCelsius, 27)
    }

    func testNewestSampleChosenByTimestampNotArrayOrder() throws {
        let payload = """
        {"samples": [
          {"timestamp": "2026-08-25T23:42:49.503911+00:00",
           "nodes": [{"node": "newest", "gpus": [{"index": 0, "utilization_percent": 42.0}]}]},
          {"timestamp": "2026-08-25T23:00:00.000000+00:00",
           "nodes": [{"node": "middle", "gpus": [{"index": 0, "utilization_percent": 1.0}]}]},
          {"timestamp": "2026-08-25T22:00:00.000000+00:00",
           "nodes": [{"node": "oldest", "gpus": [{"index": 0, "utilization_percent": 2.0}]}]}
        ]}
        """

        let snapshot = try GPUTelemetryReader.snapshot(from: Data(payload.utf8), sourcePath: nil)

        XCTAssertEqual(snapshot.nodes.keys.sorted(), ["newest"])
        XCTAssertEqual(
            snapshot.sampledAt?.timeIntervalSince1970 ?? .nan,
            1_787_701_369.503911,
            accuracy: 0.0005
        )
    }

    func testBareSampleIsSupported() throws {
        let bare = """
        {"timestamp": "2026-08-25T23:00:00Z",
         "nodes": [{"node": "n2", "gpus": [{"index": 0, "utilization_percent": 5.0}]}]}
        """

        let snapshot = try GPUTelemetryReader.snapshot(from: Data(bare.utf8), sourcePath: nil)

        XCTAssertEqual(snapshot.nodes["n2"]?.utilizationPercent, 5)
        XCTAssertEqual(snapshot.sampledAt, Date(timeIntervalSince1970: 1_787_698_800))
    }

    func testImplausibleOrNonNumericReadingsBecomeUnknownWhileTheDeviceStaysVisible() throws {
        let payload = """
        {"timestamp": "2026-08-25T23:00:00Z",
         "nodes": [{"node": "n2", "gpus": [
           {"index": 0, "name": "A100", "utilization_percent": 128.0, "memory_used_mib": -1.0},
           {"index": 1, "name": "A100", "utilization_percent": "98"}
         ]}]}
        """

        let snapshot = try GPUTelemetryReader.snapshot(from: Data(payload.utf8), sourcePath: nil)
        let node = try XCTUnwrap(snapshot.nodes["n2"])

        XCTAssertEqual(node.deviceCount, 2)
        XCTAssertEqual(node.reportingDeviceCount, 0)
        XCTAssertNil(node.utilizationPercent)
        XCTAssertNil(node.devices[0].memoryUsedMiB)
        XCTAssertTrue(node.isPartial)
    }

    func testDuplicateNodeAndDeviceEntriesDoNotDoubleCountCoverage() throws {
        let payload = """
        {"timestamp": "2026-08-25T23:00:00Z", "nodes": [
          {"node": "n2", "gpus": [
            {"index": 0, "utilization_percent": 50.0, "memory_used_mib": 10.0, "memory_total_mib": 100.0}
          ]},
          {"node": "n2", "gpus": [
            {"index": 0, "utilization_percent": 50.0, "memory_used_mib": 10.0, "memory_total_mib": 100.0},
            {"index": 1, "utilization_percent": 100.0, "memory_used_mib": 20.0, "memory_total_mib": 100.0}
          ]}
        ]}
        """

        let snapshot = try GPUTelemetryReader.snapshot(from: Data(payload.utf8), sourcePath: nil)
        let node = try XCTUnwrap(snapshot.nodes["n2"])

        XCTAssertEqual(node.deviceCount, 2)
        XCTAssertEqual(node.devices.map(\.index), [0, 1])
        XCTAssertEqual(node.utilizationPercent, 75)
        XCTAssertEqual(node.memoryUsedMiB, 30)
    }

    func testUnsupportedShapeIsReportedRatherThanReturningEmptyData() {
        let payload = #"{"jobs": [], "nodes": {"n1": "idle"}}"#

        XCTAssertThrowsError(
            try GPUTelemetryReader.snapshot(from: Data(payload.utf8), sourcePath: nil)
        ) { error in
            guard case .unsupportedShape = error as? GPUTelemetryError else {
                return XCTFail("expected unsupportedShape, got \(error)")
            }
        }
    }

    func testMalformedJSONIsReported() {
        XCTAssertThrowsError(
            try GPUTelemetryReader.snapshot(from: Data("{not json".utf8), sourcePath: nil)
        ) { error in
            guard case .malformedJSON = error as? GPUTelemetryError else {
                return XCTFail("expected malformedJSON, got \(error)")
            }
        }
    }

    func testLedgerWithoutRecordedPollIsEmptyNotAnError() throws {
        let payload = #"{"telemetry": {"poll_count": 0, "last_poll": null}, "updated_at": 1788968455.6}"#

        let snapshot = try GPUTelemetryReader.snapshot(from: Data(payload.utf8), sourcePath: nil)

        XCTAssertNil(snapshot.sampledAt)
        XCTAssertTrue(snapshot.nodes.isEmpty)
        XCTAssertEqual(snapshot.freshness(at: Date()), .unavailable)
    }

    func testMissingFileIsReportedAsAReadFailure() async {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).json").path

        do {
            _ = try await GPUTelemetryReader.read(path: path)
            XCTFail("expected a read failure")
        } catch {
            XCTAssertEqual(error as? GPUTelemetryError, .missingFile(path: path))
        }
    }

}

final class GPUTelemetryFreshnessTests: XCTestCase {
    private let sampledAt = Date(timeIntervalSince1970: 1_787_701_369)

    private func snapshot(readError: String? = nil) -> GPUTelemetrySnapshot {
        GPUTelemetrySnapshot(
            sampledAt: sampledAt,
            nodes: ["n1": GPUNodeTelemetry(name: "n1", devices: [])],
            readError: readError
        )
    }

    func testFreshWindowBoundaries() {
        let reading = snapshot()

        XCTAssertEqual(reading.freshness(at: sampledAt.addingTimeInterval(60)), .fresh)
        XCTAssertEqual(reading.freshness(at: sampledAt.addingTimeInterval(60.5)), .stale)
        // Small clock skew is tolerated; a sample from the far future is not believable.
        XCTAssertEqual(reading.freshness(at: sampledAt.addingTimeInterval(-5)), .fresh)
        XCTAssertEqual(reading.freshness(at: sampledAt.addingTimeInterval(-6)), .unavailable)
    }

    func testReadFailureMakesAnOtherwiseLiveReadingStale() {
        let failed = snapshot().markingReadError("permission denied")

        XCTAssertEqual(failed.freshness(at: sampledAt.addingTimeInterval(1)), .stale)
        XCTAssertEqual(GPUTelemetrySnapshot.empty.freshness(at: sampledAt), .unavailable)
    }

    /// The inspector shows the telemetry section only when a reading is attached,
    /// so "nothing configured" and "configured but broken" must be distinct.
    func testEmptinessReflectsWhetherATelemetryFileIsAttached() {
        XCTAssertTrue(GPUTelemetrySnapshot.empty.isEmpty)
        XCTAssertFalse(snapshot().isEmpty)

        // A failed read still counts as attached: the user picked a file, and the
        // inspector has to be able to say it could not be read.
        let failed = GPUTelemetrySnapshot(
            readError: "no such file",
            sourcePath: "/tmp/example-telemetry.json"
        )
        XCTAssertFalse(failed.isEmpty)
    }
}

@MainActor
final class GPUTelemetryStoreTests: XCTestCase {
    /// Each test gets its own defaults suite, created inside the test body so no state is shared
    /// across the nonisolated XCTest lifecycle hooks. Only the suite name — a `Sendable` value —
    /// is captured for cleanup.
    private func isolatedDefaults() throws -> UserDefaults {
        let suiteName = "GPUTelemetryStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    private func reading(node: String, at seconds: TimeInterval = 1_787_701_369) -> GPUTelemetrySnapshot {
        GPUTelemetrySnapshot(
            sampledAt: Date(timeIntervalSince1970: seconds),
            nodes: [node: GPUNodeTelemetry(
                name: node,
                devices: [GPUDeviceTelemetry(index: 0, name: "A100", utilizationPercent: 42)]
            )]
        )
    }

    func testOrdinaryRefreshLoadsLocalFeedEvenWhenTheSchedulerFetchFails() async throws {
        let defaults = try isolatedDefaults()
        defaults.set("colby", forKey: GPUTelemetrySettings.hostKey)
        defaults.set("/tmp/feed.json", forKey: GPUTelemetrySettings.pathKey)
        let expected = reading(node: "n1")
        let store = ClusterStore(
            fetchSnapshot: { _ in throw ClusterClientError.sshFailed(code: 255, message: "unreachable") },
            telemetryDefaults: defaults,
            readGPUTelemetry: { _ in expected }
        )

        await store.refresh(host: "colby")

        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(store.gpuTelemetry, expected)
    }

    func testReadFailureKeepsTheLastGoodReadingVisiblyStale() async throws {
        let defaults = try isolatedDefaults()
        defaults.set("colby", forKey: GPUTelemetrySettings.hostKey)
        defaults.set("/tmp/feed.json", forKey: GPUTelemetrySettings.pathKey)
        let good = reading(node: "n1")
        let failures = FailureSwitch()
        let store = ClusterStore(
            fetchSnapshot: { _ in .empty },
            telemetryDefaults: defaults,
            readGPUTelemetry: { _ in
                if await failures.shouldFail {
                    throw GPUTelemetryError.unreadable(path: "/tmp/feed.json", reason: "permission denied")
                }
                return good
            }
        )

        await store.refreshGPUTelemetry(host: "colby")
        await failures.fail()
        await store.refreshGPUTelemetry(host: "colby")

        XCTAssertEqual(store.gpuTelemetry.nodes["n1"], good.nodes["n1"])
        XCTAssertEqual(store.gpuTelemetry.sampledAt, good.sampledAt)
        XCTAssertNotNil(store.gpuTelemetry.readError)
        XCTAssertEqual(
            store.gpuTelemetry.freshness(at: Date(timeIntervalSince1970: 1_787_701_370)),
            .stale
        )
    }

    func testFeedBoundToAnotherHostIsNotShown() async throws {
        let defaults = try isolatedDefaults()
        defaults.set("colby", forKey: GPUTelemetrySettings.hostKey)
        defaults.set("/tmp/feed.json", forKey: GPUTelemetrySettings.pathKey)
        let colbyReading = reading(node: "n1")
        let store = ClusterStore(
            fetchSnapshot: { _ in .empty },
            telemetryDefaults: defaults,
            readGPUTelemetry: { _ in colbyReading }
        )

        await store.refreshGPUTelemetry(host: "colby")
        XCTAssertFalse(store.gpuTelemetry.nodes.isEmpty)

        await store.refreshGPUTelemetry(host: "other-cluster")

        XCTAssertEqual(store.gpuTelemetry, .empty)
    }

    func testSourceChangeDropsOldAttributionAndIgnoresTheLateRead() async throws {
        let defaults = try isolatedDefaults()
        defaults.set("colby", forKey: GPUTelemetrySettings.hostKey)
        defaults.set("/tmp/feed-a.json", forKey: GPUTelemetrySettings.pathKey)
        let slowReadStarted = Gate()
        let releaseSlowRead = Gate()
        let oldReading = reading(node: "old-cluster-node")
        let newReading = reading(node: "new-cluster-node", at: 1_787_701_400)
        let store = ClusterStore(
            fetchSnapshot: { _ in .empty },
            telemetryDefaults: defaults,
            readGPUTelemetry: { path in
                guard path == "/tmp/feed-a.json" else { return newReading }
                await slowReadStarted.open()
                await releaseSlowRead.wait()
                return oldReading
            }
        )

        let slowRefresh = Task { await store.refreshGPUTelemetry(host: "colby") }
        await slowReadStarted.wait()
        defaults.set("/tmp/feed-b.json", forKey: GPUTelemetrySettings.pathKey)
        await store.refreshGPUTelemetry(host: "colby")
        await releaseSlowRead.open()
        await slowRefresh.value

        XCTAssertEqual(store.gpuTelemetry.nodes.keys.sorted(), ["new-cluster-node"])
        XCTAssertEqual(store.gpuTelemetry.sampledAt, newReading.sampledAt)
    }

    func testBindingChangedDuringPendingReadDropsTheLateResult() async throws {
        let defaults = try isolatedDefaults()
        defaults.set("colby", forKey: GPUTelemetrySettings.hostKey)
        defaults.set("/tmp/feed.json", forKey: GPUTelemetrySettings.pathKey)
        let slowReadStarted = Gate()
        let releaseSlowRead = Gate()
        let pendingReading = reading(node: "colby-node")
        let store = ClusterStore(
            fetchSnapshot: { _ in .empty },
            telemetryDefaults: defaults,
            readGPUTelemetry: { _ in
                await slowReadStarted.open()
                await releaseSlowRead.wait()
                return pendingReading
            }
        )

        let slowRefresh = Task { await store.refreshGPUTelemetry(host: "colby") }
        await slowReadStarted.wait()
        // The feed is rebound to another cluster while the read is still in flight.
        defaults.set("other-cluster", forKey: GPUTelemetrySettings.hostKey)
        await store.refreshGPUTelemetry(host: "colby")
        XCTAssertEqual(store.gpuTelemetry, .empty)

        await releaseSlowRead.open()
        await slowRefresh.value

        XCTAssertEqual(store.gpuTelemetry, .empty)
    }

    func testClearedBindingHidesReadingsAndDoesNotReadTheFeed() async throws {
        let defaults = try isolatedDefaults()
        defaults.set("colby", forKey: GPUTelemetrySettings.hostKey)
        defaults.set("/tmp/feed.json", forKey: GPUTelemetrySettings.pathKey)
        let counter = ReadCounter()
        let colbyReading = reading(node: "n1")
        let store = ClusterStore(
            fetchSnapshot: { _ in .empty },
            telemetryDefaults: defaults,
            readGPUTelemetry: { _ in
                _ = await counter.record()
                return colbyReading
            }
        )

        await store.refreshGPUTelemetry(host: "colby")
        XCTAssertFalse(store.gpuTelemetry.nodes.isEmpty)
        let readsWhileBound = await counter.count

        // An empty binding is unconfigured, not a wildcard.
        defaults.set("", forKey: GPUTelemetrySettings.hostKey)
        await store.refreshGPUTelemetry(host: "colby")

        XCTAssertEqual(store.gpuTelemetry, .empty)
        let readsAfterClearing = await counter.count
        XCTAssertEqual(readsAfterClearing, readsWhileBound)
    }

    func testUnconfiguredTelemetryPathHidesReadingsAndNeverReads() async throws {
        let defaults = try isolatedDefaults()
        defaults.set("colby", forKey: GPUTelemetrySettings.hostKey)
        let counter = ReadCounter()
        let value = reading(node: "n1")
        let store = ClusterStore(
            fetchSnapshot: { _ in .empty },
            telemetryDefaults: defaults,
            readGPUTelemetry: { _ in
                _ = await counter.record()
                return value
            }
        )

        await store.refreshGPUTelemetry(host: "colby")

        XCTAssertEqual(store.gpuTelemetry, .empty)
        let reads = await counter.count
        XCTAssertEqual(reads, 0, "an empty telemetry path is disabled, not a default file")
    }

    func testLatestRefreshWinsWhenReadsOfTheSameSourceOverlap() async throws {
        let defaults = try isolatedDefaults()
        defaults.set("colby", forKey: GPUTelemetrySettings.hostKey)
        defaults.set("/tmp/feed.json", forKey: GPUTelemetrySettings.pathKey)
        let slowReadStarted = Gate()
        let releaseSlowRead = Gate()
        let order = ReadCounter()
        let stale = reading(node: "first-request", at: 1_787_701_000)
        let latest = reading(node: "second-request", at: 1_787_701_400)
        let store = ClusterStore(
            fetchSnapshot: { _ in .empty },
            telemetryDefaults: defaults,
            readGPUTelemetry: { _ in
                guard await order.record() > 1 else {
                    await slowReadStarted.open()
                    await releaseSlowRead.wait()
                    return stale
                }
                return latest
            }
        )

        let firstRefresh = Task { await store.refreshGPUTelemetry(host: "colby") }
        await slowReadStarted.wait()
        await store.refreshGPUTelemetry(host: "colby")
        await releaseSlowRead.open()
        await firstRefresh.value

        XCTAssertEqual(store.gpuTelemetry.nodes.keys.sorted(), ["second-request"])
        XCTAssertEqual(store.gpuTelemetry.sampledAt, latest.sampledAt)
    }
}

private actor FailureSwitch {
    private(set) var shouldFail = false

    func fail() {
        shouldFail = true
    }
}

private actor ReadCounter {
    private(set) var count = 0

    @discardableResult
    func record() -> Int {
        count += 1
        return count
    }
}

/// One-shot async gate used to order the concurrent-read regression deterministically.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}
