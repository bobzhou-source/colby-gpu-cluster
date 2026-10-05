import AppKit
import XCTest
import SwiftUI
@testable import ColbyGPUCluster

final class CityPaletteTests: XCTestCase {
    func testNormalFrameUsesOneSampleForEachQuarterHour() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let firstDate = calendar.date(from: DateComponents(year: 2026, month: 7, day: 12, hour: 14, minute: 2))!
        let secondDate = calendar.date(from: DateComponents(year: 2026, month: 7, day: 12, hour: 14, minute: 14, second: 59))!

        let first = CityPalette.frame(date: firstDate, demo: false, calendar: calendar)
        let second = CityPalette.frame(date: secondDate, demo: false, calendar: calendar)

        XCTAssertEqual(first.key, 56)
        XCTAssertEqual(first, second)
    }

    func testNormalFrameChangesAtTheNextQuarterHour() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let before = calendar.date(from: DateComponents(year: 2026, month: 7, day: 12, hour: 14, minute: 14, second: 59))!
        let after = calendar.date(from: DateComponents(year: 2026, month: 7, day: 12, hour: 14, minute: 15))!

        let first = CityPalette.frame(date: before, demo: false, calendar: calendar)
        let second = CityPalette.frame(date: after, demo: false, calendar: calendar)

        XCTAssertEqual(first.key, 56)
        XCTAssertEqual(second.key, 57)
        XCTAssertNotEqual(first.sample, second.sample)
    }

    func testDemoFrameKeysStaySeparateFromNormalKeys() {
        let first = CityPalette.frame(date: Date(timeIntervalSinceReferenceDate: 89.9), demo: true)
        let wrapped = CityPalette.frame(date: Date(timeIntervalSinceReferenceDate: 90), demo: true)
        let normal = CityPalette.frame(date: Date(timeIntervalSinceReferenceDate: 90), demo: false)

        XCTAssertEqual(first.key, 1_089)
        XCTAssertEqual(wrapped.key, 1_000)
        XCTAssertTrue((1_000...1_089).contains(first.key))
        XCTAssertTrue((1_000...1_089).contains(wrapped.key))
        XCTAssertFalse((1_000...1_089).contains(normal.key))
    }
    func testSampleAtZeroUsesMidnightSkyAndHorizonTokens() {
        let sample = CityPalette.sample(t: 0)

        assertRGB(sample.skyTop, equals: CalmCityStyle.midnightSky)
        assertRGB(sample.skyHorizon, equals: CalmCityStyle.midnightHorizon)
        assertRGB(sample.tint, equals: CalmCityStyle.midnightHorizon)
        XCTAssertEqual(sample.tintAmount, 0.18, accuracy: 1e-12)
        XCTAssertEqual(sample.night, 1, accuracy: 1e-12)
    }

    func testSampleWraparoundIsContinuousNearMidnight() {
        let beforeMidnight = CityPalette.sample(t: 0.999)
        let afterMidnight = CityPalette.sample(t: 0.001)

        assertRGB(beforeMidnight.skyTop, equals: afterMidnight.skyTop, accuracy: 0.01)
        assertRGB(beforeMidnight.skyHorizon, equals: afterMidnight.skyHorizon, accuracy: 0.01)
        assertRGB(beforeMidnight.tint, equals: afterMidnight.tint, accuracy: 0.01)
        XCTAssertEqual(beforeMidnight.tintAmount, afterMidnight.tintAmount, accuracy: 0.0001)
        XCTAssertEqual(beforeMidnight.night, afterMidnight.night, accuracy: 0.0001)
    }

    func testNightifyUsesCurrentDarkeningFormula() {
        let color = CityPalette.nightify(RGB(r: 100, g: 150, b: 200), night: 0.5)

        assertRGB(color, equals: RGB(
            r: 64.63094886681448,
            g: 96.75420019623701,
            b: 131.5685749814454
        ))
    }

    func testNightFallsMonotonicallyFromDawnToNoon() {
        let dawn = CityPalette.sample(t: 0.24).night
        let sunrise = CityPalette.sample(t: 0.285).night
        let morning = CityPalette.sample(t: 0.34).night
        let noon = CityPalette.sample(t: 0.5).night

        XCTAssertGreaterThan(dawn, sunrise)
        XCTAssertGreaterThan(sunrise, morning)
        XCTAssertGreaterThan(morning, noon)
    }

    func testSurfaceDarkensItsNightInputAtMidnight() {
        let surface = CityPalette.surface(
            day: CityPalette.terrainDay,
            night: RGB(r: 16, g: 20, b: 26),
            sample: CityPalette.sample(t: 0)
        )

        assertRGB(surface, equals: RGB(
            r: 9.316269380065968,
            g: 11.782298418113896,
            b: 19.0423459940031
        ))
    }

    func testSurfaceMovesTowardCalmGroundAtMidday() {
        let midpoint = CityPalette.surface(
            day: CityPalette.terrainDay,
            night: RGB(r: 16, g: 20, b: 26),
            sample: CityPalette.sample(t: 0.5)
        )

        assertRGB(
            midpoint,
            equals: RGB(
                r: 16 + (CalmCityStyle.ground.r - 16) * CityPalette.surfaceDaylightLift,
                g: 20 + (CalmCityStyle.ground.g - 20) * CityPalette.surfaceDaylightLift,
                b: 26 + (CalmCityStyle.ground.b - 26) * CityPalette.surfaceDaylightLift
            )
        )
    }



    func testPhaseNamesHonorEveryReferenceBoundary() {
        XCTAssertEqual(CityPalette.phaseName(t: 0.209_999), "NIGHT")
        XCTAssertEqual(CityPalette.phaseName(t: 0.21), "DAWN")
        XCTAssertEqual(CityPalette.phaseName(t: 0.31), "MORNING")
        XCTAssertEqual(CityPalette.phaseName(t: 0.45), "MIDDAY")
        XCTAssertEqual(CityPalette.phaseName(t: 0.62), "AFTERNOON")
        XCTAssertEqual(CityPalette.phaseName(t: 0.70), "GOLDEN HOUR")
        XCTAssertEqual(CityPalette.phaseName(t: 0.775), "DUSK")
        XCTAssertEqual(CityPalette.phaseName(t: 0.85), "NIGHT")
        XCTAssertEqual(CityPalette.phaseName(t: 0.88), "NIGHT")
    }

    func testSamplingIsDeterministicForEquivalentWrappedTimes() {
        let first = CityPalette.sample(t: -0.265)
        let second = CityPalette.sample(t: 12.735)

        assertRGB(first.skyTop, equals: second.skyTop)
        assertRGB(first.skyHorizon, equals: second.skyHorizon)
        assertRGB(first.tint, equals: second.tint)
        XCTAssertEqual(first.tintAmount, second.tintAmount, accuracy: 1e-12)
        XCTAssertEqual(first.night, second.night, accuracy: 1e-12)
        XCTAssertEqual(first.dayAmount, second.dayAmount, accuracy: 1e-12)
        XCTAssertEqual(first.diffuseLeft, second.diffuseLeft, accuracy: 1e-12)
        XCTAssertEqual(first.diffuseRight, second.diffuseRight, accuracy: 1e-12)
    }

    func testCarColorUsesApprovedVoxelPalette() {
        let color = NSColor(carColor(for: "a")).usingColorSpace(.sRGB)!

        XCTAssertEqual(color.redComponent, 1, accuracy: 0.001)
        XCTAssertEqual(color.greenComponent, 0.82, accuracy: 0.001)
        XCTAssertEqual(color.blueComponent, 0.25, accuracy: 0.001)
    }

    private func luminance(_ color: RGB) -> Double {
        0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b
    }

    private func assertRGB(_ actual: RGB, equals expected: RGB, accuracy: Double = 1e-9, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.r, expected.r, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.g, expected.g, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.b, expected.b, accuracy: accuracy, file: file, line: line)
    }
}
