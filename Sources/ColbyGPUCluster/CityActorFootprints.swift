import CoreGraphics

struct CityActorSolid: Equatable, Sendable {
    let center: CGPoint
    let vertices: [CGPoint]
    let lowerZ: CGFloat
    let upperZ: CGFloat
    /// Upper ring of a lofted solid, paired 1:1 with `vertices`. When set,
    /// the sides skew from the lower ring at `lowerZ` to this ring at
    /// `upperZ`, so a thigh can lean forward off the hip and a shin can
    /// slant back to the ankle instead of standing as a vertical column.
    /// `nil` extrudes `vertices` straight up.
    var upperVertices: [CGPoint]? = nil

    /// Every world vertex the painted solid occupies, both rings, so cull
    /// bounds cover lofted geometry and not just the ground ring.
    var allVertices: [CGPoint] { vertices + (upperVertices ?? []) }
}

/// Kaiju rig: a bipedal creature built from tapered solids. `arms` is ordered
/// far pair first (upper, forearm) then the near pair, so the renderer can
/// paint the far limb behind the body and the near limb in front of it.
struct CityKaijuFootprints: Equatable, Sendable {
    let feet: [CityActorSolid]
    let legs: [CityActorSolid]
    /// Joint socket rings, far side first, then the near side, each side
    /// ordered hip, knee, ankle, shoulder, elbow. Each ring is centered on
    /// the shared joint its two limb segments loft from, so the renderer can
    /// band every seam and the cull bounds can cover the socket meshes.
    let joints: [CityActorSolid]
    /// Hips and ribcage: the heavy low mass the tail and legs hang off.
    let torso: CityActorSolid
    /// Pale under-mass slung forward of the hips.
    let belly: CityActorSolid
    /// Ribcage rising and leaning forward out of the hips.
    let chest: CityActorSolid
    let neck: CityActorSolid
    let head: CityActorSolid
    /// Heavy ridge overhanging the eye, proud of the skull on both flanks.
    let brow: CityActorSolid
    let snout: CityActorSolid
    let jaw: CityActorSolid
    let arms: [CityActorSolid]
    let tail: [CityActorSolid]
}

struct CityUFOFootprints: Equatable, Sendable {
    let lowerHull: [CGPoint]
    let upperHull: [CGPoint]
    let cockpit: [CGPoint]
}

enum CityActorFootprints {
    /// Global vehicle scale: car length reads ≈ 2.9× a pedestrian's height
    /// (0.48wu) instead of ≈ 4.8×, so vehicles and people share one ruler.
    static let carScale: CGFloat = 0.62

    static func carBody(center: CGPoint, alongX: Bool) -> [CGPoint] {
        oriented(
            offsets: [
                CGPoint(x: -1.15 * carScale, y: -0.50 * carScale),
                CGPoint(x: 0.72 * carScale, y: -0.50 * carScale),
                CGPoint(x: 1.15 * carScale, y: -0.28 * carScale),
                CGPoint(x: 1.15 * carScale, y: 0.28 * carScale),
                CGPoint(x: 0.72 * carScale, y: 0.50 * carScale),
                CGPoint(x: -1.15 * carScale, y: 0.50 * carScale),
            ],
            center: center,
            alongX: alongX
        )
    }

    static func carCabin(center: CGPoint, alongX: Bool) -> [CGPoint] {
        oriented(
            offsets: [
                CGPoint(x: -0.55 * carScale, y: -0.34 * carScale),
                CGPoint(x: 0.30 * carScale, y: -0.34 * carScale),
                CGPoint(x: 0.50 * carScale, y: -0.18 * carScale),
                CGPoint(x: 0.50 * carScale, y: 0.18 * carScale),
                CGPoint(x: 0.30 * carScale, y: 0.34 * carScale),
                CGPoint(x: -0.55 * carScale, y: 0.34 * carScale),
            ],
            center: center,
            alongX: alongX
        )
    }

    static func carVisibleWheelCenters(center: CGPoint, alongX: Bool) -> [CGPoint] {
        if alongX {
            return [
                CGPoint(x: center.x - 0.72 * carScale, y: center.y + 0.49 * carScale),
                CGPoint(x: center.x + 0.68 * carScale, y: center.y + 0.49 * carScale),
            ]
        }
        return [
            CGPoint(x: center.x + 0.49 * carScale, y: center.y - 0.72 * carScale),
            CGPoint(x: center.x + 0.49 * carScale, y: center.y + 0.68 * carScale),
        ]
    }

    static func orientedRectangle(
        center: CGPoint,
        heading: CGVector,
        length: CGFloat,
        width: CGFloat
    ) -> [CGPoint] {
        taperedRectangle(
            center: center,
            heading: heading,
            length: length,
            backWidth: width,
            frontWidth: width
        )
    }

    /// Trapezoid footprint whose forward edge is narrower (or wider) than its
    /// back edge. Extruded, it reads as a tapering limb or muzzle instead of a
    /// brick; vertex order matches `orientedRectangle`.
    static func taperedRectangle(
        center: CGPoint,
        heading: CGVector,
        length: CGFloat,
        backWidth: CGFloat,
        frontWidth: CGFloat
    ) -> [CGPoint] {
        let magnitude = max(0.000_001, hypot(heading.dx, heading.dy))
        let forward = CGVector(dx: heading.dx / magnitude, dy: heading.dy / magnitude)
        let lateral = CGVector(dx: -forward.dy, dy: forward.dx)
        let halfLength = length / 2
        let halfBack = backWidth / 2
        let halfFront = frontWidth / 2
        func corner(_ along: CGFloat, _ across: CGFloat) -> CGPoint {
            CGPoint(
                x: center.x + forward.dx * along + lateral.dx * across,
                y: center.y + forward.dy * along + lateral.dy * across
            )
        }
        return [
            corner(-halfLength, -halfBack),
            corner(halfLength, -halfFront),
            corner(halfLength, halfFront),
            corner(-halfLength, halfBack),
        ]
    }

    /// Bipedal kaiju built from tapered masses in a weight-bearing theropod
    /// stance. Every limb is a kinematic chain over shared joints: each leg
    /// lofts hip -> knee -> ankle, each arm shoulder -> elbow -> wrist, and
    /// both segments of a chain derive their rings from the same joint
    /// coordinates, so nothing can drift apart or bob independently. Broad
    /// haunches fold through bent knees into slanted shins and narrow ankles
    /// over planted three-toed feet; the hips rock over the stance foot with
    /// the walk; a hip mass flows level into a deep ribcage; short folded
    /// arms counter-swing the legs; a heavy brow sits over a tapering muzzle;
    /// and a tail thins continuously from a thick hip-high base to a
    /// ground-dragging tip.
    ///
    /// `stride` is the foot's fore-aft half-excursion. `kaijuPose` sets it to
    /// the patrol speed times a quarter walk period, which makes the stance
    /// foot's linear backtrack cancel the body's advance exactly, so planted
    /// feet do not slide against the ground. `sway` is the lateral carriage
    /// roll; the rig subtracts it from the feet so they keep the patrol lane.
    static func kaiju(
        center: CGPoint,
        heading: CGFloat,
        bob: CGFloat,
        step: CGFloat = 0.31,
        tailPhase: CGFloat = 1.1,
        jawDrop: CGFloat = 0,
        headRear: CGFloat = 0,
        liveliness: CGFloat = 1,
        stride: CGFloat = 0.2,
        sway: CGFloat = 0
    ) -> CityKaijuFootprints {
        let direction = heading >= 0 ? CGFloat(1) : -1
        let forward = CGVector(dx: direction, dy: 0)
        // Walk-cycle channels; `CityWhimsy.KaijuPose` mirrors the foot-lift
        // formula so pose consumers agree with the rig, and the renderer's
        // toes ride `foot.lowerZ` so lifted feet carry their toes with them.
        let walkClock = step * .pi * 2
        let liftFar = max(0, sin(walkClock)) * 0.85 * liveliness
        let liftNear = max(0, sin(walkClock + .pi)) * 0.85 * liveliness
        let armSwing = sin(walkClock) * 0.4 * liveliness
        let headSway = sin(walkClock + 0.7) * 0.18 * liveliness
        // Fore-aft foot travel. Swing (the half cycle where this leg's lift
        // clock is positive) glides the foot cosinely from a half-stride
        // behind its station to the same distance ahead; stance tracks it
        // straight back at 4x stride per cycle phase, which equals the body's
        // ground speed when stride == travelRate * walkPeriod / 4.
        func footTravel(_ clock: CGFloat) -> CGFloat {
            let cycles = clock / (.pi * 2)
            let localPhase = cycles - floor(cycles)
            return localPhase < 0.5 ? -stride * cos(clock) : stride * (3 - 4 * localPhase)
        }

        func solid(
            _ x: CGFloat,
            _ y: CGFloat,
            length: CGFloat,
            width: CGFloat,
            frontWidth: CGFloat? = nil,
            lowerZ: CGFloat,
            upperZ: CGFloat,
            extraLift: CGFloat = 0,
            upperBonus: CGFloat = 0,
            yOffset: CGFloat = 0
        ) -> CityActorSolid {
            let partCenter = CGPoint(x: center.x + x * direction, y: center.y + y + yOffset)
            return CityActorSolid(
                center: partCenter,
                vertices: taperedRectangle(
                    center: partCenter,
                    heading: forward,
                    length: length,
                    backWidth: width,
                    frontWidth: frontWidth ?? width
                ),
                lowerZ: lowerZ + extraLift,
                upperZ: upperZ + bob + extraLift + upperBonus
            )
        }

        /// Lofted segment between two joints of a chain: the base ring sits
        /// under `base` at its own height and the crown ring under `crown`,
        /// so the painted solid leans from joint to joint. Both rings of both
        /// segments around a joint are built from the same joint coordinates,
        /// so the chain cannot gap or drift. Each ring is a tapered
        /// rectangle, so a thigh can be broad at the hip and pinch at the
        /// knee while the whole slab slants forward.
        func segment(
            base: (x: CGFloat, y: CGFloat, z: CGFloat, length: CGFloat, back: CGFloat, front: CGFloat),
            crown: (x: CGFloat, y: CGFloat, z: CGFloat, length: CGFloat, back: CGFloat, front: CGFloat)
        ) -> CityActorSolid {
            func ring(
                _ x: CGFloat, _ y: CGFloat, _ length: CGFloat, _ back: CGFloat, _ front: CGFloat
            ) -> (center: CGPoint, vertices: [CGPoint]) {
                let jointCenter = CGPoint(x: center.x + x * direction, y: center.y + y)
                return (
                    jointCenter,
                    taperedRectangle(
                        center: jointCenter, heading: forward,
                        length: length, backWidth: back, frontWidth: front
                    )
                )
            }
            let baseRing = ring(base.x, base.y, base.length, base.back, base.front)
            let crownRing = ring(crown.x, crown.y, crown.length, crown.back, crown.front)
            return CityActorSolid(
                center: CGPoint(
                    x: (baseRing.center.x + crownRing.center.x) / 2,
                    y: (baseRing.center.y + crownRing.center.y) / 2
                ),
                vertices: baseRing.vertices,
                lowerZ: base.z,
                upperZ: max(base.z, crown.z),
                upperVertices: crownRing.vertices
            )
        }

        /// Socket ring wrapped around a joint: a short vertical solid
        /// centered on the shared joint coordinate, so it pokes out of both
        /// adjoining segment rings as a visible hinge. Joints never dip
        /// below the ground plane.
        func socket(
            _ at: (x: CGFloat, y: CGFloat, z: CGFloat),
            halfHeight: CGFloat,
            length: CGFloat,
            back: CGFloat,
            front: CGFloat
        ) -> CityActorSolid {
            let ringCenter = CGPoint(x: center.x + at.x * direction, y: center.y + at.y)
            return CityActorSolid(
                center: ringCenter,
                vertices: taperedRectangle(
                    center: ringCenter, heading: forward,
                    length: length, backWidth: back, frontWidth: front
                ),
                lowerZ: max(0, at.z - halfHeight),
                upperZ: at.z + halfHeight
            )
        }

        // Planted three-toed feet: a narrow heel swelling into a broad toe
        // fan the renderer splits into three separated prongs, and set wide
        // apart across the body so the stance reads weight-bearing on two
        // separated feet instead of tiptoe on a single pedestal. A planted
        // foot is fully static (no bob, no drift): its lift rides only its
        // own swing, and `sway` is subtracted so it keeps the patrol lane.
        func footSolid(
            station: CGFloat,
            lane: CGFloat,
            clock: CGFloat,
            lift: CGFloat
        ) -> CityActorSolid {
            let footCenter = CGPoint(
                x: center.x + (station + footTravel(clock)) * direction,
                y: center.y + lane - sway
            )
            return CityActorSolid(
                center: footCenter,
                vertices: taperedRectangle(
                    center: footCenter, heading: forward,
                    length: 3.0, backWidth: 1.15, frontWidth: 2.30
                ),
                lowerZ: lift,
                upperZ: 1.05 + lift
            )
        }
        let feet = [
            footSolid(station: 0.45, lane: -1.55, clock: walkClock, lift: liftFar),
            footSolid(station: 1.55, lane: 1.50, clock: walkClock + .pi, lift: liftNear),
        ]
        // Weight-bearing leg chain per side, derived from three shared
        // joints — hip, knee, ankle — so thigh and shin always meet exactly
        // at the knee and the shin always meets its foot at the ankle. The
        // chain is a Z and never a column: a broad haunch buried in the hips
        // leans forward and down into a pinched knee well in front of the
        // pelvis, then the shin slants back down from that knee to a narrow
        // ankle planted over the heel. The stance hip sinks under load while
        // the swing hip rises, rocking the carriage over the planted foot,
        // and the knee rides halfway up the chain so the bob compresses the
        // leg instead of sliding it. Knees splay outward, standing wider
        // than the hips. Order: far thigh, far shin, then the near side.
        func legChain(
            footStation: CGFloat,
            footLane: CGFloat,
            hipLane: CGFloat,
            clock: CGFloat,
            lift: CGFloat,
            counterLift: CGFloat
        ) -> (thigh: CityActorSolid, shin: CityActorSolid, hip: CityActorSolid, knee: CityActorSolid, ankle: CityActorSolid) {
            let laneSign: CGFloat = hipLane < 0 ? -1 : 1
            let hip = (
                x: CGFloat(-0.55),
                y: hipLane,
                z: 11.4 + bob * 0.55 + lift * 0.25 - counterLift * 0.30
            )
            let ankle = (
                x: footStation + footTravel(clock) - 0.55,
                y: footLane - sway,
                z: 1.30 + lift
            )
            let knee = (
                x: (hip.x + ankle.x) / 2 + 1.50,
                y: (hip.y + ankle.y) / 2 + laneSign * 0.35,
                z: (hip.z + ankle.z) / 2 + 0.45
            )
            return (
                thigh: segment(
                    base: (knee.x, knee.y, knee.z, 1.70, 2.05, 1.70),
                    crown: (hip.x, hip.y, hip.z, 2.40, 3.20, 2.40)
                ),
                shin: segment(
                    base: (ankle.x, ankle.y, ankle.z, 1.15, 1.35, 1.15),
                    crown: (knee.x, knee.y, knee.z, 1.55, 1.85, 1.60)
                ),
                hip: socket(hip, halfHeight: 0.45, length: 1.90, back: 2.20, front: 1.90),
                knee: socket(knee, halfHeight: 0.50, length: 1.85, back: 2.20, front: 1.90),
                ankle: socket(ankle, halfHeight: 0.42, length: 1.20, back: 1.45, front: 1.25)
            )
        }
        let farLeg = legChain(
            footStation: 0.45, footLane: -1.55, hipLane: -0.95,
            clock: walkClock, lift: liftFar, counterLift: liftNear
        )
        let nearLeg = legChain(
            footStation: 1.55, footLane: 1.50, hipLane: 0.95,
            clock: walkClock + .pi, lift: liftNear, counterLift: liftFar
        )
        let legs = [farLeg.thigh, farLeg.shin, nearLeg.thigh, nearLeg.shin]
        // The carriage rocks toward the planted side in step with the hips.
        let stanceShift = liftFar - liftNear
        // Hips: heavy, widest at the haunches, narrowing forward into the
        // chest so the whole animal leans over its toes.
        let torso = solid(
            -0.20, 0,
            length: 5.0, width: 3.60, frontWidth: 3.00,
            lowerZ: 8.6, upperZ: 14.2,
            yOffset: stanceShift * 0.22
        )
        // Belly slung low and forward of the hips; drawn pale so the
        // underside separates from the back.
        let belly = solid(
            1.00, 0.25,
            length: 3.9, width: 2.80, frontWidth: 2.20,
            lowerZ: 8.0, upperZ: 12.6,
            yOffset: stanceShift * 0.18
        )
        // Ribcage: deep and pitched forward but level with the hips — the
        // horizontal carriage of a weight-bearing animal, not a rearing
        // tower. Narrower than the hips.
        let chest = solid(
            1.70, -0.05,
            length: 3.6, width: 3.30, frontWidth: 2.70,
            lowerZ: 11.0, upperZ: 15.2,
            yOffset: stanceShift * 0.12
        )
        let neck = solid(
            3.10, -0.05,
            length: 2.0, width: 2.25, frontWidth: 1.85,
            lowerZ: 14.6, upperZ: 17.4,
            extraLift: headRear * 0.6,
            yOffset: headSway
        )
        let head = solid(
            4.50, -0.15,
            length: 3.4, width: 2.90, frontWidth: 2.35,
            lowerZ: 15.8, upperZ: 19.4,
            extraLift: headRear,
            yOffset: headSway
        )
        // Brow: proud of the skull on both flanks and overhanging the eye.
        let brow = solid(
            4.85, -0.12,
            length: 2.5, width: 3.35, frontWidth: 2.75,
            lowerZ: 18.5, upperZ: 19.6,
            extraLift: headRear,
            yOffset: headSway
        )
        // Muzzle: long, tapering to a blunt nose.
        let snout = solid(
            6.60, 0.10,
            length: 2.8, width: 2.30, frontWidth: 1.65,
            lowerZ: 16.2, upperZ: 17.9,
            extraLift: headRear,
            yOffset: headSway
        )
        let jaw = solid(
            6.30, 0.10,
            length: 2.5, width: 2.00, frontWidth: 1.40,
            lowerZ: 15.0, upperZ: 16.05,
            extraLift: headRear - jawDrop,
            upperBonus: jawDrop * 0.3,
            yOffset: headSway
        )
        // Short folded arms as a second chain over shared joints: a socket
        // cap set into the chest flank, an upper arm dropping to the elbow,
        // and a forearm angling forward and down to the wrist. Each arm
        // counter-swings its same-side leg — shoulder fixed, elbow swinging
        // back and down while that side's leg steps forward. Far pair first.
        func armChain(
            shoulderLane: CGFloat,
            sideSwing: CGFloat
        ) -> (upper: CityActorSolid, forearm: CityActorSolid, shoulder: CityActorSolid, elbow: CityActorSolid) {
            let laneSign: CGFloat = shoulderLane < 0 ? -1 : 1
            let shoulder = (x: CGFloat(2.00), y: shoulderLane, z: 14.8 + bob * 0.75)
            let elbow = (
                x: shoulder.x + 0.95 + sideSwing * 0.35,
                y: shoulderLane + laneSign * 0.18,
                z: 12.55 + bob * 0.75 + sideSwing * 0.55
            )
            let wrist = (
                x: elbow.x + 1.05,
                y: elbow.y + laneSign * 0.06,
                z: elbow.z - 1.55
            )
            return (
                upper: segment(
                    base: (elbow.x, elbow.y, elbow.z, 1.10, 1.05, 0.85),
                    crown: (shoulder.x, shoulder.y, shoulder.z, 1.40, 1.35, 1.05)
                ),
                forearm: segment(
                    base: (wrist.x, wrist.y, wrist.z, 0.95, 0.80, 0.65),
                    crown: (elbow.x, elbow.y, elbow.z, 1.15, 1.00, 0.80)
                ),
                shoulder: socket(shoulder, halfHeight: 0.48, length: 1.50, back: 1.50, front: 1.25),
                elbow: socket(elbow, halfHeight: 0.38, length: 1.10, back: 1.15, front: 0.95)
            )
        }
        let farArm = armChain(shoulderLane: -2.05, sideSwing: -armSwing)
        let nearArm = armChain(shoulderLane: 2.00, sideSwing: armSwing)
        let arms = [farArm.upper, farArm.forearm, nearArm.upper, nearArm.forearm]
        // Joint hardware, far side first: hip, knee, ankle, shoulder, elbow,
        // then the near side in the same order.
        let joints = [
            farLeg.hip, farLeg.knee, farLeg.ankle, farArm.shoulder, farArm.elbow,
            nearLeg.hip, nearLeg.knee, nearLeg.ankle, nearArm.shoulder, nearArm.elbow,
        ]

        // Tail: six long overlapping segments whose widths and heights step
        // down continuously, each one lofted from its broad ground ring up
        // to a shorter, narrower crown pulled back toward the rump. The
        // crown offset chamfers the tip-facing top edge of every segment,
        // so the sweep reads as one tapering cone off the hips — thick
        // where it leaves the rump, ground-dragging at the tip — instead
        // of a row of barrels. The rest y-lane curves smoothly and each
        // segment lags the wag clock, swinging wider toward the tip but
        // never far enough for a neighbour pair to part and expose a gap
        // in the sweep.
        let tail: [(x: CGFloat, y: CGFloat, length: CGFloat, width: CGFloat, front: CGFloat, lowerZ: CGFloat, upperZ: CGFloat)] = [
            (-4.4, 0.30, 4.6, 2.85, 2.45, 6.4, 12.9),
            (-7.3, 0.48, 4.2, 2.35, 1.95, 4.9, 10.4),
            (-10.0, 0.60, 3.8, 1.80, 1.45, 3.3, 7.8),
            (-12.4, 0.58, 3.4, 1.35, 1.00, 1.9, 5.3),
            (-14.9, 0.42, 3.0, 0.95, 0.65, 0.7, 2.9),
            (-17.0, 0.18, 2.6, 0.60, 0.38, 0.0, 1.3),
        ]
        let tailSolids = tail.enumerated().map { index, spec in
            let sway = sin(tailPhase - CGFloat(index) * 0.5) * (0.18 + 0.10 * CGFloat(index)) * liveliness
            let crownShift = spec.length * 0.22
            return segment(
                base: (
                    spec.x, spec.y + sway, spec.lowerZ,
                    spec.length, spec.width, spec.front
                ),
                crown: (
                    spec.x + crownShift, spec.y + sway, spec.upperZ + bob,
                    spec.length * 0.74, spec.width * 0.72, spec.front * 0.66
                )
            )
        }
        return CityKaijuFootprints(
            feet: feet,
            legs: legs,
            joints: joints,
            torso: torso,
            belly: belly,
            chest: chest,
            neck: neck,
            head: head,
            brow: brow,
            snout: snout,
            jaw: jaw,
            arms: arms,
            tail: tailSolids
        )
    }

    static func ufo(center: CGPoint, diameter: CGFloat) -> CityUFOFootprints {
        let half = diameter / 2
        let corner = diameter / 8
        let lowerHull = [
            CGPoint(x: center.x - half, y: center.y - corner),
            CGPoint(x: center.x - corner, y: center.y - half),
            CGPoint(x: center.x + corner, y: center.y - half),
            CGPoint(x: center.x + half, y: center.y - corner),
            CGPoint(x: center.x + half, y: center.y + corner),
            CGPoint(x: center.x + corner, y: center.y + half),
            CGPoint(x: center.x - corner, y: center.y + half),
            CGPoint(x: center.x - half, y: center.y + corner),
        ]
        func scaled(_ scale: CGFloat) -> [CGPoint] {
            lowerHull.map { point in
                CGPoint(
                    x: center.x + (point.x - center.x) * scale,
                    y: center.y + (point.y - center.y) * scale
                )
            }
        }
        return CityUFOFootprints(
            lowerHull: lowerHull,
            upperHull: scaled(0.72),
            cockpit: scaled(0.32)
        )
    }

    private static func oriented(
        offsets: [CGPoint],
        center: CGPoint,
        alongX: Bool
    ) -> [CGPoint] {
        offsets.map { offset in
            if alongX {
                return CGPoint(x: center.x + offset.x, y: center.y + offset.y)
            }
            return CGPoint(x: center.x - offset.y, y: center.y + offset.x)
        }
    }
}
