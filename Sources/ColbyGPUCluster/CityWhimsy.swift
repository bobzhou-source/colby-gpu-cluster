import CoreGraphics
import Foundation
import SwiftUI

/// Deterministic, world-space city life models. Every animated result is derived from its
/// input date and stable byte-hash seed; renderers project these coordinates with IsoProjection.
enum CityWhimsy {
    struct Tint: Equatable, Sendable {
        let red: Double
        let green: Double
        let blue: Double
        let opacity: Double

        var color: Color { Color(red: red, green: green, blue: blue).opacity(opacity) }
    }

    struct Puff: Equatable, Sendable {
        let x: CGFloat
        let y: CGFloat
        let z: CGFloat
        let radius: CGFloat
        let opacity: Double
    }


    struct FarCar: Equatable, Sendable {
        let x: CGFloat
        let y: CGFloat
        /// Unit direction of travel along the route, used for renderer-side lane offsets.
        let dirX: CGFloat
        let dirY: CGFloat
        let forward: Bool
        let brightness: Double
    }

    /// Immutable polyline data prepared once and sampled repeatedly by animation frames.
    struct RouteMetrics: Sendable {
        struct Segment: Sendable {
            let startX: CGFloat
            let startY: CGFloat
            let endX: CGFloat
            let endY: CGFloat
            let length: CGFloat
            /// Distance from the route origin to this segment's start.
            let prefixLength: CGFloat
        }

        let segments: [Segment]
        let length: CGFloat
        private let fallback: (x: CGFloat, y: CGFloat)

        init(_ points: [(CGFloat, CGFloat)]) {
            fallback = points.first ?? (0, 0)
            var builtSegments: [Segment] = []
            builtSegments.reserveCapacity(max(0, points.count - 1))
            var accumulatedLength: CGFloat = 0

            for index in points.indices.dropLast() {
                let start = points[index]
                let end = points[points.index(after: index)]
                let segmentLength = hypot(end.0 - start.0, end.1 - start.1)
                guard segmentLength > 0 else { continue }
                builtSegments.append(
                    Segment(
                        startX: start.0,
                        startY: start.1,
                        endX: end.0,
                        endY: end.1,
                        length: segmentLength,
                        prefixLength: accumulatedLength
                    )
                )
                accumulatedLength += segmentLength
            }

            segments = builtSegments
            length = accumulatedLength
        }

        func sample(distance: CGFloat) -> (x: CGFloat, y: CGFloat) {
            guard let segment = segment(containing: distance) else { return fallback }
            let clamped = min(max(0, distance), length)
            let fraction = (clamped - segment.prefixLength) / segment.length
            return (
                segment.startX + (segment.endX - segment.startX) * fraction,
                segment.startY + (segment.endY - segment.startY) * fraction
            )
        }

        func sample(progress: CGFloat) -> (x: CGFloat, y: CGFloat, alongX: Bool) {
            guard let segment = segment(containing: length * min(max(0, progress), 1)) else {
                return (fallback.x, fallback.y, true)
            }
            let clamped = length * min(max(0, progress), 1)
            let fraction = (clamped - segment.prefixLength) / segment.length
            return (
                segment.startX + (segment.endX - segment.startX) * fraction,
                segment.startY + (segment.endY - segment.startY) * fraction,
                abs(segment.endX - segment.startX) >= abs(segment.endY - segment.startY)
            )
        }

        func segmentEndpoints(progress: CGFloat) -> (start: (x: CGFloat, y: CGFloat), end: (x: CGFloat, y: CGFloat))? {
            guard let segment = segment(containing: length * min(max(0, progress), 1)) else {
                return nil
            }
            return (
                start: (segment.startX, segment.startY),
                end: (segment.endX, segment.endY)
            )
        }

        private func segment(containing distance: CGFloat) -> Segment? {
            guard length > 0 else { return nil }
            let clamped = min(max(0, distance), length)
            var lower = 0
            var upper = segments.count
            while lower < upper {
                let midpoint = lower + (upper - lower) / 2
                if segments[midpoint].prefixLength + segments[midpoint].length < clamped {
                    lower = midpoint + 1
                } else {
                    upper = midpoint
                }
            }
            return lower < segments.count ? segments[lower] : segments.last
        }
    }

    struct Wake: Equatable, Sendable {
        let start: (x: CGFloat, y: CGFloat, z: CGFloat)
        let end: (x: CGFloat, y: CGFloat, z: CGFloat)

        static func == (lhs: Wake, rhs: Wake) -> Bool {
            lhs.start.x == rhs.start.x && lhs.start.y == rhs.start.y && lhs.start.z == rhs.start.z && lhs.end.x == rhs.end.x && lhs.end.y == rhs.end.y && lhs.end.z == rhs.end.z
        }
    }

    struct Ferry: Equatable, Sendable {
        let x: CGFloat
        let y: CGFloat
        let z: CGFloat
        let wake: [Wake]
        let cabinLight: Tint
    }

    struct Walker: Equatable, Sendable {
        let x: CGFloat
        let y: CGFloat
        let progress: CGFloat
        let isReturning: Bool
        let bobPhase: Double
        let colorKey: String
    }

    struct WoodlandRunner: Equatable, Sendable {
        let x: CGFloat
        let y: CGFloat
        let headingX: CGFloat
        let headingY: CGFloat
        let bobPhase: Double
        let colorKey: String
    }

    struct Stroller: Equatable, Sendable {
        let x: CGFloat
        let y: CGFloat
        let colorKey: String
        let headingX: CGFloat
        let headingY: CGFloat
    }

    struct Shopper: Equatable, Sendable {
        let id: String
        let x: CGFloat
        let y: CGFloat
        let colorKey: String
        let dwelling: Bool
    }



    struct Bird: Equatable, Sendable {
        let x: CGFloat
        let y: CGFloat
        let z: CGFloat
        let flapPhase: Double
    }

    struct Balloon: Equatable, Sendable {
        let x: CGFloat
        let y: CGFloat
        let z: CGFloat
        let bob: CGFloat
        let tint: Tint
        /// 0..1 festival state: at 1 the balloon tows a pennant string.
        let celebration: Double
    }

    struct Spark: Equatable, Sendable {
        let x: CGFloat
        let y: CGFloat
        let z: CGFloat
        let radius: CGFloat
        let opacity: Double
        let tint: Tint
    }

    /// City band and closer: returns 2–4 rising puffs from a lit plot's tallest roof.
    /// `plotOrigin` is the plot's world x/y, so every returned coordinate is world-space.
    /// Province omits smoke; city renders it; street inherits the city layer.
    static func smokePuffs(plotID: String, plotOrigin: CGPoint, building: BuildingSpec, load: Double, date: Date, reduceMotion: Bool) -> [Puff] {
        let fill = min(1, max(0, load))
        let count = 2 + Int((fill * 2.999).rounded(.down))
        let baseX = plotOrigin.x + building.ox + building.bw / 2
        let baseY = plotOrigin.y + building.oy + building.bd / 2
        let seconds = date.timeIntervalSinceReferenceDate
        return (0..<count).map { index in
            let seed = unitSeed("\(plotID):smoke:\(index)")
            let cycle = reduceMotion ? positiveRemainder(seed + 0.31, 1) : positiveRemainder(seconds * (0.18 + fill * 0.24) + seed, 1)
            let rise = CGFloat(cycle * (2.1 + fill * 2.4))
            return Puff(x: baseX + CGFloat(seed - 0.5) * 0.7, y: baseY + CGFloat(seed * 0.7 - 0.35), z: building.h + rise, radius: 0.35 + CGFloat(cycle) * 0.85, opacity: max(0, (1 - cycle) * (0.34 + fill * 0.46)))
        }
    }

    /// Province band and closer: glides a ferry through the river. City and street retain it.
    static func ferry(date: Date, reduceMotion: Bool) -> Ferry {
        let cycle = positiveRemainder((reduceMotion ? 0 : date.timeIntervalSinceReferenceDate) / 40, 1)
        let travel = 0.5 - 0.5 * cos(cycle * .pi * 2)
        let y = CGFloat(10 + travel * 80)
        let direction: CGFloat = sin(cycle * .pi * 2) >= 0 ? 1 : -1
        return Ferry(x: 10, y: y, z: 0.18, wake: [Wake(start: (9.72, y - direction * 0.25, 0.12), end: (9.15, y - direction * 1.35, 0.06)), Wake(start: (10.28, y - direction * 0.25, 0.12), end: (10.85, y - direction * 1.35, 0.06))], cabinLight: Tint(red: 1, green: 0.72, blue: 0.30, opacity: 0.9))
    }

    /// City and street: red aviation-light opacity for towers at least 8 world units high.
    static func antennaBlink(plotID: String, date: Date) -> Double {
        let phase = positiveRemainder(date.timeIntervalSinceReferenceDate / 2.4 + unitSeed("\(plotID):blink"), 1)
        return 0.15 + 0.85 * pow(max(0, sin(phase * .pi * 2)), 3)
    }

    /// Street detail: returns up to three walkers interpolated along a precomputed plot entry route.
    static func pedestrians(
        plotID: String,
        count: Int,
        routeMetrics: RouteMetrics,
        date: Date,
        reduceMotion: Bool
    ) -> [Walker] {
        guard count > 0, routeMetrics.length > 0 else { return [] }
        return (0..<min(3, count)).map { index in
            let seed = unitSeed("\(plotID):walker:\(index)")
            let normalized = reduceMotion
                ? positiveRemainder(seed + 0.17, 1)
                : positiveRemainder(
                    date.timeIntervalSinceReferenceDate * (0.045 + seed * 0.025) + seed,
                    1
                )
            let progress = triangleWave(normalized)
            let position = routeMetrics.sample(progress: progress)
            let isReturning = !reduceMotion && normalized > 0.5
            let laneMagnitude: CGFloat = index % 2 == 0 ? 0.18 : 0.22
            let turnBlend = CGFloat(sin(.pi * Double(progress)))
            let travelSide: CGFloat = isReturning ? 1 : -1
            let lane = travelSide * laneMagnitude * turnBlend
            return Walker(
                x: position.x + (position.alongX ? 0 : lane),
                y: position.y + (position.alongX ? lane : 0),
                progress: progress,
                isReturning: isReturning,
                bobPhase: reduceMotion
                    ? 0
                    : positiveRemainder(
                        date.timeIntervalSinceReferenceDate * 5 + seed * 10,
                        .pi * 2
                    ),
                colorKey: "walker-\(Int(seed * 5))"
            )
        }
    }

    /// City and street: two deterministic runners circle each woodland campground.
    /// Every loop stays within 3.8 world units of its supplied center.
    static func woodlandRunners(
        centers: [CGPoint],
        date: Date,
        reduceMotion: Bool
    ) -> [WoodlandRunner] {
        let seconds = date.timeIntervalSinceReferenceDate
        var runners: [WoodlandRunner] = []
        runners.reserveCapacity(centers.count * 2)

        for (centerIndex, center) in centers.enumerated() {
            for slot in 0..<2 {
                let identity = "woodland-runner-\(centerIndex)-\(slot)"
                let seed = unitSeed(identity)
                let radiusSeed = positiveRemainder(seed * 7.13 + 0.23, 1)
                let minorRadiusSeed = positiveRemainder(seed * 11.17 + 0.37, 1)
                let majorRadius = CGFloat(3 + radiusSeed * 0.8)
                let minorRadius = CGFloat(1.8 + minorRadiusSeed * 0.5)
                let rotation = positiveRemainder(seed * 5.19 + 0.41, 1) * .pi * 2
                let direction: Double = slot.isMultiple(of: 2) ? 1 : -1
                let loopSpeed = 0.105 + seed * 0.02
                let phase = reduceMotion
                    ? seed
                    : positiveRemainder(seconds * loopSpeed * direction + seed, 1)
                let angle = phase * .pi * 2
                let cosAngle = CGFloat(cos(angle))
                let sinAngle = CGFloat(sin(angle))
                let cosRotation = CGFloat(cos(rotation))
                let sinRotation = CGFloat(sin(rotation))

                let localX = majorRadius * cosAngle
                let localY = minorRadius * sinAngle
                let travelDirection = CGFloat(direction)
                let localTangentX = -majorRadius * sinAngle * travelDirection
                let localTangentY = minorRadius * cosAngle * travelDirection
                let tangentX = localTangentX * cosRotation - localTangentY * sinRotation
                let tangentY = localTangentX * sinRotation + localTangentY * cosRotation
                let tangentLength = hypot(tangentX, tangentY)

                runners.append(WoodlandRunner(
                    x: center.x + localX * cosRotation - localY * sinRotation,
                    y: center.y + localX * sinRotation + localY * cosRotation,
                    headingX: tangentX / tangentLength,
                    headingY: tangentY / tangentLength,
                    bobPhase: reduceMotion
                        ? 0
                        : positiveRemainder(seconds * 12 + seed * .pi * 2, .pi * 2),
                    colorKey: identity
                ))
            }
        }
        return runners
    }

    /// Street band only: deterministic sidewalk walkers that ping-pong along local streets.
    static func strollers(
        localStreets: [[(CGFloat, CGFloat)]],
        runningJobCount: Int,
        date: Date,
        reduceMotion: Bool
    ) -> [Stroller] {
        guard !localStreets.isEmpty else { return [] }

        let totalCount = min(4 + max(0, runningJobCount) * 3, 28)
        let seconds = reduceMotion ? 0 : date.timeIntervalSinceReferenceDate
        var strollers: [Stroller] = []
        strollers.reserveCapacity(totalCount)

        for index in 0..<totalCount {
            let streetIndex = index % localStreets.count
            let slot = index / localStreets.count
            let street = localStreets[streetIndex]
            let length = polylineLength(street)
            guard length > 0 else { continue }

            let seed = unitSeed("stroller:\(streetIndex):\(slot)")
            let phase = reduceMotion
                ? seed
                : positiveRemainder(seconds * 0.45 / Double(length) + seed, 1)
            let forward = phase < 0.5
            let distance = triangleWave(phase) * length
            let pose = strollerPose(on: street, distance: distance, length: length)
            let side: CGFloat = slot.isMultiple(of: 2) ? 1 : -1
            let offsetX = -pose.pathHeadingY * 0.6 * side
            let offsetY = pose.pathHeadingX * 0.6 * side

            strollers.append(Stroller(
                x: pose.x + offsetX,
                y: pose.y + offsetY,
                colorKey: "stroller-\(streetIndex)-\(slot)",
                headingX: reduceMotion ? 1 : (forward ? pose.pathHeadingX : -pose.pathHeadingX),
                headingY: reduceMotion ? 0 : (forward ? pose.pathHeadingY : -pose.pathHeadingY)
            ))
        }
        return strollers
    }

    /// City band and closer: shop-door visitors ping-pong between deterministic stop pairs,
    /// pausing for 1.2 seconds at each door. Reduced motion freezes the complete pose.
    static func shoppers(
        shopStops: [(CGFloat, CGFloat)],
        runningJobCount: Int,
        date: Date,
        reduceMotion: Bool
    ) -> [Shopper] {
        guard !shopStops.isEmpty else { return [] }

        let totalCount = min(10, 2 + max(0, runningJobCount))
        let seconds = reduceMotion ? 0 : date.timeIntervalSinceReferenceDate
        let dwellDuration: Double = 1.2

        return (0..<totalCount).map { index in
            let id = "shopper-\(index)"
            let seed = unitSeed(id)
            let startIndex = Int(unitSeed("\(id):start") * Double(shopStops.count)) % shopStops.count
            let endOffset = shopStops.count > 1
                ? 1 + Int(unitSeed("\(id):end") * Double(shopStops.count - 1))
                : 0
            let endIndex = (startIndex + endOffset) % shopStops.count
            let start = shopStops[startIndex]
            let end = shopStops[endIndex]
            let distance = hypot(end.0 - start.0, end.1 - start.1)

            guard distance > 0 else {
                return Shopper(id: id, x: start.0, y: start.1, colorKey: id, dwelling: true)
            }

            let travelDuration = Double(distance / 1.8)
            let cycleDuration = dwellDuration * 2 + travelDuration * 2
            var phase = positiveRemainder(seconds + seed * cycleDuration, cycleDuration)

            if phase < dwellDuration {
                return Shopper(id: id, x: start.0, y: start.1, colorKey: id, dwelling: true)
            }
            phase -= dwellDuration

            if phase < travelDuration {
                let progress = shopperEase(phase / travelDuration)
                return Shopper(
                    id: id,
                    x: start.0 + (end.0 - start.0) * progress,
                    y: start.1 + (end.1 - start.1) * progress,
                    colorKey: id,
                    dwelling: false
                )
            }
            phase -= travelDuration

            if phase < dwellDuration {
                return Shopper(id: id, x: end.0, y: end.1, colorKey: id, dwelling: true)
            }
            phase -= dwellDuration

            let progress = shopperEase(phase / travelDuration)
            return Shopper(
                id: id,
                x: end.0 + (start.0 - end.0) * progress,
                y: end.1 + (start.1 - end.1) * progress,
                colorKey: id,
                dwelling: false
            )
        }
    }

    /// All bands: returns a five-bird flock crossing the world sky diagonally. Renderers draw
    /// sky life in their dynamic layer, so province, city, and street all retain the flock.
    static func birds(date: Date, reduceMotion: Bool) -> [Bird] {
        let seconds = date.timeIntervalSinceReferenceDate
        let progress = reduceMotion ? 0.35 : positiveRemainder(seconds / 45, 1)
        let leaderX = CGFloat(-20 + 200 * progress)
        let leaderY = CGFloat(30 + 24 * sin(progress * .pi * 2 * 0.5))
        let flapBase = reduceMotion ? 0 : seconds * 6
        var flock = [Bird(x: leaderX, y: leaderY, z: 15, flapPhase: flapBase)]

        for index in 1...2 {
            let distance = CGFloat(index)
            let flapPhase = reduceMotion ? 0 : flapBase + Double(index)
            flock.append(Bird(x: leaderX - 2.2 * distance, y: leaderY + 1.6 * distance, z: 15 - 0.3 * distance, flapPhase: flapPhase))
            flock.append(Bird(x: leaderX - 2.2 * distance, y: leaderY - 1.6 * distance, z: 15 - 0.3 * distance, flapPhase: flapPhase))
        }
        return flock
    }

    /// All bands: returns a warm hot-air balloon crossing the world sky. Renderers draw it in
    /// their dynamic layer, applying `bob` to `z`, so province, city, and street all retain it.
    /// `celebration` (0..1) tows a pennant string when the cluster is fully taken.
    static func balloon(date: Date, reduceMotion: Bool, celebration: Double = 0) -> Balloon {
        let seconds = date.timeIntervalSinceReferenceDate
        let progress = reduceMotion ? 0.4 : positiveRemainder(seconds / 70, 1)
        let loop = reduceMotion ? 0 : Int(floor(seconds / 70))
        let tint = loop.isMultiple(of: 2)
            ? Tint(red: 1, green: 0.58, blue: 0.24, opacity: 0.92)
            : Tint(red: 0.96, green: 0.34, blue: 0.28, opacity: 0.92)
        return Balloon(
            x: CGFloat(-10 + 180 * progress),
            y: CGFloat(110 - 60 * progress),
            z: 20,
            bob: reduceMotion ? 0 : CGFloat(2 * sin(progress * .pi * 6)),
            tint: tint,
            celebration: min(1, max(0, celebration))
        )
    }

    /// City band and closer: warm sparks drifting over a fully idle plot at
    /// night - unused capacity twinkles instead of lighting windows. Each
    /// firefly rides a slow Lissajous around the anchor and pulses on its
    /// own deterministic clock.
    static func fireflies(
        plotID: String,
        anchor: (x: CGFloat, y: CGFloat),
        count: Int,
        date: Date,
        reduceMotion: Bool
    ) -> [Spark] {
        let seconds = date.timeIntervalSinceReferenceDate
        return (0..<max(0, count)).map { index in
            let seed = unitSeed("\(plotID):firefly:\(index)")
            let orbitX = 1.2 + unitSeed("\(plotID):firefly-orbit-x:\(index)") * 1.6
            let orbitY = 0.9 + unitSeed("\(plotID):firefly-orbit-y:\(index)") * 1.2
            let speed = 0.35 + seed * 0.4
            let phase = reduceMotion ? seed : positiveRemainder(seconds * speed + seed * 7, 1)
            let angle = phase * .pi * 2
            let blink = reduceMotion
                ? 0.7
                : 0.35 + 0.65 * pow(0.5 + 0.5 * sin(seconds * (2.2 + seed * 2) + seed * 20), 2)
            return Spark(
                x: anchor.x + CGFloat(cos(angle) * orbitX),
                y: anchor.y + CGFloat(sin(angle * 1.3) * orbitY),
                z: 0.9 + CGFloat(0.5 + 0.5 * sin(angle * 2 + seed * 9)),
                radius: 0.14,
                opacity: blink,
                tint: Tint(red: 0.78, green: 0.98, blue: 0.52, opacity: blink)
            )
        }
    }


    /// City band and closer: produces a rocket then a 12–16-spark burst after a plot is freed.
    /// `plotOrigin` is the world x/y launch site beneath the burst. Province omits fireworks; street inherits them. Reduced motion returns one static peak burst.
    static func fireworkParticles(plotID: String, plotOrigin: CGPoint, sinceLaunch: TimeInterval, reduceMotion: Bool) -> [Spark] {
        let launchSite = (x: plotOrigin.x, y: plotOrigin.y)
        if reduceMotion { return sparks(plotID: plotID, origin: launchSite, elapsed: 1.2, opacity: 0.78) }
        guard sinceLaunch >= 0 else { return [] }
        if sinceLaunch < 0.7 {
            let progress = CGFloat(sinceLaunch / 0.7)
            return [Spark(x: launchSite.x, y: launchSite.y, z: 0.3 + progress * 8, radius: 0.22, opacity: max(0, 1 - Double(progress) * 0.25), tint: Tint(red: 1, green: 0.78, blue: 0.33, opacity: 1))]
        }
        return sparks(plotID: plotID, origin: launchSite, elapsed: sinceLaunch - 0.7, opacity: max(0, 1 - (sinceLaunch - 0.7) / 2.5))
    }

    /// City band and closer: returns a slow sweep angle for an h200 plot's searchlight. Province omits it; street inherits it. The caller gates this to h200.
    static func searchlightAngle(plotID: String, date: Date) -> Angle? {
        let phase = positiveRemainder(date.timeIntervalSinceReferenceDate / 14 + unitSeed("\(plotID):searchlight"), 1)
        return .radians(-0.85 + sin(phase * .pi * 2) * 0.7)
    }

    /// All bands: returns deterministic cars travelling along the supplied world-space routes.
    static func farTraffic(routes: [[(CGFloat, CGFloat)]], date: Date, reduceMotion: Bool) -> [FarCar] {
        farTraffic(routeMetrics: routes.map(RouteMetrics.init), date: date, reduceMotion: reduceMotion)
    }

    /// Samples precomputed route metrics without rebuilding polyline segments during a frame.
    static func farTraffic(routeMetrics: [RouteMetrics], date: Date, reduceMotion: Bool) -> [FarCar] {
        let seconds = reduceMotion ? 0 : date.timeIntervalSinceReferenceDate
        var cars: [FarCar] = []
        cars.reserveCapacity(min(40, routeMetrics.count * 6))
        for (routeIndex, metrics) in routeMetrics.enumerated() where cars.count < 40 {
            let length = metrics.length
            guard length > 0 else { continue }
            let count = min(6, max(2, Int(length / 14)))
            for carIndex in 0..<min(count, 40 - cars.count) {
                let prefix = "far-traffic:\(routeIndex):\(carIndex)"
                let speed = 2.2 + unitSeed("\(prefix):speed") * 2
                let start = unitSeed("\(prefix):start") * Double(length)
                let forward = unitSeed("\(prefix):direction") >= 0.5
                let distance = positiveRemainder(start + (forward ? speed * seconds : -speed * seconds), Double(length))
                let position = metrics.sample(distance: CGFloat(distance))
                let ahead = metrics.sample(distance: CGFloat(positiveRemainder(distance + 0.5, Double(length))))
                var dirX = ahead.x - position.x, dirY = ahead.y - position.y
                let magnitude = max(0.0001, hypot(dirX, dirY))
                dirX /= magnitude
                dirY /= magnitude
                if !forward { dirX = -dirX; dirY = -dirY }
                cars.append(FarCar(x: position.x, y: position.y, dirX: dirX, dirY: dirY, forward: forward, brightness: 0.4 + unitSeed("\(prefix):brightness") * 0.6))
            }
        }
        return cars
    }

    /// All bands: deterministic 0.3-second-quantized star brightness.
    static func starTwinkle(index: Int, date: Date) -> Double {
        let step = Int(floor(date.timeIntervalSinceReferenceDate / 0.3))
        return unitSeed("star:\(index):\(step)")
    }

    /// All bands: deterministic lamp level, normally 1.0 with rare 0.12-second dips.
    static func lampFlicker(lampIndex: Int, date: Date) -> Double {
        let windowLength = 7 + unitSeed("lamp:\(lampIndex):window-length") * 4
        let seconds = date.timeIntervalSinceReferenceDate
        let window = Int(floor(seconds / windowLength))
        guard unitSeed("lamp:\(lampIndex):window:\(window)") < 1.0 / 6.0 else { return 1 }
        let phase = positiveRemainder(seconds, windowLength)
        let start = unitSeed("lamp:\(lampIndex):dip:\(window)") * max(0, windowLength - 0.12)
        return phase >= start && phase < start + 0.12 ? 0.35 : 1
    }

    /// All bands: deterministic 0.4-second neon brightness; broken signs strobe continuously.
    static func neonFlicker(seed: Int, broken: Bool, date: Date) -> Double {
        let step = Int(floor(date.timeIntervalSinceReferenceDate / 0.4))
        let value = unitSeed("neon:\(seed):\(step)")
        if broken { return value > 0.5 ? 1 : 0.15 }
        return value < 0.06 ? 0.25 : 1
    }

    private static func sparks(plotID: String, origin: (x: CGFloat, y: CGFloat), elapsed: TimeInterval, opacity: Double) -> [Spark] {
        let count = 12 + Int(unitSeed("\(plotID):firework-count") * 4.999)
        return (0..<count).map { index in
            let angle = (Double(index) / Double(count)) * .pi * 2 + unitSeed("\(plotID):spark-angle:\(index)") * 0.35
            let time = CGFloat(elapsed)
            let distance = CGFloat(2.2 + unitSeed("\(plotID):spark-speed:\(index)") * 1.8) * time
            return Spark(x: origin.x + cos(angle) * distance, y: origin.y + sin(angle) * distance, z: 8.3 + sin(angle) * distance - 0.85 * time * time, radius: 0.16, opacity: opacity, tint: Tint(red: 1, green: 0.46 + unitSeed("\(plotID):spark-tint:\(index)") * 0.4, blue: 0.20, opacity: opacity))
        }
    }

    private static func shopperEase(_ progress: Double) -> CGFloat {
        let value = min(1, max(0, progress))
        return CGFloat(value * value * (3 - 2 * value))
    }

    private static func polylineLength(_ path: [(CGFloat, CGFloat)]) -> CGFloat {
        zip(path, path.dropFirst()).reduce(0) { total, segment in
            total + hypot(segment.1.0 - segment.0.0, segment.1.1 - segment.0.1)
        }
    }

    private static func strollerPose(
        on path: [(CGFloat, CGFloat)],
        distance: CGFloat,
        length: CGFloat
    ) -> (x: CGFloat, y: CGFloat, pathHeadingX: CGFloat, pathHeadingY: CGFloat) {
        var remaining = min(max(0, distance), length)
        var lastDirection: (x: CGFloat, y: CGFloat)?

        for (start, end) in zip(path, path.dropFirst()) {
            let dx = end.0 - start.0
            let dy = end.1 - start.1
            let segmentLength = hypot(dx, dy)
            guard segmentLength > 0 else { continue }
            let direction = (x: dx / segmentLength, y: dy / segmentLength)
            lastDirection = direction
            if remaining <= segmentLength {
                let fraction = remaining / segmentLength
                return (
                    start.0 + dx * fraction,
                    start.1 + dy * fraction,
                    direction.x,
                    direction.y
                )
            }
            remaining -= segmentLength
        }

        let endpoint = path.last ?? (0, 0)
        let direction = lastDirection ?? (x: 1, y: 0)
        return (endpoint.0, endpoint.1, direction.x, direction.y)
    }

    enum ActivityKind: CaseIterable, Equatable, Sendable {
        case picnic, kite, dogWalk, ballGame, gardening
    }

    struct ActivityScene: Equatable, Sendable {
        let kind: ActivityKind
        /// World-space anchor on the plot apron, clear of every building footprint.
        let x: CGFloat
        let y: CGFloat
    }

    /// Required clear radius around an activity anchor, in world units.
    static let activityClearance: CGFloat = 1.6

    /// Deterministic leisure vignette for a plot. The kind and the preferred
    /// corner both hash from the plot id; the anchor is the first apron corner
    /// whose clearance disc misses every building footprint. Returns nil when
    /// the plot is too crowded to host a scene.
    static func activityScene(
        plotID: String,
        x: CGFloat,
        y: CGFloat,
        w: CGFloat,
        d: CGFloat,
        footprints: [CGRect]
    ) -> ActivityScene? {
        let seed = unitSeed("\(plotID)-activity")
        let kinds = ActivityKind.allCases
        let kind = kinds[min(kinds.count - 1, Int(seed * Double(kinds.count)))]
        let inset: CGFloat = 2.0
        guard w > inset * 2, d > inset * 2 else { return nil }
        let candidates: [(CGFloat, CGFloat)] = [
            (x + inset, y + d - inset),
            (x + w - inset, y + d - inset),
            (x + inset, y + inset),
            (x + w - inset, y + inset),
            (x + w / 2, y + d - inset),
        ]
        let start = Int(unitSeed("\(plotID)-activity-corner") * Double(candidates.count))
        for offset in 0..<candidates.count {
            let (cx, cy) = candidates[(start + offset) % candidates.count]
            let clear = footprints.allSatisfy { footprint in
                !footprint.insetBy(dx: -activityClearance, dy: -activityClearance)
                    .contains(CGPoint(x: cx, y: cy))
            }
            if clear { return ActivityScene(kind: kind, x: cx, y: cy) }
        }
        return nil
    }

    struct KaijuPose: Equatable, Sendable {
        let x: CGFloat
        let y: CGFloat
        let heading: CGFloat
        let bob: CGFloat
        /// Walk-cycle phase 0...1; the two feet alternate lifts off this.
        var step: CGFloat = 0.31
        /// Foot fore-aft half-excursion in world units. Derived from the
        /// patrol speed (travelRate * walkPeriod / 4) so a stance foot's
        /// linear backtrack cancels the body's ground speed exactly and
        /// planted feet never slide.
        var stride: CGFloat = 0.2
        /// Lateral carriage sway; the rig subtracts it from the feet so
        /// planted toes keep the patrol lane while the body rolls.
        var sway: CGFloat = 0
        /// Tail-wag clock in radians; the rig phase-shifts it per segment
        /// so the tail ripples instead of swinging as one stick.
        var tailPhase: CGFloat = 1.1
        /// Roar envelope 0...1: jaw drop, head rear, dorsal glow, breath.
        var roar: CGFloat = 0
        /// Cluster-derived liveliness 0...1; scales every motion amplitude.
        var liveliness: CGFloat = 1

        /// Jaw lower-z drop while roaring.
        var jawDrop: CGFloat { roar * 0.62 }
        /// Head/neck/snout lift while roaring.
        var headRear: CGFloat { roar * 0.95 }
    }

    /// What the saucer should look at this cycle, derived from cluster data.
    /// All fields optional: a fully idle cluster leaves the UFO on patrol.
    struct UFOMission: Equatable, Sendable {
        /// World-space center of the busiest lit plot (most jobs, then load).
        var scanTarget: CGPoint?
        /// Scheduler job pressure at the scan target; drives beam strength while hovering.
        var scanIntensity: Double = 0
        /// World-space anchor of the pending-job queue.
        var queueTarget: CGPoint?
        var queueDepth: Int = 0
    }

    struct UFOEvent: Equatable, Sendable {
        let x: CGFloat
        let y: CGFloat
        let altitude: CGFloat
        let beam: CGFloat
    }

    /// A friendly kaiju patrols a narrow meadow habitat beside the city core,
    /// remaining discoverable as the camera moves through every zoom band.
    /// `energy` (0..1) follows cluster activity: a busy cluster keeps the
    /// kaiju lively; an empty one leaves it dozing with a barely-there bob.
    /// Reduced motion freezes it at a stable, fully connected stance.
    static func kaijuPose(date: Date, reduceMotion: Bool, bounds: CGRect, energy: Double = 1) -> KaijuPose {
        let patrolPeriod: Double = 36
        let phase = reduceMotion
            ? 0.31
            : positiveRemainder(date.timeIntervalSinceReferenceDate / patrolPeriod, 1)
        let seconds = date.timeIntervalSinceReferenceDate
        let travel = triangleWave(phase)
        let safe = bounds.insetBy(
            dx: CityCreatureGeometry.Kaiju.tailReach,
            dy: CityCreatureGeometry.Kaiju.footprint.height / 2 + 1
        )
        let liveliness = CGFloat(0.25 + 0.75 * min(1, max(0, energy)))
        // Lateral carriage sway rides on the patrol lane; the rig subtracts
        // it from the feet so planted toes never drift with the body roll.
        // Capped so lanes minus sway plus half a foot stay inside the
        // culled footprint depth.
        let sway = CGFloat(sin(phase * .pi * 4)) * min(0.25, safe.height * 0.008) * liveliness
        // Bound the patrol excursion rather than clipping stride after the
        // speed calculation. Every stance then cancels actual world travel,
        // including on large maps, without overstretching the leg rig.
        let walkPeriod: Double = 2.6
        let maximumStride: CGFloat = 0.5
        let patrolSpan = min(safe.width * 0.04, maximumStride * 2 * CGFloat(patrolPeriod / walkPeriod))
        let travelRate = reduceMotion ? CGFloat(0) : patrolSpan * 2 / CGFloat(patrolPeriod)
        let stride = travelRate * CGFloat(walkPeriod) / 4
        let x = safe.minX + safe.width * 0.75 + patrolSpan * (travel - 0.5)
        let y = safe.minY + safe.height * 0.454 + sway
        // Roar: a ~2s smooth pulse once per 36s patrol loop, while facing +x.
        let roarDistance = min(abs(phase - 0.22), 1 - abs(phase - 0.22))
        let roarRaw = max(0, 1 - roarDistance / 0.055)
        let roarEnvelope = roarRaw * roarRaw * (3 - 2 * roarRaw)
        return KaijuPose(
            x: x,
            y: y,
            heading: phase < 0.5 ? 1 : -1,
            bob: reduceMotion ? 0 : CGFloat(sin(phase * .pi * 8)) * 0.35 * liveliness,
            // Reduced motion freezes locomotion at a connected neutral
            // stance: step 0 parks both lift clocks at zero crossings, so
            // both feet ground on their stations with the chains level.
            step: reduceMotion ? 0 : CGFloat(positiveRemainder(seconds / walkPeriod, 1)),
            stride: reduceMotion ? 0 : stride,
            sway: sway,
            tailPhase: reduceMotion ? 1.1 : CGFloat(seconds * .pi * 2 / 5.2),
            roar: reduceMotion ? 0 : CGFloat(roarEnvelope) * liveliness,
            liveliness: liveliness
        )
    }

    /// A recurring saucer crosses the near-city sky where its ground beam and
    /// hull remain discoverable at every zoom band. Without a mission it
    /// patrols the legacy lane; with one it runs 90-second sorties - easing
    /// out to the busiest plot (or the pending queue every other loop),
    /// hovering low with a beam scaled to the target's load, then returning.
    static func ufoEvent(date: Date, reduceMotion: Bool, bounds: CGRect, mission: UFOMission? = nil) -> UFOEvent {
        let phase = reduceMotion
            ? 0.58
            : positiveRemainder(date.timeIntervalSinceReferenceDate / 28, 1)
        let kaijuPhase = reduceMotion
            ? 0.31
            : positiveRemainder(date.timeIntervalSinceReferenceDate / 36, 1)
        let companionLaneOffset: CGFloat = sin(kaijuPhase * .pi * 2) >= 0 ? 0.012 : 0
        let safe = bounds.insetBy(
            dx: CityCreatureGeometry.UFO.diameter / 2,
            dy: CityCreatureGeometry.UFO.diameter / 2
        )
        // Legacy patrol lane; also the anchor sorties depart from and return to.
        let patrol = (
            x: safe.minX + safe.width * (0.793 + companionLaneOffset + 0.03 * CGFloat(phase)),
            y: safe.minY + safe.height * 0.446 - safe.width * companionLaneOffset
        )
        guard let mission, mission.scanTarget != nil || mission.queueTarget != nil else {
            return UFOEvent(
                x: patrol.x,
                y: patrol.y,
                altitude: 22.4 + CGFloat(sin(phase * .pi * 2)) * 1.5,
                beam: reduceMotion
                    ? 0.42
                    : 0.34 + 0.28 * triangleWave(phase * 2)
            )
        }

        let seconds = date.timeIntervalSinceReferenceDate
        let sortieLength: Double = 90
        let loop = reduceMotion ? 0 : Int(floor(seconds / sortieLength))
        let sortie = reduceMotion ? 0.5 : positiveRemainder(seconds / sortieLength, 1)
        // Alternate between scanning the busiest plot and inspecting the queue.
        let visitQueue = mission.queueDepth > 0
            && mission.queueTarget != nil
            && (mission.scanTarget == nil || loop % 2 == 1)
        let destination = visitQueue ? mission.queueTarget! : mission.scanTarget
        guard let target = destination else {
            // Work exists only in the other category this loop; hold the lane.
            return UFOEvent(x: patrol.x, y: patrol.y, altitude: 22.4, beam: 0.2)
        }
        let beamStrength = visitQueue
            ? min(1, 0.3 + 0.12 * Double(mission.queueDepth))
            : 0.35 + 0.65 * min(1, max(0, mission.scanIntensity))

        // Sortie envelope: approach (0..0.3), hover (0.3..0.75), depart (0.75..1).
        let approach = min(1, CGFloat(sortie / 0.3))
        let depart = sortie > 0.75 ? CGFloat((sortie - 0.75) / 0.25) : 0
        let easedApproach = approach * approach * (3 - 2 * approach)
        let easedDepart = depart * depart * (3 - 2 * depart)
        let toward = easedApproach * (1 - easedDepart)
        // Slow inspection drift while hovering.
        let hover = min(1, max(0, (CGFloat(sortie) - 0.3) / 0.12)) * (1 - easedDepart)
        let driftAngle = seconds * 0.9
        let drift = (
            x: cos(driftAngle) * 1.1 * hover,
            y: sin(driftAngle) * 0.8 * hover
        )
        let x = patrol.x + (target.x + drift.x - patrol.x) * toward
        let y = patrol.y + (target.y + drift.y - patrol.y) * toward
        let altitude = 22.4 - 5.6 * hover + CGFloat(sin(seconds * 1.7)) * 0.5 * hover
        let pulse = reduceMotion ? 0.5 : 0.5 + 0.5 * sin(seconds * 2.3)
        let beam = 0.15 + (beamStrength - 0.15) * hover * (0.75 + 0.25 * pulse)
        return UFOEvent(x: x, y: y, altitude: altitude, beam: beam)
    }

    private static func triangleWave(_ value: Double) -> CGFloat { CGFloat(1 - abs(2 * positiveRemainder(value, 1) - 1)) }

    private static func unitSeed(_ value: String) -> Double {
        let hash = value.utf8.reduce(UInt64(1_469_598_103_934_665_603)) { partial, byte in (partial ^ UInt64(byte)) &* 1_099_511_628_211 }
        return Double(hash % 1_000_000) / 1_000_000
    }

    static func positiveRemainder(_ value: Double, _ modulus: Double) -> Double {
        let remainder = value.truncatingRemainder(dividingBy: modulus)
        return remainder >= 0 ? remainder : remainder + modulus
    }
}
