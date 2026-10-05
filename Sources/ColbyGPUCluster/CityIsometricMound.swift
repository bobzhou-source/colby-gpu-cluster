import CoreGraphics
import SwiftUI

/// A restrained world-space terrain outcrop built from three broad isometric planes.
struct CityIsometricMoundGeometry: Equatable, Sendable {
    let baseX: CGFloat
    let baseY: CGFloat
    let height: CGFloat
    let radius: CGFloat

    let facets: [CityProjectedFacet]
    let contactShadowPath: Path
    let projectedBounds: CGRect

    init(x: CGFloat, y: CGFloat, height: CGFloat, radius: CGFloat) {
        self.baseX = x
        self.baseY = y
        self.height = height
        self.radius = radius

        let left = CityWorldPoint3D(x: x - radius * 0.9, y: y + radius * 0.2, z: 0)
        let back = CityWorldPoint3D(x: x - radius * 0.5, y: y - radius * 0.65, z: 0)
        let right = CityWorldPoint3D(x: x + radius * 0.55, y: y - radius * 0.85, z: 0)
        let front = CityWorldPoint3D(x: x + radius * 0.7, y: y + radius * 0.7, z: 0)
        let ridgeLeft = CityWorldPoint3D(
            x: x - radius * 0.15,
            y: y - radius * 0.2,
            z: height
        )
        let ridgeRight = CityWorldPoint3D(
            x: x + radius * 0.25,
            y: y - radius * 0.3,
            z: height * 0.88
        )

        self.facets = [
            CityProjectedFacet(
                worldPoints: [back, right, ridgeRight, ridgeLeft],
                panel: 0,
                light: .top
            ),
            CityProjectedFacet(
                worldPoints: [left, back, ridgeLeft, front],
                panel: 1,
                light: .left
            ),
            CityProjectedFacet(
                worldPoints: [front, ridgeLeft, ridgeRight, right],
                panel: 2,
                light: .right
            ),
        ].sorted { $0.depth < $1.depth }

        let base = [left, back, right, front]
        var shadow = Path()
        shadow.move(to: left.projected)
        for point in base.dropFirst() {
            shadow.addLine(to: point.projected)
        }
        shadow.closeSubpath()
        self.contactShadowPath = shadow

        let projected = (base + [ridgeLeft, ridgeRight]).map(\.projected)
        let minX = projected.map(\.x).min() ?? 0
        let maxX = projected.map(\.x).max() ?? 0
        let minY = projected.map(\.y).min() ?? 0
        let maxY = projected.map(\.y).max() ?? 0
        self.projectedBounds = CGRect(
            x: minX - 0.5,
            y: minY - 0.5,
            width: maxX - minX + 1,
            height: maxY - minY + 1
        )
    }
}
