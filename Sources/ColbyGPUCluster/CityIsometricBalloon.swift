import CoreGraphics
import SwiftUI

/// Native world-space isometric balloon geometry with an inflated faceted
/// envelope, burner, and suspended basket.
struct CityIsometricBalloonGeometry: Equatable, Sendable {
    let x: CGFloat
    let y: CGFloat
    let z: CGFloat
    let radius: CGFloat

    /// Visible facets of the complete inflated envelope, sorted far to near.
    /// Elevated viewing exposes part of the back dome as well as the front.
    /// Mirrored meridians share the eight fabric-panel colors.
    let facets: [CityProjectedFacet]

    /// Horizontal silhouette chords ordered crown to mouth. Each row spans a
    /// full diameter of the envelope at that height: `start` is the left
    /// silhouette world point (meridian 135°), `end` the right (meridian
    /// −45°), both ends share the row's z, the midpoint sits on the balloon
    /// axis at (x, y), and `(end.x - start.x) / √2` recovers the slice circle
    /// radius. The first row is the degenerate crown apex; the last is the
    /// narrow mouth.
    let envelopeRows: [CityWorldSegment3D]
    let burnerCenter: CityWorldPoint3D
    let basket: [CityProjectedFacet]
    let basketTopCenter: CityWorldPoint3D
    let basketFrontBand: CityWorldSegment3D
    let cloudBackBounds: CGRect
    let cloudFrontBounds: CGRect
    let projectedBounds: CGRect

    init(x: CGFloat, y: CGFloat, z: CGFloat, radius: CGFloat) {
        self.x = x
        self.y = y
        self.z = z
        self.radius = radius

        // Authored interpretation: the crown rides at z + 1.15r and the whole
        // inflated envelope hangs above a small suspended basket.
        let crownZ = z + radius * 1.15
        let envelopeHeight = radius * 2.0
        let widestRadius = radius * 0.70
        let equator = CGFloat(0.30)
        let lowerBulgeEnd = CGFloat(0.62)
        let rootTwo = CGFloat(2).squareRoot()

        // Teardrop profile of revolution about the vertical axis at (x, y):
        // a spherical crown dome swells to the equator, eases across the
        // lower bulge, then contracts into the narrow neck.
        func profileRadius(_ t: CGFloat) -> CGFloat {
            if t <= equator {
                let rise = (equator - t) / equator
                return widestRadius * (1 - rise * rise).squareRoot()
            }
            if t <= lowerBulgeEnd {
                let u = (t - equator) / (lowerBulgeEnd - equator)
                return widestRadius * (1 - 0.14 * u * u * (3 - 2 * u))
            }
            let u = (t - lowerBulgeEnd) / (1 - lowerBulgeEnd)
            return widestRadius * (0.86 - 0.64 * u * u * (1.2 - 0.2 * u))
        }

        // Silhouette rows crown to mouth. Offsetting each slice radius by
        // 1/√2 places the row endpoints on the meridians that project to the
        // exact screen left/right extremes of the horizontal slice circle.
        let rowFractions: [CGFloat] = [
            0, 0.05, 0.10, 0.16, 0.23, 0.30, 0.40, 0.50, 0.62, 0.74, 0.86, 0.94, 1.0,
        ]
        var rows = [CityWorldSegment3D]()
        rows.reserveCapacity(rowFractions.count)
        for t in rowFractions {
            let offset = profileRadius(t) / rootTwo
            let height = crownZ - envelopeHeight * t
            rows.append(CityWorldSegment3D(
                start: CityWorldPoint3D(x: x - offset, y: y + offset, z: height),
                end: CityWorldPoint3D(x: x + offset, y: y - offset, z: height)
            ))
        }
        self.envelopeRows = rows

        // Build the whole surface, then cull by its outward normal. Keeping
        // only the front angular half would cut away the upper back dome,
        // which is visible from the elevated isometric camera.
        let bandCount = 16
        let startAngle = -CGFloat.pi / 4
        let meridians = (0...bandCount).map { band in
            let angle = startAngle + 2 * CGFloat.pi * CGFloat(band) / CGFloat(bandCount)
            return CGPoint(x: cos(angle), y: sin(angle))
        }
        var vertices = [CityWorldPoint3D]()
        vertices.reserveCapacity(meridians.count * rows.count)
        for row in rows {
            let sliceRadius = (row.end.x - row.start.x) / rootTwo
            for direction in meridians {
                vertices.append(CityWorldPoint3D(
                    x: x + sliceRadius * direction.x,
                    y: y + sliceRadius * direction.y,
                    z: row.start.z
                ))
            }
        }
        func surfacePoint(meridian: Int, row: Int) -> CityWorldPoint3D {
            vertices[row * meridians.count + meridian]
        }
        let viewZ = 2 * IsoProjection.fy / IsoProjection.fz
        var envelopeFacets = [CityProjectedFacet]()
        envelopeFacets.reserveCapacity(bandCount * (rowFractions.count - 1))
        for band in 0..<bandCount {
            for row in 1..<rowFractions.count {
                let worldPoints: [CityWorldPoint3D]
                if row == 1 {
                    // Crown cap: the first row degenerates to the apex.
                    worldPoints = [
                        surfacePoint(meridian: band, row: 1),
                        surfacePoint(meridian: band + 1, row: 1),
                        CityWorldPoint3D(x: x, y: y, z: crownZ),
                    ]
                } else {
                    worldPoints = [
                        surfacePoint(meridian: band, row: row),
                        surfacePoint(meridian: band + 1, row: row),
                        surfacePoint(meridian: band + 1, row: row - 1),
                        surfacePoint(meridian: band, row: row - 1),
                    ]
                }
                let ux = worldPoints[1].x - worldPoints[0].x
                let uy = worldPoints[1].y - worldPoints[0].y
                let uz = worldPoints[1].z - worldPoints[0].z
                let vx = worldPoints[2].x - worldPoints[0].x
                let vy = worldPoints[2].y - worldPoints[0].y
                let vz = worldPoints[2].z - worldPoints[0].z
                let nx = uy * vz - uz * vy
                let ny = uz * vx - ux * vz
                let nz = ux * vy - uy * vx
                guard nx + ny + nz * viewZ > 0 else { continue }
                let light: CityFacetLight = nz > max(abs(nx), abs(ny))
                    ? .top : nx > ny ? .right : .left
                let panel = band < 8 ? band : 15 - band
                envelopeFacets.append(
                    CityProjectedFacet(worldPoints: worldPoints, panel: panel, light: light)
                )
            }
        }
        let facets = envelopeFacets.sorted {
            $0.depth == $1.depth ? $0.panel < $1.panel : $0.depth < $1.depth
        }
        self.facets = facets

        // The mouth diameter (last row) drives the burner placement below
        // the narrow neck.
        let neckShadow = rows[rowFractions.count - 1]

        // A proportionally small wicker load suspended well below the mouth.
        let basketWidth = radius * 0.30
        let basketHeight = radius * 0.20
        let basketTopZ = z - radius * 1.25
        let half = basketWidth / 2
        let bottomZ = basketTopZ - basketHeight
        let corners = [
            CityWorldPoint3D(x: x - half, y: y - half, z: bottomZ),
            CityWorldPoint3D(x: x + half, y: y - half, z: bottomZ),
            CityWorldPoint3D(x: x + half, y: y + half, z: bottomZ),
            CityWorldPoint3D(x: x - half, y: y + half, z: bottomZ),
            CityWorldPoint3D(x: x - half, y: y - half, z: basketTopZ),
            CityWorldPoint3D(x: x + half, y: y - half, z: basketTopZ),
            CityWorldPoint3D(x: x + half, y: y + half, z: basketTopZ),
            CityWorldPoint3D(x: x - half, y: y + half, z: basketTopZ),
        ]
        self.basket = [
            CityProjectedFacet(
                worldPoints: [corners[4], corners[5], corners[6], corners[7]],
                panel: 0,
                light: .top
            ),
            CityProjectedFacet(
                worldPoints: [corners[1], corners[2], corners[6], corners[5]],
                panel: 1,
                light: .right
            ),
            CityProjectedFacet(
                worldPoints: [corners[3], corners[2], corners[6], corners[7]],
                panel: 2,
                light: .left
            ),
        ]

        let basketTopCenter = CityWorldPoint3D(x: x, y: y, z: basketTopZ)
        self.basketTopCenter = basketTopCenter
        let basketFrontBand = CityWorldSegment3D(
            start: CityWorldPoint3D(
                x: x - half,
                y: y + half,
                z: bottomZ + basketHeight * 0.62
            ),
            end: CityWorldPoint3D(
                x: x + half,
                y: y + half,
                z: bottomZ + basketHeight * 0.62
            )
        )
        self.basketFrontBand = basketFrontBand

        // The burner hangs midway between the narrow mouth and the basket rim.
        let burnerCenter = CityWorldPoint3D(
            x: (neckShadow.start.x + neckShadow.end.x + basketTopCenter.x * 2) / 4,
            y: (neckShadow.start.y + neckShadow.end.y + basketTopCenter.y * 2) / 4,
            z: (neckShadow.start.z + neckShadow.end.z + basketTopCenter.z * 2) / 4
        )
        self.burnerCenter = burnerCenter

        // Each horizontal slice projects to an axis-aligned ellipse, so the
        // true projected silhouette is the union of those ellipses. Sample the
        // profile finely: the upper back dome rides visibly above the crown
        // apex on screen, beyond what the front-half facets reach.
        let sliceCount = 64
        let axisScreenX = (x - y) * IsoProjection.s + IsoProjection.ox
        var sliceMinX = axisScreenX
        var sliceMaxX = axisScreenX
        var sliceMinY = CGFloat.infinity
        var sliceMaxY = -CGFloat.infinity
        for index in 0...sliceCount {
            let t = CGFloat(index) / CGFloat(sliceCount)
            let centerY = (x + y) * IsoProjection.fy
                - (crownZ - envelopeHeight * t) * IsoProjection.fz
                + IsoProjection.oy
            let sliceRadius = profileRadius(t) * rootTwo
            let semiX = sliceRadius * IsoProjection.s
            let semiY = sliceRadius * IsoProjection.fy
            sliceMinX = min(sliceMinX, axisScreenX - semiX)
            sliceMaxX = max(sliceMaxX, axisScreenX + semiX)
            sliceMinY = min(sliceMinY, centerY - semiY)
            sliceMaxY = max(sliceMaxY, centerY + semiY)
        }
        let sliceBounds = CGRect(
            x: sliceMinX,
            y: sliceMinY,
            width: sliceMaxX - sliceMinX,
            height: sliceMaxY - sliceMinY
        )
        let projectedRadius = max(min(sliceBounds.width, sliceBounds.height) / 2, 0.5)
        let cloudBackBounds = CGRect(
            x: sliceMinX - projectedRadius * 0.30,
            y: (sliceMinY + sliceMaxY) / 2 + projectedRadius * 0.22,
            width: projectedRadius * 0.68,
            height: projectedRadius * 0.28
        )
        let cloudFrontBounds = CGRect(
            x: sliceMaxX - projectedRadius * 0.38,
            y: (sliceMinY + sliceMaxY) / 2 + projectedRadius * 0.38,
            width: projectedRadius * 0.46,
            height: projectedRadius * 0.22
        )
        self.cloudBackBounds = cloudBackBounds
        self.cloudFrontBounds = cloudFrontBounds

        let anchorPoints = [
            burnerCenter,
            basketTopCenter,
            basketFrontBand.start,
            basketFrontBand.end,
        ]
        let points = facets.flatMap(\.worldPoints) + corners + anchorPoints
        let projected = points.map(\.projected)
        let minX = min(sliceMinX, projected.map(\.x).min() ?? sliceMinX)
        let maxX = max(sliceMaxX, projected.map(\.x).max() ?? sliceMaxX)
        let minY = min(sliceMinY, projected.map(\.y).min() ?? sliceMinY)
        let maxY = max(sliceMaxY, projected.map(\.y).max() ?? sliceMaxY)
        let geometryBounds = CGRect(
            x: minX - 0.5,
            y: minY - 0.5,
            width: maxX - minX + 1,
            height: maxY - minY + 1
        )
        self.projectedBounds = geometryBounds
            .union(cloudBackBounds)
            .union(cloudFrontBounds)
    }
}