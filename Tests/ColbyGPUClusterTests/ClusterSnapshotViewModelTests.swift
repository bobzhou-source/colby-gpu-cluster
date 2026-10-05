import Foundation
import XCTest
@testable import ColbyGPUCluster

final class ClusterSnapshotViewModelTests: XCTestCase {
    func testTierSectionsRankProfilesFromBestToLowest() throws {
        let snapshot = try snapshot(
            sinfo: """
            mig-01|idle|gpu:1g.20gb:1
            l4-01|idle|gpu:L4:1
            h200-01|idle|gpu:H200:1
            """
        )

        XCTAssertEqual(snapshot.tierSections.map(\.tier), [.h200, .l4, .mig])
    }

    func testHeadlineNamesBestVacantTierAndHigherTierRelease() throws {
        let snapshot = try snapshot(
            sinfo: """
            a100-01|idle|gpu:A100:1
            h200-01|alloc|gpu:H200:1
            """,
            squeue: """
            100|alice|train|RUNNING|01:00:00|03:06:00|1|h200-01|h200-01
            """
        )

        XCTAssertEqual(snapshot.headline.primary, "A100 is vacant")
        XCTAssertEqual(snapshot.headline.secondary, "Next best: H200 frees in ~2.1h")
        XCTAssertEqual(snapshot.headline.statusKey, .idle)
    }

    func testHeadlineAppendsSingularCommuterSuffixForPendingWork() throws {
        let snapshot = try snapshot(
            sinfo: """
            a100-01|idle|gpu:A100:1
            h200-01|alloc|gpu:H200:1
            """,
            squeue: """
            100|alice|train|RUNNING|01:00:00|03:06:00|1|h200-01|h200-01
            101|bob|evaluate|PENDING|00:00|02:00:00|1||Resources
            """
        )

        XCTAssertEqual(snapshot.headline.secondary, "Next best: H200 frees in ~2.1h · 1 commuter at the bridge")
    }

    func testSettledProvinceShowsSoonestReleaseInHeadline() throws {
        let snapshot = try snapshot(
            sinfo: """
            h200-01|alloc|gpu:H200:1
            """,
            squeue: """
            100|alice|train|RUNNING|01:00:00|02:00:00|1|h200-01|h200-01
            """
        )

        XCTAssertEqual(snapshot.headline.primary, "All cities settled")
        XCTAssertEqual(snapshot.headline.secondary, "Soonest: H200 frees in ~1.0h")
    }

    func testDrainedProvinceReportsClosureWithoutAvailability() throws {
        let snapshot = try snapshot(
            sinfo: """
            h200-01|drain*|gpu:H200:1
            """
        )

        XCTAssertEqual(snapshot.headline.primary, "Province closed")
        XCTAssertEqual(snapshot.headline.secondary, "All cities are offline")
        XCTAssertEqual(snapshot.headline.statusKey, .drain)
    }

    func testMenuBarSummaryUsesOpenTowersAndTierThenNameOrder() throws {
        let snapshot = try snapshot(
            sinfo: """
            a100-01|idle|gpu:A100:1
            h200-b|alloc|gpu:H200:1
            h200-a|idle|gpu:H200:1
            """
        )

        XCTAssertEqual(snapshot.menuBarSummary.text, "2/3")
        XCTAssertEqual(towerDescriptions(snapshot.menuBarSummary), ["h200:open", "h200:working", "a100:open"])
    }

    func testMenuBarSummaryUsesWorkingTowerForNonIdleNonDrainedNode() throws {
        let snapshot = try snapshot(sinfo: "h200-01|alloc|gpu:H200:1")

        XCTAssertEqual(snapshot.menuBarSummary.text, "0/1")
        XCTAssertEqual(towerDescriptions(snapshot.menuBarSummary), ["h200:working"])
    }

    func testMenuBarSummaryUsesOfflineTowersForDrainedAndUnknownNodes() throws {
        let snapshot = try snapshot(
            sinfo: """
            l4-01|mystery|gpu:L4:1
            h200-01|drain*|gpu:H200:1
            """
        )

        XCTAssertEqual(snapshot.menuBarSummary.text, "0/2")
        XCTAssertEqual(towerDescriptions(snapshot.menuBarSummary), ["h200:offline", "l4:offline"])
    }

    private func towerDescriptions(_ summary: MenuBarSummary) -> [String] {
        summary.towers.map { tower in
            let state: String = switch tower.state {
            case .open: "open"
            case .working: "working"
            case .offline: "offline"
            }
            return "\(tower.tier.rawValue):\(state)"
        }
    }

    private func snapshot(sinfo: String, squeue: String = "") throws -> ClusterSnapshot {
        try SlurmParser.parseSnapshot(
            """
            ===SINFO===
            \(sinfo)
            ===SQUEUE===
            \(squeue)
            ===RC=== 0 0
            """,
            now: Date(timeIntervalSince1970: 1_000)
        )
    }
}
