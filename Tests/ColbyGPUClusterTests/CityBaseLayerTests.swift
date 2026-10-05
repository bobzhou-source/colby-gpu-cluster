import CoreGraphics
import XCTest
@testable import ColbyGPUCluster

@MainActor
final class CityBaseLayerTests: XCTestCase {
    func testScreenTransformMapsRenderedCameraIntoDisplayedCamera() {
        let rendered = CityCamera(scale: 2, translation: CGSize(width: 13, height: -7))
        let displayed = CityCamera(scale: 3, translation: CGSize(width: 31, height: 17))
        let transformed = CGPoint(x: 40, y: 20).applying(
            CityBaseLayerPolicy.screenTransform(from: rendered, to: displayed)
        )

        XCTAssertEqual(transformed.x, 71.5, accuracy: 0.000_001)
        XCTAssertEqual(transformed.y, 57.5, accuracy: 0.000_001)
    }

    func testScreenTransformIsIdentityForInvalidScales() {
        let valid = CityCamera(scale: 1, translation: .zero)
        let invalid = CityCamera(scale: .nan, translation: .zero)

        XCTAssertEqual(
            CityBaseLayerPolicy.screenTransform(from: valid, to: invalid),
            .identity
        )
    }

    func testCanDisplayRequiresSharedStructuralKey() {
        let rendered = key(camera: CityCamera(scale: 1, translation: .zero), band: .province)
        let transientCamera = key(camera: CityCamera(scale: 2, translation: CGSize(width: 20, height: 8)), band: .street)
        let newGeometry = CityBaseRenderKey(
            geometrySignature: "new-city",
            densitySignature: rendered.densitySignature,
            viewport: rendered.viewport,
            displayScale: rendered.displayScale,
            paletteBucket: rendered.paletteBucket,
            camera: rendered.camera,
            band: rendered.band
        )
        let newDensity = CityBaseRenderKey(
            geometrySignature: rendered.geometrySignature,
            densitySignature: "b:4",
            viewport: rendered.viewport,
            displayScale: rendered.displayScale,
            paletteBucket: rendered.paletteBucket,
            camera: rendered.camera,
            band: rendered.band
        )

        XCTAssertTrue(CityBaseLayerPolicy.canDisplay(rendered, for: transientCamera))
        XCTAssertFalse(CityBaseLayerPolicy.canDisplay(rendered, for: newGeometry))
        XCTAssertFalse(
            CityBaseLayerPolicy.canDisplay(rendered, for: newDensity),
            "crossing a density stage must force a fresh base render"
        )
    }

    func testRequestBurstRendersOnlyFinalKey() async {
        let coordinator = CityBaseRenderCoordinator()
        var renderKeys: [Int] = []

        for index in 0..<100 {
            let requested = key(camera: CityCamera(scale: 1, translation: CGSize(width: index, height: 0)), band: .city)
            coordinator.request(key: requested, delay: .milliseconds(120)) {
                renderKeys.append(index)
                return self.image(color: UInt8(index))
            }
        }
        try? await Task.sleep(for: .milliseconds(180))

        XCTAssertEqual(renderKeys, [99])
        XCTAssertEqual(coordinator.frame?.key.camera.translation.width, 99)
    }

    func testCancellationBeforeDelayDoesNotRender() async {
        let coordinator = CityBaseRenderCoordinator()
        var renderCount = 0

        coordinator.request(key: key(camera: CityCamera(scale: 1, translation: .zero), band: .city), delay: .milliseconds(120)) {
            renderCount += 1
            return self.image(color: 1)
        }
        coordinator.cancel()
        try? await Task.sleep(for: .milliseconds(180))

        XCTAssertEqual(renderCount, 0)
        XCTAssertNil(coordinator.frame)
    }

    func testObsoleteRenderCannotReplaceNewerKey() async {
        let coordinator = CityBaseRenderCoordinator()
        let old = key(camera: CityCamera(scale: 1, translation: .zero), band: .city)
        let new = key(camera: CityCamera(scale: 2, translation: .zero), band: .city)

        coordinator.request(key: old, delay: .zero) {
            await Task.yield()
            return self.image(color: 1)
        }
        await Task.yield()
        coordinator.request(key: new, delay: .zero) {
            self.image(color: 2)
        }
        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(coordinator.frame?.key, new)
    }

    func testContinuousRequestStreamStillLandsFrames() async {
        // Fast drags stream camera changes far longer than the settle delay.
        // The coordinator must throttle (render mid-stream), not debounce
        // (postpone forever): the retained base otherwise slides away and
        // leaves labels floating over empty sky.
        let coordinator = CityBaseRenderCoordinator()
        var renderCount = 0
        var last = key(camera: CityCamera(scale: 1, translation: .zero), band: .city)

        for index in 0..<10 {
            last = key(camera: CityCamera(scale: 1, translation: CGSize(width: index, height: 0)), band: .city)
            coordinator.request(key: last, delay: .milliseconds(60)) {
                renderCount += 1
                return self.image(color: UInt8(index))
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertGreaterThanOrEqual(renderCount, 2, "renders must land during the stream, not only after it ends")
        XCTAssertEqual(coordinator.frame?.key, last)
    }

    private func key(camera: CityCamera, band: ZoomBand) -> CityBaseRenderKey {
        CityBaseRenderKey(
            geometrySignature: "campus",
            densitySignature: "",
            viewport: CGSize(width: 460, height: 600),
            displayScale: 2,
            paletteBucket: 42,
            camera: camera,
            band: band
        )
    }

    private func image(color: UInt8) -> CGImage {
        let data = Data([color, color, color, 255])
        let provider = CGDataProvider(data: data as CFData)!
        return CGImage(
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }
}
