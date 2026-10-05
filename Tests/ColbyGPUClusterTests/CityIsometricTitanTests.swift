import Testing
import CoreGraphics
@testable import ColbyGPUCluster

@Suite("CityIsometricTitan")
struct CityIsometricTitanTests {
    /// Ground extent of the whole figure along its long axis.
    private func groundLength(_ titan: CityIsometricTitanGeometry) -> CGFloat {
        titan.worldFootprintBounds.width
    }

    /// Tallest point of any mass, dome peaks included.
    private func apex(_ titan: CityIsometricTitanGeometry) -> CGFloat {
        titan.allSolids.map { $0.baseZ + $0.height + $0.domePeak }.max() ?? 0
    }

    @Test("The golem lies on its side: one long low body, head and feet at opposite ends")
    func sideLyingSilhouette() {
        let titan = CityIsometricTitanGeometry(x: 0, y: 0)

        // A reclining body is far longer along the ground than it is tall.
        // A seated or standing stack fails this outright.
        #expect(groundLength(titan) >= apex(titan) * 3)

        // Head at one end of the long axis, feet at the other, with the
        // trunk between them: the figure reads head-to-toe across the
        // terrain instead of bottom-to-top.
        #expect(titan.footDown.worldBounds.maxX < titan.torso.worldBounds.minX)
        #expect(titan.footUp.worldBounds.maxX < titan.torso.worldBounds.minX)
        #expect(titan.head.worldBounds.minX > titan.torso.worldBounds.midX)

        // The trunk runs along the ground, not up from it.
        #expect(titan.torso.worldBounds.width > titan.torso.height)
        #expect(titan.torso.baseZ == 0)
    }

    @Test("The trunk is one contiguous mass spanning hips to shoulders")
    func continuousTrunk() {
        let titan = CityIsometricTitanGeometry(x: 0, y: 0)
        let trunk = titan.torso.worldBounds

        for core in [titan.hipCoreDown, titan.hipCoreUp, titan.shoulderCoreUp] {
            #expect(trunk.contains(CGPoint(x: core.worldBounds.midX, y: core.worldBounds.midY)))
        }
        // Hip end and shoulder end belong to the same solid, so there is no
        // seam where a stacked pelvis slab used to meet a chest slab.
        #expect(titan.hipCoreDown.worldBounds.midX < titan.shoulderCoreUp.worldBounds.midX)
        #expect(titan.torso.height >= 3.5 * CityIsometricTitanGeometry.modelScale)
    }

    @Test("The head rests on the bent lower arm, which stays planted")
    func headRestsOnLowerArm() {
        let titan = CityIsometricTitanGeometry(x: 0, y: 0)
        let pillow = titan.forearmDown

        // The pillow is on the ground and the skull sits exactly on top of
        // it: no floating head, no head sunk into the terrain.
        #expect(pillow.baseZ == 0)
        #expect(abs(titan.head.baseZ - (pillow.baseZ + pillow.height)) < 0.001)

        // The head actually covers the forearm rather than merely touching it.
        let overlap = titan.head.worldBounds.intersection(pillow.worldBounds)
        #expect(!overlap.isNull)
        #expect(overlap.width * overlap.height >= 0.6 * pillow.worldBounds.width * pillow.worldBounds.height)

        // Shoulder end -> elbow -> wrist -> hand all remain one grounded arm.
        #expect(titan.upperArmDown.baseZ == 0)
        #expect(!titan.upperArmDown.worldBounds.intersection(pillow.worldBounds).isNull)
        #expect(!pillow.worldBounds.intersection(titan.handDown.worldBounds).isNull)
        // The arm folds: the hand ends up past the head's near edge, so the
        // limb reads as bent under the face, not stretched out behind it.
        #expect(titan.handDown.worldBounds.midX > titan.upperArmDown.worldBounds.maxX)
    }

    @Test("Both legs bend and fold sideways, the sky-side leg resting on its twin")
    func bentLegsFoldToTheSide() {
        let titan = CityIsometricTitanGeometry(x: 0, y: 0)

        for (thigh, shin, foot) in [
            (titan.thighDown, titan.shinDown, titan.footDown),
            (titan.thighUp, titan.shinUp, titan.footUp),
        ] {
            // Each segment joins the next: no gaps at knee or ankle.
            #expect(!thigh.worldBounds.intersection(shin.worldBounds).isNull)
            #expect(!shin.worldBounds.intersection(foot.worldBounds).isNull)
            // The knee bends forward of the hip and the foot trails the
            // shin, so the leg folds across the terrain.
            #expect(shin.worldBounds.maxY > thigh.worldBounds.maxY)
            #expect(foot.worldBounds.maxY > shin.worldBounds.maxY)
        }
        // The ground-side leg is crushed under the sky-side leg.
        #expect(titan.thighDown.baseZ == 0)
        #expect(titan.thighUp.baseZ > titan.thighDown.baseZ)
        #expect(titan.thighUp.baseZ <= titan.thighDown.baseZ + titan.thighDown.height)
    }

    @Test("The face is quarter-turned onto its cheek and stands proud of the head")
    func sidewaysFace() {
        let titan = CityIsometricTitanGeometry(x: 0, y: 0)

        // Crown -> brow -> nose -> chin runs along the body's long axis
        // because the head lies on its side.
        #expect(titan.brow.worldBounds.midX > titan.nose.worldBounds.midX)
        #expect(titan.nose.worldBounds.midX > titan.mouth.worldBounds.midX)
        // ... and they share a height band instead of stacking in z.
        let browTop = titan.brow.baseZ + titan.brow.height
        let mouthTop = titan.mouth.baseZ + titan.mouth.height
        #expect(min(browTop, mouthTop) - max(titan.brow.baseZ, titan.mouth.baseZ) > 0)

        // Inlays are proud of the head's camera-facing plane in paint order,
        // so the waking eye covers the sleeping slit in the same socket.
        #expect(titan.eyeSlit.worldBounds.maxY > titan.head.worldBounds.maxY)
        #expect(titan.eyeOpen.worldBounds.maxY > titan.eyeSlit.worldBounds.maxY)
        #expect(titan.pupil.worldBounds.maxY > titan.eyeOpen.worldBounds.maxY)
        #expect(titan.nose.worldBounds.maxY > titan.head.worldBounds.maxY)
        let socket = titan.eyeSlit.worldBounds.intersection(titan.eyeOpen.worldBounds)
        #expect(!socket.isNull)
        #expect(socket.width * socket.height >= 0.3 * titan.eyeSlit.worldBounds.width * titan.eyeSlit.worldBounds.height)

        // Two sockets on a cheek-down head stack vertically on screen.
        #expect(titan.eyeSocketOffset.x == 0)
        #expect(titan.eyeSocketOffset.y < 0)
    }

    @Test("Eye glow is centered on the elevated pupil facets")
    func eyeGlowCenter() {
        let titan = CityIsometricTitanGeometry(x: 0, y: 0)
        let points = titan.pupil.facets.flatMap(\.projectedPoints)
        let expected = points.reduce(CGPoint.zero) {
            CGPoint(
                x: $0.x + $1.x / CGFloat(points.count),
                y: $0.y + $1.y / CGFloat(points.count)
            )
        }
        let center = CityRenderer.titanEyeGlowCenter(for: titan)

        #expect(abs(center.x - expected.x) < 1e-9)
        #expect(abs(center.y - expected.y) < 1e-9)
    }

    @Test("Waking lifts the head and turns the face without sitting the golem up")
    func wakeLiftsHeadOnly() {
        let asleep = CityIsometricTitanGeometry(x: 0, y: 0, wake: 0)
        let awake = CityIsometricTitanGeometry(x: 0, y: 0, wake: 1)

        #expect(awake.head.baseZ > asleep.head.baseZ)
        for pose in [asleep, awake] {
            // The neck stretches with the head: never a floating skull.
            #expect(pose.neck.baseZ + pose.neck.height + pose.neck.domePeak >= pose.head.baseZ)
            #expect(!pose.neck.worldBounds.intersection(pose.head.worldBounds).isNull)
        }
        // The body stays down: trunk, legs, and the arm it sleeps on are
        // untouched, and the figure is still far longer than it is tall.
        #expect(awake.torso == asleep.torso)
        #expect(awake.groundedSolids == asleep.groundedSolids)
        #expect(groundLength(awake) >= apex(awake) * 2.5)
        // The sky-side shoulder squares up as it stirs.
        #expect(awake.shoulderUp.baseZ > asleep.shoulderUp.baseZ)
        // The hinge turns the face out over the open terrain corner.
        #expect(awake.nose.worldBounds.midX > asleep.nose.worldBounds.midX)
        // Breath alone still stirs the head.
        let breath = CityIsometricTitanGeometry(x: 0, y: 0, breath: 1)
        #expect(breath.head.baseZ > asleep.head.baseZ)
    }

    @Test("Every mass is drawn exactly once: retained base and live overlay never overlap")
    func massesPartitionCleanly() {
        let titan = CityIsometricTitanGeometry(x: 0, y: 0)
        let faceInlays = [titan.brow, titan.nose, titan.mouth, titan.eyeSlit, titan.eyeOpen, titan.pupil]

        for solid in titan.dynamicSolids {
            #expect(!titan.groundedSolids.contains(solid))
        }
        // The head assembly paints its own inlays; they are neither baked
        // nor queued as standalone posed masses.
        for inlay in faceInlays {
            #expect(!titan.groundedSolids.contains(inlay))
            #expect(!titan.dynamicSolids.contains(inlay))
        }
        #expect(titan.groundedSolids.count + titan.dynamicSolids.count + faceInlays.count == titan.allSolids.count)
    }

    @Test("Joint cores overlap both adjoining masses throughout wake and breathing")
    func connectedPoseSweep() {
        let resting = CityIsometricTitanGeometry(x: 0, y: 0)
        for wake: CGFloat in [0, 0.5, 1] {
            for breath: CGFloat in [0, 0.5, 1] {
                let pose = CityIsometricTitanGeometry(x: 0, y: 0, wake: wake, breath: breath)
                // A retained base must remain valid through the whole transition.
                #expect(pose.groundedSolids == resting.groundedSolids)
                let chains = [
                    (pose.hipCoreDown, pose.torso, pose.thighDown),
                    (pose.hipCoreUp, pose.torso, pose.thighUp),
                    (pose.kneeCoreDown, pose.thighDown, pose.shinDown),
                    (pose.kneeCoreUp, pose.thighUp, pose.shinUp),
                    (pose.ankleCoreDown, pose.shinDown, pose.footDown),
                    (pose.ankleCoreUp, pose.shinUp, pose.footUp),
                    (pose.elbowCoreDown, pose.upperArmDown, pose.forearmDown),
                    (pose.wristCoreDown, pose.forearmDown, pose.handDown),
                    (pose.elbowCoreUp, pose.upperArmUp, pose.forearmUp),
                    (pose.wristCoreUp, pose.forearmUp, pose.handUp),
                    (pose.shoulderCoreUp, pose.torso, pose.shoulderUp),
                ]
                for (core, first, second) in chains {
                    for segment in [first, second] {
                        let overlap = core.worldBounds.intersection(segment.worldBounds)
                        #expect(!overlap.isNull && overlap.width > 0.02 && overlap.height > 0.02)
                        let overlapZ = min(core.baseZ + core.height, segment.baseZ + segment.height)
                            - max(core.baseZ, segment.baseZ)
                        #expect(overlapZ > 0.02)
                    }
                }
            }
        }
    }

    @Test("Landmark stays inside its authored terrain envelope")
    func figureEnvelope() {
        let titan = CityIsometricTitanGeometry(x: 0, y: 0)

        // The landmark is province-readable: bounds scale with `modelScale`.
        // Keep a ceiling so a mass edit cannot silently sprawl past the
        // authored envelope, and a floor so it cannot shrink off the map.
        #expect(titan.worldFootprintBounds.width <= 26 * CityIsometricTitanGeometry.modelScale)
        #expect(titan.worldFootprintBounds.height <= 22 * CityIsometricTitanGeometry.modelScale)
        #expect(titan.worldFootprintBounds.width >= 12 * CityIsometricTitanGeometry.modelScale)
        #expect(titan.worldFootprintBounds.height >= 6 * CityIsometricTitanGeometry.modelScale)
    }

    @Test("Render bounds include contact patches and stroke padding")
    func completeRenderBounds() {
        let titan = CityIsometricTitanGeometry(x: 0, y: 0)

        #expect(titan.renderBounds.minX < titan.projectedBounds.minX)
        #expect(titan.renderBounds.minY < titan.projectedBounds.minY)
        #expect(titan.renderBounds.maxX > titan.projectedBounds.maxX)
        #expect(titan.renderBounds.maxY > titan.projectedBounds.maxY)
        #expect(titan.groundedSolids.flatMap(\.worldFootprint).allSatisfy {
            titan.renderBounds.contains(CityWorldPoint3D(x: $0.x, y: $0.y, z: 0.02).projected)
        })
        // The awake pose stays inside the bounds the base layer reserved
        // for the sleeping one, so a wake transition never clips.
        let awake = CityIsometricTitanGeometry(x: 0, y: 0, wake: 1, breath: 1)
        #expect(titan.renderBounds.union(awake.renderBounds).height <= titan.renderBounds.height * 1.25)
    }

    @Test("World facets and painter order are deterministic")
    func worldFacetsAndOrdering() {
        let first = CityIsometricTitanGeometry(x: 5, y: 10)
        let second = CityIsometricTitanGeometry(x: 5, y: 10)

        #expect(first == second)
        for index in 1..<first.allSolids.count {
            #expect(first.allSolids[index].sortKey >= first.allSolids[index - 1].sortKey)
        }
    }

    @Test("World offset translates every mass")
    func worldOffset() {
        let first = CityIsometricTitanGeometry(x: 0, y: 0)
        let second = CityIsometricTitanGeometry(x: 10, y: 20)

        for (left, right) in zip(first.allSolids, second.allSolids) {
            #expect(abs(right.worldOrigin.x - left.worldOrigin.x - 10) < 0.000_001)
            #expect(abs(right.worldOrigin.y - left.worldOrigin.y - 20) < 0.000_001)
            #expect(abs(right.width - left.width) < 0.000_001)
            #expect(abs(right.depth - left.depth) < 0.000_001)
            #expect(abs(right.baseZ - left.baseZ) < 0.000_001)
            #expect(abs(right.height - left.height) < 0.000_001)
        }
    }

    @Test("Gaze drift is bounded, deterministic, and still under Reduce Motion")
    func gazeDrift() {
        let a = CityTitanGaze.pupilOffset(seconds: 100, wake: 1, reduceMotion: false)
        #expect(a == CityTitanGaze.pupilOffset(seconds: 100, wake: 1, reduceMotion: false))
        for seconds in stride(from: 0.0, through: 120.0, by: 0.1) {
            let point = CityTitanGaze.pupilOffset(
                seconds: seconds,
                wake: 1,
                reduceMotion: false
            )
            #expect(abs(point.x) <= 1.1 + 0.001)
            #expect(abs(point.y) <= 0.45 + 0.001)
        }
        #expect(CityTitanGaze.pupilOffset(seconds: 100, wake: 1, reduceMotion: true) == .zero)
        #expect(CityTitanGaze.pupilOffset(seconds: 100, wake: 0, reduceMotion: false) == .zero)
        let moved = (0..<60).contains {
            CityTitanGaze.pupilOffset(
                seconds: Double($0),
                wake: 1,
                reduceMotion: false
            ) != a
        }
        #expect(moved)
    }
}
