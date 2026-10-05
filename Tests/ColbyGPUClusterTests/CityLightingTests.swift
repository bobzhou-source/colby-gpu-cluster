import XCTest
@testable import ColbyGPUCluster

@MainActor
final class CityLightingTests: XCTestCase {
    func testNightKeepsAmbientAndLocalLightWithoutDirectionalShadow() {
        let lighting = CityLighting.sample(palette: CityPalette.sample(t: 0))

        XCTAssertEqual(lighting.directionalIntensity, 0, accuracy: 1e-12)
        XCTAssertEqual(lighting.shadowOpacity, 0, accuracy: 1e-12)
        XCTAssertGreaterThan(lighting.ambientIntensity, 0)
        XCTAssertGreaterThan(lighting.localLightIntensity, 0.9)
    }

    func testMiddayProducesShortBoundedShadowAndStrongRoofLight() {
        let lighting = CityLighting.sample(palette: CityPalette.sample(t: 0.5))

        XCTAssertGreaterThan(lighting.directionalIntensity, 0.9)
        XCTAssertGreaterThan(lighting.shadowLength, 8.5)
        XCTAssertGreaterThan(lighting.shadowOpacity, 0.38)
        XCTAssertLessThan(lighting.shadowLength, 10)
        XCTAssertLessThanOrEqual(lighting.shadowLength, CityLighting.maximumShadowLength)
        XCTAssertGreaterThan(lighting.topIntensity, lighting.southwestIntensity)
        XCTAssertGreaterThan(lighting.topIntensity, lighting.southeastIntensity)
    }

    func testMorningAndAfternoonReverseShadowAndFacadeEmphasis() {
        let morning = CityLighting.sample(palette: CityPalette.sample(t: 0.34))
        let afternoon = CityLighting.sample(palette: CityPalette.sample(t: 0.66))

        let origin = IsoProjection.project(0, 0)
        let morningTip = IsoProjection.project(
            CGFloat(morning.shadowOffset.width),
            CGFloat(morning.shadowOffset.height)
        )
        let afternoonTip = IsoProjection.project(
            CGFloat(afternoon.shadowOffset.width),
            CGFloat(afternoon.shadowOffset.height)
        )
        XCTAssertLessThan(morningTip.x - origin.x, 0)
        XCTAssertGreaterThan(afternoonTip.x - origin.x, 0)
        XCTAssertGreaterThan(morningTip.y - origin.y, 0)
        XCTAssertGreaterThan(afternoonTip.y - origin.y, 0)
        XCTAssertGreaterThan(morning.southeastIntensity, morning.southwestIntensity)
        XCTAssertGreaterThan(afternoon.southwestIntensity, afternoon.southeastIntensity)
    }

    func testNearHorizonShadowIsBoundedAndFades() {
        let sunrise = CityLighting.sample(palette: CityPalette.sample(t: 0.251))
        let morning = CityLighting.sample(palette: CityPalette.sample(t: 0.34))

        XCTAssertLessThanOrEqual(sunrise.shadowLength, CityLighting.maximumShadowLength)
        XCTAssertLessThan(sunrise.shadowOpacity, morning.shadowOpacity)
    }

    func testGeometryKeyReusesSubthresholdDayCycleFrames() {
        let first = CityLighting.sample(palette: CityPalette.sample(t: 0.5000))
        let second = CityLighting.sample(palette: CityPalette.sample(t: 0.5001))

        XCTAssertEqual(first.geometryKey, second.geometryKey)
    }

    func testLampPoolsStayVisibleAtNightAndRestrainedByDay() {
        let night = CityLighting.sample(palette: CityPalette.sample(t: 0))
        let midday = CityLighting.sample(palette: CityPalette.sample(t: 0.5))

        XCTAssertGreaterThanOrEqual(CityLighting.streetLampPoolOpacity(for: night, detailScale: 0.7, flicker: 1), 0.38)
        XCTAssertLessThan(CityLighting.streetLampPoolOpacity(for: midday, detailScale: 0.7, flicker: 1), 0.10)
    }

    func testLampHeadHaloIsBrightAtNightAndSubtleByDay() {
        let night = CityLighting.sample(palette: CityPalette.sample(t: 0))
        let midday = CityLighting.sample(palette: CityPalette.sample(t: 0.5))

        XCTAssertGreaterThanOrEqual(CityLighting.streetLampHeadOpacity(for: night, detailScale: 1), 0.45)
        XCTAssertLessThan(CityLighting.streetLampHeadOpacity(for: midday, detailScale: 1), 0.15)
    }

    func testActiveWindowPoolsIlluminateNearbyGroundOnlyAtNight() {
        let night = CityLighting.sample(palette: CityPalette.sample(t: 0))
        let midday = CityLighting.sample(palette: CityPalette.sample(t: 0.5))

        XCTAssertEqual(CityLighting.windowPoolOpacity(for: night, utilization: 0, detailScale: 1), 0)
        let streetNight = CityLighting.windowPoolOpacity(for: night, utilization: 1, detailScale: 1)
        let cityNight = CityLighting.windowPoolOpacity(for: night, utilization: 1, detailScale: 0.65)
        XCTAssertGreaterThan(streetNight, 0.30)
        XCTAssertLessThan(cityNight, streetNight)
        XCTAssertLessThan(CityLighting.windowPoolOpacity(for: midday, utilization: 1, detailScale: 1), 0.02)
    }
    func testFacadeShadingTracksTheMovingSunWithoutReplacingMaterialHue() {
        let base = RGB(r: 190, g: 124, b: 112)
        let morningPalette = CityPalette.sample(t: 0.34)
        let afternoonPalette = CityPalette.sample(t: 0.66)
        let morning = CityPalette.faceColors(
            base: base,
            sample: morningPalette,
            lighting: CityLighting.sample(palette: morningPalette)
        )
        let afternoon = CityPalette.faceColors(
            base: base,
            sample: afternoonPalette,
            lighting: CityLighting.sample(palette: afternoonPalette)
        )

        XCTAssertGreaterThan(morning.right.r, morning.left.r)
        XCTAssertGreaterThan(afternoon.left.r, morning.left.r)
        XCTAssertGreaterThan(morning.top.r, morning.left.r)
        XCTAssertGreaterThan(afternoon.top.r, afternoon.right.r)
    }

    func testCastShadowGeometryMovesWithSunAndSkipsNight() throws {
        let morning = CityLighting.sample(palette: CityPalette.sample(t: 0.34))
        let afternoon = CityLighting.sample(palette: CityPalette.sample(t: 0.66))
        let night = CityLighting.sample(palette: CityPalette.sample(t: 0))
        let morningQuad = try XCTUnwrap(CityRenderer.realtimeShadowQuad(
            x: 0, y: 0, bw: 4, bd: 3, h: 10, lighting: morning
        ))
        let afternoonQuad = try XCTUnwrap(CityRenderer.realtimeShadowQuad(
            x: 0, y: 0, bw: 4, bd: 3, h: 10, lighting: afternoon
        ))

        XCTAssertEqual(morningQuad.count, 6)
        XCTAssertEqual(afternoonQuad.count, 6)
        XCTAssertNotEqual(morningQuad, afternoonQuad)
        XCTAssertNil(CityRenderer.realtimeShadowQuad(
            x: 0, y: 0, bw: 4, bd: 3, h: 10, lighting: night
        ))
    }

    func testLocalFacadeLiftOnlyWarmsActiveNightBuildings() {
        let base = RGB(r: 38, g: 46, b: 62)
        let night = CityLighting.sample(palette: CityPalette.sample(t: 0))
        let day = CityLighting.sample(palette: CityPalette.sample(t: 0.5))

        XCTAssertEqual(CityPalette.localLightLift(base, lighting: night, utilization: 0), base)
        XCTAssertEqual(CityPalette.localLightLift(base, lighting: day, utilization: 1), base)
        let lifted = CityPalette.localLightLift(base, lighting: night, utilization: 1)
        XCTAssertGreaterThan(lifted.r, base.r)
        XCTAssertGreaterThan(lifted.g, base.g)
    }

    func testCelestialBodiesFollowOpposingIsometricOrbits() {
        let sunrise = CityLighting.celestialPosition(palette: CityPalette.sample(t: 0.251))
        let noon = CityLighting.celestialPosition(palette: CityPalette.sample(t: 0.5))
        let sunset = CityLighting.celestialPosition(palette: CityPalette.sample(t: 0.749))
        let moonrise = CityLighting.celestialPosition(palette: CityPalette.sample(t: 0.751))
        let midnight = CityLighting.celestialPosition(palette: CityPalette.sample(t: 0))
        let moonset = CityLighting.celestialPosition(palette: CityPalette.sample(t: 0.249))

        XCTAssertGreaterThan(sunrise.x, noon.x)
        XCTAssertGreaterThan(noon.x, sunset.x)
        XCTAssertLessThan(noon.y, sunrise.y)
        XCTAssertLessThan(noon.y, sunset.y)
        XCTAssertLessThan(midnight.y, 0.25, "The moon must be visibly high at midnight")
        XCTAssertLessThan(moonrise.x, midnight.x)
        XCTAssertLessThan(midnight.x, moonset.x)
    }


}
