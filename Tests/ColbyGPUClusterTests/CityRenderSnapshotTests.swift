import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import ColbyGPUCluster

@MainActor
final class CityRenderSnapshotTests: XCTestCase {
    private let date = Date(timeIntervalSinceReferenceDate: 700_000_000)
    private let size = CGSize(width: 920, height: 720)

    func test_snapshotGallery() throws {
        guard let directory = ProcessInfo.processInfo.environment["CITY_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set CITY_SNAPSHOT_DIR to write the deterministic snapshot gallery.")
        }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

        let paletteAxis: [(Double, String)] = [
            (0.0, "000-night"), (0.24, "024-dawn"), (0.50, "050-midday"),
            (0.65, "065-afternoon"), (0.75, "075-goldenhour"), (0.85, "085-dusk"),
        ]
        for (name, camera, band) in cameras(size: size) {
            for (time, label) in paletteAxis {
                // Anchor the frame date to the same local time of day as `t` so
                // the in-app daypart badge agrees with the palette axis.
                let paletteDate = Calendar.current.startOfDay(for: date).addingTimeInterval(time * 86_400)
                let image = try renderPNG(camera: camera, t: time, band: band, size: size, frameDate: paletteDate)
                try writePNG(image, to: URL(filePath: directory).appending(path: "city-\(name)-t\(label).png"))
            }
            for offset in [0.0, 2.5, 5.0] {
                let image = try renderPNG(camera: camera, t: 0, band: band, size: size, frameDate: date.addingTimeInterval(offset))
                try writePNG(image, to: URL(filePath: directory).appending(path: "city-\(name)-motion-\(Int(offset * 10))ds.png"))
            }
        }
    }


    func testWorldSpacePropBoundsRemainVisibleInProvinceFrames() {
        let staticPaths = CitySceneStaticPaths(scape: scape)
        let worldBounds = staticPaths.groundWorldBounds
        let provinceCamera = cameras(size: size)[0].1
        let viewport = CGRect(origin: .zero, size: size)
        func screenBounds(_ bounds: CGRect) -> CGRect {
            CGRect(
                origin: provinceCamera.apply(bounds.origin),
                size: CGSize(
                    width: bounds.width * provinceCamera.scale,
                    height: bounds.height * provinceCamera.scale
                )
            )
        }

        let titan = CityRenderer.sleepingTitanGeometry(worldBounds: worldBounds)
        XCTAssertTrue(viewport.contains(screenBounds(titan.renderBounds)))
        XCTAssertTrue(worldBounds.contains(titan.worldFootprintBounds))
        XCTAssertTrue(titan.groundedSolids.flatMap(\.worldFootprint).allSatisfy {
            worldBounds.contains(CGPoint(x: $0.x, y: $0.y))
        })

        for hill in staticPaths.hills {
            let mound = CityIsometricMoundGeometry(
                x: hill.x,
                y: hill.y,
                height: hill.height * 1.55,
                radius: hill.radius * 1.05
            )
            XCTAssertTrue(viewport.contains(screenBounds(mound.projectedBounds)))
        }

        for reduceMotion in [false, true] {
            for offset in [0.0, 2.5, 5.0, 35.0, 70.0] {
                let model = CityWhimsy.balloon(
                    date: date.addingTimeInterval(offset),
                    reduceMotion: reduceMotion
                )
                let balloon = CityRenderer.balloonGeometry(model: model, bounds: worldBounds)
                XCTAssertTrue(
                    viewport.contains(screenBounds(balloon.projectedBounds)),
                    "Province frame must contain the balloon at offset \(offset), reduceMotion=\(reduceMotion)"
                )
            }
        }
    }

    func testReferenceActorAnchorsRemainVisibleAcrossGalleryFrames() {
        let staticPaths = CitySceneStaticPaths(scape: scape)
        let worldBounds = staticPaths.groundWorldBounds
        let startOfDay = Calendar.current.startOfDay(for: date)
        let frameDates = [0.0, 0.24, 0.50, 0.65, 0.75, 0.85].map {
            startOfDay.addingTimeInterval($0 * 86_400)
        } + [0.0, 2.5, 5.0].map {
            date.addingTimeInterval($0)
        }
        let safeViewport = CGRect(origin: .zero, size: size).insetBy(dx: 20, dy: 20)

        for frameDate in frameDates {
            let kaiju = CityWhimsy.kaijuPose(
                date: frameDate,
                reduceMotion: false,
                bounds: worldBounds
            )
            let ufo = CityWhimsy.ufoEvent(
                date: frameDate,
                reduceMotion: false,
                bounds: worldBounds
            )
            for (name, camera, _) in cameras(size: size) {
                let anchors = [
                    ("kaiju feet", camera.apply(IsoProjection.project(kaiju.x, kaiju.y, 0))),
                    (
                        "kaiju head",
                        camera.apply(IsoProjection.project(
                            kaiju.x + (kaiju.heading >= 0 ? 1.8 : -1.8),
                            kaiju.y - 1.2,
                            20 + kaiju.bob
                        ))
                    ),
                    ("UFO hull", camera.apply(IsoProjection.project(ufo.x, ufo.y, ufo.altitude))),
                    ("UFO beam", camera.apply(IsoProjection.project(ufo.x, ufo.y, 0))),
                ]
                for (actor, anchor) in anchors {
                    XCTAssertTrue(
                        safeViewport.contains(anchor),
                        "\(name) must contain the \(actor) on \(frameDate): \(anchor)"
                    )
                }
            }
        }
    }

    func testNightBackdropContainsMovingMoonBeforeTerrainComposition() throws {
        let image = try renderBackdropPNG(t: 0, size: size)
        let diameter = min(size.width, size.height) * 0.11
        let position = CityLighting.celestialPosition(palette: CityPalette.sample(t: 0))
        let center = CGPoint(x: size.width * position.x, y: size.height * position.y)
        let moonPixels = matchingPixelCount(
            in: image,
            rect: CGRect(
                x: center.x - diameter / 2,
                y: center.y - diameter / 2,
                width: diameter,
                height: diameter
            )
        ) { red, green, blue in
            blue > 0.75 && red > 0.5 && red < 0.75 && green > 0.4 && green < 0.65
                && blue > red + 0.15
        }

        XCTAssertGreaterThanOrEqual(
            moonPixels,
            2_000,
            "The moon must be drawn into the backdrop before terrain can occlude it."
        )
    }



    private func skyFloor(camera: CityCamera) -> (CGFloat) -> CGFloat {
        let bounds = CitySceneStaticPaths(scape: scape).groundWorldBounds
        let top = camera.apply(IsoProjection.project(bounds.minX, bounds.minY))
        let right = camera.apply(IsoProjection.project(bounds.maxX, bounds.minY))
        let left = camera.apply(IsoProjection.project(bounds.minX, bounds.maxY))
        return { x in
            if x >= top.x, x <= right.x, right.x > top.x {
                return top.y + (right.y - top.y) * ((x - top.x) / (right.x - top.x))
            }
            if x >= left.x, x < top.x, top.x > left.x {
                return left.y + (top.y - left.y) * ((x - left.x) / (top.x - left.x))
            }
            return self.size.height
        }
    }

    /// Daylight water must read as FILLED water, not as a ghost outline: the
    /// fill at the production meander center line (`CityScape.riverCenter`)
    /// must separate from the adjacent terrain and from the sky at every
    /// daylight palette sample — including golden hour, where the atmospheric
    /// tint mix compresses ground-plane contrast most. The margin is
    /// calibrated to the restored dark-city identity (restrained surface
    /// lift, stronger river lift): well above the ~14 pre-lift ghost level,
    /// below the ~30 the sky-reflecting river holds at golden hour.
    func testDaylightProvinceRiverSeparatesFromTerrainAndSky() throws {
        let (_, camera, band) = cameras(size: size).first { $0.0 == "province" }!
        // Flow stations picked clear of the calmed bridge corridor
        // (s ~ 0.38...0.66, where the avenue approach legitimately hugs the
        // band) and of the prop windows in `drawWater`.
        let stations: [CGFloat] = [0.12, 0.20, 0.30, 0.72, 0.82, 0.90]
        let floor = skyFloor(camera: camera)
        for (t, label) in [(0.50, "midday"), (0.65, "afternoon"), (0.75, "goldenhour")] {
            let image = try renderPNG(camera: camera, t: t, band: band, size: size, staticOnly: true)
            var deltas: [Double] = []
            var waterSamples: [(Double, Double, Double)] = []
            for s in stations {
                let center = CityScape.riverCenter(s)
                let water = camera.apply(IsoProjection.project(center.x, center.y))
                let bank = camera.apply(IsoProjection.project(center.x + 24, center.y))
                let waterPixel = try pixel(at: water, in: image)
                waterSamples.append(waterPixel)
                deltas.append(distance255(waterPixel, try pixel(at: bank, in: image)))
            }
            deltas.sort()
            XCTAssertGreaterThanOrEqual(
                deltas[deltas.count / 2], 24,
                "\(label) river fill must separate from adjacent ground by a clear margin — a near-terrain fill leaves only the bank outline (ghost quadrilateral). Deltas: \(deltas.map { Int($0) })"
            )
            // Probe the upper-right sky wash. At golden hour the deliberate
            // atmospheric tint moves sky and river closer together, so keep
            // the same clear margin required for bank separation there.
            let skyX: CGFloat = 828
            let skyPixel = try pixel(at: CGPoint(x: skyX, y: max(0, floor(skyX) - 70)), in: image)
            let skyDelta = distance255(waterSamples[1], skyPixel)
            let requiredSkyDelta = label == "goldenhour" ? 24.0 : 40.0
            XCTAssertGreaterThanOrEqual(
                skyDelta, requiredSkyDelta,
                "\(label) river fill must not camouflage into the sky wash (Δ\(Int(skyDelta)))."
            )
        }
    }



    /// Ground-hung telemetry keeps one white ink and a plum sticker shadow:
    /// the sign must show bright text pixels AND dark shadow pixels at night
    /// and at midday, so it stays legible on the plum night ground and on the
    /// bright cream daytime apron alike.
    func testHardwareSignTextStaysLegibleAtNightAndMidday() throws {
        let testSize = CGSize(width: 460, height: 360)
        let focusedSnapshot = ClusterSnapshot(
            generatedAt: date,
            nodes: [node(name: "n15", tier: .h200, gpuCount: 1, status: .idle)],
            pending: []
        )
        let focusedScape = CityScape.build(snapshot: focusedSnapshot)
        let plot = try XCTUnwrap(focusedScape.plots.first)
        let revealed = plot.buildings.filter { CityDensity.isRevealed($0.revealStage, at: 0) }
        let tallest = try XCTUnwrap(revealed.max { $0.h < $1.h })
        let sign = IsoProjection.project(
            plot.x + tallest.ox + tallest.bw / 2,
            plot.y + tallest.oy + tallest.bd + 0.8,
            1
        )
        let camera = CityCamera(
            scale: 4,
            translation: CGSize(width: testSize.width / 2 - sign.x * 4, height: testSize.height / 2 - sign.y * 4)
        )
        let textRect = CGRect(x: testSize.width / 2 - 70, y: testSize.height / 2 - 2, width: 140, height: 20)
        for (t, label) in [(0.0, "night"), (0.5, "midday")] {
            let image = try renderPNG(snapshot: focusedSnapshot, camera: camera, t: t, band: .city, size: testSize)
            XCTAssertGreaterThanOrEqual(
                matchingPixelCount(in: image, rect: textRect) { red, green, blue in
                    min(red, min(green, blue)) > 0.7
                },
                12,
                "The \(label) hardware sign needs bright text pixels."
            )
            XCTAssertGreaterThanOrEqual(
                matchingPixelCount(in: image, rect: textRect) { red, green, blue in
                    max(red, max(green, blue)) < 0.5
                },
                8,
                "The \(label) hardware sign needs dark sticker-shadow pixels for contrast."
            )
        }
    }




    func testStreetTelemetryTextDoesNotOverflowFarCropAtScaleEight() throws {
        let testSize = CGSize(width: 480, height: 280)
        let job = ClusterJob(
            id: "8501",
            user: "render",
            name: "telemetry",
            state: "RUNNING",
            elapsedSeconds: 72,
            limitSeconds: 600,
            remainingSeconds: 528,
            nodeList: "n15",
            reason: ""
        )
        let focusedSnapshot = ClusterSnapshot(
            generatedAt: date,
            nodes: [node(name: "n15", tier: .h200, gpuCount: 1, status: .busy, jobs: [job])],
            pending: []
        )
        let focusedScape = CityScape.build(snapshot: focusedSnapshot)
        let plot = try XCTUnwrap(focusedScape.plots.first)
        let building = try XCTUnwrap(plot.buildings.max { $0.h < $1.h })
        let labelWorld = IsoProjection.project(
            plot.x + building.ox + building.bw + 0.2,
            plot.y + building.oy + building.bd + 0.2,
            building.h * 0.12
        )
        let camera = CityCamera(
            scale: 8,
            translation: CGSize(width: 14 - labelWorld.x * 8, height: testSize.height / 2 - labelWorld.y * 8)
        )
        let image = try renderPNG(snapshot: focusedSnapshot, camera: camera, t: 0, band: .street, size: testSize)

        XCTAssertEqual(
            matchingPixelCount(in: image, rect: CGRect(x: 180, y: 0, width: testSize.width - 180, height: testSize.height)) { red, green, blue in
                red > 0.85 && green > 0.12 && green < 0.55 && blue > 0.42
            },
            0,
            "Screen-space progress text for job 8501 at 12% must not bleed into the far crop; that crop excludes its ribbon geometry."
        )
    }
    func testBaseWorldWindowOccupancyChangesWhenOnlyJobsChange() throws {
        let busy = snapshot
        var idleNodes = busy.nodes
        for index in idleNodes.indices {
            idleNodes[index].jobs = []
        }
        let idle = ClusterSnapshot(generatedAt: busy.generatedAt, nodes: idleNodes, pending: busy.pending)
        let (_, camera, band) = cameras(size: size).first { $0.0 == "city" }!

        let busyBase = try renderBasePNG(snapshot: busy, camera: camera, t: 0.5, band: band, size: size)
        let idleBase = try renderBasePNG(snapshot: idle, camera: camera, t: 0.5, band: band, size: size)

        XCTAssertNotEqual(
            busyBase.dataProvider?.data as Data?,
            idleBase.dataProvider?.data as Data?,
            "The retained base must refresh facade occupancy when active GPU jobs change."
        )
    }

    func testRefreshingSnapshotDoesNotPaintViewportHeightWhiteSweep() throws {
        let (_, camera, band) = cameras(size: size).first { $0.0 == "province" }!
        let fresh = try renderPNG(camera: camera, t: 0, band: band, size: size, refreshState: .fresh)
        let refreshing = try renderPNG(camera: camera, t: 0, band: band, size: size, refreshState: .refreshing)
        let phase = CGFloat(date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8)
        let sweepX = phase * (size.width + 120) - 85
        let samples = stride(from: CGFloat(150), through: size.height - 90, by: 120).map { y in
            CGPoint(x: sweepX + 50 * y / size.height, y: y)
        }
        let brightening = try samples.map { point in
            luminance(try pixel(at: point, in: refreshing)) - luminance(try pixel(at: point, in: fresh))
        }.sorted()
        let medianBrightening = brightening[brightening.count / 2]

        XCTAssertLessThan(
            medianBrightening,
            0.01,
            "Refreshing must not materially brighten the viewport-height sweep samples: \(brightening)"
        )
    }


    private var snapshot: ClusterSnapshot {
        ClusterSnapshot(generatedAt: date, nodes: [
            node(name: "n15", tier: .h200, gpuCount: 1, status: .busy, jobs: jobs(count: 3, node: "n15")),
            node(name: "n16", tier: .rtxpro6000, gpuCount: 1, status: .partial, jobs: jobs(count: 1, node: "n16")),
            node(name: "n10", tier: .a100, gpuCount: 1, status: .busy, jobs: jobs(count: 1, node: "n10")),
            node(name: "n2", tier: .l40s, gpuCount: 1, status: .idle),
            node(name: "n7", tier: .l4, gpuCount: 1, status: .drain),
            node(name: "n8", tier: .l4, gpuCount: 1, status: .busy, jobs: jobs(count: 1, node: "n8")),
            node(name: "n14", tier: .mig, gpuCount: 2, status: .idle),
        ], pending: [])
    }

    private var scape: CityScape { CityScape.build(snapshot: snapshot) }

    private func renderBackdropPNG(t: Double, size: CGSize) throws -> CGImage {
        let scene = CityRenderer(
            scape: scape,
            staticPaths: CitySceneStaticPaths(scape: scape),
            reduceMotion: false
        )
        let sample = CityPalette.sample(t: t)
        let content = Canvas { context, canvasSize in
            scene.drawBackdrop(context: &context, size: canvasSize, sample: sample)
        }
        let renderer = ImageRenderer(content: content.frame(width: size.width, height: size.height))
        renderer.scale = 1
        return try XCTUnwrap(renderer.cgImage)
    }

    private func renderPNG(snapshot: ClusterSnapshot? = nil, camera: CityCamera, t: Double, band: ZoomBand, size: CGSize, refreshState: SnapshotRefreshState = .fresh, frameDate: Date? = nil, staticOnly: Bool = false) throws -> CGImage {
        let renderDate = frameDate ?? date
        let scape = CityScape.build(snapshot: snapshot ?? self.snapshot)
        let staticPaths = CitySceneStaticPaths(scape: scape)
        let director = CityDirector()
        director.reconcile(scape: scape, date: date, reduceMotion: false, band: band)
        let scene = CityRenderer(scape: scape, staticPaths: staticPaths, reduceMotion: false)
        let sample = CityPalette.sample(t: t)
        let content = ZStack {
            Canvas { context, canvasSize in
                scene.drawBackdrop(context: &context, size: canvasSize, sample: sample)
            }
            Canvas { context, canvasSize in
                scene.drawBaseWorld(context: &context, size: canvasSize, sample: sample, camera: camera, band: band)
            }
            if !staticOnly {
                Canvas { context, canvasSize in
                    scene.drawLiveOverlay(
                        context: &context,
                        size: canvasSize,
                        date: renderDate,
                        sample: sample,
                        camera: camera,
                        band: band,
                        director: director,
                        refreshState: refreshState,
                        pending: [],
                        hoverPoint: nil,
                        hoveredPlotID: nil,
                        selectedPlotID: nil,
                        bubble: nil
                    )
                }
            }
        }
        let renderer = ImageRenderer(content: content.frame(width: size.width, height: size.height))
        renderer.scale = 1
        return try XCTUnwrap(renderer.cgImage)
    }

    private func renderBasePNG(snapshot: ClusterSnapshot, camera: CityCamera, t: Double, band: ZoomBand, size: CGSize) throws -> CGImage {
        let scape = CityScape.build(snapshot: snapshot)
        let scene = CityRenderer(
            scape: scape,
            staticPaths: CitySceneStaticPaths(scape: scape),
            reduceMotion: false
        )
        let content = Canvas { context, canvasSize in
            scene.drawBaseWorld(
                context: &context,
                size: canvasSize,
                sample: CityPalette.sample(t: t),
                camera: camera,
                band: band
            )
        }
        let renderer = ImageRenderer(content: content.frame(width: size.width, height: size.height))
        renderer.scale = 1
        return try XCTUnwrap(renderer.cgImage)
    }

    private func cameras(size: CGSize) -> [(String, CityCamera, ZoomBand)] {
        let scape = scape
        let province = CityCamera.fitting(
            worldScreenBounds: CitySceneView.framedWorldBounds(
                scape: scape,
                staticPaths: CitySceneStaticPaths(scape: scape)
            ),
            in: size,
            margin: 24,
            labelInset: 30
        )
        let plot = scape.plots.first { $0.node.name == "n15" }!
        let center = IsoProjection.project(plot.x + plot.w / 2, plot.y + plot.d / 2)
        func centered(scale: CGFloat) -> CityCamera {
            CityCamera(scale: scale, translation: CGSize(width: size.width / 2 - center.x * scale, height: size.height / 2 - center.y * scale))
        }
        return [
            ("province", province, .province),
            ("city", centered(scale: 1.8), .city),
            ("street", centered(scale: 4), .street),
        ]
    }

    private func node(name: String, tier: GPUTier, gpuCount: Int, status: NodeStatus, jobs: [ClusterJob] = []) -> ClusterNode {
        ClusterNode(
            name: name,
            gres: [GPUResource(gpuType: tier.shortLabel, profile: tier.rawValue, vramGB: 80, count: gpuCount, used: status == .idle ? 0 : gpuCount)],
            state: status.rawValue,
            status: status,
            stateLabel: status.rawValue,
            jobs: jobs
        )
    }

    private func jobs(count: Int, node: String) -> [ClusterJob] {
        (0..<count).map { index in
            ClusterJob(id: "\(node)-job-\(index)", user: "user\(index)", name: "job\(index)", state: "RUNNING", elapsedSeconds: 120, limitSeconds: 600, remainingSeconds: 480, nodeList: node, reason: "")
        }
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination), "Could not write \(url.path)")
    }

    private func pixel(at point: CGPoint, in image: CGImage) throws -> (Double, Double, Double) {
        let x = min(max(Int(point.x.rounded()), 0), image.width - 1)
        let y = min(max(Int(point.y.rounded()), 0), image.height - 1)
        let bytes = try XCTUnwrap(image.dataProvider?.data) as Data
        let offset = y * image.bytesPerRow + x * 4
        return colorComponents(in: image, bytes: bytes, offset: offset)
    }

    private func colorComponents(in image: CGImage, bytes: Data, offset: Int) -> (Double, Double, Double) {
        let values = (Double(bytes[offset]) / 255, Double(bytes[offset + 1]) / 255, Double(bytes[offset + 2]) / 255, Double(bytes[offset + 3]) / 255)
        let alphaInfo = CGImageAlphaInfo(rawValue: image.bitmapInfo.rawValue & CGBitmapInfo.alphaInfoMask.rawValue)
        let byteOrder = image.bitmapInfo.intersection(.byteOrderMask)
        switch (byteOrder, alphaInfo) {
        case (.byteOrder32Little, .premultipliedFirst),
             (.byteOrder32Little, .first),
             (.byteOrder32Little, .noneSkipFirst):
            return (values.2, values.1, values.0)
        case (.byteOrder32Little, .premultipliedLast),
             (.byteOrder32Little, .last),
             (.byteOrder32Little, .noneSkipLast):
            return (values.3, values.2, values.1)
        case (.byteOrder32Big, .premultipliedFirst),
             (.byteOrder32Big, .first),
             (.byteOrder32Big, .noneSkipFirst):
            return (values.1, values.2, values.3)
        default:
            return (values.0, values.1, values.2)
        }
    }
    private func matchingPixelCount(in image: CGImage, matching predicate: (Double, Double, Double) -> Bool) -> Int {
        guard let data = image.dataProvider?.data else { return 0 }
        let bytes = data as Data
        return stride(from: 0, to: image.height * image.bytesPerRow, by: 4).reduce(into: 0) { count, offset in
            guard offset + 3 < bytes.count else { return }
            let pixel = colorComponents(in: image, bytes: bytes, offset: offset)
            if predicate(pixel.0, pixel.1, pixel.2) {
                count += 1
            }
        }
    }

    private func matchingPixelCount(in image: CGImage, rect: CGRect, matching predicate: (Double, Double, Double) -> Bool) -> Int {
        let clipped = rect.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !clipped.isNull, let data = image.dataProvider?.data else { return 0 }
        let bytes = data as Data
        return (Int(clipped.minY)..<Int(clipped.maxY)).reduce(into: 0) { count, y in
            for x in Int(clipped.minX)..<Int(clipped.maxX) {
                let offset = y * image.bytesPerRow + x * 4
                let pixel = colorComponents(in: image, bytes: bytes, offset: offset)
                if predicate(pixel.0, pixel.1, pixel.2) {
                    count += 1
                }
            }
        }
    }

    private func luminance(_ rgb: (Double, Double, Double)) -> Double {
        0.2126 * rgb.0 + 0.7152 * rgb.1 + 0.0722 * rgb.2
    }

    /// Euclidean RGB distance in the 0...255 channel domain.
    private func distance255(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
        let dr = (a.0 - b.0) * 255, dg = (a.1 - b.1) * 255, db = (a.2 - b.2) * 255
        return (dr * dr + dg * dg + db * db).squareRoot()
    }
}
