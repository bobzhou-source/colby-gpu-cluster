import CoreGraphics

enum CityExtrudedSideShade: Equatable, Sendable {
    case right
    case left
}

struct CityProjectedSideFace: Equatable, Sendable {
    let edgeIndex: Int
    let shade: CityExtrudedSideShade
    let points: [CGPoint]
}

struct CityExtrudedFootprint: Equatable, Sendable {
    let projectedTop: [CGPoint]
    let visibleSides: [CityProjectedSideFace]

    init(vertices: [CGPoint], lowerZ: CGFloat, upperZ: CGFloat) {
        precondition(vertices.count >= 3)
        precondition(upperZ >= lowerZ)

        projectedTop = vertices.map { vertex in
            IsoProjection.project(vertex.x, vertex.y, upperZ)
        }

        var sides: [CityProjectedSideFace] = []
        sides.reserveCapacity(vertices.count / 2 + 1)
        for edgeIndex in vertices.indices {
            let start = vertices[edgeIndex]
            let end = vertices[(edgeIndex + 1) % vertices.count]
            let dx = end.x - start.x
            let dy = end.y - start.y

            // The fixed city camera sees outward faces whose normal points
            // toward positive world x/y. Edge-on faces have no raster area.
            guard dy - dx > 0 else { continue }
            let shade: CityExtrudedSideShade = dy >= -dx ? .right : .left
            sides.append(CityProjectedSideFace(
                edgeIndex: edgeIndex,
                shade: shade,
                points: [
                    IsoProjection.project(start.x, start.y, upperZ),
                    IsoProjection.project(start.x, start.y, lowerZ),
                    IsoProjection.project(end.x, end.y, lowerZ),
                    IsoProjection.project(end.x, end.y, upperZ),
                ]
            ))
        }
        visibleSides = sides
    }
}
