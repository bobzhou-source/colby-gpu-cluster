import CoreGraphics
import Foundation
import XCTest

@testable import ColbyGPUCluster

final class CityCreatureGeometryTests: XCTestCase {
    func testKaijuCullBoundsContainEveryRigSolid() {
        for seconds in stride(from: 0.0, through: 40.0, by: 0.5) {
            let pose = CityWhimsy.KaijuPose(
                x: 40,
                y: 50,
                heading: seconds < 20 ? 1 : -1,
                bob: 0.3,
                step: CGFloat(seconds.truncatingRemainder(dividingBy: 1)),
                tailPhase: CGFloat(seconds),
                roar: 1
            )
            let rig = CityActorFootprints.kaiju(
                center: CGPoint(x: pose.x, y: pose.y),
                heading: pose.heading,
                bob: pose.bob,
                step: pose.step,
                tailPhase: pose.tailPhase,
                jawDrop: pose.jawDrop,
                headRear: pose.headRear,
                liveliness: pose.liveliness
            )
            let footprint = CityCreatureGeometry.kaijuFootprint(for: pose)
            let solids = rig.feet + rig.legs + rig.joints + rig.arms + rig.tail + [
                rig.torso, rig.belly, rig.chest, rig.neck,
                rig.head, rig.brow, rig.snout, rig.jaw,
            ]
            for solid in solids {
                // Lofted limbs and tail segments carry a second ring, so
                // the cull has to contain both rings, not just the base.
                for vertex in solid.allVertices {
                    XCTAssertTrue(
                        footprint.insetBy(dx: -0.0001, dy: -0.0001).contains(vertex),
                        "Rig vertex \(vertex) escapes the culled footprint \(footprint)"
                    )
                }
                XCTAssertLessThanOrEqual(
                    solid.upperZ,
                    CityCreatureGeometry.Kaiju.height,
                    "Rig solid rises above the culled kaiju height"
                )
                XCTAssertGreaterThanOrEqual(solid.lowerZ, 0)
            }
        }
    }

    func testActorRenderPolicyUsesWorldScale() {
        XCTAssertEqual(CityCreatureRenderPolicy.scaleMode, .world)
    }

    func testActorScreenBoundsGrowInDirectProportionToCameraScale() {
        let pose = CityWhimsy.KaijuPose(
            x: 40,
            y: 50,
            heading: 1,
            bob: 0
        )
        let event = CityWhimsy.UFOEvent(
            x: 70,
            y: 45,
            altitude: 26,
            beam: 0.5
        )
        let small = CityCamera(scale: 1, translation: .zero)
        let large = CityCamera(scale: 3, translation: .zero)

        for projectedBounds in [
            CityCreatureGeometry.kaijuProjectedBounds(for: pose),
            CityCreatureGeometry.ufoProjectedBounds(for: event),
        ] {
            let smallBounds = CityCreatureGeometry.screenBounds(
                projectedBounds: projectedBounds,
                camera: small
            )
            let largeBounds = CityCreatureGeometry.screenBounds(
                projectedBounds: projectedBounds,
                camera: large
            )

            XCTAssertEqual(
                largeBounds.width / smallBounds.width,
                3,
                accuracy: 0.001
            )
            XCTAssertEqual(
                largeBounds.height / smallBounds.height,
                3,
                accuracy: 0.001
            )
        }
    }

    func testZoomBandsSelectIncreasingCreatureDetail() {
        XCTAssertEqual(CityCreatureDetail(band: .province), .silhouette)
        XCTAssertEqual(CityCreatureDetail(band: .city), .identity)
        XCTAssertEqual(CityCreatureDetail(band: .street), .full)
    }

    func testProvinceUFOUsesStaticIdentificationBeamWithoutFineDetail() {
        let policy = CityCreatureRenderPolicy.ufo(detail: .silhouette, night: 0.8)
        XCTAssertTrue(policy.drawBeam)
        XCTAssertFalse(policy.drawBeamCore)
        XCTAssertFalse(policy.drawLights)
        XCTAssertFalse(policy.drawAlien)
        XCTAssertEqual(policy.particleCount, 0)
    }

    func testStreetUFOEnablesBoundedFineDetail() {
        let policy = CityCreatureRenderPolicy.ufo(detail: .full, night: 0.8)
        XCTAssertTrue(policy.drawBeamCore)
        XCTAssertTrue(policy.drawLights)
        XCTAssertTrue(policy.drawAlien)
        XCTAssertEqual(policy.particleCount, 2)
    }

    func testPoseFootprintsRemainInsideTerrainBounds() {
        let bounds = CGRect(x: -20, y: 10, width: 40, height: 30)
        for seconds in stride(from: 0.0, through: 72.0, by: 1.0) {
            let date = Date(timeIntervalSinceReferenceDate: seconds)
            let kaiju = CityWhimsy.kaijuPose(
                date: date,
                reduceMotion: false,
                bounds: bounds
            )
            let ufo = CityWhimsy.ufoEvent(
                date: date,
                reduceMotion: false,
                bounds: bounds
            )
            XCTAssertTrue(bounds.contains(
                CityCreatureGeometry.kaijuFootprint(for: kaiju)
            ))
            XCTAssertTrue(bounds.contains(
                CityCreatureGeometry.ufoFootprint(for: ufo)
            ))
        }
    }
}
