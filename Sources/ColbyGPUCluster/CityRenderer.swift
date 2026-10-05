import AppKit
import SwiftUI

@MainActor
struct CityRenderer {
    let scape: CityScape
    let staticPaths: CitySceneStaticPaths
    let reduceMotion: Bool
    /// Measured node-level readings, independent of scheduler allocation.
    var gpuTelemetry: GPUTelemetrySnapshot = .empty
    /// Settled per-plot density stages (0...10); missing plots are baseline.
    var densityStages: [String: Int] = [:] {
        didSet {
            occlusionField = CityOcclusionField(
                occluders: staticPaths.occluders,
                densityStages: densityStages
            )
        }
    }
    private var occlusionField: CityOcclusionField

    init(scape: CityScape, staticPaths: CitySceneStaticPaths, reduceMotion: Bool) {
        self.scape = scape
        self.staticPaths = staticPaths
        self.reduceMotion = reduceMotion
        self.occlusionField = CityOcclusionField(
            occluders: staticPaths.occluders,
            densityStages: [:]
        )
    }

    private func densityStage(for plot: CityPlot) -> Int {
        densityStages[plot.id] ?? 0
    }

    /// Buildings revealed on this plot at its settled density stage.
    func visiblePavilions(for plot: CityPlot) -> [BuildingSpec] {
        let stage = densityStage(for: plot)
        return plot.buildings.filter { CityDensity.isRevealed($0.revealStage, at: stage) }
    }

    /// The plot's tallest revealed pavilion, but only once every one of its
    /// massing tiers has landed - live smoke and gauges anchor to a finished
    /// chimney mouth, never a rising shell.
    func completedChimneyHost(for plot: CityPlot) -> BuildingSpec? {
        let stage = densityStage(for: plot)
        guard let building = visiblePavilions(for: plot).max(by: { $0.h < $1.h }) else { return nil }
        let tierCount = max(1, building.tiers.count)
        let visible = CityDensity.visibleTierCount(revealStage: building.revealStage, tierCount: tierCount, stage: stage)
        return visible >= tierCount ? building : nil
    }
    struct WindowGrid: Equatable {
        let rows: Int
        let frontColumns: Int
        let sideColumns: Int
    }

    struct LifeScale {
        let smokeRadius: CGFloat
        let fireworkRadius: CGFloat
    }


    enum BaseWorldDepthKind: Equatable {
        case forestTree
        case campground
        case plot
        case lamp
        case prop
        case parkedCar
        case titan
    }

    enum BaseWorldDepthItem {
        case forestTree(Tree)
        case campground(CitySceneStaticPaths.Campground)
        case plot(CityPlot)
        case lamp(CGPoint)
        case prop(CityPlacementPlan.Prop)
        case parkedCar(CityPlacementPlan.ParkedCar)
        case titan(CityIsometricTitanGeometry, CityTitanSolid)

        var kind: BaseWorldDepthKind {
            switch self {
            case .forestTree: .forestTree
            case .campground: .campground
            case .plot: .plot
            case .lamp: .lamp
            case .prop: .prop
            case .parkedCar: .parkedCar
            case .titan: .titan
            }
        }
    }

    private static func byteHash(_ value: String) -> Int {
        value.utf8.reduce(2_166_136_261) { ($0 ^ Int($1)) &* 16_777_619 }
    }

    private static let starPositions: [(x: CGFloat, y: CGFloat)] = (0..<90).map { index in
        (
            CGFloat(Self.byteHash("57A7-x-\(index)") & 0xffff) / 65_535,
            CGFloat(Self.byteHash("57A7-y-\(index)") & 0xffff) / 65_535
        )
    }

    private static var cachedStarTwinkles: (step: Int, values: [Double])?
    private static var cachedWaterShimmer: (step: Int, values: [(distribution: Double, opacity: Double)])?

    private static func starTwinkles(for date: Date) -> [Double] {
        let step = Int(floor(date.timeIntervalSinceReferenceDate / 0.3))
        if let cachedStarTwinkles, cachedStarTwinkles.step == step { return cachedStarTwinkles.values }
        let values = (0..<90).map { index in CityWhimsy.starTwinkle(index: index, date: date) }
        cachedStarTwinkles = (step, values)
        return values
    }

    private static func waterShimmerValues(for date: Date) -> [(distribution: Double, opacity: Double)] {
        let step = Int(floor(date.timeIntervalSinceReferenceDate / 0.3))
        if let cachedWaterShimmer, cachedWaterShimmer.step == step { return cachedWaterShimmer.values }
        let values = (0..<36).map { index in
            (
                Double(Self.byteHash("shimmer-\(index)-\(step)") & 0xffff) / 65_535,
                Double(Self.byteHash("shimmer-alpha-\(index)-\(step)") & 0xffff) / 65_535
            )
        }
        cachedWaterShimmer = (step, values)
        return values
    }

    static func drawsFarTraffic(in _: ZoomBand) -> Bool { true }

    /// Province actors are roughly a pixel wide, so their cached screen bounds are sufficient.
    static func actorOcclusionUsesBoundsOnly(in band: ZoomBand) -> Bool { band == .province }


    /// Crane geometry is plot equipment; activity state may style it but must not include/exclude it.
    static func drawsCrane(hasCrane: Bool, mode _: CityMode) -> Bool {
        hasCrane
    }

    static func runningJobCount(in block: CityBlock, plots: [CityPlot]) -> Int {
        let plotIDs = Set(block.plotIDs)
        return plots
            .filter { plotIDs.contains($0.id) }
            .flatMap(\.node.jobs)
            .filter { $0.state == "RUNNING" }
            .reduce(into: Set<String>()) { seen, job in
                _ = seen.insert(job.id)
            }
            .count
    }

    static func shopStops(in block: CityBlock, plots: [CityPlot]) -> [(CGFloat, CGFloat)] {
        let plotIDs = Set(block.plotIDs)
        return plots
            .filter { plotIDs.contains($0.id) && ($0.mode == .lit || $0.mode == .half) }
            .flatMap(\.shops)
            .map { ($0.x, $0.y) }
    }

    static func localStreets(in block: CityBlock, scape: CityScape) -> [[(CGFloat, CGFloat)]] {
        let blockRect = CGRect(
            x: block.bounds.x,
            y: block.bounds.y - 4.1,
            width: block.bounds.w,
            height: block.bounds.d + 4.2
        )
        return scape.localStreets.filter { street in
            street.contains { point in
                blockRect.contains(CGPoint(x: point.0, y: point.1))
            }
        }
    }

    static func block(containing plotID: String, scape: CityScape) -> CityBlock? {
        scape.blocks.first { $0.plotIDs.contains(plotID) }
    }

    static func lifeScale(in band: ZoomBand) -> LifeScale {
        band == .province
            ? LifeScale(smokeRadius: 0.6, fireworkRadius: 0.7)
            : LifeScale(smokeRadius: 1, fireworkRadius: 1)
    }
    static func visibleCourierCount(runningJobs: Int, reduceMotion: Bool) -> Int {
        reduceMotion ? 0 : min(max(runningJobs, 0), 3)
    }
    static let humanWorldHeight: CGFloat = 0.48
    static let maxBuildingWorldHeight: CGFloat = 20



    static func visibleResidentCount(gpuCount: Int, jobPressure: Double) -> Int {
        let capacity = max(0, gpuCount)
        let occupied = min(1, max(0, jobPressure))
        return min(12, Int((Double(capacity) * occupied * 3).rounded()))
    }

    static func pavilionWindowIsLit(
        plotID: String,
        building: BuildingSpec,
        sequence: Int,
        t: Double,
        jobPressure: Double
    ) -> Bool {
        let seed = byteHash("\(plotID)-\(building.ox)-\(building.oy)")
        return CityWindows.isLit(
            buildingSeed: seed,
            sequence: sequence,
            t: t,
            load: jobPressure
        )
    }

    private static func dynamicActorCount(fullCount: Int, lod: CityDetailLevel) -> Int {
        guard fullCount > 0 else { return 0 }
        return Int(Double(fullCount) * lod.fade(CityDetailLevel.actors))
    }

    static func dynamicActorOpacity(lod: CityDetailLevel) -> Double {
        let range = CityDetailLevel.actors
        let bottomRampUpperBound = range.lowerBound + (range.upperBound - range.lowerBound) * 0.2
        return lod.fade(range.lowerBound...bottomRampUpperBound)
    }

    static func windowGrid(scale: CGFloat, h: CGFloat, bw: CGFloat, bd: CGFloat) -> WindowGrid? {
        // The voxel restyle makes each grid pitch 1.6× roomier; the renderer
        // then fills 80% of that pitch with a saturated facade cell.
        let city = WindowGrid(rows: max(1, Int(h / (2.8 * 1.6))), frontColumns: min(3, max(1, Int(bw / (1.6 * 1.6)))), sideColumns: min(2, max(1, Int(bd / (1.8 * 1.6)))))
        let street = WindowGrid(rows: max(1, Int(h / (2.2 * 1.6))), frontColumns: max(1, Int(bw / (1.25 * 1.6))), sideColumns: max(1, Int(bd / (1.25 * 1.6))))
        let quantizedScale = (scale * 4).rounded() / 4
        let progress = min(1, max(0, (quantizedScale - 1.9) / (3.2 - 1.9)))
        func interpolate(_ low: Int, _ high: Int) -> Int {
            Int((CGFloat(low) + CGFloat(high - low) * progress).rounded())
        }
        return WindowGrid(
            rows: interpolate(city.rows, street.rows),
            frontColumns: interpolate(city.frontColumns, street.frontColumns),
            sideColumns: interpolate(city.sideColumns, street.sideColumns)
        )
    }

    static func voxelTreeCanopyCount(x: CGFloat, y: CGFloat) -> Int {
        Int(UInt(bitPattern: Self.byteHash("\(x)-\(y)-canopy")) % 3) + 1
    }

    static func nonOverlappingLabelRects(_ candidates: [CGRect]) -> [CGRect] {
        candidates.reduce(into: []) { placed, candidate in
            if !placed.contains(where: { $0.intersects(candidate) }) { placed.append(candidate) }
        }
    }

    static func shadowQuad(x: CGFloat, y: CGFloat, bw: CGFloat, bd: CGFloat, h: CGFloat) -> [CGPoint] {
        let b0 = IsoProjection.project(x, y + bd)
        let b1 = IsoProjection.project(x + bw, y + bd)
        let height = min(26, abs(IsoProjection.project(x, y, h).y - IsoProjection.project(x, y).y))
        let offset = CGSize(width: height * 0.34, height: height * 0.18)
        return [b0, b1, CGPoint(x: b1.x + offset.width, y: b1.y + offset.height), CGPoint(x: b0.x + offset.width, y: b0.y + offset.height)]
    }

    /// Projected ground hull for one sunlight cast shadow. Height only scales
    /// the bounded world-space offset; it never changes the footprint.
    static func realtimeShadowQuad(
        x: CGFloat,
        y: CGFloat,
        bw: CGFloat,
        bd: CGFloat,
        h: CGFloat,
        lighting: CityLighting.Sample
    ) -> [CGPoint]? {
        guard lighting.shadowOpacity > 0, h > 0, bw > 0, bd > 0 else { return nil }
        let heightScale = min(1, h / 10)
        let dx = CGFloat(lighting.shadowOffset.width) * heightScale
        let dy = CGFloat(lighting.shadowOffset.height) * heightScale
        return [
            IsoProjection.project(x, y, 0.71),
            IsoProjection.project(x + bw, y, 0.71),
            IsoProjection.project(x + bw + dx, y + dy, 0.71),
            IsoProjection.project(x + bw + dx, y + bd + dy, 0.71),
            IsoProjection.project(x + dx, y + bd + dy, 0.71),
            IsoProjection.project(x, y + bd, 0.71),
        ]
    }


    static func pedestrianHeading(
        routeMetrics: CityWhimsy.RouteMetrics,
        progress: CGFloat,
        isReturning: Bool
    ) -> CGSize {
        guard let segment = routeMetrics.segmentEndpoints(progress: progress) else { return CGSize(width: 1, height: 0) }
        let projectedStart = IsoProjection.project(segment.start.x, segment.start.y)
        let projectedEnd = IsoProjection.project(segment.end.x, segment.end.y)
        let direction: CGFloat = isReturning ? -1 : 1
        return CGSize(
            width: (projectedEnd.x - projectedStart.x) * direction,
            height: (projectedEnd.y - projectedStart.y) * direction
        )
    }

    static func jobPlateLines(node: ClusterNode) -> [String] {
        let runningJobs = node.jobs.filter { $0.state == "RUNNING" }
        var lines = runningJobs.prefix(2).map { job in
            let elapsed = job.elapsedSeconds.map(DurationText.compact) ?? "0m"
            let remaining = job.remainingSeconds.map { "\(DurationText.compact($0)) left" } ?? "no wall"
            return "\(job.id) \(job.user) · \(elapsed) · \(remaining)"
        }
        if runningJobs.count > lines.count {
            lines.append("+\(runningJobs.count - lines.count) more")
        }
        return lines
    }

    /// The single hardware/VRAM fact for a plot, stated once — with the GPU
    /// ordinal only when the node actually has more than one unit.
    static func hardwareSignText(gpuIndex: Int, gpuCount: Int, gpuType: String, vramGB: Double) -> String {
        let hardware = "\(gpuType) · POP \(Int(vramGB)) GB"
        return gpuCount > 1 ? "GPU \(gpuIndex)/\(gpuCount) · \(hardware)" : hardware
    }

    private func nightColor(_ r: Double, _ g: Double, _ b: Double, sample: CityPalette.Sample, attenuation: Double = 1) -> Color {
        CityPalette.nightify(RGB(r: r, g: g, b: b), night: sample.night * attenuation).color
    }

    private func surfaceColor(day: RGB, night: RGB, sample: CityPalette.Sample, attenuation: Double = 1, daylightLift: Double = CityPalette.surfaceDaylightLift) -> Color {
        CityPalette.surface(day: day, night: night, sample: sample, nightAttenuation: attenuation, daylightLift: daylightLift).color
    }

    /// One shared plum-ink outline for every live drawing path.
    static let outlineInk = CalmCityStyle.ink.color.opacity(0.9)

    /// Mixes two token colors in the 0...255 domain.
    private static func mixed(_ lower: RGB, _ upper: RGB, _ amount: Double) -> RGB {
        RGB(
            r: lower.r + (upper.r - lower.r) * amount,
            g: lower.g + (upper.g - lower.g) * amount,
            b: lower.b + (upper.b - lower.b) * amount
        )
    }

    /// A world-surface token darkened toward the plum night for the sample.
    private func nightified(_ token: RGB, sample: CityPalette.Sample, attenuation: Double = 1) -> Color {
        CityPalette.nightify(token, night: sample.night * attenuation).color
    }

    func drawBackdrop(context: inout GraphicsContext, size: CGSize, sample: CityPalette.Sample) {
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .linearGradient(
                Gradient(colors: [sample.skyTop.color, sample.skyHorizon.color]),
                startPoint: .zero,
                endPoint: CGPoint(x: 0, y: size.height)
            )
        )
        let day = 1 - sample.night
        if day > 0.05 {
            // Clouds belong to the sky's hour: they drink the atmospheric
            // tint (peach at dawn, marigold at golden hour) and carry a
            // lavender underside instead of pasted-on pure white.
            let tintMix = min(0.75, sample.tintAmount * 1.4)
            let cloudTop = Self.mixed(RGB(r: 255, g: 255, b: 255), sample.tint, tintMix)
            let cloudUnder = Self.mixed(Self.mixed(RGB(r: 255, g: 255, b: 255), CalmCityStyle.lavender, 0.4), sample.tint, min(0.85, tintMix + 0.2))
            for anchor in [CGPoint(x: 0.16, y: 0.20), CGPoint(x: 0.44, y: 0.10), CGPoint(x: 0.86, y: 0.27)] {
                let c = CGPoint(x: size.width * anchor.x, y: size.height * anchor.y)
                let r = min(size.width, size.height) * 0.030
                let lobes: [(dx: CGFloat, dy: CGFloat, w: CGFloat, h: CGFloat)] = [
                    (-1.7, -1.0, 3.4, 2.0),
                    (-2.6, -0.2, 2.4, 1.3),
                    (0.4, -0.1, 2.5, 1.4),
                ]
                for lobe in lobes {
                    let rect = CGRect(
                        x: c.x + r * (lobe.dx + 0.12),
                        y: c.y + r * (lobe.dy + 0.34),
                        width: r * lobe.w,
                        height: r * lobe.h
                    )
                    context.fill(Path(ellipseIn: rect), with: .color(nightified(cloudUnder, sample: sample, attenuation: 0.5).opacity(0.5 * day)))
                }
                for lobe in lobes {
                    let rect = CGRect(x: c.x + r * lobe.dx, y: c.y + r * lobe.dy, width: r * lobe.w, height: r * lobe.h)
                    context.fill(Path(ellipseIn: rect), with: .color(nightified(cloudTop, sample: sample, attenuation: 0.5).opacity(0.85 * day)))
                }
            }
        }
        if sample.t > 0.25 && sample.t < 0.75 {
            drawCelestialBody(context: &context, size: size, sample: sample)
            return
        }
        let diameter = min(size.width, size.height) * 0.11
        let position = CityLighting.celestialPosition(palette: sample)
        let center = CGPoint(x: size.width * position.x, y: size.height * position.y)
        let halo = CGRect(x: center.x - diameter * 0.9, y: center.y - diameter * 0.9, width: diameter * 1.8, height: diameter * 1.8)
        context.fill(
            Path(ellipseIn: halo),
            with: .color(CalmCityStyle.lavender.color.opacity(0.08 * sample.night))
        )
        let disc = CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
        context.fill(Path(ellipseIn: disc), with: .color(CalmCityStyle.lavender.color.opacity(0.92)))
    }

    func drawCelestialBody(context: inout GraphicsContext, size: CGSize, sample: CityPalette.Sample) {
        guard sample.t > 0.25 && sample.t < 0.75 else { return }
        let diameter = min(size.width, size.height) * 0.07
        let position = CityLighting.celestialPosition(palette: sample)
        let center = CGPoint(x: size.width * position.x, y: size.height * position.y)
        let halo = CGRect(x: center.x - diameter * 1.05, y: center.y - diameter * 1.05, width: diameter * 2.1, height: diameter * 2.1)
        context.fill(
            Path(ellipseIn: halo),
            with: .color(CalmCityStyle.sun.color.opacity(0.14 * (1 - sample.night)))
        )
        let disc = CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
        context.fill(
            Path(ellipseIn: disc),
            with: .radialGradient(
                Gradient(colors: [CalmCityStyle.paper.color, CalmCityStyle.sun.color, Self.mixed(CalmCityStyle.sun, CalmCityStyle.marigold, 0.55).color]),
                center: center,
                startRadius: 0,
                endRadius: diameter / 2
            )
        )
    }

    /// Confetti drifts of wildflowers scattered across open meadow, cleared
    /// of plots, streets, and the river. Tiny fills, no strokes; they give
    /// the empty middle distance a storybook meadow texture at every zoom.
    private func drawWildflowerDrifts(context: inout GraphicsContext, sample: CityPalette.Sample) {
        let bounds = staticPaths.groundWorldBounds
        let polylines = [scape.avenue] + scape.localStreets + [scape.river]
        func clearOfInfrastructure(_ x: CGFloat, _ y: CGFloat) -> Bool {
            for polyline in polylines {
                for point in polyline where abs(point.0 - x) < 8 && abs(point.1 - y) < 8 {
                    if hypot(point.0 - x, point.1 - y) < 2.6 { return false }
                }
            }
            return !scape.plots.contains {
                $0.x - 2 <= x && x <= $0.x + $0.w + 2 && $0.y - 2 <= y && y <= $0.y + $0.d + 2
            }
        }
        for drift in 0..<9 {
            let hash = UInt(bitPattern: Self.byteHash("wildflower-drift-\(drift)"))
            let cx = bounds.minX + 8 + CGFloat(hash % 941) / 941 * (bounds.width - 16)
            let cy = bounds.minY + 8 + CGFloat((hash >> 10) % 947) / 947 * (bounds.height - 16)
            guard clearOfInfrastructure(cx, cy) else { continue }
            let petals = 7 + Int((hash >> 20) % 6)
            for petal in 0..<petals {
                let phash = UInt(bitPattern: Self.byteHash("wildflower-\(drift)-\(petal)"))
                let px = cx + (CGFloat(phash % 89) / 89 - 0.5) * 9
                let py = cy + (CGFloat((phash >> 7) % 83) / 83 - 0.5) * 9
                guard clearOfInfrastructure(px, py) else { continue }
                let tonePick = (phash >> 13) % 3
                let tone = tonePick == 0 ? CalmCityStyle.blossom : tonePick == 1 ? CalmCityStyle.marigold : CalmCityStyle.paper
                let p = IsoProjection.project(px, py, 0.02)
                let r = 0.55 + CGFloat((phash >> 20) % 3) * 0.2
                context.fill(
                    Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r * 0.62, width: r * 2, height: r * 1.24)),
                    with: .color(nightified(tone, sample: sample).opacity(0.75))
                )
            }
        }
    }

    /// Extruded soil-and-bedrock rims on the two near edges of the terrain
    /// slab, plus a soft umbra settling beneath it. Drawn before the ground
    /// fill so the lawn caps the wall tops and masks the shadow copies on
    /// every rim except the walled ones. Geometry-only, so the retained base
    /// stays byte-identical when jobs change.
    private func drawDioramaBase(context: inout GraphicsContext, sample: CityPalette.Sample) {
        let bounds = staticPaths.groundWorldBounds
        let southwest = IsoProjection.project(bounds.minX, bounds.maxY)
        let near = IsoProjection.project(bounds.maxX, bounds.maxY)
        let southeast = IsoProjection.project(bounds.maxX, bounds.minY)
        let depth: CGFloat = 22
        let shadowStrength = 0.35 + 0.65 * sample.dayAmount
        context.fill(
            staticPaths.ground.offsetBy(dx: 0, dy: depth * 1.9),
            with: .color(CalmCityStyle.ink.color.opacity(0.05 * shadowStrength))
        )
        context.fill(
            staticPaths.ground.offsetBy(dx: 0, dy: depth * 1.2),
            with: .color(CalmCityStyle.ink.color.opacity(0.07 * shadowStrength))
        )
        func band(_ a: CGPoint, _ b: CGPoint, _ top: CGFloat, _ bottom: CGFloat) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: a.x, y: a.y + top))
            path.addLine(to: CGPoint(x: b.x, y: b.y + top))
            path.addLine(to: CGPoint(x: b.x, y: b.y + bottom))
            path.addLine(to: CGPoint(x: a.x, y: a.y + bottom))
            path.closeSubpath()
            return path
        }
        // The southeast rim catches less sky than the southwest one, so its
        // strata run a half-step deeper for form separation.
        for (a, b, shade) in [(southwest, near, 0.0), (near, southeast, 0.16)] as [(CGPoint, CGPoint, Double)] {
            let grassLip = Self.mixed(CalmCityStyle.ground, CalmCityStyle.ink, 0.16 + shade)
            let topsoil = Self.mixed(CalmCityStyle.soilTop, CalmCityStyle.ink, shade)
            let subsoil = Self.mixed(CalmCityStyle.soilDeep, CalmCityStyle.ink, shade)
            let rock = Self.mixed(CalmCityStyle.bedrock, CalmCityStyle.ink, shade)
            context.fill(band(a, b, 0, 2.4), with: .color(nightified(grassLip, sample: sample)))
            context.fill(band(a, b, 2.4, depth * 0.48), with: .color(nightified(topsoil, sample: sample)))
            context.fill(band(a, b, depth * 0.48, depth * 0.8), with: .color(nightified(subsoil, sample: sample)))
            context.fill(band(a, b, depth * 0.8, depth), with: .color(nightified(rock, sample: sample)))
        }
    }

    func drawBaseWorld(
        context: inout GraphicsContext,
        size: CGSize,
        sample: CityPalette.Sample,
        camera: CityCamera,
        band: ZoomBand
    ) {
        context.concatenate(
            CGAffineTransform(translationX: camera.translation.width, y: camera.translation.height)
                .scaledBy(x: camera.scale, y: camera.scale)
        )
        let plan = CityRenderPlan(
            scape: scape,
            staticPaths: staticPaths,
            camera: camera,
            size: size,
            band: band
        )
        let lighting = CityLighting.sample(palette: sample)
        drawDioramaBase(context: &context, sample: sample)
        // Aerial perspective baked into the lawn itself: the far rim washes
        // toward the horizon sky while the near rim settles a half-step
        // deeper, so the diorama reads depth before any object is drawn.
        let worldBounds = staticPaths.groundWorldBounds
        let farCorner = IsoProjection.project(worldBounds.minX, worldBounds.minY)
        let nearCorner = IsoProjection.project(worldBounds.maxX, worldBounds.maxY)
        let horizonWash = Self.mixed(sample.skyHorizon, sample.skyTop, 0.3)
        let farGround = Self.mixed(CalmCityStyle.ground, horizonWash, 0.34)
        let nearGround = Self.mixed(CalmCityStyle.ground, CalmCityStyle.ink, 0.06)
        context.fill(
            staticPaths.ground,
            with: .linearGradient(
                Gradient(colors: [
                    nightified(farGround, sample: sample, attenuation: 0.85),
                    nightified(nearGround, sample: sample),
                ]),
                startPoint: farCorner,
                endPoint: nearCorner
            )
        )
        // Large soft mottling: terrain-scale sage and cream patches break the
        // single green long before the per-plot meadow specks register.
        for index in 0..<14 {
            let hash = UInt(bitPattern: Self.byteHash("terrain-mottle-\(index)"))
            let mx = worldBounds.minX + CGFloat(hash % 977) / 977 * worldBounds.width
            let my = worldBounds.minY + CGFloat((hash >> 10) % 971) / 971 * worldBounds.height
            let halfWidth = 34 + CGFloat((hash >> 20) % 46)
            let tone = index % 2 == 0
                ? Self.mixed(CalmCityStyle.ground, CalmCityStyle.leaf, 0.38)
                : Self.mixed(CalmCityStyle.ground, CalmCityStyle.paper, 0.40)
            let opacity = (0.13 + 0.09 * Double((hash >> 27) % 5) / 4) * (1 - 0.55 * sample.night)
            let p = IsoProjection.project(mx, my, 0.005)
            context.fill(
                Path(ellipseIn: CGRect(x: p.x - halfWidth, y: p.y - halfWidth * 0.55, width: halfWidth * 2, height: halfWidth * 1.1)),
                with: .color(nightified(tone, sample: sample).opacity(opacity))
            )
        }
        drawWildflowerDrifts(context: &context, sample: sample)
        // Soft meadow patches: large hashed pastel blobs break up the single
        // ground green. Geometry-only, so the retained base stays
        // byte-identical when jobs change.
        for plot in plan.visiblePlots {
            for index in 0..<2 {
                let hash = UInt(bitPattern: Self.byteHash("\(plot.id)-meadow-\(index)"))
                let mx = plot.x + plot.w * (CGFloat(hash % 89) / 89 * 1.8 - 0.4)
                let my = plot.y + plot.d * (CGFloat((hash >> 7) % 83) / 83 * 1.8 - 0.4)
                let radius = 9 + CGFloat((hash >> 14) % 7) * 2
                let token = index == 0
                    ? Self.mixed(CalmCityStyle.ground, CalmCityStyle.leaf, 0.30)
                    : Self.mixed(CalmCityStyle.ground, CalmCityStyle.paper, 0.35)
                let p = IsoProjection.project(mx, my, 0.01)
                context.fill(
                    Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius * 0.55, width: radius * 2, height: radius * 1.1)),
                    with: .color(nightified(token, sample: sample).opacity(0.5 * (1 - 0.55 * sample.night)))
                )
            }
        }
        drawHills(context: &context, sample: sample, visibleRect: plan.visibleRect)
        drawMountains(context: &context, sample: sample, visibleRect: plan.visibleRect)
        drawWater(context: &context, sample: sample)
        let roadFill = nightified(CalmCityStyle.road, sample: sample)
        for road in staticPaths.roads {
            context.fill(road.fill, with: .color(roadFill))
        }
        context.fill(staticPaths.bridgeTop, with: .color(nightified(CalmCityStyle.paper, sample: sample)))
        context.fill(staticPaths.bridgeSoutheast, with: .color(roadFill))
        context.fill(staticPaths.bridgeSouthwest, with: .color(roadFill))
        // Forest trees share world-depth ordering with plot slabs. Drawing the
        // entire belt before every plot lets nearer slabs bury tree trunks.
        let forestCullRect = plan.visibleRect.insetBy(dx: -24, dy: -24)
        let visibleForest = staticPaths.forest.filter {
            forestCullRect.contains(IsoProjection.project($0.x, $0.y, 0))
        }

        drawCityDetail(context: &context, staticPaths: staticPaths, plan: plan, sample: sample)
        if band != .province {
            drawStreetLampPools(
                context: &context,
                visibleRect: plan.visibleRect,
                lighting: lighting,
                multiplier: band == .street ? 1 : 0.7
            )
        }
        drawDepthSortedForestPlotGeometryAndLampFixtures(
            context: &context,
            plan: plan,
            forest: visibleForest,
            sample: sample,
            lighting: lighting,
            band: band
        )
    }

    nonisolated static func farTrafficDescriptor(
        for car: CityWhimsy.FarCar,
        index: Int
    ) -> CityLiveItemDescriptor {
        let x = car.x - car.dirY * 0.45
        let y = car.y + car.dirX * 0.45
        return CityLiveItemDescriptor(
            id: "far-traffic-\(index)",
            layer: .world,
            mode: .skip,
            anchor: CityWorldAnchor(x: x, y: y, z: 0.15),
            sortKey: IsoProjection.sortKey(x: x, y: y),
            probeBounds: nil
        )
    }

    func drawLiveOverlay(
        context: inout GraphicsContext,
        size: CGSize,
        date: Date,
        sample: CityPalette.Sample,
        camera: CityCamera,
        band: ZoomBand,
        director: CityDirector,
        refreshState: SnapshotRefreshState,
        pending: [PendingJob],
        hoverPoint: CGPoint?,
        hoveredPlotID: String?,
        selectedPlotID: String?,
        bubble: (plotID: String, citizenIndex: Int, text: String, shownAt: Date)?,
        construction: [String: CityDirector.DensityTransition] = [:]
    ) {
        var overlayContext = context
        context.concatenate(
            CGAffineTransform(translationX: camera.translation.width, y: camera.translation.height)
                .scaledBy(x: camera.scale, y: camera.scale)
        )
        let plan = CityRenderPlan(
            scape: scape,
            staticPaths: staticPaths,
            camera: camera,
            size: size,
            band: band
        )
        let smokePhase = reduceMotion ? 0 : date.timeIntervalSinceReferenceDate
        let lighting = CityLighting.sample(palette: sample)
        let lod = CityDetailLevel(scale: camera.scale, band: band)
        // Cluster-wide vitals drive the data vignettes: titan wake, UFO scan
        // targets, kaiju energy, balloon festival, idle fireflies.
        let vitals = Self.clusterVitals(scape: scape, pendingCount: pending.count)
        let wake = reduceMotion ? director.titanWakeTarget : director.titanWake(at: date)
        var ufoMission = CityWhimsy.UFOMission()
        ufoMission.scanTarget = vitals.busiestAnchor
        ufoMission.scanIntensity = vitals.busiestJobPressure
        if vitals.pendingJobs > 0, let anchor = scape.commuterQueueAnchors(count: 1).first {
            ufoMission.queueTarget = CGPoint(x: anchor.0, y: anchor.1)
            ufoMission.queueDepth = vitals.pendingJobs
        }
        // The golem's pose is resolved once per overlay pass so the posed
        // masses, their occluders, and their capture phases all agree.
        // Under Reduce Motion the breath phase pins to mid-swell: the
        // data-dependent wake pose stays valid, idle oscillation stops,
        // and two captures 120s apart render the identical settled golem.
        let golemSeconds = date.timeIntervalSinceReferenceDate
        let golemBreath: CGFloat = reduceMotion ? 0.5 : CGFloat(0.5 + 0.5 * sin(golemSeconds * 0.9))
        let golemPose = Self.sleepingTitanGeometry(
            worldBounds: staticPaths.groundWorldBounds,
            wake: CGFloat(wake),
            breath: golemBreath
        )
        let golemSolids = golemPose.dynamicSolids
        // Ambient world life: animated river sparkle and distant avenue traffic.
        drawWaterShimmer(context: &context, date: date, sample: sample)
        // Build the live sprite queue with world anchors and depth ordering.
        var queue = CityLiveQueue()
        let field = CityOcclusionField(
            occluders: staticPaths.occluders + golemSolids.map {
                CitySceneStaticPaths.titanOccluder(solid: $0)
            },
            densityStages: densityStages
        )
        let farTrafficRadius = max(0.5, 1.0 / max(camera.scale, 0.01))
        for (index, car) in CityWhimsy.farTraffic(
            routeMetrics: scape.trafficRouteMetrics,
            date: date,
            reduceMotion: reduceMotion
        ).enumerated() {
            let descriptor = Self.farTrafficDescriptor(for: car, index: index)
            let point = IsoProjection.project(
                descriptor.anchor.x,
                descriptor.anchor.y,
                descriptor.anchor.z
            )
            guard plan.visibleRect
                .insetBy(dx: -farTrafficRadius, dy: -farTrafficRadius)
                .contains(point)
            else { continue }
            queue.enqueue(descriptor) { [self] ctx in
                var context = ctx
                drawFarTrafficSprite(
                    context: &context,
                    car: car,
                    sample: sample,
                    radius: farTrafficRadius,
                    band: band
                )
            }
        }
        
        for plot in plan.visiblePlots {
            // Row 1: Construction
            if let transition = construction[plot.id] {
                queue.enqueue(
                    CityLiveItemDescriptor(
                        id: "construction-\(plot.id)",
                        layer: .world,
                        mode: .none,
                        anchor: CityWorldAnchor(x: plot.x, y: plot.y, z: 0),
                        sortKey: IsoProjection.sortKey(x: plot.x, y: plot.y),
                        probeBounds: nil
                    )
                ) { [self] ctx in
                    var context = ctx
                    drawConstruction(context: &context, plot: plot, transition: transition, date: date, sample: sample, lighting: lighting, band: band)
                }
            }
            
            
            // Row 3: Chimney Smoke - per-puff extraction
            if plot.mode == .lit || plot.mode == .half,
               UInt(bitPattern: Self.byteHash("\(plot.id)-smokes")) % 2 == 0,
               let building = completedChimneyHost(for: plot) {
                let height = min(building.h, Self.maxBuildingWorldHeight)
                let seed = Double(UInt(bitPattern: Self.byteHash("\(plot.id)-smoke-seed")) % 997) / 997
                let sx = plot.x + building.ox + building.bw * 0.28
                let sy = plot.y + building.oy + building.bd * 0.30
                let top = height + 1.35
                for index in 0..<3 {
                    queue.enqueue(
                        CityLiveItemDescriptor(
                            id: "smoke-\(plot.id)-\(index)",
                            layer: .world,
                            mode: .none,
                            anchor: CityWorldAnchor(x: sx, y: sy, z: top),
                            sortKey: IsoProjection.sortKey(x: sx, y: sy),
                            probeBounds: nil
                        )
                    ) { ctx in
                        let context = ctx
                        let puff = Color(red: 1, green: 0.99, blue: 0.97)
                        let life = (smokePhase * 0.22 + Double(index) / 3 + seed).truncatingRemainder(dividingBy: 1)
                        let p = IsoProjection.project(sx - CGFloat(life) * 1.6, sy - CGFloat(life) * 0.9, top + CGFloat(life) * 3.2)
                        let radius = 1.1 + CGFloat(life) * 2.6
                        context.fill(
                            Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)),
                            with: .color(puff.opacity(Double(1 - life) * (0.5 - 0.22 * sample.night)))
                        )
                    }
                }
            }
            
            // Row 4: Citizens (hoist loop)
            if plot.mode == .lit || plot.mode == .half {
                let jobPressure = CityWindows.runningJobPressure(for: plot.node)
                let residentCount = Self.visibleResidentCount(gpuCount: plot.node.totalGPUCount, jobPressure: jobPressure)
                let count = Self.dynamicActorCount(fullCount: residentCount, lod: lod)
                let opacity = Self.dynamicActorOpacity(lod: lod)
                let center = IsoProjection.project(plot.x + plot.w / 2, plot.y + plot.d / 2, 1)
                for index in 0..<count {
                    let world = citizenWorldPosition(plot: plot, index: index, date: date)
                    let p = IsoProjection.project(world.x, world.y, 0.05)
                    let key = plot.node.jobs.isEmpty ? plot.node.name : plot.node.jobs[index % plot.node.jobs.count].user
                    queue.enqueue(
                        CityLiveItemDescriptor(
                            id: "citizen-\(plot.id)-\(index)",
                            layer: .world,
                            mode: .none,
                            anchor: CityWorldAnchor(x: world.x, y: world.y, z: 0.05),
                            sortKey: IsoProjection.sortKey(x: world.x, y: world.y),
                            probeBounds: nil
                        )
                    ) { [self] ctx in
                        var context = ctx
                        drawOcclusionAwareBlob(
                            context: &context,
                            worldX: world.x,
                            worldY: world.y,
                            at: p,
                            key: key,
                            heading: CGSize(width: center.x - p.x, height: center.y - p.y),
                            date: date,
                            sample: sample,
                            opacity: opacity
                        )
                    }
                }
            }
            // Row 5: Activities
            let footprints = plot.buildings.map { building in
                CGRect(x: plot.x + building.ox, y: plot.y + building.oy, width: building.bw, height: building.bd)
            }
            if let scene = CityWhimsy.activityScene(plotID: plot.id, x: plot.x, y: plot.y, w: plot.w, d: plot.d, footprints: footprints) {
                queue.enqueue(
                    CityLiveItemDescriptor(
                        id: "activity-\(plot.id)",
                        layer: .world,
                        mode: .none,
                        anchor: CityWorldAnchor(x: scene.x, y: scene.y, z: 0.05),
                        sortKey: IsoProjection.sortKey(x: scene.x, y: scene.y),
                        probeBounds: nil
                    )
                ) { [self] ctx in
                    var context = ctx
                    drawActivities(context: &context, plot: plot, scape: scape, date: date, sample: sample, band: band, lod: lod)
                }
            }
            if sample.night > 0.3, plot.node.jobs.isEmpty,
               plot.node.totalGPUCount > 0,
               plot.node.freeGPUCount == plot.node.totalGPUCount {
                let moteScale: CGFloat = band == .province ? 1.8 : 1
                let anchor = (x: plot.x + plot.w / 2, y: plot.y + plot.d / 2)
                let flies = CityWhimsy.fireflies(
                    plotID: plot.id,
                    anchor: anchor,
                    count: 2,
                    date: date,
                    reduceMotion: reduceMotion
                )
                for (i, fly) in flies.enumerated() {
                    let point = IsoProjection.project(fly.x, fly.y, fly.z)
                    let spriteBounds = CGRect(
                        x: point.x - 2.3 * moteScale,
                        y: point.y - 2.3 * moteScale,
                        width: 4.6 * moteScale,
                        height: 4.6 * moteScale
                    )
                    queue.enqueue(
                        CityLiveItemDescriptor(
                            id: "firefly-\(plot.id)-\(i)",
                            layer: .world,
                            mode: .punch(),
                            anchor: CityWorldAnchor(x: fly.x, y: fly.y, z: fly.z),
                            sortKey: IsoProjection.sortKey(x: fly.x, y: fly.y),
                            probeBounds: spriteBounds
                        )
                    ) { ctx in
                        let context = ctx
                        let glowRadius: CGFloat = 2.3 * moteScale
                        context.fill(
                            Path(ellipseIn: CGRect(
                                x: point.x - glowRadius,
                                y: point.y - glowRadius,
                                width: glowRadius * 2,
                                height: glowRadius * 2
                            )),
                            with: .color(fly.tint.color.opacity(0.10 * fly.opacity * sample.night))
                        )
                        let core = 0.85 * moteScale
                        context.fill(
                            Path(ellipseIn: CGRect(x: point.x - core, y: point.y - core, width: core * 2, height: core * 2)),
                            with: .color(fly.tint.color.opacity(0.85 * fly.opacity))
                        )
                    }
                }
            }
            
            
            // Row 8: Cars - per-car extraction
            if band == .street {
                let cone = CityRenderPolicies.headlightCone(band: band)
                var parkedSlot = 0
                let spaced = director.spacedCarPositions(plotID: plot.id, scape: scape, date: date)
                for car in director.cars where car.plotID == plot.id {
                    var seat: (x: CGFloat, y: CGFloat, alongX: Bool)?
                    if case .parked = car.phase {
                        if let spots = staticPaths.placement.commuteSpots[plot.id],
                           parkedSlot < spots.count {
                            let spot = spots[parkedSlot]
                            seat = (spot.x, spot.y, true)
                        }
                        parkedSlot += 1
                    } else if let position = spaced[car.id] {
                        seat = position
                    }
                    if let seat {
                        queue.enqueue(
                            CityLiveItemDescriptor(
                                id: "car-\(car.id)",
                                layer: .world,
                                mode: .none,
                                anchor: CityWorldAnchor(x: seat.x, y: seat.y, z: 0.5),
                                sortKey: IsoProjection.sortKey(x: seat.x, y: seat.y),
                                probeBounds: nil
                            )
                        ) { [self] ctx in
                            var context = ctx
                            guard !occlusionField.isHidden(worldX: seat.x, worldY: seat.y, z: 0.5) else { return }
                            let hash = stableByteHash(car.id) & Int.max
                            let kind = Self.carKind(forHash: hash)
                            drawCar(
                                context: &context,
                                at: (seat.x, seat.y),
                                alongX: seat.alongX,
                                colorToken: car.colorToken,
                                sample: sample,
                                kind: kind,
                                bodyToken: kind == .van ? Self.carBodyTokens[(hash / 10) % Self.carBodyTokens.count] : nil
                            )
                            if let cone { drawHeadlightCone(context: &context, at: (seat.x, seat.y), alongX: seat.alongX, cone: cone) }
                        }
                    }
                }
            }
            // Row 9: Pedestrians - per-walker extraction
            if let routeMetrics = scape.entryRouteMetrics(for: plot.id) {
                let jobPressure = CityWindows.runningJobPressure(for: plot.node)
                let residentCount = Self.visibleResidentCount(gpuCount: plot.node.totalGPUCount, jobPressure: jobPressure)
                let count = Self.dynamicActorCount(fullCount: residentCount, lod: lod)
                let opacity = Self.dynamicActorOpacity(lod: lod)
                let walkers = CityWhimsy.pedestrians(
                    plotID: plot.id,
                    count: count,
                    routeMetrics: routeMetrics,
                    date: date,
                    reduceMotion: reduceMotion
                )
                for (i, w) in walkers.enumerated() {
                    queue.enqueue(
                        CityLiveItemDescriptor(
                            id: "walker-\(plot.id)-\(i)",
                            layer: .world,
                            mode: .none,
                            anchor: CityWorldAnchor(x: w.x, y: w.y, z: 0.05),
                            sortKey: IsoProjection.sortKey(x: w.x, y: w.y),
                            probeBounds: nil
                        )
                    ) { [self] ctx in
                        var context = ctx
                        let heading = Self.pedestrianHeading(
                            routeMetrics: routeMetrics,
                            progress: w.progress,
                            isReturning: w.isReturning
                        )
                        let point = IsoProjection.project(w.x, w.y, 0.05)
                        let bob = reduceMotion ? 0 : CGFloat(sin(w.bobPhase)) * 0.5
                        drawOcclusionAwareBlob(
                            context: &context,
                            worldX: w.x,
                            worldY: w.y,
                            at: CGPoint(x: point.x, y: point.y + bob),
                            key: w.colorKey,
                            heading: heading,
                            date: date,
                            sample: sample,
                            opacity: opacity
                        )
                    }
                }
            }
            
            
            // Row 17: Searchlight
            if band != .province,
               plot.mode == .lit, GPUTier(rawValue: plot.node.profile) == .h200,
               let tallest = plot.buildings.max(by: { $0.h < $1.h }),
               let angle = CityWhimsy.searchlightAngle(plotID: plot.id, date: date) {
                let height = tallest.h
                let cx = plot.x + plot.w / 2
                let cy = plot.y + plot.d / 2
                queue.enqueue(
                    CityLiveItemDescriptor(
                        id: "searchlight-\(plot.id)",
                        layer: .aerial,
                        mode: .skip,
                        anchor: CityWorldAnchor(x: cx, y: cy, z: height),
                        sortKey: IsoProjection.sortKey(x: cx, y: cy),
                        probeBounds: nil
                    )
                ) { [self] ctx in
                    var context = ctx
                    drawSearchlight(context: &context, plot: plot, building: tallest, angle: angle, visibleRect: plan.visibleRect, cameraScale: camera.scale, sample: sample)
                }
            }
            
            // Row 18: Fireworks - per-spark extraction
            if band != .province, let launch = director.celebrationsByPlot[plot.id] {
                let fireworkScale = plan.lifeScale.fireworkRadius
                for (sparkIndex, spark) in CityWhimsy.fireworkParticles(
                    plotID: plot.id,
                    plotOrigin: CGPoint(x: plot.x, y: plot.y),
                    sinceLaunch: date.timeIntervalSince(launch),
                    reduceMotion: reduceMotion
                ).enumerated() {
                    queue.enqueue(
                        CityLiveItemDescriptor(
                            id: "firework-\(plot.id)-\(sparkIndex)",
                            layer: .aerial,
                            mode: .skip,
                            anchor: CityWorldAnchor(x: spark.x, y: spark.y, z: spark.z),
                            sortKey: IsoProjection.sortKey(x: spark.x, y: spark.y),
                            probeBounds: nil
                        )
                    ) { ctx in
                        let context = ctx
                        let point = IsoProjection.project(spark.x, spark.y, spark.z)
                        let radius = spark.radius * fireworkScale
                        context.fill(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)), with: .color(spark.tint.color))
                    }
                }
            }
        }
        
        // Row 11: Shopper Bustle - per-actor/table/cart extraction
        let actorOpacity = Self.dynamicActorOpacity(lod: lod)
        if actorOpacity > 0 {
            for block in scape.blocks {
                let runningJobCount = Self.runningJobCount(in: block, plots: scape.plots)
                let fullCount = min(10, 2 + max(0, runningJobCount))
                let count = Self.dynamicActorCount(fullCount: fullCount, lod: lod)
                guard count > 0 else { continue }
                for (shopperIndex, shopper) in CityWhimsy.shoppers(
                    shopStops: Self.shopStops(in: block, plots: scape.plots),
                    runningJobCount: runningJobCount,
                    date: date,
                    reduceMotion: reduceMotion
                ).prefix(count).enumerated() {
                    queue.enqueue(
                        CityLiveItemDescriptor(
                            id: "shopper-\(block.id)-\(shopperIndex)",
                            layer: .world,
                            mode: .none,
                            anchor: CityWorldAnchor(x: shopper.x, y: shopper.y, z: 0.05),
                            sortKey: IsoProjection.sortKey(x: shopper.x, y: shopper.y),
                            probeBounds: nil
                        )
                    ) { [self] ctx in
                        var context = ctx
                        let point = IsoProjection.project(shopper.x, shopper.y, 0.05)
                        drawOcclusionAwareBlob(
                            context: &context,
                            worldX: shopper.x,
                            worldY: shopper.y,
                            at: point,
                            key: shopper.colorKey,
                            heading: CGSize(width: 1, height: 0),
                            date: date,
                            sample: sample,
                            opacity: actorOpacity
                        )
                        if shopper.dwelling {
                            for offset: CGFloat in [-0.7, 0.7] {
                                context.fill(
                                    Path(ellipseIn: CGRect(x: point.x + offset - 0.38, y: point.y - 5.2 - abs(offset) * 0.35, width: 0.76, height: 0.76)),
                                    with: .color(Color(red: 1, green: 0.76, blue: 0.30).opacity(0.9 * actorOpacity))
                                )
                            }
                        }
                    }
                }
            }
            
            let shops = scape.plots
                .filter { $0.mode == .lit || $0.mode == .half }
                .flatMap(\.shops)
            let patronBob = reduceMotion ? 0 : CGFloat(sin(date.timeIntervalSinceReferenceDate * .pi * 4)) * 0.18
            for (shopIndex, shop) in shops.enumerated() where shop.kind == .cafe {
                let outward = shop.facingX ? (x: CGFloat(0), y: CGFloat(0.9)) : (x: CGFloat(0.9), y: CGFloat(0))
                let seatAxis = shop.facingX ? (x: CGFloat(0.7), y: CGFloat(0)) : (x: CGFloat(0), y: CGFloat(0.7))
                let tableWorld = (x: shop.x + outward.x, y: shop.y + outward.y)
                guard !occlusionField.isHidden(worldX: tableWorld.x, worldY: tableWorld.y, z: 0.18, boundsOnly: Self.actorOcclusionUsesBoundsOnly(in: band)) else { continue }
                queue.enqueue(
                    CityLiveItemDescriptor(
                        id: "cafe-table-\(shopIndex)",
                        layer: .world,
                        mode: .none,
                        anchor: CityWorldAnchor(x: tableWorld.x, y: tableWorld.y, z: 0.2),
                        sortKey: IsoProjection.sortKey(x: tableWorld.x, y: tableWorld.y),
                        probeBounds: nil
                    )
                ) { ctx in
                    var context = ctx
                    let table = IsoProjection.project(tableWorld.x, tableWorld.y, 0.2)
                    context.opacity *= actorOpacity
                    context.fill(Path(ellipseIn: CGRect(x: table.x - 1.5, y: table.y - 1.0, width: 3, height: 1.5)), with: .color(Color(red: 0.35, green: 0.22, blue: 0.13)))
                }
                let patronCount = Self.dynamicActorCount(fullCount: 2, lod: lod)
                for side in Array<CGFloat>([-1, 1]).prefix(patronCount) {
                    let patronWorld = (x: tableWorld.x + seatAxis.x * side, y: tableWorld.y + seatAxis.y * side)
                    queue.enqueue(
                        CityLiveItemDescriptor(
                            id: "cafe-patron-\(shopIndex)-\(side)",
                            layer: .world,
                            mode: .none,
                            anchor: CityWorldAnchor(x: patronWorld.x, y: patronWorld.y, z: 0.05),
                            sortKey: IsoProjection.sortKey(x: patronWorld.x, y: patronWorld.y),
                            probeBounds: nil
                        )
                    ) { [self] ctx in
                        var context = ctx
                        let patron = IsoProjection.project(patronWorld.x, patronWorld.y, 0.05 + patronBob)
                        drawBlob(context: &context, at: patron, key: "cafe-patron-\(shopIndex)-\(side)", heading: CGSize(width: side, height: 0), date: date, sample: sample, opacity: actorOpacity)
                    }
                }
            }
            
            for (plazaIndex, plaza) in scape.plazas.enumerated() {
                guard !occlusionField.isHidden(worldX: plaza.x, worldY: plaza.y, z: 0.18, boundsOnly: Self.actorOcclusionUsesBoundsOnly(in: band)) else { continue }
                queue.enqueue(
                    CityLiveItemDescriptor(
                        id: "plaza-cart-\(plazaIndex)",
                        layer: .world,
                        mode: .none,
                        anchor: CityWorldAnchor(x: plaza.x, y: plaza.y, z: 0.2),
                        sortKey: IsoProjection.sortKey(x: plaza.x, y: plaza.y),
                        probeBounds: nil
                    )
                ) { ctx in
                    var context = ctx
                    let cart = IsoProjection.project(plaza.x, plaza.y, 0.2)
                    let basket = CGRect(x: cart.x - 1.7, y: cart.y - 1.1, width: 3.4, height: 1.8)
                    context.opacity *= actorOpacity
                    context.fill(Path(roundedRect: basket, cornerRadius: 0.35), with: .color(Color(red: 0.38, green: 0.22, blue: 0.12)))
                    for (index, offset) in [-1.4, 0, 1.4].enumerated() {
                        let balloon = CGPoint(x: cart.x + offset, y: cart.y - 5.4 - CGFloat(index % 2) * 0.7)
                        context.fill(Path(ellipseIn: CGRect(x: balloon.x - 1.15, y: balloon.y - 1.55, width: 2.3, height: 3.1)), with: .color([Color(red: 1, green: 0.58, blue: 0.24), Color(red: 0.32, green: 0.90, blue: 0.58), Color(red: 0.96, green: 0.34, blue: 0.50)][index].opacity(0.92)))
                        stroke(context: &context, [CGPoint(x: balloon.x, y: balloon.y + 1.55), CGPoint(x: basket.midX, y: basket.minY)], color: .white.opacity(0.5), width: 0.45)
                    }
                }
            }
        }
        
        // Row 12: Commuters - per-car extraction
        let count = queueCarCount(pending: pending)
        let phase = reduceMotion ? 0 : date.timeIntervalSinceReferenceDate
        for (index, anchor) in scape.commuterQueueAnchors(count: count).enumerated() {
            let job = pending[index]
            queue.enqueue(
                CityLiveItemDescriptor(
                    id: "commuter-\(index)",
                    layer: .world,
                    mode: .none,
                    anchor: CityWorldAnchor(x: anchor.0, y: anchor.1, z: band == .province ? 0.8 : 0.5),
                    sortKey: IsoProjection.sortKey(x: anchor.0, y: anchor.1),
                    probeBounds: nil
                )
            ) { [self] ctx in
                var context = ctx
                switch band {
                case .province:
                    if occlusionField.isHidden(worldX: anchor.0, worldY: anchor.1, z: 0.8, boundsOnly: Self.actorOcclusionUsesBoundsOnly(in: band)) { return }
                    let p = IsoProjection.project(anchor.0, anchor.1, 0.8)
                    let bob = reduceMotion ? 0 : CGFloat(sin(phase * 1.4 + Double(index)))
                    drawBlob(context: &context, at: CGPoint(x: p.x, y: p.y + bob), key: job.user, heading: CGSize(width: 1, height: 0), date: Date(timeIntervalSinceReferenceDate: phase), sample: sample)
                case .city, .street:
                    guard !occlusionField.isHidden(worldX: anchor.0, worldY: anchor.1, z: 0.5) else { return }
                    drawCar(context: &context, at: anchor, alongX: false, colorToken: carColorRGB(for: job.user), sample: sample)
                    if let cone = CityRenderPolicies.headlightCone(band: band) { drawHeadlightCone(context: &context, at: anchor, alongX: false, cone: cone) }
                }
            }
        }
        
        // Row 13: Strollers - per-stroller extraction
        if CityRenderPolicies.shouldDrawStrollers(band: band) {
            let strollerOpacity = Self.dynamicActorOpacity(lod: lod)
            for (strollerIndex, stroller) in CityWhimsy.strollers(
                localStreets: scape.localStreets,
                runningJobCount: scape.runningJobs.count,
                date: date,
                reduceMotion: reduceMotion
            ).enumerated() {
                let point = IsoProjection.project(stroller.x, stroller.y, 0.05)
                guard plan.visibleRect.insetBy(dx: -2, dy: -2).contains(point) else { continue }
                queue.enqueue(
                    CityLiveItemDescriptor(
                        id: "stroller-\(strollerIndex)",
                        layer: .world,
                        mode: .none,
                        anchor: CityWorldAnchor(x: stroller.x, y: stroller.y, z: 0.05),
                        sortKey: IsoProjection.sortKey(x: stroller.x, y: stroller.y),
                        probeBounds: nil
                    )
                ) { [self] ctx in
                    var context = ctx
                    let point = IsoProjection.project(stroller.x, stroller.y, 0.05)
                    let headingPoint = IsoProjection.project(
                        stroller.x + stroller.headingX,
                        stroller.y + stroller.headingY,
                        0.05
                    )
                    drawOcclusionAwareBlob(
                        context: &context,
                        worldX: stroller.x,
                        worldY: stroller.y,
                        at: point,
                        key: stroller.colorKey,
                        heading: CGSize(
                            width: headingPoint.x - point.x,
                            height: headingPoint.y - point.y
                        ),
                        date: date,
                        sample: sample,
                        opacity: strollerOpacity
                    )
                }
            }
        }
        
        // Row 13: Woodland Runners - per-runner extraction
        if band != .province {
            let runnerOpacity = Self.dynamicActorOpacity(lod: lod)
            let centers = staticPaths.campgrounds.map(\.center)
            for (runnerIndex, runner) in CityWhimsy.woodlandRunners(
                centers: centers,
                date: date,
                reduceMotion: reduceMotion
            ).enumerated() {
                let point = IsoProjection.project(runner.x, runner.y, 0.05)
                guard plan.visibleRect.insetBy(dx: -3, dy: -3).contains(point) else { continue }
                queue.enqueue(
                    CityLiveItemDescriptor(
                        id: "runner-\(runnerIndex)",
                        layer: .world,
                        mode: .none,
                        anchor: CityWorldAnchor(x: runner.x, y: runner.y, z: 0.05),
                        sortKey: IsoProjection.sortKey(x: runner.x, y: runner.y),
                        probeBounds: nil
                    )
                ) { [self] ctx in
                    var context = ctx
                    let point = IsoProjection.project(runner.x, runner.y, 0.05)
                    let headingPoint = IsoProjection.project(
                        runner.x + runner.headingX,
                        runner.y + runner.headingY,
                        0.05
                    )
                    let bob = reduceMotion ? 0 : CGFloat(sin(runner.bobPhase)) * 0.6
                    drawOcclusionAwareBlob(
                        context: &context,
                        worldX: runner.x,
                        worldY: runner.y,
                        at: CGPoint(x: point.x, y: point.y + bob),
                        key: runner.colorKey,
                        heading: CGSize(
                            width: headingPoint.x - point.x,
                            height: headingPoint.y - point.y
                        ),
                        date: date,
                        sample: sample,
                        opacity: runnerOpacity
                    )
                }
            }
        }
        
        // Rows 14-16: Creature Events (Kaiju, UFO Beam, UFO Hull)
        let bounds = staticPaths.groundWorldBounds
        let kaiju = CityWhimsy.kaijuPose(date: date, reduceMotion: reduceMotion, bounds: bounds, energy: vitals.allocationFraction)
        if plan.visibleRect.intersects(CityCreatureGeometry.kaijuProjectedBounds(for: kaiju)) {
            let kaijuBounds = CityCreatureGeometry.kaijuProjectedBounds(for: kaiju)
            queue.enqueue(
                CityLiveItemDescriptor(
                    id: "kaiju",
                    layer: .world,
                    mode: .punch(),
                    anchor: CityWorldAnchor(x: kaiju.x, y: kaiju.y, z: 0),
                        sortKey: IsoProjection.sortKey(x: kaiju.x, y: kaiju.y),
                    probeBounds: kaijuBounds
                )
            ) { [self] ctx in
                var context = ctx
                drawKaiju(context: &context, pose: kaiju, sample: sample, detail: CityCreatureDetail(band: band))
            }
        }
        
        let ufo = CityWhimsy.ufoEvent(date: date, reduceMotion: reduceMotion, bounds: bounds, mission: ufoMission)
        if plan.visibleRect.intersects(CityCreatureGeometry.ufoProjectedBounds(for: ufo)) {
            let detail = CityCreatureDetail(band: band)
            
            // Row 15: UFO Beam - compute actual frustum bounds and exclusion
            let center = CGPoint(x: ufo.x, y: ufo.y)
            let groundSize = (detail == .silhouette ? 10.5 : 6.2) * (0.75 + 0.5 * ufo.beam)
            let topSize: CGFloat = 2.2
            let topRect = CityActorFootprints.orientedRectangle(
                center: center,
                heading: CGVector(dx: 1, dy: 0),
                length: topSize,
                width: topSize
            )
            let bottomRect = CityActorFootprints.orientedRectangle(
                center: center,
                heading: CGVector(dx: 1, dy: 0),
                length: groundSize,
                width: groundSize
            )
            let groundShadowEllipse = CGRect(
                x: IsoProjection.project(ufo.x, ufo.y, 0.02).x - 16,
                y: IsoProjection.project(ufo.x, ufo.y, 0.02).y - 4.5,
                width: 32,
                height: 9
            )
            let beamProjectedPoints = bottomRect.map { IsoProjection.project($0.x, $0.y, 0.04) } + topRect.map { IsoProjection.project($0.x, $0.y, ufo.altitude - 0.8) }
            let beamBounds = beamProjectedPoints.reduce(groundShadowEllipse) { $0.union(CGRect(origin: $1, size: .zero)) }
            let exclusionGroup = ufoMission.scanTarget.flatMap { target in
                scape.plots.first { plot in
                    let footprint = CGRect(x: plot.x, y: plot.y, width: plot.w, height: plot.d)
                    return footprint.contains(target)
                        && footprint.contains(CGPoint(x: ufo.x, y: ufo.y))
                }?.id
            }
            queue.enqueue(
                CityLiveItemDescriptor(
                    id: "ufo-beam",
                    layer: .world,
                    mode: .punch(exclusionGroup: exclusionGroup),
                    anchor: CityWorldAnchor(x: ufo.x, y: ufo.y, z: 0),
                    sortKey: IsoProjection.sortKey(x: ufo.x, y: ufo.y),
                    probeBounds: beamBounds
                )
            ) { [self] ctx in
                var context = ctx
                drawUFOBeam(context: &context, event: ufo, sample: sample, detail: detail)
            }
            
            // Row 16: UFO Hull (aerial layer, skip)
            queue.enqueue(
                CityLiveItemDescriptor(
                    id: "ufo-hull",
                    layer: .aerial,
                    mode: .skip,
                    anchor: CityWorldAnchor(x: ufo.x, y: ufo.y, z: ufo.altitude),
                        sortKey: IsoProjection.sortKey(x: ufo.x, y: ufo.y),
                    probeBounds: nil
                )
            ) { [self] ctx in
                var context = ctx
                drawUFOHull(context: &context, event: ufo, date: date, sample: sample, detail: detail)
            }
        }
        
        // Row 22: Golem posed masses. The retained base holds the whole
        // reclining body; the sky-side shoulder, its draped upper arm,
        // their moving joint cores, and the head assembly draw here per
        // frame so wake and breath animate with no stale baked body
        // underneath. Each posed mass is its own depth-sorted item:
        // intervening world geometry still interleaves and its per-frame
        // occluder in the field makes it occlude other live actors in
        // turn. The golem is one landmark, so every golem occluder —
        // baked or posed — shares the `titan` group and is excluded here:
        // a body cannot punch holes in itself. Neck and head keep their
        // own assembly draw so the neck never paints over the face; the
        // head's shadow follows the live pose.
        for (golemIndex, golemSolid) in golemSolids.enumerated()
        where golemSolid != golemPose.neck && golemSolid != golemPose.head {
            let golemProbe = golemSolid.facets.flatMap(\.projectedPoints).reduce(CGRect.null) {
                $0.union(CGRect(origin: $1, size: .zero))
            }
            queue.enqueue(
                CityLiveItemDescriptor(
                    id: "golem-\(golemIndex)",
                    layer: .world,
                    mode: .punch(exclusionGroup: "titan"),
                    anchor: CityWorldAnchor(
                        x: golemSolid.worldBounds.maxX,
                        y: golemSolid.worldBounds.maxY,
                        z: 0
                    ),
                    sortKey: golemSolid.sortKey,
                    probeBounds: golemProbe
                )
            ) { [self] ctx in
                var context = ctx
                // Masses that hang above the ground carry their ambient
                // patch with them, so the ground darkening tracks the
                // stirring shoulder instead of staying baked where the
                // mass came to rest.
                if golemSolid.baseZ > 0.001 {
                    drawTitanContactPatch(context: &context, solid: golemSolid, opacity: 0.05)
                }
                drawTitanSolid(
                    context: &context,
                    sample: sample,
                    geometry: golemPose,
                    solid: golemSolid
                )
            }
        }
        let titanHeadBounds = golemPose.head.facets.flatMap(\.projectedPoints).reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
        let titanNearSortKey = golemPose.head.worldBounds.maxX + golemPose.head.worldBounds.maxY
        queue.enqueue(
            CityLiveItemDescriptor(
                id: "titan-head",
                layer: .world,
                mode: .punch(exclusionGroup: "titan"),
                anchor: CityWorldAnchor(
                    x: golemPose.head.worldBounds.maxX,
                    y: golemPose.head.worldBounds.maxY,
                    z: 0
                ),
                sortKey: titanNearSortKey,
                probeBounds: titanHeadBounds
            )
        ) { [self] ctx in
            var context = ctx
            drawTitanHead(
                context: &context,
                sample: sample,
                date: date,
                geometry: golemPose,
                wake: wake,
                band: band
            )
        }
        
        // Rows 19-21: Balloon shadow, envelope, and birds
        let balloon = CityWhimsy.balloon(date: date, reduceMotion: reduceMotion, celebration: wake)
        let balloonGeometry = Self.balloonGeometry(model: balloon, bounds: bounds)
        
        // Row 20: Balloon shadow
        queue.enqueue(
            CityLiveItemDescriptor(
                id: "balloon-shadow",
                layer: .world,
                mode: .skip,
                anchor: CityWorldAnchor(x: balloonGeometry.x, y: balloonGeometry.y, z: 0),
                sortKey: IsoProjection.sortKey(x: balloonGeometry.x, y: balloonGeometry.y),
                probeBounds: nil
            )
        ) { [self] ctx in
            var context = ctx
            drawBalloonGroundShadow(context: &context, geometry: balloonGeometry, sample: sample, visibleRect: plan.visibleRect)
        }
        
        // Row 19: Balloon envelope
        queue.enqueue(
            CityLiveItemDescriptor(
                id: "balloon",
                layer: .aerial,
                mode: .skip,
                anchor: CityWorldAnchor(x: balloonGeometry.x, y: balloonGeometry.y, z: balloonGeometry.z),
                sortKey: IsoProjection.sortKey(x: balloonGeometry.x, y: balloonGeometry.y),
                probeBounds: nil
            )
        ) { [self] ctx in
            var context = ctx
            drawHotAirBalloon(context: &context, visibleRect: plan.visibleRect, date: date, sample: sample, lighting: lighting, band: band, celebration: wake)
        }
        
        // Row 21: Birds - per-bird extraction without calling drawSkyWhimsy
        let ink = nightified(CalmCityStyle.ink, sample: sample).opacity(0.90)
        for (birdIndex, bird) in CityWhimsy.birds(date: date, reduceMotion: reduceMotion).enumerated() {
            let wx = bounds.minX + (bird.x + 20) / 200 * bounds.width
            let wy = bounds.minY + (bird.y - 6) / 48 * bounds.height
            let point = IsoProjection.project(wx, wy, bird.z)
            guard plan.visibleRect.insetBy(dx: -2, dy: -2).contains(point) else { continue }
            queue.enqueue(
                CityLiveItemDescriptor(
                    id: "bird-\(birdIndex)",
                    layer: .aerial,
                    mode: .skip,
                    anchor: CityWorldAnchor(x: wx, y: wy, z: bird.z),
                    sortKey: IsoProjection.sortKey(x: wx, y: wy),
                    probeBounds: nil
                )
            ) { ctx in
                var context = ctx
                let point = IsoProjection.project(wx, wy, bird.z)
                let wing = CGFloat(0.42 + 0.22 * sin(bird.flapPhase))
                drawOutlinedVoxelBox(
                    context: &context,
                    at: point,
                    w: 0.9,
                    d: 0.46 + wing * 0.4,
                    h: 0.18,
                    z0: 0,
                    top: .white.opacity(0.68),
                    se: .white.opacity(0.48),
                    sw: .white.opacity(0.36),
                    ink: ink
                )
            }
        }
        
        // Draw the unified queue
        queue.draw(context: &context, field: field)
        
        
        // Unchanged overlay UI tail
        let titanRenderBounds = sleepingTitanGeometry().renderBounds
        let titanScreenOrigin = camera.apply(titanRenderBounds.origin)
        let titanLabelExclusion = CGRect(
            x: titanScreenOrigin.x,
            y: titanScreenOrigin.y,
            width: titanRenderBounds.width * camera.scale,
            height: titanRenderBounds.height * camera.scale
        ).insetBy(dx: -8, dy: -8)
        drawLabels(
            context: &context,
            overlayContext: &overlayContext,
            plots: plan.visiblePlots,
            scale: camera.scale,
            date: date,
            camera: camera,
            band: band,
            palette: AppTheme.graphite.palette,
            visibleRect: plan.visibleRect,
            exclusionRect: band == .province ? titanLabelExclusion : nil,
            hoveredPlotID: hoveredPlotID
        )
        drawHoverTooltip(context: &overlayContext, point: hoverPoint, plotID: hoveredPlotID, scape: scape, band: band, size: size)
        if let selectedPlotID, let selectedPlot = scape.plots.first(where: { $0.id == selectedPlotID }) {
            drawSelectionOutline(context: &context, plot: selectedPlot)
        }
        if let bubble, let plot = scape.plots.first(where: { $0.id == bubble.plotID }) {
            drawCitizenBubble(context: &overlayContext, plot: plot, citizenIndex: bubble.citizenIndex, text: bubble.text, shownAt: bubble.shownAt, date: date, camera: camera, size: size)
        }
        drawFreshnessOverlay(context: &overlayContext, size: size, state: refreshState, date: date)
    }

    /// Buildings gained between a transition's stages rise out of the pad in
    /// the live overlay while the retained base keeps the settled city. The
    /// geometry and colors mirror `drawBasePlot` exactly, so the animation's
    /// final frame matches the next settled base render pixel-for-pixel.
    private func drawConstruction(
        context: inout GraphicsContext,
        plot: CityPlot,
        transition: CityDirector.DensityTransition,
        date: Date,
        sample: CityPalette.Sample,
        lighting: CityLighting.Sample,
        band: ZoomBand
    ) {
        let raw = date.timeIntervalSince(transition.start) / CityDirector.densityTransitionDuration
        let progress = CGFloat(min(max(raw, 0), 1))
        func height(_ building: BuildingSpec, tiers visibleTiers: Int, of tierCount: Int) -> CGFloat {
            guard visibleTiers > 0 else { return 0 }
            let fraction: CGFloat = visibleTiers >= tierCount
                ? 1
                : building.tiers.indices.contains(visibleTiers - 1) ? building.tiers[visibleTiers - 1].f1 : 1
            return min(building.h, Self.maxBuildingWorldHeight) * fraction
        }
        // Rising shells keep the settled plot's array order: the base layer
        // draws revealed buildings in the same sequence, so construction
        // never disagrees with the painter order the plot settles into.
        var rising: [(building: BuildingSpec, from: CGFloat, to: CGFloat)] = []
        for building in plot.buildings where CityDensity.isRevealed(building.revealStage, at: transition.toStage) {
            let tierCount = max(1, building.tiers.count)
            let fromTiers = CityDensity.isRevealed(building.revealStage, at: transition.fromStage)
                ? CityDensity.visibleTierCount(revealStage: building.revealStage, tierCount: tierCount, stage: transition.fromStage)
                : 0
            let toTiers = CityDensity.visibleTierCount(revealStage: building.revealStage, tierCount: tierCount, stage: transition.toStage)
            guard toTiers > fromTiers else { continue }
            rising.append((
                building,
                height(building, tiers: fromTiers, of: tierCount),
                height(building, tiers: toTiers, of: tierCount)
            ))
        }
        if ProcessInfo.processInfo.environment["CITY_CONSTRUCT_DEBUG"] != nil {
            FileHandle.standardError.write("construct-debug plot=\(plot.id) buildings=\(plot.buildings.count) rising=\(rising.count) from=\(transition.fromStage) to=\(transition.toStage)\n".data(using: .utf8)!)
        }
        guard !rising.isEmpty else { return }
        if band != .province {
            for item in rising {
                drawConstructionTape(context: &context, plot: plot, building: item.building, sample: sample, band: band)
            }
            drawConstructionCrew(context: &context, plot: plot, rising: rising, layer: .behindShells, date: date, sample: sample)
        }
        for (slot, item) in rising.enumerated() {
            // Staggered rise: earlier slots break ground first, everyone
            // lands together by the end of the transition window.
            let delay = rising.count > 1 ? 0.4 * CGFloat(slot) / CGFloat(rising.count - 1) : 0
            let local = min(max((progress - delay) / max(0.001, 1 - delay), 0), 1)
            let eased = local * local * (3 - 2 * local)
            let lift = reduceMotion ? item.to : item.from + (item.to - item.from) * eased
            guard lift > 0.01 else { continue }
            let base = CalmCityStyle.pavilionBase(facade: item.building.facade)
            let faces = CityPalette.faceColors(base: base, sample: sample, lighting: lighting, nightAttenuation: 0.92)
            let wrapBase = Self.mixed(CalmCityStyle.paper, CalmCityStyle.marigold, 0.22)
            let wrapFaces = CityPalette.faceColors(base: wrapBase, sample: sample, lighting: lighting, nightAttenuation: 0.92)
            let drawShell: (inout GraphicsContext) -> Void = { ctx in
                outlinedVoxelBox(
                    context: &ctx,
                    x: plot.x + item.building.ox,
                    y: plot.y + item.building.oy,
                    w: item.building.bw,
                    d: item.building.bd,
                    h: lift,
                    top: faces.top.color,
                    se: faces.right.color,
                    sw: faces.left.color,
                    outlineWidth: 0.8
                )
                // Kraft wrap band on the rising shell: unfinished towers wear
                // a paper cap until their final tier lands.
                if lift > 1.2 {
                    outlinedVoxelBox(
                        context: &ctx,
                        x: plot.x + item.building.ox - 0.05,
                        y: plot.y + item.building.oy - 0.05,
                        w: item.building.bw + 0.1,
                        d: item.building.bd + 0.1,
                        h: lift + 0.1,
                        z0: lift - min(0.85, lift - 0.2),
                        top: wrapFaces.top.color,
                        se: wrapFaces.right.color,
                        sw: wrapFaces.left.color,
                        outlineWidth: 0.5
                    )
                }
            }
            // Shells rise behind settled foreground towers: punch the
            // occluder silhouettes out of the shell layer so depth holds.
            let shellBounds = constructionScreenBounds(
                x: plot.x + item.building.ox,
                y: plot.y + item.building.oy,
                w: item.building.bw,
                d: item.building.bd,
                z0: 0,
                z1: lift + 0.3
            )
            if let mask = occlusionField.punchMask(
                spriteBounds: shellBounds,
                backSortKey: plot.x + item.building.ox + plot.y + item.building.oy
            ) {
                context.drawLayer { layer in
                    if reduceMotion {
                        // Reduced motion swaps the vertical rise for a fade.
                        layer.opacity = Double(eased)
                    }
                    drawShell(&layer)
                    layer.blendMode = .destinationOut
                    layer.fill(mask, with: .color(.black))
                    // Widened punch: settled towers paint their ink edge half a
                    // stroke outside their fill silhouette, and the shell's ink
                    // survives in that sliver without the extra margin.
                    layer.stroke(mask, with: .color(.black), lineWidth: 1.0)
                }
            } else {
                var layer = context
                if reduceMotion {
                    // Reduced motion swaps the vertical rise for a quiet fade-in.
                    layer.opacity = Double(eased)
                }
                drawShell(&layer)
            }
        }
        if band != .province {
            drawConstructionCrew(context: &context, plot: plot, rising: rising, layer: .inFrontOfShells, date: date, sample: sample)
            drawConstructionSiteProps(context: &context, plot: plot, rising: rising, sample: sample)
        }
    }

    private func drawConstructionTape(
        context: inout GraphicsContext,
        plot: CityPlot,
        building: BuildingSpec,
        sample: CityPalette.Sample,
        band: ZoomBand
    ) {
        // City band halves the stripe count and thickens strokes so the
        // tape survives the smaller on-screen footprint.
        let detailScale: CGFloat = band == .street ? 1 : 1.7
        let bx = plot.x + building.ox
        let by = plot.y + building.oy
        let geometry = CityConstructionTapeGeometry(
            x: bx,
            y: by,
            width: building.bw,
            depth: building.bd,
            piecesPerEdge: band == .street ? 6 : 3
        )
        let ink = nightified(CalmCityStyle.ink, sample: sample).opacity(0.92)
        let yellow = nightified(CalmCityStyle.marigold, sample: sample)
        // Traffic cones guard the taped corners: stacked coral/paper bands
        // read as striped cones from street zoom down to city.
        let coneCoral = nightified(CalmCityStyle.coral, sample: sample)
        let coneStripe = nightified(CalmCityStyle.paper, sample: sample, attenuation: 0.05)
        let drawBody: (inout GraphicsContext) -> Void = { ctx in
            for post in geometry.posts {
                let conePoint = IsoProjection.project(post.point.x, post.point.y, 0.02)
                drawOutlinedVoxelBox(
                    context: &ctx, at: conePoint, w: 0.34, d: 0.34, h: 0.10, z0: 0,
                    top: coneCoral, se: coneCoral.opacity(0.75), sw: coneCoral.opacity(0.58), ink: Self.outlineInk
                )
                drawOutlinedVoxelBox(
                    context: &ctx, at: conePoint, w: 0.22, d: 0.22, h: 0.09, z0: 0.10,
                    top: coneStripe, se: coneStripe.opacity(0.78), sw: coneStripe.opacity(0.6), ink: Self.outlineInk
                )
                drawOutlinedVoxelBox(
                    context: &ctx, at: conePoint, w: 0.12, d: 0.12, h: 0.11, z0: 0.19,
                    top: coneCoral, se: coneCoral.opacity(0.78), sw: coneCoral.opacity(0.6), ink: Self.outlineInk
                )
            }
            for post in geometry.posts {
                stroke(
                    context: &ctx,
                    [
                        IsoProjection.project(post.point.x, post.point.y, post.baseZ),
                        IsoProjection.project(post.point.x, post.point.y, post.topZ),
                    ],
                    color: ink,
                    width: 1.15 * detailScale
                )
            }
            for segment in geometry.tapeSegments {
                stroke(
                    context: &ctx,
                    [
                        IsoProjection.project(segment.start.x, segment.start.y, segment.startZ),
                        IsoProjection.project(segment.end.x, segment.end.y, segment.endZ),
                    ],
                    color: segment.stripe == .yellow ? yellow.opacity(0.98) : ink,
                    width: 1.7 * detailScale
                )
            }
            // Pennant flag on each post top: the flutter sells an active site.
            for (index, post) in geometry.posts.enumerated() {
                let top = IsoProjection.project(post.point.x, post.point.y, post.topZ)
                let flag = nightified(index.isMultiple(of: 2) ? CalmCityStyle.coral : CalmCityStyle.marigold, sample: sample)
                fill(
                    context: &ctx,
                    [
                        CGPoint(x: top.x, y: top.y - 0.5),
                        CGPoint(x: top.x, y: top.y + 0.35),
                        CGPoint(x: top.x + 1.5, y: top.y - 0.05),
                    ],
                    color: flag.opacity(0.95)
                )
            }
        }
        // Punch settled foreground towers out of the tape layer so the ring
        // tucks behind neighbors instead of painting over their faces.
        let pad: CGFloat = 1.2
        let bounds = constructionScreenBounds(x: bx - pad, y: by - pad, w: building.bw + 2 * pad, d: building.bd + 2 * pad, z0: 0, z1: 2.3)
        if let mask = occlusionField.punchMask(spriteBounds: bounds, backSortKey: bx + by - 2 * pad) {
            context.drawLayer { layer in
                drawBody(&layer)
                layer.blendMode = .destinationOut
                layer.fill(mask, with: .color(.black))
                layer.stroke(mask, with: .color(.black), lineWidth: 1.0)
            }
        } else {
            drawBody(&context)
        }
    }


    /// Screen-space bounds of a world rect spanning heights z0...z1, used
    /// to test construction dressing against the occluder silhouettes.
    private func constructionScreenBounds(x: CGFloat, y: CGFloat, w: CGFloat, d: CGFloat, z0: CGFloat, z1: CGFloat) -> CGRect {
        var rect: CGRect?
        for (cornerX, cornerY) in [(x, y), (x + w, y), (x, y + d), (x + w, y + d)] {
            for z in [z0, z1] {
                let point = IsoProjection.project(cornerX, cornerY, z)
                let pointRect = CGRect(x: point.x, y: point.y, width: 0, height: 0)
                rect = rect?.union(pointRect) ?? pointRect
            }
        }
        return rect ?? .zero
    }

    /// Which side of the rising shells a crew member draws on, so workers
    /// pass behind the shell on the far lap and in front on the near lap.
    private enum CrewLayer {
        case behindShells
        case inFrontOfShells
    }

    /// Hard-hat crew working the rising shells: a walker laps the tape line
    /// while a second hammers the south face with dust puffs. All motion is
    /// deterministic from `date` alone.
    private func drawConstructionCrew(
        context: inout GraphicsContext,
        plot: CityPlot,
        rising: [(building: BuildingSpec, from: CGFloat, to: CGFloat)],
        layer: CrewLayer,
        date: Date,
        sample: CityPalette.Sample
    ) {
        let time = reduceMotion ? 0 : date.timeIntervalSinceReferenceDate
        var workerSlots = 0
        for (buildingIndex, item) in rising.enumerated() where workerSlots < 3 {
            let building = item.building
            let bx = plot.x + building.ox
            let by = plot.y + building.oy
            // Walkers lap the tape line, which stands pad 1.2 off the walls.
            let pad: CGFloat = 1.2
            let perimeter = 2 * (building.bw + 2 * pad) + 2 * (building.bd + 2 * pad)
            guard perimeter > 0.01 else { continue }
            let lapDistance = CGFloat((time * 0.9 + Double(buildingIndex) * 2.3).truncatingRemainder(dividingBy: Double(perimeter)))
            let walker = perimeterPoint(
                x: bx - pad,
                y: by - pad,
                w: building.bw + 2 * pad,
                d: building.bd + 2 * pad,
                distance: lapDistance
            )
            let walkerInFront = walker.y > by + building.bd / 2
            if walkerInFront == (layer == .inFrontOfShells) {
                let wp = IsoProjection.project(walker.x, walker.y, 0.05)
                drawWorkerFigure(
                    context: &context,
                    worldX: walker.x,
                    worldY: walker.y,
                    at: wp,
                    heading: walker.heading,
                    date: date,
                    sample: sample
                )
            }
            workerSlots += 1
            // Hammerer on the first rising shell: bouncing strikes at the
            // south face plus a cycling dust puff at the strike point.
            if buildingIndex == 0, workerSlots < 3, layer == .inFrontOfShells {
                let hx = bx + building.bw / 2
                let hy = by + building.bd + 0.62
                let strike = reduceMotion ? 0 : abs(sin(time * 7.0)) * 0.14
                let hp = IsoProjection.project(hx, hy, 0.05 + strike)
                drawWorkerFigure(
                    context: &context,
                    worldX: hx,
                    worldY: hy,
                    at: hp,
                    heading: CGSize(width: 0, height: -1),
                    date: date,
                    sample: sample
                )
                workerSlots += 1
                if !reduceMotion {
                    let age = CGFloat((time + 0.35).truncatingRemainder(dividingBy: 0.9) / 0.9)
                    let puffCenter = IsoProjection.project(hx, by + building.bd - 0.05, 0.25)
                    let radius = 0.25 + age * 0.85
                    let puffRect = CGRect(x: puffCenter.x - radius, y: puffCenter.y - radius * 0.72, width: radius * 2, height: radius * 1.44)
                    let puffColor = nightified(CalmCityStyle.paper, sample: sample, attenuation: 0.18).opacity(Double(1 - age) * 0.4)
                    if let mask = occlusionField.punchMask(spriteBounds: puffRect, backSortKey: hx + by + building.bd) {
                        context.drawLayer { layer in
                            layer.fill(Path(ellipseIn: puffRect), with: .color(puffColor))
                            layer.blendMode = .destinationOut
                            layer.fill(mask, with: .color(.black))
                            layer.stroke(mask, with: .color(.black), lineWidth: 1.0)
                        }
                    } else {
                        context.fill(Path(ellipseIn: puffRect), with: .color(puffColor))
                    }
                }
            }
        }
    }

    /// Maps a distance along a rectangle's perimeter to a world point and
    /// travel heading; used by the lapping construction walker.
    private func perimeterPoint(x: CGFloat, y: CGFloat, w: CGFloat, d: CGFloat, distance: CGFloat) -> (x: CGFloat, y: CGFloat, heading: CGSize) {
        let perimeter = 2 * w + 2 * d
        var s = distance.truncatingRemainder(dividingBy: perimeter)
        if s < 0 { s += perimeter }
        if s < w { return (x + s, y, CGSize(width: 1, height: 0)) }
        s -= w
        if s < d { return (x + w, y + s, CGSize(width: 0, height: 1)) }
        s -= d
        if s < w { return (x + w - s, y + d, CGSize(width: -1, height: 0)) }
        s -= w
        return (x, y + d - s, CGSize(width: 0, height: -1))
    }

    /// Staged site props: a materials pallet with crates beside the first
    /// rising shell, kept to one stack per plot so busy sites stay readable.
    private func drawConstructionSiteProps(
        context: inout GraphicsContext,
        plot: CityPlot,
        rising: [(building: BuildingSpec, from: CGFloat, to: CGFloat)],
        sample: CityPalette.Sample
    ) {
        guard let first = rising.first else { return }
        let b = first.building
        let px = plot.x + b.ox + b.bw + 0.95
        let py = plot.y + b.oy + b.bd * 0.35
        let wood = nightified(CalmCityStyle.road, sample: sample, attenuation: 0.05)
        let crate = nightified(CalmCityStyle.paper, sample: sample, attenuation: 0.08)
        let ink = Self.outlineInk
        let drawStack: (inout GraphicsContext) -> Void = { ctx in
            drawOutlinedVoxelBox(
                context: &ctx, at: IsoProjection.project(px, py, 0.02), w: 0.9, d: 0.7, h: 0.09, z0: 0,
                top: wood, se: wood.opacity(0.75), sw: wood.opacity(0.58), ink: ink
            )
            drawOutlinedVoxelBox(
                context: &ctx, at: IsoProjection.project(px, py, 0.02), w: 0.5, d: 0.42, h: 0.34, z0: 0.09,
                top: crate, se: crate.opacity(0.78), sw: crate.opacity(0.6), ink: ink
            )
            drawOutlinedVoxelBox(
                context: &ctx, at: IsoProjection.project(px + 0.1, py - 0.06, 0.02), w: 0.34, d: 0.3, h: 0.26, z0: 0.43,
                top: crate.opacity(0.95), se: crate.opacity(0.7), sw: crate.opacity(0.55), ink: ink
            )
        }
        let bounds = constructionScreenBounds(x: px - 0.55, y: py - 0.45, w: 1.15, d: 0.95, z0: 0, z1: 0.8)
        if let mask = occlusionField.punchMask(spriteBounds: bounds, backSortKey: px + py) {
            context.drawLayer { layer in
                drawStack(&layer)
                layer.blendMode = .destinationOut
                layer.fill(mask, with: .color(.black))
                layer.stroke(mask, with: .color(.black), lineWidth: 1.0)
            }
        } else {
            drawStack(&context)
        }
    }

    /// Occlusion-aware wrapper for the crew figure, mirroring the citizen
    /// blob's behavior behind settled buildings.
    private func drawWorkerFigure(
        context: inout GraphicsContext,
        worldX: CGFloat,
        worldY: CGFloat,
        at point: CGPoint,
        heading: CGSize,
        date: Date,
        sample: CityPalette.Sample
    ) {
        guard let mask = occlusionField.punchMask(
            worldX: worldX,
            worldY: worldY,
            spriteBounds: Self.humanSpriteBounds(at: point)
        ) else {
            drawWorkerBlob(context: &context, at: point, heading: heading, date: date, sample: sample)
            return
        }
        context.drawLayer { layer in
            drawWorkerBlob(context: &layer, at: point, heading: heading, date: date, sample: sample)
            layer.blendMode = .destinationOut
            layer.fill(mask, with: .color(.black))
        }
    }

    /// Blob figure in the construction uniform: hi-vis vest with a
    /// reflective chest band and a hard hat with a brim ring.
    private func drawWorkerBlob(
        context: inout GraphicsContext,
        at point: CGPoint,
        heading: CGSize,
        date: Date,
        sample: CityPalette.Sample
    ) {
        let blink = !reduceMotion
            && (date.timeIntervalSinceReferenceDate + 0.6)
                .truncatingRemainder(dividingBy: 3.1) < 0.12
        let heightScale: CGFloat = blink ? 0.90 : 1
        let vest = nightified(CalmCityStyle.marigold, sample: sample)
        let hat = nightified(CalmCityStyle.marigold, sample: sample, attenuation: 0.10)
        let ink = Self.outlineInk
        let skin = Color(red: 0.99, green: 0.80, blue: 0.62)
        var figureContext = context
        if CityRenderPolicies.shouldMirrorBlob(heading: heading) {
            figureContext.concatenate(CGAffineTransform(translationX: point.x, y: 0).scaledBy(x: -1, y: 1).translatedBy(x: -point.x, y: 0))
        }
        figureContext.fill(
            Path(ellipseIn: CGRect(x: point.x - 0.27, y: point.y - 0.10, width: 0.54, height: 0.20)),
            with: .color(.black.opacity(0.30))
        )
        let bodyHeight = Self.humanWorldHeight * 0.625 * heightScale
        let headHeight = Self.humanWorldHeight * 0.375 * heightScale
        drawOutlinedVoxelBox(
            context: &figureContext, at: point, w: 0.28, d: 0.24, h: bodyHeight, z0: 0,
            top: vest, se: vest.opacity(0.75), sw: vest.opacity(0.58), ink: ink
        )
        drawOutlinedVoxelBox(
            context: &figureContext, at: point, w: 0.30, d: 0.26, h: 0.07, z0: bodyHeight * 0.55,
            top: .white.opacity(0.85), se: .white.opacity(0.65), sw: .white.opacity(0.5), ink: ink
        )
        drawOutlinedVoxelBox(
            context: &figureContext, at: point, w: 0.19, d: 0.19, h: headHeight, z0: bodyHeight,
            top: hat, se: skin.opacity(0.86), sw: skin.opacity(0.72), ink: ink
        )
        drawOutlinedVoxelBox(
            context: &figureContext, at: point, w: 0.27, d: 0.27, h: 0.055, z0: bodyHeight + headHeight,
            top: hat, se: hat.opacity(0.75), sw: hat.opacity(0.58), ink: ink
        )
    }

    private func drawBasePlot(
        context: inout GraphicsContext,
        plot: CityPlot,
        sample: CityPalette.Sample,
        lighting: CityLighting.Sample,
        band: ZoomBand
    ) {
        box(
            context: &context,
            x: plot.x,
            y: plot.y,
            w: plot.w,
            d: plot.d,
            h: 0.7,
            top: nightified(CalmCityStyle.paper, sample: sample),
            se: nightified(CalmCityStyle.road, sample: sample),
            sw: nightified(CalmCityStyle.road, sample: sample, attenuation: 1.06)
        )
        // Same pavilion set at every zoom band: culling to the tallest at
        // province made buildings visibly pop out of existence on zoom-out.
        // Density stages reveal extras beyond the baseline silhouette.
        let stage = densityStage(for: plot)
        let pavilions = visiblePavilions(for: plot)
        let chimneyHost = pavilions.max(by: { $0.h < $1.h })
        drawBuildingLightPools(
            context: &context,
            pavilions: pavilions,
            plot: plot,
            lighting: lighting,
            sample: sample,
            band: band
        )
        let shadowCasterCount = CityRenderPolicies.shadowCasterCount(
            buildingCount: pavilions.count,
            band: band
        )
        for building in pavilions.prefix(shadowCasterCount) {
            let tierCount = max(1, building.tiers.count)
            let visibleTiers = CityDensity.visibleTierCount(
                revealStage: building.revealStage,
                tierCount: tierCount,
                stage: stage
            )
            let fraction: CGFloat = visibleTiers >= tierCount
                ? 1
                : building.tiers.indices.contains(visibleTiers - 1) ? building.tiers[visibleTiers - 1].f1 : 1
            if let shadow = Self.realtimeShadowQuad(
                x: plot.x + building.ox,
                y: plot.y + building.oy,
                bw: building.bw,
                bd: building.bd,
                h: min(building.h, Self.maxBuildingWorldHeight) * fraction,
                lighting: lighting
            ) {
                fill(context: &context, shadow, color: CalmCityStyle.ink.color.opacity(lighting.shadowOpacity))
            }
        }
        // Painter-order the plot's contents together: trees drawn after every
        // pavilion floated over roofs whenever a tree sat deeper than a
        // building. Larger key = nearer the camera = drawn later.
        var order: [(key: CGFloat, index: Int, isTree: Bool)] = pavilions.enumerated().map { index, building in
            (IsoProjection.sortKey(x: plot.x + building.ox + building.bw, y: plot.y + building.oy + building.bd), index, false)
        }
        let trees = plot.trees.filter { CityDensity.isRevealed($0.revealStage, at: stage) }
        order += trees.enumerated().map { index, tree in
            (IsoProjection.sortKey(x: tree.x, y: tree.y), index, true)
        }
        for item in order.sorted(by: { $0.key < $1.key }) {
            if item.isTree {
                drawTree(context: &context, tree: trees[item.index], sample: sample)
                continue
            }
            let building = pavilions[item.index]
            let state = CalmCityStyle.buildingState(for: plot)
            let facade = state == .unknown
                ? Self.mixed(building.facade, RGB(r: 151, g: 158, b: 164), 0.88)
                : building.facade
            let base = CalmCityStyle.pavilionBase(facade: facade)
            var faces = CityPalette.faceColors(base: base, sample: sample, lighting: lighting, nightAttenuation: 0.92)
            let jobPressure = state == .allocated ? CityWindows.runningJobPressure(for: plot.node) : 0
            let occupancy = CityWindows.occupancyFraction(jobPressure: jobPressure, t: sample.t)
            faces.left = CityPalette.localLightLift(faces.left, lighting: lighting, utilization: occupancy)
            faces.right = CityPalette.localLightLift(faces.right, lighting: lighting, utilization: occupancy)
            let tierCount = max(1, building.tiers.count)
            let visibleTiers = CityDensity.visibleTierCount(revealStage: building.revealStage, tierCount: tierCount, stage: stage)
            let complete = visibleTiers >= tierCount
            let heightFraction: CGFloat = complete
                ? 1
                : building.tiers.indices.contains(visibleTiers - 1) ? building.tiers[visibleTiers - 1].f1 : 1
            let height = min(building.h, Self.maxBuildingWorldHeight) * heightFraction
            let sx = plot.x + building.ox, sy = plot.y + building.oy
            outlinedVoxelBox(
                context: &context,
                x: plot.x + building.ox,
                y: plot.y + building.oy,
                w: building.bw,
                d: building.bd,
                h: height,
                top: faces.top.color,
                se: faces.right.color,
                sw: faces.left.color,
                outlineWidth: 0.8
            )
            // Toy-block lid: a slightly overhanging cream-washed roof slab
            // gives every pavilion the "capped brick" silhouette instead of a
            // bare extruded prism. Rising density buildings stay lidless until
            // their final tier lands, so they read as under construction.
            if complete {
                let lidBase = Self.mixed(base, CalmCityStyle.paper, 0.30)
                let lidFaces = CityPalette.faceColors(base: lidBase, sample: sample, lighting: lighting, nightAttenuation: 0.92)
                let overhang: CGFloat = 0.22
                outlinedVoxelBox(
                    context: &context,
                    x: sx - overhang,
                    y: sy - overhang,
                    w: building.bw + overhang * 2,
                    d: building.bd + overhang * 2,
                    h: height + 0.5,
                    z0: height,
                    top: lidFaces.top.color,
                    se: lidFaces.right.color,
                    sw: lidFaces.left.color,
                    outlineWidth: 0.8
                )
            } else if height > 0.6 {
                // Unfinished pavilion: kraft paper wrap band under the open
                // top plus scaffold poles along the front face, so settled
                // mid-rise shells read as active construction sites rather
                // than lidless boxes.
                let wrapBase = Self.mixed(CalmCityStyle.paper, CalmCityStyle.marigold, 0.22)
                let wrapFaces = CityPalette.faceColors(base: wrapBase, sample: sample, lighting: lighting, nightAttenuation: 0.92)
                outlinedVoxelBox(
                    context: &context,
                    x: sx - 0.05,
                    y: sy - 0.05,
                    w: building.bw + 0.1,
                    d: building.bd + 0.1,
                    h: height + 0.1,
                    z0: height - min(0.85, height - 0.2),
                    top: wrapFaces.top.color,
                    se: wrapFaces.right.color,
                    sw: wrapFaces.left.color,
                    outlineWidth: 0.5
                )
                let poleCount = max(2, Int(building.bw / 1.9))
                let woodTop = nightColor(150, 112, 70, sample: sample)
                let woodSe = nightColor(118, 86, 52, sample: sample)
                let woodSw = nightColor(100, 72, 44, sample: sample)
                for poleIndex in 0..<poleCount {
                    let px = sx + 0.45 + CGFloat(poleIndex) * (building.bw - 0.9) / CGFloat(max(1, poleCount - 1))
                    box(
                        context: &context,
                        x: px,
                        y: sy + building.bd + 0.18,
                        w: 0.09,
                        d: 0.09,
                        h: height + 0.5,
                        top: woodTop,
                        se: woodSe,
                        sw: woodSw
                    )
                }
            }
            // Brick chimney on the plot's tallest pavilion: anchors the live
            // smoke puffs. Geometry-only (plot-id hash), so the retained base
            // stays byte-identical when jobs change.
            if complete, building == chimneyHost,
               UInt(bitPattern: Self.byteHash("\(plot.id)-smokes")) % 2 == 0 {
                let brick = Self.mixed(CalmCityStyle.coral, base, 0.35)
                let brickFaces = CityPalette.faceColors(base: brick, sample: sample, lighting: lighting, nightAttenuation: 0.92)
                outlinedVoxelBox(
                    context: &context,
                    x: sx + building.bw * 0.28 - 0.35,
                    y: sy + building.bd * 0.30 - 0.35,
                    w: 0.7,
                    d: 0.7,
                    h: height + 1.35,
                    z0: height + 0.4,
                    top: brickFaces.top.color,
                    se: brickFaces.right.color,
                    sw: brickFaces.left.color,
                    outlineWidth: 0.8
                )
            }
            // Roof clutter: a hashed AC unit (and sometimes a slim vent) on
            // wider roofs breaks up the empty lid slabs. Geometry-only.
            let clutterHash = UInt(bitPattern: Self.byteHash("\(plot.id)-roof-\(building.ox)-\(building.oy)"))
            if complete, building.bw > 2.4, clutterHash % 4 != 0 {
                let grey = Self.mixed(CalmCityStyle.ink, CalmCityStyle.paper, 0.72)
                let greyFaces = CityPalette.faceColors(base: grey, sample: sample, lighting: lighting, nightAttenuation: 0.92)
                let ux = sx + 0.5 + CGFloat(clutterHash % 61) / 61 * max(0.1, building.bw - 1.8)
                let uy = sy + 0.5 + CGFloat((clutterHash >> 8) % 61) / 61 * max(0.1, building.bd - 1.8)
                outlinedVoxelBox(
                    context: &context,
                    x: ux, y: uy, w: 0.85, d: 0.85,
                    h: height + 1.05, z0: height + 0.5,
                    top: greyFaces.top.color, se: greyFaces.right.color, sw: greyFaces.left.color,
                    outlineWidth: 0.55
                )
                if clutterHash % 3 == 0 {
                    outlinedVoxelBox(
                        context: &context,
                        x: ux + 1.1, y: uy + 0.15, w: 0.4, d: 0.4,
                        h: height + 1.45, z0: height + 0.5,
                        top: greyFaces.top.color, se: greyFaces.right.color, sw: greyFaces.left.color,
                        outlineWidth: 0.55
                    )
                }
            }
            if complete {
                drawPavilionWindows(context: &context, plot: plot, building: building, height: height, sample: sample)
                drawBuildingOperation(context: &context, plot: plot, building: building, height: height, sample: sample)
            }
        }
        if band != .province {
            drawFlowerDots(context: &context, plot: plot, sample: sample)
            drawCornerPlanters(context: &context, plot: plot, sample: sample, lighting: lighting)
        }
    }

    /// Operational state is part of the architecture, painted with its host
    /// building so nearer buildings and trees naturally occlude it.
    private func drawBuildingOperation(
        context: inout GraphicsContext,
        plot: CityPlot,
        building: BuildingSpec,
        height: CGFloat,
        sample: CityPalette.Sample
    ) {
        let state = CalmCityStyle.buildingState(for: plot)
        let x = plot.x + building.ox, y = plot.y + building.oy
        let w = building.bw, d = building.bd
        let frontY = y + d + 0.06
        let ink = nightified(CalmCityStyle.ink, sample: sample, attenuation: 0.55)
        let trim = nightified(CalmCityStyle.paper, sample: sample, attenuation: 0.55)
        let steel = nightified(RGB(r: 113, g: 132, b: 141), sample: sample, attenuation: 0.6)
        let amber = nightified(CalmCityStyle.marigold, sample: sample, attenuation: 0.45)
        func facade(_ side: Bool, _ a: CGFloat, _ b: CGFloat, _ bottom: CGFloat, _ top: CGFloat) -> [CGPoint] {
            if side {
                return [
                    IsoProjection.project(x + w + 0.06, y + d * a, bottom),
                    IsoProjection.project(x + w + 0.06, y + d * b, bottom),
                    IsoProjection.project(x + w + 0.06, y + d * b, top),
                    IsoProjection.project(x + w + 0.06, y + d * a, top),
                ]
            }
            return [
                IsoProjection.project(x + w * a, frontY, bottom),
                IsoProjection.project(x + w * b, frontY, bottom),
                IsoProjection.project(x + w * b, frontY, top),
                IsoProjection.project(x + w * a, frontY, top),
            ]
        }
        let doorHeight = min(3.0, height * 0.36)
        let door = facade(false, 0.32, 0.68, 0.72, doorHeight)

        switch state {
        case .allocated, .free:
            // Broad workshop glazing reads at province scale; a quiet building
            // retains its intact glass and open entrance rather than looking ruined.
            for side in [false, true] {
                for row in 0..<2 {
                    let bottom = height * (0.40 + CGFloat(row) * 0.26)
                    let windows = facade(side, 0.14, 0.86, bottom, bottom + height * 0.14)
                    fill(context: &context, windows, color: ink)
                    let glass = state == .allocated
                        ? CalmCityStyle.paper.color.opacity(0.88 + 0.1 * sample.night)
                        : nightified(CalmCityStyle.water, sample: sample, attenuation: 0.8).opacity(0.65)
                    fill(context: &context, facade(side, 0.17, 0.83, bottom + 0.13, bottom + height * 0.14 - 0.13), color: glass)
                    for column in 1..<4 {
                        let fraction = 0.14 + CGFloat(column) * 0.18
                        let mullion = side
                            ? [IsoProjection.project(x + w + 0.08, y + d * fraction, bottom), IsoProjection.project(x + w + 0.08, y + d * fraction, bottom + height * 0.14)]
                            : [IsoProjection.project(x + w * fraction, frontY + 0.02, bottom), IsoProjection.project(x + w * fraction, frontY + 0.02, bottom + height * 0.14)]
                        stroke(context: &context, mullion, color: ink, width: 0.8)
                    }
                }
            }
            fill(context: &context, door, color: ink)
            stroke(context: &context, door + [door[0]], color: trim, width: 1.2)
            if state == .free {
                // Two folded-back loading doors, leaving an unobstructed opening.
                for edge: CGFloat in [0.32, 0.68] {
                    let outward: CGFloat = edge < 0.5 ? -0.10 : 0.10
                    fill(context: &context, [
                        IsoProjection.project(x + w * edge, frontY, 0.72),
                        IsoProjection.project(x + w * (edge + outward), frontY + 0.55, 0.72),
                        IsoProjection.project(x + w * (edge + outward), frontY + 0.55, doorHeight),
                        IsoProjection.project(x + w * edge, frontY, doorHeight),
                    ], color: trim)
                }
            } else {
                fill(context: &context, facade(false, 0.36, 0.64, 0.82, doorHeight - 0.15), color: CalmCityStyle.marigold.color.opacity(0.9))
                // Raised rooftop extractors give operating buildings a distinct
                // industrial silhouette even when individual windows are subpixel.
                for vent in 0..<3 {
                    let vx = x + w * (0.20 + CGFloat(vent) * 0.22)
                    outlinedVoxelBox(
                        context: &context, x: vx, y: y + d * 0.50,
                        w: w * 0.13, d: d * 0.22, h: height + 1.35, z0: height + 0.5,
                        top: trim, se: steel, sw: ink, outlineWidth: 0.7
                    )
                }
            }
        case .drained:
            // A repair site around an intact shell: real scaffold depth,
            // boarded access, working decks, and only a partial safety wrap.
            let timber = nightified(RGB(r: 181, g: 146, b: 98), sample: sample, attenuation: 0.58)
            let timberEdge = nightified(RGB(r: 116, g: 91, b: 66), sample: sample, attenuation: 0.58)
            let tube = nightified(RGB(r: 159, g: 174, b: 170), sample: sample, attenuation: 0.48)
            let net = nightified(RGB(r: 68, g: 115, b: 107), sample: sample, attenuation: 0.48)
            let outer: CGFloat = 0.95
            let levels = min(4, max(2, Int(height / 3.5)))
            let deckTop = height - 0.35
            func sitePoint(_ across: CGFloat, _ depth: CGFloat, _ z: CGFloat) -> CGPoint {
                IsoProjection.project(x + w * across, frontY + depth, z)
            }

            fill(context: &context, facade(false, 0.18, 0.82, 0.75, height * 0.61), color: ink)
            fill(context: &context, facade(false, 0.21, 0.79, 0.78, height * 0.59), color: steel)
            for slat in 1..<6 {
                let z = 0.8 + CGFloat(slat) * (height * 0.59 - 0.8) / 6
                stroke(context: &context, [sitePoint(0.21, 0.02, z), sitePoint(0.79, 0.02, z)], color: ink.opacity(0.6), width: 0.55)
            }
            // Individual plywood sheets close a side opening without making
            // the intact shell look shattered or abandoned.
            fill(context: &context, facade(true, 0.26, 0.74, height * 0.34, height * 0.61), color: ink)
            fill(context: &context, facade(true, 0.29, 0.71, height * 0.35, height * 0.60), color: timber)
            for joint: CGFloat in [0.43, 0.57] {
                stroke(context: &context, [
                    IsoProjection.project(x + w + 0.09, y + d * joint, height * 0.35),
                    IsoProjection.project(x + w + 0.09, y + d * joint, height * 0.60),
                ], color: timberEdge, width: 0.55)
            }

            // Stacked roof timbers have gaps and a cross-laid upper layer;
            // a solid green rectangle here reads as a solar panel, not supplies.
            for sleeper in 0..<2 {
                outlinedVoxelBox(
                    context: &context, x: x + w * (0.17 + CGFloat(sleeper) * 0.30), y: y + d * 0.23,
                    w: w * 0.07, d: d * 0.34, h: height + 0.72, z0: height + 0.52,
                    top: timber, se: timberEdge, sw: timberEdge, outlineWidth: 0.4
                )
            }
            for plank in 0..<3 {
                outlinedVoxelBox(
                    context: &context, x: x + w * 0.12, y: y + d * (0.24 + CGFloat(plank) * 0.13),
                    w: w * 0.48, d: d * 0.09, h: height + 0.94, z0: height + 0.72,
                    top: timber, se: timberEdge, sw: timberEdge, outlineWidth: 0.4
                )
            }

            // The right bay is wrapped; the left stays open so platforms,
            // wall ties and the gap between scaffold and facade remain legible.
            fill(context: &context, [
                sitePoint(0.51, outer - 0.08, height * 0.29),
                sitePoint(0.91, outer - 0.08, height * 0.29),
                sitePoint(0.91, outer - 0.08, deckTop + 0.65),
                sitePoint(0.51, outer - 0.08, deckTop + 0.65),
            ], color: net.opacity(0.84))
            for seam in 1..<4 {
                let a = 0.51 + CGFloat(seam) * 0.10
                stroke(context: &context, [sitePoint(a, outer - 0.06, height * 0.29), sitePoint(a, outer - 0.06, deckTop + 0.65)], color: tube.opacity(0.23), width: 0.4)
            }
            // Rear uprights first; the front structure is drawn after decks.
            for a: CGFloat in [0.09, 0.50, 0.91] {
                stroke(context: &context, [sitePoint(a, 0.12, 0.72), sitePoint(a, 0.12, deckTop + 1.0)], color: steel, width: 0.85)
            }
            for level in 1...levels {
                let z = 0.72 + CGFloat(level) * (deckTop - 0.72) / CGFloat(levels)
                let previous = 0.72 + CGFloat(level - 1) * (deckTop - 0.72) / CGFloat(levels)
                // The deck casts a small contact shadow on its host wall.
                fill(context: &context, [
                    sitePoint(0.07, 0.01, z - 0.38), sitePoint(0.94, 0.01, z - 0.38),
                    sitePoint(0.94, 0.01, z), sitePoint(0.07, 0.01, z),
                ], color: ink.opacity(0.22))
                outlinedVoxelBox(
                    context: &context, x: x + w * 0.06, y: frontY + 0.08,
                    w: w * 0.89, d: outer + 0.12, h: z, z0: z - 0.16,
                    top: timber, se: timberEdge, sw: timberEdge, outlineWidth: 0.45
                )
                for a: CGFloat in [0.09, 0.50, 0.91] {
                    stroke(context: &context, [sitePoint(a, 0.12, z + 0.07), sitePoint(a, outer, z + 0.07)], color: tube, width: 0.65)
                }
                stroke(context: &context, [sitePoint(0.09, outer, z + 0.78), sitePoint(0.91, outer, z + 0.78)], color: tube, width: 0.85)
                // Alternating single diagonals keep the frame structural,
                // avoiding the repeated white-X lattice of the old treatment.
                let left: CGFloat = level.isMultiple(of: 2) ? 0.09 : 0.50
                let right: CGFloat = level.isMultiple(of: 2) ? 0.50 : 0.91
                stroke(context: &context, [sitePoint(left, outer, previous + 0.12), sitePoint(right, outer, z - 0.12)], color: steel, width: 0.8)
            }
            // A slightly raked access ladder occupies the unwrapped bay.
            for rail: CGFloat in [0.14, 0.26] {
                stroke(context: &context, [
                    sitePoint(rail, outer + 0.04, 0.76),
                    sitePoint(rail + 0.06, outer + 0.04, deckTop + 0.35),
                ], color: tube, width: 0.95)
            }
            let rungs = min(12, max(4, Int(height / 1.2)))
            for rung in 1..<rungs {
                let fraction = CGFloat(rung) / CGFloat(rungs)
                let z = 0.76 + fraction * (deckTop + 0.35 - 0.76)
                stroke(context: &context, [
                    sitePoint(0.14 + fraction * 0.06, outer + 0.05, z),
                    sitePoint(0.26 + fraction * 0.06, outer + 0.05, z),
                ], color: tube, width: 0.7)
            }
            for a: CGFloat in [0.09, 0.50, 0.91] {
                let px = x + w * a
                outlinedVoxelBox(
                    context: &context, x: px - 0.18, y: frontY + outer - 0.18,
                    w: 0.36, d: 0.36, h: 0.87, z0: 0.72,
                    top: timber, se: timberEdge, sw: timberEdge, outlineWidth: 0.35
                )
                outlinedVoxelBox(
                    context: &context, x: px - 0.055, y: frontY + outer - 0.055,
                    w: 0.11, d: 0.11, h: deckTop + 1.0, z0: 0.87,
                    top: tube, se: steel, sw: tube, outlineWidth: 0.3
                )
            }
            // A freestanding striped barrier blocks the shuttered entrance.
            let barrierY = outer + 0.22
            for a: CGFloat in [0.25, 0.75] {
                stroke(context: &context, [sitePoint(a, barrierY, 0.72), sitePoint(a, barrierY, 2.12)], color: timberEdge, width: 1.5)
            }
            fill(context: &context, [
                sitePoint(0.20, barrierY, 1.15), sitePoint(0.80, barrierY, 1.15),
                sitePoint(0.80, barrierY, 1.95), sitePoint(0.20, barrierY, 1.95),
            ], color: amber)
            for stripe in 0..<5 {
                let a = 0.23 + CGFloat(stripe) * 0.10
                fill(context: &context, [
                    sitePoint(a, barrierY + 0.01, 1.15), sitePoint(a + 0.045, barrierY + 0.01, 1.15),
                    sitePoint(a + 0.10, barrierY + 0.01, 1.95), sitePoint(a + 0.055, barrierY + 0.01, 1.95),
                ], color: ink)
            }
        case .unknown:
            // Architectural detail recedes behind frosted faces and a low
            // roof-hugging veil. No invented damage or asserted occupation.
            let fog = RGB(r: 185, g: 199, b: 203)
            for side in [false, true] {
                var face = Path()
                face.addLines(facade(side, 0, 1, 0.72, height + 0.4))
                face.closeSubpath()
                context.fill(face, with: .linearGradient(
                    Gradient(colors: [
                        nightified(fog, sample: sample, attenuation: 0.35).opacity(0.86),
                        nightified(fog, sample: sample, attenuation: 0.5).opacity(0.40),
                    ]),
                    startPoint: IsoProjection.project(x + w / 2, frontY, height),
                    endPoint: IsoProjection.project(x + w / 2, frontY, 0.72)
                ))
            }
            fill(context: &context, [
                IsoProjection.project(x - 0.1, y - 0.1, height + 0.65),
                IsoProjection.project(x + w + 0.1, y - 0.1, height + 0.65),
                IsoProjection.project(x + w + 0.1, y + d + 0.1, height + 0.65),
                IsoProjection.project(x - 0.1, y + d + 0.1, height + 0.65),
            ], color: nightified(fog, sample: sample, attenuation: 0.35).opacity(0.85))
        }
    }



    /// Boxy street-corner planters with a leafy mound soften the empty plot
    /// aprons. Placement is pure plot geometry, so the retained base stays
    /// byte-identical when jobs change.
    private func drawCornerPlanters(
        context: inout GraphicsContext,
        plot: CityPlot,
        sample: CityPalette.Sample,
        lighting: CityLighting.Sample
    ) {
        let planterTone = Self.mixed(CalmCityStyle.paper, CalmCityStyle.coral, 0.35)
        let faces = CityPalette.faceColors(base: planterTone, sample: sample, lighting: lighting, nightAttenuation: 0.92)
        for corner in 0..<2 {
            let hash = UInt(bitPattern: Self.byteHash("\(plot.id)-planter-\(corner)"))
            guard hash % 3 != 0 else { continue }
            let px = corner == 0 ? plot.x + 0.55 : plot.x + plot.w - 1.3
            let py = plot.y + plot.d - 1.3
            outlinedVoxelBox(
                context: &context,
                x: px, y: py, w: 0.75, d: 0.75,
                h: 1.25, z0: 0.7,
                top: faces.top.color, se: faces.right.color, sw: faces.left.color,
                outlineWidth: 0.55
            )
            let mound = IsoProjection.project(px + 0.38, py + 0.38, 1.55)
            let leaf = hash % 2 == 0 ? CalmCityStyle.leaf : CalmCityStyle.blossom
            context.fill(
                Path(ellipseIn: CGRect(x: mound.x - 0.95, y: mound.y - 0.85, width: 1.9, height: 1.7)),
                with: .color(nightified(leaf, sample: sample, attenuation: 0.6))
            )
        }
    }

    /// A pinch of confetti flora on the plot apron. Positions hash from the
    /// stable plot id, so the retained base stays byte-identical when jobs
    /// change.
    private func drawFlowerDots(
        context: inout GraphicsContext,
        plot: CityPlot,
        sample: CityPalette.Sample
    ) {
        let tokens = [CalmCityStyle.coral, CalmCityStyle.marigold, CalmCityStyle.blossom]
        for index in 0..<6 {
            let hash = UInt(bitPattern: Self.byteHash("\(plot.id)-flower-\(index)"))
            let fx = plot.x + 0.8 + CGFloat(hash % 997) / 997 * (plot.w - 1.6)
            let fy = plot.y + plot.d - 0.55 - CGFloat((hash >> 10) % 97) / 97 * 0.5
            let p = IsoProjection.project(fx, fy, 0.74)
            let color = tokens[Int(hash % 3)]
            context.fill(
                Path(ellipseIn: CGRect(x: p.x - 0.8, y: p.y - 0.8, width: 1.6, height: 1.6)),
                with: .color(nightified(color, sample: sample, attenuation: 0.6))
            )
        }
    }

    /// Batched structural window cells whose warm subset follows deterministic
    /// GPU occupancy. The retained base key includes the occupancy signature.
    private func drawPavilionWindows(
        context: inout GraphicsContext,
        plot: CityPlot,
        building: BuildingSpec,
        height: CGFloat,
        sample: CityPalette.Sample
    ) {
        let rows = min(4, max(2, Int(height / 3.2)))
        let frontColumns = min(4, max(2, Int(building.bw / 1.8)))
        let sideColumns = min(3, max(1, Int(building.bd / 2.2)))
        let x = plot.x + building.ox, y = plot.y + building.oy
        let warm = Self.mixed(CalmCityStyle.paper, CalmCityStyle.marigold, 0.45 + 0.55 * sample.night)
        let cool = Self.mixed(CalmCityStyle.paper, CalmCityStyle.water, 0.45)
        let state = CalmCityStyle.buildingState(for: plot)
        let jobPressure = state == .allocated ? CityWindows.runningJobPressure(for: plot.node) : 0
        var warmCells = Path()
        var coolCells = Path()
        for row in 0..<rows {
            let wz = height - (CGFloat(row) + 0.7) * height / CGFloat(rows + 1)
            for column in 0..<frontColumns {
                let front = IsoProjection.project(x + (CGFloat(column) + 0.5) * building.bw / CGFloat(frontColumns), y + building.bd + 0.02, wz)
                let sequence = row * (frontColumns + sideColumns) + column
                let lit = state == .allocated && Self.pavilionWindowIsLit(
                    plotID: plot.id,
                    building: building,
                    sequence: sequence,
                    t: sample.t,
                    jobPressure: jobPressure
                )
                if lit {
                    Self.addFacadeCell(&warmCells, center: front, halfW: 0.72, halfH: 0.95, sideFace: false)
                } else {
                    Self.addFacadeCell(&coolCells, center: front, halfW: 0.72, halfH: 0.95, sideFace: false)
                }
            }
            for column in 0..<sideColumns {
                let side = IsoProjection.project(x + building.bw + 0.02, y + (CGFloat(column) + 0.5) * building.bd / CGFloat(sideColumns), wz)
                let sequence = row * (frontColumns + sideColumns) + frontColumns + column
                if state == .allocated && Self.pavilionWindowIsLit(
                    plotID: plot.id,
                    building: building,
                    sequence: sequence,
                    t: sample.t,
                    jobPressure: jobPressure
                ) {
                    Self.addFacadeCell(&warmCells, center: side, halfW: 0.72, halfH: 0.95, sideFace: true)
                } else {
                    Self.addFacadeCell(&coolCells, center: side, halfW: 0.72, halfH: 0.95, sideFace: true)
                }
            }
        }
        context.fill(warmCells, with: .color(warm.color.opacity(0.95)))
        context.fill(coolCells, with: .color(nightified(cool, sample: sample, attenuation: 0.6).opacity(state == .unknown ? 0.15 : 0.55)))
    }





    private func drawFreshnessOverlay(context: inout GraphicsContext, size: CGSize, state: SnapshotRefreshState, date: Date) {
        let dimming = sceneDimming(for: state)
        guard dimming > 0 || state == .refreshing else { return }
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.02, green: 0.04, blue: 0.07).opacity(dimming)))
        switch state {
        case .refreshing:
            break
        case .unavailable:
            drawText(context: &context, "PROVINCE UNAVAILABLE", at: CGPoint(x: size.width / 2, y: size.height / 2), font: .caption.monospaced().weight(.bold), color: .white.opacity(0.72), anchor: .center)
        case .fresh, .stale:
            break
        }
    }


    /// One concise live cluster fact, hung with the title in the upper-right province sky.
    var provinceHeadline: String {
        let open = scape.plots.count { $0.mode == .vacant }
        return "\(open)/\(scape.plots.count) GPUS OPEN · \(scape.runningJobs.count) JOBS RUNNING"
    }


    /// Designed toy water for the meandering river: sandy shore ring under
    /// the fill, a darker deep channel tracing the thalweg, a braided island
    /// with its own trees, a downstream lagoon, hashed ripple dashes, lily
    /// pads, one moored rowboat, and station-hashed quiet life (lily
    /// clusters, reed clumps, one small wooden dock). Pure scape geometry
    /// + palette sample,
    /// so the retained base stays byte-identical when jobs change. Props
    /// keep to along-flow windows clear of the bridge corridor
    /// (s ~ 0.38...0.66) and >= 0.03 in s away from the pinned
    /// river-separation sample stations.
    private func drawWater(context: inout GraphicsContext, sample: CityPalette.Sample) {
        // Shore band first: a widened warm stroke reads as sandy banks.
        let shore = Self.mixed(CalmCityStyle.paper, CalmCityStyle.marigold, 0.35)
        context.stroke(
            staticPaths.river,
            with: .color(nightified(shore, sample: sample)),
            style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round)
        )
        context.fill(staticPaths.river, with: .color(nightified(CalmCityStyle.water, sample: sample)))
        // Shallow rim: a light, sand-warmed band hugging the banks inside the
        // fill, so the water ramps shore -> shallow -> open -> deep channel
        // instead of reading as one flat sticker.
        var shallowLayer = context
        shallowLayer.clip(to: staticPaths.river)
        let shallow = Self.mixed(CalmCityStyle.water, Self.mixed(CalmCityStyle.paper, CalmCityStyle.marigold, 0.4), 0.42)
        shallowLayer.stroke(
            staticPaths.river,
            with: .color(nightified(shallow, sample: sample).opacity(0.85)),
            style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)
        )
        let stations = CityScape.riverStations
        guard stations.count > 2 else { return }
        func spot(_ s: CGFloat, _ lateral: CGFloat) -> CGPoint {
            let world = CityScape.riverPoint(s, lateral: lateral)
            return IsoProjection.project(world.x, world.y, 0)
        }
        func bankOffsets(_ s: CGFloat) -> (west: CGFloat, east: CGFloat) {
            (-CityScape.riverHalfWidth(s), CityScape.riverHalfWidth(s) + CityScape.riverLagoonBulge(s))
        }
        // Deep channel: follows the meander down the middle and pinches
        // around the island's west shore, so the water reads as depth
        // instead of a flat sticker.
        let deep = nightified(Self.mixed(CalmCityStyle.water, CalmCityStyle.ink, 0.24), sample: sample)
        func channelEast(_ station: CityScape.RiverStation) -> CGFloat {
            min(-station.west * 0.45, CityScape.riverIslandLateral - CityScape.riverIslandHalfLens(station.s) - 0.9)
        }
        var channel = Path()
        channel.move(to: spot(stations[0].s, stations[0].west * 0.45))
        for station in stations.dropFirst() {
            channel.addLine(to: spot(station.s, station.west * 0.45))
        }
        for station in stations.reversed() {
            channel.addLine(to: spot(station.s, channelEast(station)))
        }
        channel.closeSubpath()
        context.fill(channel, with: .color(deep.opacity(0.85)))
        context.stroke(
            staticPaths.river,
            with: .color(nightified(Self.mixed(CalmCityStyle.water, CalmCityStyle.ink, 0.35), sample: sample)),
            lineWidth: 1.2
        )
        // Braided island: sand ring, meadow center, and a couple of trees.
        context.fill(staticPaths.riverIsland, with: .color(nightified(shore, sample: sample)))
        context.stroke(
            staticPaths.riverIsland,
            with: .color(nightified(Self.mixed(CalmCityStyle.water, CalmCityStyle.ink, 0.35), sample: sample)),
            lineWidth: 1
        )
        let islandMid = (CityScape.riverIslandRange.lowerBound + CityScape.riverIslandRange.upperBound) / 2
        let meadowCenter = spot(islandMid, CityScape.riverIslandLateral)
        context.fill(
            Path(ellipseIn: CGRect(x: meadowCenter.x - 9, y: meadowCenter.y - 4, width: 18, height: 8)),
            with: .color(nightified(CalmCityStyle.ground, sample: sample).opacity(0.9))
        )
        for (offset, size) in [(CGFloat(-1.4), CGFloat(0.8)), (CGFloat(1.6), CGFloat(0.6))] {
            let world = CityScape.riverPoint(islandMid + offset * 0.012, lateral: CityScape.riverIslandLateral + offset)
            drawTree(context: &context, tree: Tree(x: world.x, y: world.y, size: size), sample: sample, nightAttenuation: 1)
        }
        // Static toy-water ripples: pale hashed dashes, no animation cost.
        // Windows are (s range, lateral-fraction range); fractions resolve
        // against the local bank offsets, keeping dashes on open water.
        let rippleWindows: [(s0: CGFloat, s1: CGFloat, f0: CGFloat, f1: CGFloat)] = [
            (0.13, 0.30, -0.65, -0.30),
            (0.36, 0.41, -0.45, 0.45),
            (0.62, 0.67, -0.45, 0.45),
            (0.78, 0.82, -0.45, 0.45),
            (0.83, 0.89, 0.25, 0.70),
        ]
        let ripple = nightified(Self.mixed(CalmCityStyle.water, CalmCityStyle.paper, 0.55), sample: sample)
        var dashes = Path()
        for index in 0..<12 {
            let hash = UInt(bitPattern: Self.byteHash("ripple-\(index)"))
            let window = rippleWindows[index % rippleWindows.count]
            let s = window.s0 + (window.s1 - window.s0) * CGFloat(hash % 89) / 89
            let fraction = window.f0 + (window.f1 - window.f0) * CGFloat((hash >> 8) % 71) / 71
            let offsets = bankOffsets(s)
            let lateral = fraction * ((fraction < 0 ? -offsets.west : offsets.east) - 1.2)
            let point = spot(s, lateral)
            let half = 2.2 + CGFloat((hash >> 16) % 5) * 0.55
            dashes.move(to: CGPoint(x: point.x - half, y: point.y))
            dashes.addLine(to: CGPoint(x: point.x + half, y: point.y))
        }
        context.stroke(dashes, with: .color(ripple.opacity(0.7)), style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
        // Lily pads cluster on the island fringe and in the lagoon. Full
        // night attenuation so they go dark with the wild water.
        for index in 0..<8 {
            let hash = UInt(bitPattern: Self.byteHash("lily-\(index)"))
            let s: CGFloat
            let lateral: CGFloat
            if index % 2 == 0 {
                s = CityScape.riverIslandRange.lowerBound
                    + (CityScape.riverIslandRange.upperBound - CityScape.riverIslandRange.lowerBound)
                    * CGFloat(hash % 83) / 83
                lateral = CityScape.riverIslandLateral + CityScape.riverIslandHalfLens(s) + 1.4 + CGFloat((hash >> 8) % 5) * 0.35
            } else {
                s = 0.83 + 0.06 * CGFloat(hash % 83) / 83
                lateral = bankOffsets(s).east * (0.35 + CGFloat((hash >> 8) % 5) * 0.08)
            }
            let point = spot(s, lateral)
            context.fill(Path(ellipseIn: CGRect(x: point.x - 2.6, y: point.y - 1.5, width: 5.2, height: 3)), with: .color(nightified(CalmCityStyle.leafDeep, sample: sample)))
            context.fill(Path(ellipseIn: CGRect(x: point.x - 1.6, y: point.y - 1.1, width: 3.2, height: 1.9)), with: .color(nightified(CalmCityStyle.leaf, sample: sample)))
            if hash % 3 == 0 {
                context.fill(Path(ellipseIn: CGRect(x: point.x - 0.8, y: point.y - 0.9, width: 1.6, height: 1.6)), with: .color(nightified(CalmCityStyle.blossom, sample: sample)))
            }
        }
        // One moored rowboat rests in the lagoon.
        let boatHash = UInt(bitPattern: Self.byteHash("rowboat"))
        let boatS = 0.85 + CGFloat(boatHash % 5) * 0.008
        let boat = spot(boatS, bankOffsets(boatS).east * 0.55)
        let hull = CGRect(x: boat.x - 4.6, y: boat.y - 2.1, width: 9.2, height: 4.2)
        context.fill(Path(ellipseIn: hull), with: .color(nightified(CalmCityStyle.paper, sample: sample, attenuation: 0.85)))
        context.stroke(Path(ellipseIn: hull), with: .color(nightified(CalmCityStyle.coral, sample: sample, attenuation: 0.85)), lineWidth: 1)
        var bench = Path()
        bench.move(to: CGPoint(x: boat.x - 2.2, y: boat.y))
        bench.addLine(to: CGPoint(x: boat.x + 2.2, y: boat.y))
        context.stroke(bench, with: .color(nightified(CalmCityStyle.ink, sample: sample).opacity(0.7)), lineWidth: 1)
        // Station-hashed quiet life: lily clusters, reed clumps, one dock.
        drawRiverBankLife(context: &context, sample: sample)
    }

    /// One quiet-life sample station on the river centerline. Stations are
    /// spaced 2.5 world units apart along the polyline; the station index
    /// hash picks the feature (0-2 lily cluster, 3 reeds, 4 ripple ring,
    /// 5 none), so the static base pass and the live overlay agree on
    /// placement.
    private func riverLifeStations() -> [(index: Int, s: CGFloat, x: CGFloat, y: CGFloat)] {
        let stations = CityScape.riverStations
        var result: [(index: Int, s: CGFloat, x: CGFloat, y: CGFloat)] = []
        var nextMark: CGFloat = 0
        var travelled: CGFloat = 0
        var index = 0
        for (a, b) in zip(stations, stations.dropFirst()) {
            let segment = ((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y)).squareRoot()
            while segment > 0, travelled + segment >= nextMark {
                let t = (nextMark - travelled) / segment
                result.append((
                    index: index,
                    s: a.s + (b.s - a.s) * t,
                    x: a.x + (b.x - a.x) * t,
                    y: a.y + (b.y - a.y) * t
                ))
                index += 1
                nextMark += 2.5
            }
            travelled += segment
        }
        return result
    }

    /// The bridge deck hides the river beneath it: nothing is placed within
    /// 6 world units of the deck centerline.
    private func riverLifeNearBridge(x: CGFloat, y: CGFloat) -> Bool {
        let deck = scape.bridgeDeck
        let midY = (deck.min.1 + deck.max.1) / 2
        let clampedX = min(max(x, deck.min.0), deck.max.0)
        let dx = x - clampedX, dy = y - midY
        return dx * dx + dy * dy < 36
    }

    /// Projected length of one ground-plane world unit (pre-camera), for
    /// sizing screen-space sprites in world terms.
    private var riverLifeUnit: CGFloat {
        (IsoProjection.s * IsoProjection.s + IsoProjection.fy * IsoProjection.fy).squareRoot()
    }

    /// Hash-jittered open-water lateral offset that stays clear of the
    /// braided island lens (same clamp as the sparkle pass).
    private func riverLifeOpenLateral(s: CGFloat, hash: UInt) -> CGFloat {
        let fraction = CGFloat((hash >> 12) % 101) / 101
        var lateral = (fraction - 0.5) * 2 * (CityScape.riverHalfWidth(s) - 1.5)
        let lens = CityScape.riverIslandHalfLens(s)
        if lens > 0, lateral > CityScape.riverIslandLateral - lens - 1 {
            lateral = CityScape.riverIslandLateral - lens - 1.5
        }
        return lateral
    }

    /// Static station life for the base pass: lily clusters on open water
    /// and reed clumps leaning on the banks, then one small dock. All
    /// placement is station-hash derived, so the retained base stays
    /// byte-identical when jobs change; tones dim with the night palette.
    private func drawRiverBankLife(context: inout GraphicsContext, sample: CityPalette.Sample) {
        let unit = riverLifeUnit
        let padColor = nightified(Self.mixed(CalmCityStyle.leaf, CalmCityStyle.water, 0.25), sample: sample, attenuation: 0.8)
        let blossomColor = nightified(CalmCityStyle.blossom, sample: sample, attenuation: 0.8)
        let reedColor = nightified(CalmCityStyle.spruce, sample: sample, attenuation: 0.8).opacity(0.8)
        let cattailColor = nightified(Self.mixed(CalmCityStyle.marigold, CalmCityStyle.ink, 0.3), sample: sample, attenuation: 0.8)
        // Reed tips lean 0.08 down-sun: west at sunrise, east at sunset.
        let lean = (x: 0.08 * CGFloat(sample.sunProgress * 2 - 1), y: CGFloat(0.03))
        for station in riverLifeStations() {
            guard !riverLifeNearBridge(x: station.x, y: station.y) else { continue }
            let hash = UInt(bitPattern: Self.byteHash("river-life-\(station.index)"))
            switch hash % 6 {
            case 0, 1, 2:
                // Lily cluster: 2-4 small pads scattered around the station.
                let count = 2 + Int((hash >> 6) % 3)
                let baseLateral = riverLifeOpenLateral(s: station.s, hash: hash)
                for pad in 0..<count {
                    let padHash = UInt(bitPattern: Self.byteHash("river-life-\(station.index)-pad-\(pad)"))
                    let lateral = baseLateral + (CGFloat((padHash >> 4) % 61) / 61 - 0.5) * 1.6
                    let along = (CGFloat((padHash >> 10) % 61) / 61 - 0.5) * 1.8
                    let width = (0.3 + CGFloat((padHash >> 16) % 41) / 41 * 0.2) * unit
                    let world = CityScape.riverPoint(station.s, lateral: lateral)
                    let point = IsoProjection.project(world.x, world.y + along, 0.02)
                    context.fill(
                        Path(ellipseIn: CGRect(x: point.x - width / 2, y: point.y - width * 0.31, width: width, height: width * 0.62)),
                        with: .color(padColor)
                    )
                    if padHash % 5 == 0 {
                        let dot = 0.12 * unit
                        context.fill(
                            Path(ellipseIn: CGRect(x: point.x - dot / 2, y: point.y - dot * 0.31, width: dot, height: dot * 0.62)),
                            with: .color(blossomColor)
                        )
                    }
                }
            case 3:
                // Reed clump: 4 thin stems on the hash-picked bank, some
                // tipped with a cattail.
                let side: CGFloat = (hash >> 9) % 2 == 0 ? -1 : 1
                let bankLateral = side * (CityScape.riverHalfWidth(station.s) + 0.15)
                let world = CityScape.riverPoint(station.s, lateral: bankLateral)
                for stem in 0..<4 {
                    let stemHash = UInt(bitPattern: Self.byteHash("river-life-\(station.index)-reed-\(stem)"))
                    let spread = (CGFloat((stemHash >> 4) % 61) / 61 - 0.5) * 0.7
                    let height = 0.6 + CGFloat((stemHash >> 10) % 41) / 41 * 0.4
                    let base = IsoProjection.project(world.x, world.y + spread, 0)
                    let tip = IsoProjection.project(world.x + lean.x * height, world.y + spread + lean.y * height, height)
                    stroke(context: &context, [base, tip], color: reedColor, width: 0.7)
                    if stemHash % 10 < 3 {
                        context.fill(
                            Path(ellipseIn: CGRect(x: tip.x - 0.55, y: tip.y - 2.1, width: 1.1, height: 2.2)),
                            with: .color(cattailColor)
                        )
                    }
                }
            default:
                break
            }
        }
        drawRiverDock(context: &context, stations: riverLifeStations(), sample: sample)
    }

    /// One small wooden dock on a hash-picked station: a 1.6 x 1.0 plank
    /// platform on four posts, reaching from the bank into the water
    /// perpendicular to the shore. Wood tones match the tree trunks.
    private func drawRiverDock(
        context: inout GraphicsContext,
        stations: [(index: Int, s: CGFloat, x: CGFloat, y: CGFloat)],
        sample: CityPalette.Sample
    ) {
        let eligible = stations.filter { !riverLifeNearBridge(x: $0.x, y: $0.y) }
        guard !eligible.isEmpty else { return }
        let hash = UInt(bitPattern: Self.byteHash("river-life-dock"))
        let station = eligible[Int(hash % UInt(eligible.count))]
        let side: CGFloat = (hash >> 8) % 2 == 0 ? -1 : 1
        // The lagoon bulge widens the east bank; the dock must meet dry land.
        let bulge = side > 0 ? CityScape.riverLagoonBulge(station.s) : 0
        let bankLateral = side * (CityScape.riverHalfWidth(station.s) + bulge + 0.15)
        let anchor = CityScape.riverPoint(station.s, lateral: bankLateral)
        let length: CGFloat = 1.6, width: CGFloat = 1.0
        let px = side > 0 ? anchor.x - length + 0.25 : anchor.x - 0.25
        let py = anchor.y - width / 2
        let postTop = nightColor(120, 90, 56, sample: sample, attenuation: 0.8)
        let postSE = nightColor(96, 72, 45, sample: sample, attenuation: 0.8)
        let postSW = nightColor(80, 60, 38, sample: sample, attenuation: 0.8)
        for (ox, oy) in [(0.05, 0.05), (0.05, 0.85), (1.45, 0.05), (1.45, 0.85)] as [(CGFloat, CGFloat)] {
            box(context: &context, x: px + ox, y: py + oy, w: 0.1, d: 0.1, h: 0.13, z0: 0, top: postTop, se: postSE, sw: postSW)
        }
        box(
            context: &context, x: px, y: py, w: length, d: width, h: 0.25, z0: 0.13,
            top: nightColor(150, 112, 70, sample: sample, attenuation: 0.8),
            se: nightColor(120, 90, 56, sample: sample, attenuation: 0.8),
            sw: nightColor(100, 75, 47, sample: sample, attenuation: 0.8)
        )
        // Three plank seam lines across the deck.
        let seamColor = nightified(CalmCityStyle.ink, sample: sample, attenuation: 0.8).opacity(0.15)
        for seam in 1...3 {
            let sx = px + length * CGFloat(seam) / 4
            stroke(
                context: &context,
                [IsoProjection.project(sx, py + 0.05, 0.26), IsoProjection.project(sx, py + width - 0.05, 0.26)],
                color: seamColor,
                width: 0.5
            )
        }
    }

    /// Low faceted world-space foothills separate the town meadow from the
    /// horizon mountains. Static source coordinates keep retained rendering
    /// deterministic when job data changes.
    private func drawHills(context: inout GraphicsContext, sample: CityPalette.Sample, visibleRect: CGRect) {
        let sunward = Self.mixed(CalmCityStyle.ground, CalmCityStyle.paper, 0.07)
        let middle = Self.mixed(CalmCityStyle.ground, CalmCityStyle.spruce, 0.08)
        let shaded = Self.mixed(CalmCityStyle.ground, CalmCityStyle.ink, 0.035)
        for hill in staticPaths.hills {
            let geometry = CityIsometricMoundGeometry(
                x: hill.x,
                y: hill.y,
                height: hill.height * 0.82,
                radius: hill.radius * 0.90
            )
            guard visibleRect.insetBy(dx: -24, dy: -24).intersects(geometry.projectedBounds) else { continue }

            context.fill(
                geometry.contactShadowPath,
                with: .color(nightified(CalmCityStyle.ink, sample: sample).opacity(0.08))
            )
            for facet in geometry.facets {
                let token: RGB
                switch facet.light {
                case .top:
                    token = sunward
                case .left:
                    token = shaded
                case .right:
                    token = middle
                }
                context.fill(facet.path, with: .color(nightified(token, sample: sample)))
            }
        }
    }

    nonisolated static func sleepingTitanGeometry(
        worldBounds: CGRect,
        wake: CGFloat = 0,
        breath: CGFloat = 0
    ) -> CityIsometricTitanGeometry {
        let scale = CityIsometricTitanGeometry.modelScale
        return CityIsometricTitanGeometry(
            x: worldBounds.maxX - 12 - 25 * scale,
            y: worldBounds.maxY - 10 - 25 * scale,
            wake: wake,
            breath: breath
        )
    }

    nonisolated static func titanEyeGlowCenter(
        for geometry: CityIsometricTitanGeometry
    ) -> CGPoint {
        let points = geometry.pupil.facets.flatMap(\.projectedPoints)
        return points.reduce(CGPoint.zero) {
            CGPoint(
                x: $0.x + $1.x / CGFloat(points.count),
                y: $0.y + $1.y / CGFloat(points.count)
            )
        }
    }

    private func sleepingTitanGeometry() -> CityIsometricTitanGeometry {
        Self.sleepingTitanGeometry(worldBounds: staticPaths.groundWorldBounds)
    }

    /// Contact patches belong below every world-depth primitive; otherwise a
    /// nearer tree or structure can be darkened by a later titan mass.
    /// Only masses that actually rest on the ground in every pose bake a
    /// patch here — elevated joint cores would otherwise leave a shadow
    /// floating under thin air, and the posed masses paint their own
    /// patches live so nothing stale is left behind when they move.
    private func drawTitanContacts(
        context: inout GraphicsContext,
        geometry: CityIsometricTitanGeometry
    ) {
        for solid in geometry.groundedSolids where solid.baseZ <= 0.001 {
            drawTitanContactPatch(context: &context, solid: solid, opacity: 0.08)
        }
    }

    /// One ground patch under a golem mass, at the mass's current posed
    /// footprint so a moving mass never leaves its shadow behind.
    private func drawTitanContactPatch(
        context: inout GraphicsContext,
        solid: CityTitanSolid,
        opacity: Double
    ) {
        let points = solid.worldFootprint.map {
            CityWorldPoint3D(x: $0.x, y: $0.y, z: 0.02)
        }
        var contact = Path()
        if let first = points.first?.projected {
            contact.move(to: first)
            for point in points.dropFirst() {
                contact.addLine(to: point.projected)
            }
            contact.closeSubpath()
        }
        context.fill(contact, with: .color(Color.black.opacity(opacity)))
    }

    /// Paint role for a golem mass. The anatomy only reads if the shoulder
    /// cap, limbs, hands, and feet carry their own tone; one shared
    /// lavender turns the whole figure into rubble. The golem lies on its
    /// side, so the limb split is ground-side against sky-side rather than
    /// far against near.
    private enum TitanPaint {
        case body
        case cap
        /// Ground-side limb, crushed against the terrain in shadow.
        case limbGround
        /// Sky-side limb, draped on top and catching the light.
        case limbSky
        case extremity
        /// Darker stone socket where two masses meet.
        case joint
    }

    /// Resolves a mass back to its named part. Unknown masses fall back
    /// to the body stone, so a new solid is always painted, never dropped.
    private static func titanPaint(
        for solid: CityTitanSolid,
        in geometry: CityIsometricTitanGeometry
    ) -> TitanPaint {
        switch solid {
        case geometry.torso:
            return .body
        case geometry.shoulderUp:
            return .cap
        case geometry.thighDown, geometry.shinDown,
             geometry.upperArmDown, geometry.forearmDown:
            return .limbGround
        case geometry.thighUp, geometry.shinUp,
             geometry.upperArmUp, geometry.forearmUp:
            return .limbSky
        case geometry.footDown, geometry.footUp, geometry.handDown, geometry.handUp:
            return .extremity
        case geometry.hipCoreDown, geometry.hipCoreUp,
             geometry.kneeCoreDown, geometry.kneeCoreUp,
             geometry.ankleCoreDown, geometry.ankleCoreUp,
             geometry.wristCoreDown, geometry.wristCoreUp,
             geometry.elbowCoreDown, geometry.elbowCoreUp,
             geometry.shoulderCoreUp:
            return .joint
        default:
            return .body
        }
    }

    /// A golem mass is painted independently so ordinary world geometry
    /// can interleave between the reclining body parts. Serves both the
    /// baked static masses and the per-frame posed overlay masses.
    private func drawTitanSolid(
        context: inout GraphicsContext,
        sample: CityPalette.Sample,
        geometry: CityIsometricTitanGeometry,
        solid: CityTitanSolid
    ) {
        let stone = Self.mixed(CalmCityStyle.lavender, CalmCityStyle.ground, 0.18)
        let tint: RGB
        switch Self.titanPaint(for: solid, in: geometry) {
        case .body:
            tint = stone
        case .cap:
            // The sky-side shoulder catches the light above the trunk.
            tint = Self.mixed(stone, CalmCityStyle.paper, 0.10)
        case .limbGround:
            // The ground-side limbs sink into shadow under the body.
            tint = Self.mixed(stone, CalmCityStyle.ink, 0.10)
        case .limbSky:
            tint = Self.mixed(stone, CalmCityStyle.paper, 0.08)
        case .extremity:
            // Hands and feet catch the sky, lifting off the body mass.
            tint = Self.mixed(stone, CalmCityStyle.paper, 0.12)
        case .joint:
            // Joint sockets sink a step below limb stone so the
            // connected articulation reads as carved, not stacked.
            tint = Self.mixed(stone, CalmCityStyle.ink, 0.14)
        }
        fillTitanFacets(context: &context, sample: sample, facets: solid.facets, tint: tint)
    }

    /// Facet shading carries the stone volume. Only the outer crown gets
    /// a quiet crease; outlining every bevel made limbs read as stacked plates.
    private func fillTitanFacets(
        context: inout GraphicsContext,
        sample: CityPalette.Sample,
        facets: [CityProjectedFacet],
        tint: RGB? = nil
    ) {
        let base = tint ?? Self.mixed(CalmCityStyle.lavender, CalmCityStyle.ground, 0.18)
        for facet in facets {
            let token: RGB
            switch facet.light {
            case .top:
                token = Self.mixed(base, CalmCityStyle.paper, 0.24)
            case .left:
                token = Self.mixed(base, CalmCityStyle.ink, 0.34)
            case .right:
                token = Self.mixed(base, CalmCityStyle.ink, 0.22)
            }
            // Pale stone retains ambient moonlight so the landmark's
            // silhouette and joints remain readable without emissive trim.
            context.fill(facet.path, with: .color(nightified(token, sample: sample, attenuation: 0.68)))
            if facet.light == .top && facet.panel == 0 {
                context.stroke(
                    facet.path,
                    with: .color(nightified(CalmCityStyle.ink, sample: sample).opacity(0.12)),
                    lineWidth: 0.35
                )
            }
        }
    }

    /// The golem's head lives in the live overlay so wakefulness animates
    /// per frame: it lifts off its slumped rest as the cluster fills, the
    /// closed eye slit gives way to an open eye that glows softly at night,
    /// breath keeps a slow bob, and Zzz drifts off the face while it sleeps.
    /// Receives the shared per-pass pose so its geometry, its occluders,
    /// and the posed-mass items all render the same breath phase.
    private func drawTitanHead(
        context: inout GraphicsContext,
        sample: CityPalette.Sample,
        date: Date,
        geometry: CityIsometricTitanGeometry,
        wake: Double,
        band: ZoomBand
    ) {
        let seconds = date.timeIntervalSinceReferenceDate
        // Ground patch first: as the head lifts off its slumped rest, its
        // shadow stays behind and deepens, which is what makes the
        // elevation read.
        let headContact = geometry.head.worldFootprint.map {
            CityWorldPoint3D(x: $0.x, y: $0.y, z: 0.02)
        }
        var headShadow = Path()
        if let first = headContact.first?.projected {
            headShadow.move(to: first)
            for point in headContact.dropFirst() {
                headShadow.addLine(to: point.projected)
            }
            headShadow.closeSubpath()
        }
        context.fill(headShadow, with: .color(Color.black.opacity(0.05 + 0.07 * wake)))
        // The neck fills the chest-to-head wedge as the head lifts; it
        // belongs to the live pose, so it draws with the head assembly.
        // Face plane tints: the head reads one shade lighter than the
        // body, and the neck sinks darker so head, face, and chest never
        // fuse into one mass.
        let headTint = Self.mixed(CalmCityStyle.lavender, CalmCityStyle.paper, 0.30)
        fillTitanFacets(
            context: &context,
            sample: sample,
            facets: geometry.neck.facets,
            tint: Self.mixed(CalmCityStyle.lavender, CalmCityStyle.ink, 0.30)
        )
        fillTitanFacets(context: &context, sample: sample, facets: geometry.head.facets, tint: headTint)
        fillTitanFacets(context: &context, sample: sample, facets: geometry.brow.facets, tint: headTint)
        // Face features are inlaid stone, not decals: dark solids slightly
        // proud of the face plane, so they hold a crisp edge at every zoom.
        let inlay = Self.mixed(CalmCityStyle.ink, CalmCityStyle.lavender, 0.22)
        fillTitanFacets(context: &context, sample: sample, facets: geometry.mouth.facets, tint: inlay)
        fillTitanFacets(context: &context, sample: sample, facets: geometry.eyeSlit.facets, tint: inlay)
        // Carve the sleep features: the closed eye slit, the mouth seam,
        // and the heavy brow overhang get ink outlines so the face reads as
        // chiseled stone whether the golem drowses or wakes.
        let featureInk = nightified(CalmCityStyle.ink, sample: sample)
        if let slitTop = geometry.eyeSlit.facets.first(where: { $0.light == .top }) {
            context.stroke(slitTop.path, with: .color(featureInk.opacity(0.60)), lineWidth: 0.75)
        }
        if let mouthTop = geometry.mouth.facets.first(where: { $0.light == .top }) {
            context.stroke(mouthTop.path, with: .color(featureInk.opacity(0.50)), lineWidth: 0.65)
        }
        if let browTop = geometry.brow.facets.first(where: { $0.light == .top }) {
            context.stroke(browTop.path, with: .color(featureInk.opacity(0.32)), lineWidth: 0.55)
        }
        if wake > 0.1 {
            let openness = min(1, (wake - 0.1) / 0.35)
            let gaze = CityTitanGaze.pupilOffset(
                seconds: seconds,
                wake: wake,
                reduceMotion: reduceMotion
            )
            let eyeCenter = Self.titanEyeGlowCenter(for: geometry)
            fillTitanFacets(context: &context, sample: sample, facets: geometry.eyeOpen.facets, tint: inlay)
            // The head lies on its cheek, so the sockets stack along the
            // world up axis: the pupil pair separates vertically and the
            // neck's ground-plane yaw never tilts that separation.
            let eyeOffset = geometry.eyeSocketOffset
            for side in [CGFloat(-1), CGFloat(1)] {
                let offset = CGPoint(x: gaze.x + side * eyeOffset.x, y: gaze.y + side * eyeOffset.y)
                let gazeCenter = CGPoint(x: eyeCenter.x + offset.x, y: eyeCenter.y + offset.y)
                if sample.night > 0.02 {
                    let glowRadius = 2.4 + 5.5 * openness
                    context.fill(
                        Path(ellipseIn: CGRect(
                            x: gazeCenter.x - glowRadius, y: gazeCenter.y - glowRadius,
                            width: glowRadius * 2, height: glowRadius * 2
                        )),
                        with: .radialGradient(
                            Gradient(colors: [
                                Color(red: 1, green: 0.72, blue: 0.35).opacity(0.50 * sample.night * openness),
                                .clear,
                            ]),
                            center: gazeCenter, startRadius: 0, endRadius: glowRadius
                        )
                    )
                }
                var gazeContext = context
                gazeContext.translateBy(x: offset.x, y: offset.y)
                fillTitanFacets(
                    context: &gazeContext, sample: sample, facets: geometry.pupil.facets,
                    tint: RGB(r: 235, g: 168, b: 82)
                )
            }
        }
        // A stone bridge divides the recessed eye strip into two sockets.
        fillTitanFacets(
            context: &context, sample: sample, facets: geometry.nose.facets,
            tint: headTint
        )
        // Zzz drifts up from the face while the cluster drowses.
        // No band gate: the golem reads as a province landmark, so its sleep
        // charms must survive the fully-zoomed-out view too.
        if wake < 0.3 {
            let footprint = geometry.head.worldFootprint
            let minX = footprint.map(\.x).min() ?? 0
            let maxX = footprint.map(\.x).max() ?? 0
            let minY = footprint.map(\.y).min() ?? 0
            let maxY = footprint.map(\.y).max() ?? 0
            let faceZ = geometry.head.baseZ + geometry.head.height + geometry.head.domePeak
            let drowse = (0.3 - wake) / 0.3
            for index in 0..<3 {
                // Snore glyphs freeze at a fixed drifting trail under
                // Reduce Motion: no idle oscillation, but the settled
                // sleep charm still reads identically at any timestamp.
                let cycle: CGFloat = reduceMotion
                    ? 0.18 + CGFloat(index) * 0.24
                    : CGFloat((seconds / 3.2 + Double(index) / 3)
                        .truncatingRemainder(dividingBy: 1))
                let opacity = (1 - cycle) * 0.78 * drowse
                guard opacity > 0.01 else { continue }
                let point = IsoProjection.project(
                    (minX + maxX) / 2 + CGFloat(cycle) * 1.7,
                    // The face is the head's camera-facing plane, so the
                    // glyphs rise off that side, not the back of the skull.
                    maxY - (maxY - minY) * 0.25,
                    faceZ + CGFloat(cycle) * 5.4
                )
                // World-unit size: scales with the camera like the titan
                // itself instead of shrinking as you zoom in.
                let size = 8 + 3.6 * cycle
                context.draw(
                    Text("z")
                        .font(.system(size: size, weight: .bold, design: .rounded))
                        .foregroundStyle(nightified(CalmCityStyle.ink, sample: sample).opacity(opacity)),
                    at: point,
                    anchor: .center
                )
            }
        }
    }



    /// Cluster-wide signals for the data-driven vignettes, computed once per
    /// overlay pass from the scape and the pending queue.
    struct ClusterVitals: Equatable, Sendable {
        /// Used / total allocatable GPUs; drain and unknown nodes still count
        /// as capacity, matching the density staging rule.
        var allocationFraction: Double = 0
        var runningJobs: Int = 0
        var pendingJobs: Int = 0
        var busiestPlotID: String?
        var busiestAnchor: CGPoint?
        var busiestJobPressure: Double = 0
    }

    static func clusterVitals(scape: CityScape, pendingCount: Int) -> ClusterVitals {
        var vitals = ClusterVitals(pendingJobs: pendingCount)
        var total = 0
        var used = 0
        var seen = Set<String>()
        var best: (anchor: CGPoint, jobs: Int, jobPressure: Double, plotID: String)?
        for plot in scape.plots {
            if seen.insert(plot.node.name).inserted {
                total += plot.node.totalGPUCount
                used += plot.node.totalGPUCount - plot.node.freeGPUCount
                vitals.runningJobs += plot.node.jobs.count
            }
            guard plot.mode == .lit || plot.mode == .half else { continue }
            let jobs = plot.node.jobs.count
            guard jobs > 0 else { continue }
            let jobPressure = CityWindows.runningJobPressure(for: plot.node)
            let anchor = CGPoint(x: plot.x + plot.w / 2, y: plot.y + plot.d / 2)
            if best == nil || jobs > best!.jobs || (jobs == best!.jobs && jobPressure > best!.jobPressure) {
                best = (anchor, jobs, jobPressure, plot.id)
            }
        }
        vitals.allocationFraction = total > 0 ? Double(used) / Double(total) : 0
        vitals.busiestPlotID = best?.plotID
        vitals.busiestAnchor = best?.anchor
        vitals.busiestJobPressure = best?.jobPressure ?? 0
        return vitals
    }

    /// Stylized far-rim mountains: flat screen-space prisms with split
    /// light/shadow faces, a jagged snow cap, and a haze mix toward the
    /// horizon so they read as distant scenery behind the town. Pure static
    /// geometry - the retained base stays byte-identical when jobs change.
    private func drawMountains(context: inout GraphicsContext, sample: CityPalette.Sample, visibleRect: CGRect) {
        let leftColor = Self.mixed(CalmCityStyle.lavender, CalmCityStyle.ink, 0.28)
        let rightColor = Self.mixed(CalmCityStyle.lavender, CalmCityStyle.paper, 0.38)
        let leftSnow = Self.mixed(CalmCityStyle.paper, CalmCityStyle.lavender, 0.10)
        let rightSnow = Self.mixed(CalmCityStyle.paper, CalmCityStyle.skyTop, 0.18)

        func point(from apex: CGPoint, toward base: CGPoint, amount: CGFloat) -> CGPoint {
            CGPoint(
                x: apex.x + (base.x - apex.x) * amount,
                y: apex.y + (base.y - apex.y) * amount
            )
        }

        // Atmospheric perspective: mountains sit on the far north/west rims,
        // so x+y is a stable depth proxy (smaller = farther from camera).
        // Farther massifs wash toward the horizon sky and lose outline
        // contrast; nearer ones stay saturated. Far-to-near paint order keeps
        // overlaps correct.
        let minDepth = staticPaths.mountains.first.map { $0.x + $0.y } ?? 0
        let maxDepth = staticPaths.mountains.last.map { $0.x + $0.y } ?? 0
        let depthSpan = max(maxDepth - minDepth, 0.001)
        let horizon = Self.mixed(
            CalmCityStyle.skyHorizon,
            CalmCityStyle.skyTop,
            0.35
        )
        for mountain in staticPaths.mountains {
            let haze = 0.15 + 0.5 * (
                1 - (mountain.x + mountain.y - minDepth) / depthSpan
            )
            let geometry = mountain.geometry
            guard visibleRect.insetBy(
                dx: -24,
                dy: -24
            ).intersects(mountain.projectedBounds) else {
                continue
            }

            context.fill(
                mountain.foothillSkirt,
                with: .color(nightified(
                    Self.mixed(
                        CalmCityStyle.spruce,
                        CalmCityStyle.lavender,
                        0.45
                    ),
                    sample: sample
                ))
            )

            // One massif = jagged faces + summit ridge + snow cap; the loop
            // below draws a smaller companion peak behind the main one so
            // clusters read as multi-summit ranges instead of lone pyramids.
            func drawMassif(_ geometry: CityMountainGeometry) {
                func flank(_ shoulders: [CGPoint], corner: CGPoint) -> Path {
                    var path = Path()
                    path.move(to: geometry.apex)
                    for shoulder in shoulders { path.addLine(to: shoulder) }
                    path.addLine(to: corner)
                    path.addLine(to: geometry.near)
                    path.closeSubpath()
                    return path
                }
                let leftFace = flank(geometry.leftShoulders, corner: geometry.left)
                let rightFace = flank(geometry.rightShoulders, corner: geometry.right)
                // Faces shade from lit summit to grounded base with a
                // gradient: depth comes from value falloff instead of a
                // pasted shade wedge.
                let leftBaseMid = CGPoint(
                    x: (geometry.left.x + geometry.near.x) / 2,
                    y: (geometry.left.y + geometry.near.y) / 2
                )
                let rightBaseMid = CGPoint(
                    x: (geometry.right.x + geometry.near.x) / 2,
                    y: (geometry.right.y + geometry.near.y) / 2
                )
                let leftTop = nightified(Self.mixed(leftColor, horizon, haze), sample: sample)
                let leftBottom = nightified(
                    Self.mixed(Self.mixed(leftColor, CalmCityStyle.ink, 0.30), horizon, haze),
                    sample: sample
                )
                let rightTop = nightified(Self.mixed(rightColor, horizon, haze), sample: sample)
                let rightBottom = nightified(
                    Self.mixed(Self.mixed(rightColor, CalmCityStyle.ink, 0.16), horizon, haze),
                    sample: sample
                )
                context.fill(
                    leftFace,
                    with: .linearGradient(
                        Gradient(colors: [leftTop, leftBottom]),
                        startPoint: geometry.apex,
                        endPoint: leftBaseMid
                    )
                )
                context.fill(
                    rightFace,
                    with: .linearGradient(
                        Gradient(colors: [rightTop, rightBottom]),
                        startPoint: geometry.apex,
                        endPoint: rightBaseMid
                    )
                )
                // Jagged snow cap: notch points pushed further down-slope
                // break the cap's lower edge so it reads as wind-carved snow
                // rather than two pasted triangles.
                let capAmount: CGFloat = 0.30
                let capLeft = point(from: geometry.apex, toward: geometry.left, amount: capAmount * 1.08)
                let capNear = point(from: geometry.apex, toward: geometry.near, amount: capAmount * 0.92)
                let capRight = point(from: geometry.apex, toward: geometry.right, amount: capAmount)
                func notch(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
                    let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                    return CGPoint(
                        x: mid.x + (mid.x - geometry.apex.x) * 0.42,
                        y: mid.y + (mid.y - geometry.apex.y) * 0.42
                    )
                }
                var leftCap = Path()
                leftCap.move(to: geometry.apex)
                leftCap.addLine(to: capNear)
                leftCap.addLine(to: notch(capNear, capLeft))
                leftCap.addLine(to: capLeft)
                leftCap.closeSubpath()
                var rightCap = Path()
                rightCap.move(to: geometry.apex)
                rightCap.addLine(to: capRight)
                rightCap.addLine(to: notch(capRight, capNear))
                rightCap.addLine(to: capNear)
                rightCap.closeSubpath()
                context.fill(
                    leftCap,
                    with: .color(nightified(Self.mixed(leftSnow, horizon, haze * 0.6), sample: sample, attenuation: 0.72))
                )
                context.fill(
                    rightCap,
                    with: .color(nightified(Self.mixed(rightSnow, horizon, haze * 0.6), sample: sample, attenuation: 0.72))
                )
            }

            // The companion summit is retained with the static scene.
            drawMassif(mountain.companionGeometry)
            drawMassif(geometry)
            // Darker base band grounds each massif against the terrain.
            let bandLeft = point(from: geometry.apex, toward: geometry.left, amount: 0.72)
            let bandNear = point(from: geometry.apex, toward: geometry.near, amount: 0.72)
            let bandRight = point(from: geometry.apex, toward: geometry.right, amount: 0.72)
            var band = Path()
            band.move(to: bandLeft)
            band.addLine(to: bandNear)
            band.addLine(to: bandRight)
            band.addLine(to: geometry.right)
            band.addLine(to: geometry.near)
            band.addLine(to: geometry.left)
            band.closeSubpath()
            context.fill(band, with: .color(nightified(CalmCityStyle.ink, sample: sample).opacity(0.08 * Double(1 - haze))))
        }
    }

    private func drawCityDetail(
        context: inout GraphicsContext,
        staticPaths: CitySceneStaticPaths,
        plan: CityRenderPlan,
        sample: CityPalette.Sample
    ) {
        let asphalt = surfaceColor(day: RGB(r: 150, g: 142, b: 178), night: RGB(r: 44, g: 38, b: 70), sample: sample)
        let laneMarkingOpacity = plan.band == .province ? 0.45 : 0.85
        for (street, laneMarkings) in zip(staticPaths.localStreets, staticPaths.laneMarkings) where street.bounds.intersects(plan.visibleRect) {
            context.stroke(street.path, with: .color(asphalt), lineWidth: 5.0)
            if laneMarkingOpacity > 0 {
                context.stroke(
                    laneMarkings.path,
                    with: .color(Color(red: 1, green: 0.78, blue: 0.22).opacity(laneMarkingOpacity)),
                    style: StrokeStyle(lineWidth: 0.9, dash: [7.2, 4.2])
                )
            }
        }
        // Manhole dots at street midpoints: the smallest street-furniture
        // mark, only worth its ink at street zoom.
        if plan.band == .street {
            let manholeInk = nightified(CalmCityStyle.ink, sample: sample).opacity(0.16)
            for street in scape.localStreets where street.count > 1 {
                for index in 0..<(street.count - 1) {
                    let a = street[index], b = street[index + 1]
                    let mid = IsoProjection.project((a.0 + b.0) / 2, (a.1 + b.1) / 2, 0.04)
                    guard plan.visibleRect.contains(mid) else { continue }
                    context.fill(
                        Path(ellipseIn: CGRect(x: mid.x - 1.1, y: mid.y - 0.55, width: 2.2, height: 1.1)),
                        with: .color(manholeInk)
                    )
                }
            }
        }
    }

    /// Sidewalk furniture for the street band: benches and planters alternate
    /// along the local-street sidewalks, hydrants hug intersection corners,
    /// and mailboxes stand at every second plot corner. Placement derives only
    /// from world geometry (streets, plots, lamps) so the set is stable
    /// regardless of job data. Drawn from the depth-sorted pass so props in
    /// front of a plot podium paint over it instead of being buried.
    private func drawStreetProp(
        context: inout GraphicsContext,
        prop: CityPlacementPlan.Prop,
        sample: CityPalette.Sample
    ) {
        // Props hidden behind a building silhouette are skipped like lamp
        // fixtures and pedestrians: probe the piece's tallest point.
        func isVisible(_ point: (CGFloat, CGFloat), topZ: CGFloat) -> Bool {
            !occlusionField.isHidden(worldX: point.0, worldY: point.1, z: topZ)
        }
        let point = (prop.x, prop.y)
        switch prop.kind {
        case let .bench(alongX, rearX, rearY):
            guard isVisible(point, topZ: 0.35) else { return }
            drawStreetPropBench(context: &context, x: prop.x, y: prop.y, alongX: alongX, rearX: rearX, rearY: rearY, sample: sample)
        case let .planter(seed):
            guard isVisible(point, topZ: 0.35) else { return }
            drawStreetPropPlanter(context: &context, x: prop.x, y: prop.y, seed: seed, sample: sample)
        case .hydrant:
            guard isVisible(point, topZ: 0.35) else { return }
            drawStreetPropHydrant(context: &context, x: prop.x, y: prop.y, sample: sample)
        case .mailbox:
            guard isVisible(point, topZ: 0.7) else { return }
            drawStreetPropMailbox(context: &context, x: prop.x, y: prop.y, sample: sample)
        }
    }
    /// Tiny ink contact shadow: world radii mapped through the iso scale so
    /// the ellipse hugs the prop footprint at every zoom.
    private func streetPropShadow(
        context: inout GraphicsContext,
        x: CGFloat, y: CGFloat,
        worldRX: CGFloat, worldRY: CGFloat,
        sample: CityPalette.Sample
    ) {
        let center = IsoProjection.project(x, y, 0.01)
        let radiusX = worldRX * IsoProjection.s, radiusY = worldRY * IsoProjection.fy
        context.fill(
            Path(ellipseIn: CGRect(x: center.x - radiusX, y: center.y - radiusY, width: radiusX * 2, height: radiusY * 2)),
            with: .color(nightified(CalmCityStyle.ink, sample: sample, attenuation: 0.8).opacity(0.12))
        )
    }

    /// Wood-slat bench facing the road: a seat box on two stubby legs with a
    /// back slat standing at the edge away from the asphalt.
    private func drawStreetPropBench(
        context: inout GraphicsContext,
        x: CGFloat, y: CGFloat,
        alongX: Bool,
        rearX: CGFloat, rearY: CGFloat,
        sample: CityPalette.Sample
    ) {
        let wood = Self.mixed(CalmCityStyle.marigold, CalmCityStyle.soilTop, 0.45)
        let leg = nightified(Self.mixed(wood, CalmCityStyle.ink, 0.3), sample: sample, attenuation: 0.8)
        let top = nightified(wood, sample: sample, attenuation: 0.8)
        let se = nightified(Self.mixed(wood, CalmCityStyle.ink, 0.22), sample: sample, attenuation: 0.8)
        let sw = nightified(Self.mixed(wood, CalmCityStyle.ink, 0.34), sample: sample, attenuation: 0.8)
        streetPropShadow(context: &context, x: x, y: y, worldRX: 0.6, worldRY: 0.25, sample: sample)
        let halfLength: CGFloat = 0.5, halfDepth: CGFloat = 0.175, legSize: CGFloat = 0.08
        for end in [-1 as CGFloat, 1] {
            let legX = alongX ? x + end * (halfLength - 0.06 - legSize) : x - legSize / 2
            let legY = alongX ? y - legSize / 2 : y + end * (halfLength - 0.06 - legSize)
            box(context: &context, x: legX, y: legY, w: legSize, d: legSize, h: 0.28, top: leg, se: leg, sw: leg)
        }
        box(
            context: &context,
            x: alongX ? x - halfLength : x - halfDepth,
            y: alongX ? y - halfDepth : y - halfLength,
            w: alongX ? halfLength * 2 : halfDepth * 2,
            d: alongX ? halfDepth * 2 : halfLength * 2,
            h: 0.40, z0: 0.28, top: top, se: se, sw: sw
        )
        let backCenterX = x + rearX * (halfDepth - 0.05), backCenterY = y + rearY * (halfDepth - 0.05)
        box(
            context: &context,
            x: alongX ? backCenterX - halfLength : backCenterX - 0.05,
            y: alongX ? backCenterY - 0.05 : backCenterY - halfLength,
            w: alongX ? halfLength * 2 : 0.1,
            d: alongX ? 0.1 : halfLength * 2,
            h: 0.75, z0: 0.40, top: top, se: se, sw: sw
        )
    }

    /// Paper-tone planter tub with tiny leaf tufts and a single blossom dot;
    /// tuft offsets derive from the placement hash so each pot differs.
    private func drawStreetPropPlanter(
        context: inout GraphicsContext,
        x: CGFloat, y: CGFloat,
        seed: Int,
        sample: CityPalette.Sample
    ) {
        let tub = Self.mixed(CalmCityStyle.paper, CalmCityStyle.marigold, 0.3)
        let top = nightified(tub, sample: sample, attenuation: 0.8)
        let se = nightified(Self.mixed(tub, CalmCityStyle.ink, 0.22), sample: sample, attenuation: 0.8)
        let sw = nightified(Self.mixed(tub, CalmCityStyle.ink, 0.34), sample: sample, attenuation: 0.8)
        streetPropShadow(context: &context, x: x, y: y, worldRX: 0.3, worldRY: 0.2, sample: sample)
        box(context: &context, x: x - 0.225, y: y - 0.225, w: 0.45, d: 0.45, h: 0.35, top: top, se: se, sw: sw)
        let leaf = nightified(CalmCityStyle.leaf, sample: sample, attenuation: 0.8)
        let leafDeep = nightified(CalmCityStyle.leafDeep, sample: sample, attenuation: 0.8)
        for tuft in 0..<3 {
            let dx = (CGFloat((seed >> (tuft * 5)) % 13) / 13 - 0.5) * 0.24
            let dy = (CGFloat((seed >> (tuft * 5 + 7)) % 11) / 11 - 0.5) * 0.24
            let z = 0.5 + CGFloat((seed >> (tuft * 3 + 12)) % 5) / 5 * 0.2
            let point = IsoProjection.project(x + dx, y + dy, z)
            context.fill(
                Path(ellipseIn: CGRect(x: point.x - 0.8, y: point.y - 0.45, width: 1.6, height: 0.9)),
                with: .color(tuft % 2 == 0 ? leaf : leafDeep)
            )
        }
        let bloom = IsoProjection.project(x, y, 0.68)
        context.fill(
            Path(ellipseIn: CGRect(x: bloom.x - 0.5, y: bloom.y - 0.5, width: 1, height: 1)),
            with: .color(nightified(CalmCityStyle.blossom, sample: sample, attenuation: 0.8))
        )
    }

    /// Coral hydrant: a small voxel body with a dome cap and two side nubs.
    private func drawStreetPropHydrant(
        context: inout GraphicsContext,
        x: CGFloat, y: CGFloat,
        sample: CityPalette.Sample
    ) {
        let coral = Self.mixed(CalmCityStyle.coral, CalmCityStyle.ink, 0.1)
        let top = nightified(Self.mixed(CalmCityStyle.coral, CalmCityStyle.paper, 0.2), sample: sample, attenuation: 0.8)
        let body = nightified(coral, sample: sample, attenuation: 0.8)
        let se = nightified(Self.mixed(coral, CalmCityStyle.ink, 0.25), sample: sample, attenuation: 0.8)
        let sw = nightified(Self.mixed(coral, CalmCityStyle.ink, 0.38), sample: sample, attenuation: 0.8)
        streetPropShadow(context: &context, x: x, y: y, worldRX: 0.16, worldRY: 0.12, sample: sample)
        box(context: &context, x: x - 0.11, y: y - 0.11, w: 0.22, d: 0.22, h: 0.5, top: body, se: se, sw: sw)
        box(context: &context, x: x - 0.07, y: y - 0.07, w: 0.14, d: 0.14, h: 0.62, z0: 0.5, top: top, se: se, sw: sw)
        box(context: &context, x: x + 0.11, y: y - 0.03, w: 0.06, d: 0.06, h: 0.36, z0: 0.28, top: top, se: se, sw: sw)
        box(context: &context, x: x - 0.03, y: y + 0.11, w: 0.06, d: 0.06, h: 0.36, z0: 0.28, top: top, se: se, sw: sw)
    }

    /// Water-blue mailbox on a dark ink-blue post with a tiny paper flag.
    private func drawStreetPropMailbox(
        context: inout GraphicsContext,
        x: CGFloat, y: CGFloat,
        sample: CityPalette.Sample
    ) {
        let post = nightified(Self.mixed(CalmCityStyle.ink, CalmCityStyle.water, 0.2), sample: sample, attenuation: 0.8)
        let top = nightified(CalmCityStyle.water, sample: sample, attenuation: 0.8)
        let se = nightified(Self.mixed(CalmCityStyle.water, CalmCityStyle.ink, 0.22), sample: sample, attenuation: 0.8)
        let sw = nightified(Self.mixed(CalmCityStyle.water, CalmCityStyle.ink, 0.34), sample: sample, attenuation: 0.8)
        let flag = nightified(CalmCityStyle.paper, sample: sample, attenuation: 0.8)
        streetPropShadow(context: &context, x: x, y: y, worldRX: 0.15, worldRY: 0.1, sample: sample)
        box(context: &context, x: x - 0.035, y: y - 0.035, w: 0.07, d: 0.07, h: 0.55, top: post, se: post, sw: post)
        box(context: &context, x: x - 0.17, y: y - 0.12, w: 0.34, d: 0.24, h: 0.79, z0: 0.55, top: top, se: se, sw: sw)
        box(context: &context, x: x + 0.15, y: y - 0.015, w: 0.03, d: 0.03, h: 0.93, z0: 0.79, top: flag, se: flag, sw: flag)
        box(context: &context, x: x + 0.15, y: y - 0.015, w: 0.11, d: 0.03, h: 0.95, z0: 0.92, top: flag, se: flag, sw: flag)
    }

    /// Ground-hung telemetry ink. The candy ground plane is bright cream and
    /// meadow green by day and plum-dark at night, so signage keeps one white
    /// ink and relies on the sticker shadow drawn by `drawTelemetry` to stay
    /// legible against both extremes.
    static func telemetryInk(opacity: Double) -> Color {
        .white.opacity(opacity)
    }

    private func drawLabels(
        context: inout GraphicsContext,
        overlayContext: inout GraphicsContext,
        plots: [CityPlot],
        scale: CGFloat,
        date: Date,
        camera: CityCamera,
        band: ZoomBand,
        palette: AppPalette,
        visibleRect: CGRect,
        exclusionRect: CGRect? = nil,
        hoveredPlotID: String? = nil
    ) {
        var activityLabels: [String: String?] = [:]
        let labels = plots.enumerated().map { index, plot in
            let activity = activityLabels[plot.node.name] ?? gpuActivityLabel(nodeName: plot.node.name, at: date)
            activityLabels[plot.node.name] = activity
            return (index: index, activity: activity,
                    rect: labelGroupRect(for: plot, band: band, camera: camera, activity: activity))
        }
        let labelRects = labels.map(\.rect)
            .filter { rect in exclusionRect.map { !$0.intersects(rect) } ?? true }
        var accepted = Self.nonOverlappingLabelRects(labelRects)
        // Labels whose anchor sits well outside the viewport belong to a plot
        // that is only clipped in by a corner; skip them so they never hover
        // over unrelated neighboring geometry.
        let labelCullRect = visibleRect.insetBy(dx: -110, dy: -150)
        var telemetryNodes = Set<String>()
        for label in labels {
            let plot = plots[label.index]
            guard let index = accepted.firstIndex(of: label.rect) else { continue }
            accepted.remove(at: index)
            let plateOpacity = nodeLabelOpacity(scale: scale)
            let sign = labelAnchor(for: plot)
            guard labelCullRect.contains(sign) else { continue }
            let jobLineCount = band == .street ? Self.jobPlateLines(node: plot.node).count : 0
            if plateOpacity > 0 {
                drawPlate(context: &overlayContext, plot: plot, camera: camera, at: sign, statusOffset: 12 + CGFloat(jobLineCount) * 10, hovered: plot.id == hoveredPlotID, opacity: plateOpacity, palette: palette)
                // One measured cue per visible node, never per inferred GPU plot.
                if let activity = label.activity, telemetryNodes.insert(plot.node.name).inserted {
                    drawTelemetry(
                        context: &overlayContext, camera: camera,
                        activity,
                        at: sign, offset: CGSize(width: 0, height: 24 + CGFloat(jobLineCount) * 10),
                        font: .caption2.monospaced().weight(.semibold),
                        color: Self.telemetryInk(opacity: plateOpacity),
                        anchor: .top, shadowOpacity: plateOpacity
                    )
                }
            }
            let label = Self.hardwareSignText(gpuIndex: plot.gpuIndex, gpuCount: plot.gpuCount, gpuType: plot.node.gpuType, vramGB: plot.node.vramGB)
            drawTelemetry(context: &overlayContext, camera: camera, label, at: sign, font: .caption2.monospaced().weight(.semibold), color: Self.telemetryInk(opacity: citySignageOpacity(scale: scale)), anchor: .top, shadowOpacity: citySignageOpacity(scale: scale))
            if band == .street {
                for (lineIndex, line) in Self.jobPlateLines(node: plot.node).enumerated() {
                    drawTelemetry(context: &overlayContext, camera: camera, line, at: sign, offset: CGSize(width: 0, height: 10 + CGFloat(lineIndex) * 10), font: .caption2.monospaced(), color: Self.telemetryInk(opacity: 0.55), anchor: .top, shadowOpacity: 0.55)
                }
            }
        }
    }

    /// Node name, hardware, optional job rows, scheduler status, and a
    /// separate measured node-GPU row share one screen-space collision box.
    /// Ground anchor for a plot's label group. The anchor rides the plot's
    /// tallest revealed pavilion so signage sits beside real mass instead of
    /// floating over the empty apron/mottle in front of the plot.
    private func labelAnchor(for plot: CityPlot) -> CGPoint {
        let pavilions = visiblePavilions(for: plot)
        if let tallest = pavilions.max(by: { $0.h < $1.h }) {
            return IsoProjection.project(
                plot.x + tallest.ox + tallest.bw / 2,
                plot.y + tallest.oy + tallest.bd + 0.8,
                1
            )
        }
        return IsoProjection.project(plot.x + plot.w / 2, plot.y + plot.d + 0.8, 1)
    }

    /// Fixed-size text requires screen-space collision bounds at every zoom.
    private func labelGroupRect(for plot: CityPlot, band: ZoomBand, camera: CityCamera, activity: String?) -> CGRect {
        let sign = camera.apply(labelAnchor(for: plot))
        let jobLineCount = band == .street ? Self.jobPlateLines(node: plot.node).count : 0
        let lines = [
            plotLabel(for: plot),
            Self.hardwareSignText(gpuIndex: plot.gpuIndex, gpuCount: plot.gpuCount, gpuType: plot.node.gpuType, vramGB: plot.node.vramGB),
            plot.node.stateLabel,
            activity ?? "",
        ] + (band == .street ? Self.jobPlateLines(node: plot.node) : [])
        let width = CGFloat(lines.map(\.count).max() ?? 0) * 7 + 4
        let minY = sign.y - 14
        let maxY = sign.y + 24 + CGFloat(jobLineCount) * 10 + 12
        return CGRect(x: sign.x - width / 2, y: minY, width: width, height: maxY - minY)
    }

    /// One measured row per node. A retained older reading is still shown,
    /// carrying its age so it cannot be mistaken for current; with no usable
    /// reading the row is omitted rather than printing "unknown" everywhere.
    private func gpuActivityLabel(nodeName: String, at date: Date) -> String? {
        guard let node = gpuTelemetry.nodes[nodeName],
              let value = node.utilizationPercent,
              let sampledAt = gpuTelemetry.sampledAt else {
            return nil
        }
        let coverage = node.isPartial ? " · partial" : ""
        switch gpuTelemetry.freshness(at: date) {
        case .unavailable:
            return nil
        case .stale:
            return "GPU \(Int(value.rounded()))%\(coverage) · \(GPUTelemetrySummaryView.ageText(sampledAt: sampledAt, now: date))"
        case .fresh:
            return "GPU \(Int(value.rounded()))%\(coverage)"
        }
    }

    private func drawSmoke(context: inout GraphicsContext, plot: CityPlot, building: BuildingSpec, windowFill: Double, date: Date, scale: CGFloat) {
        var stackLift: CGFloat = 0, stackDX: CGFloat = 0, stackDY: CGFloat = 0
        for fixture in building.fixtures { if case let .smokestack(dx, dy) = fixture { stackLift = 1.5; stackDX = dx; stackDY = dy } }
        for puff in CityWhimsy.smokePuffs(plotID: plot.id, plotOrigin: CGPoint(x: plot.x, y: plot.y), building: building, load: windowFill, date: date, reduceMotion: reduceMotion) {
            let point = IsoProjection.project(puff.x + stackDX, puff.y + stackDY, puff.z + stackLift)
            let radius = puff.radius * scale
            context.fill(Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)), with: .color(Color(white: 0.85).opacity(puff.opacity * 0.5)))
        }
    }



    private func drawHoverTooltip(
        context: inout GraphicsContext,
        point: CGPoint?,
        plotID: String?,
        scape: CityScape,
        band: ZoomBand,
        size: CGSize
    ) {
        guard let point,
              let plotID,
              let plot = scape.plots.first(where: { $0.id == plotID }) else { return }
        let text = band == .province
            ? "\(plot.node.name) · \(plot.node.jobs.count { $0.state == "RUNNING" }) running · \(plot.node.freeInText)"
            : plot.gpuCount > 1
                ? "\(plot.node.name) · GPU \(plot.gpuIndex) of \(plot.gpuCount) · \(CalmCityStyle.buildingState(for: plot).rawValue)"
                : "\(plot.node.name) · \(CalmCityStyle.buildingState(for: plot).rawValue)"
        let resolved = context.resolve(Text(text).font(.caption2.monospaced().weight(.semibold)).foregroundStyle(CityTooltipStyle.foreground.color))
        let measured = resolved.measure(in: CGSize(width: size.width - 8, height: size.height))
        let plate = CityTooltipLayout.plate(
            preferredSize: CGSize(width: measured.width + 14, height: max(22, measured.height + 8)),
            anchoredAt: point,
            canvasSize: size
        )
        context.fill(Path(roundedRect: plate, cornerRadius: 5), with: .color(CalmCityStyle.ink.color.opacity(0.94)))
        context.draw(resolved, at: CGPoint(x: plate.minX + 7, y: plate.midY), anchor: .leading)
    }

    private func drawSelectionOutline(context: inout GraphicsContext, plot: CityPlot) {
        let corners = [
            IsoProjection.project(plot.x, plot.y, 0.06),
            IsoProjection.project(plot.x + plot.w, plot.y, 0.06),
            IsoProjection.project(plot.x + plot.w, plot.y + plot.d, 0.06),
            IsoProjection.project(plot.x, plot.y + plot.d, 0.06),
        ]
        let outline = corners + [corners[0]]
        stroke(context: &context, outline, color: CalmCityStyle.ink.color.opacity(0.95), width: 4)
        stroke(context: &context, outline, color: CalmCityStyle.paper.color, width: 1.8)
    }

    private func drawCitizenBubble(
        context: inout GraphicsContext,
        plot: CityPlot,
        citizenIndex: Int,
        text: String,
        shownAt: Date,
        date: Date,
        camera: CityCamera,
        size: CGSize
    ) {
        let opacity = CityBubbleTiming.opacity(shownAt: shownAt, now: date)
        guard opacity > 0 else { return }
        let citizen = citizenWorldPosition(plot: plot, index: citizenIndex, date: date)
        let anchor = camera.apply(IsoProjection.project(citizen.x, citizen.y, 1.8))
        let resolved = context.resolve(Text(text).font(.caption2.monospaced().weight(.semibold)).foregroundStyle(.white))
        let measured = resolved.measure(in: CGSize(width: size.width - 8, height: size.height))
        let plate = CityTooltipLayout.plate(
            preferredSize: CGSize(width: measured.width + 14, height: max(22, measured.height + 8)),
            anchoredAt: anchor,
            canvasSize: size
        )
        context.fill(Path(roundedRect: plate, cornerRadius: 5), with: .color(CalmCityStyle.ink.color.opacity(0.94 * opacity)))
        let tailBase = CGPoint(x: min(max(plate.minX + 8, anchor.x), plate.maxX - 8), y: plate.maxY)
        var tail = Path()
        tail.move(to: CGPoint(x: tailBase.x - 4, y: tailBase.y))
        tail.addLine(to: CGPoint(x: tailBase.x + 4, y: tailBase.y))
        tail.addLine(to: anchor)
        tail.closeSubpath()
        context.fill(tail, with: .color(CalmCityStyle.ink.color.opacity(0.94 * opacity)))
        context.opacity = opacity
        context.draw(resolved, at: CGPoint(x: plate.minX + 7, y: plate.midY), anchor: .leading)
        context.opacity = 1
    }

    private func drawZoomBandBadge(context: inout GraphicsContext, size: CGSize, band: ZoomBand, phase: String) {
        let name: String = switch band {
        case .province: "PROVINCE"
        case .city: "CITY"
        case .street: "STREET"
        }
        let hint = band == .province ? " · scroll or ⊕ to zoom" : ""
        drawText(
            context: &context,
            "\(name) · \(phase)\(hint)",
            at: CGPoint(x: 12, y: size.height - 14),
            font: .caption2.monospaced().weight(.bold),
            color: .white.opacity(band == .province ? 0.36 : 0.5),
            anchor: .bottomLeading
        )
    }




    private func drawOcclusionAwareBlob(
        context: inout GraphicsContext,
        worldX: CGFloat,
        worldY: CGFloat,
        at point: CGPoint,
        key: String,
        heading: CGSize,
        date: Date,
        sample: CityPalette.Sample,
        opacity: Double = 1
    ) {
        guard let mask = occlusionField.punchMask(
            worldX: worldX,
            worldY: worldY,
            spriteBounds: Self.humanSpriteBounds(at: point)
        ) else {
            drawBlob(
                context: &context,
                at: point,
                key: key,
                heading: heading,
                date: date,
                sample: sample,
                opacity: opacity
            )
            return
        }

        context.drawLayer { layer in
            drawBlob(
                context: &layer,
                at: point,
                key: key,
                heading: heading,
                date: date,
                sample: sample,
                opacity: opacity
            )
            layer.blendMode = .destinationOut
            layer.fill(mask, with: .color(.black))
        }
    }

    private func drawBlob(
        context: inout GraphicsContext,
        at point: CGPoint,
        key: String,
        heading: CGSize,
        date: Date,
        sample: CityPalette.Sample,
        opacity: Double = 1
    ) {
        guard opacity > 0 else { return }
        let hash = stableByteHash(key)
        let blink = !reduceMotion
            && (date.timeIntervalSinceReferenceDate + Double(hash % 97) / 9)
                .truncatingRemainder(dividingBy: 3.8) < 0.12
        let heightScale: CGFloat = blink ? 0.90 : 1
        let shirt = [
            Color(red: 1, green: 0.31, blue: 0.63),
            Color(red: 0.30, green: 0.52, blue: 0.95),
            Color(red: 1, green: 0.82, blue: 0.25),
            Color(red: 0.45, green: 0.78, blue: 0.35),
            Color(red: 1, green: 0.55, blue: 0.20),
        ][(hash & Int.max) % 5]
        let ink = Self.outlineInk
        let skin = Color(red: 0.99, green: 0.80, blue: 0.62)
        let hair = Color(red: 0.16, green: 0.12, blue: 0.10)
        _ = sample
        var figureContext = context
        figureContext.opacity *= opacity
        if CityRenderPolicies.shouldMirrorBlob(heading: heading) {
            figureContext.concatenate(CGAffineTransform(translationX: point.x, y: 0).scaledBy(x: -1, y: 1).translatedBy(x: -point.x, y: 0))
        }
        figureContext.fill(
            Path(ellipseIn: CGRect(x: point.x - 0.27, y: point.y - 0.10, width: 0.54, height: 0.20)),
            with: .color(.black.opacity(0.30))
        )
        let bodyHeight = Self.humanWorldHeight * 0.625 * heightScale
        let headHeight = Self.humanWorldHeight * 0.375 * heightScale
        drawOutlinedVoxelBox(
            context: &figureContext, at: point, w: 0.28, d: 0.24, h: bodyHeight, z0: 0,
            top: shirt, se: shirt.opacity(0.75), sw: shirt.opacity(0.58), ink: ink
        )
        drawOutlinedVoxelBox(
            context: &figureContext, at: point, w: 0.19, d: 0.19, h: headHeight, z0: bodyHeight,
            top: hair, se: skin.opacity(0.86), sw: skin.opacity(0.72), ink: ink
        )
    }



    /// Bipedal kaiju assembled from tapered world solids: broad haunches over
    /// bent knees, a hip mass leaning forward into a raised ribcage, a pale
    /// belly slung beneath it, short folded arms, a dorsal crest that grows
    /// from the tail tip to the shoulders, and a browed skull with a tapering
    /// muzzle over a dark maw. Parts paint in world-depth order, so the
    /// silhouette reads the same whichever way the creature patrols.
    private func drawKaiju(
        context: inout GraphicsContext,
        pose: CityWhimsy.KaijuPose,
        sample: CityPalette.Sample,
        detail: CityCreatureDetail
    ) {
        let heading = pose.heading >= 0 ? CGFloat(1) : -1
        let forward = CGVector(dx: heading, dy: 0)
        let attenuation = detail == .silhouette ? 0.52 : 0.58
        let bodyBase = detail == .silhouette
            ? Self.mixed(CalmCityStyle.spruce, CalmCityStyle.ink, 0.54)
            : Self.mixed(CalmCityStyle.spruce, CalmCityStyle.leaf, 0.56)
        func tone(
            _ base: RGB,
            deepen: Double = 0
        ) -> (top: RGB, left: RGB, right: RGB) {
            CityPalette.faceColors(
                base: base,
                sample: sample,
                nightAttenuation: attenuation + deepen
            )
        }
        let bodyFaces = tone(bodyBase)
        let hideFaces = tone(Self.mixed(bodyBase, CalmCityStyle.ink, 0.14))
        let tailFaces = tone(Self.mixed(bodyBase, CalmCityStyle.ink, 0.22))
        let bellyFaces = tone(Self.mixed(bodyBase, CalmCityStyle.paper, 0.38))
        let scuteFaces = tone(
            Self.mixed(Self.mixed(bodyBase, CalmCityStyle.paper, 0.60), CalmCityStyle.marigold, 0.14),
            deepen: 0.10
        )
        let headFaces = tone(Self.mixed(bodyBase, CalmCityStyle.paper, 0.10))
        let jawFaces = tone(Self.mixed(bodyBase, CalmCityStyle.ink, 0.28), deepen: 0.18)
        let mawFaces = tone(Self.mixed(CalmCityStyle.ink, CalmCityStyle.coral, 0.22), deepen: 0.10)
        let boneFaces = tone(Self.mixed(CalmCityStyle.paper, CalmCityStyle.marigold, 0.14), deepen: 0.12)
        let eyeFaces = tone(CalmCityStyle.paper, deepen: 0.20)
        let pupilFaces = tone(CalmCityStyle.ink)
        let plateFaces = CityPalette.faceColors(
            base: Self.mixed(CalmCityStyle.marigold, CalmCityStyle.paper, Double(pose.roar) * 0.3),
            sample: sample,
            nightAttenuation: detail == .silhouette ? 0.38 : 0.48
        )
        let rig = CityActorFootprints.kaiju(
            center: CGPoint(x: pose.x, y: pose.y),
            heading: heading,
            bob: pose.bob,
            step: pose.step,
            tailPhase: pose.tailPhase,
            jawDrop: pose.jawDrop,
            headRear: pose.headRear,
            liveliness: pose.liveliness,
            stride: pose.stride,
            sway: pose.sway
        )

        let shadowCenter = IsoProjection.project(pose.x, pose.y, 0.02)
        context.fill(
            Path(ellipseIn: CGRect(
                x: shadowCenter.x - 20,
                y: shadowCenter.y - 6,
                width: 40,
                height: 12
            )),
            with: .color(
                nightified(CalmCityStyle.ink, sample: sample)
                    .opacity(CityCreatureGeometry.Kaiju.shadowOpacity)
            )
        )

        // Stomp dust: a puff blooms at each foot right after it lands.
        if detail != .silhouette {
            for (index, foot) in rig.feet.enumerated() {
                let landPhase: CGFloat = index == 0 ? 0.5 : 0.0
                let rawAge = (pose.step - landPhase).truncatingRemainder(dividingBy: 1)
                let age = rawAge < 0 ? rawAge + 1 : rawAge
                guard age < 0.18 else { continue }
                let t = age / 0.18
                let puffCenter = IsoProjection.project(
                    foot.center.x + heading * 1.4,
                    foot.center.y,
                    0.08
                )
                let radius = 1.2 + t * 3.4
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: puffCenter.x - radius,
                        y: puffCenter.y - radius * 0.55,
                        width: radius * 2,
                        height: radius * 1.1
                    )),
                    with: .color(
                        nightified(CalmCityStyle.paper, sample: sample, attenuation: 0.18)
                            .opacity(Double(1 - t) * 0.35 * Double(pose.liveliness))
                    )
                )
            }
        }

        /// Paints an actor solid as a lofted prism: the rounded lower ring
        /// at `lowerZ` skews into the rounded upper ring at `upperZ`, so a
        /// leaning limb reads as a diagonal slab with a visible knee joint
        /// instead of a vertical column. Solids without an upper ring
        /// extrude straight up. `peak` keeps the beveled crown that stops
        /// parts from ending in flat prisms.
        func sculpt(_ solid: CityActorSolid, peak: CGFloat = 0.22) -> [CityProjectedFacet] {
            func rounded(_ ring: [CGPoint]) -> [CGPoint] {
                var outline: [CGPoint] = []
                outline.reserveCapacity(ring.count * 2)
                for index in ring.indices {
                    let point = ring[index]
                    let previous = ring[(index + ring.count - 1) % ring.count]
                    let next = ring[(index + 1) % ring.count]
                    outline.append(CGPoint(x: point.x * 0.82 + previous.x * 0.18, y: point.y * 0.82 + previous.y * 0.18))
                    outline.append(CGPoint(x: point.x * 0.82 + next.x * 0.18, y: point.y * 0.82 + next.y * 0.18))
                }
                return outline
            }
            func ringCenter(_ ring: [CGPoint]) -> CGPoint {
                let xs = ring.map(\.x)
                let ys = ring.map(\.y)
                return CGPoint(
                    x: ((xs.min() ?? 0) + (xs.max() ?? 0)) / 2,
                    y: ((ys.min() ?? 0) + (ys.max() ?? 0)) / 2
                )
            }
            let base = rounded(solid.vertices)
            guard base.count >= 3 else { return [] }
            let crown: [CGPoint] = {
                guard
                    let upper = solid.upperVertices,
                    upper.count == solid.vertices.count
                else { return base }
                return rounded(upper)
            }()
            let height = max(0, solid.upperZ - solid.lowerZ)
            let z0 = solid.lowerZ
            let z1 = solid.lowerZ + height * (1 - peak)
            let baseCenter = ringCenter(base)
            let crownCenter = ringCenter(crown)
            // Shoulder ring: the crown pulled toward its own centroid, so
            // the sides slope inward under a beveled cap.
            let inset: CGFloat = peak > 0 ? 0.20 : 0
            let shoulder = crown.map { point in
                CGPoint(
                    x: point.x + (crownCenter.x - point.x) * inset,
                    y: point.y + (crownCenter.y - point.y) * inset
                )
            }
            var facets: [CityProjectedFacet] = base.indices.map { index in
                let next = (index + 1) % base.count
                let edgeX = (base[index].x + base[next].x) / 2
                let edgeY = (base[index].y + base[next].y) / 2
                let light: CityFacetLight = edgeX - baseCenter.x >= edgeY - baseCenter.y ? .right : .left
                return CityProjectedFacet(
                    worldPoints: [
                        CityWorldPoint3D(x: base[index].x, y: base[index].y, z: z0),
                        CityWorldPoint3D(x: base[next].x, y: base[next].y, z: z0),
                        CityWorldPoint3D(x: shoulder[next].x, y: shoulder[next].y, z: z1),
                        CityWorldPoint3D(x: shoulder[index].x, y: shoulder[index].y, z: z1),
                    ],
                    panel: index + 1,
                    light: light
                )
            }
            func facetDepth(_ facet: CityProjectedFacet) -> CGFloat {
                facet.worldPoints.reduce(CGFloat(0)) { $0 + $1.x + $1.y }
            }
            facets.sort { facetDepth($0) < facetDepth($1) }
            if peak > 0 {
                let apex = CityWorldPoint3D(
                    x: crownCenter.x, y: crownCenter.y, z: z1 + height * peak
                )
                for index in shoulder.indices {
                    let next = (index + 1) % shoulder.count
                    let edgeX = (shoulder[index].x + shoulder[next].x) / 2
                    let edgeY = (shoulder[index].y + shoulder[next].y) / 2
                    let light: CityFacetLight = edgeX - crownCenter.x >= edgeY - crownCenter.y ? .right : .left
                    facets.append(CityProjectedFacet(
                        worldPoints: [
                            CityWorldPoint3D(x: shoulder[index].x, y: shoulder[index].y, z: z1),
                            CityWorldPoint3D(x: shoulder[next].x, y: shoulder[next].y, z: z1),
                            apex,
                        ],
                        panel: 0,
                        light: light
                    ))
                }
            } else {
                facets.append(CityProjectedFacet(
                    worldPoints: shoulder.map { CityWorldPoint3D(x: $0.x, y: $0.y, z: z1) },
                    panel: 0,
                    light: .top
                ))
            }
            return facets
        }

        func paint(
            _ solid: CityActorSolid,
            _ faces: (top: RGB, left: RGB, right: RGB),
            rimWidth: CGFloat = 0.35,
            peak: CGFloat = 0.22,
            prepared: [CityProjectedFacet]? = nil
        ) {
            let facets = prepared ?? sculpt(solid, peak: peak)
            for facet in facets {
                let side = facet.light == .right ? faces.right : faces.left
                let color = facet.panel == 0 ? Self.mixed(faces.top, side, 0.18) : side
                context.fill(facet.path, with: .color(color.color))
                if facet.panel == 0, rimWidth > 0 {
                    context.stroke(facet.path, with: .color(faces.left.color.opacity(0.16)), lineWidth: rimWidth * 0.5)
                }
            }
        }

        /// Paints a tapered block in world space; `x`/`y` are absolute.
        func paintBlock(
            x: CGFloat,
            y: CGFloat,
            length: CGFloat,
            backWidth: CGFloat,
            frontWidth: CGFloat,
            lowerZ: CGFloat,
            upperZ: CGFloat,
            faces: (top: RGB, left: RGB, right: RGB),
            rimWidth: CGFloat = 0.14,
            peak: CGFloat = 0.22
        ) {
            let vertices = CityActorFootprints.taperedRectangle(
                center: CGPoint(x: x, y: y), heading: forward,
                length: length, backWidth: backWidth, frontWidth: frontWidth
            )
            paint(
                CityActorSolid(center: CGPoint(x: x, y: y), vertices: vertices, lowerZ: lowerZ, upperZ: max(lowerZ, upperZ)),
                faces, rimWidth: rimWidth, peak: peak
            )
        }

        let torsoFacets = sculpt(rig.torso)
        let chestFacets = sculpt(rig.chest)

        // Dorsal crest: blades rooted in the actual spine surface, largest
        // over the hip-to-ribcage transition and tapering toward the neck.
        // Root z derives from whichever back solid owns that station (bob
        // and head lift included), sunk by an embed depth so every blade
        // grows out of the body instead of hovering over the domed back.
        let crest: [(x: CGFloat, y: CGFloat, root: CGFloat, height: CGFloat, length: CGFloat, back: CGFloat, front: CGFloat)] = {
            let spec: [(x: CGFloat, y: CGFloat, height: CGFloat, length: CGFloat, back: CGFloat, front: CGFloat)] = [
                (-2.0, -0.15, 2.5, 1.15, 0.62, 0.30),
                (-0.9, -0.12, 3.0, 1.30, 0.66, 0.32),
                (0.6, -0.10, 2.1, 1.20, 0.60, 0.30),
                (1.9, -0.08, 1.8, 1.00, 0.52, 0.26),
            ]
            // Intersect the actual beveled roof, not a footprint's maximum
            // height: near a tapered edge those are different surfaces.
            let roof = (torsoFacets + chestFacets).filter { $0.panel == 0 }
            func spineTop(at point: CGPoint) -> CGFloat? {
                var top: CGFloat?
                for facet in roof {
                    let a = facet.worldPoints[0], b = facet.worldPoints[1], c = facet.worldPoints[2]
                    let denominator = (b.y - c.y) * (a.x - c.x) + (c.x - b.x) * (a.y - c.y)
                    guard abs(denominator) > 0.000001 else { continue }
                    let wa = ((b.y - c.y) * (point.x - c.x) + (c.x - b.x) * (point.y - c.y)) / denominator
                    let wb = ((c.y - a.y) * (point.x - c.x) + (a.x - c.x) * (point.y - c.y)) / denominator
                    let wc = 1 - wa - wb
                    guard min(wa, wb, wc) >= -0.000001 else { continue }
                    let z = wa * a.z + wb * b.z + wc * c.z
                    top = max(top ?? z, z)
                }
                return top
            }
            return spec.compactMap { blade in
                let station = CGPoint(x: pose.x + heading * blade.x, y: pose.y + blade.y)
                guard let top = spineTop(at: station) else { return nil }
                return (blade.x, blade.y, top - 0.55, blade.height, blade.length, blade.back, blade.front)
            }
        }()
        // Tail blades ride their segment, so the crest wags with the tail.
        let tailBlades: [(height: CGFloat, length: CGFloat, back: CGFloat, front: CGFloat)] = [
            (1.9, 1.15, 0.62, 0.30),
            (1.5, 1.00, 0.54, 0.26),
            (1.05, 0.86, 0.46, 0.22),
            (0.60, 0.72, 0.38, 0.18),
        ]

        enum Part {
            case tail(Int)
            case crest(Int)
            case foot(Int)
            case leg(Int)
            case joint(Int)
            case arm(Int)
            case torso
            case belly
            case scutes
            case chest
            case neck
            case head
            case muzzle
        }

        let scuteCenter = CGPoint(
            x: rig.belly.center.x,
            y: (rig.belly.vertices.map(\.y).max() ?? rig.belly.center.y) + 0.02
        )
        var parts: [(key: CGFloat, order: Int, part: Part)] = []
        func schedule(_ part: Part, at point: CGPoint) {
            parts.append((
                key: IsoProjection.sortKey(x: point.x, y: point.y),
                order: parts.count,
                part: part
            ))
        }
        for index in rig.tail.indices { schedule(.tail(index), at: rig.tail[index].center) }
        for index in crest.indices {
            schedule(.crest(index), at: CGPoint(
                x: pose.x + heading * crest[index].x,
                y: pose.y + crest[index].y
            ))
        }
        for index in rig.feet.indices { schedule(.foot(index), at: rig.feet[index].center) }
        for index in rig.legs.indices { schedule(.leg(index), at: rig.legs[index].center) }
        for index in rig.arms.indices { schedule(.arm(index), at: rig.arms[index].center) }
        schedule(.torso, at: rig.torso.center)
        for index in rig.joints.indices { schedule(.joint(index), at: rig.joints[index].center) }
        schedule(.belly, at: rig.belly.center)
        schedule(.chest, at: rig.chest.center)
        if detail != .silhouette { schedule(.scutes, at: scuteCenter) }
        schedule(.neck, at: rig.neck.center)
        schedule(.head, at: rig.head.center)
        schedule(.muzzle, at: rig.snout.center)
        parts.sort { $0.key == $1.key ? $0.order < $1.order : $0.key < $1.key }

        for entry in parts {
            switch entry.part {
            case let .tail(index):
                let segment = rig.tail[index]
                paint(segment, tailFaces, rimWidth: 0.25, peak: 0.10)
                guard index < tailBlades.count else { continue }
                let blade = tailBlades[index]
                paintBlock(
                    x: segment.center.x,
                    y: segment.center.y,
                    length: blade.length,
                    backWidth: blade.back,
                    frontWidth: blade.front,
                    lowerZ: segment.upperZ - 0.25,
                    upperZ: segment.upperZ + blade.height,
                    faces: plateFaces, peak: 0.85
                )
            case let .crest(index):
                let blade = crest[index]
                paintBlock(
                    x: pose.x + heading * blade.x,
                    y: pose.y + blade.y,
                    length: blade.length,
                    backWidth: blade.back,
                    frontWidth: blade.front,
                    lowerZ: blade.root,
                    upperZ: blade.root + blade.height,
                    faces: plateFaces,
                    rimWidth: 0.18, peak: 0.85
                )
            case let .foot(index):
                let foot = rig.feet[index]
                paint(foot, hideFaces, peak: 0)
                guard detail != .silhouette else { continue }
                // Three separated toes fan off the front of each planted
                // foot — the middle toe longest — each carrying a bone claw,
                // so the weight-bearing stance reads three-toed, not hooved.
                for toe in [(offset: CGFloat(-0.70), length: CGFloat(1.45)),
                            (offset: CGFloat(0), length: CGFloat(1.7)),
                            (offset: CGFloat(0.70), length: CGFloat(1.45))] {
                    paintBlock(
                        x: foot.center.x + heading * 1.30,
                        y: foot.center.y + toe.offset,
                        length: toe.length,
                        backWidth: 0.66,
                        frontWidth: 0.50,
                        lowerZ: foot.lowerZ,
                        upperZ: foot.lowerZ + 0.92,
                        faces: hideFaces,
                        rimWidth: 0.14, peak: 0.10
                    )
                    paintBlock(
                        x: foot.center.x + heading * (1.30 + toe.length * 0.5 + 0.28),
                        y: foot.center.y + toe.offset,
                        length: 0.62,
                        backWidth: 0.42,
                        frontWidth: 0.16,
                        lowerZ: foot.lowerZ + 0.04,
                        upperZ: foot.lowerZ + 0.50,
                        faces: boneFaces,
                        rimWidth: 0.08
                    )
                }
            case let .leg(index):
                paint(rig.legs[index], hideFaces)
            case let .joint(index):
                // Visible hinge band wrapping the shared joint, flat-topped
                // so it reads as a socket collar rather than another prism.
                paint(rig.joints[index], boneFaces, rimWidth: 0.16, peak: 0)
            case let .arm(index):
                paint(rig.arms[index], hideFaces, rimWidth: 0.28)
            case .torso:
                paint(rig.torso, bodyFaces, rimWidth: 0.45, prepared: torsoFacets)
            case .belly:
                paint(rig.belly, bellyFaces, rimWidth: 0.30)
            case .chest:
                paint(rig.chest, bodyFaces, rimWidth: 0.45, prepared: chestFacets)
            case .scutes:
                // Belly plating: shallow pale bands that hug the underside
                // with hairline gaps, so the belly reads segmented instead
                // of wearing three separate slats.
                for index in 0..<3 {
                    let lower = 8.9 + CGFloat(index) * 1.24
                    paintBlock(
                        x: scuteCenter.x - heading * CGFloat(index) * 0.18,
                        y: scuteCenter.y,
                        length: 3.1 - CGFloat(index) * 0.45,
                        backWidth: 0.22,
                        frontWidth: 0.16,
                        lowerZ: lower,
                        upperZ: lower + 1.08 + pose.bob * 0.5,
                        faces: scuteFaces,
                        rimWidth: 0.10, peak: 0
                    )
                }
            case .neck:
                paint(rig.neck, hideFaces, rimWidth: 0.30)
            case .head:
                paint(rig.head, headFaces, rimWidth: 0.45)
                paint(rig.brow, hideFaces, rimWidth: 0.30)
                // Eyeball and pupil are shallow solids proud of the skull's
                // camera-facing cheek, tucked under the brow overhang.
                let cheekY = (rig.head.vertices.map(\.y).max() ?? rig.head.center.y) - 0.12
                let eyeX = rig.head.center.x + heading * 0.85
                let eyeTop = rig.head.upperZ - 1.20
                paintBlock(
                    x: eyeX,
                    y: cheekY,
                    length: 1.35,
                    backWidth: 0.74,
                    frontWidth: 0.54,
                    lowerZ: eyeTop - 1.05,
                    upperZ: eyeTop,
                    faces: eyeFaces,
                    rimWidth: 0.10
                )
                paintBlock(
                    x: eyeX + heading * 0.24,
                    y: cheekY + 0.24,
                    length: 0.52,
                    backWidth: 0.44,
                    frontWidth: 0.34,
                    lowerZ: eyeTop - 0.80,
                    upperZ: eyeTop - 0.22,
                    faces: pupilFaces,
                    rimWidth: 0
                )
            case .muzzle:
                // The maw is a dark solid between jaw and muzzle: dropping the
                // jaw opens a real mouth instead of widening a painted line.
                paintBlock(
                    x: rig.jaw.center.x,
                    y: rig.jaw.center.y,
                    length: 2.3,
                    backWidth: 1.80,
                    frontWidth: 1.25,
                    lowerZ: rig.jaw.upperZ - 0.20,
                    upperZ: rig.snout.lowerZ + 0.12,
                    faces: mawFaces,
                    rimWidth: 0
                )
                paint(rig.jaw, jawFaces, rimWidth: 0.25)
                paint(rig.snout, headFaces, rimWidth: 0.30)
                guard detail != .silhouette else { continue }
                let lipY = (rig.jaw.vertices.map(\.y).max() ?? rig.jaw.center.y) - 0.06
                for (index, offset) in [CGFloat(-0.62), 0.02, 0.60].enumerated() {
                    let scale = 1 - CGFloat(index) * 0.14
                    paintBlock(
                        x: rig.snout.center.x + heading * offset,
                        y: lipY,
                        length: 0.36 * scale,
                        backWidth: 0.30,
                        frontWidth: 0.18,
                        lowerZ: rig.snout.lowerZ - 0.66 * scale,
                        upperZ: rig.snout.lowerZ + 0.06,
                        faces: boneFaces,
                        rimWidth: 0.08
                    )
                }
                for offset in [CGFloat(-0.35), 0.42] {
                    paintBlock(
                        x: rig.jaw.center.x + heading * offset,
                        y: lipY,
                        length: 0.30,
                        backWidth: 0.26,
                        frontWidth: 0.16,
                        lowerZ: rig.jaw.upperZ - 0.06,
                        upperZ: rig.jaw.upperZ + 0.42,
                        faces: boneFaces,
                        rimWidth: 0.08
                    )
                }
                // Nostril pit near the blunt end of the muzzle.
                let snoutFaceY = (rig.snout.vertices.map(\.y).max() ?? rig.snout.center.y) - 0.05
                paintBlock(
                    x: rig.snout.center.x + heading * 0.92,
                    y: snoutFaceY,
                    length: 0.36,
                    backWidth: 0.30,
                    frontWidth: 0.24,
                    lowerZ: rig.snout.upperZ - 0.80,
                    upperZ: rig.snout.upperZ - 0.40,
                    faces: mawFaces,
                    rimWidth: 0
                )
            }
        }

        // Roar dressing: the tall crest blades glow from the spine up, and a
        // pastel breath cloud puffs out of the muzzle.
        guard pose.roar > 0.03 else { return }
        for blade in crest where blade.height >= 2.0 {
            let glowCenter = IsoProjection.project(
                pose.x + heading * blade.x,
                pose.y + blade.y,
                blade.root + blade.height
            )
            let glowRadius = 1.8 + pose.roar * 3.2
            context.fill(
                Path(ellipseIn: CGRect(
                    x: glowCenter.x - glowRadius,
                    y: glowCenter.y - glowRadius,
                    width: glowRadius * 2,
                    height: glowRadius * 2
                )),
                with: .radialGradient(
                    Gradient(colors: [
                        Color(red: 1, green: 0.72, blue: 0.35).opacity(Double(pose.roar) * (0.38 + 0.2 * sample.night)),
                        .clear,
                    ]),
                    center: glowCenter,
                    startRadius: 0,
                    endRadius: glowRadius
                )
            )
        }
        if detail != .silhouette {
            let breathColor = nightified(
                Self.mixed(CalmCityStyle.coral, CalmCityStyle.paper, 0.45),
                sample: sample,
                attenuation: 0.12
            )
            for index in 0..<3 {
                let drift = 1.2 + CGFloat(index) * 1.3 + pose.roar * 1.4
                let puffCenter = IsoProjection.project(
                    pose.x + heading * (8.0 + drift),
                    rig.snout.center.y,
                    16.9 + pose.bob + pose.headRear
                )
                let radius = (1.6 + CGFloat(index) * 1.1) * (0.6 + 0.7 * pose.roar)
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: puffCenter.x - radius,
                        y: puffCenter.y - radius * 0.8,
                        width: radius * 2,
                        height: radius * 1.6
                    )),
                    with: .color(breathColor.opacity(Double(pose.roar) * (0.42 - Double(index) * 0.11)))
                )
            }
        }
    }

    private func drawUFOBeam(
        context: inout GraphicsContext,
        event: CityWhimsy.UFOEvent,
        sample: CityPalette.Sample,
        detail: CityCreatureDetail
    ) {
        let policy = CityCreatureRenderPolicy.ufo(detail: detail, night: sample.night)
        let center = CGPoint(x: event.x, y: event.y)
        let ground = IsoProjection.project(event.x, event.y, 0.02)
        let ink = nightified(CalmCityStyle.ink, sample: sample)

        context.fill(
            Path(ellipseIn: CGRect(
                x: ground.x - 16,
                y: ground.y - 4.5,
                width: 32,
                height: 9
            )),
            with: .color(ink.opacity(CityCreatureGeometry.UFO.shadowOpacity))
        )

        func drawBeamFrustum(
            topSize: CGFloat,
            groundSize: CGFloat,
            color: Color,
            opacity: Double
        ) {
            let top = CityActorFootprints.orientedRectangle(
                center: center,
                heading: CGVector(dx: 1, dy: 0),
                length: topSize,
                width: topSize
            )
            let bottom = CityActorFootprints.orientedRectangle(
                center: center,
                heading: CGVector(dx: 1, dy: 0),
                length: groundSize,
                width: groundSize
            )
            fill(
                context: &context,
                bottom.map { point in
                    IsoProjection.project(point.x, point.y, 0.04)
                },
                color: color.opacity(opacity * 0.72)
            )
            for edge in [1, 2] {
                let next = (edge + 1) % 4
                fill(
                    context: &context,
                    [
                        IsoProjection.project(top[edge].x, top[edge].y, event.altitude - 1.45),
                        IsoProjection.project(top[next].x, top[next].y, event.altitude - 1.45),
                        IsoProjection.project(bottom[next].x, bottom[next].y, 0.04),
                        IsoProjection.project(bottom[edge].x, bottom[edge].y, 0.04),
                    ],
                    color: color.opacity(opacity)
                )
            }
        }

        if policy.drawBeam {
            drawBeamFrustum(
                topSize: 2.2,
                groundSize: (detail == .silhouette ? 10.5 : 6.2) * (0.75 + 0.5 * event.beam),
                color: nightified(
                    detail == .silhouette ? CalmCityStyle.coral : CalmCityStyle.marigold,
                    sample: sample,
                    attenuation: 0.05
                ),
                opacity: detail == .silhouette
                    ? 0.24
                    : event.beam * (0.16 + 0.11 * sample.night)
            )
            if policy.drawBeamCore {
                drawBeamFrustum(
                    topSize: 0.9,
                    groundSize: 2.8,
                    color: nightified(CalmCityStyle.paper, sample: sample, attenuation: 0.08),
                    opacity: min(event.beam * (0.12 + 0.08 * sample.night), 0.18)
                )
            }
        }
    }

    /// Saucer built as a stack of octagonal rings that shrink away from a
    /// widest equator: the belly slopes down to a small underside plate, the
    /// upper hull slopes in to a collar, and a faceted glass canopy steps up
    /// from it. Ring scales and heights stay inside the culled dome height.
    private func drawUFOHull(
        context: inout GraphicsContext,
        event: CityWhimsy.UFOEvent,
        date: Date,
        sample: CityPalette.Sample,
        detail: CityCreatureDetail
    ) {
        let policy = CityCreatureRenderPolicy.ufo(detail: detail, night: sample.night)
        let center = CGPoint(x: event.x, y: event.y)
        let diameter = CityCreatureGeometry.UFO.diameter * 0.86
        let rig = CityActorFootprints.ufo(center: center, diameter: diameter)
        let ink = nightified(CalmCityStyle.ink, sample: sample)
        let hullBase = Self.mixed(CalmCityStyle.lavender, CalmCityStyle.paper, 0.12)
        let hullFaces = CityPalette.faceColors(
            base: hullBase,
            sample: sample,
            nightAttenuation: detail == .silhouette ? 0.62 : 0.74
        )
        let deckFaces = CityPalette.faceColors(
            base: Self.mixed(hullBase, CalmCityStyle.paper, 0.16),
            sample: sample,
            nightAttenuation: detail == .silhouette ? 0.60 : 0.72
        )
        let undersideFaces = CityPalette.faceColors(
            base: Self.mixed(CalmCityStyle.lavender, CalmCityStyle.ink, 0.48),
            sample: sample,
            nightAttenuation: detail == .silhouette ? 0.72 : 0.82
        )
        let keelFaces = CityPalette.faceColors(
            base: Self.mixed(CalmCityStyle.lavender, CalmCityStyle.ink, 0.66),
            sample: sample,
            nightAttenuation: detail == .silhouette ? 0.76 : 0.86
        )
        let collarFaces = CityPalette.faceColors(
            base: Self.mixed(CalmCityStyle.lavender, CalmCityStyle.ink, 0.58),
            sample: sample,
            nightAttenuation: detail == .silhouette ? 0.74 : 0.84
        )
        let cockpitFaces = CityPalette.faceColors(
            base: CalmCityStyle.water,
            sample: sample,
            nightAttenuation: 0.72
        )

        /// Octagonal ring concentric with the hull, scaled about the center.
        func ring(_ scale: CGFloat) -> [CGPoint] {
            rig.lowerHull.map { point in
                CGPoint(
                    x: center.x + (point.x - center.x) * scale,
                    y: center.y + (point.y - center.y) * scale
                )
            }
        }
        func band(
            _ vertices: [CGPoint],
            _ lowerZ: CGFloat,
            _ upperZ: CGFloat,
            _ faces: (top: RGB, left: RGB, right: RGB),
            rimWidth: CGFloat = 0.35,
            opacity: Double = 1,
            top: [CGPoint]? = nil
        ) {
            let upper = top ?? vertices
            let facets = vertices.indices.map { index in
                let next = (index + 1) % vertices.count
                let edgeX = (vertices[index].x + vertices[next].x) / 2 - center.x
                let edgeY = (vertices[index].y + vertices[next].y) / 2 - center.y
                return CityProjectedFacet(
                    worldPoints: [
                        CityWorldPoint3D(x: vertices[index].x, y: vertices[index].y, z: event.altitude + lowerZ),
                        CityWorldPoint3D(x: vertices[next].x, y: vertices[next].y, z: event.altitude + lowerZ),
                        CityWorldPoint3D(x: upper[next].x, y: upper[next].y, z: event.altitude + upperZ),
                        CityWorldPoint3D(x: upper[index].x, y: upper[index].y, z: event.altitude + upperZ),
                    ],
                    panel: index, light: edgeX >= edgeY ? .right : .left
                )
            }.sorted { $0.depth < $1.depth }
            for facet in facets {
                let color = facet.light == .right ? faces.right : faces.left
                context.fill(facet.path, with: .color(color.color.opacity(opacity)))
            }
            let lid = upper.map { IsoProjection.project($0.x, $0.y, event.altitude + upperZ) }
            fill(context: &context, lid, color: faces.top.color.opacity(opacity))
            if rimWidth > 0 {
                stroke(context: &context, lid + [lid[0]], color: ink.opacity(0.24), width: rimWidth)
            }
        }

        // Belly: three rings sloping down and in from the equator.
        band(ring(0.42), -1.55, -1.18, keelFaces, rimWidth: 0.20, top: ring(0.70))
        band(ring(0.70), -1.18, -0.74, keelFaces, rimWidth: 0.26, top: ring(0.90))
        band(ring(0.90), -0.74, -0.30, undersideFaces, rimWidth: 0.34, top: rig.lowerHull)
        // Equator: the widest ring, the ledge the whole profile hangs off.
        band(rig.lowerHull, -0.30, 0.25, undersideFaces, rimWidth: 0.45)
        // Upper hull: two rings sloping in toward the canopy collar.
        band(rig.lowerHull, 0.25, 0.72, hullFaces, rimWidth: 0.42, top: ring(0.88))
        band(ring(0.88), 0.72, 1.10, deckFaces, rimWidth: 0.40, top: rig.upperHull)
        band(ring(0.46), 1.10, 1.32, collarFaces, rimWidth: 0.28)
        // True sloping glass surfaces, not nested vertical-sided blocks.
        // The collar must stay behind the dome: painting its opaque lid last
        // would flatten the entire canopy back into a cyan plate.
        let glassFaces = (
            top: Self.mixed(cockpitFaces.top, CalmCityStyle.paper, 0.48 * sample.dayAmount),
            left: Self.mixed(cockpitFaces.left, CalmCityStyle.ink, 0.28),
            right: Self.mixed(cockpitFaces.right, CalmCityStyle.paper, 0.14 * sample.dayAmount)
        )
        let canopyOpacity: Double = detail == .silhouette ? 0.90 : 0.82
        band(rig.cockpit, 1.32, 1.74, glassFaces, rimWidth: 0.25, opacity: canopyOpacity, top: ring(0.25))
        band(ring(0.25), 1.74, 2.03, glassFaces, rimWidth: 0.20, opacity: canopyOpacity, top: ring(0.16))
        band(ring(0.16), 2.03, 2.22, glassFaces, rimWidth: 0.15, opacity: canopyOpacity, top: ring(0.08))
        band(ring(0.08), 2.22, 2.36, glassFaces, rimWidth: 0.10, opacity: canopyOpacity, top: ring(0.015))

        if detail != .silhouette {
            // Crew read at distance: when the actual pilot figures are too
            // small to draw, two ink pits on the canopy's sunny face stand in.
            let canopyFrontY = center.y + diameter / 2 * 0.30
            for side in policy.drawAlien ? [] : [-1.0, 1.0] {
                let eyeX = center.x + CGFloat(side) * 0.24
                fill(
                    context: &context,
                    [
                        IsoProjection.project(eyeX - 0.08, canopyFrontY + 0.02, event.altitude + 1.62),
                        IsoProjection.project(eyeX + 0.08, canopyFrontY + 0.02, event.altitude + 1.62),
                        IsoProjection.project(eyeX + 0.08, canopyFrontY + 0.02, event.altitude + 1.84),
                        IsoProjection.project(eyeX - 0.08, canopyFrontY + 0.02, event.altitude + 1.84),
                    ],
                    color: ink
                )
            }
            // One crisp glass shine along the canopy's lit shoulder.
            stroke(
                context: &context,
                [
                    IsoProjection.project(center.x - 0.46, canopyFrontY, event.altitude + 2.06),
                    IsoProjection.project(center.x + 0.46, canopyFrontY, event.altitude + 2.06),
                ],
                color: nightified(CalmCityStyle.paper, sample: sample).opacity(0.55),
                width: 0.45
            )
        }

        guard detail != .silhouette else { return }

        let lightTokens = [
            CalmCityStyle.marigold,
            CalmCityStyle.coral,
            CalmCityStyle.spruce,
        ]
        if policy.drawLights {
            // Lamps recessed just under the equator ledge, where the belly
            // slope shades them.
            let lightIndices = [0, 1, 2, 4, 5, 6]
            for (index, vertexIndex) in lightIndices.enumerated() {
                let hullPoint = rig.lowerHull[vertexIndex]
                let inset = CGPoint(
                    x: center.x + (hullPoint.x - center.x) * 0.80,
                    y: center.y + (hullPoint.y - center.y) * 0.80
                )
                drawExtrudedFootprint(
                    context: &context,
                    vertices: CityActorFootprints.orientedRectangle(
                        center: inset,
                        heading: CGVector(dx: 1, dy: 0),
                        length: 0.58,
                        width: 0.58
                    ),
                    lowerZ: event.altitude - 0.62,
                    upperZ: event.altitude - 0.18,
                    top: nightified(lightTokens[index % lightTokens.count], sample: sample),
                    right: nightified(lightTokens[index % lightTokens.count], sample: sample, attenuation: 0.18),
                    left: nightified(lightTokens[index % lightTokens.count], sample: sample, attenuation: 0.28),
                    rimWidth: 0.18
                )
            }
        }

        if policy.drawAlien {
            let animSeconds = reduceMotion ? 0.0 : date.timeIntervalSinceReferenceDate
            // Cockpit crew: two small mint pilots standing on the canopy
            // floor inside the glass; the left one waves when its arm cycle
            // swings high. Sized so their antenna tips stay under the culled
            // canopy ceiling.
            let bobA = CGFloat(sin(animSeconds * 2.1)) * 0.05
            let bobB = CGFloat(sin(animSeconds * 2.1 + 2.4)) * 0.05
            let wave = max(0, CGFloat(sin(animSeconds * 3.2)))
            drawAlienFigure(
                context: &context,
                sample: sample,
                ink: ink,
                wx: center.x - 0.46,
                wy: center.y + 0.26,
                z0: event.altitude + 1.36 + bobA,
                size: 0.86,
                wave: wave,
                rider: false,
                seconds: animSeconds
            )
            drawAlienFigure(
                context: &context,
                sample: sample,
                ink: ink,
                wx: center.x + 0.54,
                wy: center.y - 0.04,
                z0: event.altitude + 1.34 + bobB,
                size: 0.78,
                wave: 0,
                rider: false,
                seconds: animSeconds
            )
            // Beam rider: a third alien floats down the beam and back while
            // the beam is strong enough to surf.
            if event.beam > 0.42 {
                let rideRaw = (animSeconds / 7.5).truncatingRemainder(dividingBy: 1)
                let rideWrapped = rideRaw < 0 ? rideRaw + 1 : rideRaw
                let ride = CGFloat(1 - abs(2 * rideWrapped - 1))
                let riderZ = (event.altitude - 3.1) * (1 - ride) + 1.3 * ride
                drawAlienFigure(
                    context: &context,
                    sample: sample,
                    ink: ink,
                    wx: center.x + CGFloat(sin(animSeconds * 1.3)) * 0.35,
                    wy: center.y + CGFloat(cos(animSeconds * 1.1)) * 0.25,
                    z0: riderZ,
                    size: 1.5,
                    wave: 0,
                    rider: true,
                    seconds: animSeconds
                )
            }
        }

        let rawPhase = reduceMotion
            ? 0.35
            : date.timeIntervalSinceReferenceDate / 3
        let remainder = rawPhase.truncatingRemainder(dividingBy: 1)
        let phase = remainder < 0 ? remainder + 1 : remainder
        for index in 0..<policy.particleCount {
            let fraction = CGFloat(
                (phase + Double(index) * 0.5).truncatingRemainder(dividingBy: 1)
            )
            let moteCenter = CGPoint(
                x: center.x + CGFloat(index - 1) * 0.80,
                y: center.y + (fraction - 0.5) * 2.2
            )
            drawExtrudedFootprint(
                context: &context,
                vertices: CityActorFootprints.orientedRectangle(
                    center: moteCenter,
                    heading: CGVector(dx: 1, dy: 0),
                    length: 0.24,
                    width: 0.24
                ),
                lowerZ: event.altitude - 5.0 - fraction * 4.0,
                upperZ: event.altitude - 4.65 - fraction * 4.0,
                top: nightified(CalmCityStyle.paper, sample: sample).opacity(0.72),
                right: nightified(CalmCityStyle.marigold, sample: sample).opacity(0.62),
                left: nightified(CalmCityStyle.coral, sample: sample).opacity(0.54)
            )
        }
    }

    /// A lil mint alien in the voxel grammar: body, big head, ink eyes on
    /// the sunny face, and a marigold antenna bulb that glows after dark.
    /// `wave` raises one arm (0..1); `rider` adds outstretched flapping arms
    /// and kicking legs for the beam-surfing pose.
    private func drawAlienFigure(
        context: inout GraphicsContext,
        sample: CityPalette.Sample,
        ink: Color,
        wx: CGFloat,
        wy: CGFloat,
        z0: CGFloat,
        size s: CGFloat,
        wave: CGFloat,
        rider: Bool,
        seconds: Double
    ) {
        let mint = Self.mixed(CalmCityStyle.leaf, CalmCityStyle.paper, 0.42)
        let faces = CityPalette.faceColors(
            base: mint,
            sample: sample,
            nightAttenuation: 0.3
        )
        let forward = CGVector(dx: 1, dy: 0)
        func box(
            _ cx: CGFloat,
            _ cy: CGFloat,
            _ length: CGFloat,
            _ width: CGFloat,
            _ lowerZ: CGFloat,
            _ upperZ: CGFloat,
            rimWidth: CGFloat = 0.14
        ) {
            drawExtrudedFootprint(
                context: &context,
                vertices: CityActorFootprints.orientedRectangle(
                    center: CGPoint(x: cx, y: cy),
                    heading: forward,
                    length: length,
                    width: width
                ),
                lowerZ: lowerZ,
                upperZ: upperZ,
                top: faces.top.color,
                right: faces.right.color,
                left: faces.left.color,
                rimWidth: rimWidth
            )
        }

        box(wx, wy, 0.34 * s, 0.30 * s, z0, z0 + 0.42 * s) // body
        box(wx, wy, 0.42 * s, 0.38 * s, z0 + 0.40 * s, z0 + 0.82 * s) // head

        // Eyes on the +y (viewer-facing) head face.
        let face = wy + 0.19 * s + 0.01
        for side in [-1.0, 1.0] {
            let eyeX = wx + CGFloat(side) * 0.10 * s
            fill(
                context: &context,
                [
                    IsoProjection.project(eyeX - 0.045 * s, face, z0 + 0.56 * s),
                    IsoProjection.project(eyeX + 0.045 * s, face, z0 + 0.56 * s),
                    IsoProjection.project(eyeX + 0.045 * s, face, z0 + 0.68 * s),
                    IsoProjection.project(eyeX - 0.045 * s, face, z0 + 0.68 * s),
                ],
                color: ink
            )
        }

        // Antenna: dark stem, marigold bulb, soft glow at night.
        box(wx, wy, 0.05 * s, 0.05 * s, z0 + 0.82 * s, z0 + 0.97 * s, rimWidth: 0.05)
        drawExtrudedFootprint(
            context: &context,
            vertices: CityActorFootprints.orientedRectangle(
                center: CGPoint(x: wx, y: wy),
                heading: forward,
                length: 0.12 * s,
                width: 0.12 * s
            ),
            lowerZ: z0 + 0.97 * s,
            upperZ: z0 + 1.09 * s,
            top: nightified(CalmCityStyle.marigold, sample: sample, attenuation: 0.08),
            right: nightified(CalmCityStyle.marigold, sample: sample, attenuation: 0.20),
            left: nightified(CalmCityStyle.marigold, sample: sample, attenuation: 0.30),
            rimWidth: 0.05
        )
        if sample.night > 0.25 {
            let tip = IsoProjection.project(wx, wy, z0 + 1.12 * s)
            let glowRadius = 1.3 * s
            context.fill(
                Path(ellipseIn: CGRect(
                    x: tip.x - glowRadius,
                    y: tip.y - glowRadius,
                    width: glowRadius * 2,
                    height: glowRadius * 2
                )),
                with: .radialGradient(
                    Gradient(colors: [
                        Color(red: 1, green: 0.72, blue: 0.35).opacity(0.5 * sample.night),
                        .clear,
                    ]),
                    center: tip,
                    startRadius: 0,
                    endRadius: glowRadius
                )
            )
        }

        if wave > 0 {
            let lift = wave * 0.28 * s
            box(
                wx + 0.26 * s,
                wy + 0.06 * s,
                0.20 * s,
                0.09 * s,
                z0 + 0.44 * s + lift,
                z0 + 0.58 * s + lift,
                rimWidth: 0.08
            )
        }
        if rider {
            let flap = CGFloat(sin(seconds * 4.2)) * 0.06 * s
            box(wx - 0.30 * s, wy + 0.02 * s, 0.24 * s, 0.09 * s, z0 + 0.38 * s + flap, z0 + 0.50 * s + flap, rimWidth: 0.08)
            box(wx + 0.30 * s, wy + 0.02 * s, 0.24 * s, 0.09 * s, z0 + 0.38 * s - flap, z0 + 0.50 * s - flap, rimWidth: 0.08)
            let kick = CGFloat(sin(seconds * 3.4)) * 0.05 * s
            box(wx - 0.09 * s, wy - 0.01 * s + kick, 0.10 * s, 0.10 * s, z0 - 0.14 * s, z0 + 0.02 * s, rimWidth: 0.06)
            box(wx + 0.09 * s, wy - 0.01 * s - kick, 0.10 * s, 0.10 * s, z0 - 0.14 * s, z0 + 0.02 * s, rimWidth: 0.06)
        }
    }

    static func balloonGeometry(
        model: CityWhimsy.Balloon,
        bounds: CGRect
    ) -> CityIsometricBalloonGeometry {
        let flightProgress = (model.x + 10) / 180
        return CityIsometricBalloonGeometry(
            x: bounds.minX + (0.12 + 0.76 * flightProgress) * bounds.width,
            y: bounds.minY + (0.78 - 0.56 * flightProgress) * bounds.height,
            z: model.z + model.bob + 2.2,
            radius: 5.0
        )
    }

    private func drawBalloonGroundShadow(
        context: inout GraphicsContext,
        geometry: CityIsometricBalloonGeometry,
        sample: CityPalette.Sample,
        visibleRect: CGRect
    ) {
        let shadowRX = 2.2 * IsoProjection.s
        let shadowRY = 1.1 * IsoProjection.s
        let shadowCenter = IsoProjection.project(geometry.x, geometry.y, 0)
        let shadowRect = CGRect(
            x: shadowCenter.x - shadowRX,
            y: shadowCenter.y - shadowRY,
            width: shadowRX * 2,
            height: shadowRY * 2
        )
        if visibleRect.insetBy(dx: -12, dy: -12).intersects(shadowRect) {
            context.fill(
                Path(ellipseIn: shadowRect),
                with: .color(CalmCityStyle.ink.color.opacity(0.10 * (0.4 + 0.6 * sample.dayAmount)))
            )
        }
    }


    /// Warm hot-air balloon on its endless crossing. The envelope is five
    /// vertical gore panels shaded by sun azimuth — gores facing the sun
    /// (which crosses upper-right to lower-left through the day) lift toward
    /// lit paper while opposite gores sink toward ink — under a vertical
    /// gradient that keeps the silhouette round. At night every gore deepens
    /// toward ink, a warm burner glow blooms under the envelope mouth, and a
    /// soft pool of light gathers inside the basket rim. A soft ink shadow
    /// rides the terrain beneath, and the basket sways like a pendulum on
    /// four rim tension lines. Flight path, culling, and band behavior are
    /// unchanged.
    private func drawHotAirBalloon(
        context: inout GraphicsContext,
        visibleRect: CGRect,
        date: Date,
        sample: CityPalette.Sample,
        lighting: CityLighting.Sample,
        band: ZoomBand,
        celebration: Double
    ) {
        let ink = nightified(CalmCityStyle.ink, sample: sample).opacity(0.90)
        let bounds = staticPaths.groundWorldBounds
        let balloon = CityWhimsy.balloon(date: date, reduceMotion: reduceMotion, celebration: celebration)
        let geometry = Self.balloonGeometry(model: balloon, bounds: bounds)

        guard visibleRect.insetBy(dx: -64, dy: -64).intersects(geometry.projectedBounds) else { return }

        let basket = Self.mixed(CalmCityStyle.road, CalmCityStyle.coral, 0.1)
        let directionalBasketFaces = CityPalette.faceColors(
            base: basket,
            sample: sample,
            lighting: lighting,
            nightAttenuation: 0.70
        )
        let basketFaces = (
            top: Self.mixed(basket, directionalBasketFaces.top, 0.62),
            left: Self.mixed(basket, directionalBasketFaces.left, 0.62),
            right: Self.mixed(basket, directionalBasketFaces.right, 0.62)
        )
        let closeDetail = band == .city || band == .street

        // Envelope silhouette rows run crown -> mouth. Each row is a real
        // horizontal circle on the envelope and its ends are that circle's
        // exact screen extremes, so seams and tapes can follow the inflated
        // profile instead of three straight anchor chords.
        let rows = geometry.envelopeRows
        guard let crownRow = rows.first, let mouthRow = rows.last else { return }
        /// Recovers the world circle behind a silhouette row: the ends sit at
        /// theta = 135 deg and theta = -45 deg on that circle.
        func circle(
            _ row: CityWorldSegment3D
        ) -> (cx: CGFloat, cy: CGFloat, radius: CGFloat, z: CGFloat) {
            (
                cx: (row.start.x + row.end.x) / 2,
                cy: (row.start.y + row.end.y) / 2,
                radius: max(0, (row.end.x - row.start.x) / 1.414_213_6),
                z: row.start.z
            )
        }
        /// Screen point at `theta` radians on a row circle. The camera-facing
        /// half spans -pi/4 (right extreme) to 3pi/4 (left extreme).
        func rowPoint(_ row: CityWorldSegment3D, _ theta: CGFloat) -> CGPoint {
            let ring = circle(row)
            return IsoProjection.project(
                ring.cx + ring.radius * cos(theta),
                ring.cy + ring.radius * sin(theta),
                ring.z
            )
        }
        let crownRing = circle(crownRow)
        let mouthRing = circle(mouthRow)
        let crown = IsoProjection.project(crownRing.cx, crownRing.cy, crownRing.z)
        let mouth = IsoProjection.project(mouthRing.cx, mouthRing.cy, mouthRing.z)
        let neckL = mouthRow.start.projected
        let neckR = mouthRow.end.projected

        // Sun-azimuth panel response: a gore's horizontal position against
        // the sun's side of the sky picks lit paper or ink shade; at night
        // all gores deepen uniformly toward ink.
        let panelBase = Self.mixed(CalmCityStyle.coral, CalmCityStyle.paper, 0.38)
        let sunH = 1 - sample.sunProgress
        let daylight = sample.dayAmount
        let panelCount = 8
        func panelColor(_ litFactor: Double) -> RGB {
            var dayPanel = Self.mixed(panelBase, CalmCityStyle.ink, 0.30 * (1 - litFactor))
            dayPanel = Self.mixed(dayPanel, CalmCityStyle.paper, 0.25 * litFactor)
            let nightPanel = Self.mixed(panelBase, CalmCityStyle.ink, 0.45 + 0.25 * sample.night)
            return Self.mixed(nightPanel, dayPanel, daylight)
        }
        func panelLit(_ panel: Int) -> Double {
            let across = (Double(panel) + 0.5) / Double(panelCount)
            return max(0, min(1, 1 - abs(across - sunH) * 1.8))
        }

        // Rear veil sits behind the complete envelope.
        if closeDetail {
            let cloud = geometry.cloudBackBounds
            context.fill(
                Path(ellipseIn: CGRect(
                    x: cloud.minX,
                    y: cloud.minY + cloud.height * 0.36,
                    width: cloud.width * 0.56,
                    height: cloud.height * 0.44
                )),
                with: .color(nightified(CalmCityStyle.paper, sample: sample, attenuation: 0.35).opacity(0.14))
            )
            context.fill(
                Path(ellipseIn: CGRect(
                    x: cloud.minX + cloud.width * 0.27,
                    y: cloud.minY + cloud.height * 0.13,
                    width: cloud.width * 0.58,
                    height: cloud.height * 0.59
                )),
                with: .color(nightified(CalmCityStyle.lavender, sample: sample, attenuation: 0.28).opacity(0.10))
            )
            context.fill(
                Path(ellipseIn: CGRect(
                    x: cloud.minX + cloud.width * 0.61,
                    y: cloud.minY + cloud.height * 0.34,
                    width: cloud.width * 0.39,
                    height: cloud.height * 0.43
                )),
                with: .color(nightified(CalmCityStyle.paper, sample: sample, attenuation: 0.38).opacity(0.11))
            )
        }

        // Envelope skin: the geometry's camera-facing quads, already sorted
        // far -> near. Panel index picks the gore's sun response; the facet's
        // own light picks how far that gore turns away from the camera.
        for facet in geometry.facets {
            let shade: Double
            switch facet.light {
            case .top:
                shade = 0
            case .right:
                shade = 0.10
            case .left:
                shade = 0.20
            }
            context.fill(
                facet.path,
                with: .color(
                    Self.mixed(panelColor(panelLit(facet.panel)), CalmCityStyle.ink, shade).color
                )
            )
        }

        // Vertical wash from the lit crown to the shaded mouth ties the
        // faceted gores into one inflated volume. The wash covers the union
        // of the painted facets, not a chord polygon, so it still fits when
        // upper back meridians project above the crown apex.
        let mouthShade = panelColor(0)
        var envelopeOutline = Path()
        for facet in geometry.facets {
            envelopeOutline.addPath(facet.path)
        }
        context.fill(
            envelopeOutline,
            with: .linearGradient(
                Gradient(colors: [
                    panelColor(1).color.opacity(0.20),
                    RGB(r: mouthShade.r * 0.9, g: mouthShade.g * 0.9, b: mouthShade.b * 0.9).color.opacity(0.26)
                ]),
                startPoint: crown,
                endPoint: mouth
            )
        )

        // Stitched fabric definition: ink seams run crown to mouth along the
        // panel meridians, and two load tapes ride the near half of their
        // row circles, so both curve with the envelope.
        if closeDetail {
            let stitch = nightified(CalmCityStyle.ink, sample: sample)
            for panel in 1..<panelCount {
                let theta = -CGFloat.pi / 4 + .pi * CGFloat(panel) / CGFloat(panelCount)
                stroke(
                    context: &context,
                    rows.map { rowPoint($0, theta) },
                    color: stitch.opacity(0.20),
                    width: 0.5
                )
            }
            for rowIndex in [rows.count / 3, (rows.count * 2) / 3] where rowIndex < rows.count {
                let row = rows[rowIndex]
                let arc = (0...8).map { step -> CGPoint in
                    rowPoint(row, -CGFloat.pi / 4 + .pi * CGFloat(step) / 8)
                }
                stroke(
                    context: &context,
                    arc,
                    color: stitch.opacity(0.16),
                    width: 0.6
                )
            }
        }

        if closeDetail {
            let cloud = geometry.cloudFrontBounds
            context.fill(
                Path(ellipseIn: CGRect(
                    x: cloud.minX,
                    y: cloud.minY + cloud.height * 0.34,
                    width: cloud.width * 0.62,
                    height: cloud.height * 0.47
                )),
                with: .color(nightified(CalmCityStyle.paper, sample: sample, attenuation: 0.30).opacity(0.17))
            )
            context.fill(
                Path(ellipseIn: CGRect(
                    x: cloud.minX + cloud.width * 0.36,
                    y: cloud.minY + cloud.height * 0.10,
                    width: cloud.width * 0.64,
                    height: cloud.height * 0.64
                )),
                with: .color(nightified(CalmCityStyle.lavender, sample: sample, attenuation: 0.25).opacity(0.14))
            )
        }

        guard let basketTopFacet = geometry.basket.first(where: { $0.light == .top }) else { return }
        let topCorners = basketTopFacet.worldPoints

        // Pendulum sway: the basket and everything it carries slides
        // laterally along world x on a slow sine, frozen under reduceMotion.
        let swayPhase: CGFloat = reduceMotion ? 0 : CGFloat(sin(date.timeIntervalSinceReferenceDate * 0.7))
        let sway = CGSize(
            width: 0.3 * swayPhase * IsoProjection.s,
            height: 0.3 * swayPhase * IsoProjection.fy
        )
        func swayed(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x + sway.width, y: point.y + sway.height)
        }

        // Four tension lines fan from the narrow neck row down to every
        // basket top corner.
        let rigging: [(anchor: CGPoint, corner: CGPoint)] = [
            (neckL, topCorners[3].projected),
            (neckL, topCorners[0].projected),
            (neckR, topCorners[1].projected),
            (neckR, topCorners[2].projected)
        ]
        for line in rigging {
            stroke(
                context: &context,
                [line.anchor, swayed(line.corner)],
                color: nightified(CalmCityStyle.ink, sample: sample).opacity(0.55),
                width: 0.45
            )
        }

        // Cross-brace across the basket mouth stiffens the suspension
        // read: the rim reads framed, not just outlined.
        for brace in [(0, 2), (1, 3)] {
            stroke(
                context: &context,
                [
                    swayed(topCorners[brace.0].projected),
                    swayed(topCorners[brace.1].projected)
                ],
                color: nightified(CalmCityStyle.ink, sample: sample).opacity(0.35),
                width: 0.4
            )
        }

        // Burner glow: a warm radial light under the envelope mouth that
        // blooms as night falls.
        if sample.night > 0.02 {
            let glowRadius = 1.2 * IsoProjection.s
            context.fill(
                Path(ellipseIn: CGRect(
                    x: mouth.x - glowRadius,
                    y: mouth.y - glowRadius,
                    width: glowRadius * 2,
                    height: glowRadius * 2
                )),
                with: .radialGradient(
                    Gradient(colors: [
                        Color(red: 1, green: 0.62, blue: 0.25).opacity(0.35 * sample.night),
                        .clear
                    ]),
                    center: mouth,
                    startRadius: 0,
                    endRadius: glowRadius
                )
            )
        }

        let burner = swayed(geometry.burnerCenter.projected)
        let basketTop = swayed(geometry.basketTopCenter.projected)
        let localLight = lighting.localLightIntensity
        let haloOpacity = 0.04 + 0.20 * localLight
        fill(
            context: &context,
            [
                CGPoint(x: burner.x, y: burner.y - 3.0),
                CGPoint(x: burner.x + 2.15, y: burner.y),
                CGPoint(x: burner.x, y: burner.y + 2.35),
                CGPoint(x: burner.x - 2.15, y: burner.y)
            ],
            color: nightified(CalmCityStyle.marigold, sample: sample, attenuation: 0.20).opacity(haloOpacity)
        )
        let housing = CGRect(x: burner.x - 1.45, y: burner.y - 0.25, width: 2.9, height: 1.55)
        context.fill(
            Path(roundedRect: housing, cornerRadius: 0.35),
            with: .color(nightified(CalmCityStyle.ink, sample: sample).opacity(0.88))
        )
        fill(
            context: &context,
            [
                CGPoint(x: burner.x, y: burner.y - 2.05),
                CGPoint(x: burner.x + 0.92, y: burner.y - 0.28),
                CGPoint(x: burner.x, y: burner.y + 0.78),
                CGPoint(x: burner.x - 0.92, y: burner.y - 0.28)
            ],
            color: nightified(CalmCityStyle.marigold, sample: sample, attenuation: 0.15).opacity(0.32 + 0.68 * localLight)
        )
        if closeDetail {
            let phase = reduceMotion ? 0 : date.timeIntervalSinceReferenceDate
            let travel = geometry.radius * 0.42
            for index in 0..<2 {
                let offset = Double(index) * 1.7
                let rise = CGFloat((sin(phase * 1.15 + offset) + 1) * 0.5) * travel
                let start = CGPoint(
                    x: burner.x + CGFloat(sin(phase * 0.7 + offset)) * 0.55,
                    y: burner.y - 2.35 - rise
                )
                let middle = CGPoint(x: start.x + 0.52, y: start.y - 1.05)
                let end = CGPoint(x: middle.x - 0.30, y: middle.y - 0.86)
                let wispColor = index == 0
                    ? nightified(CalmCityStyle.marigold, sample: sample, attenuation: 0.30)
                    : nightified(CalmCityStyle.paper, sample: sample, attenuation: 0.35)
                stroke(
                    context: &context,
                    [start, middle, end],
                    color: wispColor.opacity(0.14 + 0.30 * localLight),
                    width: 0.38
                )
            }
        }

        context.fill(
            basketTopFacet.path.offsetBy(dx: sway.width, dy: sway.height),
            with: .color(basketFaces.top.color)
        )
        context.fill(
            basketTopFacet.path.offsetBy(dx: sway.width, dy: sway.height),
            with: .color(nightified(CalmCityStyle.marigold, sample: sample, attenuation: 0.25).opacity(0.05 + 0.19 * localLight))
        )

        // A small pool of burner light gathers inside the basket rim.
        if sample.night > 0.02 {
            let poolRadius: CGFloat = 4.0
            context.fill(
                Path(ellipseIn: CGRect(
                    x: basketTop.x - poolRadius,
                    y: basketTop.y - poolRadius,
                    width: poolRadius * 2,
                    height: poolRadius * 2
                )),
                with: .radialGradient(
                    Gradient(colors: [
                        Color(red: 1, green: 0.62, blue: 0.25).opacity(0.25 * sample.night),
                        .clear
                    ]),
                    center: basketTop,
                    startRadius: 0,
                    endRadius: poolRadius
                )
            )
        }
        if closeDetail {
            for (index, offset) in [-1.00, 0.94].enumerated() {
                let x = basketTop.x + offset
                let body = CGRect(x: x - 0.48, y: basketTop.y - 1.55, width: 0.96, height: 2.55)
                context.fill(
                    Path(roundedRect: body, cornerRadius: 0.35),
                    with: .color(ink.opacity(0.82))
                )
                let head = CGRect(x: x - 0.58, y: basketTop.y - 2.55 - CGFloat(index) * 0.14, width: 1.16, height: 1.16)
                context.fill(
                    Path(ellipseIn: head),
                    with: .color(nightified(CalmCityStyle.paper, sample: sample, attenuation: 0.50).opacity(0.86))
                )
            }
        }
        for facet in geometry.basket where facet.light != .top {
            let color: RGB
            switch facet.light {
            case .top:
                color = basketFaces.top
            case .left:
                color = basketFaces.left
            case .right:
                color = basketFaces.right
            }
            context.fill(
                facet.path.offsetBy(dx: sway.width, dy: sway.height),
                with: .color(color.color)
            )
            // Woven wicker: pale horizontal weave lines across each
            // visible side, interpolated between the bottom edge and the
            // top rim of the facet quad.
            if closeDetail {
                let points = facet.projectedPoints
                guard points.count >= 4 else { continue }
                let weave = nightified(CalmCityStyle.paper, sample: sample, attenuation: 0.50).opacity(0.45)
                for fraction in [0.38, 0.72] {
                    let bottomA = points[0]
                    let bottomB = points[1]
                    let topA = points[3]
                    let topB = points[2]
                    stroke(
                        context: &context,
                        [
                            CGPoint(
                                x: bottomA.x + (topA.x - bottomA.x) * CGFloat(fraction),
                                y: bottomA.y + (topA.y - bottomA.y) * CGFloat(fraction)
                            ),
                            CGPoint(
                                x: bottomB.x + (topB.x - bottomB.x) * CGFloat(fraction),
                                y: bottomB.y + (topB.y - bottomB.y) * CGFloat(fraction)
                            ),
                        ],
                        color: weave,
                        width: 0.45
                    )
                }
            }
        }

        // Darker rim band crowning the wood basket's visible top edges.
        let rimDrop = geometry.radius * 0.05
        let rimColor = nightified(
            Self.mixed(CalmCityStyle.road, CalmCityStyle.ink, 0.45),
            sample: sample,
            attenuation: 0.7
        )
        func rimBand(_ a: CityWorldPoint3D, _ b: CityWorldPoint3D) {
            fill(
                context: &context,
                [
                    swayed(a.projected),
                    swayed(b.projected),
                    swayed(IsoProjection.project(b.x, b.y, b.z - rimDrop)),
                    swayed(IsoProjection.project(a.x, a.y, a.z - rimDrop))
                ],
                color: rimColor
            )
        }
        rimBand(topCorners[3], topCorners[2])
        rimBand(topCorners[1], topCorners[2])

        if closeDetail {
            stroke(
                context: &context,
                [
                    swayed(geometry.basketFrontBand.start.projected),
                    swayed(geometry.basketFrontBand.end.projected)
                ],
                color: nightified(CalmCityStyle.paper, sample: sample, attenuation: 0.40).opacity(0.50),
                width: 0.76
            )
        }

        // Festival pennant: when every GPU is taken the balloon tows a
        // string of small flags that sag and flutter on a deterministic wind.
        if balloon.celebration > 0.01 {
            let phase = reduceMotion ? 0 : date.timeIntervalSinceReferenceDate
            let anchor = swayed(geometry.basketTopCenter.projected)
            let tints = [
                CalmCityStyle.coral, CalmCityStyle.marigold, CalmCityStyle.spruce,
                CalmCityStyle.lavender, CalmCityStyle.water, CalmCityStyle.paper,
            ]
            let flags = 5
            func pennantPoint(_ index: Int) -> CGPoint {
                let t = CGFloat(index) / CGFloat(flags)
                let flutter = CGFloat(sin(phase * 2.1 + Double(index) * 0.9)) * 1.2 * t
                return CGPoint(
                    x: anchor.x - t * 30,
                    y: anchor.y + 2.0 + t * 8.5 + flutter
                )
            }
            stroke(
                context: &context,
                (0...flags).map(pennantPoint),
                color: nightified(CalmCityStyle.ink, sample: sample).opacity(0.55 * balloon.celebration),
                width: 1.1
            )
            for index in 0..<flags {
                let t = (CGFloat(index) + 0.5) / CGFloat(flags)
                let flutter = CGFloat(sin(phase * 2.1 + Double(index) * 0.9 + 0.45)) * 1.2 * t
                let cx = anchor.x - t * 30
                let cy = anchor.y + 2.0 + t * 8.5 + flutter
                fill(
                    context: &context,
                    [
                        CGPoint(x: cx - 2.2, y: cy),
                        CGPoint(x: cx + 2.2, y: cy),
                        CGPoint(x: cx, y: cy + 4.2),
                    ],
                    color: nightified(tints[index % tints.count], sample: sample).opacity(0.92 * balloon.celebration)
                )
            }
        }
    }

    private func drawSearchlight(
        context: inout GraphicsContext,
        plot: CityPlot,
        building: BuildingSpec,
        angle: Angle,
        visibleRect: CGRect,
        cameraScale: CGFloat,
        sample: CityPalette.Sample
    ) {
        let roof = (
            x: plot.x + building.ox + building.bw / 2,
            y: plot.y + building.oy + building.bd / 2,
            z: building.h + 0.3
        )
        let apex = IsoProjection.project(roof.x, roof.y, roof.z)
        guard CityRenderPolicies.shouldDrawSearchlight(apex: apex, in: visibleRect) else { return }

        let geometry = CityRenderPolicies.searchlightGeometry(apex: apex, angle: angle, cameraScale: cameraScale)
        let teal = Color(red: 0.31, green: 0.89, blue: 0.76)
        // The hero light of the night: a layered wedge — soft outer edge, hot
        // core, and a near-white spine — bright enough to read at 1x while the
        // capped geometry keeps its bounded screen footprint. Daylight relaxes it.
        let nightBoost = 0.35 + 0.65 * sample.night
        // Beams fade to clear at the tip: a beam that ends mid-air should
        // dissolve, not stop, and neighboring rooftops it crosses stay
        // readable instead of taking a hard teal band.
        var wedge = Path()
        wedge.move(to: apex)
        wedge.addLine(to: geometry.left)
        wedge.addLine(to: geometry.right)
        wedge.closeSubpath()
        context.fill(
            wedge,
            with: .linearGradient(
                Gradient(colors: [teal.opacity(0.16 * nightBoost), teal.opacity(0)]),
                startPoint: apex,
                endPoint: geometry.tip
            )
        )
        let coreLeft = CGPoint(x: geometry.tip.x + (geometry.left.x - geometry.tip.x) * 0.45, y: geometry.tip.y + (geometry.left.y - geometry.tip.y) * 0.45)
        let coreRight = CGPoint(x: geometry.tip.x + (geometry.right.x - geometry.tip.x) * 0.45, y: geometry.tip.y + (geometry.right.y - geometry.tip.y) * 0.45)
        var core = Path()
        core.move(to: apex)
        core.addLine(to: coreLeft)
        core.addLine(to: coreRight)
        core.closeSubpath()
        context.fill(
            core,
            with: .linearGradient(
                Gradient(colors: [Color(red: 0.62, green: 0.97, blue: 0.88).opacity(0.22 * nightBoost), Color(red: 0.62, green: 0.97, blue: 0.88).opacity(0)]),
                startPoint: apex,
                endPoint: geometry.tip
            )
        )
        // Spine as a fading ribbon: strokes cannot gradient, so a narrow
        // triangle standing in for the line lets the hot core dissolve too.
        let spineAngle = atan2(geometry.tip.y - apex.y, geometry.tip.x - apex.x)
        let spineHalf = (0.55 / max(cameraScale, 0.01))
        let perp = CGPoint(x: -sin(spineAngle) * spineHalf, y: cos(spineAngle) * spineHalf)
        var spine = Path()
        spine.move(to: apex)
        spine.addLine(to: CGPoint(x: geometry.tip.x + perp.x, y: geometry.tip.y + perp.y))
        spine.addLine(to: CGPoint(x: geometry.tip.x - perp.x, y: geometry.tip.y - perp.y))
        spine.closeSubpath()
        context.fill(
            spine,
            with: .linearGradient(
                Gradient(colors: [Color(red: 0.91, green: 0.97, blue: 0.96).opacity(0.5 * nightBoost), Color(red: 0.91, green: 0.97, blue: 0.96).opacity(0)]),
                startPoint: apex,
                endPoint: geometry.tip
            )
        )

        let ink = Color(red: 0.02, green: 0.03, blue: 0.09).opacity(0.9)
        let fixtureScale = 1 / max(cameraScale, 0.01)
        drawOutlinedVoxelBox(
            context: &context,
            at: apex,
            w: 1.12 * fixtureScale,
            d: 0.94 * fixtureScale,
            h: 0.20 * fixtureScale,
            z0: -0.65 * fixtureScale,
            top: Color(red: 0.22, green: 0.68, blue: 0.67),
            se: Color(red: 0.10, green: 0.30, blue: 0.34),
            sw: Color(red: 0.07, green: 0.22, blue: 0.28),
            ink: ink,
            outlineWidth: fixtureScale
        )
        drawOutlinedVoxelBox(
            context: &context,
            at: apex,
            w: 0.62 * fixtureScale,
            d: 0.54 * fixtureScale,
            h: 0.45 * fixtureScale,
            z0: -0.45 * fixtureScale,
            top: Color(red: 0.91, green: 0.97, blue: 0.96),
            se: teal.opacity(0.86),
            sw: Color(red: 0.20, green: 0.61, blue: 0.63),
            ink: ink,
            outlineWidth: fixtureScale
        )

    }

    /// Typography ramp: the diorama stays wordless at province, node plates
    /// bloom through the city band, and street zoom hands off to hardware
    /// signage and job lines as the plates retire.
    private func nodeLabelOpacity(scale: CGFloat) -> Double {
        let fadeIn = max(0, min(1, Double((scale - 0.8) / 0.7)))
        let fadeOut = max(0, min(1, Double((3.5 - scale) / 2)))
        return min(fadeIn, fadeOut)
    }

    private func citySignageOpacity(scale: CGFloat) -> Double {
        max(0, min(1, Double((scale - 2.2) / 1.2)))
    }

    func renderBounds(for plot: CityPlot) -> CGRect {
        let maximumHeight = max(10, plot.buildings.map { $0.h * constructionGrowScaleMaximum }.max() ?? 0)
        return projectedBounds(for: [
            IsoProjection.project(plot.x, plot.y),
            IsoProjection.project(plot.x + plot.w, plot.y),
            IsoProjection.project(plot.x, plot.y + plot.d),
            IsoProjection.project(plot.x + plot.w, plot.y + plot.d),
            IsoProjection.project(plot.x, plot.y, maximumHeight),
            IsoProjection.project(plot.x + plot.w, plot.y, maximumHeight),
            IsoProjection.project(plot.x, plot.y + plot.d, maximumHeight),
            IsoProjection.project(plot.x + plot.w, plot.y + plot.d, maximumHeight),
        ])
    }

    private func projectedBounds(for points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .null }
        return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) {
            $0.union(CGRect(origin: $1, size: .zero))
        }
    }



    private func drawStaticPlot(
        context: inout GraphicsContext,
        overlayContext: inout GraphicsContext,
        plot: CityPlot,
        date: Date,
        sample: CityPalette.Sample,
        scale: CGFloat,
        camera: CityCamera,
        band: ZoomBand,
        lod: CityDetailLevel
    ) {
        if band != .province {
            for building in plot.buildings {
                fill(context: &context, Self.shadowQuad(x: plot.x + building.ox, y: plot.y + building.oy, bw: building.bw, bd: building.bd, h: building.h), color: .black.opacity(0.20))
            }
        }
        let closed = plot.mode == .closed
        box(context: &context, x: plot.x, y: plot.y, w: plot.w, d: plot.d, h: 0.7, top: surfaceColor(day: RGB(r: 118, g: 126, b: 136), night: RGB(r: 34, g: 40, b: 48), sample: sample, attenuation: 0.75), se: surfaceColor(day: RGB(r: 104, g: 112, b: 122), night: RGB(r: 26, g: 30, b: 36), sample: sample, attenuation: 0.75), sw: surfaceColor(day: RGB(r: 96, g: 104, b: 114), night: RGB(r: 21, g: 25, b: 30), sample: sample, attenuation: 0.75))
        if plot.mode == .vacant { dashedPlot(context: &context, plot: plot) }
        if plot.mode == .lit, plot.node.jobs.contains(where: { $0.state == "RUNNING" }) {
            let corners = [
                IsoProjection.project(plot.x, plot.y, 0.7),
                IsoProjection.project(plot.x + plot.w, plot.y, 0.7),
                IsoProjection.project(plot.x + plot.w, plot.y + plot.d, 0.7),
                IsoProjection.project(plot.x, plot.y + plot.d, 0.7),
            ]
            stroke(context: &context, corners + [corners[0]], color: Color(red: 0.31, green: 0.89, blue: 0.76).opacity(0.30), width: 0.8)
        }
        for (index, building) in plot.buildings.enumerated() {
            drawStaticBuilding(context: &context, building: building, plot: plot, index: index, date: date, sample: sample, windowFill: CityWindows.runningJobPressure(for: plot.node), cameraScale: scale, band: band, lod: lod)
        }
        drawShops(context: &context, plot: plot, date: date, sample: sample, band: band, lod: lod)
        if plot.mode != .closed {
            for tree in plot.trees { drawTree(context: &context, tree: tree, sample: sample) }
        }
        if closed { drawClosedMarkers(context: &context, plot: plot) }
    }

    private func fillSoftRadialEllipse(
        context: inout GraphicsContext,
        center: CGPoint,
        radiusX: CGFloat,
        radiusY: CGFloat,
        color: Color
    ) {
        guard radiusX > 0, radiusY > 0 else { return }
        var ellipseContext = context
        ellipseContext.concatenate(
            CGAffineTransform(translationX: center.x, y: center.y)
                .scaledBy(x: 1, y: radiusY / radiusX)
                .translatedBy(x: -center.x, y: -center.y)
        )
        ellipseContext.fill(
            Path(
                ellipseIn: CGRect(
                    x: center.x - radiusX,
                    y: center.y - radiusX,
                    width: radiusX * 2,
                    height: radiusX * 2
                )
            ),
            with: .radialGradient(
                Gradient(colors: [color, .clear]),
                center: center,
                startRadius: 0,
                endRadius: radiusX
            )
        )
    }

    static func baseWorldDepthItems(
        plots: [CityPlot],
        forest: [Tree],
        lamps: [CGPoint],
        campgrounds: [CitySceneStaticPaths.Campground] = [],
        props: [CityPlacementPlan.Prop] = [],
        parkedCars: [CityPlacementPlan.ParkedCar] = [],
        titan: CityIsometricTitanGeometry? = nil
    ) -> [BaseWorldDepthItem] {
        // Only stationary masses remain baked. The sky-side shoulder, its
        // draped upper arm, their moving joints, and the head assembly
        // animate in the live overlay.
        let titanSolids = titan?.groundedSolids ?? []
        var entries: [(key: CGFloat, stableOrder: Int, item: BaseWorldDepthItem)] = []
        entries.reserveCapacity(
            plots.count + forest.count + lamps.count + campgrounds.count
                + props.count + parkedCars.count + titanSolids.count
        )

        for plot in plots {
            // Back-corner key: the plot podium is a 0.7wu extrusion, so any
            // object standing in front of its near edges (lamps, props, trees
            // on the sidewalk) must draw AFTER it. The old front-corner key
            // sorted the plot after everything behind its near corner, which
            // let the podium slab and buildings paint over street-side
            // fixtures standing in front of them.
            entries.append((
                key: IsoProjection.sortKey(x: plot.x, y: plot.y),
                stableOrder: entries.count,
                item: .plot(plot)
            ))
        }
        for tree in forest {
            entries.append((
                key: IsoProjection.sortKey(x: tree.x, y: tree.y),
                stableOrder: entries.count,
                item: .forestTree(tree)
            ))
        }
        for campground in campgrounds {
            entries.append((
                key: IsoProjection.sortKey(
                    x: campground.center.x,
                    y: campground.center.y
                ),
                stableOrder: entries.count,
                item: .campground(campground)
            ))
        }
        for lamp in lamps {
            entries.append((
                key: IsoProjection.sortKey(x: lamp.x, y: lamp.y),
                stableOrder: entries.count,
                item: .lamp(lamp)
            ))
        }
        for prop in props {
            entries.append((
                key: IsoProjection.sortKey(x: prop.x, y: prop.y),
                stableOrder: entries.count,
                item: .prop(prop)
            ))
        }
        for car in parkedCars {
            entries.append((
                key: IsoProjection.sortKey(x: car.x, y: car.y),
                stableOrder: entries.count,
                item: .parkedCar(car)
            ))
        }
        if let titan {
            for solid in titanSolids {
                entries.append((
                    key: solid.sortKey,
                    stableOrder: entries.count,
                    item: .titan(titan, solid)
                ))
            }
        }

        return entries.sorted {
            $0.key == $1.key ? $0.stableOrder < $1.stableOrder : $0.key < $1.key
        }.map(\.item)
    }

    private func drawDepthSortedForestPlotGeometryAndLampFixtures(
        context: inout GraphicsContext,
        plan: CityRenderPlan,
        forest: [Tree],
        sample: CityPalette.Sample,
        lighting: CityLighting.Sample,
        band: ZoomBand
    ) {
        var lamps: [CGPoint] = []
        if band != .province {
            let cullRect = plan.visibleRect.insetBy(dx: -4, dy: -4)
            lamps = scape.lamps.compactMap { lamp in
                let point = CGPoint(x: lamp.0, y: lamp.1)
                return cullRect.contains(IsoProjection.project(point.x, point.y, 0)) ? point : nil
            }
        }
        // Sidewalk props join the same depth pass: drawn in drawCityDetail
        // they sorted before every plot, so podiums and buildings painted
        // over pieces standing in front of them.
        var props: [CityPlacementPlan.Prop] = []
        if band == .street {
            let cullRect = plan.visibleRect.insetBy(dx: -6, dy: -6)
            props = staticPaths.placement.props.filter {
                cullRect.contains(IsoProjection.project($0.x, $0.y, 0))
            }
        }
        let parkedCars = band == .street
            ? staticPaths.placement.parkedCars.filter { car in
                plan.visiblePlots.contains { $0.id == car.plotID }
            }
            : []
        let titan = sleepingTitanGeometry()
        let visibleTitan = plan.visibleRect.intersects(titan.renderBounds) ? titan : nil
        if let visibleTitan {
            drawTitanContacts(context: &context, geometry: visibleTitan)
        }

        for item in Self.baseWorldDepthItems(
            plots: plan.visiblePlots,
            forest: forest,
            lamps: lamps,
            campgrounds: staticPaths.campgrounds.filter {
                plan.visibleRect.insetBy(dx: -16, dy: -10).contains(
                    IsoProjection.project($0.center.x, $0.center.y, 0)
                )
            },
            props: props,
            parkedCars: parkedCars,
            titan: visibleTitan
        ) {
            switch item {
            case let .forestTree(tree):
                drawTree(context: &context, tree: tree, sample: sample, nightAttenuation: 1)
            case let .campground(campground):
                drawCampground(
                    context: &context,
                    campground: campground,
                    sample: sample,
                    lighting: lighting,
                    band: band
                )

            case let .plot(plot):
                drawBasePlot(context: &context, plot: plot, sample: sample, lighting: lighting, band: band)
            case let .lamp(point):
                drawStreetLampFixture(
                    context: &context,
                    point: point,
                    lighting: lighting,
                    multiplier: band == .street ? 1 : 0.7
                )
            case let .prop(prop):
                drawStreetProp(context: &context, prop: prop, sample: sample)
            case let .parkedCar(car):
                guard !occlusionField.isHidden(
                    worldX: car.x,
                    worldY: car.y,
                    z: 0.5
                ) else { continue }
                let token = Self.carBodyTokens[(car.hash / 10) % Self.carBodyTokens.count]
                drawCar(
                    context: &context,
                    at: (car.x, car.y),
                    alongX: true,
                    colorToken: token,
                    sample: sample,
                    kind: Self.carKind(forHash: car.hash),
                    bodyToken: token,
                    desaturate: 0.25
                )
            case let .titan(geometry, solid):
                drawTitanSolid(
                    context: &context,
                    sample: sample,
                    geometry: geometry,
                    solid: solid
                )
            }
        }
    }

    private func drawCampground(
        context: inout GraphicsContext,
        campground: CitySceneStaticPaths.Campground,
        sample: CityPalette.Sample,
        lighting: CityLighting.Sample,
        band: ZoomBand
    ) {
        let center = campground.center
        let projectedCenter = IsoProjection.project(center.x, center.y, 0)
        let clearing = Path(ellipseIn: CGRect(
            x: projectedCenter.x - 6.5,
            y: projectedCenter.y - 3.1,
            width: 13,
            height: 6.2
        ))
        context.fill(
            clearing,
            with: .color(
                nightified(
                    Self.mixed(CalmCityStyle.ground, CalmCityStyle.paper, 0.14),
                    sample: sample
                ).opacity(0.82)
            )
        )

        let cosine = cos(campground.heading)
        let sine = sin(campground.heading)
        func worldPoint(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(
                x: center.x + x * cosine - y * sine,
                y: center.y + x * sine + y * cosine
            )
        }

        let tentOffsets = [
            CGPoint(x: -2.2, y: -0.8),
            CGPoint(x: 2.2, y: -0.4),
            CGPoint(x: 0.8, y: 1.9),
        ]
        if band == .province {
            // Far zoom keeps only soft tent silhouettes on the clearing.
            for index in 0..<min(2, min(campground.tentCount, tentOffsets.count)) {
                let offset = tentOffsets[index]
                let tent = worldPoint(offset.x, offset.y)
                let north = IsoProjection.project(tent.x, tent.y - 0.8, 0.04)
                let east = IsoProjection.project(tent.x + 1.0, tent.y, 0.04)
                let south = IsoProjection.project(tent.x, tent.y + 0.8, 0.04)
                let west = IsoProjection.project(tent.x - 1.0, tent.y, 0.04)
                let peak = IsoProjection.project(tent.x, tent.y, 1.45)
                let faces = CityPalette.faceColors(
                    base: campgroundTentAccent(seed: campground.seed, index: index),
                    sample: sample,
                    lighting: lighting,
                    nightAttenuation: 0.76
                )
                fill(context: &context, [north, east, peak], color: faces.right.color)
                fill(context: &context, [east, south, peak], color: faces.right.color.opacity(0.88))
                fill(context: &context, [south, west, peak], color: faces.left.color)
                fill(context: &context, [west, north, peak], color: faces.top.color)
            }
            return
        }

        // Painter order inside the camp: far tents, the central fire, near
        // tents, then the bench arc on the camera-near rim.
        let fireWorld = worldPoint(0, 0)
        let fireKey = fireWorld.x + fireWorld.y
        var tents: [(index: Int, world: CGPoint, key: CGFloat)] = []
        for index in 0..<min(campground.tentCount, tentOffsets.count) {
            let world = worldPoint(tentOffsets[index].x, tentOffsets[index].y)
            tents.append((index, world, world.x + world.y))
        }
        tents.sort { $0.key < $1.key }

        var fireDrawn = false
        for tent in tents {
            if !fireDrawn, tent.key >= fireKey {
                drawCampgroundFire(context: &context, center: fireWorld, seed: campground.seed, sample: sample)
                fireDrawn = true
            }
            drawCampgroundRidgeTent(
                context: &context,
                center: tent.world,
                heading: campground.heading,
                accent: campgroundTentAccent(seed: campground.seed, index: tent.index),
                sample: sample,
                band: band
            )
            if tent.index == 1 {
                drawCampgroundBackpack(context: &context, center: worldPoint(2.0, 0.55), sample: sample)
            }
        }
        if !fireDrawn {
            drawCampgroundFire(context: &context, center: fireWorld, seed: campground.seed, sample: sample)
        }

        // Two log benches arc the camera-near side at radius 2.2, each
        // rotated to face the fire: long axis tangent to its radius. The
        // 14/76-degree spread keeps one bench in the open sight channel at
        // densely forested sites, where near-rim canopies (painted after
        // the whole camp) overhang the clearing's near edge.
        for degrees in [14.0, 76.0] {
            let angle = CGFloat(degrees) * .pi / 180
            drawCampgroundRotatedBox(
                context: &context,
                cx: center.x + cos(angle) * 2.2,
                cy: center.y + sin(angle) * 2.2,
                z0: 0.02,
                w: 1.1,
                d: 0.3,
                h: 0.25,
                angle: angle + .pi / 2,
                top: nightColor(168, 128, 80, sample: sample, attenuation: 0.9),
                se: nightColor(150, 112, 70, sample: sample),
                sw: nightColor(132, 96, 58, sample: sample)
            )
        }
    }

    /// Per-tent canvas accent, shared across zoom bands so a tent keeps its
    /// color while the camera dives from province to street.
    private func campgroundTentAccent(seed: Int, index: Int) -> RGB {
        let accents = [CalmCityStyle.coral, CalmCityStyle.water, CalmCityStyle.marigold]
        return accents[(seed % 3 + index) % accents.count]
    }

    /// One crafted ridge tent: two-tone fabric panels over a wooden ridge
    /// pole with uprights, an ink door triangle on the near panel, guy ropes
    /// with stake dots (street zoom), and a soft groundsheet underneath.
    private func drawCampgroundRidgeTent(
        context: inout GraphicsContext,
        center: CGPoint,
        heading: CGFloat,
        accent: RGB,
        sample: CityPalette.Sample,
        band: ZoomBand
    ) {
        let halfLength: CGFloat = 0.95
        let halfDepth: CGFloat = 0.7
        let ridgeHeight: CGFloat = 1.1
        let eaveZ: CGFloat = 0.03
        let cosine = cos(heading)
        let sine = sin(heading)
        func point(_ lx: CGFloat, _ ly: CGFloat, _ z: CGFloat) -> CGPoint {
            IsoProjection.project(
                center.x + lx * cosine - ly * sine,
                center.y + lx * sine + ly * cosine,
                z
            )
        }

        // Soft groundsheet peeking out from under the canvas.
        let sheet = point(0, 0, 0.02)
        context.fill(
            Path(ellipseIn: CGRect(x: sheet.x - 10.5, y: sheet.y - 5.6, width: 21, height: 11.2)),
            with: .color(
                nightified(Self.mixed(CalmCityStyle.ground, CalmCityStyle.paper, 0.5), sample: sample)
                    .opacity(0.5)
            )
        )

        let ridgeA = point(-halfLength, 0, ridgeHeight)
        let ridgeB = point(halfLength, 0, ridgeHeight)
        let eaveNW = point(-halfLength, -halfDepth, eaveZ)
        let eaveNE = point(halfLength, -halfDepth, eaveZ)
        let eaveSW = point(-halfLength, halfDepth, eaveZ)
        let eaveSE = point(halfLength, halfDepth, eaveZ)

        let southNear = (eaveSW.y + eaveSE.y) / 2 > (eaveNW.y + eaveNE.y) / 2
        let westNear = (eaveNW.y + eaveSW.y) / 2 > (eaveNE.y + eaveSE.y) / 2
        let nearPanelColor = nightified(Self.mixed(CalmCityStyle.paper, accent, 0.55), sample: sample, attenuation: 0.85)
        let farPanelColor = nightified(Self.mixed(CalmCityStyle.paper, accent, 0.72), sample: sample, attenuation: 0.95)
        let nearGableColor = nightified(Self.mixed(CalmCityStyle.paper, accent, 0.62), sample: sample, attenuation: 0.9)
        let farGableColor = nightified(Self.mixed(CalmCityStyle.paper, accent, 0.72), sample: sample, attenuation: 1)
        let wood = nightColor(150, 112, 70, sample: sample)

        // Far upright first so the canvas overlaps its foot.
        let farUprightX = westNear ? halfLength + 0.05 : -halfLength - 0.05
        stroke(
            context: &context,
            [point(farUprightX, 0, 0.02), point(farUprightX, 0, ridgeHeight + 0.05)],
            color: wood,
            width: 0.55
        )

        fill(context: &context, westNear ? [eaveSE, eaveNE, ridgeB] : [eaveNW, eaveSW, ridgeA], color: farGableColor)
        fill(context: &context, southNear ? [eaveNW, eaveNE, ridgeB, ridgeA] : [eaveSW, eaveSE, ridgeB, ridgeA], color: farPanelColor)
        fill(context: &context, southNear ? [eaveSW, eaveSE, ridgeB, ridgeA] : [eaveNW, eaveNE, ridgeB, ridgeA], color: nearPanelColor)
        fill(context: &context, westNear ? [eaveNW, eaveSW, ridgeA] : [eaveSE, eaveNE, ridgeB], color: nearGableColor)

        // Ink door triangle sitting on the near panel's slope.
        let side: CGFloat = southNear ? 1 : -1
        func panelPoint(_ lx: CGFloat, _ fraction: CGFloat) -> CGPoint {
            point(
                lx,
                side * halfDepth * (1 - fraction),
                eaveZ + fraction * (ridgeHeight - eaveZ)
            )
        }
        fill(
            context: &context,
            [panelPoint(-0.225, 0.02), panelPoint(0.225, 0.02), panelPoint(0, 0.68)],
            color: nightified(CalmCityStyle.ink, sample: sample, attenuation: 0.8).opacity(0.55)
        )

        // Street zoom adds guy ropes from each ridge end to a stake set
        // 0.55 out beyond the near corner, dotted with an ink stake.
        if band == .street {
            let ropeColor = nightified(CalmCityStyle.ink, sample: sample, attenuation: 0.75).opacity(0.5)
            for end in [-halfLength, halfLength] {
                let corner = CGPoint(x: end, y: side * halfDepth)
                let length = hypot(corner.x, corner.y)
                let stake = CGPoint(
                    x: corner.x + corner.x / length * 0.55,
                    y: corner.y + corner.y / length * 0.55
                )
                let stakePoint = point(stake.x, stake.y, 0.02)
                stroke(
                    context: &context,
                    [point(end, 0, ridgeHeight), stakePoint],
                    color: ropeColor,
                    width: 0.4
                )
                context.fill(
                    Path(ellipseIn: CGRect(x: stakePoint.x - 0.22, y: stakePoint.y - 0.12, width: 0.44, height: 0.24)),
                    with: .color(nightified(CalmCityStyle.ink, sample: sample, attenuation: 0.75).opacity(0.65))
                )
            }
        }

        // Near upright and the ridge pole with its 0.25 overhang per end.
        let nearUprightX = westNear ? -halfLength - 0.05 : halfLength + 0.05
        stroke(
            context: &context,
            [point(nearUprightX, 0, 0.02), point(nearUprightX, 0, ridgeHeight + 0.05)],
            color: wood,
            width: 0.55
        )
        stroke(
            context: &context,
            [point(-halfLength - 0.25, 0, ridgeHeight + 0.04), point(halfLength + 0.25, 0, ridgeHeight + 0.04)],
            color: wood,
            width: 0.6
        )
    }

    /// Stone-ring campfire at the clearing's heart: six stones, two crossed
    /// logs, and once dusk settles an ember glow with two flame teardrops
    /// over a warm ground pool. Flame flicker is seeded per site; reduced
    /// motion pins the flames to their rest height.
    private func drawCampgroundFire(
        context: inout GraphicsContext,
        center: CGPoint,
        seed: Int,
        sample: CityPalette.Sample
    ) {
        let hearth = IsoProjection.project(center.x, center.y, 0.06)
        let night = sample.night
        let ember = min(max((night - 0.3) / 0.7, 0), 1)

        if night > 0.3 {
            fillSoftRadialEllipse(
                context: &context,
                center: IsoProjection.project(center.x, center.y, 0.02),
                radiusX: 13.75,
                radiusY: 6.9,
                color: Color(red: 1, green: 0.62, blue: 0.30).opacity(0.10 * night)
            )
            fillSoftRadialEllipse(
                context: &context,
                center: hearth,
                radiusX: 8.8,
                radiusY: 4.4,
                color: Color(red: 1, green: 0.55, blue: 0.2).opacity(0.5 * ember)
            )
        }

        // Ring of six small stone boxes.
        let stoneTop = nightColor(158, 156, 168, sample: sample, attenuation: 0.9)
        let stoneSE = nightColor(150, 148, 160, sample: sample)
        let stoneSW = nightColor(128, 126, 140, sample: sample)
        let ringOffset = CGFloat(seed % 60) * .pi / 180
        for index in 0..<6 {
            let angle = ringOffset + CGFloat(index) * .pi / 3
            let sx = center.x + cos(angle) * 0.5
            let sy = center.y + sin(angle) * 0.5
            box(
                context: &context,
                x: sx - 0.08,
                y: sy - 0.08,
                w: 0.16,
                d: 0.16,
                h: 0.18,
                z0: 0.02,
                top: stoneTop,
                se: stoneSE,
                sw: stoneSW
            )
        }

        // Two crossed logs, rotated 60 degrees apart.
        let logTop = nightColor(136, 100, 62, sample: sample, attenuation: 0.9)
        let logSE = nightColor(118, 84, 50, sample: sample)
        let logSW = nightColor(104, 72, 42, sample: sample)
        let logAngle = CGFloat((seed >> 5) % 60) * .pi / 180
        for index in 0..<2 {
            drawCampgroundRotatedBox(
                context: &context,
                cx: center.x,
                cy: center.y,
                z0: 0.04 + CGFloat(index) * 0.05,
                w: 0.7,
                d: 0.14,
                h: 0.14,
                angle: logAngle + CGFloat(index) * .pi / 3,
                top: logTop,
                se: logSE,
                sw: logSW
            )
        }

        guard night > 0.3 else { return }
        // Two teardrop flames flickering with a deterministic per-site phase.
        let time = reduceMotion ? 0 : Date().timeIntervalSinceReferenceDate
        let phase = Double(seed % 6_283) / 1_000
        for index in 0..<2 {
            let flicker = reduceMotion
                ? 1
                : 1 + 0.15 * sin(time * 7 + phase + Double(index) * 2.1)
            let height = CGFloat(1.375 * flicker)
            let halfWidth = CGFloat(0.42 * flicker)
            let base = CGPoint(
                x: hearth.x + (index == 0 ? -0.5 : 0.5),
                y: hearth.y - 1.1 + CGFloat(index) * 0.25
            )
            var flame = Path()
            flame.move(to: base)
            flame.addCurve(
                to: CGPoint(x: base.x, y: base.y - height),
                control1: CGPoint(x: base.x + halfWidth, y: base.y - height * 0.2),
                control2: CGPoint(x: base.x + halfWidth * 0.5, y: base.y - height * 0.75)
            )
            flame.addCurve(
                to: base,
                control1: CGPoint(x: base.x - halfWidth * 0.5, y: base.y - height * 0.75),
                control2: CGPoint(x: base.x - halfWidth, y: base.y - height * 0.2)
            )
            context.fill(
                flame,
                with: .color(Color(red: 1, green: 0.72, blue: 0.30).opacity(0.9 * ember))
            )
        }
    }

    /// A little coral backpack resting beside one tent, darker flap on top.
    private func drawCampgroundBackpack(
        context: inout GraphicsContext,
        center: CGPoint,
        sample: CityPalette.Sample
    ) {
        box(
            context: &context,
            x: center.x - 0.15,
            y: center.y - 0.11,
            w: 0.3,
            d: 0.22,
            h: 0.4,
            z0: 0.02,
            top: nightified(Self.mixed(CalmCityStyle.coral, CalmCityStyle.ink, 0.3), sample: sample, attenuation: 0.9),
            se: nightified(CalmCityStyle.coral, sample: sample, attenuation: 0.85),
            sw: nightified(CalmCityStyle.coral, sample: sample)
        )
    }

    /// A small axis-free box: top plus the two camera-facing sides, used for
    /// benches and fire logs that sit rotated on the clearing floor.
    private func drawCampgroundRotatedBox(
        context: inout GraphicsContext,
        cx: CGFloat,
        cy: CGFloat,
        z0: CGFloat,
        w: CGFloat,
        d: CGFloat,
        h: CGFloat,
        angle: CGFloat,
        top: Color,
        se: Color,
        sw: Color
    ) {
        let cosine = cos(angle)
        let sine = sin(angle)
        let hw = w / 2
        let hd = d / 2
        let corners: [(x: CGFloat, y: CGFloat)] = [(hw, hd), (-hw, hd), (-hw, -hd), (hw, -hd)]
        func world(_ local: (x: CGFloat, y: CGFloat)) -> CGPoint {
            CGPoint(
                x: cx + local.x * cosine - local.y * sine,
                y: cy + local.x * sine + local.y * cosine
            )
        }
        let topFace = corners.map { IsoProjection.project(world($0).x, world($0).y, z0 + h) }
        let bottomFace = corners.map { IsoProjection.project(world($0).x, world($0).y, z0) }
        // Edges 0-1, 1-2, 2-3, 3-0 carry outward normals for the local
        // +y, -x, -y, +x faces; a face is visible when its world normal
        // points toward the camera at (+x, +y).
        let faces: [(from: Int, to: Int, normalX: CGFloat, normalY: CGFloat, isSE: Bool)] = [
            (0, 1, -sine, cosine, false),
            (1, 2, -cosine, -sine, true),
            (2, 3, sine, -cosine, false),
            (3, 0, cosine, sine, true),
        ]
        for face in faces where face.normalX + face.normalY > 0 {
            fill(
                context: &context,
                [bottomFace[face.from], bottomFace[face.to], topFace[face.to], topFace[face.from]],
                color: face.isSE ? se : sw
            )
        }
        fill(context: &context, topFace, color: top)
    }

    private func drawStreetLampPools(
        context: inout GraphicsContext,
        visibleRect: CGRect,
        lighting: CityLighting.Sample,
        multiplier: Double
    ) {
        for lamp in scape.lamps {
            let ground = IsoProjection.project(lamp.0, lamp.1, 0)
            guard visibleRect.insetBy(dx: -8, dy: -8).contains(ground) else { continue }
            let poolOpacity = CityLighting.streetLampPoolOpacity(
                for: lighting,
                detailScale: multiplier
            )
            fillSoftRadialEllipse(
                context: &context,
                center: ground,
                radiusX: 8 * multiplier,
                radiusY: 4 * multiplier,
                color: Color(red: 1, green: 0.80, blue: 0.47).opacity(poolOpacity)
            )
        }
    }

    private func drawStreetLampFixture(
        context: inout GraphicsContext,
        point: CGPoint,
        lighting: CityLighting.Sample,
        multiplier: Double
    ) {
        let ground = IsoProjection.project(point.x, point.y, 0)
        guard !occlusionField.isHidden(
            worldX: point.x,
            worldY: point.y,
            z: 3.1
        ) else { return }

        let top = IsoProjection.project(point.x, point.y, 2.6)
        let headGlow = IsoProjection.project(point.x, point.y, 3.1)
        let haloRadius = 3.2 * multiplier
        context.fill(
            Path(
                ellipseIn: CGRect(
                    x: headGlow.x - haloRadius,
                    y: headGlow.y - haloRadius,
                    width: haloRadius * 2,
                    height: haloRadius * 2
                )
            ),
            with: .radialGradient(
                Gradient(colors: [
                    Color(red: 1, green: 0.74, blue: 0.30).opacity(
                        CityLighting.streetLampHeadOpacity(for: lighting, detailScale: multiplier)
                    ),
                    .clear,
                ]),
                center: headGlow,
                startRadius: 0,
                endRadius: haloRadius
            )
        )
        stroke(
            context: &context,
            [ground, top],
            color: Color(red: 0.10, green: 0.09, blue: 0.13).opacity(0.95),
            width: 1.05 * multiplier
        )
        let head = 0.62 * multiplier
        outlinedVoxelBox(
            context: &context,
            x: point.x - head / 2,
            y: point.y - head / 2,
            w: head,
            d: head,
            h: 2.6 + head,
            z0: 2.6,
            top: Color(red: 1, green: 0.80, blue: 0.38)
                .opacity(0.70 + 0.30 * lighting.localLightIntensity),
            se: Color(red: 0.98, green: 0.60, blue: 0.20)
                .opacity(0.70 + 0.30 * lighting.localLightIntensity),
            sw: Color(red: 0.80, green: 0.44, blue: 0.12)
                .opacity(0.70 + 0.30 * lighting.localLightIntensity),
            outlineWidth: 0.8 * multiplier
        )
        // Dark lantern cap: a small hat above the emissive head so the lamp
        // reads as one object even when the pole thins out at distance.
        let cap = 0.40 * multiplier
        outlinedVoxelBox(
            context: &context,
            x: point.x - cap / 2,
            y: point.y - cap / 2,
            w: cap,
            d: cap,
            h: 2.6 + head + 0.16,
            z0: 2.6 + head,
            top: Color(red: 0.22, green: 0.20, blue: 0.26).opacity(0.95),
            se: Color(red: 0.15, green: 0.13, blue: 0.18).opacity(0.95),
            sw: Color(red: 0.12, green: 0.10, blue: 0.15).opacity(0.95),
            outlineWidth: 0.5 * multiplier
        )
    }

    private func drawBuildingLightPools(
        context: inout GraphicsContext,
        pavilions: [BuildingSpec],
        plot: CityPlot,
        lighting: CityLighting.Sample,
        sample: CityPalette.Sample,
        band: ZoomBand
    ) {
        guard band != .province, plot.mode == .lit || plot.mode == .half else { return }
        let detailScale = band == .street ? 1.0 : 0.65
        let occupancy = CityWindows.occupancyFraction(
            jobPressure: CityWindows.runningJobPressure(for: plot.node),
            t: sample.t
        )
        let opacity = CityLighting.windowPoolOpacity(
            for: lighting,
            utilization: occupancy,
            detailScale: detailScale
        )
        guard opacity > 0.01 else { return }

        for (index, building) in pavilions.enumerated() where plot.mode == .lit || index == 0 {
            let center = IsoProjection.project(
                plot.x + building.ox + building.bw * 0.5,
                plot.y + building.oy + building.bd + 0.55,
                0.72
            )
            let radius = max(4, min(10, (building.bw + building.bd) * 0.65))
            fillSoftRadialEllipse(
                context: &context,
                center: center,
                radiusX: radius,
                radiusY: radius * 0.38,
                color: Color(red: 1, green: 0.64, blue: 0.28).opacity(opacity)
            )
        }
    }

    private func drawStaticBuilding(context: inout GraphicsContext, building: BuildingSpec, plot: CityPlot, index: Int, date: Date, sample: CityPalette.Sample, windowFill: Double, cameraScale: CGFloat, band: ZoomBand, lod: CityDetailLevel) {
        let x = plot.x + building.ox, y = plot.y + building.oy
        let lit = plot.mode == .lit || plot.mode == .half
        let cracked = (plot.mode == .vacant || plot.mode == .closed) && building.crackSeed
        let halfLit = plot.mode == .half && index == 0
        let scale: CGFloat = 1
        let base = CityPalette.buildingBase(lit: lit, sample: sample, facade: building.facade)
        let faces = CityPalette.faceColors(base: base, sample: sample, nightAttenuation: 0.92)
        let outlineWidth: CGFloat = switch band {
        case .province: 0.3
        case .city: 0.55
        case .street: 0.9
        }
        for tier in building.tiers {
            let h1 = building.h * tier.f1 * scale
            guard h1 - building.h * tier.f0 * scale > 0.01 else { continue }
            let inset = tier.inset
            outlinedVoxelBox(
                context: &context,
                x: x + inset, y: y + inset, w: building.bw - inset * 2, d: building.bd - inset * 2, h: h1,
                top: faces.top.color, se: faces.right.color, sw: faces.left.color, outlineWidth: outlineWidth
            )
        }
        let seed = stableByteHash("\(plot.id)-\(index)")
        let progress = plot.node.determiningJob.flatMap { $0.state == "RUNNING" ? $0.progress : nil }
        let windowFade = CityRenderPolicies.windowFacadeOpacity(lod: lod)
        guard windowFade > 0,
              let grid = Self.windowGrid(scale: cameraScale, h: building.h, bw: building.bw, bd: building.bd) else {
            if cracked { drawBuildingCracks(context: &context, building: building, plot: plot, index: index) }
            drawRoofFixtures(context: &context, building: building, plot: plot, date: date, sample: sample, band: band)
            drawBuildingNeon(context: &context, building: building, plot: plot, index: index, date: date, sample: sample)
            return
        }
        var litWindows = Path(), unlitWindows = Path()
        let windowColor: Color = switch plot.mode {
        case .closed:
            Color(red: 1, green: 0.30, blue: 0.20)
        case .vacant:
            Color(red: 0.30, green: 0.40, blue: 0.60)
        case .lit, .half:
            stableByteHash("\(plot.id)-\(index)-window-hue") % 10 < 6
                ? Color(red: 1, green: 0.82, blue: 0.25)
                : Color(red: 0.25, green: 0.88, blue: 0.92)
        }
        let facades: [(plane: Int, columns: Int)] = [(0, grid.frontColumns), (1, grid.sideColumns)]
        for (plane, columns) in facades {
            for row in 0..<grid.rows {
                for column in 0..<columns {
                    let sequence = plane * 1000 + row * columns + column
                    let enabled = lit && (!halfLit || column < columns / 2)
                    let rowFraction = 1 - (Double(row) + 0.7) / Double(grid.rows + 1)
                    let effectiveLoad = min(1, windowFill * CityWindows.floorLoadMultiplier(progress: progress, rowFraction: rowFraction))
                    let on = enabled && CityWindows.isLit(buildingSeed: seed, sequence: sequence, t: sample.t, load: effectiveLoad)
                    let wz = building.h - (CGFloat(row) + 0.7) * building.h / CGFloat(grid.rows + 1)
                    let fraction = wz / max(building.h, 0.001)
                    let inset = building.tiers.first(where: { fraction >= $0.f0 && fraction <= $0.f1 })?.inset ?? building.tiers.last?.inset ?? 0
                    let p = plane == 0
                        ? IsoProjection.project(x + inset + (CGFloat(column) + 0.5) * (building.bw - inset * 2) / CGFloat(columns), y + building.bd - inset + 0.02, wz)
                        : IsoProjection.project(x + building.bw - inset + 0.02, y + inset + (CGFloat(column) + 0.5) * (building.bd - inset * 2) / CGFloat(columns), wz)
                    let pitch = (1.4 + min(1, max(0, (cameraScale - 1.9) / (3.2 - 1.9))) * 0.3) * 1.6
                    if on { Self.addFacadeCell(&litWindows, center: p, halfW: pitch * 0.8 / 2, halfH: pitch * 0.8 / 2, sideFace: plane == 1) } else { Self.addFacadeCell(&unlitWindows, center: p, halfW: pitch * 0.8 / 2, halfH: pitch * 0.8 / 2, sideFace: plane == 1) }
                }
            }
        }
        context.fill(litWindows, with: .color(windowColor.opacity(0.95 * windowFade)))
        context.fill(unlitWindows, with: .color(Color(red: 0.30, green: 0.40, blue: 0.60).opacity((plot.mode == .vacant ? 0.28 : 0.12) * windowFade)))
        if cracked { drawBuildingCracks(context: &context, building: building, plot: plot, index: index) }
        drawRoofFixtures(context: &context, building: building, plot: plot, date: date, sample: sample, band: band); drawBuildingNeon(context: &context, building: building, plot: plot, index: index, date: date, sample: sample)
    }

    private func drawBuildingCracks(context: inout GraphicsContext, building: BuildingSpec, plot: CityPlot, index: Int) {
        let x = plot.x + building.ox
        let y = plot.y + building.oy
        let seed = stableByteHash("\(plot.id)-\(index)-crack")
        let normalizedSeed = seed & Int.max
        let sideFace = normalizedSeed.isMultiple(of: 2)
        let phase = CGFloat(normalizedSeed % 997) / 997
        let lower = building.h * (0.22 + 0.08 * phase)
        let upper = min(building.h - 0.18, building.h * (0.70 + 0.10 * phase))
        guard upper > lower else { return }
        let mid = (lower + upper) / 2
        let points: [CGPoint]
        if sideFace {
            let y0 = y + building.bd * (0.28 + 0.36 * phase)
            points = [
                IsoProjection.project(x + building.bw + 0.035, y0, upper),
                IsoProjection.project(x + building.bw + 0.035, min(y + building.bd, y0 + 0.42), mid),
                IsoProjection.project(x + building.bw + 0.035, max(y, y0 - 0.36), lower),
            ]
        } else {
            let x0 = x + building.bw * (0.26 + 0.38 * phase)
            points = [
                IsoProjection.project(x0, y + building.bd + 0.035, upper),
                IsoProjection.project(min(x + building.bw, x0 + 0.45), y + building.bd + 0.035, mid),
                IsoProjection.project(max(x, x0 - 0.34), y + building.bd + 0.035, lower),
            ]
        }
        stroke(context: &context, points, color: Color(red: 0.02, green: 0.025, blue: 0.035).opacity(0.55), width: 0.5)
    }

    private func outlinedVoxelBox(
        context: inout GraphicsContext,
        x: CGFloat, y: CGFloat, w: CGFloat, d: CGFloat, h: CGFloat, z0: CGFloat = 0,
        top: Color, se: Color, sw: Color, outlineWidth: CGFloat
    ) {
        let a = IsoProjection.project(x, y, h), b = IsoProjection.project(x + w, y, h)
        let c = IsoProjection.project(x + w, y + d, h), e = IsoProjection.project(x, y + d, h)
        let b0 = IsoProjection.project(x + w, y, z0), c0 = IsoProjection.project(x + w, y + d, z0)
        let e0 = IsoProjection.project(x, y + d, z0)
        let topFace = [a, b, c, e], rightFace = [b, b0, c0, c], leftFace = [e, c, c0, e0]
        fill(context: &context, topFace, color: top)
        fill(context: &context, rightFace, color: se)
        fill(context: &context, leftFace, color: sw)
        // Soft top-rim highlight instead of ink contours keeps the toy look line-free.
        stroke(context: &context, topFace + [a], color: .white.opacity(0.16), width: outlineWidth)
    }
    private func avenuePath() -> Path {
        var path = Path()
        let points = scape.avenue.map { IsoProjection.project($0.0, $0.1, 0.06) }
        if let first = points.first { path.move(to: first); path.addLines(Array(points.dropFirst())) }
        return path
    }

    private func drawForegroundStars(context: inout GraphicsContext, size: CGSize, sample: CityPalette.Sample) {
        let yellow = Color(red: 1, green: 0.82, blue: 0.25).opacity(0.84 * sample.night)
        for point in [
            CGPoint(x: size.width * 0.18, y: size.height * 0.09),
            CGPoint(x: size.width * 0.38, y: size.height * 0.15),
            CGPoint(x: size.width * 0.58, y: size.height * 0.07),
        ] {
            context.fill(Path(CGRect(x: point.x - 2.2, y: point.y - 0.4, width: 4.4, height: 0.8)), with: .color(yellow))
            context.fill(Path(CGRect(x: point.x - 0.4, y: point.y - 2.2, width: 0.8, height: 4.4)), with: .color(yellow))
        }
    }



    private func drawWaterShimmer(context: inout GraphicsContext, date: Date, sample: CityPalette.Sample) {
        guard CityRenderPolicies.canDrawWaterShimmer(scape.river) else { return }
        for (index, value) in Self.waterShimmerValues(for: date).enumerated() {
            let hash = value.distribution
            guard hash >= 0.5 else { continue }
            let s = (CGFloat(Double(index % 9)) / 9 + CGFloat(hash) * 0.08).truncatingRemainder(dividingBy: 1)
            // The bridge deck hides the corridor stretch; skip unseen sparkle.
            if (0.46...0.62).contains(s) { continue }
            var lateral = (CGFloat(hash) - 0.5) * 2 * (CityScape.riverHalfWidth(s) - 1.5)
            // Keep sparkle off the island lens.
            let lens = CityScape.riverIslandHalfLens(s)
            if lens > 0, lateral > CityScape.riverIslandLateral - lens - 1 {
                lateral = CityScape.riverIslandLateral - lens - 1.5
            }
            let world = CityScape.riverPoint(s, lateral: lateral)
            let point = IsoProjection.project(world.x, world.y, 0.02)
            context.fill(Path(CGRect(x: point.x, y: point.y, width: 1.8 + 3.2 * hash, height: 1.1)), with: .color(Color(red: 0.745, green: 0.839, blue: 1).opacity(0.08 + 0.26 * value.opacity)))
        }
        drawRiverRippleRings(context: &context, date: date)
        drawRiverDucks(context: &context, date: date, sample: sample)
    }

    /// Expanding-fading ripple rings at the hash-picked ripple stations:
    /// two concentric ink rings per station, radius looping 0.3 -> 0.9
    /// world units over 3 s, phased by the station hash. Reduced motion
    /// swaps the loop for a pair of static faint rings.
    private func drawRiverRippleRings(context: inout GraphicsContext, date: Date) {
        let seconds = date.timeIntervalSinceReferenceDate
        let ink = CalmCityStyle.ink.color
        for station in riverLifeStations() {
            let hash = UInt(bitPattern: Self.byteHash("river-life-\(station.index)"))
            guard hash % 6 == 4, !riverLifeNearBridge(x: station.x, y: station.y) else { continue }
            let world = CityScape.riverPoint(station.s, lateral: riverLifeOpenLateral(s: station.s, hash: hash))
            let center = IsoProjection.project(world.x, world.y, 0.02)
            if reduceMotion {
                for (radius, opacity) in [(0.5, 0.05), (0.85, 0.03)] as [(CGFloat, Double)] {
                    context.stroke(
                        Path(ellipseIn: riverLifeRingRect(center: center, radius: radius)),
                        with: .color(ink.opacity(opacity)),
                        lineWidth: 0.6
                    )
                }
            } else {
                let phase = seconds / 3 + Double((hash >> 8) % 97) / 97
                for ring in 0..<2 {
                    let progress = CGFloat((phase + Double(ring) * 0.5).truncatingRemainder(dividingBy: 1))
                    let radius = 0.3 + 0.6 * progress
                    let opacity = (ring == 0 ? 0.10 : 0.06) * Double(1 - progress * 0.75)
                    context.stroke(
                        Path(ellipseIn: riverLifeRingRect(center: center, radius: radius)),
                        with: .color(ink.opacity(opacity)),
                        lineWidth: 0.6
                    )
                }
            }
        }
    }

    /// Ground-plane circle of `radius` world units as a screen-space ellipse rect.
    private func riverLifeRingRect(center: CGPoint, radius: CGFloat) -> CGRect {
        let rx = radius * IsoProjection.s * 1.414_213_562
        let ry = radius * IsoProjection.fy * 1.414_213_562
        return CGRect(x: center.x - rx, y: center.y - ry, width: rx * 2, height: ry * 2)
    }

    /// Three toy ducks drifting slowly down-river, each on its own hashed
    /// lane: paper body, head dot ahead along the travel direction, tiny
    /// marigold beak, and a soft fading V wake. The drift loops the river
    /// in ~250 s; reduced motion freezes the flock at evenly spaced
    /// stations. The bridge deck hides the corridor stretch, so a duck
    /// under it is skipped like the sparkle. Ducks darken slightly toward
    /// dusk (ink mix scaled by the night amount).
    private func drawRiverDucks(context: inout GraphicsContext, date: Date, sample: CityPalette.Sample) {
        let seconds = reduceMotion ? 0 : date.timeIntervalSinceReferenceDate
        let unit = riverLifeUnit
        let duskMix = 0.15 * sample.night
        let bodyColor = Self.mixed(CalmCityStyle.paper, CalmCityStyle.ink, duskMix).color
        let headColor = Self.mixed(Self.mixed(CalmCityStyle.paper, CalmCityStyle.marigold, 0.2), CalmCityStyle.ink, duskMix).color
        let beakColor = Self.mixed(CalmCityStyle.marigold, CalmCityStyle.ink, duskMix).color
        let wakeColor = Self.mixed(CalmCityStyle.water, CalmCityStyle.paper, 0.5).color
        for duck in 0..<3 {
            let hash = UInt(bitPattern: Self.byteHash("river-duck-\(duck)"))
            let phase = reduceMotion
                ? Double(duck) / 3
                : (Double(duck) / 3 + seconds * 0.004).truncatingRemainder(dividingBy: 1)
            let s = CGFloat(phase)
            var lateral = (CGFloat((hash >> 6) % 81) / 81 - 0.5) * (CityScape.riverHalfWidth(s) - 2)
            let lens = CityScape.riverIslandHalfLens(s)
            if lens > 0, lateral > CityScape.riverIslandLateral - lens - 1 {
                lateral = CityScape.riverIslandLateral - lens - 1.5
            }
            let world = CityScape.riverPoint(s, lateral: lateral)
            guard !riverLifeNearBridge(x: world.x, y: world.y) else { continue }
            let point = IsoProjection.project(world.x, world.y, 0.02)
            // Screen-space heading from the flow direction at this station.
            let aheadWorld = CityScape.riverPoint(min(1, s + 0.01), lateral: lateral)
            let behindWorld = CityScape.riverPoint(max(0, s - 0.01), lateral: lateral)
            let ahead = IsoProjection.project(aheadWorld.x, aheadWorld.y, 0.02)
            let behind = IsoProjection.project(behindWorld.x, behindWorld.y, 0.02)
            let rawDir = CGPoint(x: ahead.x - behind.x, y: ahead.y - behind.y)
            let dirLen = (rawDir.x * rawDir.x + rawDir.y * rawDir.y).squareRoot()
            guard dirLen > 0.001 else { continue }
            let dir = CGPoint(x: rawDir.x / dirLen, y: rawDir.y / dirLen)
            let perp = CGPoint(x: -dir.y, y: dir.x)
            // Soft V wake trailing from the rear, fading outward.
            let rear = CGPoint(x: point.x - dir.x * 0.2 * unit, y: point.y - dir.y * 0.2 * unit)
            for side in [-1.0, 1.0] as [Double] {
                let sign = CGFloat(side)
                let mid = CGPoint(
                    x: rear.x - dir.x * 0.25 * unit + perp.x * sign * 0.07 * unit,
                    y: rear.y - dir.y * 0.25 * unit + perp.y * sign * 0.07 * unit
                )
                let tip = CGPoint(
                    x: rear.x - dir.x * 0.5 * unit + perp.x * sign * 0.18 * unit,
                    y: rear.y - dir.y * 0.5 * unit + perp.y * sign * 0.18 * unit
                )
                stroke(context: &context, [rear, mid], color: wakeColor.opacity(0.5), width: 0.8)
                stroke(context: &context, [mid, tip], color: wakeColor.opacity(0.2), width: 0.7)
            }
            // Body, head, beak.
            let bodyW = 0.4 * unit, bodyH = 0.25 * unit
            context.fill(
                Path(ellipseIn: CGRect(x: point.x - bodyW / 2, y: point.y - bodyH / 2, width: bodyW, height: bodyH)),
                with: .color(bodyColor)
            )
            let head = CGPoint(x: point.x + dir.x * 0.28 * unit, y: point.y + dir.y * 0.28 * unit - 0.05 * unit)
            let headR = 0.08 * unit
            context.fill(
                Path(ellipseIn: CGRect(x: head.x - headR, y: head.y - headR * 0.9, width: headR * 2, height: headR * 1.8)),
                with: .color(headColor)
            )
            var beak = Path()
            let beakBase = CGPoint(x: head.x + dir.x * headR * 0.8, y: head.y + dir.y * headR * 0.8)
            let beakTip = CGPoint(x: head.x + dir.x * (headR + 0.08 * unit), y: head.y + dir.y * (headR + 0.08 * unit))
            beak.move(to: CGPoint(x: beakBase.x + perp.x * 0.03 * unit, y: beakBase.y + perp.y * 0.03 * unit))
            beak.addLine(to: CGPoint(x: beakBase.x - perp.x * 0.03 * unit, y: beakBase.y - perp.y * 0.03 * unit))
            beak.addLine(to: beakTip)
            beak.closeSubpath()
            context.fill(beak, with: .color(beakColor))
        }
    }

    private func drawFarTrafficSprite(
        context: inout GraphicsContext,
        car: CityWhimsy.FarCar,
        sample: CityPalette.Sample,
        radius: CGFloat,
        band: ZoomBand
    ) {
        let point = IsoProjection.project(
            car.x - car.dirY * 0.45,
            car.y + car.dirX * 0.45,
            0.15
        )
        let rect = CGRect(
            x: point.x - radius * 0.75,
            y: point.y - radius * 0.75,
            width: radius * 1.5,
            height: radius * 1.5
        )
        let color = car.forward
            ? Color(red: 1, green: 0.957, blue: 0.82)
            : Color(red: 1, green: 0.36, blue: 0.29)
        context.fill(
            Path(rect),
            with: .color(
                color.opacity((0.20 + 0.25 * sample.night) * car.brightness)
            )
        )
        if band != .province, sample.night >= 0.3 {
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: 2.2))
                layer.fill(
                    Path(rect),
                    with: .color(color.opacity(0.35 * sample.night))
                )
            }
        }
    }

    private func drawRoofFixtures(context: inout GraphicsContext, building: BuildingSpec, plot: CityPlot, date: Date, sample: CityPalette.Sample, band: ZoomBand) {
        let x = plot.x + building.ox + building.bw / 2, y = plot.y + building.oy + building.bd / 2, z = building.h
        for fixture in building.fixtures {
            switch fixture {
            case let .waterTower(dx, dy): box(context: &context, x: x + dx - 0.45, y: y + dy - 0.45, w: 0.9, d: 0.9, h: z + 1.35, z0: z, top: nightColor(96, 74, 56, sample: sample), se: nightColor(122, 96, 72, sample: sample), sw: nightColor(74, 58, 44, sample: sample))
            case let .acUnit(dx, dy): box(context: &context, x: x + dx - 0.3, y: y + dy - 0.25, w: 0.6, d: 0.5, h: z + 0.35, z0: z, top: nightColor(150, 158, 170, sample: sample), se: nightColor(96, 104, 116, sample: sample), sw: nightColor(80, 88, 100, sample: sample))
            case let .antennaMast(height): let base = IsoProjection.project(x, y, z); let tip = IsoProjection.project(x, y, z + height); stroke(context: &context, [base, tip], color: .white.opacity(0.4), width: 0.7); stroke(context: &context, [CGPoint(x: tip.x - 0.7, y: tip.y + height * 0.35), CGPoint(x: tip.x + 0.7, y: tip.y + height * 0.35)], color: .white.opacity(0.4), width: 0.7)
            case let .smokestack(dx, dy): box(context: &context, x: x + dx - 0.175, y: y + dy - 0.175, w: 0.35, d: 0.35, h: z + 1.5, z0: z, top: nightColor(112, 118, 130, sample: sample), se: nightColor(70, 74, 84, sample: sample), sw: nightColor(70, 74, 84, sample: sample))
            case let .radarDish(dx, dy): let p = IsoProjection.project(x + dx, y + dy, z + 0.3); let angle = reduceMotion ? 1.2 : date.timeIntervalSinceReferenceDate * .pi * 2 / 5.5; context.stroke(Path(ellipseIn: CGRect(x: p.x - 2.6, y: p.y - 1.1, width: 5.2, height: 2.2)), with: .color(.white.opacity(0.5 + 0.3 * sample.night)), lineWidth: 1); let end = CGPoint(x: p.x + CGFloat(cos(angle)) * 3.4, y: p.y + CGFloat(sin(angle)) * 3.4); stroke(context: &context, [p, end], color: .white.opacity(0.5 + 0.3 * sample.night), width: 1); context.fill(Path(CGRect(x: end.x - 0.5, y: end.y - 0.5, width: 1, height: 1)), with: .color(.white.opacity(0.9)))
            }
        }
    }

    private func drawBuildingNeon(context: inout GraphicsContext, building: BuildingSpec, plot: CityPlot, index: Int, date: Date, sample: CityPalette.Sample) {
        guard (plot.mode == .lit || plot.mode == .half), let sign = building.neonSign else { return }
        let color = sign.usesMagenta ? Color(red: 1, green: 0.36, blue: 0.54) : Color(red: 0.31, green: 0.89, blue: 0.76)
        let alpha = 0.9 * CityWhimsy.neonFlicker(seed: stableByteHash("\(plot.id)-\(index)"), broken: sign.broken, date: date) * (0.35 + 0.65 * sample.night)
        var panels = Path()
        // Horizontal marquee band: cells run along the southeast parapet just
        // under the roofline, so signs read as storefront marquees rather
        // than a vertical stripe climbing the corner edge.
        let count = max(2, min(sign.segments, 5))
        let zSign = max(1.4, building.h - 0.45)
        let yFace = plot.y + building.oy + building.bd + 0.03
        let xStart = plot.x + building.ox + 0.9
        let xStride = max(0.9, (building.bw - 1.8) / CGFloat(max(1, count - 1)))
        for segment in 0..<count {
            let p = IsoProjection.project(xStart + CGFloat(segment) * xStride, yFace, zSign)
            Self.addFacadeCell(&panels, center: p, halfW: 1.05, halfH: 0.8, sideFace: true)
        }
        context.drawLayer { layer in layer.addFilter(.blur(radius: 2)); layer.fill(panels, with: .color(color.opacity(alpha * 0.5))) }
        context.fill(panels, with: .color(color.opacity(alpha)))
    }

    /// Toy woodland trees with deterministic species variety keyed off the
    /// stable position hash: spruces, poplars, and birches join the original
    /// candy lollipop (which keeps its blooming pink quarter) so plots and
    /// forest belts read as mixed woodland. All species share the sun-tracking
    /// contact shadow, keep canopies anchored to their trunk tips, and
    /// night-attenuate with the renderer's attenuation.
    private func drawTree(context: inout GraphicsContext, tree: Tree, sample: CityPalette.Sample, nightAttenuation: Double = 0.6) {
        let canopySize = 0.65 + tree.size * 0.6
        let plumpness = CGFloat(Self.voxelTreeCanopyCount(x: tree.x, y: tree.y))
        let landmarkGrowth = max(0, tree.size - 3)
        let trunk: CGFloat = 0.12 + landmarkGrowth * 0.07
        let trunkHeight: CGFloat = 0.95 + landmarkGrowth * 0.22
        // Sun-tracking contact shadow keeps trees grounded like buildings:
        // the ellipse hugs the trunk base and leans away from the sun,
        // shrinking to a faint ambient pool at night. Sample-only, so the
        // retained base stays byte-identical when jobs change.
        let sunSkew = (0.5 - sample.sunProgress) * 2 * sample.dayAmount
        let nightShrink = 1 - 0.45 * sample.night
        let shadowLean = 0.22 * nightShrink
        let shadowCenter = IsoProjection.project(
            tree.x + shadowLean * (1 - 0.7 * sunSkew),
            tree.y + shadowLean * (1 + 0.7 * sunSkew),
            0.02
        )
        let shadowR = canopySize * (2.0 + plumpness * 0.35) * nightShrink
        context.fill(
            Path(ellipseIn: CGRect(x: shadowCenter.x - shadowR, y: shadowCenter.y - shadowR * 0.5, width: shadowR * 2, height: shadowR)),
            with: .color(CalmCityStyle.ink.color.opacity(0.07 + 0.12 * sample.dayAmount))
        )
        // Deterministic species roll off the same stable position-hash family
        // as the canopy count: pines, poplars, and birches join the candy
        // lollipop so forest belts read as mixed woodland. Every species keeps
        // its canopy anchored to the trunk tip and night-attenuates with the
        // renderer's attenuation.
        let speciesKey = Int(UInt(bitPattern: stableByteHash("\(tree.x)-\(tree.y)-species")) % 20)
        switch speciesKey {
        case 0...4:
            // Pine/spruce: three stacked triangles of decreasing width on a
            // short dark trunk, bottom tier darkest, with a faint paper
            // snow-dust facet on the top tier's sun-side slope by day.
            let pineTrunk = 0.14 + landmarkGrowth * 0.07
            let pineTrunkHeight = 0.8 + landmarkGrowth * 0.22
            outlinedVoxelBox(
                context: &context, x: tree.x - pineTrunk / 2, y: tree.y - pineTrunk / 2, w: pineTrunk, d: pineTrunk, h: pineTrunkHeight,
                top: nightColor(126, 92, 66, sample: sample, attenuation: nightAttenuation),
                se: nightColor(101, 72, 50, sample: sample, attenuation: nightAttenuation),
                sw: nightColor(84, 60, 42, sample: sample, attenuation: nightAttenuation),
                outlineWidth: 0.55
            )
            let trunkTip = IsoProjection.project(tree.x, tree.y, pineTrunkHeight)
            let tierHeight = canopySize * 0.9
            let tierStep = tierHeight - canopySize * 0.25
            let tierWidths: [CGFloat] = [2.2, 1.7, 1.2]
            let tierTones = [0.5, 0.3, 0.15]
            for tier in 0..<3 {
                let baseY = trunkTip.y - CGFloat(tier) * tierStep
                let halfW = canopySize * tierWidths[tier]
                var triangle = Path()
                triangle.move(to: CGPoint(x: trunkTip.x, y: baseY - tierHeight))
                triangle.addLine(to: CGPoint(x: trunkTip.x - halfW, y: baseY))
                triangle.addLine(to: CGPoint(x: trunkTip.x + halfW, y: baseY))
                triangle.closeSubpath()
                context.fill(
                    triangle,
                    with: .color(nightified(Self.mixed(CalmCityStyle.spruce, CalmCityStyle.leafDeep, tierTones[tier]), sample: sample, attenuation: nightAttenuation))
                )
            }
            if sample.dayAmount > 0.01 {
                let topBaseY = trunkTip.y - 2 * tierStep
                let topApexY = topBaseY - tierHeight
                let topHalfW = canopySize * 1.2
                // Sun side mirrors the contact-shadow lean direction below.
                let sunDirX = -(1 - 0.7 * sunSkew)
                var facet = Path()
                facet.move(to: CGPoint(x: trunkTip.x, y: topApexY))
                facet.addLine(to: CGPoint(x: trunkTip.x + sunDirX * topHalfW * 0.55, y: topApexY + tierHeight * 0.45))
                facet.addLine(to: CGPoint(x: trunkTip.x + sunDirX * topHalfW * 0.14, y: topApexY + tierHeight * 0.34))
                facet.closeSubpath()
                context.fill(
                    facet,
                    with: .color(nightified(CalmCityStyle.paper, sample: sample, attenuation: nightAttenuation).opacity(0.18 * sample.dayAmount))
                )
            }
        case 5...7:
            // Poplar/cypress: a tall narrow column on a slim trunk, with a
            // paler stripe ellipse offset toward the sun.
            let poplarTrunk = 0.1 + landmarkGrowth * 0.07
            let poplarTrunkHeight = 0.8 + landmarkGrowth * 0.22
            outlinedVoxelBox(
                context: &context, x: tree.x - poplarTrunk / 2, y: tree.y - poplarTrunk / 2, w: poplarTrunk, d: poplarTrunk, h: poplarTrunkHeight,
                top: nightColor(126, 92, 66, sample: sample, attenuation: nightAttenuation),
                se: nightColor(101, 72, 50, sample: sample, attenuation: nightAttenuation),
                sw: nightColor(84, 60, 42, sample: sample, attenuation: nightAttenuation),
                outlineWidth: 0.55
            )
            let trunkTip = IsoProjection.project(tree.x, tree.y, poplarTrunkHeight)
            let halfW = canopySize * 0.55
            let halfH = canopySize * 1.6 * (0.9 + tree.size * 0.2)
            // The column bottom sits well under the trunk tip so the ellipse
            // visibly overlaps its stick and never floats.
            let columnBottom = IsoProjection.project(tree.x, tree.y, poplarTrunkHeight - 0.18)
            let center = CGPoint(x: trunkTip.x, y: columnBottom.y - halfH)
            let column = CGRect(x: center.x - halfW, y: center.y - halfH, width: halfW * 2, height: halfH * 2)
            context.fill(
                Path(ellipseIn: column),
                with: .color(nightified(Self.mixed(CalmCityStyle.leafDeep, CalmCityStyle.spruce, 0.4), sample: sample, attenuation: nightAttenuation))
            )
            let sunDirX = -(1 - 0.7 * sunSkew)
            let sunDirY = -(1 + 0.7 * sunSkew)
            let stripe = CGRect(
                x: center.x - halfW * 0.22 + sunDirX * halfW * 0.3,
                y: center.y - halfH * 0.9 + sunDirY * halfH * 0.1,
                width: halfW * 0.44,
                height: halfH * 1.8
            )
            context.fill(
                Path(ellipseIn: stripe),
                with: .color(nightified(Self.mixed(CalmCityStyle.leafDeep, CalmCityStyle.paper, 0.15), sample: sample, attenuation: nightAttenuation))
            )
        case 8...10:
            // Birch: smaller, paler round canopy on a paper-white trunk
            // carrying three tiny ink tick marks, alternating sides.
            outlinedVoxelBox(
                context: &context, x: tree.x - trunk / 2, y: tree.y - trunk / 2, w: trunk, d: trunk, h: trunkHeight,
                top: nightified(Self.mixed(CalmCityStyle.paper, CalmCityStyle.ink, 0.05), sample: sample, attenuation: nightAttenuation),
                se: nightified(Self.mixed(CalmCityStyle.paper, CalmCityStyle.ink, 0.14), sample: sample, attenuation: nightAttenuation),
                sw: nightified(Self.mixed(CalmCityStyle.paper, CalmCityStyle.ink, 0.22), sample: sample, attenuation: nightAttenuation),
                outlineWidth: 0.55
            )
            let tickInk = nightified(CalmCityStyle.ink, sample: sample, attenuation: nightAttenuation).opacity(0.55)
            // Heights sit on the visible part of every trunk size: the
            // canopy seat swallows the upper trunk, so the three dashes
            // live on the lower half where they stay readable.
            let tickFractions: [CGFloat] = [0.22, 0.36, 0.5]
            for (index, fraction) in tickFractions.enumerated() {
                let edge = IsoProjection.project(tree.x + trunk / 2, tree.y + trunk / 2, trunkHeight * fraction)
                let side: CGFloat = index.isMultiple(of: 2) ? -1 : 1
                context.fill(
                    Path(ellipseIn: CGRect(x: edge.x + side * 0.2 - 0.29, y: edge.y - 0.09, width: 0.58, height: 0.18)),
                    with: .color(tickInk)
                )
            }
            let trunkTip = IsoProjection.project(tree.x, tree.y, trunkHeight)
            let radius = canopySize * (2.4 + plumpness * 0.5) * 0.75
            // Seat matches the lollipop's 30%-radius overlap, but never less
            // than the trunk top diamond's drop plus margin, so even the
            // smallest pale canopy visibly swallows its stick (no floating).
            let seat = max(radius * 0.3, 2 * trunk * IsoProjection.fy + 0.35)
            let center = CGPoint(x: trunkTip.x, y: trunkTip.y - radius + seat)
            let bright = nightified(Self.mixed(CalmCityStyle.leaf, CalmCityStyle.paper, 0.35), sample: sample, attenuation: nightAttenuation)
            let deep = nightified(Self.mixed(CalmCityStyle.leafDeep, CalmCityStyle.paper, 0.35), sample: sample, attenuation: nightAttenuation)
            let canopyRect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            context.fill(
                Path(ellipseIn: canopyRect.offsetBy(dx: radius * 0.16, dy: radius * 0.18)),
                with: .color(deep)
            )
            context.fill(Path(ellipseIn: canopyRect), with: .color(bright))
            let dimple = CGRect(x: center.x - radius * 0.42, y: center.y - radius * 0.52, width: radius * 0.5, height: radius * 0.4)
            context.fill(Path(ellipseIn: dimple), with: .color(.white.opacity(0.16)))
        default:
            // Candy lollipop: a round canopy on a stubby trunk, with a
            // deterministic quarter blooming pink so plots read as playful
            // gardens.
            outlinedVoxelBox(
                context: &context, x: tree.x - trunk / 2, y: tree.y - trunk / 2, w: trunk, d: trunk, h: trunkHeight,
                top: nightColor(126, 92, 66, sample: sample), se: nightColor(101, 72, 50, sample: sample), sw: nightColor(84, 60, 42, sample: sample),
                outlineWidth: 0.55
            )
            let blooming = tree.size < 4
                && Int(UInt(bitPattern: Self.byteHash("\(tree.x)-\(tree.y)-blossom")) % 4) == 0
            let brightToken = blooming ? CalmCityStyle.blossom : CalmCityStyle.leaf
            let deepToken = blooming ? Self.mixed(CalmCityStyle.blossom, CalmCityStyle.ink, 0.22) : CalmCityStyle.leafDeep
            let radius = canopySize * (2.4 + plumpness * 0.5)
            // Anchor the canopy to the trunk tip: the ball's bottom overlaps
            // the trunk by ~30% of its radius, so the lollipop never floats
            // free of its stick regardless of size/plumpness combination.
            let trunkTip = IsoProjection.project(tree.x, tree.y, trunkHeight)
            let center = CGPoint(x: trunkTip.x, y: trunkTip.y - radius * 0.7)
            let bright = nightified(brightToken, sample: sample, attenuation: nightAttenuation)
            let deep = nightified(deepToken, sample: sample, attenuation: nightAttenuation)
            let canopyRect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            context.fill(
                Path(ellipseIn: canopyRect.offsetBy(dx: radius * 0.16, dy: radius * 0.18)),
                with: .color(deep)
            )
            context.fill(Path(ellipseIn: canopyRect), with: .color(bright))
            let dimple = CGRect(x: center.x - radius * 0.42, y: center.y - radius * 0.52, width: radius * 0.5, height: radius * 0.4)
            context.fill(Path(ellipseIn: dimple), with: .color(.white.opacity(0.16)))
        }
    }


    private func drawCrane(context: inout GraphicsContext, plot: CityPlot, phase: TimeInterval) {
        let x = plot.x + plot.w - 2, y = plot.y + 2, bob = reduceMotion ? 0 : CGFloat(sin(phase * 1.3)) * 0.4
        stroke(context: &context, [IsoProjection.project(x, y, 0.5), IsoProjection.project(x, y, 9)], color: Color(red: 0.85, green: 0.63, blue: 0.24), width: 1.5)
        stroke(context: &context, [IsoProjection.project(x - 4, y, 8.5), IsoProjection.project(x + 2, y, 8.5)], color: Color(red: 0.85, green: 0.63, blue: 0.24), width: 1.4)
        stroke(context: &context, [IsoProjection.project(x + 1, y, 8.5), IsoProjection.project(x + 1, y, 4 + bob)], color: .white.opacity(0.46), width: 0.7)
        let load = IsoProjection.project(x + 1, y, 3.5 + bob)
        context.fill(Path(CGRect(x: load.x - 2, y: load.y - 1, width: 4, height: 2)), with: .color(Color(red: 0.85, green: 0.63, blue: 0.24)))
    }

    private func drawClosedMarkers(context: inout GraphicsContext, plot: CityPlot) {
        let a = IsoProjection.project(plot.x + 0.5, plot.y + plot.d / 2, 1), b = IsoProjection.project(plot.x + plot.w - 0.5, plot.y + plot.d / 2, 1)
        stroke(context: &context, [a, b], color: Color(red: 0.89, green: 0.76, blue: 0.24), width: 2)
        for x in [plot.x + 1.5, plot.x + plot.w - 1.5] { let p = IsoProjection.project(x, plot.y + plot.d - 1, 1); context.fill(Path(ellipseIn: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)), with: .color(Color(red: 0.88, green: 0.54, blue: 0.24))) }
    }


    private func drawHeadlightCone(context: inout GraphicsContext, at world: (CGFloat, CGFloat), alongX: Bool, cone: CityRenderPolicies.HeadlightCone) {
        let forward: (CGFloat, CGFloat) = alongX ? (cone.length, 0) : (0, cone.length)
        let lateral: (CGFloat, CGFloat) = alongX ? (0, cone.length * 0.36) : (cone.length * 0.36, 0)
        let points = [
            IsoProjection.project(world.0, world.1, 0.08),
            IsoProjection.project(world.0 + forward.0 + lateral.0, world.1 + forward.1 + lateral.1, 0.08),
            IsoProjection.project(world.0 + forward.0 - lateral.0, world.1 + forward.1 - lateral.1, 0.08),
        ]
        fill(context: &context, points, color: Color(red: 1, green: 0.86, blue: 0.48).opacity(cone.alpha))
    }


    /// One car silhouette, split off the car hash into calm sedans, marigold
    /// taxis with a roof sign, and two-tone delivery vans. `desaturate`
    /// pulls curb-parked bodies toward paper so moving traffic keeps the
    /// brighter job-driven colors; wheels and ground shadow stay identical
    /// across kinds.
    private func drawCar(
        context: inout GraphicsContext,
        at world: (CGFloat, CGFloat),
        alongX: Bool,
        colorToken: RGB,
        sample: CityPalette.Sample,
        kind: CarKind = .sedan,
        bodyToken: RGB? = nil,
        desaturate: Double = 0
    ) {
        let center = CGPoint(x: world.0, y: world.1)
        let carScale = CityActorFootprints.carScale
        let bodyRGB = bodyToken.map { desaturate > 0 ? Self.mixed($0, CalmCityStyle.paper, desaturate) : $0 }
        let bodyTokenResolved: RGB
        switch kind {
        case .sedan, .van:
            bodyTokenResolved = bodyRGB ?? colorToken
        case .taxi:
            bodyTokenResolved = Self.mixed(Self.mixed(CalmCityStyle.marigold, CalmCityStyle.ink, 0.05), CalmCityStyle.paper, desaturate)
        }
        // Bodies join the nocturne; only lamps and headlight cones stay emissive.
        let bodyColor = nightified(bodyTokenResolved, sample: sample, attenuation: 0.85).opacity(0.98)
        let glassToken = kind == .taxi ? Self.mixed(CalmCityStyle.water, CalmCityStyle.ink, 0.3) : CalmCityStyle.water
        let glass = nightified(glassToken, sample: sample, attenuation: 0.7)
        let ink = nightified(CalmCityStyle.ink, sample: sample).opacity(0.92)

        let ground = IsoProjection.project(world.0, world.1, 0.02)
        context.fill(
            Path(ellipseIn: CGRect(x: ground.x - 8.5 * carScale, y: ground.y - 1.6 * carScale, width: 17 * carScale, height: 4.4 * carScale)),
            with: .color(Color.black.opacity(0.22))
        )

        for wheel in CityActorFootprints.carVisibleWheelCenters(center: center, alongX: alongX) {
            let point = IsoProjection.project(wheel.x, wheel.y, 0.22 * carScale)
            let tire = CGRect(x: point.x - 1.7 * carScale, y: point.y - 1.9 * carScale, width: 3.4 * carScale, height: 3.8 * carScale)
            context.fill(Path(ellipseIn: tire), with: .color(ink))
            context.fill(
                Path(ellipseIn: tire.insetBy(dx: 1.05 * carScale, dy: 1.2 * carScale)),
                with: .color(Color(red: 0.58, green: 0.63, blue: 0.68).opacity(0.95))
            )
        }

        let body = CityActorFootprints.carBody(center: center, alongX: alongX)
        drawExtrudedFootprint(
            context: &context,
            vertices: body,
            lowerZ: 0.14 * carScale,
            upperZ: 0.70 * carScale,
            top: bodyColor,
            right: bodyColor.opacity(0.78),
            left: bodyColor.opacity(0.62),
            rimWidth: 0.50
        )

        switch kind {
        case .sedan, .taxi:
            let cabin = CityActorFootprints.carCabin(center: center, alongX: alongX)
            drawExtrudedFootprint(
                context: &context,
                vertices: cabin,
                lowerZ: 0.70 * carScale,
                upperZ: 1.12 * carScale,
                top: bodyColor,
                right: glass.opacity(0.92),
                left: glass.opacity(0.78),
                rimWidth: 0.45
            )

            let cabinSolid = CityExtrudedFootprint(vertices: cabin, lowerZ: 0.70 * carScale, upperZ: 1.12 * carScale)
            for side in cabinSolid.visibleSides {
                guard side.points.count == 4 else { continue }
                let dividerTop = CGPoint(
                    x: (side.points[0].x + side.points[3].x) * 0.5,
                    y: (side.points[0].y + side.points[3].y) * 0.5
                )
                let dividerBottom = CGPoint(
                    x: (side.points[1].x + side.points[2].x) * 0.5,
                    y: (side.points[1].y + side.points[2].y) * 0.5
                )
                stroke(context: &context, [dividerTop, dividerBottom], color: ink.opacity(0.72), width: 0.65)
            }

            if kind == .taxi {
                // Tiny paper roof sign with an ink dot, centered on the cabin top.
                let signLength: CGFloat = 0.3 * carScale
                let signWidth: CGFloat = 0.18 * carScale
                box(
                    context: &context,
                    x: world.0 - (alongX ? signLength : signWidth) / 2,
                    y: world.1 - (alongX ? signWidth : signLength) / 2,
                    w: alongX ? signLength : signWidth,
                    d: alongX ? signWidth : signLength,
                    h: (1.12 + 0.12) * carScale,
                    z0: 1.12 * carScale,
                    top: nightified(CalmCityStyle.paper, sample: sample, attenuation: 0.75),
                    se: nightified(Self.mixed(CalmCityStyle.paper, CalmCityStyle.ink, 0.10), sample: sample, attenuation: 0.75),
                    sw: nightified(Self.mixed(CalmCityStyle.paper, CalmCityStyle.ink, 0.18), sample: sample, attenuation: 0.75)
                )
                let signTop = IsoProjection.project(world.0, world.1, (1.12 + 0.13) * carScale)
                context.fill(
                    Path(ellipseIn: CGRect(x: signTop.x - 0.6 * carScale, y: signTop.y - 0.35 * carScale, width: 1.2 * carScale, height: 0.7 * carScale)),
                    with: .color(nightified(CalmCityStyle.ink, sample: sample).opacity(0.6))
                )
            }
        case .van:
            // Boxy cargo over the rear 60% of the body footprint; the cab
            // keeps the body color with one windshield band up front and no
            // glass divider.
            let heading = CGVector(dx: alongX ? 1 : 0, dy: alongX ? 0 : 1)
            let cargo = CityActorFootprints.orientedRectangle(
                center: CGPoint(x: center.x - heading.dx * 0.46 * carScale, y: center.y - heading.dy * 0.46 * carScale),
                heading: heading,
                length: 1.38 * carScale,
                width: 0.96 * carScale
            )
            let cargoColor = nightified(bodyRGB.map { Self.mixed(CalmCityStyle.paper, $0, 0.55) } ?? CalmCityStyle.paper, sample: sample, attenuation: 0.85)
            drawExtrudedFootprint(
                context: &context,
                vertices: cargo,
                lowerZ: 0.70 * carScale,
                upperZ: 1.35 * carScale,
                top: cargoColor,
                right: cargoColor.opacity(0.78),
                left: cargoColor.opacity(0.62),
                rimWidth: 0.45
            )
            let cab = CityActorFootprints.orientedRectangle(
                center: CGPoint(x: center.x + heading.dx * 0.60 * carScale, y: center.y + heading.dy * 0.60 * carScale),
                heading: heading,
                length: 0.70 * carScale,
                width: 0.68 * carScale
            )
            drawExtrudedFootprint(
                context: &context,
                vertices: cab,
                lowerZ: 0.70 * carScale,
                upperZ: 1.35 * carScale,
                top: bodyColor,
                right: bodyColor.opacity(0.78),
                left: bodyColor.opacity(0.62),
                rimWidth: 0.45
            )
            let face = CGPoint(x: center.x + heading.dx * 0.96 * carScale, y: center.y + heading.dy * 0.96 * carScale)
            let side = CGVector(dx: -heading.dy * 0.28 * carScale, dy: heading.dx * 0.28 * carScale)
            fill(
                context: &context,
                [
                    IsoProjection.project(face.x + side.dx, face.y + side.dy, 0.94 * carScale),
                    IsoProjection.project(face.x - side.dx, face.y - side.dy, 0.94 * carScale),
                    IsoProjection.project(face.x - side.dx, face.y - side.dy, 1.24 * carScale),
                    IsoProjection.project(face.x + side.dx, face.y + side.dy, 1.24 * carScale),
                ],
                color: glass.opacity(0.85)
            )
        }

        let length: CGFloat = 2.30 * carScale
        let width: CGFloat = 1.0 * carScale
        let front = alongX
            ? (x: world.0 + length / 2 + 0.03, y: world.1)
            : (x: world.0, y: world.1 + length / 2 + 0.03)
        let rear = alongX
            ? (x: world.0 - length / 2 - 0.03, y: world.1)
            : (x: world.0, y: world.1 - length / 2 - 0.03)
        let lateral: (CGFloat, CGFloat) = alongX
            ? (0, width * 0.28)
            : (width * 0.28, 0)
        for multiplier: CGFloat in [-1, 1] {
            drawCarLamp(
                context: &context,
                at: (front.x + lateral.0 * multiplier, front.y + lateral.1 * multiplier),
                sideFace: alongX,
                color: Color(red: 1, green: 0.88, blue: 0.55)
            )
            drawCarLamp(
                context: &context,
                at: (rear.x + lateral.0 * multiplier, rear.y + lateral.1 * multiplier),
                sideFace: alongX,
                color: Color(red: 1, green: 0.30, blue: 0.20)
            )
        }
    }

    /// Vehicle silhouette keyed off the stable car hash: roughly 60% calm
    /// sedans, 20% taxis, 20% delivery vans.
    private enum CarKind: Equatable {
        case sedan
        case taxi
        case van
    }

    /// The `carColor(for:)` palette restated as 0...255 RGB tokens so van
    /// two-tone and curb desaturation mixes stay in token space.
    private static let carBodyTokens: [RGB] = [
        RGB(r: 63.75, g: 224.4, b: 234.6),
        RGB(r: 255, g: 79.05, b: 160.65),
        RGB(r: 255, g: 209.1, b: 63.75),
        RGB(r: 234.6, g: 239.7, b: 249.9),
        RGB(r: 76.5, g: 132.6, b: 242.25),
    ]

    /// Hash % 10 split: 0-5 sedan, 6-7 taxi, 8-9 van.
    private static func carKind(forHash hash: Int) -> CarKind {
        switch (hash & Int.max) % 10 {
        case 0...5: return .sedan
        case 6...7: return .taxi
        default: return .van
        }
    }


    /// Street endpoints, corners, and axis crossings — the spots curb
    /// parking must yield to.

    private func drawExtrudedFootprint(
        context: inout GraphicsContext,
        vertices: [CGPoint],
        lowerZ: CGFloat,
        upperZ: CGFloat,
        top: Color,
        right: Color,
        left: Color,
        rimWidth: CGFloat = 0
    ) {
        let solid = CityExtrudedFootprint(
            vertices: vertices,
            lowerZ: lowerZ,
            upperZ: upperZ
        )
        fill(context: &context, solid.projectedTop, color: top)
        for side in solid.visibleSides {
            fill(
                context: &context,
                side.points,
                color: side.shade == .right ? right : left
            )
        }
        if rimWidth > 0, let first = solid.projectedTop.first {
            stroke(
                context: &context,
                solid.projectedTop + [first],
                color: .white.opacity(0.16),
                width: rimWidth
            )
        }
    }

    private func drawCarLamp(context: inout GraphicsContext, at world: (CGFloat, CGFloat), sideFace: Bool, color: Color) {
        let lampScale = CityActorFootprints.carScale
        let point = IsoProjection.project(world.0, world.1, 0.42 * lampScale)
        var lamp = Path()
        Self.addFacadeCell(&lamp, center: point, halfW: 0.22 * lampScale, halfH: 0.22 * lampScale, sideFace: sideFace)
        context.fill(lamp, with: .color(color))
    }

    private func drawOutlinedVoxelBox(
        context: inout GraphicsContext,
        x: CGFloat,
        y: CGFloat,
        w: CGFloat,
        d: CGFloat,
        h: CGFloat,
        z0: CGFloat = 0,
        top: Color,
        se: Color,
        sw: Color,
        ink: Color
    ) {
        let a = IsoProjection.project(x, y, z0 + h)
        let b = IsoProjection.project(x + w, y, z0 + h)
        let c = IsoProjection.project(x + w, y + d, z0 + h)
        let e = IsoProjection.project(x, y + d, z0 + h)
        let b0 = IsoProjection.project(x + w, y, z0)
        let c0 = IsoProjection.project(x + w, y + d, z0)
        let e0 = IsoProjection.project(x, y + d, z0)
        for (face, color) in [
            ([a, b, c, e], top),
            ([b, b0, c0, c], se),
            ([e, c, c0, e0], sw),
        ] {
            fill(context: &context, face, color: color)
            stroke(context: &context, face + [face[0]], color: ink, width: 0.7)
        }
    }

    private func drawOutlinedVoxelBox(
        context: inout GraphicsContext,
        at point: CGPoint,
        w: CGFloat,
        d: CGFloat,
        h: CGFloat,
        z0: CGFloat,
        top: Color,
        se: Color,
        sw: Color,
        ink: Color,
        outlineWidth: CGFloat = 0.9
    ) {
        let origin = IsoProjection.project(0, 0)
        let xEnd = IsoProjection.project(w / 2, 0)
        let yEnd = IsoProjection.project(0, d / 2)
        let zEnd = IsoProjection.project(0, 0, z0)
        let hEnd = IsoProjection.project(0, 0, h)
        let xAxis = CGSize(width: xEnd.x - origin.x, height: xEnd.y - origin.y)
        let yAxis = CGSize(width: yEnd.x - origin.x, height: yEnd.y - origin.y)
        let zAxis = CGSize(width: zEnd.x - origin.x, height: zEnd.y - origin.y)
        let hAxis = CGSize(width: hEnd.x - origin.x, height: hEnd.y - origin.y)
        let base = CGPoint(x: point.x - xAxis.width - yAxis.width, y: point.y - xAxis.height - yAxis.height)
        let a = CGPoint(x: base.x + zAxis.width + hAxis.width, y: base.y + zAxis.height + hAxis.height)
        let b = CGPoint(x: a.x + xAxis.width * 2, y: a.y + xAxis.height * 2)
        let c = CGPoint(x: b.x + yAxis.width * 2, y: b.y + yAxis.height * 2)
        let e = CGPoint(x: a.x + yAxis.width * 2, y: a.y + yAxis.height * 2)
        let b0 = CGPoint(x: base.x + zAxis.width + xAxis.width * 2, y: base.y + zAxis.height + xAxis.height * 2)
        let c0 = CGPoint(x: b0.x + yAxis.width * 2, y: b0.y + yAxis.height * 2)
        let e0 = CGPoint(x: base.x + zAxis.width + yAxis.width * 2, y: base.y + zAxis.height + yAxis.height * 2)
        for (face, color) in [
            ([a, b, c, e], top),
            ([b, b0, c0, c], se),
            ([e, c, c0, e0], sw),
        ] {
            fill(context: &context, face, color: color)
        }
        stroke(context: &context, [a, b, c, e, a], color: .white.opacity(0.16), width: outlineWidth)
    }

    /// Appends a parallelogram lying in a building facade plane: `sideFace` selects the
    /// x-constant (northeast/southeast-right) face shear; otherwise the y-constant front face.
    static func addFacadeCell(_ path: inout Path, center p: CGPoint, halfW: CGFloat, halfH: CGFloat, sideFace: Bool) {
        let shear = halfW * IsoProjection.fy / IsoProjection.s * (sideFace ? -1 : 1)
        path.move(to: CGPoint(x: p.x - halfW, y: p.y - shear - halfH))
        path.addLine(to: CGPoint(x: p.x + halfW, y: p.y + shear - halfH))
        path.addLine(to: CGPoint(x: p.x + halfW, y: p.y + shear + halfH))
        path.addLine(to: CGPoint(x: p.x - halfW, y: p.y - shear + halfH))
        path.closeSubpath()
    }


    static func humanSpriteBounds(at point: CGPoint) -> CGRect {
        CGRect(x: point.x - 1.6, y: point.y - 4.1, width: 3.2, height: 4.7)
    }



    private func citizenWorldPosition(plot: CityPlot, index: Int, date: Date) -> (x: CGFloat, y: CGFloat) {
        let time = reduceMotion ? 0 : date.timeIntervalSinceReferenceDate
        let offset = CGFloat(sin(time * 0.7 + Double(index))) * 1.6
        // Citizens fill the south apron in rows of five; extra rows step
        // toward the plot interior so larger crowds stay on the lot.
        let column = index % 5
        let row = index / 5
        return (
            plot.x + 1.6 + CGFloat(column) * max(1, (plot.w - 3) / 5) + offset,
            plot.y + plot.d - 0.8 - CGFloat(row) * 1.5
        )
    }

    /// Leisure vignettes - picnics, kites, dog walks, ball games, gardening -
    /// one deterministic scene per plot apron so districts feel lived-in even
    /// between jobs. Motion derives only from the frame date.
    private func drawActivities(context: inout GraphicsContext, plot: CityPlot, scape: CityScape, date: Date, sample: CityPalette.Sample, band: ZoomBand, lod: CityDetailLevel) {
        guard plot.mode != .closed else { return }
        let opacity = Self.dynamicActorOpacity(lod: lod)
        guard opacity > 0 else { return }
        let footprints = plot.buildings.map { building in
            CGRect(x: plot.x + building.ox, y: plot.y + building.oy, width: building.bw, height: building.bd)
        }
        guard let scene = CityWhimsy.activityScene(plotID: plot.id, x: plot.x, y: plot.y, w: plot.w, d: plot.d, footprints: footprints) else { return }
        guard !occlusionField.isHidden(worldX: scene.x, worldY: scene.y, z: 0.05, boundsOnly: Self.actorOcclusionUsesBoundsOnly(in: band)) else { return }
        let time = reduceMotion ? 0 : date.timeIntervalSinceReferenceDate
        switch scene.kind {
        case .picnic:
            drawPicnic(context: &context, scene: scene, plotID: plot.id, date: date, sample: sample, opacity: opacity)
        case .kite:
            drawKite(context: &context, scene: scene, plotID: plot.id, time: time, date: date, sample: sample, opacity: opacity)
        case .dogWalk:
            drawDogWalk(context: &context, scene: scene, plotID: plot.id, time: time, date: date, sample: sample, opacity: opacity)
        case .ballGame:
            drawBallGame(context: &context, scene: scene, plotID: plot.id, time: time, date: date, sample: sample, opacity: opacity)
        case .gardening:
            drawGardening(context: &context, scene: scene, plotID: plot.id, date: date, sample: sample, opacity: opacity)
        }
    }

    private func drawPicnic(context: inout GraphicsContext, scene: CityWhimsy.ActivityScene, plotID: String, date: Date, sample: CityPalette.Sample, opacity: Double) {
        let corners = [(-1.4, -1.0), (1.4, -1.0), (1.4, 1.0), (-1.4, 1.0)].map {
            IsoProjection.project(scene.x + CGFloat($0.0), scene.y + CGFloat($0.1), 0.02)
        }
        var blanket = Path()
        blanket.addLines(corners)
        blanket.closeSubpath()
        context.fill(blanket, with: .color(Color(red: 1, green: 0.62, blue: 0.66).opacity(0.9 * opacity)))
        context.stroke(blanket, with: .color(Self.outlineInk.opacity(0.7 * opacity)), lineWidth: 0.7)
        let basket = IsoProjection.project(scene.x, scene.y, 0.18)
        context.fill(
            Path(ellipseIn: CGRect(x: basket.x - 1.1, y: basket.y - 0.85, width: 2.2, height: 1.7)),
            with: .color(Color(red: 0.72, green: 0.42, blue: 0.18).opacity(opacity))
        )
        for side: CGFloat in [-2.1, 2.1] {
            let p = IsoProjection.project(scene.x + side, scene.y, 0.05)
            drawBlob(context: &context, at: p, key: "\(plotID)-picnic-\(side > 0 ? "e" : "w")", heading: CGSize(width: -side, height: 0), date: date, sample: sample, opacity: opacity)
        }
    }

    private func drawKite(context: inout GraphicsContext, scene: CityWhimsy.ActivityScene, plotID: String, time: TimeInterval, date: Date, sample: CityPalette.Sample, opacity: Double) {
        let anchor = IsoProjection.project(scene.x, scene.y, 0.05)
        drawBlob(context: &context, at: anchor, key: "\(plotID)-kite-flyer", heading: CGSize(width: 1, height: 0), date: date, sample: sample, opacity: opacity)
        let seed = Double(stableByteHash("\(plotID)-kite") % 7)
        let sway = CGFloat(sin(time * 0.8 + seed)) * 1.1
        let lift = 4.6 + 0.4 * CGFloat(sin(time * 1.7 + seed))
        let tip = IsoProjection.project(scene.x + 1.6 + sway, scene.y - 0.6, lift)
        var kite = Path()
        kite.move(to: CGPoint(x: tip.x, y: tip.y - 3.4))
        kite.addLine(to: CGPoint(x: tip.x + 2.4, y: tip.y))
        kite.addLine(to: CGPoint(x: tip.x, y: tip.y + 3.4))
        kite.addLine(to: CGPoint(x: tip.x - 2.4, y: tip.y))
        kite.closeSubpath()
        var string = Path()
        string.move(to: CGPoint(x: anchor.x, y: anchor.y - 4.4))
        string.addLine(to: CGPoint(x: tip.x, y: tip.y + 3.4))
        context.stroke(string, with: .color(Self.outlineInk.opacity(0.4 * opacity)), lineWidth: 0.5)
        context.fill(kite, with: .color(Color(red: 1, green: 0.55, blue: 0.20).opacity(opacity)))
        context.stroke(kite, with: .color(Self.outlineInk.opacity(0.8 * opacity)), lineWidth: 0.7)
    }

    private func drawDogWalk(context: inout GraphicsContext, scene: CityWhimsy.ActivityScene, plotID: String, time: TimeInterval, date: Date, sample: CityPalette.Sample, opacity: Double) {
        let angle = time * 0.45 + Double(stableByteHash("\(plotID)-dog") % 13)
        let wx = scene.x + CGFloat(cos(angle)) * 1.1
        let wy = scene.y + CGFloat(sin(angle)) * 0.7
        let walker = IsoProjection.project(wx, wy, 0.05)
        let dogX = wx + CGFloat(cos(angle + 0.9))
        let dogY = wy + CGFloat(sin(angle + 0.9)) * 0.7
        let dog = IsoProjection.project(dogX, dogY, 0.05)
        var leash = Path()
        leash.move(to: CGPoint(x: walker.x, y: walker.y - 2.2))
        leash.addLine(to: CGPoint(x: dog.x, y: dog.y - 0.8))
        context.stroke(leash, with: .color(Self.outlineInk.opacity(0.4 * opacity)), lineWidth: 0.5)
        drawBlob(context: &context, at: walker, key: "\(plotID)-dog-walker", heading: CGSize(width: dog.x - walker.x, height: dog.y - walker.y), date: date, sample: sample, opacity: opacity)
        drawOutlinedVoxelBox(
            context: &context,
            at: dog,
            w: 0.7,
            d: 0.45,
            h: 0.42,
            z0: 0.02,
            top: Color(red: 0.72, green: 0.5, blue: 0.28).opacity(opacity),
            se: Color(red: 0.6, green: 0.4, blue: 0.2).opacity(opacity),
            sw: Color(red: 0.52, green: 0.34, blue: 0.16).opacity(opacity),
            ink: Self.outlineInk.opacity(0.8 * opacity),
            outlineWidth: 0.6
        )
    }

    private func drawBallGame(context: inout GraphicsContext, scene: CityWhimsy.ActivityScene, plotID: String, time: TimeInterval, date: Date, sample: CityPalette.Sample, opacity: Double) {
        let west = IsoProjection.project(scene.x - 1.9, scene.y, 0.05)
        let east = IsoProjection.project(scene.x + 1.9, scene.y, 0.05)
        drawBlob(context: &context, at: west, key: "\(plotID)-ball-w", heading: CGSize(width: east.x - west.x, height: east.y - west.y), date: date, sample: sample, opacity: opacity)
        drawBlob(context: &context, at: east, key: "\(plotID)-ball-e", heading: CGSize(width: west.x - east.x, height: west.y - east.y), date: date, sample: sample, opacity: opacity)
        let cycle = CityWhimsy.positiveRemainder(time * 0.55, 1)
        let shuttle = reduceMotion ? 0.5 : CGFloat(cycle < 0.5 ? cycle * 2 : (1 - cycle) * 2)
        let ballX = scene.x - 1.9 + 3.8 * shuttle
        let ballZ = 0.6 + 1.8 * 4 * shuttle * (1 - shuttle)
        let ball = IsoProjection.project(ballX, scene.y, ballZ)
        let rect = CGRect(x: ball.x - 0.9, y: ball.y - 0.9, width: 1.8, height: 1.8)
        context.fill(Path(ellipseIn: rect), with: .color(Color(red: 1, green: 0.82, blue: 0.25).opacity(opacity)))
        context.stroke(Path(ellipseIn: rect), with: .color(Self.outlineInk.opacity(0.8 * opacity)), lineWidth: 0.5)
    }

    private func drawGardening(context: inout GraphicsContext, scene: CityWhimsy.ActivityScene, plotID: String, date: Date, sample: CityPalette.Sample, opacity: Double) {
        let gardener = IsoProjection.project(scene.x, scene.y, 0.05)
        drawBlob(context: &context, at: gardener, key: "\(plotID)-gardener", heading: CGSize(width: 1, height: 0.4), date: date, sample: sample, opacity: opacity)
        for index in 0..<3 {
            let sprout = IsoProjection.project(scene.x + 1.0 + CGFloat(index) * 0.7, scene.y + 0.7, 0.16)
            let color = index == 1
                ? Color(red: 1, green: 0.62, blue: 0.24)
                : Color(red: 0.42, green: 0.76, blue: 0.34)
            let rect = CGRect(x: sprout.x - 0.7, y: sprout.y - 0.7, width: 1.4, height: 1.4)
            context.fill(Path(ellipseIn: rect), with: .color(color.opacity(opacity)))
            context.stroke(Path(ellipseIn: rect), with: .color(Self.outlineInk.opacity(0.7 * opacity)), lineWidth: 0.5)
        }
    }


    private func drawPlate(context: inout GraphicsContext, plot: CityPlot, camera: CityCamera, at sign: CGPoint, statusOffset: CGFloat, hovered: Bool, opacity: Double, palette: AppPalette) {
        let status: (String, Color) = switch CalmCityStyle.buildingState(for: plot) {
        case .free: ("available", palette.status(.idle))
        case .allocated: ("allocated", palette.secondary)
        case .drained: (plot.node.stateLabel.lowercased(), palette.secondary)
        case .unknown: ("unverified", palette.secondary)
        }
        drawTelemetry(context: &context, camera: camera, plotLabel(for: plot), at: sign, offset: CGSize(width: 0, height: -2), font: .caption2.monospaced().weight(.bold), color: (hovered ? palette.primary : .white.opacity(0.87)).opacity(opacity), anchor: .bottom, shadowOpacity: opacity)
        drawTelemetry(context: &context, camera: camera, status.0, at: sign, offset: CGSize(width: 0, height: statusOffset), font: .caption2.monospaced(), color: status.1.opacity(opacity), anchor: .top, shadowOpacity: opacity)
    }

    private func plotLabel(for plot: CityPlot) -> String {
        guard plot.gpuCount > 1 else { return plot.node.name }
        return "\(plot.node.name) · GPU \(plot.gpuIndex)/\(plot.gpuCount)"
    }

    private func drawNeon(context: inout GraphicsContext, plot: CityPlot, phase: TimeInterval, band: ZoomBand) {
        guard plot.mode == .vacant || plot.mode == .half else { return }
        let flicker = reduceMotion ? 1.0 : (sin(phase * 5.3 + Double(neonPhaseOffset(for: plot.id))) > -0.45 ? 1.0 : 0.55)
        let p = IsoProjection.project(plot.x + plot.w / 2, plot.y + 1, 6)
        let label = plot.mode == .vacant ? "VACANT" : "ROOM"
        let green = Color(red: 0.32, green: 0.90, blue: 0.58).opacity(flicker)
        if band == .province {
            context.fill(Path(CGRect(x: p.x - 1.2, y: p.y - 1.2, width: 2.4, height: 2.4)), with: .color(green))
            return
        }
        let plateSize = label == "VACANT" ? CGSize(width: 46, height: 16) : CGSize(width: 32, height: 16)
        let plate = CGRect(x: p.x - plateSize.width / 2, y: p.y - plateSize.height / 2, width: plateSize.width, height: plateSize.height)
        context.fill(Path(roundedRect: plate, cornerRadius: 3), with: .color(Color(red: 0.04, green: 0.08, blue: 0.07).opacity(0.94)))
        context.stroke(Path(roundedRect: plate, cornerRadius: 3), with: .color(green.opacity(0.8)), lineWidth: 0.8)
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 2))
            drawText(context: &layer, label, at: p, font: .caption2.monospaced().weight(.bold), color: green.opacity(0.8), anchor: .center)
        }
        drawText(context: &context, label, at: p, font: .caption2.monospaced().weight(.bold), color: green, anchor: .center)
    }


    private func box(context: inout GraphicsContext, x: CGFloat, y: CGFloat, w: CGFloat, d: CGFloat, h: CGFloat, z0: CGFloat = 0, top: Color, se: Color, sw: Color, topStroke: Color? = nil) {
        let a = IsoProjection.project(x, y, h), b = IsoProjection.project(x + w, y, h), c = IsoProjection.project(x + w, y + d, h), e = IsoProjection.project(x, y + d, h)
        let b0 = IsoProjection.project(x + w, y, z0), c0 = IsoProjection.project(x + w, y + d, z0), e0 = IsoProjection.project(x, y + d, z0)
        fill(context: &context, [a, b, c, e], color: top); fill(context: &context, [b, b0, c0, c], color: se); fill(context: &context, [e, c, c0, e0], color: sw)
        if let topStroke { stroke(context: &context, [a, b, c, e, a], color: topStroke, width: 0.6) }
    }

    private func dashedPlot(context: inout GraphicsContext, plot: CityPlot) {
        let corners = [IsoProjection.project(plot.x, plot.y, 0.8), IsoProjection.project(plot.x + plot.w, plot.y, 0.8), IsoProjection.project(plot.x + plot.w, plot.y + plot.d, 0.8), IsoProjection.project(plot.x, plot.y + plot.d, 0.8)]
        var path = Path(); path.addLines(corners + [corners[0]])
        context.stroke(path, with: .color(Color(red: 0.32, green: 0.90, blue: 0.58).opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
    }

    private func fill(context: inout GraphicsContext, _ points: [CGPoint], color: Color) { var path = Path(); path.addLines(points); path.closeSubpath(); context.fill(path, with: .color(color)) }
    private func stroke(context: inout GraphicsContext, _ points: [CGPoint], color: Color, width: CGFloat) { var path = Path(); path.addLines(points); context.stroke(path, with: .color(color), lineWidth: width) }
    private func drawText(context: inout GraphicsContext, _ string: String, at point: CGPoint, font: Font, color: Color, anchor: UnitPoint) { context.draw(Text(string).font(font).foregroundStyle(color), at: point, anchor: anchor) }
    private func drawTelemetry(
        context: inout GraphicsContext,
        camera: CityCamera,
        _ string: String,
        at worldAnchor: CGPoint,
        offset: CGSize = .zero,
        font: Font,
        color: Color,
        anchor: UnitPoint,
        shadowOpacity: Double = 1
    ) {
        let screenAnchor = camera.apply(worldAnchor)
        let point = CGPoint(x: screenAnchor.x + offset.width, y: screenAnchor.y + offset.height)
        // Sticker shadow: one plum-ink copy behind the payload keeps light
        // inks legible on the bright daytime ground. The shadow fades with
        // the payload so zoomed-out labels vanish completely.
        drawText(context: &context, string, at: CGPoint(x: point.x + 0.9, y: point.y + 0.9), font: font, color: CalmCityStyle.ink.color.opacity(0.85 * shadowOpacity), anchor: anchor)
        drawText(context: &context, string, at: point, font: font, color: color, anchor: anchor)
    }
private func stableByteHash(_ value: String) -> Int {
    value.utf8.reduce(2_166_136_261) { ($0 ^ Int($1)) &* 16_777_619 }
}
}

struct CityMountainGeometry {
    let apex: CGPoint
    let far: CGPoint
    let right: CGPoint
    let near: CGPoint
    let left: CGPoint
    /// Silhouette shoulders descending the apex->left screen edge, apex-first.
    /// Each sits on the isometric flank with its height nudged off the straight
    /// slope, so the outline reads as a folded massif instead of a clean pyramid.
    let leftShoulders: [CGPoint]
    /// Silhouette shoulders descending the apex->right screen edge, apex-first.
    let rightShoulders: [CGPoint]

    init(x: CGFloat, y: CGFloat, height: CGFloat, radius: CGFloat) {
        apex = IsoProjection.project(x, y, height)
        far = IsoProjection.project(x - radius, y - radius)
        right = IsoProjection.project(x + radius, y - radius)
        near = IsoProjection.project(x + radius, y + radius)
        left = IsoProjection.project(x - radius, y + radius)

        // Deterministic per-massif seed: same mountain always folds the same
        // way, so the retained base render stays byte-identical.
        let seed = "\(x)-\(y)".utf8.reduce(2_166_136_261) { ($0 ^ Int($1)) &* 16_777_619 }
        func unit(_ shift: Int) -> CGFloat { CGFloat((seed >> shift) & 0xff) / 255 }
        // Shoulders zigzag down each flank: knuckles stay near the straight
        // slope while notches bite well below it, so every massif gets a
        // craggy stepped outline regardless of seed. All folds stay below the
        // 0.30 snow-cap boundary ((1 - t) * lift <= 0.68).
        func shoulders(toX: CGFloat, toY: CGFloat, phase: Int) -> [CGPoint] {
            let stops: [(t: CGFloat, knuckle: Bool, lane: Int)] = [
                (0.40, true, 0), (0.52, false, 1), (0.66, true, 2), (0.82, false, 3),
            ]
            return stops.map { stop in
                let lift = stop.knuckle
                    ? 0.94 + 0.14 * unit(phase + stop.lane * 5)
                    : 0.34 + 0.26 * unit(phase + stop.lane * 5)
                let wx = x + (toX - x) * stop.t
                let wy = y + (toY - y) * stop.t
                return IsoProjection.project(wx, wy, height * (1 - stop.t) * lift)
            }
        }
        leftShoulders = shoulders(toX: x - radius, toY: y + radius, phase: 0)
        rightShoulders = shoulders(toX: x + radius, toY: y - radius, phase: 13)
    }

    /// Full projected outline: apex down the right flank to the near corner
    /// and back up the left. Shared by terrain drawing and actor occlusion.
    var outlinePath: Path {
        var path = Path()
        path.move(to: apex)
        path.addLines(rightShoulders)
        path.addLine(to: right)
        path.addLine(to: near)
        path.addLine(to: left)
        path.addLines(leftShoulders.reversed())
        path.closeSubpath()
        return path
    }

    var footprintBounds: CGRect {
        [far, right, near, left].reduce(CGRect.null) {
            $0.union(CGRect(origin: $1, size: .zero))
        }
    }

    var bounds: CGRect {
        ([apex, far, right, near, left] + leftShoulders + rightShoulders)
            .reduce(CGRect.null) {
                $0.union(CGRect(origin: $1, size: .zero))
            }
    }
}

struct CitySearchlightGeometry {
    let tip: CGPoint
    let left: CGPoint
    let right: CGPoint
    let screenLength: CGFloat
    let screenHalfWidth: CGFloat
}

extension CityRenderPolicies {
    static let searchlightMaximumScreenLength: CGFloat = 80
    static let searchlightMaximumScreenHalfWidth: CGFloat = 5.5

    static func searchlightGeometry(apex: CGPoint, angle: Angle, cameraScale: CGFloat) -> CitySearchlightGeometry {
        let radians = angle.radians
        let dx = CGFloat(cos(radians))
        let dy = CGFloat(sin(radians))
        let origin = IsoProjection.project(0, 0, 0)
        let baseTip = IsoProjection.project(dx * 26, dy * 26, 6)
        let baseLeft = IsoProjection.project(dx * 26 - dy * 1.5, dy * 26 + dx * 1.5, 6)
        let tipOffset = CGSize(width: baseTip.x - origin.x, height: baseTip.y - origin.y)
        let halfWidthOffset = CGSize(width: baseLeft.x - baseTip.x, height: baseLeft.y - baseTip.y)
        let baseLength = (tipOffset.width * tipOffset.width + tipOffset.height * tipOffset.height).squareRoot()
        let baseHalfWidth = (halfWidthOffset.width * halfWidthOffset.width + halfWidthOffset.height * halfWidthOffset.height).squareRoot()
        let scale = max(cameraScale, 0.000_001)
        let lengthRatio = min(1, searchlightMaximumScreenLength / (baseLength * scale))
        let widthRatio = min(1, searchlightMaximumScreenHalfWidth / (baseHalfWidth * scale))
        let cappedTipOffset = CGSize(width: tipOffset.width * lengthRatio, height: tipOffset.height * lengthRatio)
        let cappedHalfWidthOffset = CGSize(width: halfWidthOffset.width * widthRatio, height: halfWidthOffset.height * widthRatio)
        let tip = CGPoint(x: apex.x + cappedTipOffset.width, y: apex.y + cappedTipOffset.height)

        return CitySearchlightGeometry(
            tip: tip,
            left: CGPoint(x: tip.x + cappedHalfWidthOffset.width, y: tip.y + cappedHalfWidthOffset.height),
            right: CGPoint(x: tip.x - cappedHalfWidthOffset.width, y: tip.y - cappedHalfWidthOffset.height),
            screenLength: baseLength * lengthRatio * scale,
            screenHalfWidth: baseHalfWidth * widthRatio * scale
        )
    }

    static func shouldDrawSearchlight(apex: CGPoint, in visibleWorldRect: CGRect) -> Bool {
        visibleWorldRect.contains(apex)
    }

    struct HeadlightCone: Equatable {
        let length: CGFloat
        let alpha: Double
    }

    /// Headlight cones exist only at street zoom: province and city cars are a
    /// few pixels wide, and a glowing cone per car would outrank the flagship
    /// searchlight in the night light hierarchy.
    static func headlightCone(band: ZoomBand) -> HeadlightCone? {
        band == .street ? HeadlightCone(length: 1.4, alpha: 0.10) : nil
    }

}
