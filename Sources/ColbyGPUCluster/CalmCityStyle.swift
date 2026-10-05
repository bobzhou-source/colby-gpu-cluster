import SwiftUI

/// Candy toy-town design tokens: saturated but soft hues (high lightness, no
/// neon) over a dark plum ink, so the city reads as a cheerful miniature
/// diorama that stays easy on the eyes.
enum CalmCityStyle {
    static let skyTop = RGB(r: 118, g: 193, b: 240)
    static let skyHorizon = RGB(r: 255, g: 226, b: 178)
    /// Sage-calmed meadow green: desaturated just enough that candy facades
    /// and leaf canopies own the saturation budget instead of the lawn.
    static let ground = RGB(r: 139, g: 170, b: 139)
    static let water = RGB(r: 80, g: 190, b: 222)
    static let ink = RGB(r: 56, g: 46, b: 82)
    static let road = RGB(r: 228, g: 186, b: 134)
    static let paper = RGB(r: 255, g: 244, b: 222)
    /// Diorama base strata: warm soil over plum bedrock, so the extruded
    /// terrain rim reads as a cut physical model, not a floating polygon.
    static let soilTop = RGB(r: 158, g: 122, b: 84)
    static let soilDeep = RGB(r: 112, g: 84, b: 64)
    static let bedrock = RGB(r: 70, g: 58, b: 84)
    static let coral = RGB(r: 255, g: 111, b: 97)
    static let marigold = RGB(r: 255, g: 186, b: 61)
    static let spruce = RGB(r: 64, g: 195, b: 132)
    static let lavender = RGB(r: 164, g: 138, b: 236)
    /// Deep plum-lavender for the night sky horizon and tint: related to
    /// `lavender` but dark enough that terrain edges and the backdrop do not
    /// flare against the nightified ground.
    static let nightHorizon = RGB(r: 106, g: 96, b: 158)
    /// True midnight sky: deep enough that lamp pools, windows, and the moon
    /// own the night frame. Keyframe-only — `ink` stays the outline/shadow
    /// token everywhere else.
    static let midnightSky = RGB(r: 13, g: 10, b: 26)
    static let midnightHorizon = RGB(r: 34, g: 28, b: 62)
    static let sun = RGB(r: 255, g: 209, b: 84)
    static let leaf = RGB(r: 96, g: 201, b: 84)
    static let leafDeep = RGB(r: 58, g: 171, b: 94)
    static let blossom = RGB(r: 247, g: 148, b: 188)

    static func status(_ mode: CityMode) -> RGB {
        switch mode {
        case .lit:
            coral
        case .half:
            marigold
        case .vacant:
            spruce
        case .closed:
            lavender
        }
    }

    /// Stronger dimensional contrast: top faces key toward paper at full day,
    /// side faces deepen toward ink, so prism silhouettes read as solid
    /// miniature blocks instead of flat tinted polygons.
    static func faceShading(factors: (top: Double, left: Double, right: Double)) -> (top: Double, left: Double, right: Double) {
        (
            top: min(1.22, factors.top * 1.10),
            left: factors.left * 0.82,
            right: factors.right * 0.90
        )
    }

    enum BuildingState: String {
        case allocated, free, drained, unknown
    }

    /// Scheduler uncertainty and maintenance override inferred per-plot use.
    static func buildingState(for plot: CityPlot) -> BuildingState {
        switch plot.node.status {
        case .drain: .drained
        case .unknown: .unknown
        case .busy, .partial, .idle: plot.mode == .vacant ? .free : .allocated
        }
    }

    /// Facade-dominant mix keeps pavilions visibly candy-colored while a
    /// cream wash softens them toward the diorama's paper base.
    static func pavilionBase(facade: RGB) -> RGB {
        RGB(
            r: paper.r * 0.3 + facade.r * 0.7,
            g: paper.g * 0.3 + facade.g * 0.7,
            b: paper.b * 0.3 + facade.b * 0.7
        )
    }
}
