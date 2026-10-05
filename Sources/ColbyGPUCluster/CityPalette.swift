import Foundation
import SwiftUI

/// An RGB color in the reference city's 0...255 channel domain.
struct RGB: Equatable, Sendable {
    /// Red channel in the 0...255 domain.
    let r: Double
    /// Green channel in the 0...255 domain.
    let g: Double
    /// Blue channel in the 0...255 domain.
    let b: Double

    /// The equivalent SwiftUI color normalized to the 0...1 channel domain.
    /// Clamped: palette math (daylight shading of bright candy bases) can
    /// overshoot 255, and an extended-range component would silently promote
    /// the whole rendered canvas to a 16-bit wide-gamut format.
    var color: Color {
        Color(
            red: min(max(r / 255, 0), 1),
            green: min(max(g / 255, 0), 1),
            blue: min(max(b / 255, 0), 1)
        )
    }
}

struct CityPaletteFrame: Equatable, Sendable {
    let key: Int
    let sample: CityPalette.Sample
}

/// Deterministic 24-hour sky and building-lighting palette for the city atlas.
enum CityPalette {
    /// A fully sampled palette for one wrapped fraction of a day.
    struct Sample: Equatable, Sendable {
        /// Wrapped fraction of a day in 0..<1.
        let t: Double
        /// Interpolated sky color at the top of the scene.
        let skyTop: RGB
        /// Interpolated sky color at the horizon.
        let skyHorizon: RGB
        /// Interpolated atmospheric tint color.
        let tint: RGB
        /// Atmospheric tint blend amount.
        let tintAmount: Double
        /// Night darkness amount.
        let night: Double
        /// Daylight intensity, derived from the reference sun path.
        let dayAmount: Double
        /// Left-face diffuse-light contribution from the reference sun path.
        let diffuseLeft: Double
        /// Right-face diffuse-light contribution from the reference sun path.
        let diffuseRight: Double

        /// Sun path progress across the daylight arc (0 sunrise ... 1 sunset).
        let sunProgress: Double
    }

    /// Dev-render pin: when set, every `frame` request returns this exact day
    /// fraction. Only `CityRenderHarness` sets it; the live app never does.
    nonisolated(unsafe) static var pinnedDayFraction: Double?

    /// Selects one deterministic palette sample for a normal 15-minute or demo one-second bucket.
    static func frame(date: Date, demo: Bool, calendar: Calendar = .current) -> CityPaletteFrame {
        if let pinnedDayFraction {
            return CityPaletteFrame(key: 2_000 + Int(pinnedDayFraction * 10_000), sample: sample(t: pinnedDayFraction))
        }
        if demo {
            let elapsed = date.timeIntervalSinceReferenceDate
            let second = Int(elapsed.truncatingRemainder(dividingBy: 90) + 90).quotientAndRemainder(dividingBy: 90).remainder
            return CityPaletteFrame(key: 1_000 + second, sample: sample(t: Double(second) / 90))
        }

        let components = calendar.dateComponents([.hour, .minute], from: date)
        let hour = min(max(components.hour ?? 0, 0), 23)
        let minute = min(max(components.minute ?? 0, 0), 59)
        let step = hour * 4 + minute / 15
        return CityPaletteFrame(key: step, sample: sample(t: Double(step) / 96))
    }

    /// Samples the calm palette after wrapping `t` into 0..<1.
    static func sample(t: Double) -> Sample {
        let wrapped = wrappedTime(t)
        var index = 0
        while index < keyframes.count - 2 && keyframes[index + 1].time < wrapped {
            index += 1
        }

        let lower = keyframes[index]
        let upper = keyframes[index + 1]
        let fraction = smooth(clamp((wrapped - lower.time) / max(0.000_001, upper.time - lower.time), 0, 1))
        let sunProgress = clamp((wrapped - 0.25) / 0.5, 0, 1)
        let dayAmount = (wrapped > 0.25 && wrapped < 0.75) ? sin(.pi * sunProgress) : 0

        return Sample(
            t: wrapped,
            skyTop: mix(lower.skyTop, upper.skyTop, fraction),
            skyHorizon: mix(lower.skyHorizon, upper.skyHorizon, fraction),
            tint: mix(lower.tint, upper.tint, fraction),
            tintAmount: lerp(lower.tintAmount, upper.tintAmount, fraction),
            night: lerp(lower.night, upper.night, fraction),
            dayAmount: dayAmount,
            diffuseLeft: sin(sunProgress * .pi / 2),
            diffuseRight: cos(sunProgress * .pi / 2),
            sunProgress: sunProgress
        )
    }

    /// Mixes a color toward the reference midnight blue darkness by `night`.
    /// Near-black target (~5% source value) with a steepened curve: dusk keeps
    /// a readable plum world while full night collapses to darkness so lamp
    /// pools, windows, neon, and fires own the frame.
    static func nightify(_ c: RGB, night: Double) -> RGB {
        let dark = RGB(r: c.r * 0.05 + 3, g: c.g * 0.05 + 4, b: c.b * 0.05 + 12)
        let curved = pow(clamp(night, 0, 1), 1.35)
        return mix(c, dark, curved * 0.98)
    }

    /// Produces the reference top, left, and right prism colors for a building base color.
    /// Side faces dim by mixing toward the plum ink rather than multiplying
    /// toward black, so candy facades keep their hue at close zoom instead of
    /// collapsing into tan/slate. Directional separation matches the old
    /// multiplicative factors one-for-one.
    static func faceColors(
        base: RGB,
        sample: Sample,
        lighting: CityLighting.Sample? = nil,
        nightAttenuation: Double = 1.0
    ) -> (top: RGB, left: RGB, right: RGB) {
        var factors: (top: Double, left: Double, right: Double)
        if let lighting {
            factors = (
                top: 0.90 + 0.28 * lighting.topIntensity,
                left: 0.36 + 0.30 * lighting.southwestIntensity,
                right: 0.52 + 0.30 * lighting.southeastIntensity
            )
        } else {
            factors = (
                top: 1.02 + 0.10 * sample.dayAmount,
                left: 0.40 + 0.30 * sample.diffuseLeft,
                right: 0.60 + 0.30 * sample.diffuseRight
            )
        }
        // Crafted-atlas stylization: keyed through one CalmCityStyle hook so
        // tops lift toward paper while side faces deepen toward ink, making
        // the isometric prism read as a solid miniature block.
        factors = CalmCityStyle.faceShading(factors: factors)
        var top = shade(base, factors.top)
        var right = mix(base, CalmCityStyle.ink, 1 - factors.right)
        var left = mix(base, CalmCityStyle.ink, 1 - factors.left)
        top = mix(top, sample.tint, sample.tintAmount * 0.40)

        let amber = hex("#FFB347")
        let rightRim = sample.tintAmount * clamp(1 - sample.sunProgress * 2, 0, 1)
        let leftRim = sample.tintAmount * clamp(sample.sunProgress * 2 - 1, 0, 1)
        right = mix(right, amber, rightRim * 0.72)
        left = mix(left, amber, leftRim * 0.72)

        return (
            top: nightify(top, night: sample.night * nightAttenuation * 0.96),
            left: nightify(left, night: sample.night * nightAttenuation),
            right: nightify(right, night: sample.night * nightAttenuation)
        )
    }

    /// One aggregate warm facade response per active building. This is a
    /// bounded material lift, not a point-light allocation per window.
    static func localLightLift(
        _ base: RGB,
        lighting: CityLighting.Sample,
        utilization: Double
    ) -> RGB {
        let active = clamp(utilization, 0, 1)
        guard active > 0, lighting.localLightIntensity > 0.2 else { return base }
        let nightStrength = clamp((lighting.localLightIntensity - 0.12) / 0.88, 0, 1)
        return mix(base, RGB(r: 255, g: 213, b: 138), active * nightStrength * 0.12)
    }
    /// The muted daylight slate the ground plane is keyed toward. This is a
    /// reference target, not a destination: `surfaceDaylightLift` decides how
    /// far a surface actually travels toward it at full day.
    static let terrainDay = CalmCityStyle.ground
    static let surfaceDaylightLift = 0.82
    static let riverDaylightLift = 0.92
    static let buildingDaylightLift = 0.35

    /// Blends world surfaces through the calm paper-and-sage daylight palette.
    static func surface(day: RGB, night nightBase: RGB, sample: Sample, nightAttenuation: Double = 1, daylightLift: Double = surfaceDaylightLift) -> RGB {
        let daylight = mix(nightBase, day, daylightLift)
        let base = mix(daylight, nightBase, sample.night)
        let tinted = mix(base, sample.tint, sample.tintAmount * 0.25 * (1 - sample.night))
        // Quadratic after-darkening: dusk keeps its pastel-plum charm while
        // midnight pulls hand-set night bases (asphalt, terrain) down to true
        // dark. Scaled by nightAttenuation so base-layer callers keep control.
        return nightify(tinted, night: sample.night * sample.night * 0.65 * nightAttenuation)
    }

    /// Keeps the existing facade API while nudging it toward the calm paper campus palette.
    static func buildingBase(lit: Bool, sample: Sample) -> RGB {
        let facade = lit ? CalmCityStyle.coral : CalmCityStyle.spruce
        return mix(CalmCityStyle.pavilionBase(facade: facade), CalmCityStyle.ink, sample.night * 0.45)
    }

    static func buildingBase(lit: Bool, sample: Sample, facade: RGB) -> RGB {
        let base = CalmCityStyle.pavilionBase(facade: facade)
        return mix(base, CalmCityStyle.ink, sample.night * (lit ? 0.28 : 0.45))
    }

    /// Returns the exact reference clock phase for a wrapped fraction of a day.
    static func phaseName(t: Double) -> String {
        let wrapped = wrappedTime(t)
        if wrapped < 0.21 || wrapped >= 0.88 { return "NIGHT" }
        if wrapped < 0.31 { return "DAWN" }
        if wrapped < 0.45 { return "MORNING" }
        if wrapped < 0.62 { return "MIDDAY" }
        if wrapped < 0.70 { return "AFTERNOON" }
        if wrapped < 0.775 { return "GOLDEN HOUR" }
        if wrapped < 0.85 { return "DUSK" }
        return "NIGHT"
    }

    private struct Keyframe: Sendable {
        let time: Double
        let skyTop: RGB
        let skyHorizon: RGB
        let tint: RGB
        let tintAmount: Double
        let night: Double
    }

    private static let keyframes: [Keyframe] = [
        Keyframe(time: 0.00, skyTop: CalmCityStyle.midnightSky, skyHorizon: CalmCityStyle.midnightHorizon, tint: CalmCityStyle.midnightHorizon, tintAmount: 0.18, night: 1.00),
        Keyframe(time: 0.18, skyTop: CalmCityStyle.midnightSky, skyHorizon: CalmCityStyle.midnightHorizon, tint: CalmCityStyle.midnightHorizon, tintAmount: 0.15, night: 0.82),
        Keyframe(time: 0.24, skyTop: CalmCityStyle.lavender, skyHorizon: CalmCityStyle.coral, tint: CalmCityStyle.coral, tintAmount: 0.24, night: 0.56),
        Keyframe(time: 0.285, skyTop: CalmCityStyle.skyTop, skyHorizon: CalmCityStyle.skyHorizon, tint: CalmCityStyle.paper, tintAmount: 0.20, night: 0.22),
        Keyframe(time: 0.34, skyTop: CalmCityStyle.skyTop, skyHorizon: CalmCityStyle.skyHorizon, tint: CalmCityStyle.paper, tintAmount: 0.08, night: 0.04),
        Keyframe(time: 0.50, skyTop: CalmCityStyle.skyTop, skyHorizon: CalmCityStyle.skyHorizon, tint: CalmCityStyle.paper, tintAmount: 0.00, night: 0.00),
        Keyframe(time: 0.66, skyTop: CalmCityStyle.skyTop, skyHorizon: CalmCityStyle.skyHorizon, tint: CalmCityStyle.paper, tintAmount: 0.05, night: 0.03),
        Keyframe(time: 0.735, skyTop: CalmCityStyle.lavender, skyHorizon: CalmCityStyle.marigold, tint: CalmCityStyle.marigold, tintAmount: 0.24, night: 0.17),
        Keyframe(time: 0.775, skyTop: CalmCityStyle.lavender, skyHorizon: CalmCityStyle.coral, tint: CalmCityStyle.coral, tintAmount: 0.20, night: 0.48),
        Keyframe(time: 0.82, skyTop: CalmCityStyle.midnightSky, skyHorizon: CalmCityStyle.midnightHorizon, tint: CalmCityStyle.midnightHorizon, tintAmount: 0.16, night: 0.78),
        Keyframe(time: 0.88, skyTop: CalmCityStyle.midnightSky, skyHorizon: CalmCityStyle.midnightHorizon, tint: CalmCityStyle.midnightHorizon, tintAmount: 0.18, night: 1.00),
        Keyframe(time: 1.00, skyTop: CalmCityStyle.midnightSky, skyHorizon: CalmCityStyle.midnightHorizon, tint: CalmCityStyle.midnightHorizon, tintAmount: 0.18, night: 1.00),
    ]

    private static func hex(_ value: String) -> RGB {
        let digits = value.drop(while: { $0 == "#" })
        let red = Double(Int(digits.prefix(2), radix: 16)!)
        let green = Double(Int(digits.dropFirst(2).prefix(2), radix: 16)!)
        let blue = Double(Int(digits.dropFirst(4).prefix(2), radix: 16)!)
        return RGB(r: red, g: green, b: blue)
    }

    private static func wrappedTime(_ time: Double) -> Double {
        let remainder = time.truncatingRemainder(dividingBy: 1)
        return remainder < 0 ? remainder + 1 : remainder
    }

    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(max(value, lower), upper)
    }

    private static func lerp(_ lower: Double, _ upper: Double, _ amount: Double) -> Double {
        lower + (upper - lower) * amount
    }

    private static func smooth(_ value: Double) -> Double {
        value * value * (3 - 2 * value)
    }

    private static func mix(_ lower: RGB, _ upper: RGB, _ amount: Double) -> RGB {
        RGB(r: lerp(lower.r, upper.r, amount), g: lerp(lower.g, upper.g, amount), b: lerp(lower.b, upper.b, amount))
    }

    private static func shade(_ color: RGB, _ factor: Double) -> RGB {
        RGB(r: color.r * factor, g: color.g * factor, b: color.b * factor)
    }
}
