import CoreGraphics
import XCTest
@testable import ColbyGPUCluster

@MainActor
final class CityRenderPlanTests: XCTestCase {
    func testVisiblePlotsComeFromStaticRenderBounds() throws {
        let scape = CityScape.build(snapshot: try snapshot(sinfo: """
        h200-01|idle|gpu:H200:1
        a100-01|idle|gpu:A100:1
        l40s-01|idle|gpu:L40S:1
        """))
        let staticPaths = CitySceneStaticPaths(scape: scape)
        let targetPlot = try XCTUnwrap(scape.sortedPlots.dropFirst().first)
        let targetBounds = try XCTUnwrap(staticPaths.renderBoundsByPlotID[targetPlot.id])
        let camera = CityCamera(
            scale: 2,
            translation: CGSize(
                width: -targetBounds.midX * 2 + 100,
                height: -targetBounds.midY * 2 + 100
            )
        )

        let plan = CityRenderPlan(
            scape: scape,
            staticPaths: staticPaths,
            camera: camera,
            size: CGSize(width: 200, height: 200),
            band: .city
        )
        let expectedVisiblePlotIDs = scape.sortedPlots
            .filter { staticPaths.renderBoundsByPlotID[$0.id, default: .null].intersects(plan.visibleRect) }
            .map(\.id)

        XCTAssertEqual(plan.visiblePlots.map(\.id), expectedVisiblePlotIDs)
        XCTAssertEqual(plan.visibleRect, CGRect(x: targetBounds.midX - 50, y: targetBounds.midY - 50, width: 100, height: 100))
        XCTAssertTrue(plan.visiblePlots.contains { $0.id == targetPlot.id })
    }

    func testBandAndLifeScalePropagateFromOnePlanInput() throws {
        let scape = CityScape.build(snapshot: try snapshot(sinfo: "h200-01|idle|gpu:H200:1"))
        let staticPaths = CitySceneStaticPaths(scape: scape)

        let streetPlan = CityRenderPlan(
            scape: scape,
            staticPaths: staticPaths,
            camera: CityCamera(scale: 2.7, translation: .zero),
            size: CGSize(width: 320, height: 240),
            band: .street
        )
        let provincePlan = CityRenderPlan(
            scape: scape,
            staticPaths: staticPaths,
            camera: CityCamera(scale: 0.9, translation: .zero),
            size: CGSize(width: 320, height: 240),
            band: .province
        )

        XCTAssertEqual(streetPlan.band, .street)
        XCTAssertEqual(provincePlan.band, .province)
        XCTAssertLessThan(provincePlan.lifeScale.smokeRadius, streetPlan.lifeScale.smokeRadius)
        XCTAssertLessThan(provincePlan.lifeScale.fireworkRadius, streetPlan.lifeScale.fireworkRadius)
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
