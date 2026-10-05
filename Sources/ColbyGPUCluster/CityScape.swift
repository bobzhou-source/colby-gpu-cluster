import CoreGraphics
import SwiftUI

/// Conservative upper bound for the shared back-out construction animation.
let constructionGrowScaleMaximum: CGFloat = 1.100_005

/// A vertical fraction range and horizontal setback for one massing tier of a building.
struct Tier: Sendable, Equatable {
    /// Inclusive lower fraction of the building height.
    let f0: CGFloat
    /// Inclusive upper fraction of the building height.
    let f1: CGFloat
    /// World-unit inset applied to every footprint edge at this tier.
    let inset: CGFloat
}

/// A small lot-apron tree positioned in city world coordinates.
struct Tree: Sendable, Equatable {
    /// World x coordinate inside the owning plot.
    let x: CGFloat
    /// World y coordinate inside the owning plot.
    let y: CGFloat
    /// Canopy size in world units.
    let size: CGFloat
    /// Density stage (0...10) at which the tree becomes visible; zero means
    /// part of the permanent baseline scenery.
    let revealStage: Int

    init(x: CGFloat, y: CGFloat, size: CGFloat, revealStage: Int = 0) {
        self.x = x
        self.y = y
        self.size = size
        self.revealStage = revealStage
    }
}
/// Deterministic rooftop equipment, positioned relative to a building's roof center.
/// Offsets keep each fixture's footprint inside the building's top massing tier.
enum RoofFixture: Sendable, Equatable {
    case waterTower(dx: CGFloat, dy: CGFloat)
    case acUnit(dx: CGFloat, dy: CGFloat)
    case antennaMast(height: CGFloat)
    case smokestack(dx: CGFloat, dy: CGFloat)
    case radarDish(dx: CGFloat, dy: CGFloat)
}

/// Deterministic facade-neon configuration for a building.
struct NeonSignSpec: Sendable, Equatable {
    /// Number of stacked glyph panels (three through five).
    let segments: Int
    /// Vertical position along the facade, from 0.15 through 0.65.
    let offsetFraction: CGFloat
    /// Whether the sign emits magenta rather than teal.
    let usesMagenta: Bool
    /// Whether the sign uses the broken-sign flicker treatment.
    let broken: Bool
}


/// Render-independent geometry and presentation seeds for one building footprint.
///
/// Tier fractions always span the complete normalized building height.
struct BuildingSpec: Sendable, Equatable {
    let ox: CGFloat
    let oy: CGFloat
    let bw: CGFloat
    let bd: CGFloat
    let h: CGFloat
    let crackSeed: Bool
    let facade: RGB
    /// Stacked massing tiers, from the ground to the roof.
    let tiers: [Tier]
    /// Roof equipment rendered above the top massing tier.
    let fixtures: [RoofFixture]
    /// Optional neon glyph-panel configuration for the facade.
    let neonSign: NeonSignSpec?
    /// Density stage (0...10) at which the building becomes visible; zero
    /// means part of the permanent baseline silhouette.
    let revealStage: Int

    /// Creates a building with a full-height, zero-inset tier when no tiers are supplied.
    init(
        ox: CGFloat,
        oy: CGFloat,
        bw: CGFloat,
        bd: CGFloat,
        h: CGFloat,
        crackSeed: Bool,
        facade: RGB,
        tiers: [Tier] = [Tier(f0: 0, f1: 1, inset: 0)],
        fixtures: [RoofFixture] = [],
        neonSign: NeonSignSpec? = nil,
        revealStage: Int = 0
    ) {
        self.ox = ox
        self.oy = oy
        self.bw = bw
        self.bd = bd
        self.h = h
        self.crackSeed = crackSeed
        self.facade = facade
        self.tiers = tiers
        self.fixtures = fixtures
        self.neonSign = neonSign
        self.revealStage = revealStage
    }
}

enum CityMode: Equatable, Sendable {
    case lit
    case vacant
    case half
    case closed
}

enum ShopKind: CaseIterable, Sendable, Equatable {
    case cafe
    case market
    case bakery
    case records
    case arcade
}

struct ShopSpec: Sendable, Equatable {
    let kind: ShopKind
    let x: CGFloat
    let y: CGFloat
    let facingX: Bool
    let accent: Int
}

struct CityPlaza: Sendable, Equatable {
    let blockID: String
    let x: CGFloat
    let y: CGFloat
}

/// World-space lot geometry and its deterministic visual props.
struct CityPlot: Identifiable, Sendable {
    let node: ClusterNode
    let gres: GPUResource
    let gpuIndex: Int
    let gpuCount: Int
    let plotID: String
    let x: CGFloat
    let y: CGFloat
    let w: CGFloat
    let d: CGFloat
    let mode: CityMode
    let buildings: [BuildingSpec]
    let hasCrane: Bool
    /// Small trees placed on this plot's unobstructed apron.
    let trees: [Tree]
    let shops: [ShopSpec]

    /// Creates a plot with no trees unless explicitly provided.
    init(
        node: ClusterNode,
        gres: GPUResource? = nil,
        gpuIndex: Int,
        gpuCount: Int,
        plotID: String? = nil,
        x: CGFloat,
        y: CGFloat,
        w: CGFloat,
        d: CGFloat,
        mode: CityMode,
        buildings: [BuildingSpec],
        hasCrane: Bool,
        trees: [Tree] = [],
        shops: [ShopSpec] = []
    ) {
        self.node = node
        self.gres = gres ?? node.gres[0]
        self.gpuIndex = gpuIndex
        self.gpuCount = gpuCount
        self.plotID = plotID ?? (gpuCount == 1 ? node.id : "\(node.id)-gpu\(gpuIndex)")
        self.x = x
        self.y = y
        self.w = w
        self.d = d
        self.mode = mode
        self.buildings = buildings
        self.hasCrane = hasCrane
        self.trees = trees
        self.shops = shops
    }

    var id: String { plotID }

    var lotCorner: (x: CGFloat, y: CGFloat) {
        (x + w - 1.2, y + d - 2.8)
    }

    func screenBounds() -> CGRect {
        let envelopeHeight = max(
            CGFloat(10),
            buildings.reduce(CGFloat.zero) { max($0, $1.h * constructionGrowScaleMaximum) }
        )
        let corners = [
            IsoProjection.project(x, y),
            IsoProjection.project(x + w, y),
            IsoProjection.project(x, y + d),
            IsoProjection.project(x + w, y + d),
            IsoProjection.project(x, y, envelopeHeight),
            IsoProjection.project(x + w, y, envelopeHeight),
            IsoProjection.project(x, y + d, envelopeHeight),
            IsoProjection.project(x + w, y + d, envelopeHeight),
        ]
        let xs = corners.map(\.x)
        let ys = corners.map(\.y)
        return CGRect(
            x: xs.min() ?? 0,
            y: ys.min() ?? 0,
            width: (xs.max() ?? 0) - (xs.min() ?? 0),
            height: (ys.max() ?? 0) - (ys.min() ?? 0)
        )
    }
    func screenBounds(camera: CityCamera) -> CGRect {
        let bounds = screenBounds()
        let corners = [
            camera.apply(bounds.origin),
            camera.apply(CGPoint(x: bounds.maxX, y: bounds.minY)),
            camera.apply(CGPoint(x: bounds.minX, y: bounds.maxY)),
            camera.apply(CGPoint(x: bounds.maxX, y: bounds.maxY)),
        ]
        let xs = corners.map(\.x)
        let ys = corners.map(\.y)
        return CGRect(
            x: xs.min() ?? 0,
            y: ys.min() ?? 0,
            width: (xs.max() ?? 0) - (xs.min() ?? 0),
            height: (ys.max() ?? 0) - (ys.min() ?? 0)
        )
    }
}

struct CityBlock: Identifiable, Sendable {
    let node: ClusterNode
    let district: CityDistrict
    let plotIDs: [String]
    let bounds: (x: CGFloat, y: CGFloat, w: CGFloat, d: CGFloat)

    var id: String { node.id }
}

struct StreetFurniture: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case bench
        case hydrant
        case planter
        case busStop
    }

    let kind: Kind
    let x: CGFloat
    let y: CGFloat
    let alongX: Bool
}

enum CityAtlasLayout {
    static let buildingHeightScale: CGFloat = 1.2

    private static let historicalAvenue: [(CGFloat, CGFloat)] = [
        (14, 20), (14, 44), (40, 44), (40, 60),
        (60, 60), (60, 76), (78, 76), (78, 90),
    ]
    private static let streetWidth: CGFloat = 2
    private static let firstRowY: CGFloat = 94
    private static let firstBlockX: CGFloat = 84

    static func place(snapshot: ClusterSnapshot) -> (
        plots: [CityPlot],
        blocks: [CityBlock],
        localStreets: [[(CGFloat, CGFloat)]],
        avenue: [(CGFloat, CGFloat)]
    ) {
        let knownProfiles = Set(GPUTier.allCases.map(\.rawValue))
        let orderedNodes = GPUTier.allCases.flatMap { tier in
            snapshot.nodes
                .filter { GPUTier(rawValue: $0.profile) == tier }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } + snapshot.nodes
            .filter { !knownProfiles.contains($0.profile) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        var plots: [CityPlot] = []
        var blocks: [CityBlock] = []
        var rows: [(district: CityDistrict, y: CGFloat)] = []
        var currentY = firstRowY

        for row in districtRows(from: orderedNodes) {
            var cursorX = firstBlockX
            var rowMaxDepth = CGFloat.zero
            rows.append((district: row.district, y: currentY))

            for node in row.nodes {
                let gpuUnits = node.gres.flatMap { resource in
                    (1...resource.count).map { (resource: resource, ordinal: $0) }
                }
                let count = gpuUnits.count
                let grid = grid(for: count)
                let kind = row.district
                let lot = lotSize(for: kind)
                let blockWidth = CGFloat(grid.columns) * lot.w + CGFloat(grid.columns - 1) * streetWidth
                let blockDepth = CGFloat(grid.rows) * lot.d + CGFloat(grid.rows - 1) * streetWidth
                let plotIDs = gpuUnits.map { unit in
                    Self.plotID(for: node, resource: unit.resource, ordinal: unit.ordinal)
                }
                let block = CityBlock(
                    node: node,
                    district: kind,
                    plotIDs: plotIDs,
                    bounds: (x: cursorX, y: currentY, w: blockWidth, d: blockDepth)
                )

                for (zeroBased, unit) in gpuUnits.enumerated() {
                    let gpuIndex = zeroBased + 1
                    let column = zeroBased % grid.columns
                    let plotRow = zeroBased / grid.columns
                    let x = block.bounds.x + CGFloat(column) * (lot.w + streetWidth)
                    let y = block.bounds.y + CGFloat(plotRow) * (lot.d + streetWidth)
                    let plotID = plotIDs[zeroBased]
                    let mode = cityMode(for: node, resource: unit.resource, ordinal: unit.ordinal)
                    let buildings = Self.assigningRevealStages(buildings(for: kind, plotID: plotID, nodeName: node.name))
                    plots.append(CityPlot(
                        node: node,
                        gres: unit.resource,
                        gpuIndex: gpuIndex,
                        gpuCount: count,
                        plotID: plotID,
                        x: x,
                        y: y,
                        w: lot.w,
                        d: lot.d,
                        mode: mode,
                        buildings: buildings,
                        hasCrane: kind == .metropolis,
                        trees: Self.assigningRevealStages(trees(
                            for: kind,
                            plotID: plotID,
                            x: x,
                            y: y,
                            w: lot.w,
                            d: lot.d,
                            buildings: buildings
                        )),
                        shops: shops(for: kind, plotID: plotID, x: x, y: y, buildings: buildings)
                    ))
                }
                blocks.append(block)
                cursorX += blockWidth + streetWidth * 3
                rowMaxDepth = max(rowMaxDepth, blockDepth)
            }
            currentY += rowMaxDepth + DistrictStyle.style(for: row.district).rowGap
        }
        plots = addingRadarDish(to: plots)


        var avenue = historicalAvenue
        guard !blocks.isEmpty else {
            return (plots: plots, blocks: blocks, localStreets: [], avenue: avenue)
        }
        let spineX = firstBlockX - 6
        for (rowIndex, row) in rows.enumerated() {
            let rowEntry = (spineX, row.y - 4)
            for block in blocks where block.district == row.district {
                appendAvenuePoint(rowEntry, to: &avenue)
                appendAvenuePoint(blockEntry(for: block), to: &avenue)
            }
            if rowIndex < rows.count - 1 {
                appendAvenuePoint(rowEntry, to: &avenue)
            }
        }
        let streets = localStreets(plots: plots, blocks: blocks)
        return (plots: plots, blocks: blocks, localStreets: streets, avenue: avenue)
    }

    private static func appendAvenuePoint(_ point: (CGFloat, CGFloat), to avenue: inout [(CGFloat, CGFloat)]) {
        if avenue.last?.0 != point.0 || avenue.last?.1 != point.1 {
            avenue.append(point)
        }
    }

    private static func districtRows(from orderedNodes: [ClusterNode]) -> [(district: CityDistrict, nodes: [ClusterNode])] {
        var districts: [CityDistrict] = []
        var nodesByDistrict: [CityDistrict: [ClusterNode]] = [:]
        for node in orderedNodes {
            let district = kind(for: node)
            if nodesByDistrict[district] == nil {
                districts.append(district)
                nodesByDistrict[district] = []
            }
            nodesByDistrict[district]?.append(node)
        }
        return districts.compactMap { district in
            guard let nodes = nodesByDistrict[district], !nodes.isEmpty else { return nil }
            return (district: district, nodes: nodes)
        }
    }

    private static func blockEntry(for block: CityBlock) -> (CGFloat, CGFloat) {
        (block.bounds.x + block.bounds.w / 2, block.bounds.y - 4)
    }

    private static func grid(for count: Int) -> (columns: Int, rows: Int) {
        switch count {
        case 1: (1, 1)
        case 2: (2, 1)
        case 3...4: (2, 2)
        default: (4, (count + 3) / 4)
        }
    }

    private static func localStreets(plots: [CityPlot], blocks: [CityBlock]) -> [[(CGFloat, CGFloat)]] {
        let blocksByNodeID = Dictionary(uniqueKeysWithValues: blocks.map { ($0.node.id, $0) })
        let ingressStreets = plots.compactMap { plot -> [(CGFloat, CGFloat)]? in
            guard let block = blocksByNodeID[plot.node.id] else {
                assertionFailure("Every allocated plot must belong to its allocated city block.")
                return nil
            }
            let entry = blockEntry(for: block)
            let centre = (plot.x + plot.w / 2, plot.y + plot.d / 2)
            if entry.0 == centre.0 {
                return [entry, centre]
            }
            let ingress = (entry.0, block.bounds.y + 0.1)
            let turn = (centre.0, ingress.1)
            return [entry, ingress, turn, centre]
        }
        return ingressStreets + blocks.flatMap { block in
            internalStreets(for: block, plots: plots.filter { $0.node.id == block.id })
        }
    }

    private static func internalStreets(for block: CityBlock, plots: [CityPlot]) -> [[(CGFloat, CGFloat)]] {
        guard plots.count > 1 else { return [] }
        let plotRects = plots.map { CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.d).insetBy(dx: -0.25, dy: -0.25) }
        let blockRect = CGRect(x: block.bounds.x, y: block.bounds.y, width: block.bounds.w, height: block.bounds.d)
        let columns = Array(Set(plots.map(\.x))).sorted()
        let rows = Array(Set(plots.map(\.y))).sorted()
        var candidates: [[(CGFloat, CGFloat)]] = []

        if columns.count > 1 {
            let left = plots.filter { $0.x == columns[0] }.map { $0.x + $0.w }.max() ?? blockRect.minX
            let right = plots.filter { $0.x == columns[1] }.map(\.x).min() ?? blockRect.maxX
            candidates.append([((left + right) / 2, blockRect.minY), ((left + right) / 2, blockRect.maxY)])
        }
        if rows.count > 1 {
            let top = plots.filter { $0.y == rows[0] }.map { $0.y + $0.d }.max() ?? blockRect.minY
            let bottom = plots.filter { $0.y == rows[1] }.map(\.y).min() ?? blockRect.maxY
            candidates.append([(blockRect.minX, (top + bottom) / 2), (blockRect.maxX, (top + bottom) / 2)])
        }
        let valid = candidates.filter { street in
            street.allSatisfy { point in
                point.0 >= blockRect.minX && point.0 <= blockRect.maxX
                    && point.1 >= blockRect.minY && point.1 <= blockRect.maxY
            } && !streetIntersectsAnyPlot(street, plotRects: plotRects)
        }
        guard valid.count > 1 else { return valid }
        return CityRandom.stringHash(block.id) & 1 == 0
            ? valid
            : [valid[Int(CityRandom.stringHash(block.id) % UInt32(valid.count))]]
    }

    private static func streetIntersectsAnyPlot(_ street: [(CGFloat, CGFloat)], plotRects: [CGRect]) -> Bool {
        zip(street, street.dropFirst()).contains { start, end in
            plotRects.contains { rect in
                if start.0 == end.0 {
                    return start.0 >= rect.minX && start.0 <= rect.maxX
                        && max(min(start.1, end.1), rect.minY) <= min(max(start.1, end.1), rect.maxY)
                }
                if start.1 == end.1 {
                    return start.1 >= rect.minY && start.1 <= rect.maxY
                        && max(min(start.0, end.0), rect.minX) <= min(max(start.0, end.0), rect.maxX)
                }
                return rect.contains(CGPoint(x: start.0, y: start.1))
                    || rect.contains(CGPoint(x: end.0, y: end.1))
            }
        }
    }

    static func lampPositions(localStreets: [[(CGFloat, CGFloat)]], plots: [CityPlot]) -> [(CGFloat, CGFloat)] {
        let spacing: CGFloat = 6
        let vertexClearance: CGFloat = 1
        // Mid-sidewalk: the painted strip spans roadHalf+0.155...roadHalf+0.505
        // (center 0.83 for the 0.5 local-road half-width). The previous 0.55
        // planted poles on the curb seam, half in the asphalt.
        let sidewalkOffset: CGFloat = 0.83
        let plotClearance: CGFloat = 0.4
        let plotFootprints = plots.map { CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.d) }
        var lamps: [(CGFloat, CGFloat)] = []

        for (streetIndex, street) in localStreets.enumerated() where street.count > 1 {
            var distanceToNextLamp = spacing
            for (_, pair) in zip(street.indices, zip(street, street.dropFirst())) {
                let start = pair.0, end = pair.1
                let deltaX = end.0 - start.0
                let deltaY = end.1 - start.1
                let length = hypot(deltaX, deltaY)
                guard length > 0 else { continue }

                var travelled: CGFloat = 0
                while travelled + distanceToNextLamp <= length {
                    travelled += distanceToNextLamp
                    let progress = travelled / length
                    if travelled >= vertexClearance && length - travelled >= vertexClearance {
                        let centre = (start.0 + deltaX * progress, start.1 + deltaY * progress)
                        let normal = (-deltaY / length, deltaX / length)
                        let sides = [-1 as CGFloat, 1].map { sign in
                            (centre.0 + normal.0 * sidewalkOffset * sign, centre.1 + normal.1 * sidewalkOffset * sign)
                        }
                        let distances = sides.map { point in
                            plotFootprints.map { distance(from: point, to: $0) }.min() ?? .greatestFiniteMagnitude
                        }
                        let eligible = sides.indices.filter { distances[$0] >= plotClearance }
                        guard !eligible.isEmpty else {
                            distanceToNextLamp = spacing
                            continue
                        }
                        let preferredSide = streetIndex & 1
                        let selectedIndex = eligible.max { lhs, rhs in
                            if distances[lhs] == distances[rhs] {
                                return lhs != preferredSide && rhs == preferredSide
                            }
                            return distances[lhs] < distances[rhs]
                        }!
                        let selected = sides[selectedIndex]
                        if localStreets.allSatisfy({ distance(from: selected, to: $0) >= 0.4 }) {
                            lamps.append(selected)
                        }
                    }
                    distanceToNextLamp = spacing
                }
                distanceToNextLamp -= length - travelled
            }
        }
        return lamps
    }

    private static func distance(from point: (CGFloat, CGFloat), to rect: CGRect) -> CGFloat {
        hypot(max(max(rect.minX - point.0, 0), point.0 - rect.maxX), max(max(rect.minY - point.1, 0), point.1 - rect.maxY))
    }


    static func streetFurniture(
        localStreets: [[(CGFloat, CGFloat)]],
        avenue: [(CGFloat, CGFloat)],
        plots: [CityPlot]
    ) -> [StreetFurniture] {
        let expandedPlots = plots.map { CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.d).insetBy(dx: -0.3, dy: -0.3) }
        var furniture: [StreetFurniture] = []

        func isClear(_ point: (CGFloat, CGFloat)) -> Bool {
            !expandedPlots.contains { $0.contains(CGPoint(x: point.0, y: point.1)) }
                && localStreets.allSatisfy { distance(from: point, to: $0) >= 0.55 }
        }

        for (streetIndex, street) in localStreets.enumerated() {
            var distanceToNextPiece: CGFloat = 3.5
            var slotIndex = 0
            for (start, end) in zip(street, street.dropFirst()) {
                let dx = end.0 - start.0, dy = end.1 - start.1
                let length = hypot(dx, dy)
                guard length > 0 else { continue }
                let nx = -dy / length, ny = dx / length
                var travelled: CGFloat = 0
                while travelled + distanceToNextPiece <= length {
                    travelled += distanceToNextPiece
                    let side: CGFloat = slotIndex.isMultiple(of: 2) ? 1 : -1
                    let point = (
                        start.0 + dx * travelled / length + nx * 0.7 * side,
                        start.1 + dy * travelled / length + ny * 0.7 * side
                    )
                    if isClear(point) {
                        let selection = CityRandom.hashFraction(streetIndex, slotIndex)
                        let kind: StreetFurniture.Kind
                        switch selection {
                        case ..<0.35: kind = .bench
                        case ..<0.65: kind = .planter
                        case ..<0.90: kind = .hydrant
                        default: kind = .busStop
                        }
                        furniture.append(StreetFurniture(kind: kind, x: point.0, y: point.1, alongX: abs(dx) >= abs(dy)))
                    }
                    slotIndex += 1
                    distanceToNextPiece = 7
                }
                distanceToNextPiece -= length - travelled
            }
        }

        for index in 1..<(max(1, avenue.count - 1)) where index.isMultiple(of: 3) {
            let previous = avenue[index - 1], intersection = avenue[index]
            let dx = intersection.0 - previous.0, dy = intersection.1 - previous.1
            let length = hypot(dx, dy)
            guard length > 0 else { continue }
            let point = (intersection.0 - dy / length, intersection.1 + dx / length)
            guard isClear(point) else { continue }
            furniture.append(StreetFurniture(kind: .busStop, x: point.0, y: point.1, alongX: abs(dx) >= abs(dy)))
        }
        return furniture
    }

    private static func distance(from point: (CGFloat, CGFloat), to street: [(CGFloat, CGFloat)]) -> CGFloat {
        zip(street, street.dropFirst()).map { start, end in
            let dx = end.0 - start.0, dy = end.1 - start.1
            let lengthSquared = dx * dx + dy * dy
            guard lengthSquared > 0 else { return hypot(point.0 - start.0, point.1 - start.1) }
            let progress = min(1, max(0, ((point.0 - start.0) * dx + (point.1 - start.1) * dy) / lengthSquared))
            return hypot(point.0 - (start.0 + dx * progress), point.1 - (start.1 + dy * progress))
        }.min() ?? .greatestFiniteMagnitude
    }

    fileprivate static func kind(for node: ClusterNode) -> CityDistrict {
        switch GPUTier(rawValue: node.profile) {
        case .h200: .metropolis
        case .rtxpro6000: .large
        case .a100, .l40s: .mid
        case .l4: .town
        case .mig, nil: .hamlet
        }
    }

    private static func lotSize(for kind: CityDistrict) -> (w: CGFloat, d: CGFloat) {
        switch kind {
        case .metropolis: (38, 26)
        case .large: (30, 20)
        case .mid: (25, 18)
        case .town: (19, 14)
        case .hamlet: (14, 10)
        }
    }

    fileprivate static func plotID(for node: ClusterNode, resource: GPUResource, ordinal: Int) -> String {
        precondition(!node.gres.isEmpty, "ClusterNode requires at least one GPU resource.")
        if resource == node.gres[0] {
            return node.gres.count == 1 && resource.count == 1
                ? node.id
                : "\(node.id)-gpu\(ordinal)"
        }
        return "\(node.id)-\(resource.profile)-gpu\(ordinal)"
    }

    fileprivate static func cityMode(for node: ClusterNode, resource: GPUResource, ordinal: Int) -> CityMode {
        if node.status == .drain || node.status == .unknown { return .closed }
        return ordinal <= resource.used ? .lit : .vacant
    }

    private static func heightMultiplier(_ name: String, index: Int) -> CGFloat {
        let seed = name.utf8.reduce(5381) { ($0 << 5) &+ $0 &+ Int($1) }
        let value = (seed &* 31 &+ index &* 7919) % 1000
        return 0.85 + 0.3 * CGFloat(Double(value) / 1000)
    }

    /// Generates one to three contiguous normalized massing tiers with upward setbacks.
    private static func tiers(for height: CGFloat, random: inout CityRandom.Mulberry32) -> [Tier] {
        let count: Int
        if height >= 9 {
            count = 3
        } else if height >= 6.5 {
            count = 2
        } else {
            count = 1
        }
        guard count > 1 else { return [Tier(f0: 0, f1: 1, inset: 0)] }

        let firstEnd = CGFloat(0.48 + random.next() * 0.12)
        let secondEnd = count == 3
            ? min(CGFloat(0.88), firstEnd + CGFloat(0.25 + random.next() * 0.10))
            : 1
        let firstInset = CGFloat(0.25 + random.next() * 0.25)
        let secondInset = firstInset + CGFloat(0.25 + random.next() * 0.25)
        if count == 2 {
            return [
                Tier(f0: 0, f1: firstEnd, inset: 0),
                Tier(f0: firstEnd, f1: 1, inset: firstInset),
            ]
        }
        return [
            Tier(f0: 0, f1: firstEnd, inset: 0),
            Tier(f0: firstEnd, f1: secondEnd, inset: firstInset),
            Tier(f0: secondEnd, f1: 1, inset: secondInset),
        ]
    }

    /// Places a deterministic number of trees in unoccupied portions of a lot apron.
    private static func trees(
        for kind: CityDistrict,
        plotID: String,
        x: CGFloat,
        y: CGFloat,
        w: CGFloat,
        d: CGFloat,
        buildings: [BuildingSpec]
    ) -> [Tree] {
        let footprints = buildings.map {
            CGRect(x: x + $0.ox, y: y + $0.oy, width: $0.bw, height: $0.bd)
        }
        var random = CityRandom.Mulberry32(seed: CityRandom.stringHash(plotID) ^ 0x5452_4545)
        let targetRange = DistrictStyle.style(for: kind).treeTarget
        let targetSpan = targetRange.upperBound - targetRange.lowerBound + 1
        let target = targetRange.lowerBound + min(targetSpan - 1, Int(random.next() * Double(targetSpan)))
        var result: [Tree] = []
        for _ in 0..<(target * 24) where result.count < target {
            let candidate = CGPoint(
                x: x + 0.25 + CGFloat(random.next()) * (w - 0.5),
                y: y + 0.25 + CGFloat(random.next()) * (d - 0.5)
            )
            guard !footprints.contains(where: { $0.contains(candidate) }) else { continue }
            result.append(Tree(x: candidate.x, y: candidate.y, size: CGFloat(0.22 + random.next() * 0.24)))
        }
        return result
    }

    private static func buildings(
        for kind: CityDistrict,
        plotID: String,
        nodeName: String
    ) -> [BuildingSpec] {
        let lot = lotSize(for: kind)
        let facadeFamilies = DistrictStyle.style(for: kind).facadeFamilies
        let layout: (columns: Int, rows: Int, count: Int, heights: (CGFloat, CGFloat))
        switch kind {
        case .metropolis: layout = (4, 3, 10, (5, 14))
        case .large: layout = (4, 2, 8, (4.5, 11))
        case .mid: layout = (3, 2, 6, (4, 9))
        case .town: layout = (2, 2, 4, (3, 6.5))
        case .hamlet: layout = (2, 2, 3, (2.5, 4.5))
        }

        let margin: CGFloat = 1
        let cellWidth = (lot.w - 2 * margin) / CGFloat(layout.columns)
        let cellDepth = (lot.d - 2 * margin) / CGFloat(layout.rows)

        let base = (0..<layout.count).map { index in
            var random = CityRandom.Mulberry32(
                seed: (CityRandom.stringHash(plotID) ^ UInt32(index)) &* 0x9E37_79B9
            )
            let width = cellWidth * CGFloat(0.70 + 0.24 * random.next())
            let depth = cellDepth * CGFloat(0.68 + 0.24 * random.next())
            let column = index % layout.columns
            let row = index / layout.columns
            let cellX = margin + CGFloat(column) * cellWidth
            let cellY = margin + CGFloat(row) * cellDepth
            let jitterX = CGFloat((random.next() - 0.5) * 0.30) * cellWidth
            let jitterY = CGFloat((random.next() - 0.5) * 0.30) * cellDepth
            let offsetX = min(max(cellX, cellX + (cellWidth - width) / 2 + jitterX), cellX + cellWidth - width)
            let offsetY = min(max(cellY, cellY + (cellDepth - depth) / 2 + jitterY), cellY + cellDepth - depth)
            let height = (
                layout.heights.0 + CGFloat(random.next()) * (layout.heights.1 - layout.heights.0)
            ) * heightMultiplier(nodeName, index: index) * buildingHeightScale
            let crackSeed = random.next() < 0.25
            let tiers = tiers(for: height, random: &random)
            let facadeIndex = min(facadeFamilies.count - 1, Int(random.next() * Double(facadeFamilies.count)))

            return BuildingSpec(
                ox: offsetX,
                oy: offsetY,
                bw: width,
                bd: depth,
                h: height,
                crackSeed: crackSeed,
                facade: facadeFamilies[facadeIndex],
                tiers: tiers
            )
        }
        let shortest = base.indices.min { base[$0].h == base[$1].h ? $0 < $1 : base[$0].h < base[$1].h } ?? 0
        return base.enumerated().map { index, building in
            let fixturePrefix = "\(plotID)-fixture-\(index)"
            var fixtures: [RoofFixture] = []
            let roofInset = building.tiers.last?.inset ?? 0
            let roofOffset: (String, CGFloat) -> (CGFloat, CGFloat) = { key, margin in
                let xr = max(0, building.bw / 2 - roofInset - margin)
                let yr = max(0, building.bd / 2 - roofInset - margin)
                return (
                    CGFloat(fixtureSeed("\(key)-x") * 2 - 1) * xr,
                    CGFloat(fixtureSeed("\(key)-y") * 2 - 1) * yr
                )
            }
            if building.h >= 8, fixtureSeed("\(fixturePrefix)-antenna") < 0.60 {
                fixtures.append(.antennaMast(height: 1.2 + CGFloat(fixtureSeed("\(fixturePrefix)-antenna-height")) * 1.2))
            } else if building.h >= 4, fixtureSeed("\(fixturePrefix)-water") < 0.35 {
                let (dx, dy) = roofOffset("\(fixturePrefix)-water", 0.65)
                fixtures.append(.waterTower(dx: dx, dy: dy))
            }
            if fixtureSeed("\(fixturePrefix)-ac") < 0.55 {
                let count = fixtureSeed("\(fixturePrefix)-ac-count") < 0.5 ? 1 : 2
                for acIndex in 0..<count {
                    let (dx, dy) = roofOffset("\(fixturePrefix)-ac-\(acIndex)", 0.45)
                    fixtures.append(.acUnit(dx: dx, dy: dy))
                }
            }
            if index == shortest, fixtureSeed("\(plotID)-smokestack") < 0.40 {
                let (dx, dy) = roofOffset("\(plotID)-smokestack", 0.4)
                fixtures.append(.smokestack(dx: dx, dy: dy))
            }
            let neonSign: NeonSignSpec?
            if (4...12).contains(building.h), fixtureSeed("\(fixturePrefix)-neon") < 0.30 {
                neonSign = NeonSignSpec(
                    segments: 3 + Int(fixtureSeed("\(fixturePrefix)-neon-segments") * 3),
                    offsetFraction: 0.15 + CGFloat(fixtureSeed("\(fixturePrefix)-neon-offset")) * 0.5,
                    usesMagenta: fixtureSeed("\(fixturePrefix)-neon-magenta") < 0.45,
                    broken: fixtureSeed("\(fixturePrefix)-neon-broken") < 0.12
                )
            } else {
                neonSign = nil
            }
            return BuildingSpec(
                ox: building.ox, oy: building.oy, bw: building.bw, bd: building.bd, h: building.h,
                crackSeed: building.crackSeed, facade: building.facade, tiers: building.tiers,
                fixtures: fixtures, neonSign: neonSign
            )
        }
    }

    /// FNV-1a alone has weak avalanche when inputs differ only in a trailing
    /// character (e.g. `…-shop-0` vs `…-shop-1`), which correlates every gate
    /// on the same plot. A murmur3 fmix32 finalizer decorrelates the seeds.
    private static func fixtureSeed(_ input: String) -> Double {
        var h = CityRandom.stringHash(input)
        h ^= h >> 16
        h = h &* 0x85EB_CA6B
        h ^= h >> 13
        h = h &* 0xC2B2_AE35
        h ^= h >> 16
        return Double(h) / Double(UInt32.max)
    }

    private static func shops(
        for kind: CityDistrict,
        plotID: String,
        x: CGFloat,
        y: CGFloat,
        buildings: [BuildingSpec]
    ) -> [ShopSpec] {
        let chance = DistrictStyle.style(for: kind).shopChance
        let eligible = buildings.enumerated().filter { $0.element.h <= 6 }
        let chosen = Array(eligible.filter { fixtureSeed("\(plotID)-shop-\($0.offset)") < chance }.prefix(2))
        return chosen.map { index, building in
            let facingX = fixtureSeed("\(plotID)-shop-face-\(index)") < 0.5
            let along = CGFloat(fixtureSeed("\(plotID)-shop-door-\(index)"))
            let doorX = x + building.ox + (facingX ? building.bw : along * building.bw)
            let doorY = y + building.oy + (facingX ? along * building.bd : building.bd)
            let kinds = ShopKind.allCases
            let kind = kinds[Int(fixtureSeed("\(plotID)-shop-kind-\(index)") * Double(kinds.count)) % kinds.count]
            return ShopSpec(
                kind: kind,
                x: doorX,
                y: doorY,
                facingX: facingX,
                accent: Int(fixtureSeed("\(plotID)-shop-accent-\(index)") * 4)
            )
        }
    }

    static func plazas(plots: [CityPlot], blocks: [CityBlock]) -> [CityPlaza] {
        blocks.compactMap { block in
            // Plots fill their blocks edge to edge, so open space only exists
            // between buildings INSIDE a plot. Scan each plot's courtyard for
            // a 3x3 clearing, preferring spots nearest the plot center.
            let blockPlots = plots
                .filter { $0.node.id == block.node.id && block.plotIDs.contains($0.id) }
                .sorted { $0.id < $1.id }
            for plot in blockPlots {
                guard plot.w > 5, plot.d > 5 else { continue }
                let obstacles = plot.buildings.map {
                    CGRect(
                        x: plot.x + $0.ox - 0.3,
                        y: plot.y + $0.oy - 0.3,
                        width: $0.bw + 0.6,
                        height: $0.bd + 0.6
                    )
                }
                let center = CGPoint(x: plot.x + plot.w / 2, y: plot.y + plot.d / 2)
                let steps = 7
                var candidates: [CGPoint] = []
                for row in 0..<steps {
                    for column in 0..<steps {
                        candidates.append(CGPoint(
                            x: plot.x + 1.8 + (plot.w - 3.6) * CGFloat(column) / CGFloat(steps - 1),
                            y: plot.y + 1.8 + (plot.d - 3.6) * CGFloat(row) / CGFloat(steps - 1)
                        ))
                    }
                }
                candidates.sort {
                    let lhs = hypot($0.x - center.x, $0.y - center.y)
                    let rhs = hypot($1.x - center.x, $1.y - center.y)
                    if lhs != rhs { return lhs < rhs }
                    if $0.y != $1.y { return $0.y < $1.y }
                    return $0.x < $1.x
                }
                for point in candidates {
                    let free = CGRect(x: point.x - 1.5, y: point.y - 1.5, width: 3, height: 3)
                    if !obstacles.contains(where: { free.intersects($0) }) {
                        return CityPlaza(blockID: block.id, x: point.x, y: point.y)
                    }
                }
            }
            return nil
        }
    }

    /// Baseline element count that stays visible on an idle plot; everything
    /// beyond it is density geometry unlocked by job progress.
    static let baselineBuildingCount = 3
    static let baselineTreeCount = 3

    private static func assigningRevealStages(_ buildings: [BuildingSpec]) -> [BuildingSpec] {
        buildings.enumerated().map { index, building in
            BuildingSpec(
                ox: building.ox, oy: building.oy, bw: building.bw, bd: building.bd, h: building.h,
                crackSeed: building.crackSeed, facade: building.facade, tiers: building.tiers,
                fixtures: building.fixtures, neonSign: building.neonSign,
                revealStage: CityDensity.revealStage(index: index, baseline: baselineBuildingCount, total: buildings.count)
            )
        }
    }

    private static func assigningRevealStages(_ trees: [Tree]) -> [Tree] {
        trees.enumerated().map { index, tree in
            Tree(
                x: tree.x, y: tree.y, size: tree.size,
                revealStage: CityDensity.revealStage(index: index, baseline: baselineTreeCount, total: trees.count)
            )
        }
    }

    private static func addingRadarDish(to plots: [CityPlot]) -> [CityPlot] {
        let candidate = plots.flatMap { plot in
            plot.buildings.indices.map { (plot: plot, buildingIndex: $0) }
        }.sorted {
            let left = $0.plot.buildings[$0.buildingIndex]
            let right = $1.plot.buildings[$1.buildingIndex]
            if left.h != right.h { return left.h > right.h }
            if $0.plot.id != $1.plot.id { return $0.plot.id < $1.plot.id }
            return $0.buildingIndex < $1.buildingIndex
        }.first
        guard let candidate else { return plots }
        return plots.map { plot in
            guard plot.id == candidate.plot.id else { return plot }
            let buildings = plot.buildings.enumerated().map { index, building in
                guard index == candidate.buildingIndex else { return building }
                let roofInset = building.tiers.last?.inset ?? 0
                let dx = CGFloat(fixtureSeed("\(plot.id)-radar-x") * 2 - 1) * max(0, building.bw / 2 - roofInset - 0.6)
                let dy = CGFloat(fixtureSeed("\(plot.id)-radar-y") * 2 - 1) * max(0, building.bd / 2 - roofInset - 0.6)
                return BuildingSpec(
                    ox: building.ox, oy: building.oy, bw: building.bw, bd: building.bd, h: building.h,
                    crackSeed: building.crackSeed, facade: building.facade, tiers: building.tiers,
                    fixtures: building.fixtures + [.radarDish(dx: dx, dy: dy)], neonSign: building.neonSign,
                    revealStage: building.revealStage
                )
            }
            return CityPlot(
                node: plot.node, gres: plot.gres, gpuIndex: plot.gpuIndex, gpuCount: plot.gpuCount,
                plotID: plot.plotID, x: plot.x, y: plot.y, w: plot.w, d: plot.d, mode: plot.mode,
                buildings: buildings, hasCrane: plot.hasCrane, trees: plot.trees, shops: plot.shops
            )
        }
    }
}

struct CityScape: Sendable {
    let plots: [CityPlot]
    let sortedPlots: [CityPlot]
    let runningJobs: [ClusterJob]
    let blocks: [CityBlock]
    let localStreets: [[(CGFloat, CGFloat)]]
    let lamps: [(CGFloat, CGFloat)]
    let furniture: [StreetFurniture]
    /// Painter order is stable scene geometry, not a per-frame render concern.
    let sortedFurniture: [StreetFurniture]
    let avenue: [(CGFloat, CGFloat)]
    /// Precomputed routes for ambient traffic; avoids rebuilding segment metrics per frame.
    let trafficRouteMetrics: [CityWhimsy.RouteMetrics]
    let bridgeDeck: (min: (CGFloat, CGFloat), max: (CGFloat, CGFloat))
    let river: [(CGFloat, CGFloat)]
    let plazas: [CityPlaza]
    private static let authoredCommuterQueueAnchors: [(CGFloat, CGFloat)] = [
        (76.4, 91.5), (78.2, 93.5), (77.2, 95.6), (79.4, 97.2),
    ]

    private let entryPaths: [String: [(CGFloat, CGFloat)]]
    /// Immutable entry-route metrics built with the scene; commute frames only sample these.
    let entryRouteMetricsByPlotID: [String: CityWhimsy.RouteMetrics]

    func entryPath(for plotID: String) -> [(CGFloat, CGFloat)]? {
        entryPaths[plotID]
    }

    func entryRouteMetrics(for plotID: String) -> CityWhimsy.RouteMetrics? {
        entryRouteMetricsByPlotID[plotID]
    }

    func commuterQueueAnchors(count: Int) -> [(CGFloat, CGFloat)] {
        guard count > 0 else { return [] }
        var anchors = Array(Self.authoredCommuterQueueAnchors.prefix(count))
        for index in anchors.count..<count {
            let extra = CGFloat(index - Self.authoredCommuterQueueAnchors.count)
            let laneOffset: CGFloat = index.isMultiple(of: 2) ? 0 : 1.1
            anchors.append((76.4 + laneOffset + extra * 0.4, 99.0 + extra * 2.0))
        }
        return anchors
    }

    /// Authored meandering river. The center line wanders around the legacy
    /// straight diagonal `(130 - 112s, 28 + 112s)` and calms back to the
    /// exact legacy band through the bridge corridor (s 0.38...0.66), so the
    /// deck and the avenue approach sit on unchanged banks. Amplitudes stay
    /// inside the corridor clearances measured against the atlas layout
    /// (>= 12 world units west of the legacy band, >= 21 east).
    struct RiverStation: Sendable {
        /// Flow parameter 0...1, north-east source to south-west mouth.
        let s: CGFloat
        /// Center-line world position.
        let x: CGFloat
        let y: CGFloat
        /// Bank offsets relative to center x (west negative, east positive;
        /// east includes the lagoon bulge).
        let west: CGFloat
        let east: CGFloat
    }

    static let riverStationCount = 61
    /// Braided island occupies this stretch of the flow, east of center.
    static let riverIslandRange: ClosedRange<CGFloat> = 0.66...0.75
    /// Lagoon bulge on the east bank, downstream.
    static let riverLagoonRange: ClosedRange<CGFloat> = 0.76...0.93

    private static func smoothstep(_ edge0: CGFloat, _ edge1: CGFloat, _ value: CGFloat) -> CGFloat {
        let t = min(max((value - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// 1 away from the bridge, 0 through it: the corridor reverts to the
    /// legacy straight band under the deck and its avenue approach.
    private static func riverCalm(_ s: CGFloat) -> CGFloat {
        smoothstep(0.38, 0.30, s) + smoothstep(0.66, 0.74, s)
    }

    /// 0 at the map-edge cross-sections so the source and mouth rows stay
    /// byte-identical to the legacy quad corners.
    private static func riverEndTaper(_ s: CGFloat) -> CGFloat {
        smoothstep(0, 0.06, s) * smoothstep(1, 0.94, s)
    }

    /// Meander offset (world x) applied to the straight center line.
    private static func riverMeander(_ s: CGFloat) -> CGFloat {
        let wave = 6 * sin(2 * .pi * 1.5 * s + 0.9) + 2.5 * sin(2 * .pi * 3.3 * s + 2.1)
        return wave * riverCalm(s) * riverEndTaper(s)
    }

    /// Island lens half-width across the flow (0 outside the island range).
    static func riverIslandHalfLens(_ s: CGFloat) -> CGFloat {
        let range = riverIslandRange
        guard range.contains(s) else { return 0 }
        return 2.5 * sin(.pi * (s - range.lowerBound) / (range.upperBound - range.lowerBound))
    }

    /// Island center offset east of the river center line.
    static let riverIslandLateral: CGFloat = 5

    static func riverCenter(_ s: CGFloat) -> (x: CGFloat, y: CGFloat) {
        (130 - 112 * s + riverMeander(s), 28 + 112 * s)
    }

    /// Symmetric channel half-width (the island stretch widens so both
    /// branches keep water; the bridge corridor pins the legacy 10).
    static func riverHalfWidth(_ s: CGFloat) -> CGFloat {
        let shaped = riverCalm(s) * riverEndTaper(s)
        let braid = 2.5 * smoothstep(0.66, 0.69, s) * smoothstep(0.75, 0.72, s)
        return 10 + (2.2 * sin(2 * .pi * 2.6 * s + 4.0) + braid) * shaped
    }

    /// Extra east-bank offset forming the downstream lagoon.
    static func riverLagoonBulge(_ s: CGFloat) -> CGFloat {
        8 * smoothstep(0.76, 0.82, s) * smoothstep(0.93, 0.88, s)
    }

    static let riverStations: [RiverStation] = (0..<riverStationCount).map { index in
        let s = CGFloat(index) / CGFloat(riverStationCount - 1)
        let center = riverCenter(s)
        let half = riverHalfWidth(s)
        return RiverStation(s: s, x: center.x, y: center.y, west: -half, east: half + riverLagoonBulge(s))
    }

    /// World position at flow parameter `s`, `lateral` world units east of
    /// the center line.
    static func riverPoint(_ s: CGFloat, lateral: CGFloat) -> (x: CGFloat, y: CGFloat) {
        let center = riverCenter(s)
        return (center.x + lateral, center.y)
    }

    /// Closed bank polygon: west bank downstream, east bank back up.
    static func riverPolygon() -> [(CGFloat, CGFloat)] {
        riverStations.map { ($0.x + $0.west, $0.y) } + riverStations.reversed().map { ($0.x + $0.east, $0.y) }
    }

    /// Closed island lens polygon (empty when the island range is empty).
    static func riverIslandPolygon() -> [(CGFloat, CGFloat)] {
        let samples = riverStations.filter { riverIslandHalfLens($0.s) > 0.15 }
        let westEdge = samples.map { station in
            (station.x + riverIslandLateral - riverIslandHalfLens(station.s), station.y)
        }
        let eastEdge = samples.reversed().map { station in
            (station.x + riverIslandLateral + riverIslandHalfLens(station.s), station.y)
        }
        return westEdge + eastEdge
    }

    static func geometrySignature(of snapshot: ClusterSnapshot) -> String {
        snapshot.nodes
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { node in
                let gresSignature = node.gres
                    .map { "\($0.profile):\($0.count)" }
                    .joined(separator: ",")
                // Status, used counts, and jobs are omitted: the atlas/static-path
                // inputs are mode-independent, and activity is refreshed in-place.
                return "\(node.name)|\(node.profile)|\(gresSignature)"
            }
            .joined(separator: "\n")
    }

    func updatingActivity(from snapshot: ClusterSnapshot) -> CityScape {
        let plotActivities = Dictionary(grouping: Self.plotActivities(from: snapshot), by: \.id)
        precondition(
            plotActivities.values.allSatisfy { $0.count == 1 },
            "CityScape activity updates require unique snapshot plot IDs."
        )
        let plotActivitiesByID = plotActivities.mapValues { $0[0] }
        precondition(
            Set(plotActivitiesByID.keys) == Set(plots.map(\.id)),
            "CityScape activity updates require matching plot topology."
        )
        precondition(
            Set(sortedPlots.map(\.id)) == Set(plots.map(\.id)),
            "CityScape activity updates require sorted plots to match plot topology."
        )

        let blockActivities = Dictionary(grouping: Self.blockActivities(from: snapshot), by: \.id)
        precondition(
            blockActivities.values.allSatisfy { $0.count == 1 },
            "CityScape activity updates require unique snapshot block IDs."
        )
        let blockActivitiesByID = blockActivities.mapValues { $0[0] }
        precondition(
            Set(blockActivitiesByID.keys) == Set(blocks.map(\.id)),
            "CityScape activity updates require matching block topology."
        )

        let updatedPlots = plots.map { plot -> CityPlot in
            guard let activity = plotActivitiesByID[plot.id] else {
                preconditionFailure("Missing snapshot plot \(plot.id) for CityScape activity update.")
            }
            return plot.updatingActivity(from: activity)
        }
        let updatedPlotsByID = Dictionary(uniqueKeysWithValues: updatedPlots.map { ($0.id, $0) })
        let updatedSortedPlots = sortedPlots.map { plot -> CityPlot in
            guard let updatedPlot = updatedPlotsByID[plot.id] else {
                preconditionFailure("Missing sorted plot \(plot.id) for CityScape activity update.")
            }
            return updatedPlot
        }

        let updatedBlocks = blocks.map { block -> CityBlock in
            guard let activity = blockActivitiesByID[block.id] else {
                preconditionFailure("Missing snapshot block \(block.id) for CityScape activity update.")
            }
            return block.updatingActivity(from: activity)
        }

        return CityScape(
            plots: updatedPlots,
            sortedPlots: updatedSortedPlots,
            runningJobs: Self.runningJobs(from: snapshot),
            blocks: updatedBlocks,
            localStreets: localStreets,
            lamps: lamps,
            furniture: furniture,
            sortedFurniture: sortedFurniture,
            avenue: avenue,
            trafficRouteMetrics: trafficRouteMetrics,
            bridgeDeck: bridgeDeck,
            river: river,
            plazas: plazas,
            entryPaths: entryPaths,
            entryRouteMetricsByPlotID: entryRouteMetricsByPlotID
        )
    }

    static func build(snapshot: ClusterSnapshot) -> CityScape {
        let layout = CityAtlasLayout.place(snapshot: snapshot)
        let blocksByNodeID = Dictionary(uniqueKeysWithValues: layout.blocks.map { ($0.node.id, $0) })
        let paths = Dictionary(uniqueKeysWithValues: layout.plots.map { plot in
            let rowEntry = blocksByNodeID[plot.node.id].map(rowEntry(for:))
            return (plot.id, entryPath(to: plot.lotCorner, avenue: layout.avenue, rowEntry: rowEntry))
        })
        let entryRouteMetricsByPlotID = paths.mapValues(CityWhimsy.RouteMetrics.init)
        let sortedPlots = layout.plots.sorted {
            IsoProjection.sortKey(x: $0.x, y: $0.y) < IsoProjection.sortKey(x: $1.x, y: $1.y)
        }
        let runningJobs = layout.plots
            .flatMap { $0.node.jobs }
            .reduce(into: [String: ClusterJob]()) { $0[$1.id] = $1 }
            .values
            .sorted { $0.id < $1.id }
        let furniture = CityAtlasLayout.streetFurniture(
            localStreets: layout.localStreets,
            avenue: layout.avenue,
            plots: layout.plots
        )

        return CityScape(
            plots: layout.plots,
            sortedPlots: sortedPlots,
            runningJobs: runningJobs,
            blocks: layout.blocks,
            localStreets: layout.localStreets,
            lamps: CityAtlasLayout.lampPositions(localStreets: layout.localStreets, plots: layout.plots),
            furniture: furniture,
            sortedFurniture: furniture.sorted { $0.x + $0.y < $1.x + $1.y },
            avenue: layout.avenue,
            trafficRouteMetrics: ([layout.avenue] + layout.localStreets).map(CityWhimsy.RouteMetrics.init),
            bridgeDeck: (min: (74, 84), max: (82, 94)),
            river: Self.riverPolygon(),
            plazas: CityAtlasLayout.plazas(plots: layout.plots, blocks: layout.blocks),
            entryPaths: paths,
            entryRouteMetricsByPlotID: entryRouteMetricsByPlotID
        )
    }
}

private struct CityPlotActivity: Sendable {
    let id: String
    let node: ClusterNode
    let gres: GPUResource
    let gpuIndex: Int
    let gpuCount: Int
    let mode: CityMode
}

private struct CityBlockActivity: Sendable {
    let id: String
    let node: ClusterNode
    let district: CityDistrict
    let plotIDs: [String]
}

/// The five-vehicle palette in 0...255 RGB token space (same tokens as
/// `carColor(for:)`) so renderers can nightify bodies before converting.
func carColorRGB(for key: String) -> RGB {
    let tokens: [RGB] = [
        RGB(r: 63.75, g: 224.4, b: 234.6),
        RGB(r: 255, g: 79.05, b: 160.65),
        RGB(r: 255, g: 209.1, b: 63.75),
        RGB(r: 234.6, g: 239.7, b: 249.9),
        RGB(r: 76.5, g: 132.6, b: 242.25),
    ]
    let value = key.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
    return tokens[abs(value) % tokens.count]
}

func carColor(for key: String) -> Color {
    carColorRGB(for: key).color
}

private extension CityPlot {
    func updatingActivity(from activity: CityPlotActivity) -> CityPlot {
        precondition(id == activity.id, "CityPlot activity updates require matching plot IDs.")
        precondition(gpuIndex == activity.gpuIndex, "CityPlot activity updates require matching GPU indices.")
        precondition(gpuCount == activity.gpuCount, "CityPlot activity updates require matching GPU counts.")
        precondition(gres.profile == activity.gres.profile, "CityPlot activity updates require matching GRES profiles.")
        precondition(gres.count == activity.gres.count, "CityPlot activity updates require matching GRES counts.")

        return CityPlot(
            node: activity.node,
            gres: activity.gres,
            gpuIndex: gpuIndex,
            gpuCount: gpuCount,
            plotID: plotID,
            x: x,
            y: y,
            w: w,
            d: d,
            mode: activity.mode,
            buildings: buildings,
            hasCrane: hasCrane,
            trees: trees,
            shops: shops
        )
    }
}

private extension CityBlock {
    func updatingActivity(from activity: CityBlockActivity) -> CityBlock {
        precondition(id == activity.id, "CityBlock activity updates require matching node IDs.")
        precondition(district == activity.district, "CityBlock activity updates require matching districts.")
        precondition(plotIDs == activity.plotIDs, "CityBlock activity updates require matching plot IDs.")

        return CityBlock(
            node: activity.node,
            district: district,
            plotIDs: plotIDs,
            bounds: bounds
        )
    }
}

private extension CityScape {
    static func plotActivities(from snapshot: ClusterSnapshot) -> [CityPlotActivity] {
        snapshot.nodes.flatMap { node -> [CityPlotActivity] in
            precondition(!node.gres.isEmpty, "ClusterNode requires at least one GPU resource.")
            let gpuUnits = node.gres.flatMap { resource -> [(resource: GPUResource, ordinal: Int)] in
                precondition(resource.count > 0, "GPU resources must advertise positive counts.")
                return (1...resource.count).map { (resource: resource, ordinal: $0) }
            }
            let gpuCount = gpuUnits.count
            return gpuUnits.enumerated().map { zeroBased, unit in
                let gpuIndex = zeroBased + 1
                return CityPlotActivity(
                    id: CityAtlasLayout.plotID(for: node, resource: unit.resource, ordinal: unit.ordinal),
                    node: node,
                    gres: unit.resource,
                    gpuIndex: gpuIndex,
                    gpuCount: gpuCount,
                    mode: CityAtlasLayout.cityMode(for: node, resource: unit.resource, ordinal: unit.ordinal)
                )
            }
        }
    }

    static func blockActivities(from snapshot: ClusterSnapshot) -> [CityBlockActivity] {
        snapshot.nodes.map { node in
            precondition(!node.gres.isEmpty, "ClusterNode requires at least one GPU resource.")
            let plotIDs = node.gres.flatMap { resource -> [String] in
                precondition(resource.count > 0, "GPU resources must advertise positive counts.")
                return (1...resource.count).map { ordinal in
                    CityAtlasLayout.plotID(for: node, resource: resource, ordinal: ordinal)
                }
            }
            return CityBlockActivity(
                id: node.id,
                node: node,
                district: CityAtlasLayout.kind(for: node),
                plotIDs: plotIDs
            )
        }
    }

    static func runningJobs(from snapshot: ClusterSnapshot) -> [ClusterJob] {
        snapshot.nodes
            .flatMap(\.jobs)
            .reduce(into: [String: ClusterJob]()) { $0[$1.id] = $1 }
            .values
            .sorted { $0.id < $1.id }
    }

    static func rowEntry(for block: CityBlock) -> (CGFloat, CGFloat) {
        (block.bounds.x + block.bounds.w / 2, block.bounds.y - 4)
    }

    static func entryPath(
        to lotCorner: (x: CGFloat, y: CGFloat),
        avenue: [(CGFloat, CGFloat)],
        rowEntry: (CGFloat, CGFloat)? = nil
    ) -> [(CGFloat, CGFloat)] {
        let bridgeSideIndex = avenue.indices.min { lhs, rhs in
            let left = abs(avenue[lhs].0 - 78) + abs(avenue[lhs].1 - 90)
            let right = abs(avenue[rhs].0 - 78) + abs(avenue[rhs].1 - 90)
            return left < right
        } ?? avenue.startIndex
        let nearestIndex = avenue.indices.min { lhs, rhs in
            let left = abs(avenue[lhs].0 - lotCorner.x) + abs(avenue[lhs].1 - lotCorner.y)
            let right = abs(avenue[rhs].0 - lotCorner.x) + abs(avenue[rhs].1 - lotCorner.y)
            return left < right
        } ?? avenue.startIndex
        let vertex = rowEntry ?? avenue[nearestIndex]
        let via: (CGFloat, CGFloat)
        if abs(vertex.0 - lotCorner.x) <= abs(vertex.1 - lotCorner.y) {
            via = (vertex.0, lotCorner.y)
        } else {
            via = (lotCorner.x, vertex.1)
        }
        let bridgeSide = avenue[bridgeSideIndex]
        var path: [(CGFloat, CGFloat)] = [bridgeSide]
        let rowSpine = (bridgeSide.0, vertex.1)
        if path.last?.0 != rowSpine.0 || path.last?.1 != rowSpine.1 {
            path.append(rowSpine)
        }
        if path.last?.0 != vertex.0 || path.last?.1 != vertex.1 {
            path.append(vertex)
        }
        if path.last?.0 != via.0 || path.last?.1 != via.1 {
            path.append(via)
        }
        if path.last?.0 != lotCorner.x || path.last?.1 != lotCorner.y {
            path.append((lotCorner.x, lotCorner.y))
        }
        return path
    }
}
