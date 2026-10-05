import CoreGraphics
import Foundation
import XCTest

@testable import ColbyGPUCluster

/// The meandering river must stay a good neighbour: banks inside the probed
/// corridor clearances, the bridge corridor byte-identical to the legacy
/// straight band, endpoints pinned to the legacy quad corners, and no plot or
/// street geometry inside the water.
@MainActor
final class RiverCorridorTests: XCTestCase {
    /// Probed clearances around the legacy band (center 130-112s, +/-10):
    /// nearest feature sits >= 12 west and >= 21 east of the band edge
    /// (bridge crossing excluded). Banks keep a 4-unit safety buffer.
    func testBanksStayInsideProbedCorridorClearances() {
        for station in CityScape.riverStations {
            let legacyCenter = 130 - 112 * station.s
            XCTAssertGreaterThanOrEqual(
                station.x + station.west, legacyCenter - 10 - 8,
                "West bank at s=\(station.s) exceeds the 12-unit corridor minus buffer."
            )
            XCTAssertLessThanOrEqual(
                station.x + station.east, legacyCenter + 10 + 17,
                "East bank at s=\(station.s) exceeds the 21-unit corridor minus buffer."
            )
        }
    }

    /// Under the deck and its avenue approach (s 0.38...0.66) the river is
    /// exactly the legacy straight band, so the bridge alignment never drifts.
    func testBridgeCorridorPinsLegacyBand() {
        for station in CityScape.riverStations where (0.38...0.66).contains(station.s) {
            XCTAssertEqual(station.x, 130 - 112 * station.s, accuracy: 1e-9)
            XCTAssertEqual(station.west, -10, accuracy: 1e-9)
            XCTAssertEqual(station.east, 10, accuracy: 1e-9)
        }
    }

    /// The river mouth and outlet stay byte-identical to the legacy quad
    /// corners so the terrain silhouette and worldBounds never move.
    func testEndpointsMatchLegacyQuadCorners() {
        let first = CityScape.riverStations.first!
        let last = CityScape.riverStations.last!
        XCTAssertEqual(first.x + first.west, 120, accuracy: 1e-9)
        XCTAssertEqual(first.x + first.east, 140, accuracy: 1e-9)
        XCTAssertEqual(first.y, 28, accuracy: 1e-9)
        XCTAssertEqual(last.x + last.west, 8, accuracy: 1e-9)
        XCTAssertEqual(last.x + last.east, 28, accuracy: 1e-9)
        XCTAssertEqual(last.y, 140, accuracy: 1e-9)
    }

    /// No plot corner or local-street sample may fall inside the water band
    /// (2-unit margin); the avenue's bridge crossing is the one legitimate
    /// exception.
    func testRiverAvoidsPlotsAndStreets() {
        for nodeCount in [3, 7, 16, 32] {
            var nodes: [ClusterNode] = []
            for index in 0..<nodeCount {
                let tier = GPUTier.allCases[index % GPUTier.allCases.count]
                let status: NodeStatus = index % 3 == 0 ? .busy : .idle
                let gres = GPUResource(
                    gpuType: tier.shortLabel, profile: tier.rawValue, vramGB: 80,
                    count: 1 + index % 4, used: status == .idle ? 0 : 1
                )
                nodes.append(
                    ClusterNode(
                        name: "n\(index + 1)", gres: [gres], state: "up",
                        status: status, stateLabel: "up", jobs: []
                    ))
            }
            let snapshot = ClusterSnapshot(
                generatedAt: Date(timeIntervalSinceReferenceDate: 700_000_000), nodes: nodes,
                pending: []
            )
            let scape = CityScape.build(snapshot: snapshot)

            func assertClear(_ x: CGFloat, _ y: CGFloat, _ label: String) {
                // Bridge crossing corridor: the avenue legitimately enters.
                if x > 72, x < 84, y > 70, y < 104 { return }
                let s = (y - 28) / 112
                guard s >= -0.05, s <= 1.05 else { return }
                let clamped = min(max(s, 0), 1)
                let center = CityScape.riverCenter(clamped)
                let west = center.x - CityScape.riverHalfWidth(clamped)
                let east =
                    center.x + CityScape.riverHalfWidth(clamped)
                    + CityScape.riverLagoonBulge(clamped)
                XCTAssertFalse(
                    x > west - 2 && x < east + 2,
                    "\(label) at (\(x), \(y)) intrudes into the river band [\(west), \(east)] for \(nodeCount) nodes."
                )
            }

            for plot in scape.plots {
                assertClear(plot.x, plot.y, "plot \(plot.id) NW")
                assertClear(plot.x + plot.w, plot.y, "plot \(plot.id) NE")
                assertClear(plot.x, plot.y + plot.d, "plot \(plot.id) SW")
                assertClear(plot.x + plot.w, plot.y + plot.d, "plot \(plot.id) SE")
            }
            for plaza in scape.plazas {
                assertClear(plaza.x, plaza.y, "plaza \(plaza.blockID)")
            }
            for (streetIndex, street) in ([scape.avenue] + scape.localStreets).enumerated() {
                for (pointIndex, point) in street.enumerated() {
                    assertClear(point.0, point.1, "street \(streetIndex) point \(pointIndex)")
                }
            }
        }
    }
}
