import AppKit
import SwiftUI

/// Offline, deterministic city renderer for art-direction iteration.
///
/// Usage:
/// ```
/// Colby GPU Cluster --render-city <png> [--city-t 0.55] [--city-zoom 1.0]
///                   [--city-size 1600x1000] [--city-scale 2] [--city-date <unix>]
///                   [--city-scenario default|idle|full|allocated|free|drained|unknown]
///
/// Drives the production `CityRenderer` three-layer pipeline (backdrop,
/// retained base world, live overlay) against a synthetic snapshot, so the
/// output matches the live app's drawing code pixel-for-pixel at the pinned
/// day fraction without needing SSH, a window, or timers.
@MainActor
enum CityRenderHarness {
    struct Options {
        var outputPath: String
        var dayFraction: Double = 0.55
        var zoom: CGFloat = 1
        var size = CGSize(width: 1600, height: 1000)
        var renderScale: CGFloat = 2
        var date = Date()
        var focusNode: String?
        /// Centers the camera on the corner titan rather than a plot.
        var focusTitan = false
        /// Centers the camera on the hot-air balloon's position at the
        /// render date instead of a plot.
        var focusBalloon = false
        /// Centers the camera on the kaiju's pose at the render date.
        var focusKaiju = false
        /// Centers the camera on the patrolling UFO at the render date.
        var focusUFO = false
        /// `full` marks every non-drain GPU used: titan wakes, balloon
        /// celebrates, fireflies vanish, UFO scans the busiest plot.
        /// `allocated`/`free`/`drained`/`unknown` render one compact plot
        /// (A100 node `n1`, one GPU) in exactly that building state, with
        /// identical geometry across all four so the production renderer
        /// can be compared state-to-state at the same framing.
        var scenario: String = "default"
        /// Plot id that receives a synthetic mid-rise construction
        /// transition, so the site vignette (tape, crew, props) renders
        /// offline without a live density reconciliation.
        var constructPlot: String?
    }

    /// Returns true when `--render-city` was present and the process should
    /// terminate after rendering.
    static func runIfRequested() -> Bool {
        let args = ProcessInfo.processInfo.arguments
        guard let flag = args.firstIndex(of: "--render-city"), args.count > flag + 1 else { return false }
        var options = Options(outputPath: args[flag + 1])
        var index = flag + 2
        while index + 1 < args.count {
            let key = args[index]
            let value = args[index + 1]
            switch key {
            case "--city-t":
                options.dayFraction = Double(value) ?? options.dayFraction
            case "--city-zoom":
                options.zoom = CGFloat(Double(value) ?? 1)
            case "--city-scale":
                options.renderScale = CGFloat(Double(value) ?? 2)
            case "--city-size":
                let parts = value.lowercased().split(separator: "x")
                if parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]) {
                    options.size = CGSize(width: w, height: h)
                }
            case "--city-date":
                if let seconds = Double(value) {
                    options.date = Date(timeIntervalSince1970: seconds)
                }
            case "--city-focus":
                options.focusNode = value
            case "--city-focus-titan":
                options.focusTitan = true
                index -= 1
            case "--city-focus-balloon":
                options.focusBalloon = true
                index -= 1
            case "--city-focus-kaiju":
                options.focusKaiju = true
                index -= 1
            case "--city-focus-ufo":
                options.focusUFO = true
                index -= 1
            case "--city-scenario":
                options.scenario = value
            case "--city-construct":
                options.constructPlot = value
            default:
                break
            }
            index += 2
        }

        do {
            try render(options: options)
            print("render-city: wrote \(options.outputPath)")
        } catch {
            FileHandle.standardError.write("render-city: failed — \(error)\n".data(using: .utf8)!)
        }
        return true
    }

    /// Deterministic placement audit (CITY_PLACEMENT_AUDIT=1): verifies every
    /// resolved prop and parked car honors its occupancy clearances against
    /// every registered footprint. Ground truth for art-direction passes —
    /// screen-space inspection cannot distinguish iso adjacency from overlap.
    private static func auditPlacement(staticPaths: CitySceneStaticPaths) {
        let plan = staticPaths.placement
        let footprints = staticPaths.occupancy.footprints
        func distance(_ x: CGFloat, _ y: CGFloat, to rect: CGRect) -> CGFloat {
            let dx = max(rect.minX - x, 0, x - rect.maxX)
            let dy = max(rect.minY - y, 0, y - rect.maxY)
            return hypot(dx, dy)
        }
        func audit(_ points: [(x: CGFloat, y: CGFloat, label: String)], clearances: [CityOccupancy.Tag: CGFloat], ownTag: CityOccupancy.Tag) {
            var violations = 0
            var worst: (margin: CGFloat, label: String)?
            for point in points {
                for footprint in footprints {
                    guard let clearance = clearances[footprint.tag] else { continue }
                    let dist = distance(point.x, point.y, to: footprint.rect)
                    if footprint.tag == ownTag, dist == 0 { continue } // its own registration
                    let margin = dist - clearance
                    if margin < -0.001 {
                        violations += 1
                        print("placement-audit VIOLATION: \(point.label) vs \(footprint.tag.rawValue) rect \(footprint.rect) — margin \(margin)")
                    }
                    if worst == nil || margin < worst!.margin { worst = (margin, point.label) }
                }
            }
            print("placement-audit: \(points.count) \(ownTag.rawValue)s, violations=\(violations), tightest margin \(worst.map { String(format: "%.2f", $0.margin) } ?? "—")")
        }
        audit(
            plan.props.map { (x: $0.x, y: $0.y, label: "prop@\($0.x),\($0.y)") },
            clearances: CityOccupancy.propBlockers,
            ownTag: .prop
        )
        audit(
            plan.parkedCars.map { (x: $0.x, y: $0.y, label: "car@\($0.plotID)") },
            clearances: CityOccupancy.parkedCarBlockers,
            ownTag: .parkedCar
        )
    }

    /// Depth-order audit (CITY_LAMP_DEBUG=1): for every lamp, finds the
    /// depth-sorted items that draw AFTER it while their screen bounds
    /// intersect the lamp's pole/head rect — i.e. the surfaces that can bury
    /// it. Diagnoses painter-order bugs analytically instead of eyeballing.
    private static func auditLampBurial(scape: CityScape, staticPaths: CitySceneStaticPaths, camera: CityCamera, size: CGSize) {
        let lampPoints = scape.lamps.map { CGPoint(x: $0.0, y: $0.1) }
        let items = CityRenderer.baseWorldDepthItems(
            plots: scape.plots,
            forest: [],
            lamps: lampPoints,
            campgrounds: []
        )
        func poleRect(for lamp: CGPoint) -> CGRect {
            let base = IsoProjection.project(lamp.x, lamp.y, 0)
            let top = IsoProjection.project(lamp.x, lamp.y, 3.4)
            return CGRect(x: base.x - 3.5, y: top.y - 3.5, width: 7, height: base.y - top.y + 7)
        }
        var buried = 0
        for (index, item) in items.enumerated() {
            guard case let .lamp(lamp) = item else { continue }
            let rect = poleRect(for: lamp)
            let lampKey = IsoProjection.sortKey(x: lamp.x, y: lamp.y)
            for later in items.dropFirst(index + 1) {
                guard case let .plot(plot) = later else { continue }
                guard let bounds = staticPaths.renderBoundsByPlotID[plot.id], bounds.intersects(rect) else { continue }
                let plotKey = IsoProjection.sortKey(x: plot.x + plot.w, y: plot.y + plot.d)
                let backKey = IsoProjection.sortKey(x: plot.x, y: plot.y)
                buried += 1
                print(String(
                    format: "lamp-burial: lamp(%.1f,%.1f) key=%.1f <- plot %@ frontKey=%.1f backKey=%.1f plotRect=(%.1f,%.1f %.1fx%.1f)",
                    lamp.x, lamp.y, lampKey, plot.id, plotKey, backKey, plot.x, plot.y, plot.w, plot.d
                ))
            }
        }
        print("lamp-burial: \(buried) lamp/plot overlaps out of \(lampPoints.count) lamps")
        // Screen dump: PNG pixel coordinates (renderScale 2) for lamps whose
        // base lands inside the rendered frame, so crops can target exact
        // fixtures instead of guessing.
        let renderScale: CGFloat = 2
        func png(_ p: CGPoint) -> (Int, Int) {
            (
                Int((p.x * camera.scale + camera.translation.width) * renderScale),
                Int((p.y * camera.scale + camera.translation.height) * renderScale)
            )
        }
        let pixelW = Int(size.width * renderScale), pixelH = Int(size.height * renderScale)
        for lamp in lampPoints {
            let base = png(IsoProjection.project(lamp.x, lamp.y, 0))
            guard base.0 >= 0, base.0 < pixelW, base.1 >= 0, base.1 < pixelH else { continue }
            let head = png(IsoProjection.project(lamp.x, lamp.y, 3.2))
            print(String(format: "lamp-pos: world(%.1f,%.1f) base-px=(%d,%d) head-px=(%d,%d)", lamp.x, lamp.y, base.0, base.1, head.0, head.1))
        }
    }

    private static func render(options: Options) throws {
        CityPalette.pinnedDayFraction = options.dayFraction
        let sample = CityPalette.sample(t: options.dayFraction)

        var snapshot = demoSnapshot()
        if let fixture = singleStateSnapshot(scenario: options.scenario, date: options.date) {
            snapshot = fixture
        } else if options.scenario == "idle" {
            // Every GPU free and no queued work: titan sleeps, city drowses.
            snapshot = ClusterSnapshot(
                generatedAt: snapshot.generatedAt,
                nodes: snapshot.nodes.map { node in
                    ClusterNode(
                        name: node.name,
                        gres: node.gres.map {
                            GPUResource(gpuType: $0.gpuType, profile: $0.profile, vramGB: $0.vramGB, count: $0.count, used: 0)
                        },
                        state: node.state,
                        status: node.status,
                        stateLabel: node.stateLabel,
                        jobs: []
                    )
                },
                pending: []
            )
        } else if options.scenario == "full" {
            snapshot = ClusterSnapshot(
                generatedAt: snapshot.generatedAt,
                nodes: snapshot.nodes.map { node in
                    guard node.status != .drain else { return node }
                    return ClusterNode(
                        name: node.name,
                        gres: node.gres.map {
                            GPUResource(gpuType: $0.gpuType, profile: $0.profile, vramGB: $0.vramGB, count: $0.count, used: $0.count)
                        },
                        state: node.state,
                        status: node.status,
                        stateLabel: node.stateLabel,
                        jobs: node.jobs
                    )
                },
                pending: snapshot.pending
            )
        }
        let scape = CityScape.build(snapshot: snapshot)
        let staticPaths = CitySceneStaticPaths(scape: scape)

        let director = CityDirector()
        var camera = CityCamera.fitting(
            worldScreenBounds: CitySceneView.framedWorldBounds(scape: scape, staticPaths: staticPaths),
            in: options.size,
            margin: 24,
            labelInset: 30
        )
        camera.zoom(
            by: options.zoom,
            anchor: CGPoint(x: options.size.width / 2, y: options.size.height / 2)
        )
        if let focusNode = options.focusNode,
           let plot = scape.plots.first(where: { $0.node.name == focusNode }) {
            let center = IsoProjection.project(plot.x + plot.w / 2, plot.y + plot.d / 2)
            camera.translation = CGSize(
                width: options.size.width / 2 - center.x * camera.scale,
                height: options.size.height / 2 - center.y * camera.scale
            )
        }
        if options.focusTitan {
            let titan = CityRenderer.sleepingTitanGeometry(
                worldBounds: staticPaths.groundWorldBounds,
                wake: 0,
                breath: 0
            )
            // Center the whole reclining figure, not its model origin: the
            // body sprawls screen-left/down of (baseX, baseY), so anchoring
            // there clipped head and feet out of frame.
            let bounds = titan.renderBounds
            camera.translation = CGSize(
                width: options.size.width / 2 - bounds.midX * camera.scale,
                height: options.size.height / 2 - bounds.midY * camera.scale
            )
        }
        if options.focusBalloon {
            let celebration = options.scenario == "full" ? 1.0 : 0.0
            let balloon = CityWhimsy.balloon(date: options.date, reduceMotion: false, celebration: celebration)
            let geometry = CityRenderer.balloonGeometry(model: balloon, bounds: staticPaths.groundWorldBounds)
            let center = IsoProjection.project(geometry.x, geometry.y, geometry.z)
            camera.translation = CGSize(
                width: options.size.width / 2 - center.x * camera.scale,
                height: options.size.height / 2 - center.y * camera.scale
            )
        }
        if options.focusKaiju {
            let energy = options.scenario == "full" ? 1.0 : 0.45
            let pose = CityWhimsy.kaijuPose(
                date: options.date,
                reduceMotion: false,
                bounds: staticPaths.groundWorldBounds,
                energy: energy
            )
            // Frame at mid-torso so the head, stomping feet, and tail all
            // land inside the crop at street zoom.
            let center = IsoProjection.project(pose.x, pose.y, 11)
            camera.translation = CGSize(
                width: options.size.width / 2 - center.x * camera.scale,
                height: options.size.height / 2 - center.y * camera.scale
            )
        }
        if options.focusUFO {
            // Mirror drawLiveOverlay's mission assembly so the focus tracks
            // the saucer on sorties, not just the idle patrol lane.
            let vitals = CityRenderer.clusterVitals(scape: scape, pendingCount: snapshot.pending.count)
            var mission = CityWhimsy.UFOMission()
            mission.scanTarget = vitals.busiestAnchor
            mission.scanIntensity = vitals.busiestJobPressure
            if vitals.pendingJobs > 0, let anchor = scape.commuterQueueAnchors(count: 1).first {
                mission.queueTarget = CGPoint(x: anchor.0, y: anchor.1)
                mission.queueDepth = vitals.pendingJobs
            }
            let event = CityWhimsy.ufoEvent(
                date: options.date,
                reduceMotion: false,
                bounds: staticPaths.groundWorldBounds,
                mission: mission
            )
            // Frame halfway down the beam: saucer above center, the ground
            // and any beam-riding alien below.
            let center = IsoProjection.project(event.x, event.y, event.altitude * 0.45)
            camera.translation = CGSize(
                width: options.size.width / 2 - center.x * camera.scale,
                height: options.size.height / 2 - center.y * camera.scale
            )
        }
        let band = ZoomBand(scale: camera.scale)
        // Reconcile in the recent past so eased transitions (titan wake)
        // have settled by the render date; first reconcile is otherwise
        // time-neutral (cars parked, density silent).
        director.reconcile(scape: scape, date: options.date.addingTimeInterval(-10), reduceMotion: false, band: band)
        var stages = director.effectiveStages(at: options.date)
        // State-comparison fixtures hold massing constant: only architectural
        // treatment changes, not job-progress-driven construction density.
        if ["allocated", "free", "drained", "unknown"].contains(options.scenario) {
            stages = Dictionary(uniqueKeysWithValues: scape.plots.map { ($0.id, 10) })
        }
        let construction = constructionTransitions(options: options, stages: stages, scape: scape)
        // The settled base renders the FROM stage while a transition runs;
        // the overlay owns the rising shells until it expires.
        for (plotID, transition) in construction {
            stages[plotID] = transition.fromStage
        }
        print(String(format: "render-city: titanWakeTarget=%.3f wakeAtRender=%.3f", director.titanWakeTarget, director.titanWake(at: options.date)))

        if ProcessInfo.processInfo.environment["CITY_PLACEMENT_AUDIT"] != nil {
            auditPlacement(staticPaths: staticPaths)
        }
        if ProcessInfo.processInfo.environment["CITY_LAMP_DEBUG"] != nil {
            auditLampBurial(scape: scape, staticPaths: staticPaths, camera: camera, size: options.size)
        }
        if ProcessInfo.processInfo.environment["CITY_CAR_DEBUG"] != nil {
            let renderScale = options.renderScale
            let field = CityOcclusionField(occluders: staticPaths.occluders, densityStages: stages)
            var slotsByPlot: [String: Int] = [:]
            let spacedByPlot = Dictionary(
                uniqueKeysWithValues: Set(director.cars.map(\.plotID)).map { plotID in
                    (
                        plotID,
                        director.spacedCarPositions(
                            plotID: plotID,
                            scape: scape,
                            date: options.date
                        )
                    )
                }
            )
            for car in director.cars {
                var world: (x: CGFloat, y: CGFloat)?
                if case .parked = car.phase {
                    let slot = slotsByPlot[car.plotID, default: 0]
                    slotsByPlot[car.plotID] = slot + 1
                    if let spots = staticPaths.placement.commuteSpots[car.plotID],
                       slot < spots.count {
                        let spot = spots[slot]
                        world = (spot.x, spot.y)
                    }
                } else if let position = spacedByPlot[car.plotID]?[car.id] {
                    world = (position.x, position.y)
                }
                guard let world else { continue }
                let occluded = field.isHidden(worldX: world.x, worldY: world.y, z: 0.5)
                let projected = IsoProjection.project(world.x, world.y, 0.5)
                let px = Int((projected.x * camera.scale + camera.translation.width) * renderScale)
                let py = Int((projected.y * camera.scale + camera.translation.height) * renderScale)
                print(String(format: "car-pos: %@ %@ world(%.2f,%.2f) png=(%d,%d) occluded=%@", car.plotID, car.jobID, world.x, world.y, px, py, occluded ? "true" : "false"))
            }
        }

        var baseRenderer = CityRenderer(scape: scape, staticPaths: staticPaths, reduceMotion: false)
        baseRenderer.densityStages = stages
        var liveRenderer = CityRenderer(scape: scape, staticPaths: staticPaths, reduceMotion: false)
        liveRenderer.densityStages = stages

        let cameraSnapshot = camera
        let content = ZStack {
            Canvas { context, size in
                baseRenderer.drawBackdrop(context: &context, size: size, sample: sample)
            }
            Canvas { context, size in
                baseRenderer.drawBaseWorld(context: &context, size: size, sample: sample, camera: cameraSnapshot, band: band)
            }
            Canvas { context, size in
                liveRenderer.drawLiveOverlay(
                    context: &context,
                    size: size,
                    date: options.date,
                    sample: sample,
                    camera: cameraSnapshot,
                    band: band,
                    director: director,
                    refreshState: .fresh,
                    pending: snapshot.pending,
                    hoverPoint: nil,
                    hoveredPlotID: nil,
                    selectedPlotID: nil,
                    bubble: nil,
                    construction: construction
                )
            }
        }
        .frame(width: options.size.width, height: options.size.height)

        let imageRenderer = ImageRenderer(content: content)
        imageRenderer.scale = options.renderScale
        guard let cgImage = imageRenderer.cgImage else {
            throw NSError(domain: "CityRenderHarness", code: 1, userInfo: [NSLocalizedDescriptionKey: "ImageRenderer produced no CGImage"])
        }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "CityRenderHarness", code: 2, userInfo: [NSLocalizedDescriptionKey: "PNG encoding failed"])
        }
        try data.write(to: URL(fileURLWithPath: options.outputPath), options: Data.WritingOptions.atomic)
        print("render-city: t=\(options.dayFraction) phase=\(CityPalette.phaseName(t: options.dayFraction)) zoom=\(options.zoom) scale=\(cameraSnapshot.scale) band=\(band)")
        let titan = CityRenderer.sleepingTitanGeometry(worldBounds: staticPaths.groundWorldBounds)
        let titanScreen = camera.apply(titan.renderBounds.origin)
        print("render-city: ground=\(staticPaths.groundWorldBounds) titanScreenOrigin=\(titanScreen) titanSize=\(titan.renderBounds.width * cameraSnapshot.scale)x\(titan.renderBounds.height * cameraSnapshot.scale)")
    }

    /// Builds the synthetic construction-transition map for
    /// `--city-construct <node|plot>[:from:to[@progress]]`: the named node
    /// or plot rises between the given stages, frozen at `progress`
    /// (default 0.55) through the transition animation.
    private static func constructionTransitions(options: Options, stages: [String: Int], scape: CityScape) -> [String: CityDirector.DensityTransition] {
        guard let spec = options.constructPlot else { return [:] }
        var query = spec
        var fromOverride: Int?
        var toOverride: Int?
        var progress = 0.55
        if let atIndex = spec.lastIndex(of: "@"), let parsed = Double(spec[spec.index(after: atIndex)...]) {
            progress = min(max(parsed, 0), 1)
            query = String(spec[spec.startIndex..<atIndex])
        }
        let parts = query.split(separator: ":")
        if parts.count == 3, let from = Int(parts[1]), let to = Int(parts[2]) {
            query = String(parts[0])
            fromOverride = from
            toOverride = to
        }
        let plotID = scape.plots.first(where: { $0.id == query || $0.node.name == query })?.id ?? query
        let settled = stages[plotID] ?? CityDensity.stageCount
        let toStage = toOverride ?? settled
        let fromStage = fromOverride ?? max(0, toStage - 2)
        guard toStage > fromStage else { return [:] }
        print("render-city: construct plot=\(plotID) from=\(fromStage) to=\(toStage) progress=\(progress)")
        return [
            plotID: CityDirector.DensityTransition(
                fromStage: fromStage,
                toStage: toStage,
                start: options.date.addingTimeInterval(-CityDirector.densityTransitionDuration * progress)
            )
        ]
    }

    /// Sixteen-node stand-in for the live Colby atlas, exercising every tier,
    /// occupancy mode, job state, and the pending queue.
    static func demoSnapshot() -> ClusterSnapshot {
        func job(_ id: String, _ user: String, _ name: String, _ node: String, elapsed: Int, limit: Int) -> ClusterJob {
            ClusterJob(
                id: id,
                user: user,
                name: name,
                state: "RUNNING",
                elapsedSeconds: elapsed,
                limitSeconds: limit,
                remainingSeconds: limit - elapsed,
                nodeList: node,
                reason: ""
            )
        }
        func node(_ name: String, _ profile: String, _ gpuType: String, _ vram: Double, _ count: Int, _ used: Int, _ status: NodeStatus, _ state: String, _ label: String, _ jobs: [ClusterJob] = []) -> ClusterNode {
            ClusterNode(
                name: name,
                gres: [GPUResource(gpuType: gpuType, profile: profile, vramGB: vram, count: count, used: used)],
                state: state,
                status: status,
                stateLabel: label,
                jobs: jobs
            )
        }

        let nodes: [ClusterNode] = [
            node("n1", "h200", "H200", 141, 8, 8, .busy, "ALLOCATED", "Allocated", [
                job("4821137", "avery", "forecast-rl", "n1", elapsed: 52_400, limit: 86_400),
                job("4821140", "akim12", "gpt2-sft", "n1", elapsed: 18_200, limit: 43_200),
                job("4821155", "mgarcia", "sweep-7b", "n1", elapsed: 71_000, limit: 86_400),
                job("4821161", "tchen", "eval-suite", "n1", elapsed: 3_600, limit: 7_200),
            ]),
            node("n2", "h200", "H200", 141, 8, 5, .partial, "MIXED", "Mixed", [
                job("4821201", "slee9", "pretrain-13b", "n2", elapsed: 61_300, limit: 172_800),
                job("4821202", "avery", "kalshi-ppo", "n2", elapsed: 9_100, limit: 28_800),
            ]),
            node("n3", "rtxpro6000", "RTX PRO 6000", 96, 4, 4, .busy, "ALLOCATED", "Allocated", [
                job("4821310", "jpatel", "sdxl-lora", "n3", elapsed: 12_900, limit: 21_600),
                job("4821311", "mgarcia", "whisper-ft", "n3", elapsed: 30_100, limit: 43_200),
            ]),
            node("n4", "rtxpro6000", "RTX PRO 6000", 96, 4, 0, .idle, "IDLE", "Idle"),
            node("n5", "a100", "A100", 80, 4, 4, .busy, "ALLOCATED", "Allocated", [
                job("4821407", "nguyen", "llama-dpo", "n5", elapsed: 78_800, limit: 86_400),
                job("4821408", "akim12", "reward-model", "n5", elapsed: 5_400, limit: 10_800),
                job("4821412", "fbaker", "rm-bench", "n5", elapsed: 45_000, limit: 64_800),
            ]),
            node("n6", "a100", "A100", 80, 4, 2, .partial, "MIXED", "Mixed", [
                job("4821450", "tchen", "vit-train", "n6", elapsed: 25_200, limit: 50_400),
            ]),
            node("n7", "a100", "A100", 80, 4, 0, .idle, "IDLE", "Idle"),
            node("n8", "a100", "A100", 80, 4, 0, .drain, "DRAIN", "Draining"),
            node("n9", "l40s", "L40S", 48, 6, 6, .busy, "ALLOCATED", "Allocated", [
                job("4821518", "jpatel", "video-diff", "n9", elapsed: 14_700, limit: 36_000),
                job("4821519", "slee9", "clip-finetune", "n9", elapsed: 8_200, limit: 14_400),
            ]),
            node("n10", "l40s", "L40S", 48, 6, 3, .partial, "MIXED", "Mixed", [
                job("4821555", "mgarcia", "tts-train", "n10", elapsed: 19_900, limit: 28_800),
            ]),
            node("n11", "l40s", "L40S", 48, 6, 0, .idle, "IDLE", "Idle"),
            node("n12", "l4", "L4", 24, 4, 1, .partial, "MIXED", "Mixed", [
                job("4821602", "nguyen", "onnx-export", "n12", elapsed: 2_700, limit: 7_200),
            ]),
            node("n13", "l4", "L4", 24, 4, 0, .idle, "IDLE", "Idle"),
            node("n14", "mig", "MIG 1g.20gb", 20, 7, 5, .partial, "MIXED", "Mixed", [
                job("4821651", "fbaker", "infer-batch", "n14", elapsed: 11_300, limit: 21_600),
                job("4821652", "akim12", "emb-index", "n14", elapsed: 6_100, limit: 10_800),
            ]),
            node("n15", "mig", "MIG 1g.20gb", 20, 7, 0, .idle, "IDLE", "Idle"),
            node("n16", "h200", "H200", 141, 8, 8, .busy, "ALLOCATED", "Allocated", [
                job("4821701", "avery", "forecast-rl-2", "n16", elapsed: 80_300, limit: 86_400),
                job("4821704", "jpatel", "grpo-large", "n16", elapsed: 33_900, limit: 57_600),
            ]),
        ]
        let pending = [
            PendingJob(id: "4821801", user: "tchen", name: "optuna-sweep", reason: "Resources", limitSeconds: 57_600),
            PendingJob(id: "4821802", user: "mgarcia", name: "data-parallel", reason: "Resources", limitSeconds: 86_400),
            PendingJob(id: "4821803", user: "slee9", name: "rl-tune", reason: "Priority", limitSeconds: 43_200),
            PendingJob(id: "4821804", user: "nguyen", name: "eval-hold", reason: "Dependency", limitSeconds: 14_400),
        ]
        return ClusterSnapshot(generatedAt: Date(), nodes: nodes, pending: pending)
    }
    /// State fixtures feature the same one-GPU A100 node (`n1`) within the
    /// full atlas. Keeping the surrounding terrain avoids the corner titan
    /// obscuring the plot in tiny single-node worlds. Only n1's state changes.
    private static func singleStateSnapshot(scenario: String, date: Date) -> ClusterSnapshot? {
        let used: Int
        let status: NodeStatus
        let state: String
        let label: String
        var jobs: [ClusterJob] = []
        switch scenario {
        case "allocated":
            used = 1
            status = .busy
            state = "ALLOCATED"
            label = "Allocated"
            jobs = [ClusterJob(
                id: "4821900",
                user: "avery",
                name: "forecast-rl",
                state: "RUNNING",
                elapsedSeconds: 3_600,
                limitSeconds: 7_200,
                remainingSeconds: 3_600,
                nodeList: "n1",
                reason: ""
            )]
        case "free":
            used = 0
            status = .idle
            state = "IDLE"
            label = "Idle"
        case "drained":
            used = 0
            status = .drain
            state = "DRAIN"
            label = "Draining"
        case "unknown":
            used = 0
            status = .unknown
            state = "UNKNOWN"
            label = "Unknown"
        default:
            return nil
        }
        return ClusterSnapshot(
            generatedAt: date,
            nodes: [ClusterNode(
                name: "n1",
                gres: [GPUResource(gpuType: "A100", profile: "a100", vramGB: 80, count: 1, used: used)],
                state: state,
                status: status,
                stateLabel: label,
                jobs: jobs
            )] + demoSnapshot().nodes.filter { $0.name != "n1" },
            pending: []
        )
    }
}
