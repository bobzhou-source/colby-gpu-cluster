import CoreGraphics

enum CityCreatureDetail: Equatable, Sendable {
    case silhouette
    case identity
    case full

    init(band: ZoomBand) {
        switch band {
        case .province:
            self = .silhouette
        case .city:
            self = .identity
        case .street:
            self = .full
        }
    }
}

enum CityCreatureRenderPolicy {
    enum ScaleMode: Equatable {
        case world
    }

    static let scaleMode: ScaleMode = .world
    struct UFOFeatures: Equatable {
        let drawBeam: Bool
        let drawBeamCore: Bool
        let drawLights: Bool
        let drawAlien: Bool
        let particleCount: Int
    }

    static func ufo(detail: CityCreatureDetail, night: Double) -> UFOFeatures {
        switch detail {
        case .silhouette:
            return UFOFeatures(
                drawBeam: true,
                drawBeamCore: false,
                drawLights: false,
                drawAlien: false,
                particleCount: 0
            )
        case .identity:
            return UFOFeatures(
                drawBeam: true,
                drawBeamCore: night > 0.3,
                drawLights: true,
                drawAlien: false,
                particleCount: 0
            )
        case .full:
            return UFOFeatures(
                drawBeam: true,
                drawBeamCore: night > 0.3,
                drawLights: true,
                drawAlien: true,
                particleCount: CityCreatureGeometry.UFO.particleCount
            )
        }
    }
}

enum CityCreatureGeometry {
    enum Kaiju {
        /// Tallest point of the rig: brow crown plus the roar head lift and
        /// the walk bob, rounded up.
        static let height: CGFloat = 22
        /// Body-only plan extent. The tail, muzzle, and roar breath are added
        /// separately in `kaijuFootprint`; the depth covers the swung arms.
        static let footprint = CGSize(width: 5, height: 6)
        /// Distance from the body center to the far tail tip, including wag
        /// and a conservative margin.
        static let tailReach: CGFloat = 18.5
        static let shadowOpacity = 0.22
    }

    enum UFO {
        /// Plan diameter of the saucer's widest ring, and the culled footprint.
        static let diameter: CGFloat = 14
        /// Top of the glass canopy above the flight altitude; the cull uses it
        /// as the actor's ceiling.
        static let domeHeight: CGFloat = 2.4
        static let shadowOpacity = 0.14
        static let particleCount = 2
    }

    static func kaijuFootprint(
        for pose: CityWhimsy.KaijuPose
    ) -> CGRect {
        let bodyMinX = pose.x - Kaiju.footprint.width / 2
        let bodyMaxX = pose.x + Kaiju.footprint.width / 2
        let tailTipX = pose.x - pose.heading * Kaiju.tailReach
        // Roar breath drifts forward of the snout; keep it inside the cull.
        let breathTipX = pose.x + pose.heading * 13.5
        let minX = min(bodyMinX, tailTipX, breathTipX)
        let maxX = max(bodyMaxX, tailTipX, breathTipX)
        return CGRect(
            x: minX,
            y: pose.y - Kaiju.footprint.height / 2,
            width: maxX - minX,
            height: Kaiju.footprint.height
        )
    }

    static func ufoFootprint(
        for event: CityWhimsy.UFOEvent
    ) -> CGRect {
        CGRect(
            x: event.x - UFO.diameter / 2,
            y: event.y - UFO.diameter / 2,
            width: UFO.diameter,
            height: UFO.diameter
        )
    }

    static func kaijuProjectedBounds(
        for pose: CityWhimsy.KaijuPose
    ) -> CGRect {
        projectedBounds(
            footprint: kaijuFootprint(for: pose),
            maxZ: Kaiju.height + max(pose.bob, 0)
        )
    }

    static func ufoProjectedBounds(
        for event: CityWhimsy.UFOEvent
    ) -> CGRect {
        projectedBounds(
            footprint: ufoFootprint(for: event),
            maxZ: event.altitude + UFO.domeHeight
        )
    }

    static func screenBounds(
        projectedBounds: CGRect,
        camera: CityCamera
    ) -> CGRect {
        let topLeft = camera.apply(CGPoint(
            x: projectedBounds.minX,
            y: projectedBounds.minY
        ))
        let topRight = camera.apply(CGPoint(
            x: projectedBounds.maxX,
            y: projectedBounds.minY
        ))
        let bottomRight = camera.apply(CGPoint(
            x: projectedBounds.maxX,
            y: projectedBounds.maxY
        ))
        let bottomLeft = camera.apply(CGPoint(
            x: projectedBounds.minX,
            y: projectedBounds.maxY
        ))
        return [topLeft, topRight, bottomRight, bottomLeft]
            .reduce(CGRect.null) {
                $0.union(CGRect(origin: $1, size: .zero))
            }
    }

    private static func projectedBounds(
        footprint: CGRect,
        maxZ: CGFloat
    ) -> CGRect {
        let groundNorth = IsoProjection.project(
            footprint.minX,
            footprint.minY,
            0
        )
        let groundEast = IsoProjection.project(
            footprint.maxX,
            footprint.minY,
            0
        )
        let groundSouth = IsoProjection.project(
            footprint.maxX,
            footprint.maxY,
            0
        )
        let groundWest = IsoProjection.project(
            footprint.minX,
            footprint.maxY,
            0
        )
        let topNorth = IsoProjection.project(
            footprint.minX,
            footprint.minY,
            maxZ
        )
        let topEast = IsoProjection.project(
            footprint.maxX,
            footprint.minY,
            maxZ
        )
        let topSouth = IsoProjection.project(
            footprint.maxX,
            footprint.maxY,
            maxZ
        )
        let topWest = IsoProjection.project(
            footprint.minX,
            footprint.maxY,
            maxZ
        )
        return [
            groundNorth,
            groundEast,
            groundSouth,
            groundWest,
            topNorth,
            topEast,
            topSouth,
            topWest,
        ].reduce(CGRect.null) {
            $0.union(CGRect(origin: $1, size: .zero))
        }
    }
}
