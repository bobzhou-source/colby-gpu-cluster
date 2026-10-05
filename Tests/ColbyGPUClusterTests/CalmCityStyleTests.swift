import XCTest
@testable import ColbyGPUCluster

final class CalmCityStyleTests: XCTestCase {
    func testStatusColorsFollowCityModes() {
        XCTAssertEqual(CalmCityStyle.status(.lit), CalmCityStyle.coral)
        XCTAssertEqual(CalmCityStyle.status(.half), CalmCityStyle.marigold)
        XCTAssertEqual(CalmCityStyle.status(.vacant), CalmCityStyle.spruce)
        XCTAssertEqual(CalmCityStyle.status(.closed), CalmCityStyle.lavender)
    }

    func testPavilionBaseUsesFacadeDominantCreamMix() {
        let facade = RGB(r: 4, g: 84, b: 164)

        let base = CalmCityStyle.pavilionBase(facade: facade)
        XCTAssertEqual(base.r, CalmCityStyle.paper.r * 0.3 + 4 * 0.7, accuracy: 1e-9)
        XCTAssertEqual(base.g, CalmCityStyle.paper.g * 0.3 + 84 * 0.7, accuracy: 1e-9)
        XCTAssertEqual(base.b, CalmCityStyle.paper.b * 0.3 + 164 * 0.7, accuracy: 1e-9)
        // Facade dominance is the design contract: the candy hue must survive the cream wash.
        XCTAssertLessThan(abs(base.g - 84), abs(base.g - CalmCityStyle.paper.g))
    }
}
