import CoreGraphics

enum CityTapeStripe: Hashable {
    case yellow
    case ink
}

struct CityTapeSegment: Equatable {
    let start: CGPoint
    let end: CGPoint
    let startZ: CGFloat
    let endZ: CGFloat
    let stripe: CityTapeStripe
}

struct CityTapePost: Equatable {
    let point: CGPoint
    let baseZ: CGFloat
    let topZ: CGFloat
}

struct CityConstructionTapeGeometry {
    let tapeZ: CGFloat = 1.55
    let posts: [CityTapePost]
    let tapeSegments: [CityTapeSegment]

    init(x: CGFloat, y: CGFloat, width: CGFloat, depth: CGFloat, piecesPerEdge: Int = 6) {
        let pad: CGFloat = 1.2
        let corners = [
            CGPoint(x: x - pad, y: y - pad),
            CGPoint(x: x + width + pad, y: y - pad),
            CGPoint(x: x + width + pad, y: y + depth + pad),
            CGPoint(x: x - pad, y: y + depth + pad),
        ]
        posts = corners.map { CityTapePost(point: $0, baseZ: 0.05, topZ: 1.73) }
        var segments: [CityTapeSegment] = []
        for edgeIndex in corners.indices {
            let start = corners[edgeIndex]
            let end = corners[(edgeIndex + 1) % corners.count]
            // Caution tape sags between posts: split each edge into striped
            // pieces whose joints dip, so the strand reads as hung rope.
            let pieces = max(2, piecesPerEdge)
            let sag: CGFloat = 0.65
            func strandZ(_ t: CGFloat) -> CGFloat {
                // Parabolic sag: maximum at edge middle (t=0.5), zero at posts (t=0, t=1)
                let sagFactor = 4 * t * (1 - t)  // 0 at t=0,1; 1 at t=0.5
                return 1.55 - sag * sagFactor
            }
            for piece in 0..<pieces {
                let t0 = CGFloat(piece) / CGFloat(pieces)
                let t1 = CGFloat(piece + 1) / CGFloat(pieces)
                let a = CGPoint(x: start.x + (end.x - start.x) * t0, y: start.y + (end.y - start.y) * t0)
                let b = CGPoint(x: start.x + (end.x - start.x) * t1, y: start.y + (end.y - start.y) * t1)
                segments.append(CityTapeSegment(
                    start: a,
                    end: b,
                    startZ: strandZ(t0),
                    endZ: strandZ(t1),
                    stripe: (edgeIndex + piece).isMultiple(of: 2) ? .yellow : .ink
                ))
            }
        }
        tapeSegments = segments
    }
}
