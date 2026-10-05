import CoreGraphics

struct CityCamera: Equatable, Sendable {
    var scale: CGFloat
    var translation: CGSize

    static let scaleRange: ClosedRange<CGFloat> = 0.6...8.0
    /// Allows fitted cameras below the interactive range while keeping inversion finite.
    static let minimumScale: CGFloat = 0.000_001

    func apply(_ p: CGPoint) -> CGPoint {
        CGPoint(
            x: p.x * scale + translation.width,
            y: p.y * scale + translation.height
        )
    }

    func invert(_ p: CGPoint) -> CGPoint {
        CGPoint(
            x: (p.x - translation.width) / scale,
            y: (p.y - translation.height) / scale
        )
    }

    mutating func zoom(by factor: CGFloat, anchor: CGPoint) {
        scale = Self.sanitizedScale(scale)
        let worldAtAnchor = invert(anchor)
        let requestedScale = scale * factor
        scale = scale < Self.scaleRange.lowerBound && requestedScale < Self.scaleRange.lowerBound
            ? Self.sanitizedScale(requestedScale)
            : requestedScale.clamped(to: Self.scaleRange)
        translation = CGSize(
            width: anchor.x - worldAtAnchor.x * scale,
            height: anchor.y - worldAtAnchor.y * scale
        )
    }


    private static func sanitizedScale(_ scale: CGFloat) -> CGFloat {
        guard scale.isFinite else { return minimumScale }
        return min(max(scale, minimumScale), scaleRange.upperBound)
    }
    mutating func clampTranslation(worldScreenBounds: CGRect, viewport: CGSize) {
        guard !worldScreenBounds.isNull, !worldScreenBounds.isEmpty,
              viewport.width > 0, viewport.height > 0 else { return }

        let scaled = CGRect(
            x: worldScreenBounds.minX * scale,
            y: worldScreenBounds.minY * scale,
            width: worldScreenBounds.width * scale,
            height: worldScreenBounds.height * scale
        )
        let requiredVisibleWidth = min(scaled.width * 0.2, viewport.width)
        let requiredVisibleHeight = min(scaled.height * 0.2, viewport.height)
        let xRange = (requiredVisibleWidth - scaled.maxX)...(viewport.width - requiredVisibleWidth - scaled.minX)
        let yRange = (requiredVisibleHeight - scaled.maxY)...(viewport.height - requiredVisibleHeight - scaled.minY)
        translation = CGSize(
            width: translation.width.clamped(to: xRange),
            height: translation.height.clamped(to: yRange)
        )
    }

    /// Fits the world bounds into the viewport. `labelInset` reserves extra
    /// screen room below the content for the label stacks that hang beneath
    /// the lowest plots, biasing the chain toward frame center.
    static func fitting(worldScreenBounds: CGRect, in viewport: CGSize, margin: CGFloat, labelInset: CGFloat = 0) -> CityCamera {
        guard !worldScreenBounds.isNull, !worldScreenBounds.isEmpty,
              viewport.width > 0, viewport.height > 0 else {
            return CityCamera(scale: 1, translation: .zero)
        }

        let usableWidth = max(0, viewport.width - margin * 2)
        let usableHeight = max(0, viewport.height - margin * 2 - labelInset)
        let requestedFittingScale = min(
            usableWidth / worldScreenBounds.width,
            usableHeight / worldScreenBounds.height
        )
        let fittingScale = sanitizedScale(requestedFittingScale.nextDown)
        var camera = CityCamera(
            scale: fittingScale,
            translation: CGSize(
                width: viewport.width / 2 - worldScreenBounds.midX * fittingScale,
                height: (viewport.height - labelInset) / 2 - worldScreenBounds.midY * fittingScale
            )
        )
        camera.clampTranslation(worldScreenBounds: worldScreenBounds, viewport: viewport)
        return camera
    }
}

enum ZoomBand: Equatable, Sendable {
    case province
    case city
    case street

    init(scale: CGFloat) {
        switch scale {
        case ..<1.2:
            self = .province
        case ..<2.6:
            self = .city
        default:
            self = .street
        }
    }

    static func next(from current: ZoomBand, scale: CGFloat) -> ZoomBand {
        switch current {
        case .province:
            return ZoomBand(scale: scale)
        case .city:
            if scale >= 2.6 { return .street }
            if scale < 1.08 { return .province }
            return .city
        case .street:
            if scale < 1.08 { return .province }
            if scale < 2.35 { return .city }
            return .street
        }
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
