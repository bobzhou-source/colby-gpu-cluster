import CoreGraphics
import XCTest
@testable import ColbyGPUCluster

final class CityExtrudedFootprintTests: XCTestCase {
    func testProjectsEveryTopVertexThroughIsoProjection() {
        let vertices = [
            CGPoint(x: 2, y: 3),
            CGPoint(x: 6, y: 3),
            CGPoint(x: 7, y: 5),
            CGPoint(x: 4, y: 8),
            CGPoint(x: 1, y: 6),
        ]
        let solid = CityExtrudedFootprint(vertices: vertices, lowerZ: 1, upperZ: 7)

        XCTAssertEqual(
            solid.projectedTop,
            vertices.map { IsoProjection.project($0.x, $0.y, 7) }
        )
    }

    func testRectangleEmitsOnlyCameraFacingSidesInStableOrder() {
        let solid = CityExtrudedFootprint(
            vertices: [
                CGPoint(x: 2, y: 3),
                CGPoint(x: 6, y: 3),
                CGPoint(x: 6, y: 8),
                CGPoint(x: 2, y: 8),
            ],
            lowerZ: 1,
            upperZ: 7
        )

        XCTAssertEqual(solid.visibleSides.map(\.edgeIndex), [1, 2])
        XCTAssertEqual(solid.visibleSides.map(\.shade), [.right, .left])
        XCTAssertEqual(
            solid.visibleSides[0].points,
            [
                IsoProjection.project(6, 3, 7),
                IsoProjection.project(6, 3, 1),
                IsoProjection.project(6, 8, 1),
                IsoProjection.project(6, 8, 7),
            ]
        )
        XCTAssertEqual(
            solid.visibleSides[1].points,
            [
                IsoProjection.project(6, 8, 7),
                IsoProjection.project(6, 8, 1),
                IsoProjection.project(2, 8, 1),
                IsoProjection.project(2, 8, 7),
            ]
        )
    }

    func testClippedHullProducesMultiplePlanarVisibleSides() {
        let solid = CityExtrudedFootprint(
            vertices: [
                CGPoint(x: -3, y: -1),
                CGPoint(x: -1, y: -3),
                CGPoint(x: 2, y: -3),
                CGPoint(x: 4, y: -1),
                CGPoint(x: 4, y: 1),
                CGPoint(x: 2, y: 3),
                CGPoint(x: -1, y: 3),
                CGPoint(x: -3, y: 1),
            ],
            lowerZ: 9,
            upperZ: 11
        )

        XCTAssertEqual(solid.visibleSides.map(\.edgeIndex), [3, 4, 5])
        XCTAssertEqual(solid.visibleSides.map(\.shade), [.right, .right, .left])
        XCTAssertTrue(solid.visibleSides.allSatisfy { $0.points.count == 4 })
    }
}
