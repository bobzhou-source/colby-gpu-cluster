import CoreGraphics

enum IsoProjection {
    static let s: CGFloat = 5.5
    static let fy: CGFloat = 3.4
    static let fz: CGFloat = 5.5
    static let ox: CGFloat = 250
    static let oy: CGFloat = 30

    static func project(_ x: CGFloat, _ y: CGFloat, _ z: CGFloat = 0) -> CGPoint {
        CGPoint(x: (x - y) * s + ox, y: (x + y) * fy - z * fz + oy)
    }

    /// Inverse at z = 0 (hit-testing).
    static func unproject(_ p: CGPoint) -> (x: CGFloat, y: CGFloat) {
        let a = (p.x - ox) / s
        let b = (p.y - oy) / fy
        return ((a + b) / 2, (b - a) / 2)
    }

    /// Painter order: larger key draws later (nearer camera).
    static func sortKey(x: CGFloat, y: CGFloat) -> CGFloat { x + y }
}
