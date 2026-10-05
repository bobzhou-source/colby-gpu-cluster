import CoreGraphics
import SwiftUI

/// Extruded world-space solid with light-sensitive facets.
///
/// `domeInset`/`domePeak` turn the flat prism into a worn boulder: the side
/// ring slopes inward to a shrunken shoulder ring at full height, and a
/// triangular fan rises from the shoulder ring to a peaked cap centroid.
/// Zero values reproduce the original flat-top extrusion.
struct CityTitanSolid: Equatable, Sendable {
    let worldFootprint: [CGPoint]
    let baseZ: CGFloat
    let height: CGFloat
    var domeInset: CGFloat = 0
    var domePeak: CGFloat = 0
    /// A clipped flat crown instead of the optional boulder apex.
    var capInset: CGFloat? = nil

    var worldOrigin: (x: CGFloat, y: CGFloat) {
        (worldBounds.minX, worldBounds.minY)
    }

    var width: CGFloat { worldBounds.width }
    var depth: CGFloat { worldBounds.height }

    var worldBounds: CGRect {
        guard
            let minX = worldFootprint.map(\.x).min(),
            let maxX = worldFootprint.map(\.x).max(),
            let minY = worldFootprint.map(\.y).min(),
            let maxY = worldFootprint.map(\.y).max()
        else {
            return .zero
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    var facets: [CityProjectedFacet] {
        guard worldFootprint.count >= 3 else { return [] }
        let z0 = baseZ
        let z1 = baseZ + height
        let centerX = worldBounds.midX
        let centerY = worldBounds.midY

        let domed = domeInset > 0
        // Shoulder ring: footprint pulled toward the centroid at full height.
        let shoulder = worldFootprint.map { point in
            CGPoint(
                x: point.x + (centerX - point.x) * domeInset,
                y: point.y + (centerY - point.y) * domeInset
            )
        }
        let topRing = domed ? shoulder : worldFootprint

        var sides = worldFootprint.indices.map { index in
            let start = worldFootprint[index]
            let end = worldFootprint[(index + 1) % worldFootprint.count]
            let topStart = topRing[index]
            let topEnd = topRing[(index + 1) % topRing.count]
            let edgeX = (start.x + end.x) / 2
            let edgeY = (start.y + end.y) / 2
            let light: CityFacetLight = edgeX - centerX >= edgeY - centerY ? .right : .left
            return CityProjectedFacet(
                worldPoints: [
                    CityWorldPoint3D(x: start.x, y: start.y, z: z0),
                    CityWorldPoint3D(x: end.x, y: end.y, z: z0),
                    CityWorldPoint3D(x: topEnd.x, y: topEnd.y, z: z1),
                    CityWorldPoint3D(x: topStart.x, y: topStart.y, z: z1),
                ],
                panel: index + 1,
                light: light
            )
        }
        sides.sort {
            $0.worldPoints.map { $0.x + $0.y }.reduce(0, +) <
                $1.worldPoints.map { $0.x + $0.y }.reduce(0, +)
        }
        if domed, let capInset {
            guard capInset > 0 || domePeak > 0 else {
                // Single-tier carved crown: the tapered sides meet one flat
                // top, with no second bevel ring stacked on the shoulder
                // ring. Limbs, joints, and extremities use this so the
                // figure reads as carved stone instead of stair-stepped
                // slabs.
                sides.append(CityProjectedFacet(
                    worldPoints: topRing.map {
                        CityWorldPoint3D(x: $0.x, y: $0.y, z: z1)
                    },
                    panel: 0,
                    light: .top
                ))
                return sides
            }
            let crown = topRing.map {
                CityWorldPoint3D(
                    x: $0.x + (centerX - $0.x) * capInset,
                    y: $0.y + (centerY - $0.y) * capInset,
                    z: z1 + domePeak
                )
            }
            for index in topRing.indices {
                let next = (index + 1) % topRing.count
                sides.append(CityProjectedFacet(
                    worldPoints: [
                        CityWorldPoint3D(x: topRing[index].x, y: topRing[index].y, z: z1),
                        CityWorldPoint3D(x: topRing[next].x, y: topRing[next].y, z: z1),
                        crown[next], crown[index],
                    ],
                    panel: index + 1,
                    light: .top
                ))
            }
            sides.append(CityProjectedFacet(worldPoints: crown, panel: 0, light: .top))
        } else if domed {
            // Boulder cap: triangular fan from the shoulder ring to a peaked
            // centroid. Each facet takes directional light off its outer
            // edge so the dome reads as a curved surface, not a flat lid.
            let apex = CityWorldPoint3D(x: centerX, y: centerY, z: z1 + domePeak)
            let fan = topRing.indices.map { index in
                let start = topRing[index]
                let end = topRing[(index + 1) % topRing.count]
                let edgeX = (start.x + end.x) / 2
                let edgeY = (start.y + end.y) / 2
                let light: CityFacetLight = edgeX - centerX >= edgeY - centerY ? .right : .left
                return CityProjectedFacet(
                    worldPoints: [
                        CityWorldPoint3D(x: start.x, y: start.y, z: z1),
                        CityWorldPoint3D(x: end.x, y: end.y, z: z1),
                        apex,
                    ],
                    panel: 0,
                    light: light
                )
            }
            sides.append(contentsOf: fan)
        } else {
            sides.append(CityProjectedFacet(
                worldPoints: worldFootprint.map {
                    CityWorldPoint3D(x: $0.x, y: $0.y, z: z1)
                },
                panel: 0,
                light: .top
            ))
        }
        return sides
    }

    var sortKey: CGFloat {
        worldBounds.midX + worldBounds.midY
    }
}

/// Side-lying stone-golem landmark: a heavy humanoid figure sprawled
/// asleep on its side at the terrain corner. The whole body runs along
/// the ground: the long axis is world +x, so the figure reads as a
/// reclining landform rather than an upright stack of slabs. Because it
/// lies on its side, the shoulder-to-shoulder axis is vertical — every
/// limb pairs into a ground-side (`…Down`) half crushed against the
/// terrain and a sky-side (`…Up`) half draped over it.
///
/// The anatomy is carved from a few substantial volumes, not successive
/// shallow plates:
///
/// - `torso` is one contiguous mass from hips to shoulders (8.3 x 4.8 x
///   4.2 model units) with a domed stone back. There is no separate
///   pelvis block and no waist seam to stack.
/// - The legs fold forward: thigh out of the hip, shin bent toward the
///   camera side, toed foot at the end. The sky-side leg rides on top of
///   the ground-side leg and sits a little further forward, so the pair
///   reads as two legs at rest instead of one wide slab.
/// - The ground-side arm is trapped under the body and runs forward
///   along the terrain: it is the pillow. `forearmDown` lies flat under
///   the head's front band — the edges the camera can actually see — and
///   `handDown` curls past the crown.
/// - The sky-side arm drapes down the chest front, bends at the elbow,
///   and its forearm and hand rest on the ground ahead of the belly.
///
/// The head lies on its cheek. Its crown points along +x and its chin
/// toward the shoulders, so the face is rotated a quarter turn: the brow
/// slab sits nearest the crown, the recessed eye strip runs vertically
/// (along world z, i.e. the golem's ear-to-ear axis), the nose bridge
/// crosses that strip at mid height and runs down toward the chin, and
/// the mouth seam is carved just short of the chin. The two eye sockets
/// therefore stack vertically on screen, which is what makes a sleeping
/// face read as sideways rather than upright.
///
/// Every limb, joint, and extremity carries a single carved crown
/// (`capInset: 0`) rather than a stacked pair of bevel rings; the torso
/// and skull use a peaked fan (`capInset: nil`) so their big surfaces
/// dome instead of terracing. Joint cores stay recessed under the
/// crowns they join and overlap both adjoining masses in footprint and
/// height across every pose.
///
/// Sleep is the authored rest pose: head down on the supporting forearm,
/// eye sealed. `wake` (0..1) raises the head clear of the arm, stretches
/// the neck to follow it, squares the sky-side shoulder up, and yaws the
/// face out toward the camera; `breath` (0..1) swells the sky-side
/// shoulder and bobs the head, which is the only movement a body lying
/// on its side actually shows. Both default to 0, which reproduces the
/// authored sleeping pose. The golem stays down when it wakes: it lifts
/// its head, it does not sit up, so no baked mass is ever left behind in
/// the sleeping pose while the rest of the body moves.
struct CityIsometricTitanGeometry: Equatable, Sendable {
    let baseX: CGFloat
    let baseY: CGFloat
    let wake: CGFloat
    let breath: CGFloat
    /// Shared scale factor for every solid; `CityRenderer` reads it to keep
    /// the terrain-corner anchor proportional as the model grows. Sized so
    /// the reclining figure reads as a slumbering landform at province
    /// zoom, not a rock.
    static let modelScale: CGFloat = 2.4

    init(x: CGFloat, y: CGFloat, wake: CGFloat = 0, breath: CGFloat = 0) {
        baseX = x
        baseY = y
        self.wake = min(1, max(0, wake))
        self.breath = min(1, max(0, breath))
    }

    // MARK: - Articulation (wake/breath driven, zero at rest)

    /// The sky-side shoulder is the one mass a side-lying body visibly
    /// moves as it breathes; it also squares up as the golem stirs.
    /// Bounded (≤ 0.76 model units) so the silhouette never breaks the
    /// authored envelope.
    var shoulderRise: CGFloat { 0.26 * breath + 0.50 * wake }

    /// The head rises off the forearm it sleeps on. The neck grows to
    /// follow it, so head, neck, and torso stay one connected mass
    /// instead of the skull floating away. Bounded ≤ 1.6 model units.
    var headLift: CGFloat { 1.50 * wake + 0.10 * breath }

    // MARK: - Neck hinge

    /// The head yaws about the neck as it lifts, turning the face out of
    /// its sideways rest and toward the camera instead of rising like an
    /// elevator cab. Negative angle: swings the face east, into the open
    /// terrain corner.
    private var hingeAngle: CGFloat { -0.22 * wake }
    private var hingePivot: (x: CGFloat, y: CGFloat) { (14.6, 14.7) }

    private func hingeRotate(_ x: CGFloat, _ y: CGFloat) -> (x: CGFloat, y: CGFloat) {
        let pivot = hingePivot
        let dx = x - pivot.x
        let dy = y - pivot.y
        let angle = hingeAngle
        let cosine = cos(angle)
        let sine = sin(angle)
        return (
            pivot.x + dx * cosine - dy * sine,
            pivot.y + dx * sine + dy * cosine
        )
    }

    // MARK: - Body

    /// The single dominant mass: hips through shoulders, laid along the
    /// ground on its side. Its footprint narrows at the hip end and
    /// broadens across the chest, and the crown domes into a stone back,
    /// so the trunk reads as one carved boulder-bodied torso instead of a
    /// pelvis slab with a chest slab stacked on it.
    var torso: CityTitanSolid {
        solid(
            points: [
                (6.0, 12.5), (7.7, 11.85), (12.3, 11.6), (14.3, 12.45),
                (14.3, 15.75), (12.3, 16.4), (7.7, 16.3), (6.0, 15.55),
            ],
            baseZ: 0,
            height: 4.2,
            domeInset: 0.18,
            domePeak: 0.75,
            capInset: nil
        )
    }

    // MARK: - Legs (folded forward, sky-side leg resting on ground-side)

    /// Ground-side thigh: runs out of the hip toward the feet, tapering
    /// from the wide hip to the knee.
    var thighDown: CityTitanSolid {
        solid(
            points: [(3.0, 13.4), (6.4, 12.8), (6.9, 15.9), (3.3, 15.6)],
            baseZ: 0,
            height: 2.1,
            domeInset: 0.16,
            capInset: 0
        )
    }

    /// Ground-side shin: bends at the knee toward the camera side, so the
    /// leg folds in front of the body the way a sleeper's does.
    var shinDown: CityTitanSolid {
        solid(
            points: [(2.6, 15.2), (4.9, 15.6), (4.6, 18.7), (2.5, 18.3)],
            baseZ: 0,
            height: 1.8,
            domeInset: 0.14,
            capInset: 0
        )
    }

    /// Ground-side foot: a heel matching the ankle and three squared toes
    /// combed into the leading edge.
    var footDown: CityTitanSolid {
        solid(
            points: [
                (2.4, 18.2), (4.6, 18.5), (4.6, 20.3), (4.05, 20.3),
                (4.05, 19.85), (3.75, 19.85), (3.75, 20.3), (3.25, 20.3),
                (3.25, 19.85), (2.95, 19.85), (2.95, 20.3), (2.4, 20.3),
            ],
            baseZ: 0,
            height: 1.05,
            domeInset: 0.10,
            capInset: 0
        )
    }

    /// Sky-side thigh: the upper leg rests on its twin and lies a little
    /// further forward, so the pair reads as two legs at rest.
    var thighUp: CityTitanSolid {
        solid(
            points: [(3.4, 14.4), (6.8, 13.8), (7.2, 16.9), (3.7, 17.0)],
            baseZ: 1.85,
            height: 2.0,
            domeInset: 0.16,
            capInset: 0
        )
    }

    /// Sky-side shin, folded forward over the ground-side shin.
    var shinUp: CityTitanSolid {
        solid(
            points: [(3.0, 16.5), (5.3, 16.9), (5.0, 20.0), (2.9, 19.6)],
            baseZ: 1.6,
            height: 1.7,
            domeInset: 0.14,
            capInset: 0
        )
    }

    /// Sky-side foot, toes combed like its twin, resting across it.
    var footUp: CityTitanSolid {
        solid(
            points: [
                (2.8, 19.4), (5.0, 19.7), (5.0, 21.5), (4.45, 21.5),
                (4.45, 21.05), (4.15, 21.05), (4.15, 21.5), (3.65, 21.5),
                (3.65, 21.05), (3.35, 21.05), (3.35, 21.5), (2.8, 21.5),
            ],
            baseZ: 1.15,
            height: 1.05,
            domeInset: 0.10,
            capInset: 0
        )
    }

    // MARK: - Ground-side arm (the pillow)

    /// Ground-side upper arm: trapped under the chest and running forward
    /// along the terrain toward the head.
    var upperArmDown: CityTitanSolid {
        solid(
            points: [(12.6, 14.0), (15.4, 14.3), (15.3, 16.6), (12.6, 16.4)],
            baseZ: 0,
            height: 1.35,
            domeInset: 0.16,
            capInset: 0
        )
    }

    /// Ground-side forearm: the pillow. It lies flat under the head's
    /// front band — the bottom edges the camera can actually see — so the
    /// skull rests on stone instead of hovering over the terrain.
    var forearmDown: CityTitanSolid {
        solid(
            points: [(15.1, 14.35), (18.2, 14.7), (18.1, 16.6), (15.1, 16.4)],
            baseZ: 0,
            height: 0.95,
            domeInset: 0.14,
            capInset: 0
        )
    }

    /// Ground-side hand: curled past the crown, fingers combed into the
    /// leading edge. Kept behind the face plane so the head always draws
    /// clear of it.
    var handDown: CityTitanSolid {
        solid(
            points: [
                (18.0, 14.3), (19.55, 14.6), (19.55, 15.05), (19.1, 15.05),
                (19.1, 15.35), (19.55, 15.35), (19.55, 15.8), (19.1, 15.8),
                (19.1, 16.1), (19.55, 16.1), (19.55, 16.35), (18.0, 16.15),
            ],
            baseZ: 0,
            height: 0.9,
            domeInset: 0.08,
            capInset: 0
        )
    }

    // MARK: - Sky-side arm (draped)

    /// Sky-side shoulder: the deltoid block crowning the chest end of the
    /// torso. It carries the breath swell and squares up on wake.
    var shoulderUp: CityTitanSolid {
        solid(
            points: [
                (11.7, 12.9), (13.4, 12.6), (14.4, 13.4), (14.4, 15.2),
                (13.4, 15.9), (11.7, 15.7), (11.3, 14.9), (11.3, 13.6),
            ],
            baseZ: 3.3 + shoulderRise,
            height: 1.6,
            domeInset: 0.24,
            capInset: 0
        )
    }

    /// Sky-side upper arm: drapes down the chest front from the shoulder
    /// to the elbow, riding a share of the shoulder's rise.
    var upperArmUp: CityTitanSolid {
        solid(
            points: [(11.5, 15.2), (13.9, 15.0), (13.7, 17.6), (11.4, 17.5)],
            baseZ: 1.9 + 0.55 * shoulderRise,
            height: 2.1,
            domeInset: 0.16,
            capInset: 0
        )
    }

    /// Sky-side forearm: bends off the elbow and lies along the ground
    /// ahead of the belly. Planted: the elbow absorbs the shoulder's rise.
    var forearmUp: CityTitanSolid {
        solid(
            points: [(8.6, 17.2), (11.9, 17.05), (12.0, 18.6), (8.7, 18.5)],
            baseZ: 0,
            height: 1.5,
            domeInset: 0.14,
            capInset: 0
        )
    }

    /// Sky-side hand: a blocky palm with combed fingers, resting on the
    /// ground in front of the hip.
    var handUp: CityTitanSolid {
        solid(
            points: [
                (8.8, 17.3), (8.85, 18.8), (6.6, 18.7), (6.6, 18.35),
                (7.0, 18.35), (7.0, 18.15), (6.6, 18.15), (6.6, 17.85),
                (7.0, 17.85), (7.0, 17.65), (6.6, 17.65), (6.6, 17.3),
            ],
            baseZ: 0,
            height: 1.0,
            domeInset: 0.08,
            capInset: 0
        )
    }

    // MARK: - Joint cores

    /// Darker stone joint cores where two masses meet. Each core is
    /// recessed: its footprint sits inside both adjoining segments and its
    /// crown stays below the higher neighbour's crown, so the joint reads
    /// as a shadowed socket sunk into the limb instead of an extra square
    /// plate stacked on top of it. Every core overlaps both adjoining
    /// segments in footprint and height across every pose.

    var hipCoreDown: CityTitanSolid {
        solid(
            points: [(5.7, 13.3), (7.0, 13.1), (7.1, 15.6), (5.8, 15.7)],
            baseZ: 0.35,
            height: 1.5,
            domeInset: 0.14,
            capInset: 0
        )
    }

    var hipCoreUp: CityTitanSolid {
        solid(
            points: [(6.1, 14.4), (7.4, 14.2), (7.5, 16.4), (6.2, 16.4)],
            baseZ: 1.95,
            height: 1.4,
            domeInset: 0.14,
            capInset: 0
        )
    }

    var kneeCoreDown: CityTitanSolid {
        solid(
            points: [(3.1, 15.0), (4.6, 15.2), (4.5, 16.3), (3.0, 16.1)],
            baseZ: 0.30,
            height: 1.2,
            domeInset: 0.14,
            capInset: 0
        )
    }

    var kneeCoreUp: CityTitanSolid {
        solid(
            points: [(3.5, 16.2), (5.0, 16.4), (4.9, 17.4), (3.4, 17.2)],
            baseZ: 2.0,
            height: 1.1,
            domeInset: 0.14,
            capInset: 0
        )
    }

    var ankleCoreDown: CityTitanSolid {
        solid(
            points: [(2.7, 18.0), (4.4, 18.25), (4.35, 19.0), (2.65, 18.75)],
            baseZ: 0.25,
            height: 0.70,
            domeInset: 0.12,
            capInset: 0
        )
    }

    var ankleCoreUp: CityTitanSolid {
        solid(
            points: [(3.1, 19.2), (4.8, 19.45), (4.75, 20.2), (3.05, 19.95)],
            baseZ: 1.70,
            height: 0.65,
            domeInset: 0.12,
            capInset: 0
        )
    }

    var elbowCoreDown: CityTitanSolid {
        solid(
            points: [(14.9, 14.5), (15.9, 14.6), (15.85, 16.4), (14.85, 16.3)],
            baseZ: 0.20,
            height: 0.85,
            domeInset: 0.12,
            capInset: 0
        )
    }

    var wristCoreDown: CityTitanSolid {
        solid(
            points: [(17.8, 14.7), (18.5, 14.8), (18.45, 16.3), (17.75, 16.2)],
            baseZ: 0.20,
            height: 0.65,
            domeInset: 0.12,
            capInset: 0
        )
    }

    var wristCoreUp: CityTitanSolid {
        solid(
            points: [(8.45, 17.5), (9.4, 17.45), (9.45, 18.5), (8.5, 18.55)],
            baseZ: 0.25,
            height: 0.75,
            domeInset: 0.12,
            capInset: 0
        )
    }

    /// Sky-side elbow: the one moving arm joint. It rides a share of the
    /// shoulder's rise and stays lapped into both the moving upper arm and
    /// the planted forearm at every pose.
    var elbowCoreUp: CityTitanSolid {
        solid(
            points: [(11.15, 16.8), (12.6, 16.95), (12.5, 18.1), (11.1, 17.95)],
            baseZ: 0.95 + 0.25 * shoulderRise,
            height: 1.5,
            domeInset: 0.12,
            capInset: 0
        )
    }

    /// Sky-side shoulder bridge: sits under the shoulder cap, lapping the
    /// torso crown, so the cap never floats off the trunk as it rises.
    var shoulderCoreUp: CityTitanSolid {
        solid(
            points: [(11.9, 13.3), (13.9, 13.1), (13.9, 15.5), (12.0, 15.4)],
            baseZ: 2.9 + 0.5 * shoulderRise,
            height: 1.1,
            domeInset: 0.14,
            capInset: 0
        )
    }

    // MARK: - Head assembly (live overlay, hinge-animated)

    /// Neck: bridges the torso's shoulder end to the chin and grows with
    /// the head lift, so a stirred pose shows a continuous stone neck and
    /// never a floating head.
    var neck: CityTitanSolid {
        solid(
            points: [(13.5, 13.4), (15.7, 13.2), (15.8, 15.6), (13.6, 15.7)],
            baseZ: 0.70,
            height: 2.9 + headLift,
            domeInset: 0.15,
            domePeak: 0.30,
            capInset: nil
        )
    }

    /// Head: a chamfered stone skull lying on its cheek, crown pointing
    /// along +x and chin toward the shoulders, resting on the ground-side
    /// forearm while asleep and rising clear of it on wake. Its
    /// camera-facing +y plane carries the quarter-turned face.
    var head: CityTitanSolid {
        hingedSolid(
            points: [
                (15.0, 13.5), (15.7, 12.6), (17.9, 12.6), (18.6, 13.5),
                (18.6, 15.9), (17.9, 16.8), (15.7, 16.8), (15.0, 15.9),
            ],
            baseZ: 0.95 + headLift,
            height: 3.3,
            domeInset: 0.14,
            domePeak: 0.50
        )
    }

    /// Heavy brow slab: nearest the crown on the sideways face, standing
    /// proud of the face plane so it throws the eye strip into shadow.
    /// Its long axis runs up the head's ear-to-ear (world z) axis.
    var brow: CityTitanSolid {
        hingedSolid(
            points: [(17.10, 16.55), (17.85, 16.55), (17.85, 17.30), (17.10, 17.30)],
            baseZ: 1.25 + headLift,
            height: 2.75,
            domeInset: 0.20,
            domePeak: 0.12
        )
    }

    /// Nose bridge: juts furthest off the face plane, crosses the eye
    /// strip at mid height, and runs down toward the chin — the stone
    /// bridge that divides the strip into two stacked sockets.
    var nose: CityTitanSolid {
        hingedSolid(
            points: [(16.15, 16.70), (17.06, 16.70), (17.06, 17.45), (16.15, 17.45)],
            baseZ: 2.40 + headLift,
            height: 0.70,
            domeInset: 0.25,
            domePeak: 0.20
        )
    }

    /// Engraved mouth seam: a dark inlay just short of the chin, running
    /// across the sideways face.
    var mouth: CityTitanSolid {
        hingedSolid(
            points: [(15.75, 16.68), (16.02, 16.68), (16.02, 16.93), (15.75, 16.93)],
            baseZ: 2.25 + headLift,
            height: 1.15,
            domeInset: 0.20,
            domePeak: 0.04
        )
    }

    /// Closed-eye strip: a dark seam recessed under the brow's overhang
    /// while the golem sleeps. Real geometry, not a decal. On a head lying
    /// on its cheek it runs vertically, and the nose bridge splits it into
    /// the upper and lower socket.
    var eyeSlit: CityTitanSolid {
        hingedSolid(
            points: [(16.75, 16.72), (17.05, 16.72), (17.05, 17.02), (16.75, 17.02)],
            baseZ: 1.55 + headLift,
            height: 2.25,
            domeInset: 0.20,
            domePeak: 0.03
        )
    }

    /// Open eye revealed as the golem wakes: the same socket strip, cut a
    /// touch prouder of the face plane so it paints cleanly over the slit.
    var eyeOpen: CityTitanSolid {
        hingedSolid(
            points: [(16.72, 16.74), (17.08, 16.74), (17.08, 17.06), (16.72, 17.06)],
            baseZ: 1.50 + headLift,
            height: 2.35,
            domeInset: 0.20,
            domePeak: 0.05
        )
    }

    /// Warm pupil, carved at the face center and painted once into each
    /// socket by `eyeSocketOffset`: the golem's gaze, and the night glow
    /// anchor.
    var pupil: CityTitanSolid {
        hingedSolid(
            points: [(16.78, 16.90), (17.06, 16.90), (17.06, 17.16), (16.78, 17.16)],
            baseZ: 2.60 + headLift,
            height: 0.42,
            domeInset: 0.20,
            domePeak: 0.04
        )
    }

    /// Screen-space offset from the face center to each eye socket. The
    /// head lies on its cheek, so the sockets stack along world z: the
    /// pair separates vertically on screen, and the neck hinge — a yaw in
    /// the ground plane — never tilts that separation. A pure projected
    /// delta, so it carries no projection origin.
    var eyeSocketOffset: CGPoint {
        CGPoint(x: 0, y: -IsoProjection.fz * 0.80 * Self.modelScale)
    }

    /// Every carved mass, joint cores included, in painter order. Bounds
    /// and determinism checks read this, so a pose that swings a mass out
    /// of the authored envelope shows up here.
    var allSolids: [CityTitanSolid] {
        [torso,
         thighDown, shinDown, footDown, thighUp, shinUp, footUp,
         upperArmDown, forearmDown, handDown,
         shoulderUp, upperArmUp, forearmUp, handUp,
         hipCoreDown, hipCoreUp, kneeCoreDown, kneeCoreUp,
         ankleCoreDown, ankleCoreUp, elbowCoreDown, wristCoreDown,
         wristCoreUp, elbowCoreUp, shoulderCoreUp,
         neck, head, brow, nose, mouth, eyeSlit, eyeOpen, pupil]
            .sorted { $0.sortKey < $1.sortKey }
    }

    /// Truly static masses: identical in every pose (all articulation
    /// terms are zero for them by construction). These bake into the
    /// retained base layer and register as static occluders, so the
    /// cached world never goes stale as the golem stirs. A side-lying
    /// golem keeps its trunk, both legs, the arm it sleeps on, and the
    /// draped forearm on the ground through the whole wake transition.
    var groundedSolids: [CityTitanSolid] {
        [torso,
         thighDown, shinDown, footDown, thighUp, shinUp, footUp,
         upperArmDown, forearmDown, handDown, forearmUp, handUp,
         hipCoreDown, hipCoreUp, kneeCoreDown, kneeCoreUp,
         ankleCoreDown, ankleCoreUp, elbowCoreDown, wristCoreDown, wristCoreUp]
            .sorted { $0.sortKey < $1.sortKey }
    }

    /// Posed masses that move with breath and wake: the sky-side shoulder
    /// and its draped upper arm, their moving joint cores, and the head
    /// assembly. The renderer draws these per frame in the live overlay
    /// with frame-correct depth anchors and occlusion.
    var dynamicSolids: [CityTitanSolid] {
        [shoulderUp, shoulderCoreUp, upperArmUp, elbowCoreUp, neck, head]
            .sorted { $0.sortKey < $1.sortKey }
    }

    var worldFootprintBounds: CGRect {
        allSolids.reduce(into: CGRect.null) { bounds, solid in
            bounds = bounds.union(solid.worldBounds)
        }
    }

    var nearSortKey: CGFloat {
        allSolids.map {
            IsoProjection.sortKey(x: $0.worldBounds.maxX, y: $0.worldBounds.maxY)
        }.max() ?? IsoProjection.sortKey(x: baseX, y: baseY)
    }

    // MARK: - Bounds

    var projectedBounds: CGRect {
        let points = allSolids.flatMap { solid in
            solid.facets.flatMap(\.projectedPoints)
        }
        guard
            let minX = points.map(\.x).min(),
            let maxX = points.map(\.x).max(),
            let minY = points.map(\.y).min(),
            let maxY = points.map(\.y).max()
        else {
            return .zero
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    var renderBounds: CGRect {
        let contactPoints = groundedSolids.flatMap(\.worldFootprint).map {
            CityWorldPoint3D(x: $0.x, y: $0.y, z: 0.02).projected
        }
        guard
            let minX = contactPoints.map(\.x).min(),
            let maxX = contactPoints.map(\.x).max(),
            let minY = contactPoints.map(\.y).min(),
            let maxY = contactPoints.map(\.y).max()
        else {
            return projectedBounds.insetBy(dx: -1, dy: -1)
        }
        let contactBounds = CGRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        )
        return projectedBounds.union(contactBounds).insetBy(dx: -0.5, dy: -0.5)
    }

    // MARK: - Model-space helpers

    private func solid(
        points: [(CGFloat, CGFloat)],
        baseZ: CGFloat,
        height: CGFloat,
        domeInset: CGFloat = 0,
        domePeak: CGFloat = 0,
        capInset: CGFloat? = 0.14
    ) -> CityTitanSolid {
        CityTitanSolid(
            worldFootprint: points.map {
                CGPoint(
                    x: baseX + $0.0 * Self.modelScale,
                    y: baseY + $0.1 * Self.modelScale
                )
            },
            baseZ: baseZ * Self.modelScale,
            height: height * Self.modelScale,
            domeInset: domeInset,
            domePeak: domePeak * Self.modelScale,
            capInset: capInset
        )
    }

    /// Solid whose footprint rides the neck hinge (head assembly).
    private func hingedSolid(
        points: [(CGFloat, CGFloat)],
        baseZ: CGFloat,
        height: CGFloat,
        domeInset: CGFloat = 0,
        domePeak: CGFloat = 0
    ) -> CityTitanSolid {
        CityTitanSolid(
            worldFootprint: points.map {
                let rotated = hingeRotate($0.0, $0.1)
                return CGPoint(
                    x: baseX + rotated.x * Self.modelScale,
                    y: baseY + rotated.y * Self.modelScale
                )
            },
            baseZ: baseZ * Self.modelScale,
            height: height * Self.modelScale,
            domeInset: domeInset,
            domePeak: domePeak * Self.modelScale,
            capInset: 0.14
        )
    }
}

/// Organic hold-and-saccade drift for the titan's pupil, in screen points.
/// Holds a fixation for one 2.8s interval, then eases to the next target
/// over 0.22s. Bounded so the pupil never leaves the eye inlay
/// (±1.1 × ±0.45 pt). Deterministic; frozen under Reduce Motion and scaled
/// by eye openness.
enum CityTitanGaze {
    static func pupilOffset(
        seconds: Double,
        wake: CGFloat,
        reduceMotion: Bool
    ) -> CGPoint {
        guard !reduceMotion, wake > 0.1 else { return .zero }
        let openness = min(1, (wake - 0.1) / 0.35)
        func target(_ interval: Int) -> CGPoint {
            let seed = cityStableByteHash("titan-gaze-\(interval)")
            return CGPoint(
                x: CGFloat((seed >> 3) & 0xff) / 255 * 2.2 - 1.1,
                y: CGFloat((seed >> 11) & 0xff) / 255 * 0.9 - 0.45
            )
        }
        let period = 2.8
        let interval = Int(floor(seconds / period))
        let phase = seconds - Double(interval) * period
        let from = target(interval - 1)
        let to = target(interval)
        let t = phase < 0.22 ? CGFloat(phase / 0.22) : 1
        let eased = t * t * (3 - 2 * t)
        return CGPoint(
            x: (from.x + (to.x - from.x) * eased) * openness,
            y: (from.y + (to.y - from.y) * eased) * openness
        )
    }
}
