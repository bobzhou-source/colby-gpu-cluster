import CoreGraphics
import Foundation

/// FNV-1a over UTF-8 bytes — identical recipe to the renderer's
/// `stableByteHash` (kept file-private there), so placement seeds match the
/// hashes the draw code derives for the same features.
func cityStableByteHash(_ value: String) -> Int {
    value.utf8.reduce(2_166_136_261) { ($0 ^ Int($1)) &* 16_777_619 }
}

/// Shortest distance from a world point to a polyline.
func cityPolylineDistance(_ point: (CGFloat, CGFloat), _ polyline: [(CGFloat, CGFloat)]) -> CGFloat {
    var best = CGFloat.greatestFiniteMagnitude
    for (start, end) in zip(polyline, polyline.dropFirst()) {
        let dx = end.0 - start.0, dy = end.1 - start.1
        let lengthSquared = dx * dx + dy * dy
        let progress = lengthSquared > 0
            ? max(0, min(1, ((point.0 - start.0) * dx + (point.1 - start.1) * dy) / lengthSquared))
            : 0
        let px = start.0 + dx * progress, py = start.1 + dy * progress
        best = min(best, hypot(point.0 - px, point.1 - py))
    }
    return best
}

/// Street endpoints, corners, and axis crossings — the spots curb parking
/// and sidewalk props must yield to.
func cityStreetIntersectionPoints(scape: CityScape) -> [(CGFloat, CGFloat)] {
    var points: [(CGFloat, CGFloat)] = []
    var segments: [((CGFloat, CGFloat), (CGFloat, CGFloat))] = []
    for street in scape.localStreets {
        points.append(contentsOf: street)
        for (a, b) in zip(street, street.dropFirst()) { segments.append((a, b)) }
    }
    for i in segments.indices {
        for j in (i + 1)..<segments.count {
            let (a, b) = segments[i], (c, d) = segments[j]
            let aHorizontal = a.1 == b.1
            let cHorizontal = c.1 == d.1
            guard aHorizontal != cHorizontal else { continue }
            let (h, v) = aHorizontal ? ((a, b), (c, d)) : ((c, d), (a, b))
            let hy = h.0.1
            let vx = v.0.0
            if vx >= min(h.0.0, h.1.0), vx <= max(h.0.0, h.1.0),
               hy >= min(v.0.1, v.1.1), hy <= max(v.0.1, v.1.1) {
                points.append((vx, hy))
            }
        }
    }
    return points
}

/// Deterministic world-space placement registry: every static feature
/// (roads, buildings, trees, lamps, campgrounds, props, parked cars)
/// registers a footprint, and every placement query asks before committing.
/// Built once per scape next to `CitySceneStaticPaths`; placement order is
/// fixed (infrastructure → nature → street furniture → vehicles) so results
/// never depend on frame timing or job data. Future systems register their
/// own tag and query against everything already here.
struct CityOccupancy: Sendable, Equatable {
    enum Tag: String, Sendable, Hashable, CaseIterable {
        case road, entryPath, avenue, river, bridge
        case plotCore, building, shop, tree
        case lamp, intersection, lotCorner, furniture
        case campground, terrain, prop, parkedCar
    }

    struct Footprint: Sendable, Equatable {
        let rect: CGRect
        let tag: Tag
    }

    private(set) var footprints: [Footprint] = []

    mutating func register(rect: CGRect, tag: Tag) {
        guard rect.width > 0, rect.height > 0 else { return }
        footprints.append(Footprint(rect: rect, tag: tag))
    }

    mutating func register(center: (CGFloat, CGFloat), half: CGFloat, tag: Tag) {
        register(
            rect: CGRect(x: center.0 - half, y: center.1 - half, width: half * 2, height: half * 2),
            tag: tag
        )
    }

    /// Registers a polyline as one footprint per segment, buffered by
    /// `halfWidth` past the center line.
    mutating func register(polyline: [(CGFloat, CGFloat)], halfWidth: CGFloat, tag: Tag) {
        for (start, end) in zip(polyline, polyline.dropFirst()) {
            let rect = CGRect(
                x: min(start.0, end.0) - halfWidth,
                y: min(start.1, end.1) - halfWidth,
                width: abs(end.0 - start.0) + halfWidth * 2,
                height: abs(end.1 - start.1) + halfWidth * 2
            )
            register(rect: rect, tag: tag)
        }
    }

    /// Point query: true when any footprint whose tag appears in `clearances`
    /// lies within (its own bounds + that tag's clearance) of the point.
    func isBlocked(point: (CGFloat, CGFloat), clearances: [Tag: CGFloat]) -> Bool {
        for footprint in footprints {
            guard let clearance = clearances[footprint.tag] else { continue }
            if footprint.rect.insetBy(dx: -clearance, dy: -clearance).contains(CGPoint(x: point.0, y: point.1)) {
                return true
            }
        }
        return false
    }

    func isClear(point: (CGFloat, CGFloat), clearances: [Tag: CGFloat]) -> Bool {
        !isBlocked(point: point, clearances: clearances)
    }

    /// Rect query for future bulk placements (tents, structures).
    func isClear(rect: CGRect, blockedBy tags: Set<Tag>) -> Bool {
        for footprint in footprints where tags.contains(footprint.tag) {
            if footprint.rect.intersects(rect) { return false }
        }
        return true
    }
}

extension CityOccupancy {
    /// What a sidewalk prop (bench/planter/hydrant/mailbox) must clear.
    /// Numbers reproduce the former hand-rolled keepouts, plus new tree,
    /// shop, campground, furniture, prop, and parked-car awareness.
    static let propBlockers: [Tag: CGFloat] = [
        .road: 0.15, .entryPath: 0.15, .avenue: 0.3,
        .plotCore: 0, .building: 0.2, .shop: 0.4, .tree: 0.5,
        .lamp: 0.9, .intersection: 0.5, .furniture: 0.5,
        .campground: 0.2, .terrain: 0.5, .prop: 0.7, .parkedCar: 0.9,
    ]

    /// What a curb-parked car must clear. Roads and plot cores are absent by
    /// design: the curb lane sits between the plot apron and the asphalt.
    static let parkedCarBlockers: [Tag: CGFloat] = [
        .building: 0.8, .shop: 1.1, .tree: 0.8,
        .lamp: 0.9, .intersection: 1.5, .lotCorner: 1.3, .furniture: 0.6,
        .campground: 0.2, .terrain: 0.5, .prop: 0.9, .parkedCar: 0.5,
    ]

    /// Registers everything derivable from the scape alone. Campground
    /// clearings are registered by `CitySceneStaticPaths` (it owns that list)
    /// before placement resolution runs.
    init(scape: CityScape) {
        self.init()
        for street in scape.localStreets {
            register(polyline: street, halfWidth: 0.5, tag: .road)
        }
        register(polyline: scape.avenue, halfWidth: 3.0, tag: .avenue)
        register(polyline: scape.river, halfWidth: 10, tag: .river)
        for plot in scape.plots {
            if let entry = scape.entryPath(for: plot.id) {
                register(polyline: entry, halfWidth: 1.5, tag: .entryPath)
            }
            let core = CGRect(x: plot.x, y: plot.y, width: plot.w, height: plot.d).insetBy(dx: 0.8, dy: 0.8)
            register(rect: core, tag: .plotCore)
            for building in plot.buildings {
                register(
                    rect: CGRect(x: plot.x + building.ox, y: plot.y + building.oy, width: building.bw, height: building.bd),
                    tag: .building
                )
            }
            for shop in plot.shops {
                register(center: (shop.x, shop.y), half: 0.4, tag: .shop)
            }
            for tree in plot.trees {
                register(center: (tree.x, tree.y), half: 0.3, tag: .tree)
            }
            register(center: (plot.lotCorner.x, plot.lotCorner.y), half: 0.5, tag: .lotCorner)
        }
        let deck = scape.bridgeDeck
        register(
            rect: CGRect(
                x: deck.min.0, y: deck.min.1,
                width: deck.max.0 - deck.min.0, height: deck.max.1 - deck.min.1
            ),
            tag: .bridge
        )
        for lamp in scape.lamps {
            register(center: lamp, half: 0.3, tag: .lamp)
        }
        for point in cityStreetIntersectionPoints(scape: scape) {
            register(center: point, half: 0.5, tag: .intersection)
        }
        for item in scape.furniture {
            register(center: (item.x, item.y), half: 0.4, tag: .furniture)
        }
    }
}

/// Resolved static placements for one scape: every sidewalk prop and curb
/// parked car, already filtered through `CityOccupancy`. Positions depend on
/// scape geometry only — never on job data or the clock — so the retained
/// base stays byte-identical when cluster state changes. Per-frame concerns
/// (viewport culling, occlusion probes, palette) stay in the renderer.
struct CityPlacementPlan: Sendable, Equatable {
    struct Prop: Sendable, Equatable {
        enum Kind: Sendable, Equatable {
            case bench(alongX: Bool, rearX: CGFloat, rearY: CGFloat)
            case planter(seed: Int)
            case hydrant
            case mailbox
        }
        let x: CGFloat
        let y: CGFloat
        let kind: Kind
    }

    struct ParkedCar: Sendable, Equatable {
        let plotID: String
        let x: CGFloat
        let y: CGFloat
        let hash: Int
    }

    let props: [Prop]
    let parkedCars: [ParkedCar]
    let commuteSpots: [String: [CGPoint]]
}

enum CityPlacementResolver {
    /// Ports the former render-time placement loops, replacing their
    /// hand-rolled keepouts with occupancy queries. Props resolve first and
    /// register, so parked cars yield to them; both yield to everything the
    /// scape registered. Draw-time culling/occlusion stays in the renderer.
    static func resolve(scape: CityScape, occupancy: inout CityOccupancy) -> CityPlacementPlan {
        var props: [CityPlacementPlan.Prop] = []

        // Benches and planters step along each street every 3.5 world units,
        // alternating kinds per slot and picking a sidewalk side by hash.
        let roadHalfWidth: CGFloat = 0.5
        let offset = roadHalfWidth + 0.55
        for (streetIndex, street) in scape.localStreets.enumerated() where street.count > 1 {
            var distanceToNext: CGFloat = 3.5
            var slot = 0
            for (start, end) in zip(street, street.dropFirst()) {
                let dx = end.0 - start.0, dy = end.1 - start.1
                let length = hypot(dx, dy)
                guard length > 0 else { continue }
                let nx = -dy / length, ny = dx / length
                var travelled: CGFloat = 0
                while travelled + distanceToNext <= length {
                    travelled += distanceToNext
                    distanceToNext = 3.5
                    let progress = travelled / length
                    let seed = cityStableByteHash("street-prop-\(streetIndex)-\(slot)") & Int.max
                    slot += 1
                    let side: CGFloat = seed % 2 == 0 ? 1 : -1
                    let isBench = slot % 2 == 1
                    // A prop backing onto the plot edge nearer the camera must
                    // sit fully on the sidewalk or the plot slab (drawn later)
                    // buries it; backing onto the far edge it may tuck against
                    // the lot at the full curb offset.
                    let halfDepth: CGFloat = isBench ? 0.175 : 0.225
                    let towardCamera = nx * side + ny * side < 0
                    let propOffset = towardCamera ? 1.0 - halfDepth - 0.05 : offset
                    let point = (
                        start.0 + dx * progress + nx * propOffset * side,
                        start.1 + dy * progress + ny * propOffset * side
                    )
                    guard occupancy.isClear(point: point, clearances: CityOccupancy.propBlockers) else { continue }
                    occupancy.register(center: point, half: 0.3, tag: .prop)
                    if isBench {
                        props.append(.init(x: point.0, y: point.1, kind: .bench(alongX: abs(dx) >= abs(dy), rearX: nx * side, rearY: ny * side)))
                    } else {
                        props.append(.init(x: point.0, y: point.1, kind: .planter(seed: seed)))
                    }
                }
                distanceToNext -= length - travelled
            }
        }

        // Hydrants: sparse, and only ever near intersection corners. The
        // corner side away from the camera is tried first so the piece is not
        // buried under the plot it fronts.
        for (streetIndex, street) in scape.localStreets.enumerated() {
            for (vertexIndex, vertex) in street.enumerated() {
                let seed = cityStableByteHash("hydrant-\(streetIndex)-\(vertexIndex)") & Int.max
                guard seed % 2 == 0 else { continue }
                var nx: CGFloat = 0, ny: CGFloat = 0
                if vertexIndex > 0 {
                    let sx = vertex.0 - street[vertexIndex - 1].0, sy = vertex.1 - street[vertexIndex - 1].1
                    let len = max(0.001, hypot(sx, sy)); nx += -sy / len; ny += sx / len
                }
                if vertexIndex < street.count - 1 {
                    let sx = street[vertexIndex + 1].0 - vertex.0, sy = street[vertexIndex + 1].1 - vertex.1
                    let len = max(0.001, hypot(sx, sy)); nx += -sy / len; ny += sx / len
                }
                let cornerLen = max(0.001, hypot(nx, ny)); nx /= cornerLen; ny /= cornerLen
                let preferred: CGFloat = nx + ny > 0 ? 1 : -1
                let sides: [CGFloat] = seed % 2 == 0 ? [preferred, -preferred] : [-preferred, preferred]
                for side in sides {
                    let point = (vertex.0 + nx * (roadHalfWidth + 0.3) * side, vertex.1 + ny * (roadHalfWidth + 0.3) * side)
                    guard occupancy.isClear(point: point, clearances: CityOccupancy.propBlockers) else { continue }
                    occupancy.register(center: point, half: 0.3, tag: .prop)
                    props.append(.init(x: point.0, y: point.1, kind: .hydrant))
                    break
                }
            }
        }

        // Mailboxes: one near every second plot, at the first corner (in a
        // hash-rotated order) that clears everything already placed.
        for plot in scape.plots {
            let seed = cityStableByteHash("mailbox-\(plot.id)") & Int.max
            guard seed % 2 == 0 else { continue }
            let corners: [(CGFloat, CGFloat)] = [
                (plot.x + plot.w + 0.28, plot.y + plot.d + 0.28),
                (plot.x - 0.28, plot.y + plot.d + 0.28),
                (plot.x + plot.w + 0.28, plot.y - 0.28),
                (plot.x - 0.28, plot.y - 0.28),
            ]
            for offsetIndex in 0..<4 {
                let point = corners[((seed >> 3) + offsetIndex) % 4]
                guard occupancy.isClear(point: point, clearances: CityOccupancy.propBlockers) else { continue }
                occupancy.register(center: point, half: 0.3, tag: .prop)
                props.append(.init(x: point.0, y: point.1, kind: .mailbox))
                break
            }
        }

        // Curb-parked cars along each plot's street-facing (y + d) edge:
        // 0-2 by plot hash, tucked 0.8 off the curb line, desaturated at draw
        // time. Cars yield to props because props registered first.
        var parkedCars: [CityPlacementPlan.ParkedCar] = []
        for plot in scape.plots {
            let plotHash = cityStableByteHash(plot.id) & Int.max
            let count = plotHash % 3
            guard count > 0 else { continue }
            let curbY = plot.y + plot.d - 0.8
            let midX = plot.x + plot.w / 2
            for index in 0..<count {
                let cx = midX + (CGFloat(index) - CGFloat(count - 1) / 2) * 2.5
                guard cx >= plot.x + 1.35, cx <= plot.x + plot.w - 1.35 else { continue }
                guard occupancy.isClear(point: (cx, curbY), clearances: CityOccupancy.parkedCarBlockers) else { continue }
                let hash = cityStableByteHash("\(plot.id)-parked-\(index)") & Int.max
                occupancy.register(center: (cx, curbY), half: 0.7, tag: .parkedCar)
                parkedCars.append(.init(plotID: plot.id, x: cx, y: curbY, hash: hash))
            }
        }

        // Commute-car curb seats are resolved once against the complete
        // occupancy registry, after props and static parked cars.
        var commuteSpots: [String: [CGPoint]] = [:]
        for plot in scape.plots {
            let cx = plot.x + plot.w - 1.2
            var seats: [CGPoint] = []
            var index = 0
            while index < 14 {
                let cy = plot.y + plot.d - 2.8 - CGFloat(index) * 2
                index += 1
                guard cy >= plot.y + 1 else { break }
                let footprint = CGRect(
                    x: cx - 0.75,
                    y: cy - 0.35,
                    width: 1.5,
                    height: 0.7
                )
                guard occupancy.isClear(rect: footprint, blockedBy: [.building]) else { continue }
                guard occupancy.isClear(
                    point: (cx, cy),
                    clearances: CityOccupancy.parkedCarBlockers
                ) else { continue }
                seats.append(CGPoint(x: cx, y: cy))
            }
            if !seats.isEmpty {
                commuteSpots[plot.id] = seats
            }
        }

        return CityPlacementPlan(
            props: props,
            parkedCars: parkedCars,
            commuteSpots: commuteSpots
        )
    }
}
