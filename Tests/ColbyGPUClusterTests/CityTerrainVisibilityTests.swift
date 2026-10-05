import CoreGraphics
import Foundation
import XCTest

@testable import ColbyGPUCluster

@MainActor
final class CityTerrainVisibilityTests: XCTestCase {
    private let size = CGSize(width: 920, height: 720)

    func testProvinceFramingShowsAtLeastOneMountainMassif() {
        let scape = makeScape()
        let camera = provinceCamera(for: scape)
        let viewport = CGRect(origin: .zero, size: size)
        let paths = CitySceneStaticPaths(scape: scape)

        let visibleMountains = paths.mountains.filter { mountain in
            let apex = camera.apply(IsoProjection.project(
                mountain.x,
                mountain.y,
                mountain.height
            ))
            let anchor = camera.apply(IsoProjection.project(mountain.x, mountain.y))
            return viewport.insetBy(dx: 24, dy: 24).contains(apex)
                && viewport.insetBy(dx: 24, dy: 24).contains(anchor)
        }

        XCTAssertFalse(visibleMountains.isEmpty)
    }

    func testMountainFootprintUsesTheSameIsometricAxesAsCityLots() {
        let geometry = CityMountainGeometry(
            x: 12,
            y: 18,
            height: 8,
            radius: 4
        )

        XCTAssertEqual(geometry.apex, IsoProjection.project(12, 18, 8))
        XCTAssertEqual(geometry.right, IsoProjection.project(16, 14))
        XCTAssertEqual(geometry.near, IsoProjection.project(16, 22))
        XCTAssertEqual(geometry.left, IsoProjection.project(8, 22))
        XCTAssertNotEqual(geometry.right.y, geometry.near.y)
        XCTAssertNotEqual(geometry.near.y, geometry.left.y)
    }

    func testMountainFootprintsStayProportionalToTheirHeight() {
        let paths = CitySceneStaticPaths(scape: makeScape())

        XCTAssertTrue(paths.mountains.allSatisfy { $0.radius <= $0.height * 0.55 })
    }

    func testMountainHeightsStayWithinToyCityScale() {
        let paths = CitySceneStaticPaths(scape: makeScape())
        // Generator produces 6.5 + [0,7] range; rim scaling applied afterward
        let maximumMountainHeight: CGFloat = 13.5

        XCTAssertLessThanOrEqual(paths.mountains.map(\.height).max() ?? 0, maximumMountainHeight)
    }

    func testMountainFootprintsRemainVisuallySeparated() {
        let mountains = CitySceneStaticPaths(scape: makeScape()).mountains

        for leftIndex in mountains.indices {
            for rightIndex in mountains.indices where rightIndex > leftIndex {
                let left = mountains[leftIndex]
                let right = mountains[rightIndex]
                let separation = hypot(left.x - right.x, left.y - right.y)
                XCTAssertGreaterThanOrEqual(
                    separation,
                    (left.radius + right.radius) * 0.9,
                    "\(left) overlaps \(right)"
                )
            }
        }
    }

    func testEveryMountainFootprintHasVisibleTerrainMargin() {
        let paths = CitySceneStaticPaths(scape: makeScape())
        let safeTerrain = paths.groundWorldBounds.insetBy(dx: 2, dy: 2)

        XCTAssertFalse(paths.mountains.isEmpty)
        for mountain in paths.mountains {
            XCTAssertTrue(
                safeTerrain.contains(mountain.footprint),
                "\(mountain) extends beyond painted terrain"
            )
        }
    }

    func testMountainsStayOnFarNorthAndWestRims() {
        let paths = CitySceneStaticPaths(scape: makeScape())
        let center = CGPoint(
            x: paths.groundWorldBounds.midX,
            y: paths.groundWorldBounds.midY
        )

        XCTAssertTrue(paths.mountains.allSatisfy {
            $0.x <= center.x || $0.y <= center.y
        })
        XCTAssertTrue(paths.mountains.contains { $0.y < center.y })
        XCTAssertTrue(paths.mountains.contains { $0.x < center.x })
    }

    func testProvinceFramingContainsCompleteMountainGeometry() {
        let scape = makeScape()
        let paths = CitySceneStaticPaths(scape: scape)
        let camera = CityCamera.fitting(
            worldScreenBounds: CitySceneView.framedWorldBounds(
                scape: scape,
                staticPaths: paths
            ),
            in: size,
            margin: 24,
            labelInset: 30
        )
        let safeViewport = CGRect(origin: .zero, size: size)
            .insetBy(dx: 20, dy: 20)

        for mountain in paths.mountains {
            let worldBounds = mountain.projectedBounds
            let corners = [
                CGPoint(x: worldBounds.minX, y: worldBounds.minY),
                CGPoint(x: worldBounds.maxX, y: worldBounds.minY),
                CGPoint(x: worldBounds.maxX, y: worldBounds.maxY),
                CGPoint(x: worldBounds.minX, y: worldBounds.maxY),
            ].map(camera.apply)

            XCTAssertTrue(corners.allSatisfy(safeViewport.contains))
        }
    }

    func testWoodlandIsDenseAndContainsOneGiantClearingTree() {
        let paths = CitySceneStaticPaths(scape: makeScape())

        XCTAssertGreaterThan(paths.forest.count, 120)
        XCTAssertEqual(paths.forest.filter { $0.size >= 10 }.count, 1)
        XCTAssertEqual(paths.giantTree.size, 22)
        XCTAssertTrue(paths.forest.contains(paths.giantTree))
    }

    func testStaticTerrainRegistersMountainTitanAndForestOccluders() {
        let paths = CitySceneStaticPaths(scape: makeScape())
        let titan = CityRenderer.sleepingTitanGeometry(worldBounds: paths.groundWorldBounds)
        let mountainOccluders = paths.occluders.filter { $0.plotID == "terrain-mountain" }
        let titanOccluders = paths.occluders.filter { $0.plotID == "titan" }
        let forestOccluders = paths.occluders.filter { $0.plotID == "terrain-forest" }
        let giantTreeOccluders = paths.occluders.filter { $0.plotID == "terrain-giant-tree" }

        XCTAssertEqual(mountainOccluders.count, paths.mountains.count * 2)
        XCTAssertEqual(titanOccluders.count, titan.groundedSolids.count)
        XCTAssertEqual(
            forestOccluders.count,
            paths.forest.filter { $0 != paths.giantTree && $0.size >= 3 }.count
        )
        XCTAssertEqual(giantTreeOccluders.count, 1)
        XCTAssertEqual(
            paths.occupancy.footprints.filter { $0.tag == .terrain }.count,
            paths.mountains.count * 2 + 1
        )
    }

    func testProvinceFramingShowsBraidedIslandAwayFromViewportEdge() {
        let scape = makeScape()
        let camera = provinceCamera(for: scape)
        let islandMid = (
            CityScape.riverIslandRange.lowerBound
                + CityScape.riverIslandRange.upperBound
        ) / 2
        let islandWorld = CityScape.riverPoint(
            islandMid,
            lateral: CityScape.riverIslandLateral
        )
        let island = camera.apply(IsoProjection.project(islandWorld.x, islandWorld.y))

        XCTAssertGreaterThan(island.x, 40)
        XCTAssertLessThan(island.x, size.width - 120)
        XCTAssertGreaterThan(island.y, 40)
        XCTAssertLessThan(island.y, size.height - 40)
    }

    func testBraidedIslandOccupiesOpenWaterBetweenBridgeAndLagoon() {
        XCTAssertGreaterThanOrEqual(CityScape.riverIslandRange.lowerBound, 0.66)
        XCTAssertLessThanOrEqual(
            CityScape.riverIslandRange.upperBound,
            CityScape.riverLagoonRange.lowerBound
        )
    }

    private func makeScape() -> CityScape {
        var nodes: [ClusterNode] = []
        for index in 0..<9 {
            let tier = GPUTier.allCases[index % GPUTier.allCases.count]
            let resource = GPUResource(
                gpuType: tier.shortLabel,
                profile: tier.rawValue,
                vramGB: 80,
                count: 1,
                used: 0
            )
            nodes.append(ClusterNode(
                name: "n\(index + 1)",
                gres: [resource],
                state: "up",
                status: .idle,
                stateLabel: "up",
                jobs: []
            ))
        }
        let snapshot = ClusterSnapshot(
            generatedAt: Date(timeIntervalSinceReferenceDate: 700_000_000),
            nodes: nodes,
            pending: []
        )
        return CityScape.build(snapshot: snapshot)
    }

    private func provinceCamera(for scape: CityScape) -> CityCamera {
        CityCamera.fitting(
            worldScreenBounds: scape.plots
                .map { $0.screenBounds() }
                .reduce(CGRect.null) { $0.union($1) },
            in: size,
            margin: 24,
            labelInset: 30
        )
    }
}
