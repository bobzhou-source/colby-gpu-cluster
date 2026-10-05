import XCTest
@testable import ColbyGPUCluster

final class CityIsometricBalloonTests: XCTestCase {
    func testEnvelopeRowsTraceAnInflatedTeardropSilhouette() {
        let balloon = CityIsometricBalloonGeometry(x: 100, y: 100, z: 50, radius: 20)
        let rows = balloon.envelopeRows

        // Crown-to-mouth ordering with a single crown apex.
        XCTAssertEqual(rows[0].start, rows[0].end, "crown row is the degenerate apex")
        for index in 1..<rows.count {
            XCTAssertLessThan(rows[index].start.z, rows[index - 1].start.z, "rows descend crown to mouth")
            XCTAssertEqual(
                rows[index].start.z,
                rows[index].end.z,
                accuracy: 0.001,
                "both ends of a row share the slice height"
            )
        }

        // Rows span full diameters: left to right across the balloon axis.
        for row in rows {
            XCTAssertLessThanOrEqual(row.start.projected.x, row.end.projected.x)
            XCTAssertEqual((row.start.x + row.end.x) / 2, balloon.x, accuracy: 0.001)
            XCTAssertEqual((row.start.y + row.end.y) / 2, balloon.y, accuracy: 0.001)
        }

        func width(_ row: CityWorldSegment3D) -> CGFloat {
            row.end.projected.x - row.start.projected.x
        }
        let widths = rows.map(width)
        let equator = rows.indices.max { widths[$0] < widths[$1] } ?? 0

        // The mouth is far slimmer than the equator: a suspended teardrop,
        // not the old fan that stayed nearly as wide at the mouth.
        XCTAssertGreaterThan(equator, 0)
        XCTAssertLessThan(equator, rows.count - 1)
        XCTAssertLessThan(widths[rows.count - 1], widths[equator] * 0.5)

        // Inflation: interior rows bulge beyond the straight lines that
        // joined crown, equator, and mouth in the old kite envelope.
        for index in rows.indices where index > 0 && index < equator {
            let f = (rows[0].start.z - rows[index].start.z)
                / (rows[0].start.z - rows[equator].start.z)
            let linear = f * widths[equator] + (1 - f) * widths[0]
            XCTAssertGreaterThan(
                widths[index],
                linear,
                "row \(index) must bulge beyond the crown-equator chord"
            )
        }
        for index in rows.indices where index > equator && index < rows.count - 1 {
            let f = (rows[equator].start.z - rows[index].start.z)
                / (rows[equator].start.z - rows[rows.count - 1].start.z)
            let linear = widths[equator] + f * (widths[rows.count - 1] - widths[equator])
            XCTAssertGreaterThan(
                widths[index],
                linear,
                "row \(index) must hold the lower bulge beyond the equator-mouth chord"
            )
        }
    }

    func testEnvelopeOccupiesThreeDimensionalWorldSpace() {
        let balloon = CityIsometricBalloonGeometry(x: 50, y: 60, z: 100, radius: 15)
        let points = balloon.facets.flatMap(\.worldPoints)

        let xExtent = (points.map(\.x).max() ?? 0) - (points.map(\.x).min() ?? 0)
        let yExtent = (points.map(\.y).max() ?? 0) - (points.map(\.y).min() ?? 0)
        let zExtent = (points.map(\.z).max() ?? 0) - (points.map(\.z).min() ?? 0)
        let depths = points.map { $0.x + $0.y }
        let depthExtent = (depths.max() ?? 0) - (depths.min() ?? 0)

        XCTAssertGreaterThan(xExtent, 0)
        XCTAssertGreaterThan(yExtent, 0)
        XCTAssertGreaterThan(zExtent, 0)
        XCTAssertGreaterThan(depthExtent, 1e-6, "the skin must curve out of the silhouette plane")
    }

    func testFacetsTileTheCameraFacingHalfInPainterOrder() {
        let balloon = CityIsometricBalloonGeometry(x: 100, y: 100, z: 100, radius: 20)

        // Painter order: far to near, deterministically broken by panel.
        for index in 1..<balloon.facets.count {
            XCTAssertLessThanOrEqual(balloon.facets[index - 1].depth, balloon.facets[index].depth)
        }

        // The facet mosaic reaches the full silhouette: its projected width
        // matches the widest envelope row, so the rows and facets describe
        // the same inflated surface.
        let facetPoints = balloon.facets.flatMap(\.worldPoints)
        let facetMinX = facetPoints.map { $0.projected.x }.min() ?? 0
        let facetMaxX = facetPoints.map { $0.projected.x }.max() ?? 0
        let rowMinX = balloon.envelopeRows.map { $0.start.projected.x }.min() ?? 0
        let rowMaxX = balloon.envelopeRows.map { $0.end.projected.x }.max() ?? 0
        XCTAssertEqual(facetMinX, rowMinX, accuracy: 0.5)
        XCTAssertEqual(facetMaxX, rowMaxX, accuracy: 0.5)
    }

    func testBasketIsAProportionallySmallSuspendedLoad() {
        let balloon = CityIsometricBalloonGeometry(x: 50, y: 50, z: 100, radius: 20)


        // The whole load hangs below the narrow mouth with room for the
        // burner between the two.
        let lowestEnvelopeZ = balloon.envelopeRows.map(\.start.z).min() ?? .infinity
        let highestBasketZ = balloon.basket.flatMap(\.worldPoints).map(\.z).max() ?? -.infinity
        XCTAssertLessThan(highestBasketZ, lowestEnvelopeZ)

        // It reads as a small wicker load under a big inflated envelope.
        let topFacet = balloon.basket.first { $0.light == .top }
        XCTAssertNotNil(topFacet)
        if let topFacet = topFacet {
            XCTAssertEqual(topFacet.worldPoints.count, 4, "rigging corners need the full rim quad")
            let basketWidth = (topFacet.projectedPoints.map(\.x).max() ?? 0)
                - (topFacet.projectedPoints.map(\.x).min() ?? 0)
            let widestRowWidth = balloon.envelopeRows
                .map { $0.end.projected.x - $0.start.projected.x }
                .max() ?? 0
            XCTAssertLessThan(basketWidth, widestRowWidth / 3)
        }
    }

    func testDeterministicOutput() {
        let first = CityIsometricBalloonGeometry(x: 10, y: 20, z: 30, radius: 5)
        let second = CityIsometricBalloonGeometry(x: 10, y: 20, z: 30, radius: 5)

        XCTAssertEqual(first, second)
    }

    func testProjectedBoundsTrackTheTrueSilhouette() {
        let balloon = CityIsometricBalloonGeometry(x: 0, y: 0, z: 50, radius: 15)
        let points = balloon.facets.flatMap(\.worldPoints)
            + balloon.envelopeRows.flatMap { [$0.start, $0.end] }
            + balloon.basket.flatMap(\.worldPoints)
            + [balloon.burnerCenter, balloon.basketTopCenter,
               balloon.basketFrontBand.start, balloon.basketFrontBand.end]

        XCTAssertFalse(balloon.projectedBounds.isEmpty)
        XCTAssertTrue(points.allSatisfy { balloon.projectedBounds.contains($0.projected) })


        // The upper back dome rides above the crown apex on screen under the
        // oblique projection; the bounds account for that volume instead of
        // clipping it.
        let crown = balloon.envelopeRows[0].start.projected
        XCTAssertTrue(balloon.facets.flatMap(\.projectedPoints).contains { $0.y < crown.y },
                      "the elevated camera must see the upper back dome, not just the front half")
        XCTAssertLessThanOrEqual(balloon.projectedBounds.minY, crown.y)
    }
}