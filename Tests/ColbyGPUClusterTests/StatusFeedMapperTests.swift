import Foundation
import XCTest
@testable import ColbyGPUCluster

/// Decoding of the published `colby-gpu-status/1` contract into the app's
/// snapshot model. The fixture is the captured sample copied into the test
/// bundle; nothing here opens a socket.
final class StatusFeedMapperTests: XCTestCase {
    private func fixtureData(_ name: String = "demo-status") throws -> Data {
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Resources")
            ?? Bundle.module.url(forResource: name, withExtension: "json")
        return try Data(contentsOf: try XCTUnwrap(url, "missing fixture \(name).json"))
    }

    private func fixtureSnapshot() throws -> ClusterSnapshot {
        try StatusFeedMapper.snapshot(from: fixtureData(), now: Date(timeIntervalSince1970: 0))
    }

    // MARK: - Fixture mapping

    func testFixtureDecodesTierOccupancyAndStates() throws {
        let snapshot = try fixtureSnapshot()

        XCTAssertEqual(snapshot.nodes.count, 7)
        XCTAssertEqual(snapshot.totalGPUs, 16)
        // Draining and reserved nodes publish no free GPUs even when idle.
        XCTAssertEqual(snapshot.freeGPUs, 3)
        XCTAssertEqual(snapshot.busyCount, 7)

        let partial = try XCTUnwrap(snapshot.nodes.first { $0.name == "n1" })
        XCTAssertEqual(partial.status, .partial)
        XCTAssertEqual(partial.stateLabel, "Partial")
        XCTAssertEqual(partial.gpuType, "A100")
        XCTAssertEqual(partial.profile, "a100")
        XCTAssertEqual(partial.gpuCount, 2)
        XCTAssertEqual(partial.freeGPUCount, 1)
    }

    func testDrainedNodeKeepsSchedulerReasonVerbatim() throws {
        let snapshot = try fixtureSnapshot()

        let drained = try XCTUnwrap(snapshot.nodes.first { $0.name == "n10" })
        XCTAssertEqual(drained.status, .drain)
        XCTAssertEqual(drained.stateLabel, "Drain")
        XCTAssertEqual(drained.freeGPUCount, 0)

        let reserved = try XCTUnwrap(snapshot.nodes.first { $0.name == "n15" })
        XCTAssertEqual(reserved.status, .drain)
        XCTAssertEqual(reserved.stateLabel, "Reserved")
    }

    func testUnknownGPUNameStillRendersUnderItsOwnProfile() throws {
        let snapshot = try fixtureSnapshot()

        let exotic = try XCTUnwrap(snapshot.nodes.first { $0.name == "n16" })
        XCTAssertEqual(exotic.gpuType, "RTX PRO 6000")
        XCTAssertEqual(exotic.profile, "rtxpro6000")
        XCTAssertEqual(exotic.vramGB, 96)
    }

    /// The publisher reports a MIG slice by its GRES type (`1g.20gb`), not the
    /// word "MIG", so the mapper has to recognise the slice spelling too.
    func testMIGSliceNamesMapOntoTheMIGTier() throws {
        XCTAssertEqual(GPUHardwareProfile.lookup("1g.20gb").profile, "mig")
        XCTAssertEqual(GPUHardwareProfile.lookup("1g.20gb").vramGB, 20)
        XCTAssertEqual(GPUHardwareProfile.lookup("3g.40gb").profile, "mig")

        let payload = """
        {
          "schema": "colby-gpu-status/1",
          "nodes": [
            {"name": "n30", "state": "mixed", "gpu_type": "1g.20gb", "gpus_total": 7, "gpus_used": 3}
          ],
          "jobs": []
        }
        """
        let snapshot = try StatusFeedMapper.snapshot(from: Data(payload.utf8))
        let node = try XCTUnwrap(snapshot.nodes.first)
        XCTAssertEqual(node.profile, "mig")
        XCTAssertEqual(node.gpuCount, 7)
        XCTAssertEqual(node.freeGPUCount, 4)
    }

    func testRunningJobsAttachToTheirNodesAndPendingJobsSortById() throws {
        let snapshot = try fixtureSnapshot()

        let n1 = try XCTUnwrap(snapshot.nodes.first { $0.name == "n1" })
        XCTAssertEqual(n1.jobs.map(\.id), ["17251"])
        XCTAssertEqual(n1.jobs.first?.user, "alice")
        XCTAssertEqual(n1.jobs.first?.remainingSeconds, 34_000)

        let n16 = try XCTUnwrap(snapshot.nodes.first { $0.name == "n16" })
        XCTAssertEqual(n16.jobs.map(\.id), ["17254", "17255"])

        XCTAssertEqual(snapshot.pending.map(\.id), ["17256", "17257"])
        XCTAssertEqual(snapshot.pending.first?.reason, "Resources")
        XCTAssertEqual(snapshot.pending.first?.limitSeconds, 86_400)
    }

    func testGeneratedAtUsesTheDocumentTimestamp() throws {
        let snapshot = try fixtureSnapshot()

        let expected = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-10-05T14:30:00-04:00")
        )
        XCTAssertEqual(snapshot.generatedAt, expected)
    }

    // MARK: - Publisher cross-check

    /// The document actually emitted by `publisher/publish_status.py` from its
    /// captured command fixtures. This is the end-to-end contract check: if
    /// either side changes shape, this fails.
    func testPublisherFixtureOutputMapsCleanly() throws {
        let snapshot = try StatusFeedMapper.snapshot(from: fixtureData("publisher-status"))

        XCTAssertEqual(snapshot.nodes.count, 7)
        XCTAssertEqual(snapshot.pending.count, 2)

        let h200 = try XCTUnwrap(snapshot.nodes.first { $0.name == "n15" })
        XCTAssertEqual(h200.status, .idle)
        XCTAssertEqual(h200.profile, "h200")
        XCTAssertEqual(h200.gpuCount, 4)

        let mig = try XCTUnwrap(snapshot.nodes.first { $0.name == "n30" })
        XCTAssertEqual(mig.profile, "mig")
        XCTAssertEqual(mig.gpuType, "1g.20gb")
        XCTAssertEqual(mig.gpuCount, 7)

        let a100 = try XCTUnwrap(snapshot.nodes.first { $0.name == "n20" })
        XCTAssertEqual(a100.status, .busy)
        XCTAssertEqual(a100.gpuCount, 2)
        XCTAssertEqual(a100.freeGPUCount, 0)

        XCTAssertEqual(snapshot.pending.map(\.id), ["1004", "1005"])
    }

    // MARK: - Tolerance

    func testUnknownFieldsAreIgnoredAndMissingOptionalFieldsTolerated() throws {
        let payload = """
        {
          "schema": "colby-gpu-status/1",
          "cluster": "Colby HPC",
          "generated_at": "2026-10-05T14:30:00-04:00",
          "future_field": {"nested": [1, 2, 3]},
          "nodes": [
            {"name": "n1", "state": "idle", "gpu_type": "H200", "gpus_total": 4}
          ],
          "jobs": [],
          "reservations": []
        }
        """

        let snapshot = try StatusFeedMapper.snapshot(from: Data(payload.utf8))
        let node = try XCTUnwrap(snapshot.nodes.first)
        XCTAssertEqual(node.name, "n1")
        XCTAssertEqual(node.status, .idle)
        XCTAssertEqual(node.gpuCount, 4)
        XCTAssertEqual(node.freeGPUCount, 4)
        XCTAssertTrue(node.jobs.isEmpty)
    }

    func testUsedCountNeverExceedsTotal() throws {
        let payload = """
        {
          "schema": "colby-gpu-status/1",
          "nodes": [
            {"name": "n1", "state": "allocated", "gpu_type": "L4", "gpus_total": 2, "gpus_used": 99}
          ],
          "jobs": []
        }
        """

        let snapshot = try StatusFeedMapper.snapshot(from: Data(payload.utf8))
        let node = try XCTUnwrap(snapshot.nodes.first)
        XCTAssertEqual(node.gpuCount, 2)
        XCTAssertEqual(node.freeGPUCount, 0)
    }

    func testAnEmptyFeedIsValidNotAnError() throws {
        let payload = """
        {"schema": "colby-gpu-status/1", "cluster": "Colby HPC", "nodes": [], "jobs": [], "reservations": []}
        """

        let snapshot = try StatusFeedMapper.snapshot(from: Data(payload.utf8))
        XCTAssertTrue(snapshot.nodes.isEmpty)
        XCTAssertTrue(snapshot.pending.isEmpty)
    }

    // MARK: - Rejections

    func testUnsupportedSchemaIsRejected() {
        let payload = #"{"schema": "colby-gpu-status/2", "nodes": []}"#
        XCTAssertThrowsError(try StatusFeedMapper.snapshot(from: Data(payload.utf8))) { error in
            guard case .unsupportedSchema = error as? StatusFeedError else {
                return XCTFail("expected unsupportedSchema, got \(error)")
            }
        }
    }

    func testMalformedJSONIsRejected() {
        XCTAssertThrowsError(try StatusFeedMapper.snapshot(from: Data("{not json".utf8))) { error in
            guard case .malformedJSON = error as? StatusFeedError else {
                return XCTFail("expected malformedJSON, got \(error)")
            }
        }
    }

    func testNonObjectRootIsRejected() {
        XCTAssertThrowsError(try StatusFeedMapper.snapshot(from: Data("[1, 2]".utf8))) { error in
            XCTAssertEqual(error as? StatusFeedError, .unsupportedRoot)
        }
    }

    func testHTTPClientRejectsAnUnusableURLWithoutTouchingTheNetwork() async {
        do {
            _ = try await HTTPStatusClient().fetch(urlString: "not a url")
            XCTFail("expected a rejection")
        } catch {
            guard case .invalidURL = error as? StatusFeedError else {
                return XCTFail("expected invalidURL, got \(error)")
            }
        }
    }
}

// MARK: - Source selection and polling policy

final class ClusterSourceTests: XCTestCase {
    func testStatusPageKindFallsBackToSSHWhenNoURLIsSet() {
        let source = ClusterSourceResolution.source(kind: "statusPage", url: "   ", host: "login.example.edu")
        XCTAssertEqual(source, .ssh(host: "login.example.edu"))
    }

    func testStatusPageKindUsesTheURLEvenWhenAnSSHHostExists() {
        let source = ClusterSourceResolution.source(
            kind: "statusPage",
            url: "https://example.edu/status.json",
            host: "login.example.edu"
        )
        XCTAssertEqual(source, .statusPage(url: "https://example.edu/status.json"))
        XCTAssertNil(source.sshHost)
        XCTAssertFalse(source.usesSSH)
        XCTAssertTrue(source.isConfigured)
    }

    func testSSHKindIgnoresAConfiguredStatusPage() {
        let source = ClusterSourceResolution.source(
            kind: "ssh",
            url: "https://example.edu/status.json",
            host: "login.example.edu"
        )
        XCTAssertEqual(source, .ssh(host: "login.example.edu"))
        XCTAssertTrue(source.usesSSH)
    }

    func testUnconfiguredSourcesAreNotConfigured() {
        XCTAssertFalse(ClusterSource.ssh(host: "  ").isConfigured)
        XCTAssertFalse(ClusterSource.statusPage(url: "  ").isConfigured)
        XCTAssertFalse(ClusterSource.statusPage(url: "example.edu/status.json").isConfigured)
        XCTAssertTrue(ClusterSource.statusPage(url: "https://example.edu/status.json").isConfigured)
    }

    func testHTTPPollsFasterThanSSHAndBackoffStillCapsAtFifteenMinutes() {
        XCTAssertEqual(RefreshLoopPolicy.minimumInterval(forSource: .ssh(host: "h")), 60)
        XCTAssertEqual(RefreshLoopPolicy.minimumInterval(forSource: .statusPage(url: "https://e/status.json")), 30)

        XCTAssertEqual(
            RefreshLoopPolicy.effectiveInterval(5, minimum: RefreshLoopPolicy.minimumInterval(forSource: .statusPage(url: "u"))),
            30
        )
        XCTAssertEqual(
            RefreshLoopPolicy.effectiveInterval(45, minimum: RefreshLoopPolicy.minimumInterval(forSource: .statusPage(url: "u"))),
            45
        )
        XCTAssertEqual(RefreshLoopPolicy.automaticDelay(interval: 30, consecutiveFailures: 6), 900)
    }

    func testConfiguredStatusPageSchedulesAndAnUnsetOneDoesNot() {
        XCTAssertEqual(
            RefreshLoopPolicy(configuration: RefreshConfiguration(
                source: .statusPage(url: "https://example.edu/status.json"),
                enabled: true,
                interval: 30
            )),
            .refreshAndSchedule
        )
        XCTAssertEqual(
            RefreshLoopPolicy(configuration: RefreshConfiguration(
                source: .statusPage(url: "  "),
                enabled: true,
                interval: 30
            )),
            .refreshOnce
        )
    }
}
