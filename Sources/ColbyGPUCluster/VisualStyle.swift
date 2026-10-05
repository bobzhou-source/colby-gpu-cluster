import SwiftUI


enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case graphite
    case blueprint
    case terminal

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var palette: AppPalette {
        switch self {
        case .system:
            AppPalette(
                background: Color(nsColor: .windowBackgroundColor),
                surface: Color(nsColor: .controlBackgroundColor),
                elevated: Color(nsColor: .underPageBackgroundColor),
                divider: Color(nsColor: .separatorColor),
                primary: .primary,
                secondary: .secondary,
                accent: .accentColor
            )
        case .graphite:
            AppPalette(
                background: Color(red: 0.075, green: 0.078, blue: 0.085),
                surface: Color(red: 0.11, green: 0.115, blue: 0.125),
                elevated: Color(red: 0.15, green: 0.155, blue: 0.165),
                divider: Color.white.opacity(0.13),
                primary: Color.white.opacity(0.94),
                secondary: Color.white.opacity(0.62),
                accent: Color(red: 0.31, green: 0.72, blue: 0.88)
            )
        case .blueprint:
            AppPalette(
                background: Color(red: 0.055, green: 0.075, blue: 0.10),
                surface: Color(red: 0.075, green: 0.115, blue: 0.155),
                elevated: Color(red: 0.09, green: 0.145, blue: 0.18),
                divider: Color(red: 0.25, green: 0.48, blue: 0.52),
                primary: Color(red: 0.91, green: 0.97, blue: 0.96),
                secondary: Color(red: 0.62, green: 0.76, blue: 0.77),
                accent: Color(red: 0.30, green: 0.78, blue: 0.82)
            )
        case .terminal:
            AppPalette(
                background: Color(red: 0.035, green: 0.045, blue: 0.035),
                surface: Color(red: 0.055, green: 0.075, blue: 0.055),
                elevated: Color(red: 0.08, green: 0.105, blue: 0.075),
                divider: Color(red: 0.22, green: 0.35, blue: 0.20),
                primary: Color(red: 0.86, green: 0.98, blue: 0.82),
                secondary: Color(red: 0.55, green: 0.70, blue: 0.51),
                accent: Color(red: 0.52, green: 0.82, blue: 0.44)
            )
        }
    }
}

struct AppPalette {
    let background: Color
    let surface: Color
    let elevated: Color
    let divider: Color
    let primary: Color
    let secondary: Color
    let accent: Color

    func status(_ status: NodeStatus) -> Color {
        switch status {
        case .idle: Color(red: 0.25, green: 0.78, blue: 0.48)
        case .partial: Color(red: 0.96, green: 0.68, blue: 0.20)
        case .busy: Color(red: 0.94, green: 0.34, blue: 0.32)
        case .drain: Color(red: 0.48, green: 0.50, blue: 0.56)
        case .unknown: Color(red: 0.64, green: 0.64, blue: 0.66)
        }
    }
}
