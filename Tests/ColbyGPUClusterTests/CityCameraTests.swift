import CoreGraphics
import Foundation
import XCTest
@testable import ColbyGPUCluster

final class CityCameraTests: XCTestCase {
    func testApplyAndInvertRoundTripPoints() {
        let camera = CityCamera(scale: 2.75, translation: CGSize(width: -48.5, height: 93.25))
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: -40, y: 8.5), CGPoint(x: 312.75, y: -17.25)]
        for point in points {
            let roundTripped = camera.invert(camera.apply(point))
            XCTAssertEqual(roundTripped.x, point.x, accuracy: 1e-9)
            XCTAssertEqual(roundTripped.y, point.y, accuracy: 1e-9)
        }
    }

    func testZoomKeepsWorldPointUnderAnchorFixed() {
        var camera = CityCamera(scale: 1.25, translation: CGSize(width: 34, height: -12))
        let anchor = CGPoint(x: 180, y: 270)
        let worldPoint = camera.invert(anchor)
        camera.zoom(by: 2.4, anchor: anchor)
        XCTAssertEqual(camera.apply(worldPoint).x, anchor.x, accuracy: 1e-9)
        XCTAssertEqual(camera.apply(worldPoint).y, anchor.y, accuracy: 1e-9)
        XCTAssertEqual(camera.scale, 3, accuracy: 1e-9)
    }

    func testZoomClampsScaleToDeclaredRange() {
        var camera = CityCamera(scale: 1, translation: .zero)
        let anchor = CGPoint(x: 150, y: 200)
        camera.zoom(by: 100, anchor: anchor)
        XCTAssertEqual(camera.scale, CityCamera.scaleRange.upperBound, accuracy: 1e-9)
        camera.zoom(by: 0.0001, anchor: anchor)
        XCTAssertEqual(camera.scale, CityCamera.scaleRange.lowerBound, accuracy: 1e-9)
    }

    func testClampTranslationLeavesAtLeastOneFifthOfWorldBoundsVisible() {
        var camera = CityCamera(scale: 1, translation: CGSize(width: -10_000, height: 10_000))
        let worldBounds = CGRect(x: 100, y: 80, width: 300, height: 200)
        let viewport = CGSize(width: 500, height: 400)
        camera.clampTranslation(worldScreenBounds: worldBounds, viewport: viewport)
        let transformed = transformedRect(worldBounds, by: camera)
        let visible = transformed.intersection(CGRect(origin: .zero, size: viewport))
        XCTAssertGreaterThanOrEqual(visible.width, worldBounds.width * 0.2 - 1e-4)
        XCTAssertGreaterThanOrEqual(visible.height, worldBounds.height * 0.2 - 1e-4)
    }

    func testZoomBandUsesExactProvinceCityAndStreetBoundaries() {
        XCTAssertEqual(ZoomBand(scale: 0.6), .province)
        XCTAssertEqual(ZoomBand(scale: 1.199_999), .province)
        XCTAssertEqual(ZoomBand(scale: 1.2), .city)
        XCTAssertEqual(ZoomBand(scale: 2.599_999), .city)
        XCTAssertEqual(ZoomBand(scale: 2.6), .street)
        XCTAssertEqual(ZoomBand(scale: 8), .street)
    }

    func testZoomBandNextUsesProvinceCityHysteresis() {
        XCTAssertEqual(ZoomBand.next(from: .province, scale: 1.2), .city)
        XCTAssertEqual(ZoomBand.next(from: .city, scale: 1.15), .city)
        XCTAssertEqual(ZoomBand.next(from: .city, scale: 1.079_999), .province)
    }

    func testZoomBandNextUsesCityStreetHysteresis() {
        XCTAssertEqual(ZoomBand.next(from: .city, scale: 2.6), .street)
        XCTAssertEqual(ZoomBand.next(from: .street, scale: 2.45), .street)
        XCTAssertEqual(ZoomBand.next(from: .street, scale: 2.349_999), .city)
    }

    func testFittingCameraContainsEveryPlotScreenBoundsInsideViewportMargin() throws {
        let snapshot = try SlurmParser.parseSnapshot(
            """
            ===SINFO===
            h200-01|idle|gpu:H200:1
            rtx-01|idle|gpu:RTX:1
            a100-01|alloc|gpu:A100:2
            l4-01|drain*|gpu:L4:1
            mig-01|idle|gpu:1g.20gb:1
            ===SQUEUE===
            ===RC=== 0 0
            """,
            now: Date(timeIntervalSince1970: 1_000)
        )
        let plots = CityScape.build(snapshot: snapshot).plots
        let worldBounds = plots.map { $0.screenBounds() }.reduce(CGRect.null) { $0.union($1) }
        let viewport = CGSize(width: 500, height: 680)
        let margin: CGFloat = 24
        let camera = CityCamera.fitting(worldScreenBounds: worldBounds, in: viewport, margin: margin)
        XCTAssertLessThan(
            camera.scale,
            CityCamera.scaleRange.lowerBound,
            "fitting must reduce below the interactive minimum when enlarged world bounds require it"
        )
        let allowed = CGRect(origin: .zero, size: viewport).insetBy(dx: margin, dy: margin)

        for plot in plots {
            XCTAssertTrue(allowed.contains(plot.screenBounds(camera: camera)), "\(plot.id) must fit the camera viewport")
        }
    }

    func testFittingCameraContainsMetropolisHighRiseRoofInsideViewportMargin() throws {
        let plot = CityPlot(
            node: ClusterNode(
                name: "metropolis-highrise",
                gpuType: "H200",
                profile: "h200",
                vramGB: 141,
                gpuCount: 1,
                state: "idle",
                status: .idle,
                stateLabel: "idle",
                jobs: []
            ),
            gpuIndex: 0,
            gpuCount: 1,
            x: 0,
            y: 0,
            w: 30,
            d: 20,
            mode: .lit,
            buildings: [
                BuildingSpec(ox: 0, oy: 0, bw: 4, bd: 4, h: 14, crackSeed: false, facade: RGB(r: 100, g: 100, b: 100)),
            ],
            hasCrane: false
        )
        let building = try XCTUnwrap(plot.buildings.only)
        XCTAssertGreaterThan(building.h, 10, "fixture must model a metropolis high-rise roof")
        let roofTier = try XCTUnwrap(building.tiers.last)
        let maximumAnimatedGrowth = growScale(sinceStart: 0.21, delay: 0, reduceMotion: false)
        XCTAssertGreaterThan(maximumAnimatedGrowth, 1.08, "fixture must exercise the construction overshoot")
        let animatedRoofHeight = building.h * roofTier.f1 * maximumAnimatedGrowth
        let roofCorners = [
            IsoProjection.project(
                plot.x + building.ox + roofTier.inset,
                plot.y + building.oy + roofTier.inset,
                animatedRoofHeight
            ),
            IsoProjection.project(
                plot.x + building.ox + building.bw - roofTier.inset,
                plot.y + building.oy + roofTier.inset,
                animatedRoofHeight
            ),
            IsoProjection.project(
                plot.x + building.ox + roofTier.inset,
                plot.y + building.oy + building.bd - roofTier.inset,
                animatedRoofHeight
            ),
            IsoProjection.project(
                plot.x + building.ox + building.bw - roofTier.inset,
                plot.y + building.oy + building.bd - roofTier.inset,
                animatedRoofHeight
            ),
        ]
        let worldBounds = plot.screenBounds()
        XCTAssertTrue(
            roofCorners.allSatisfy(worldBounds.contains),
            "screen bounds must contain the generated building roof"
        )

        let viewport = CGSize(width: 500, height: 680)
        let margin: CGFloat = 24
        let camera = CityCamera.fitting(worldScreenBounds: worldBounds, in: viewport, margin: margin)
        let allowed = CGRect(origin: .zero, size: viewport).insetBy(dx: margin, dy: margin)
        XCTAssertTrue(
            roofCorners.map(camera.apply).allSatisfy(allowed.contains),
            "fitting camera must keep the generated building roof inside the viewport margin"
        )
    }

    func testCameraAwareBoundsContainCameraAppliedProjectedLotCenter() throws {
        let snapshot = try SlurmParser.parseSnapshot(
            """
            ===SINFO===
            a100-01|alloc|gpu:A100:1
            ===SQUEUE===
            ===RC=== 0 0
            """,
            now: Date(timeIntervalSince1970: 1_000)
        )
        let plot = try XCTUnwrap(CityScape.build(snapshot: snapshot).plots.only)
        let camera = CityCamera(scale: 2.25, translation: CGSize(width: -71, height: 38))
        let projectedCenter = IsoProjection.project(plot.x + plot.w / 2, plot.y + plot.d / 2)
        let screenCenter = camera.apply(projectedCenter)
        let unprojected = IsoProjection.unproject(camera.invert(screenCenter))

        XCTAssertTrue(plot.screenBounds(camera: camera).contains(screenCenter))
        XCTAssertEqual(unprojected.x, plot.x + plot.w / 2, accuracy: 1e-9)
        XCTAssertEqual(unprojected.y, plot.y + plot.d / 2, accuracy: 1e-9)
    }
    func testAnchorInvariantZoomRemainsTrueWhenScaleIsClamped() {
        var camera = CityCamera(scale: 7.9, translation: CGSize(width: 24, height: -51))
        let anchor = CGPoint(x: 212, y: 144)
        let worldAtAnchor = camera.invert(anchor)

        camera.zoom(by: 3, anchor: anchor)

        XCTAssertEqual(camera.scale, 8, accuracy: 1e-9)
        XCTAssertEqual(camera.apply(worldAtAnchor).x, anchor.x, accuracy: 1e-9)
        XCTAssertEqual(camera.apply(worldAtAnchor).y, anchor.y, accuracy: 1e-9)
    }

    func testFirstZoomInFromBelowFloorUsesFittedScaleBeforeEnteringControlRange() {
        let viewport = CGSize(width: 500, height: 680)
        let fitted = CityCamera.fitting(
            worldScreenBounds: CGRect(x: 0, y: 0, width: 1_000, height: 1_000),
            in: viewport,
            margin: 24
        )
        XCTAssertLessThan(fitted.scale, CityCamera.scaleRange.lowerBound)
        var camera = fitted
        let anchor = CGPoint(x: viewport.width / 2, y: viewport.height / 2)
        let worldAtAnchor = camera.invert(anchor)

        camera.zoom(by: 1.1, anchor: anchor)

        XCTAssertEqual(camera.scale, fitted.scale * 1.1, accuracy: 1e-9)
        XCTAssertLessThan(camera.scale, CityCamera.scaleRange.lowerBound)
        XCTAssertEqual(camera.apply(worldAtAnchor).x, anchor.x, accuracy: 1e-9)
        XCTAssertEqual(camera.apply(worldAtAnchor).y, anchor.y, accuracy: 1e-9)
    }

    func testFittingWithNoUsableSpanRetainsFinitePositiveScaleAndTranslation() {
        let camera = CityCamera.fitting(
            worldScreenBounds: CGRect(x: -40, y: 20, width: 120, height: 80),
            in: CGSize(width: 100, height: 80),
            margin: 60
        )

        XCTAssertTrue(camera.scale.isFinite)
        XCTAssertGreaterThan(camera.scale, 0)
        XCTAssertTrue(camera.translation.width.isFinite)
        XCTAssertTrue(camera.translation.height.isFinite)
    }

    func testFittingWithLabelInsetReservesScreenRoomBelowTheContent() {
        let viewport = CGSize(width: 920, height: 720)
        let bounds = CGRect(x: 0, y: 0, width: 1_000, height: 1_000)
        let margin: CGFloat = 24
        let labelInset: CGFloat = 30
        let plain = CityCamera.fitting(worldScreenBounds: bounds, in: viewport, margin: margin)
        let biased = CityCamera.fitting(worldScreenBounds: bounds, in: viewport, margin: margin, labelInset: labelInset)

        let biasedBottom = biased.apply(CGPoint(x: bounds.midX, y: bounds.maxY)).y
        XCTAssertLessThanOrEqual(
            biasedBottom,
            viewport.height - margin - labelInset + 1e-9,
            "The fit must reserve room for the label stacks hanging below the lowest plots."
        )
        XCTAssertLessThan(
            biasedBottom,
            plain.apply(CGPoint(x: bounds.midX, y: bounds.maxY)).y,
            "Label-aware fitting must lift the chain toward frame center relative to the plain fit."
        )
        let biasedTop = biased.apply(CGPoint(x: bounds.midX, y: bounds.minY)).y
        XCTAssertGreaterThanOrEqual(biasedTop, margin - 1e-9)
    }

    func testRepeatedBelowFloorZoomOutKeepsScaleAndAnchorOperationsFinite() {
        var camera = CityCamera(scale: 0.1, translation: CGSize(width: 34, height: -51))
        let anchor = CGPoint(x: 212, y: 144)

        for _ in 0..<500 {
            let worldAtAnchor = camera.invert(anchor)
            camera.zoom(by: 0.1, anchor: anchor)

            XCTAssertTrue(camera.scale.isFinite)
            XCTAssertGreaterThan(camera.scale, 0)
            XCTAssertTrue(camera.translation.width.isFinite)
            XCTAssertTrue(camera.translation.height.isFinite)
            XCTAssertTrue(camera.invert(anchor).x.isFinite)
            XCTAssertTrue(camera.invert(anchor).y.isFinite)
            XCTAssertTrue(camera.apply(worldAtAnchor).x.isFinite)
            XCTAssertTrue(camera.apply(worldAtAnchor).y.isFinite)
        }
    }

    func testFirstZoomOutFromBelowFloorUsesFittedScaleBeforeEnteringControlRange() {
        let viewport = CGSize(width: 500, height: 680)
        let fitted = CityCamera.fitting(
            worldScreenBounds: CGRect(x: 0, y: 0, width: 1_000, height: 1_000),
            in: viewport,
            margin: 24
        )
        XCTAssertLessThan(fitted.scale, CityCamera.scaleRange.lowerBound)
        var camera = fitted
        let anchor = CGPoint(x: viewport.width / 2, y: viewport.height / 2)
        let worldAtAnchor = camera.invert(anchor)

        camera.zoom(by: 0.8, anchor: anchor)

        XCTAssertEqual(camera.scale, fitted.scale * 0.8, accuracy: 1e-9)
        XCTAssertLessThan(camera.scale, fitted.scale)
        XCTAssertEqual(camera.apply(worldAtAnchor).x, anchor.x, accuracy: 1e-9)
        XCTAssertEqual(camera.apply(worldAtAnchor).y, anchor.y, accuracy: 1e-9)
    }

    private func transformedRect(_ rect: CGRect, by camera: CityCamera) -> CGRect {
        let corners = [camera.apply(rect.origin), camera.apply(CGPoint(x: rect.maxX, y: rect.minY)), camera.apply(CGPoint(x: rect.minX, y: rect.maxY)), camera.apply(CGPoint(x: rect.maxX, y: rect.maxY))]
        let xs = corners.map(\.x)
        let ys = corners.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }
}

private extension Array {
    var only: Element? {
        count == 1 ? first : nil
    }
}
