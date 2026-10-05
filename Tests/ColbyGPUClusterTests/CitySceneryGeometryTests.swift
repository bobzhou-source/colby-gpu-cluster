import CoreGraphics
import XCTest
@testable import ColbyGPUCluster

final class CitySceneryGeometryTests: XCTestCase {

    func testConstructionTapeFormsStripedPerimeterOnFourPosts() {
        let geometry = CityConstructionTapeGeometry(x: 10, y: 20, width: 5, depth: 4)

        XCTAssertEqual(geometry.posts.count, 4)
        XCTAssertTrue(geometry.posts.allSatisfy { $0.baseZ == 0.05 && $0.topZ == geometry.tapeZ + 0.18 })
        XCTAssertGreaterThanOrEqual(geometry.tapeSegments.count, 8)
        XCTAssertEqual(Set(geometry.tapeSegments.map(\.stripe)), [.yellow, .ink])
        
        // Tape sags between posts: bounded sag with alternating stripes
        let allZ = geometry.tapeSegments.flatMap { [$0.startZ, $0.endZ] }
        let minZ = allZ.min() ?? geometry.tapeZ
        let maxZ = allZ.max() ?? geometry.tapeZ
        XCTAssertLessThan(minZ, geometry.tapeZ, "Tape must sag below base level between posts")
        XCTAssertLessThanOrEqual(maxZ, geometry.tapeZ, "Tape endpoints must not exceed post height")
        XCTAssertGreaterThan(geometry.tapeZ - minZ, 0.3, "Sag must be visibly bounded")
        XCTAssertLessThan(geometry.tapeZ - minZ, 1.0, "Sag must be bounded to prevent ground collision")
    }
}
