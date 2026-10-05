import CoreGraphics
import Foundation

/// Deterministic, allocation-free lighting parameters shared by the retained
/// world and live overlay. It changes light response without changing the
/// authored CalmCityStyle material palette.
enum CityLighting {
    static let maximumShadowLength = 18.0

    struct GeometryKey: Equatable, Sendable {
        let shadowXQuarterUnits: Int
        let shadowYQuarterUnits: Int
        let intensitySixtyFourths: Int
    }

    struct Sample: Equatable, Sendable {
        let ambientIntensity: Double
        let directionalIntensity: Double
        let localLightIntensity: Double
        let topIntensity: Double
        let southwestIntensity: Double
        let southeastIntensity: Double
        let shadowOffset: CGSize
        let shadowLength: Double
        let shadowOpacity: Double
        let geometryKey: GeometryKey
    }

    static func streetLampPoolOpacity(
        for sample: Sample,
        detailScale: Double = 1,
        flicker: Double = 1
    ) -> Double {
        let visibility = 0.55 + 0.45 * max(0, min(1, detailScale))
        return (0.03 + 0.55 * sample.localLightIntensity) * visibility * max(0, min(1, flicker))
    }

    static func streetLampHeadOpacity(for sample: Sample, detailScale: Double) -> Double {
        let detail = 0.55 + 0.45 * max(0, min(1, detailScale))
        return (0.03 + 0.47 * sample.localLightIntensity) * detail
    }

    static func windowPoolOpacity(
        for sample: Sample,
        utilization: Double,
        detailScale: Double
    ) -> Double {
        let active = max(0, min(1, utilization))
        let detail = max(0, min(1, detailScale))
        let nightBias = 0.25 + 0.75 * (1 - sample.directionalIntensity)
        return 0.34 * sample.localLightIntensity * nightBias * active * detail
    }

    /// Normalized screen-space position for the visible celestial body. The
    /// sun travels upper-right to lower-left; the moon traverses the same
    /// isometric orbit in the opposite direction.
    static func celestialPosition(palette: CityPalette.Sample) -> CGPoint {
        let isDay = palette.t > 0.25 && palette.t < 0.75
        let progress: Double
        if isDay {
            progress = max(0, min(1, (palette.t - 0.25) / 0.5))
        } else if palette.t >= 0.75 {
            progress = max(0, min(1, (palette.t - 0.75) / 0.5))
        } else {
            progress = max(0, min(1, (palette.t + 0.25) / 0.5))
        }
        return CGPoint(
            x: isDay ? 0.78 - 0.60 * progress : 0.18 + 0.60 * progress,
            y: 0.62 - 0.56 * sin(.pi * progress)
        )
    }

    static func sample(palette: CityPalette.Sample) -> Sample {
        let daylight = max(0, min(1, palette.dayAmount))
        let ambient = 0.32 + daylight * 0.22
        let local = 0.12 + palette.night * 0.88

        guard daylight > 0, palette.t > 0.25, palette.t < 0.75 else {
            return Sample(
                ambientIntensity: ambient,
                directionalIntensity: 0,
                localLightIntensity: local,
                topIntensity: ambient,
                southwestIntensity: ambient,
                southeastIntensity: ambient,
                shadowOffset: .zero,
                shadowLength: 0,
                shadowOpacity: 0,
                geometryKey: GeometryKey(
                    shadowXQuarterUnits: 0,
                    shadowYQuarterUnits: 0,
                    intensitySixtyFourths: 0
                )
            )
        }

        let position = celestialPosition(palette: palette)
        let sunSide = (position.x - 0.5) * 2
        let screenShadowX = -sunSide
        let screenShadowY = 0.22 + (1 - daylight) * 0.50
        // Invert the ground-plane isometric projection:
        // screenX = 5.5(dx - dy), screenY = 3.4(dx + dy).
        let rawShadowX = screenShadowX / 11 + screenShadowY / 6.8
        let rawShadowY = screenShadowY / 6.8 - screenShadowX / 11
        let rawMagnitude = max(0.000_001, hypot(rawShadowX, rawShadowY))
        let length = min(maximumShadowLength, 9 + (1 - daylight) * 9)
        let shadowX = rawShadowX / rawMagnitude * length
        let shadowY = rawShadowY / rawMagnitude * length

        let top = min(1.25, ambient + daylight * (0.58 + 0.30 * daylight))
        let southwest = min(1.15, ambient + daylight * (0.16 + 0.40 * max(0, -sunSide)))
        let southeast = min(1.15, ambient + daylight * (0.16 + 0.40 * max(0, sunSide)))

        return Sample(
            ambientIntensity: ambient,
            directionalIntensity: daylight,
            localLightIntensity: local,
            topIntensity: top,
            southwestIntensity: southwest,
            southeastIntensity: southeast,
            shadowOffset: CGSize(width: shadowX, height: shadowY),
            shadowLength: length,
            shadowOpacity: 0.40 * pow(daylight, 0.7),
            geometryKey: GeometryKey(
                shadowXQuarterUnits: Int((shadowX * 4).rounded()),
                shadowYQuarterUnits: Int((shadowY * 4).rounded()),
                intensitySixtyFourths: Int((daylight * 64).rounded())
            )
        )
    }
}
