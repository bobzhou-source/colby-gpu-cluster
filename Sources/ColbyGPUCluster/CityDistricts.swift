import CoreGraphics

public enum CityDistrict: String, CaseIterable, Sendable {
    case metropolis
    case large
    case mid
    case town
    case hamlet
}

struct DistrictStyle: Sendable {
    let accent: RGB
    let facadeFamilies: [RGB]
    let treeTarget: ClosedRange<Int>
    let shopChance: Double
    let rowGap: CGFloat

    /// Each district owns one candy hue family so neighborhoods read as
    /// distinct, saturated color blocks: turquoise metropolis, coral large,
    /// mint mid, sunny town, and berry hamlet.
    static func style(for district: CityDistrict) -> DistrictStyle {
        switch district {
        case .metropolis:
            DistrictStyle(
                accent: RGB(r: 120, g: 190, b: 255),
                facadeFamilies: [
                    RGB(r: 77, g: 182, b: 226),
                    RGB(r: 108, g: 146, b: 235),
                    RGB(r: 94, g: 208, b: 192),
                ],
                treeTarget: 2...4,
                shopChance: 0.85,
                rowGap: 14
            )
        case .large:
            DistrictStyle(
                accent: RGB(r: 255, g: 170, b: 90),
                facadeFamilies: [
                    RGB(r: 255, g: 138, b: 101),
                    RGB(r: 255, g: 177, b: 109),
                    RGB(r: 240, g: 112, b: 132),
                ],
                treeTarget: 3...5,
                shopChance: 0.7,
                rowGap: 12
            )
        case .mid:
            DistrictStyle(
                accent: RGB(r: 130, g: 220, b: 150),
                facadeFamilies: [
                    RGB(r: 112, g: 206, b: 140),
                    RGB(r: 156, g: 220, b: 118),
                    RGB(r: 84, g: 190, b: 168),
                ],
                treeTarget: 3...6,
                shopChance: 0.5,
                rowGap: 12
            )
        case .town:
            DistrictStyle(
                accent: RGB(r: 255, g: 214, b: 110),
                facadeFamilies: [
                    RGB(r: 255, g: 205, b: 92),
                    RGB(r: 250, g: 177, b: 96),
                    RGB(r: 255, g: 224, b: 130),
                ],
                treeTarget: 4...7,
                shopChance: 0.4,
                rowGap: 10
            )
        case .hamlet:
            DistrictStyle(
                accent: RGB(r: 236, g: 148, b: 210),
                facadeFamilies: [
                    RGB(r: 240, g: 144, b: 196),
                    RGB(r: 196, g: 152, b: 240),
                    RGB(r: 255, g: 170, b: 180),
                ],
                treeTarget: 4...8,
                shopChance: 0.3,
                rowGap: 10
            )
        }
    }
}
