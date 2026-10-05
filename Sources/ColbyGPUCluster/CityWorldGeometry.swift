import CoreGraphics
import SwiftUI

struct CityWorldPoint3D: Equatable, Sendable {
    let x: CGFloat
    let y: CGFloat
    let z: CGFloat

    var projected: CGPoint {
        IsoProjection.project(x, y, z)
    }
}

struct CityWorldSegment3D: Equatable, Sendable {
    let start: CityWorldPoint3D
    let end: CityWorldPoint3D
}

enum CityFacetLight: Equatable, Sendable {
    case top
    case left
    case right
}

struct CityProjectedFacet: Equatable, Sendable {
    let worldPoints: [CityWorldPoint3D]
    let panel: Int
    let light: CityFacetLight

    var projectedPoints: [CGPoint] {
        worldPoints.map(\.projected)
    }

    var path: Path {
        var path = Path()
        path.addLines(projectedPoints)
        path.closeSubpath()
        return path
    }

    var depth: CGFloat {
        worldPoints.reduce(0) { $0 + $1.x + $1.y } / CGFloat(max(worldPoints.count, 1))
    }
}
