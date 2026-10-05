import CoreGraphics
import Testing
@testable import ColbyGPUCluster

@Suite("CityIsometricMound Tests")
struct CityIsometricMoundTests {
    @Test("Three broad planes match native terrain grammar")
    func nativeFacetBudget() {
        let mound = CityIsometricMoundGeometry(x: 100, y: 100, height: 50, radius: 30)

        #expect(mound.facets.count == 3)
        #expect(mound.facets.map(\.panel).sorted() == [0, 1, 2])
        #expect(Set(mound.facets.map(\.light)) == [.top, .left, .right])
        #expect(mound.facets.allSatisfy { $0.worldPoints.count == 4 })
    }

    @Test("Projected bounds contain every terrain vertex")
    func completeBounds() {
        let mound = CityIsometricMoundGeometry(x: 100, y: 100, height: 50, radius: 30)

        #expect(!mound.projectedBounds.isEmpty)
        #expect(mound.facets.flatMap(\.worldPoints).allSatisfy {
            mound.projectedBounds.contains($0.projected)
        })
        #expect(!mound.contactShadowPath.isEmpty)
    }

    @Test("World origin translates every point")
    func worldTranslation() {
        let first = CityIsometricMoundGeometry(x: 0, y: 0, height: 20, radius: 10)
        let second = CityIsometricMoundGeometry(x: 7, y: 11, height: 20, radius: 10)

        for (left, right) in zip(first.facets, second.facets) {
            for (leftPoint, rightPoint) in zip(left.worldPoints, right.worldPoints) {
                #expect(abs(rightPoint.x - leftPoint.x - 7) < 0.000_001)
                #expect(abs(rightPoint.y - leftPoint.y - 11) < 0.000_001)
                #expect(abs(rightPoint.z - leftPoint.z) < 0.000_001)
            }
        }
    }

    @Test("Radius and height control independent dimensions")
    func dimensions() {
        let base = CityIsometricMoundGeometry(x: 0, y: 0, height: 20, radius: 10)
        let wider = CityIsometricMoundGeometry(x: 0, y: 0, height: 20, radius: 20)
        let taller = CityIsometricMoundGeometry(x: 0, y: 0, height: 40, radius: 10)
        let basePoints = base.facets.flatMap(\.worldPoints)
        let widerPoints = wider.facets.flatMap(\.worldPoints)
        let tallerPoints = taller.facets.flatMap(\.worldPoints)

        let baseWidth = (basePoints.map(\.x).max() ?? 0) - (basePoints.map(\.x).min() ?? 0)
        let widerWidth = (widerPoints.map(\.x).max() ?? 0) - (widerPoints.map(\.x).min() ?? 0)
        let baseHeight = basePoints.map(\.z).max() ?? 0
        let tallerHeight = tallerPoints.map(\.z).max() ?? 0
        #expect(widerWidth > baseWidth)
        #expect(tallerHeight > baseHeight)
    }

    @Test("Geometry and painter order are deterministic")
    func deterministicAndSorted() {
        let first = CityIsometricMoundGeometry(x: 42, y: 19, height: 17, radius: 8)
        let second = CityIsometricMoundGeometry(x: 42, y: 19, height: 17, radius: 8)

        #expect(first == second)
        for index in 1..<first.facets.count {
            #expect(first.facets[index].depth >= first.facets[index - 1].depth)
        }
    }
}
