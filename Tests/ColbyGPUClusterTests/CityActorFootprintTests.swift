import CoreGraphics
import XCTest
@testable import ColbyGPUCluster

final class CityActorFootprintTests: XCTestCase {
    func testCarBodyUsesTaperedWorldFootprintAlongX() {
        let body = CityActorFootprints.carBody(center: CGPoint(x: 10, y: 20), alongX: true)

        XCTAssertEqual(body, [
            CGPoint(x: 9.287, y: 19.69),
            CGPoint(x: 10.4464, y: 19.69),
            CGPoint(x: 10.713, y: 19.8264),
            CGPoint(x: 10.713, y: 20.1736),
            CGPoint(x: 10.4464, y: 20.31),
            CGPoint(x: 9.287, y: 20.31),
        ])
    }

    func testCarFootprintsRotateInWorldSpaceAlongY() {
        let center = CGPoint(x: 10, y: 20)
        let alongX = CityActorFootprints.carBody(center: center, alongX: true)
        let alongY = CityActorFootprints.carBody(center: center, alongX: false)

        for (actual, source) in zip(alongY, alongX) {
            XCTAssertEqual(actual.x, center.x - (source.y - center.y), accuracy: 0.0001)
            XCTAssertEqual(actual.y, center.y + (source.x - center.x), accuracy: 0.0001)
        }
    }

    func testCarCabinIsInsetAndBiasedAwayFromTaperedNose() {
        let cabin = CityActorFootprints.carCabin(center: CGPoint(x: 10, y: 20), alongX: true)

        XCTAssertEqual(cabin, [
            CGPoint(x: 9.659, y: 19.7892),
            CGPoint(x: 10.186, y: 19.7892),
            CGPoint(x: 10.31, y: 19.8884),
            CGPoint(x: 10.31, y: 20.1116),
            CGPoint(x: 10.186, y: 20.2108),
            CGPoint(x: 9.659, y: 20.2108),
        ])
    }

    func testCompactCarKeepsCabinLowAndInsetWithinWideBody() {
        let body = CityActorFootprints.carBody(center: .zero, alongX: true)
        let cabin = CityActorFootprints.carCabin(center: .zero, alongX: true)
        let bodyWidth = boundingWidth(body)
        let cabinWidth = boundingWidth(cabin)
        let bodyDepth = boundingHeight(body)
        let cabinDepth = boundingHeight(cabin)

        XCTAssertEqual(bodyWidth, 2.3 * CityActorFootprints.carScale, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(cabinWidth / bodyWidth, 0.48)
        XCTAssertLessThanOrEqual(cabinDepth / bodyDepth, 0.72)
    }

    func testCompactCarExposesOnlyTwoNearSideWheelCenters() {
        let wheels = CityActorFootprints.carVisibleWheelCenters(center: .zero, alongX: true)

        XCTAssertEqual(wheels.count, 2)
        XCTAssertLessThan(wheels[0].x, 0)
        XCTAssertGreaterThan(wheels[1].x, 0)
        XCTAssertEqual(wheels[0].y, wheels[1].y)
    }

    func testNorthSouthCarKeepsVisibleWheelsOnNearProjectedSide() {
        let wheels = CityActorFootprints.carVisibleWheelCenters(center: .zero, alongX: false)

        XCTAssertEqual(wheels, [
            CGPoint(x: 0.49 * CityActorFootprints.carScale, y: -0.72 * CityActorFootprints.carScale),
            CGPoint(x: 0.49 * CityActorFootprints.carScale, y: 0.68 * CityActorFootprints.carScale),
        ])
    }
    func testOrientedRectangleRotatesInWorldSpace() {
        XCTAssertEqual(
            CityActorFootprints.orientedRectangle(
                center: CGPoint(x: 10, y: 20),
                heading: CGVector(dx: 0, dy: 1),
                length: 4,
                width: 2
            ),
            [
                CGPoint(x: 11, y: 18),
                CGPoint(x: 11, y: 22),
                CGPoint(x: 9, y: 22),
                CGPoint(x: 9, y: 18),
            ]
        )
    }

    func testKaijuRigHasGroundedFeetBentPoseAndForwardSnout() throws {
        let rig = CityActorFootprints.kaiju(
            center: CGPoint(x: 40, y: 30),
            heading: 1,
            bob: 0
        )

        XCTAssertEqual(rig.feet.count, 2)
        // Walking pose at step 0.31: one support foot grounded, one lead foot raised
        let groundedFeet = rig.feet.filter { $0.lowerZ == 0 }
        let raisedFeet = rig.feet.filter { $0.lowerZ > 0 }
        XCTAssertEqual(groundedFeet.count, 1, "Walking pose must have exactly one grounded support foot")
        XCTAssertEqual(raisedFeet.count, 1, "Walking pose must have exactly one raised lead foot")
        XCTAssertGreaterThan(raisedFeet[0].lowerZ, 0.5, "Raised foot must be visibly lifted")
        XCTAssertNotEqual(rig.legs[0].center, rig.legs[1].center)
        XCTAssertNotEqual(rig.arms[0].upperZ, rig.arms[1].upperZ)
        XCTAssertGreaterThan(rig.head.center.x, rig.torso.center.x)
        XCTAssertGreaterThan(rig.snout.center.x, rig.head.center.x)
        XCTAssertEqual(rig.tail.last?.lowerZ, 0)
        XCTAssertGreaterThan(rig.neck.upperZ, rig.head.lowerZ)
        let headFront = try XCTUnwrap(rig.head.vertices.map(\.x).max())
        let snoutFront = try XCTUnwrap(rig.snout.vertices.map(\.x).max())
        XCTAssertGreaterThan(snoutFront - headFront, 1.5)
        XCTAssertLessThan(
            rig.snout.upperZ - rig.snout.lowerZ,
            (rig.head.upperZ - rig.head.lowerZ) * 0.65
        )
        XCTAssertLessThan(rig.jaw.upperZ, rig.snout.lowerZ)
        XCTAssertLessThan(rig.jaw.center.x, rig.snout.center.x)
        XCTAssertLessThan(
            boundingWidth(rig.jaw.vertices),
            boundingWidth(rig.snout.vertices)
        )
    }

    /// Every limb chain must stay welded across the whole walk cycle: the
    /// thigh's crown ring is centered on the hip socket, the thigh's base
    /// ring and the shin's crown ring are both centered on the knee socket,
    /// and the shin's base ring is centered on the ankle. Same for the arm
    /// chains at shoulder and elbow. This is what forbids gaps, drifting
    /// segment endpoints, and independent bobbing between the two segments
    /// around a joint.
    func testKaijuJointChainsStayConnectedAcrossFullWalkCycle() {
        func centroid(_ points: [CGPoint]) -> CGPoint {
            let count = max(1, points.count)
            return CGPoint(
                x: points.map(\.x).reduce(0, +) / CGFloat(count),
                y: points.map(\.y).reduce(0, +) / CGFloat(count)
            )
        }
        func assertPinned(
            _ ring: CGPoint,
            _ socket: CityActorSolid,
            _ name: String,
            _ step: CGFloat,
            _ heading: CGFloat
        ) {
            XCTAssertEqual(
                ring.x, socket.center.x, accuracy: 0.0001,
                "\(name) ring drifted off its socket at step \(step), heading \(heading)"
            )
            XCTAssertEqual(
                ring.y, socket.center.y, accuracy: 0.0001,
                "\(name) ring drifted off its socket at step \(step), heading \(heading)"
            )
        }
        for heading in [CGFloat(1), -1] {
            for fraction in stride(from: 0.0, through: 0.95, by: 0.05) {
                let step = CGFloat(fraction)
                let rig = CityActorFootprints.kaiju(
                    center: CGPoint(x: 40, y: 30),
                    heading: heading,
                    bob: 0.3,
                    step: step,
                    tailPhase: 1.7,
                    jawDrop: 0.3,
                    headRear: 0.4,
                    liveliness: 1,
                    stride: 0.28,
                    sway: 0.12
                )
                XCTAssertEqual(rig.joints.count, 10)
                XCTAssertEqual(rig.legs.count, 4)
                XCTAssertEqual(rig.arms.count, 4)
                // Far leg: thigh loft knee -> hip, shin loft ankle -> knee.
                assertPinned(centroid(rig.legs[0].upperVertices ?? []), rig.joints[0], "far hip", step, heading)
                assertPinned(centroid(rig.legs[0].vertices), rig.joints[1], "far knee (thigh)", step, heading)
                assertPinned(centroid(rig.legs[1].upperVertices ?? []), rig.joints[1], "far knee (shin)", step, heading)
                assertPinned(centroid(rig.legs[1].vertices), rig.joints[2], "far ankle", step, heading)
                // Near leg mirrors it: joints 5, 6, 7.
                assertPinned(centroid(rig.legs[2].upperVertices ?? []), rig.joints[5], "near hip", step, heading)
                assertPinned(centroid(rig.legs[2].vertices), rig.joints[6], "near knee (thigh)", step, heading)
                assertPinned(centroid(rig.legs[3].upperVertices ?? []), rig.joints[6], "near knee (shin)", step, heading)
                assertPinned(centroid(rig.legs[3].vertices), rig.joints[7], "near ankle", step, heading)
                // Arms: upper arm crown on the shoulder, upper base and
                // forearm crown on the elbow. Joints 3/4 far, 8/9 near.
                assertPinned(centroid(rig.arms[0].upperVertices ?? []), rig.joints[3], "far shoulder", step, heading)
                assertPinned(centroid(rig.arms[0].vertices), rig.joints[4], "far elbow (upper)", step, heading)
                assertPinned(centroid(rig.arms[1].upperVertices ?? []), rig.joints[4], "far elbow (forearm)", step, heading)
                assertPinned(centroid(rig.arms[2].upperVertices ?? []), rig.joints[8], "near shoulder", step, heading)
                assertPinned(centroid(rig.arms[2].vertices), rig.joints[9], "near elbow (upper)", step, heading)
                assertPinned(centroid(rig.arms[3].upperVertices ?? []), rig.joints[9], "near elbow (forearm)", step, heading)
                // Ankle rides its own foot: same lane, and the shin's base
                // height is the foot lift plus the fixed ankle height, so a
                // lifted foot carries its ankle with it instead of bobbing
                // independently.
                XCTAssertEqual(rig.legs[1].lowerZ - 1.30, rig.feet[0].lowerZ, accuracy: 0.0001)
                XCTAssertEqual(rig.legs[3].lowerZ - 1.30, rig.feet[1].lowerZ, accuracy: 0.0001)
                XCTAssertEqual(rig.joints[2].center.y, rig.feet[0].center.y, accuracy: 0.0001)
                XCTAssertEqual(rig.joints[7].center.y, rig.feet[1].center.y, accuracy: 0.0001)
                // Joints never sink into the ground.
                XCTAssertTrue(rig.joints.allSatisfy { $0.lowerZ >= 0 })
            }
        }
    }

    func testKaijuPlantedFeetHoldWorldPositionOnSmallAndLargePatrols() {
        for width: CGFloat in [180, 670] {
            let bounds = CGRect(x: -20, y: 10, width: width, height: 340)
            func rig(at seconds: Double) -> CityKaijuFootprints {
                let pose = CityWhimsy.kaijuPose(
                    date: Date(timeIntervalSinceReferenceDate: seconds),
                    reduceMotion: false, bounds: bounds
                )
                return CityActorFootprints.kaiju(
                    center: CGPoint(x: pose.x, y: pose.y), heading: pose.heading,
                    bob: pose.bob, step: pose.step, tailPhase: pose.tailPhase,
                    jawDrop: pose.jawDrop, headRear: pose.headRear,
                    liveliness: pose.liveliness, stride: pose.stride, sway: pose.sway
                )
            }
            // Cycles zero and eight face opposite directions. Sample the
            // stance interval of each foot using actual moving-world poses.
            for cycle in [0.0, 8.0] {
                for (foot, phase) in [(0, 0.65), (1, 0.15)] {
                    let first = rig(at: (cycle + phase) * 2.6).feet[foot]
                    let later = rig(at: (cycle + phase + 0.2) * 2.6).feet[foot]
                    XCTAssertEqual(first.lowerZ, 0, accuracy: 0.000001)
                    XCTAssertEqual(later.lowerZ, 0, accuracy: 0.000001)
                    XCTAssertEqual(later.center.x, first.center.x, accuracy: 0.000001)
                    XCTAssertEqual(later.center.y, first.center.y, accuracy: 0.000001)
                }
            }
        }
    }

    func testKaijuBothFeetRemainContinuousAtStepBoundaries() {
        let epsilon: CGFloat = 0.000001
        for heading: CGFloat in [-1, 1] {
            for boundary: CGFloat in [0.5, 1] {
                let before = CityActorFootprints.kaiju(
                    center: .zero, heading: heading, bob: 0,
                    step: boundary - epsilon, stride: 0.5
                )
                let after = CityActorFootprints.kaiju(
                    center: .zero, heading: heading, bob: 0,
                    step: (boundary + epsilon).truncatingRemainder(dividingBy: 1), stride: 0.5
                )
                for (left, right) in zip(before.feet, after.feet) {
                    XCTAssertEqual(left.center.x, right.center.x, accuracy: 0.0001)
                    XCTAssertEqual(left.center.y, right.center.y, accuracy: 0.0001)
                    XCTAssertEqual(left.lowerZ, right.lowerZ, accuracy: 0.0001)
                }
            }
        }
    }

    /// The published pose feeds the rig without re-deriving gait numbers:
    /// the pose's stride/sway pass through, and reduce motion freezes the
    /// walk at a connected neutral stance with both feet on their stations.
    func testKaijuPoseGaitFeedsRigAndFreezesConnected() {
        let bounds = CGRect(x: -20, y: 10, width: 180, height: 120)
        let moving = CityWhimsy.kaijuPose(
            date: Date(timeIntervalSinceReferenceDate: 100),
            reduceMotion: false,
            bounds: bounds
        )
        XCTAssertGreaterThan(moving.stride, 0)
        let movingRig = CityActorFootprints.kaiju(
            center: CGPoint(x: moving.x, y: moving.y),
            heading: moving.heading,
            bob: moving.bob,
            step: moving.step,
            tailPhase: moving.tailPhase,
            jawDrop: moving.jawDrop,
            headRear: moving.headRear,
            liveliness: moving.liveliness,
            stride: moving.stride,
            sway: moving.sway
        )
        XCTAssertEqual(movingRig.feet.count, 2)
        let frozen = CityWhimsy.kaijuPose(date: Date(), reduceMotion: true, bounds: bounds)
        XCTAssertEqual(frozen.step, 0)
        XCTAssertEqual(frozen.stride, 0)
        XCTAssertEqual(frozen.bob, 0)
        XCTAssertEqual(frozen.roar, 0)
        let frozenRig = CityActorFootprints.kaiju(
            center: CGPoint(x: frozen.x, y: frozen.y),
            heading: frozen.heading,
            bob: frozen.bob,
            step: frozen.step,
            stride: frozen.stride,
            sway: frozen.sway
        )
        // Neutral stance: both feet on their stations, both grounded, hips
        // level, and the leg chains still connected.
        for (foot, ankleJoint) in zip(frozenRig.feet, [frozenRig.joints[2], frozenRig.joints[7]]) {
            XCTAssertEqual(foot.lowerZ, 0, accuracy: 0.0001)
            XCTAssertEqual(ankleJoint.center.y, foot.center.y, accuracy: 0.0001)
        }
        // Hips level in the frozen stance: neither side sinks under a
        // stance load because neither foot is lifted.
        XCTAssertEqual(frozenRig.joints[0].lowerZ, frozenRig.joints[5].lowerZ, accuracy: 0.0001)
        XCTAssertEqual(frozenRig.joints[0].upperZ, frozenRig.joints[5].upperZ, accuracy: 0.0001)
    }


    func testUFOUsesNestedClippedWorldFootprints() {
        let rig = CityActorFootprints.ufo(
            center: CGPoint(x: 50, y: 40),
            diameter: 8
        )

        XCTAssertEqual(rig.lowerHull.count, 8)
        XCTAssertEqual(rig.lowerHull[0], CGPoint(x: 46, y: 39))
        XCTAssertEqual(rig.lowerHull[4], CGPoint(x: 54, y: 41))
        XCTAssertLessThan(
            boundingWidth(rig.upperHull),
            boundingWidth(rig.lowerHull)
        )
        XCTAssertLessThan(
            boundingWidth(rig.cockpit),
            boundingWidth(rig.upperHull)
        )
        XCTAssertEqual(
            CityExtrudedFootprint(
                vertices: rig.lowerHull,
                lowerZ: 9,
                upperZ: 11
            ).visibleSides.count,
            3
        )
    }

    private func boundingWidth(_ points: [CGPoint]) -> CGFloat {
        let values = points.map(\.x)
        return (values.max() ?? 0) - (values.min() ?? 0)
    }

    private func boundingHeight(_ points: [CGPoint]) -> CGFloat {
        let values = points.map(\.y)
        return (values.max() ?? 0) - (values.min() ?? 0)
    }

}
