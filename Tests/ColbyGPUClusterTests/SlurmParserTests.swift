import Foundation
import XCTest
@testable import ColbyGPUCluster

final class SlurmParserTests: XCTestCase {
    private let liveResponse = """
    ===SINFO===
    n2|mix|gpu:L40S:1|gpu:L40S:1(IDX:0)
    n7|mix|gpu:L4:1|gpu:L4:0(IDX:N/A)
    n8|idle|gpu:L4:1|gpu:L4:0(IDX:N/A)
    n10|mix|gpu:A100:1,gpu:1g.20gb:4|gpu:A100:1(IDX:0),gpu:1g.20gb:0(IDX:N/A)
    n14|down*|gpu:1g.20gb:4|gpu:1g.20gb:0(IDX:N/A)
    n15|drain|gpu:H200:1,gpu:HEQ:12|gpu:H200:0(IDX:N/A),gpu:HEQ:0(IDX:N/A)
    n16|mix|gpu:RTX:1,gpu:HEQ:12|gpu:RTX:1(IDX:0),gpu:HEQ:0(IDX:N/A)
    ===SQUEUE===
    ===RC=== 0 0
    """

    func testDurationFormats() {
        XCTAssertEqual(SlurmParser.parseDuration("45"), 45)
        XCTAssertEqual(SlurmParser.parseDuration("12:34"), 754)
        XCTAssertEqual(SlurmParser.parseDuration("01:02:03"), 3_723)
        XCTAssertEqual(SlurmParser.parseDuration("2-01:00:00"), 176_400)
        XCTAssertNil(SlurmParser.parseDuration("UNLIMITED"))
        XCTAssertNil(SlurmParser.parseDuration("bad"))
    }

    func testParsesAndJoinsClusterSnapshot() throws {
        let raw = """
        ===SINFO===
        gpu01|idle|gpu:A100:1(S:0-3)|gpu:A100:0(IDX:N/A)
        gpu02|alloc|gpu:H200:1|gpu:H200:1(IDX:0)
        gpu03|drain*|gpu:L40S:1|gpu:L40S:0(IDX:N/A)
        cpu01|idle|(null)|(null)
        ===SQUEUE===
        100|alice|train|RUNNING|01:00:00|04:00:00|1|gpu02|gpu02
        101|bob|eval|PENDING|00:00|02:00:00|1||Resources
        ===RC=== 0 0
        """

        let snapshot = try SlurmParser.parseSnapshot(
            raw,
            now: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertEqual(snapshot.nodes.count, 3)
        XCTAssertEqual(snapshot.freeGPUs, 1)
        XCTAssertEqual(snapshot.pending.count, 1)
        XCTAssertEqual(snapshot.nodes[0].name, "gpu01")
        XCTAssertEqual(snapshot.nodes[0].vramGB, 80)

        let h200 = try XCTUnwrap(snapshot.nodes.first { $0.name == "gpu02" })
        XCTAssertEqual(h200.jobs.first?.user, "alice")
        XCTAssertEqual(h200.freeInSeconds, 10_800)

        let drained = try XCTUnwrap(snapshot.nodes.first { $0.name == "gpu03" })
        XCTAssertEqual(drained.status, .drain)
    }

    func testParsesLiveSinfoResourceCountsAndAvailability() throws {
        let snapshot = try SlurmParser.parseSnapshot(liveResponse)
        let n10 = try XCTUnwrap(snapshot.nodes.first { $0.name == "n10" })
        let a100 = try XCTUnwrap(n10.gres.first { $0.profile == "a100" })
        let mig = try XCTUnwrap(n10.gres.first { $0.profile == "mig" })
        let n15 = try XCTUnwrap(snapshot.nodes.first { $0.name == "n15" })

        XCTAssertEqual(n10.gres.count, 2)
        XCTAssertEqual(a100.count, 1)
        XCTAssertEqual(a100.used, 1)
        XCTAssertEqual(a100.free, 0)
        XCTAssertEqual(mig.count, 4)
        XCTAssertEqual(mig.used, 0)
        XCTAssertEqual(mig.free, 4)
        XCTAssertEqual(n10.freeGPUCount, 4)
        XCTAssertTrue(try XCTUnwrap(snapshot.nodes.first { $0.name == "n7" }).isIdle)
        XCTAssertFalse(try XCTUnwrap(snapshot.nodes.first { $0.name == "n2" }).isIdle)
        XCTAssertEqual(n15.freeGPUCount, 0)
        XCTAssertFalse(n15.gres.contains { $0.gpuType == "HEQ" })
    }

    func testLiveSinfoSnapshotTotalsCountAllResources() throws {
        let snapshot = try SlurmParser.parseSnapshot(liveResponse)

        XCTAssertEqual(snapshot.freeGPUs, 6)
        XCTAssertEqual(snapshot.totalGPUs, 14)
    }

    func testLiveSinfoMIGTierContainsN10FreeEntry() throws {
        let snapshot = try SlurmParser.parseSnapshot(liveResponse)
        let migSection = try XCTUnwrap(snapshot.tierSections.first { $0.tier == .mig })
        let entry = try XCTUnwrap(migSection.entries.first { $0.node.name == "n10" })

        XCTAssertEqual(entry.gres.profile, "mig")
        XCTAssertEqual(entry.gres.free, 4)
    }

    func testRejectsFailedSinfoReturnCode() {
        assertParseError(
            liveResponse.replacingOccurrences(of: "===RC=== 0 0", with: "===RC=== 1 0"),
            contains: "sinfo failed"
        )
    }

    func testRejectsTruncatedResponseWithoutReturnCode() {
        assertParseError(
            liveResponse.replacingOccurrences(of: "===RC=== 0 0", with: ""),
            contains: "Truncated"
        )
    }

    func testRejectsSuccessfulResponseWithNoGPUNodes() {
        assertParseError(
            """
            ===SINFO===
            cpu01|idle|(null)|(null)
            ===SQUEUE===
            ===RC=== 0 0
            """,
            contains: "no GPU nodes"
        )
    }

    func testExpandsSlurmHostlists() {
        XCTAssertEqual(SlurmParser.expandNodeList("n[2,7-8,10]"), Set(["n2", "n7", "n8", "n10"]))
        XCTAssertEqual(SlurmParser.expandNodeList("n[01-03]"), Set(["n01", "n02", "n03"]))
        XCTAssertEqual(SlurmParser.expandNodeList("n2,n10"), Set(["n2", "n10"]))
        XCTAssertEqual(SlurmParser.expandNodeList("(null)"), Set<String>())
    }

    func testJobOnN1DoesNotAttachToN10() throws {
        let snapshot = try SlurmParser.parseSnapshot(
            """
            ===SINFO===
            n1|alloc|gpu:A100:1|gpu:A100:1(IDX:0)
            n10|alloc|gpu:A100:1|gpu:A100:1(IDX:0)
            ===SQUEUE===
            100|alice|train|RUNNING|01:00:00|04:00:00|1|n1|n1
            ===RC=== 0 0
            """
        )

        XCTAssertEqual(try XCTUnwrap(snapshot.nodes.first { $0.name == "n1" }).jobs.map(\.id), ["100"])
        XCTAssertTrue(try XCTUnwrap(snapshot.nodes.first { $0.name == "n10" }).jobs.isEmpty)
    }

    func testRejectsUnmarkedOutput() {
        XCTAssertThrowsError(try SlurmParser.parseSnapshot("ssh: host not found"))
    }

    func testGPUProfileCoverage() {
        let nodes = SlurmParser.parseNodes("""
        g1|idle|gpu:H200:1|gpu:H200:0(IDX:N/A)
        g2|idle|gpu:RTX:1|gpu:RTX:0(IDX:N/A)
        g3|idle|gpu:A100:1|gpu:A100:0(IDX:N/A)
        g4|idle|gpu:L40S:1|gpu:L40S:0(IDX:N/A)
        g5|idle|gpu:L4:1|gpu:L4:0(IDX:N/A)
        g6|idle|gpu:1g.20gb:1|gpu:1g.20gb:0(IDX:N/A)
        """)

        XCTAssertEqual(Set(nodes.flatMap(\.gres).map(\.profile)), Set(["h200", "rtxpro6000", "a100", "l40s", "l4", "mig"]))
    }

    /// Live `sinfo` reported n15 as `mix-` (planned by backfill) and the node
    /// fell into `.unknown`; every documented flag suffix must strip cleanly.
    func testStateFlagSuffixesStillClassifyTheBaseState() {
        let nodes = SlurmParser.parseNodes("""
        n15|mix-|gpu:H200:4|gpu:H200:4(IDX:0-3)
        n16|idle%|gpu:L4:1|gpu:L4:0(IDX:N/A)
        n17|alloc@|gpu:L4:1|gpu:L4:1(IDX:0)
        n18|idle!|gpu:L4:1|gpu:L4:0(IDX:N/A)
        n19|drain^|gpu:L4:1|gpu:L4:0(IDX:N/A)
        """)

        XCTAssertEqual(nodes.map(\.status), [.partial, .idle, .busy, .idle, .drain])
        XCTAssertEqual(nodes.map(\.state), ["mix", "idle", "alloc", "idle", "drain"])
    }

    private func assertParseError(_ raw: String, contains expectedText: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try SlurmParser.parseSnapshot(raw), file: file, line: line) { error in
            XCTAssertTrue(
                String(describing: error).contains(expectedText),
                "Expected error containing \"\(expectedText)\", got: \(error)",
                file: file,
                line: line
            )
        }
    }
}
