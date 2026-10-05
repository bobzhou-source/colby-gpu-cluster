import CoreGraphics

struct CityDetailLevel: Equatable, Sendable {
    static let windows: ClosedRange<CGFloat> = 1.05...1.35
    static let streetDetail: ClosedRange<CGFloat> = 1.2...1.6
    static let shopDressing: ClosedRange<CGFloat> = 2.0...2.6
    /// Actors fade in from mid city zoom so the data-driven life (workers,
    /// shoppers) is visible well before street level.
    static let actors: ClosedRange<CGFloat> = 1.15...1.6

    let scale: CGFloat
    let band: ZoomBand

    func fade(_ range: ClosedRange<CGFloat>) -> Double {
        guard range.upperBound > range.lowerBound else {
            return scale >= range.upperBound ? 1 : 0
        }
        guard scale > range.lowerBound else { return 0 }
        guard scale < range.upperBound else { return 1 }

        let t = Double((scale - range.lowerBound) / (range.upperBound - range.lowerBound))
        return t * t * (3 - 2 * t)
    }
}
