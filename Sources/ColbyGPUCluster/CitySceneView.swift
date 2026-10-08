import AppKit
import SwiftUI


enum CityBubbleTiming {
    static let lifetime: TimeInterval = 4
    static let fadeDuration: TimeInterval = 0.5

    static func opacity(shownAt: Date, now: Date) -> Double {
        let age = now.timeIntervalSince(shownAt)
        guard age >= 0, age < lifetime else { return 0 }
        return min(1, max(0, (lifetime - age) / fadeDuration))
    }
}

enum CityTooltipLayout {
    static func plate(preferredSize: CGSize, anchoredAt point: CGPoint, canvasSize: CGSize, margin: CGFloat = 4) -> CGRect {
        let maximumWidth = max(0, canvasSize.width - margin * 2)
        let maximumHeight = max(0, canvasSize.height - margin * 2)
        let size = CGSize(width: min(preferredSize.width, maximumWidth), height: min(preferredSize.height, maximumHeight))
        return CGRect(
            x: min(max(margin, point.x + 8), max(margin, canvasSize.width - margin - size.width)),
            y: min(max(margin, point.y - size.height - 4), max(margin, canvasSize.height - margin - size.height)),
            width: size.width,
            height: size.height
        )
    }
}
enum CityTooltipStyle {
    enum Foreground: Equatable {
        case white

        var color: Color {
            switch self {
            case .white: .white
            }
        }
    }

    static let foreground: Foreground = .white
}

struct CityTapResolution: Equatable {
    let selectedPlotID: String?
    let shouldFocus: Bool

    static func apply(intent: CityTapIntent, plotID: String?, selectedPlotID _: String?) -> Self {
        switch intent {
        case .focus:
            Self(selectedPlotID: nil, shouldFocus: true)
        case .select:
            Self(selectedPlotID: plotID, shouldFocus: false)
        }
    }
}


enum StreetFixtureCompositeLayer: Equatable {
    case groundLightPools
    case depthSortedGeometry
}


enum CityRenderPolicies {
    static func windowFacadeOpacity(lod: CityDetailLevel) -> Double { lod.fade(CityDetailLevel.windows) }
    static func streetDetailOpacity(lod: CityDetailLevel) -> Double { lod.fade(CityDetailLevel.streetDetail) }
    static func laneMarkingOpacity(lod: CityDetailLevel) -> Double { 0.85 * streetDetailOpacity(lod: lod) }
    static func shopDressingOpacity(lod: CityDetailLevel) -> Double { lod.fade(CityDetailLevel.shopDressing) }
    static func shopAwningOpacity(isOpen: Bool, lod: CityDetailLevel) -> Double {
        (isOpen ? 0.92 : 0.35) * shopDressingOpacity(lod: lod)
    }
    static func plazaOpacity(lod: CityDetailLevel) -> Double { shopDressingOpacity(lod: lod) }
    static func shouldDrawShopDoorGlow(isOpen: Bool, band: ZoomBand) -> Bool {
        isOpen && band != .province
    }
    static func shadowCasterCount(buildingCount: Int, band _: ZoomBand) -> Int {
        max(0, buildingCount)
    }
    static func shouldDrawStrollers(band: ZoomBand) -> Bool { band != .province }
    static let streetFixtureCompositeOrder: [StreetFixtureCompositeLayer] = [
        .groundLightPools,
        .depthSortedGeometry,
    ]
    static func canDrawWaterShimmer(_ river: [(CGFloat, CGFloat)]) -> Bool { river.count >= 2 }
    static func shouldMirrorBlob(heading: CGSize) -> Bool { heading.width < 0 }
}

enum CityScapeUpdatePlan: Equatable {
    case unchanged
    case activityOnly(nextGeometrySignature: String)
    case fullBuild(nextGeometrySignature: String)
}

enum CityScapeUpdatePolicy {
    static func plan(
        currentGeneratedAt: Date?,
        currentGeometrySignature: String,
        snapshot: ClusterSnapshot
    ) -> CityScapeUpdatePlan {
        guard currentGeneratedAt != snapshot.generatedAt else { return .unchanged }
        let nextGeometrySignature = CityScape.geometrySignature(of: snapshot)
        return currentGeometrySignature == nextGeometrySignature
            ? .activityOnly(nextGeometrySignature: nextGeometrySignature)
            : .fullBuild(nextGeometrySignature: nextGeometrySignature)
    }
}

enum CityTapIntent: Equatable {
    case focus
    case select

    static func resolve(doubleTapRecognized: Bool) -> Self {
        doubleTapRecognized ? .focus : .select
    }
}
struct CitySceneStaticPaths {
    struct CulledPath {
        let path: Path
        let bounds: CGRect
    }

    struct RoadStrip {
        let fill: Path
        let outline: Path
    }

    struct CachedOccluder {
        let bounds: CGRect
        let silhouette: Path
        let rightWallX: CGFloat
        let frontWallY: CGFloat
        let plotID: String
        let revealStage: Int
    }

    /// Static and posed masses share the same union of projected facets
    /// and the same `titan` group: the golem is one landmark, so its baked
    /// half can never punch holes in its posed half, while every other
    /// live actor still depth-sorts against both.
    static func titanOccluder(solid: CityTitanSolid, plotID: String = "titan") -> CachedOccluder {
        var silhouette = Path()
        var projectedBounds = CGRect.null
        for facet in solid.facets {
            var points = facet.projectedPoints
            projectedBounds = projectedBounds.union(bounds(for: points))
            // Back-facing facets project with opposite winding. Normalize
            // them so overlapping faces form a union, not holes in the mask.
            let area = points.indices.reduce(CGFloat(0)) { sum, index in
                let next = points[(index + 1) % points.count]
                return sum + points[index].x * next.y - next.x * points[index].y
            }
            if area < 0 { points.reverse() }
            silhouette.addPath(closedPath(points))
        }
        return CachedOccluder(
            bounds: projectedBounds,
            silhouette: silhouette,
            rightWallX: solid.worldBounds.maxX - 0.05,
            frontWallY: solid.worldBounds.maxY - 0.05,
            plotID: plotID,
            revealStage: 0
        )
    }

    /// One retained massif with model dimensions and precomputed projected paths.
    struct Mountain {
        let x: CGFloat
        let y: CGFloat
        let height: CGFloat
        let radius: CGFloat
        let geometry: CityMountainGeometry
        let companionGeometry: CityMountainGeometry
        let companionX: CGFloat
        let companionY: CGFloat
        let companionHeight: CGFloat
        let companionRadius: CGFloat
        let foothillSkirt: Path

        init(x: CGFloat, y: CGFloat, height: CGFloat, radius: CGFloat) {
            self.x = x
            self.y = y
            self.height = height
            self.radius = radius

            let geometry = CityMountainGeometry(
                x: x,
                y: y,
                height: height,
                radius: radius
            )
            self.geometry = geometry
            let clusterSeed = "\(x)|\(y)".utf8.reduce(2_166_136_261) {
                ($0 ^ Int($1)) &* 16_777_619
            }
            let side: CGFloat = clusterSeed & 1 == 0 ? 1 : -1
            let spread = radius * (
                0.88 + 0.22 * CGFloat((clusterSeed >> 4) & 0x7) / 7
            )
            let companionX = x + side * spread
            let companionY = y - side * spread
            let companionHeight = height * (
                0.60 + 0.14 * CGFloat((clusterSeed >> 8) & 0x7) / 7
            )
            let companionRadius = radius * 0.62
            self.companionX = companionX
            self.companionY = companionY
            self.companionHeight = companionHeight
            self.companionRadius = companionRadius
            self.companionGeometry = CityMountainGeometry(
                x: companionX,
                y: companionY,
                height: companionHeight,
                radius: companionRadius
            )

            var foothillSkirt = Path()
            foothillSkirt.move(to: geometry.far)
            foothillSkirt.addLines([
                geometry.right,
                geometry.near,
                geometry.left,
            ])
            foothillSkirt.closeSubpath()
            self.foothillSkirt = foothillSkirt
        }

        var projectedBounds: CGRect {
            geometry.bounds.union(companionGeometry.bounds)
        }

        var footprint: CGRect {
            CGRect(
                x: x - radius,
                y: y - radius,
                width: radius * 2,
                height: radius * 2
            )
        }
    }

    /// One soft interior mound: an ellipse dome between town and mountain
    /// ring, low enough that trees and meadow read over it naturally.
    struct Hill: Sendable, Equatable {
        let x: CGFloat
        let y: CGFloat
        let radius: CGFloat
        let height: CGFloat
    }

    struct Campground: Sendable, Equatable {
        let center: CGPoint
        let heading: CGFloat
        let tentCount: Int
        let seed: Int
    }

    let ground: Path
    /// World-space terrain extent, derived once from the current city geometry.
    let groundWorldBounds: CGRect
    /// Grid extent rounded out to grid intervals so it always covers terrain.
    let gridWorldBounds: CGRect
    let grid: Path
    let river: Path
    let riverIsland: Path
    let roads: [RoadStrip]
    let localStreets: [CulledPath]
    let sidewalks: [CulledPath]
    let curbs: Path
    let laneMarkings: [CulledPath]
    let blockOutlines: [CulledPath]
    let bridgeTop: Path
    let bridgeSoutheast: Path
    let bridgeSouthwest: Path
    let avenuePath: Path
    let renderBoundsByPlotID: [String: CGRect]
    let occluders: [CachedOccluder]
    /// World-space placement registry: every static feature's footprint.
    let occupancy: CityOccupancy
    /// Resolved sidewalk-prop and curb-parked-car placements (scape-only).
    let placement: CityPlacementPlan
    /// Woodland clusters scattered in the terrain margin outside the city
    /// core, far-to-near painter order. Pure scape geometry.
    let forest: [Tree]
    /// Oversized storybook tree anchoring one woodland clearing.
    let giantTree: Tree
    /// Small woodland destinations cut into successful forest clusters.
    let campgrounds: [Campground]
    /// Stylized mountain massifs hugging the far terrain rims (screen-top
    /// edges), far-to-near painter order. Pure scape geometry.
    let mountains: [Mountain]
    /// Rolling interior mounds between town and mountain ring, far-to-near
    /// painter order. Pure scape geometry.
    let hills: [Hill]
    var gridPathCount: Int { 1 }
    var roadPathCount: Int { roads.count }
    var localStreetPathCount: Int { localStreets.count }
    var laneMarkingPathCount: Int { laneMarkings.count }
    var geometrySignature: [Int] {
        [gridPathCount, roadPathCount, localStreetPathCount, laneMarkingPathCount, sidewalks.count, curbs.cgPath.isEmpty ? 0 : 1, blockOutlines.count]
    }

    init(scape: CityScape) {
        let terrainBounds = Self.worldBounds(for: scape).insetBy(dx: -16, dy: -16)
        self.groundWorldBounds = terrainBounds
        self.ground = Self.closedPath([
            IsoProjection.project(terrainBounds.minX, terrainBounds.minY),
            IsoProjection.project(terrainBounds.maxX, terrainBounds.minY),
            IsoProjection.project(terrainBounds.maxX, terrainBounds.maxY),
            IsoProjection.project(terrainBounds.minX, terrainBounds.maxY),
        ])
        let titanKeepout = CityRenderer.sleepingTitanGeometry(worldBounds: terrainBounds)
            .worldFootprintBounds.insetBy(dx: -2, dy: -2)
        // Woodland: three broad, dense hashed destinations rather than a
        // uniform tree blanket. Every tree and campground center is rejected
        // near terrain edges, plots, streets, the avenue, river, bridge,
        // plazas, and mountains. Pure retained scape geometry.
        let plotKeepouts = scape.plots.map {
            CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.d).insetBy(dx: -4, dy: -4)
        }
        let bridgeSpan = scape.bridgeDeck
        let deckKeepout = CGRect(
            x: bridgeSpan.min.0, y: bridgeSpan.min.1,
            width: bridgeSpan.max.0 - bridgeSpan.min.0, height: bridgeSpan.max.1 - bridgeSpan.min.1
        ).insetBy(dx: -2.5, dy: -2.5)
        var riverKeepout = Path()
        if let first = scape.river.first {
            riverKeepout.move(to: CGPoint(x: first.0, y: first.1))
            for point in scape.river.dropFirst() {
                riverKeepout.addLine(to: CGPoint(x: point.0, y: point.1))
            }
            riverKeepout.closeSubpath()
        }
        let streets = [scape.avenue] + scape.localStreets
        // A visually continuous but gapped horizon range belongs only on the
        // far north/west terrain bands. Every full footprint stays inset from
        // the painted terrain boundary.
        var mountains: [Mountain] = []
        enum Rim: String, CaseIterable { case north, west }
        for rim in Rim.allCases {
            let length = rim == .north
                ? terrainBounds.width
                : terrainBounds.height
            var along: CGFloat = 3
            var slot = 0
            while along < length - 3 {
                let peakHash = UInt(bitPattern: Self.forestHash(
                    "mountain-peak-\(rim.rawValue)-\(slot)"
                ))
                slot += 1
                var height: CGFloat = 6.5 + CGFloat((peakHash >> 16) % 8)
                let fraction = along / length
                if rim == .north, fraction > 0.70 {
                    height *= 0.62
                }
                let radius = height
                    * (0.38 + CGFloat((peakHash >> 24) % 5) * 0.04)
                let inward = radius + 3
                let jitter = (CGFloat(peakHash % 71) / 71 - 0.5) * 1.5
                let point: CGPoint
                switch rim {
                case .north:
                    point = CGPoint(
                        x: terrainBounds.minX + along + jitter,
                        y: terrainBounds.minY + inward
                    )
                case .west:
                    point = CGPoint(
                        x: terrainBounds.minX + inward,
                        y: terrainBounds.minY + along + jitter
                    )
                }

                let candidate = Mountain(
                    x: point.x,
                    y: point.y,
                    height: height,
                    radius: radius
                )
                let safeTerrain = terrainBounds.insetBy(dx: 2, dy: 2)
                let clearsPlots = plotKeepouts.allSatisfy {
                    !$0.insetBy(
                        dx: -radius * 0.7,
                        dy: -radius * 0.7
                    ).intersects(candidate.footprint)
                }
                let clearsInfrastructure = streets.allSatisfy {
                    Self.polylineDistance(from: point, to: $0) > radius + 3.5
                } && Self.polylineDistance(
                    from: point,
                    to: scape.river
                ) > radius + 4
                let clearsMountains = mountains.allSatisfy {
                    hypot($0.x - point.x, $0.y - point.y)
                        >= ($0.radius + radius) * 0.9
                }

                if safeTerrain.contains(candidate.footprint),
                   clearsPlots,
                   clearsInfrastructure,
                   clearsMountains {
                    mountains.append(candidate)
                    // Irregular stride: occasional tight clusters and open
                    // gaps break the fence-post rhythm of a fixed pitch.
                    along += radius * 2 * (0.72 + CGFloat((peakHash >> 8) % 61) / 61 * 0.85)
                } else {
                    along += 1.5
                }
            }
        }
        // Interior relief stays low and wooded; all true peaks remain on the
        // far horizon bands.
        var hills: [Hill] = []
        for slot in 0..<22 {
            let slotHash = UInt(bitPattern: Self.forestHash("relief-\(slot)"))
            let px = terrainBounds.minX + 5
                + CGFloat(slotHash % 997) / 997 * (terrainBounds.width - 10)
            let py = terrainBounds.minY + 5
                + CGFloat((slotHash >> 10) % 991) / 991
                * (terrainBounds.height - 10)
            let point = CGPoint(x: px, y: py)
            let radius = 3.5 + CGFloat((slotHash >> 24) % 5) * 0.7
            let height = radius
                * (0.32 + CGFloat((slotHash >> 28) % 3) * 0.05)
            guard !plotKeepouts.contains(where: {
                $0.insetBy(dx: -2, dy: -2).contains(point)
            }),
            streets.allSatisfy({
                Self.polylineDistance(from: point, to: $0) > radius + 2.5
            }),
            Self.polylineDistance(from: point, to: scape.river) > radius + 3,
            !deckKeepout.insetBy(dx: -3, dy: -3).contains(point),
            !titanKeepout.insetBy(dx: -radius, dy: -radius).contains(point),
            mountains.allSatisfy({
                hypot($0.x - point.x, $0.y - point.y)
                    > $0.radius + radius + 1
            }),
            hills.allSatisfy({
                hypot($0.x - point.x, $0.y - point.y)
                    > ($0.radius + radius) * 0.8
            })
            else { continue }
            hills.append(Hill(
                x: px,
                y: py,
                radius: radius,
                height: height
            ))
        }
        self.hills = hills.sorted {
            ($0.x + $0.y) != ($1.x + $1.y) ? ($0.x + $0.y) < ($1.x + $1.y) : $0.x < $1.x
        }
        self.mountains = mountains.sorted {
            ($0.x + $0.y) != ($1.x + $1.y) ? ($0.x + $0.y) < ($1.x + $1.y) : $0.x < $1.x
        }
        let forestClusterRadius: CGFloat = min(
            15,
            max(11, min(terrainBounds.width, terrainBounds.height) * 0.12)
        )
        let forestCenterSpacing = forestClusterRadius * 2.15
        let forestBounds = terrainBounds.insetBy(
            dx: max(3, forestClusterRadius * 0.45),
            dy: max(3, forestClusterRadius * 0.45)
        )
        func acceptsWoodlandPoint(_ point: CGPoint) -> Bool {
            terrainBounds.insetBy(dx: 1.5, dy: 1.5).contains(point)
                && !plotKeepouts.contains(where: { $0.contains(point) })
                && !deckKeepout.contains(point)
                && !riverKeepout.contains(point)
                && !titanKeepout.contains(point)
                && Self.polylineDistance(from: point, to: scape.river) > 3
                && !scape.plazas.contains(where: {
                    abs($0.x - point.x) < 4 && abs($0.y - point.y) < 4
                })
                && streets.allSatisfy({
                    Self.polylineDistance(from: point, to: $0) > 3.5
                })
                && mountains.allSatisfy({
                    hypot($0.x - point.x, $0.y - point.y) > $0.radius + 4
                })
        }

        var forest: [Tree] = []
        var successfulClusterCenters: [CGPoint] = []
        for candidate in 0..<96 {
            guard successfulClusterCenters.count < 3 else { break }
            let clusterHash = UInt(bitPattern: Self.forestHash(
                "forest-destination-\(candidate)"
            ))
            let center = CGPoint(
                x: forestBounds.minX
                    + CGFloat(clusterHash % 997) / 997 * forestBounds.width,
                y: forestBounds.minY
                    + CGFloat((clusterHash >> 10) % 991) / 991 * forestBounds.height
            )
            guard acceptsWoodlandPoint(center),
                  successfulClusterCenters.allSatisfy({
                      hypot($0.x - center.x, $0.y - center.y) >= forestCenterSpacing
                  })
            else { continue }

            let treeCount = 132 + Int((clusterHash >> 20) % 24)
            let ovalScale = 0.72
                + CGFloat((clusterHash >> 26) % 9) / 100
            var clusterTrees: [Tree] = []
            clusterTrees.reserveCapacity(treeCount)
            for index in 0..<treeCount {
                let treeHash = UInt(bitPattern: Self.forestHash(
                    "forest-tree-\(candidate)-\(index)"
                ))
                let angle = CGFloat.pi * 2
                    * CGFloat(treeHash % 4_091) / 4_091
                let radius = forestClusterRadius
                    * sqrt(CGFloat((treeHash >> 12) % 4_093) / 4_093)
                let point = CGPoint(
                    x: center.x + cos(angle) * radius,
                    y: center.y + sin(angle) * radius * ovalScale
                )
                guard acceptsWoodlandPoint(point) else { continue }
                clusterTrees.append(Tree(
                    x: point.x,
                    y: point.y,
                    size: 2.7
                        + CGFloat((treeHash >> 24) % 71) / 71 * 1.7
                ))
            }
            guard clusterTrees.count >= 68 else { continue }
            successfulClusterCenters.append(center)
            forest.append(contentsOf: clusterTrees)
        }

        let landmarkSeed = forest.max { lhs, rhs in
            func plotClearance(_ tree: Tree) -> CGFloat {
                plotKeepouts.map { rect in
                    hypot(tree.x - rect.midX, tree.y - rect.midY)
                }.min() ?? 0
            }
            return plotClearance(lhs) < plotClearance(rhs)
        } ?? Tree(x: terrainBounds.minX + 8, y: terrainBounds.minY + 8, size: 1)
        let landmark = Tree(x: landmarkSeed.x, y: landmarkSeed.y, size: 22)
        forest.removeAll {
            hypot($0.x - landmark.x, $0.y - landmark.y) < 8
        }
        forest.append(landmark)

        var campgrounds: [Campground] = []
        for (index, center) in successfulClusterCenters.enumerated() {
            guard campgrounds.count < 2 else { break }
            let distanceFromLandmark = hypot(
                center.x - landmark.x,
                center.y - landmark.y
            )
            let surroundingTreeCount = forest.reduce(into: 0) { count, tree in
                let distance = hypot(tree.x - center.x, tree.y - center.y)
                if distance >= 3.2, distance <= 9.5 {
                    count += 1
                }
            }
            guard distanceFromLandmark >= max(14, forestClusterRadius * 1.05),
                  !titanKeepout.insetBy(dx: -6.5, dy: -6.5).contains(center),
                  surroundingTreeCount >= 16,
                  campgrounds.allSatisfy({
                      hypot(
                          $0.center.x - center.x,
                          $0.center.y - center.y
                      ) >= forestClusterRadius * 1.75
                  })
            else { continue }

            let siteHash = UInt(bitPattern: Self.forestHash(
                "campground-\(index)"
            ))
            campgrounds.append(Campground(
                center: center,
                heading: CGFloat(siteHash % 6_283) / 1_000,
                tentCount: 2 + Int((siteHash >> 13) % 2),
                seed: Int(siteHash & UInt(Int.max))
            ))
        }
        let clearingRadius: CGFloat = 2.8
        forest.removeAll { tree in
            campgrounds.contains {
                hypot(tree.x - $0.center.x, tree.y - $0.center.y)
                    < clearingRadius
            }
        }
        self.campgrounds = campgrounds
        self.giantTree = landmark
        self.forest = forest.sorted {
            ($0.x + $0.y) != ($1.x + $1.y) ? ($0.x + $0.y) < ($1.x + $1.y) : $0.x < $1.x
        }
        let minX = (terrainBounds.minX / 10).rounded(.down) * 10
        let maxX = (terrainBounds.maxX / 10).rounded(.up) * 10
        let minY = (terrainBounds.minY / 10).rounded(.down) * 10
        let maxY = (terrainBounds.maxY / 10).rounded(.up) * 10
        self.gridWorldBounds = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        var grid = Path()
        for value in stride(from: minX, through: maxX, by: 10) {
            grid.move(to: IsoProjection.project(value, minY))
            grid.addLine(to: IsoProjection.project(value, maxY))
        }
        for value in stride(from: minY, through: maxY, by: 10) {
            grid.move(to: IsoProjection.project(minX, value))
            grid.addLine(to: IsoProjection.project(maxX, value))
        }
        self.grid = grid
        self.river = Self.closedPath(scape.river.map { IsoProjection.project($0.0, $0.1) })
        self.riverIsland = Self.closedPath(CityScape.riverIslandPolygon().map { IsoProjection.project($0.0, $0.1) })

        var roads: [RoadStrip] = []
        Self.appendRoadStrips(for: scape.avenue, halfWidth: 3.0, to: &roads)
        for plot in scape.plots {
            if let entryPath = scape.entryPath(for: plot.id) {
                Self.appendRoadStrips(for: entryPath, halfWidth: 1.5, to: &roads)
            }
        }
        self.roads = roads

        var localStreets: [CulledPath] = []
        var laneMarkings: [CulledPath] = []
        var sidewalks: [CulledPath] = []
        var curbs = Path()
        Self.appendSidewalks(for: scape.avenue, roadHalfWidth: 3.0, to: &sidewalks, curbs: &curbs)
        for street in scape.localStreets {
            Self.appendSidewalks(for: street, roadHalfWidth: 0.5, to: &sidewalks, curbs: &curbs)
        }
        for street in scape.localStreets {
            let points = street.map { IsoProjection.project($0.0, $0.1, 0.05) }
            let bounds = Self.bounds(for: points)
            var streetPath = Path()
            streetPath.addLines(points)
            localStreets.append(CulledPath(path: streetPath, bounds: bounds))

            let lanePath = Self.laneMarkings(for: street)
            laneMarkings.append(CulledPath(path: lanePath, bounds: bounds))
        }
        self.localStreets = localStreets
        self.laneMarkings = laneMarkings
        self.sidewalks = sidewalks
        self.curbs = curbs

        self.blockOutlines = scape.blocks.map { block in
            let bounds = CGRect(x: block.bounds.x, y: block.bounds.y, width: block.bounds.w, height: block.bounds.d)
            let corners = [
                IsoProjection.project(bounds.minX, bounds.minY, 0.15),
                IsoProjection.project(bounds.maxX, bounds.minY, 0.15),
                IsoProjection.project(bounds.maxX, bounds.maxY, 0.15),
                IsoProjection.project(bounds.minX, bounds.maxY, 0.15),
            ]
            return CulledPath(path: Self.closedPath(corners), bounds: Self.bounds(for: corners))
        }

        let deck = scape.bridgeDeck
        let x = deck.min.0, y = deck.min.1, w = deck.max.0 - deck.min.0, d = deck.max.1 - deck.min.1, h: CGFloat = 0.5
        let a = IsoProjection.project(x, y, h), b = IsoProjection.project(x + w, y, h), c = IsoProjection.project(x + w, y + d, h), e = IsoProjection.project(x, y + d, h)
        let b0 = IsoProjection.project(x + w, y), c0 = IsoProjection.project(x + w, y + d), e0 = IsoProjection.project(x, y + d)
        self.bridgeTop = Self.closedPath([a, b, c, e])
        self.bridgeSoutheast = Self.closedPath([b, b0, c0, c])
        self.bridgeSouthwest = Self.closedPath([e, c, c0, e0])
        var avenuePath = Path()
        let avenuePoints = scape.avenue.map { IsoProjection.project($0.0, $0.1, 0.06) }
        if let first = avenuePoints.first {
            avenuePath.move(to: first)
            avenuePath.addLines(Array(avenuePoints.dropFirst()))
        }
        self.avenuePath = avenuePath
        self.renderBoundsByPlotID = Dictionary(uniqueKeysWithValues: scape.plots.map { plot in
            (plot.id, Self.renderBounds(for: plot))
        })
        var occluders = scape.plots.flatMap { plot in
            plot.buildings.map { building in
                let bx = plot.x + building.ox
                let by = plot.y + building.oy
                let points = [
                    IsoProjection.project(bx, by, building.h),
                    IsoProjection.project(bx + building.bw, by, building.h),
                    IsoProjection.project(bx + building.bw, by, 0),
                    IsoProjection.project(bx + building.bw, by + building.bd, 0),
                    IsoProjection.project(bx, by + building.bd, 0),
                    IsoProjection.project(bx, by + building.bd, building.h),
                ]
                return CachedOccluder(
                    bounds: Self.bounds(for: points),
                    silhouette: Self.closedPath(points),
                    rightWallX: bx + building.bw - 0.05,
                    frontWallY: by + building.bd - 0.05,
                    plotID: plot.id,
                    revealStage: building.revealStage
                )
            }
        }
        occluders += mountains.flatMap { mountain -> [CachedOccluder] in
            func massif(
                _ geometry: CityMountainGeometry,
                x: CGFloat,
                y: CGFloat,
                radius: CGFloat
            ) -> CachedOccluder {
                CachedOccluder(
                    bounds: geometry.bounds,
                    silhouette: geometry.outlinePath,
                    rightWallX: x + radius - 0.05,
                    frontWallY: y + radius - 0.05,
                    plotID: "terrain-mountain",
                    revealStage: 0
                )
            }
            return [
                massif(mountain.geometry, x: mountain.x, y: mountain.y, radius: mountain.radius),
                massif(
                    mountain.companionGeometry,
                    x: mountain.companionX,
                    y: mountain.companionY,
                    radius: mountain.companionRadius
                ),
            ]
        }
        let titanGeometry = CityRenderer.sleepingTitanGeometry(worldBounds: terrainBounds)
        occluders += titanGeometry.groundedSolids.map { Self.titanOccluder(solid: $0) }
        func treeOccluder(_ tree: Tree, plotID: String) -> CachedOccluder {
            let half = tree.size * 0.35
            let bx = tree.x - half
            let by = tree.y - half
            let points = [
                IsoProjection.project(bx, by, tree.size),
                IsoProjection.project(bx + half * 2, by, tree.size),
                IsoProjection.project(bx + half * 2, by, 0),
                IsoProjection.project(bx + half * 2, by + half * 2, 0),
                IsoProjection.project(bx, by + half * 2, 0),
                IsoProjection.project(bx, by + half * 2, tree.size),
            ]
            return CachedOccluder(
                bounds: Self.bounds(for: points),
                silhouette: Self.closedPath(points),
                rightWallX: bx + half * 2 - 0.05,
                frontWallY: by + half * 2 - 0.05,
                plotID: plotID,
                revealStage: tree.revealStage
            )
        }
        occluders += forest
            .filter { $0 != landmark && $0.size >= 3 }
            .map { treeOccluder($0, plotID: "terrain-forest") }
        occluders.append(treeOccluder(landmark, plotID: "terrain-giant-tree"))
        self.occluders = occluders

        // Placement awareness: register woodland + campgrounds alongside the
        // scape-derived footprints, then resolve props and parked cars once.
        var occupancy = CityOccupancy(scape: scape)
        for tree in self.forest {
            occupancy.register(center: (tree.x, tree.y), half: max(0.3, tree.size * 0.25), tag: .tree)
        }
        occupancy.register(center: (self.giantTree.x, self.giantTree.y), half: max(0.5, self.giantTree.size * 0.3), tag: .tree)
        for campground in self.campgrounds {
            occupancy.register(center: (campground.center.x, campground.center.y), half: 6.5, tag: .campground)
        }
        for mountain in self.mountains {
            occupancy.register(
                center: (mountain.x, mountain.y),
                half: mountain.radius + 1,
                tag: .terrain
            )
            occupancy.register(
                center: (mountain.companionX, mountain.companionY),
                half: mountain.companionRadius + 1,
                tag: .terrain
            )
        }
        occupancy.register(rect: titanKeepout, tag: .terrain)
        self.placement = CityPlacementResolver.resolve(scape: scape, occupancy: &occupancy)
        self.occupancy = occupancy
    }

    private static func appendRoadStrips(for path: [(CGFloat, CGFloat)], halfWidth: CGFloat, to roads: inout [RoadStrip]) {
        for pair in zip(path, path.dropFirst()) {
            let dx = pair.1.0 - pair.0.0, dy = pair.1.1 - pair.0.1
            let length = max(1, hypot(dx, dy))
            let nx = -dy / length * halfWidth, ny = dx / length * halfWidth
            let points = [(pair.0.0 + nx, pair.0.1 + ny), (pair.1.0 + nx, pair.1.1 + ny), (pair.1.0 - nx, pair.1.1 - ny), (pair.0.0 - nx, pair.0.1 - ny)].map { IsoProjection.project($0.0, $0.1) }
            roads.append(RoadStrip(fill: closedPath(points), outline: closedPath(points)))
        }
    }

    private static func appendSidewalks(for street: [(CGFloat, CGFloat)], roadHalfWidth: CGFloat, to sidewalks: inout [CulledPath], curbs: inout Path) {
        for side: CGFloat in [-1, 1] {
            var strip = Path()
            var projectedPoints: [CGPoint] = []
            for (start, end) in zip(street, street.dropFirst()) {
                let dx = end.0 - start.0, dy = end.1 - start.1
                let length = hypot(dx, dy)
                guard length > 0 else { continue }
                let nx = -dy / length, ny = dx / length
                let centerOffset = (roadHalfWidth + 0.33) * side
                let inner = centerOffset - 0.175, outer = centerOffset + 0.175
                let quad = [
                    IsoProjection.project(start.0 + nx * inner, start.1 + ny * inner, 0.03),
                    IsoProjection.project(end.0 + nx * inner, end.1 + ny * inner, 0.03),
                    IsoProjection.project(end.0 + nx * outer, end.1 + ny * outer, 0.03),
                    IsoProjection.project(start.0 + nx * outer, start.1 + ny * outer, 0.03),
                ]
                strip.addLines(quad)
                strip.closeSubpath()
                projectedPoints.append(contentsOf: quad)

                let curbOffset = (roadHalfWidth + 0.08) * side
                curbs.move(to: IsoProjection.project(start.0 + nx * curbOffset, start.1 + ny * curbOffset, 0.04))
                curbs.addLine(to: IsoProjection.project(end.0 + nx * curbOffset, end.1 + ny * curbOffset, 0.04))
            }
            guard !projectedPoints.isEmpty else { continue }
            sidewalks.append(CulledPath(path: strip, bounds: bounds(for: projectedPoints)))
        }
    }

    private static func laneMarkings(for path: [(CGFloat, CGFloat)]) -> Path {
        var markings = Path()
        for pair in zip(path, path.dropFirst()) {
            let dx = pair.1.0 - pair.0.0
            let dy = pair.1.1 - pair.0.1
            let length = hypot(dx, dy)
            guard length > 0 else { continue }
            let ux = dx / length
            let uy = dy / length
            for distance in stride(from: CGFloat(0.8), to: length, by: 2.4) {
                markings.move(to: IsoProjection.project(pair.0.0 + ux * distance, pair.0.1 + uy * distance, 0.07))
                markings.addLine(to: IsoProjection.project(pair.0.0 + ux * min(distance + 0.9, length), pair.0.1 + uy * min(distance + 0.9, length), 0.07))
            }
        }
        return markings
    }


    private static func forestHash(_ value: String) -> Int {
        value.utf8.reduce(2_166_136_261) { ($0 ^ Int($1)) &* 16_777_619 }
    }

    /// Shortest distance from a world point to a world polyline.
    private static func polylineDistance(from point: CGPoint, to line: [(CGFloat, CGFloat)]) -> CGFloat {
        guard let first = line.first else { return .greatestFiniteMagnitude }
        guard line.count > 1 else { return hypot(point.x - first.0, point.y - first.1) }
        var best = CGFloat.greatestFiniteMagnitude
        for index in 0..<(line.count - 1) {
            let a = line[index], b = line[index + 1]
            let abx = b.0 - a.0, aby = b.1 - a.1
            let lengthSquared = abx * abx + aby * aby
            let t = lengthSquared > 0
                ? min(max(((point.x - a.0) * abx + (point.y - a.1) * aby) / lengthSquared, 0), 1)
                : 0
            best = min(best, hypot(point.x - (a.0 + abx * t), point.y - (a.1 + aby * t)))
        }
        return best
    }

    private static func worldBounds(for scape: CityScape) -> CGRect {
        var bounds = scape.plots.reduce(CGRect.null) { bounds, plot in
            bounds.union(CGRect(x: plot.x, y: plot.y, width: plot.w, height: plot.d))
        }
        let deck = scape.bridgeDeck
        let contextPoints = scape.avenue + scape.river + [
            deck.min,
            (deck.max.0, deck.min.1),
            deck.max,
            (deck.min.0, deck.max.1),
        ]
        for point in contextPoints {
            bounds = bounds.union(CGRect(x: point.0, y: point.1, width: 0, height: 0))
        }
        return bounds
    }

    private static func closedPath(_ points: [CGPoint]) -> Path {
        var path = Path()
        path.addLines(points)
        path.closeSubpath()
        return path
    }

    private static func bounds(for points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .null }
        return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) {
            $0.union(CGRect(origin: $1, size: .zero))
        }
    }

    private static func renderBounds(for plot: CityPlot) -> CGRect {
        let maximumHeight = max(10, plot.buildings.map { $0.h * constructionGrowScaleMaximum }.max() ?? 0)
        return bounds(for: [
            IsoProjection.project(plot.x, plot.y),
            IsoProjection.project(plot.x + plot.w, plot.y),
            IsoProjection.project(plot.x, plot.y + plot.d),
            IsoProjection.project(plot.x + plot.w, plot.y + plot.d),
            IsoProjection.project(plot.x, plot.y, maximumHeight),
            IsoProjection.project(plot.x + plot.w, plot.y, maximumHeight),
            IsoProjection.project(plot.x, plot.y + plot.d, maximumHeight),
            IsoProjection.project(plot.x + plot.w, plot.y + plot.d, maximumHeight),
        ])
    }
}

private final class HoverState {
    var point: CGPoint?
    var plotID: String?
    var lastInteraction = Date()
}


enum CitySceneHitTest {
    static func plot(at screenPoint: CGPoint, in scape: CityScape, camera: CityCamera) -> CityPlot? {
        let world = IsoProjection.unproject(camera.invert(screenPoint))
        return scape.plots
            .filter {
                CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.d)
                    .contains(CGPoint(x: world.x, y: world.y))
            }
            .max {
                IsoProjection.sortKey(x: $0.x, y: $0.y) <
                    IsoProjection.sortKey(x: $1.x, y: $1.y)
            }
    }

    static func citizen(
        at screenPoint: CGPoint,
        in scape: CityScape,
        date: Date,
        reduceMotion: Bool,
        camera: CityCamera
    ) -> (plot: CityPlot, job: ClusterJob, citizenIndex: Int)? {
        for plot in scape.plots where plot.mode == .lit || plot.mode == .half {
            let jobs = plot.node.jobs
            guard !jobs.isEmpty else { continue }
            // Mirrors CityRenderer.citizenWorldPosition: rows of five along
            // the south apron, extra rows stepping toward the plot interior.
            for index in 0..<min(10, jobs.count * 2 + 2) {
                let job = jobs[index % jobs.count]
                let time = reduceMotion ? 0 : date.timeIntervalSinceReferenceDate
                let offset = CGFloat(sin(time * 0.7 + Double(index))) * 1.6
                let position = camera.apply(IsoProjection.project(
                    plot.x + 1.6 + CGFloat(index % 5) * max(1, (plot.w - 3) / 5) + offset,
                    plot.y + plot.d - 0.8 - CGFloat(index / 5) * 1.5,
                    1
                ))
                guard hypot(screenPoint.x - position.x, screenPoint.y - position.y) <= 8 else { continue }
                return (plot, job, index)
            }
        }
        return nil
    }
}


struct WindowVisibilityState: Sendable {
    private(set) var isVisible = true

    mutating func update(occlusionState: NSWindow.OcclusionState) {
        isVisible = occlusionState.contains(.visible)
    }
}

enum CityRenderUpdatePolicy: Equatable {
    case liveTimelines
    case frozenCanvases

    init(isWindowVisible: Bool) {
        self = isWindowVisible ? .liveTimelines : .frozenCanvases
    }
}
enum CityBaseInvalidation: Equatable {
    case geometry
    case palette
    case displayScale
    case visibility
    case viewport
    case camera
}

enum CitySceneRenderPolicy {
    static func liveCadence(reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? 1 : 1 / 8
    }

    static func baseDelay(for invalidation: CityBaseInvalidation, isVisible: Bool) -> Duration? {
        guard isVisible else { return nil }
        return invalidation == .camera ? CityBaseLayerPolicy.cameraSettleDelay : .zero
    }
}


struct WindowVisibilityReader: NSViewRepresentable {
    @Binding var isVisible: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(isVisible: $isVisible)
    }

    func makeNSView(context: Context) -> VisibilityTrackingView {
        let view = VisibilityTrackingView()
        view.onWindowChanged = { [weak coordinator = context.coordinator] window in
            coordinator?.observe(window: window)
        }
        return view
    }

    func updateNSView(_ view: VisibilityTrackingView, context: Context) {
        context.coordinator.isVisible = $isVisible
    }

    @MainActor
    final class Coordinator: NSObject {
        var isVisible: Binding<Bool>
        private var state = WindowVisibilityState()
        private weak var window: NSWindow?

        init(isVisible: Binding<Bool>) {
            self.isVisible = isVisible
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func observe(window: NSWindow?) {
            NotificationCenter.default.removeObserver(self)
            self.window = window
            guard let window else { return }
            updateVisibility(for: window)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(occlusionStateDidChange),
                name: NSWindow.didChangeOcclusionStateNotification,
                object: window
            )
        }

        @objc private func occlusionStateDidChange() {
            guard let window else { return }
            updateVisibility(for: window)
        }

        private func updateVisibility(for window: NSWindow) {
            state.update(occlusionState: window.occlusionState)
            isVisible.wrappedValue = state.isVisible
        }
    }

    final class VisibilityTrackingView: NSView {
        var onWindowChanged: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChanged?(window)
        }
    }
}


struct CitySceneView: View {
    let store: ClusterStore
    let palette: AppPalette

    private static let initialScape = CityScape.build(snapshot: .empty)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @AppStorage("refreshInterval") private var refreshInterval = 60
    @AppStorage("cityCycleDemo") private var cityCycleDemo = false
    @AppStorage("sshHost") private var sshHost = ""
    @AppStorage("statusPageURL") private var statusPageURL = ClusterSourceDefaults.statusPageURL
    @AppStorage("dataSourceKind") private var dataSourceKind = ClusterSourceKind.statusPage.rawValue
    @State private var director = CityDirector()
    @State private var camera = CityCamera(scale: 1, translation: .zero)
    @State private var band: ZoomBand = .province
    @State private var fittedCamera: CityCamera?
    @State private var isDragging = false
    @State private var lastDragTranslation = CGSize.zero
    @State private var lastMagnification: CGFloat = 1
    @State private var viewportSize = CGSize.zero
    @State private var hover = HoverState()
    @State private var interactionStartDate: Date?
    @State private var selectedPlotID: String?
    @FocusState private var isSceneFocused: Bool
    @State private var bubble: Bubble?
    @State private var scape = CitySceneView.initialScape
    @State private var scapeGeometrySignature = CityScape.geometrySignature(of: .empty)
    @State private var staticPaths = CitySceneStaticPaths(scape: CitySceneView.initialScape)
    @State private var scapeGeneratedAt: Date?
    @State private var isWindowVisible = true
    @State private var frozenRenderDate = Date()
    @State private var frozenCamera = CityCamera(scale: 1, translation: .zero)
    @State private var baseCoordinator = CityBaseRenderCoordinator()


    private struct Bubble: Identifiable {
        let plotID: String
        let citizenIndex: Int
        let text: String
        let shownAt: Date
        var id: String { "\(plotID)-\(shownAt.timeIntervalSinceReferenceDate)" }
    }

    func hud(for plot: CityPlot, isStale: Bool = false, now: Date = Date()) -> CityHUDView {
        CityHUDView(
            plot: plot,
            isStale: isStale,
            lastSuccessfulAt: store.lastSuccessfulAt,
            sshHost: sshHost.trimmingCharacters(in: .whitespacesAndNewlines),
            gpuTelemetry: store.gpuTelemetry,
            showsSSHCommand: source.usesSSH,
            showsTelemetry: !store.gpuTelemetry.isEmpty,
            now: now,
            onDismiss: { selectedPlotID = nil }
        )
    }

    private var source: ClusterSource {
        ClusterSourceResolution.source(kind: dataSourceKind, url: statusPageURL, host: sshHost)
    }

    var body: some View {
        GeometryReader { proxy in
            if isWindowVisible {
                TimelineView(.periodic(from: .now, by: CitySceneRenderPolicy.liveCadence(reduceMotion: reduceMotion))) { timeline in
                    sceneLayers(
                        date: interactionStartDate ?? timeline.date,
                        viewport: proxy.size,
                        isFrozen: false
                    )
                }
            } else {
                sceneLayers(date: frozenRenderDate, viewport: proxy.size, isFrozen: true)
            }
        }
        .background(ScrollWheelZoomCapture { location, deltaY in
            guard viewportSize.width > 0, viewportSize.height > 0 else { return }
            zoom(by: exp(-deltaY * 0.01), anchor: location, scape: scape, viewport: viewportSize)
        })
        .background(WindowVisibilityReader(isVisible: $isWindowVisible))
        .onChange(of: isWindowVisible) { _, visible in
            if visible {
                requestBase(
                    key: desiredBaseKey(frame: CityPalette.frame(date: Date(), demo: cityCycleDemo), size: viewportSize),
                    delay: CitySceneRenderPolicy.baseDelay(for: .visibility, isVisible: true) ?? .zero
                )
            } else {
                frozenRenderDate = Date()
                frozenCamera = camera
                baseCoordinator.cancel()
            }
        }
        .onChange(of: camera) { _, _ in
            updateBand()
            requestBase(
                key: desiredBaseKey(frame: CityPalette.frame(date: Date(), demo: cityCycleDemo), size: viewportSize),
                delay: CitySceneRenderPolicy.baseDelay(for: .camera, isVisible: isWindowVisible) ?? .zero
            )
        }
        .clipped()
    }

    @ViewBuilder
    private func sceneLayers(date: Date, viewport: CGSize, isFrozen: Bool) -> some View {
        let paletteFrame = CityPalette.frame(date: date, demo: cityCycleDemo)
        let densityStages = director.effectiveStages(at: date)
        let key = desiredBaseKey(frame: paletteFrame, size: viewport, stages: densityStages)
        let refreshState = store.refreshState(
            at: date,
            staleAfter: Double(RefreshLoopPolicy.effectiveInterval(refreshInterval) * 2)
        )
        ZStack(alignment: .bottomTrailing) {
            Canvas { context, size in
                CityRenderer(scape: scape, staticPaths: staticPaths, reduceMotion: reduceMotion)
                    .drawBackdrop(context: &context, size: size, sample: paletteFrame.sample)
            }
            cachedBaseCanvas(key: key)
            Canvas { context, size in
                var renderer = CityRenderer(scape: scape, staticPaths: staticPaths, reduceMotion: reduceMotion)
                renderer.densityStages = densityStages
                // Measured telemetry belongs to the live overlay only: the
                // retained base is keyed on geometry and palette, so feeding
                // it a changing sample would rebuild the whole city every poll.
                renderer.gpuTelemetry = store.gpuTelemetry
                // Construction keeps animating (clamped at its final frame)
                // until the retained base actually displays the finished
                // stage, so finished geometry never blinks out between the
                // transition's end and the next base render landing.
                let displayedDensitySignature = baseCoordinator.frame?.key.densitySignature
                let construction = displayedDensitySignature == key.densitySignature
                    ? director.activeDensityTransitions(at: date)
                    : director.densityTransitions
                renderer
                    .drawLiveOverlay(
                        context: &context,
                        size: size,
                        date: date,
                        sample: paletteFrame.sample,
                        camera: camera,
                        band: band,
                        director: director,
                        refreshState: refreshState,
                        pending: store.snapshot.pending,
                        hoverPoint: hover.point,
                        hoveredPlotID: hover.plotID,
                        selectedPlotID: selectedPlotID,
                        bubble: bubble.map { ($0.plotID, $0.citizenIndex, $0.text, $0.shownAt) },
                        construction: construction
                    )
            }
            Color.clear
                .contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case let .active(point):
                        guard !isDragging else { return }
                        hover.point = point
                        hover.plotID = band == .province
                            ? nil
                            : CitySceneHitTest.plot(at: point, in: scape, camera: camera)?.id
                    case .ended:
                        hover.point = nil
                        hover.plotID = nil
                    }
                }
                .gesture(DragGesture(minimumDistance: 2).onChanged { value in
                    if !isDragging {
                        lastDragTranslation = .zero
                        interactionStartDate = date
                    }
                    isDragging = true
                    hover.point = nil
                    hover.plotID = nil
                    // Incremental deltas compose with concurrent zooms; rebuilding
                    // from a drag-start camera stomped mid-drag scale changes and
                    // made the view jump.
                    let delta = CGSize(
                        width: value.translation.width - lastDragTranslation.width,
                        height: value.translation.height - lastDragTranslation.height
                    )
                    lastDragTranslation = value.translation
                    pan(by: delta, scape: scape, viewport: viewportSize)
                }.onEnded { _ in
                    isDragging = false
                    lastDragTranslation = .zero
                    interactionStartDate = nil
                })
                .simultaneousGesture(MagnifyGesture().onChanged { value in
                    if interactionStartDate == nil { interactionStartDate = date }
                    let anchor = CGPoint(x: value.startAnchor.x * viewportSize.width, y: value.startAnchor.y * viewportSize.height)
                    zoom(by: value.magnification / lastMagnification, anchor: anchor, scape: scape, viewport: viewportSize)
                    lastMagnification = value.magnification
                }.onEnded { _ in
                    lastMagnification = 1
                    interactionStartDate = nil
                })
                .simultaneousGesture(
                    SpatialTapGesture(count: 2).exclusively(before: SpatialTapGesture(count: 1)).onEnded { result in
                        switch result {
                        case let .first(value):
                            let plot = CitySceneHitTest.plot(at: value.location, in: scape, camera: camera)
                            selectedPlotID = plot?.id
                            if let plot {
                                focus(on: plot, scape: scape, viewport: viewportSize, animated: !reduceMotion)
                            } else {
                                resetCamera(scape: scape, viewport: viewportSize, animated: !reduceMotion)
                            }
                        case let .second(value):
                            handleTap(at: value.location, scape: scape, date: date, camera: camera)
                        }
                    }
                )
                .focusable()
                .focused($isSceneFocused)
                .onKeyPress(.escape) {
                    if selectedPlotID != nil { selectedPlotID = nil } else { resetCamera(scape: scape, viewport: viewportSize, animated: !reduceMotion) }
                    return .handled
                }
                .onKeyPress("+") { zoomFromControl(by: 1.4); return .handled }
                .onKeyPress("-") { zoomFromControl(by: 1 / 1.4); return .handled }
                .onKeyPress("0") { resetFromControl(); return .handled }
            if let selectedPlotID, let selectedPlot = scape.plots.first(where: { $0.id == selectedPlotID }) {
                hud(for: selectedPlot, isStale: refreshState == .stale || refreshState == .unavailable, now: date)
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            if selectedPlotID == nil {
                sceneStateChip(refreshState: refreshState)
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            // Bottom-leading keeps the controls clear of the top-trailing
            // inspector regardless of how tall its job list grows.
            zoomControls
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .onAppear {
            viewportSize = viewport
            isSceneFocused = true
            let updated = rebuildScapeIfNeeded(snapshot: store.snapshot)
            if fittedCamera == nil, !updated.plots.isEmpty, viewport.width > 0, viewport.height > 0 {
                let fit = cameraFit(for: updated, viewport: viewport)
                camera = fit
                fittedCamera = fit
                updateBand()
            }
            director.reconcile(scape: scape, date: date, reduceMotion: reduceMotion, band: band)
            requestBase(key: key, delay: .zero)
        }
        .onChange(of: viewport) { _, nextSize in
            viewportSize = nextSize
            requestBase(key: desiredBaseKey(frame: paletteFrame, size: nextSize), delay: .zero)
        }
        .onChange(of: key.densitySignature) { _, _ in
            requestBase(key: key, delay: .zero)
        }
        .onChange(of: paletteFrame.key) { _, _ in
            requestBase(key: key, delay: .zero)
        }
        .onChange(of: store.snapshot.generatedAt) { _, updatedAt in
            let updated = rebuildScapeIfNeeded(snapshot: store.snapshot)
            director.reconcile(scape: updated, date: updatedAt, reduceMotion: reduceMotion, band: band)
            requestBase(key: desiredBaseKey(frame: paletteFrame, size: viewport), delay: .zero)
        }
        .onChange(of: band) { _, nextBand in
            director.reconcile(scape: scape, date: date, reduceMotion: reduceMotion, band: nextBand)
        }
        .opacity(isFrozen ? 1 : 1)
    }

    private var liveCadence: TimeInterval {
        reduceMotion ? 1 : 1 / 8
    }

    private func desiredBaseKey(
        frame: CityPaletteFrame,
        size: CGSize,
        stages: [String: Int]? = nil
    ) -> CityBaseRenderKey {
        CityBaseRenderKey(
            geometrySignature: "\(scapeGeometrySignature)|occupancy:\(CityWindows.occupancySignature(for: scape))",
            densitySignature: CityDensity.signature(stages: stages ?? director.effectiveStages(at: Date())),
            viewport: size,
            displayScale: displayScale,
            paletteBucket: frame.key,
            camera: camera,
            band: band
        )
    }

    @ViewBuilder
    private func cachedBaseCanvas(key: CityBaseRenderKey) -> some View {
        if let frame = baseCoordinator.frame, CityBaseLayerPolicy.canDisplay(frame.key, for: key) {
            Canvas { context, _ in
                context.concatenate(CityBaseLayerPolicy.screenTransform(from: frame.key.camera, to: key.camera))
                let image = context.resolve(Image(decorative: frame.image, scale: frame.key.displayScale))
                // The frame is rendered with overscan; its key camera is
                // already shifted by the margin, so the image draws from the
                // rendered-screen origin at its full padded size.
                let padded = CGSize(
                    width: CGFloat(frame.image.width) / frame.key.displayScale,
                    height: CGFloat(frame.image.height) / frame.key.displayScale
                )
                context.draw(image, in: CGRect(origin: .zero, size: padded))
            }
        }
    }

    private func paletteSample(for bucket: Int) -> CityPalette.Sample {
        if bucket >= 1_000 {
            return CityPalette.sample(t: Double(bucket - 1_000) / 90)
        }
        return CityPalette.sample(t: Double(bucket) / 96)
    }

    private func requestBase(key: CityBaseRenderKey, delay: Duration) {
        guard key.viewport.width > 0, key.viewport.height > 0 else { return }
        let renderScape = scape
        let renderPaths = staticPaths
        let renderReduceMotion = reduceMotion
        // The rendered content and the stored key must agree on density, so
        // both come from the same stages snapshot taken at request time.
        let renderStages = director.effectiveStages(at: Date())
        // Overscan: render a margin beyond the viewport so fast drags keep
        // sliding real terrain (not sky) under the live overlay until the
        // next throttled frame lands. The stored key keeps the *requested*
        // viewport for canDisplay, and carries the margin-shifted camera so
        // screenTransform anchors the padded image correctly.
        let pad = CityBaseLayerPolicy.overscan
        let paddedSize = CGSize(width: key.viewport.width + pad * 2, height: key.viewport.height + pad * 2)
        let renderKey = CityBaseRenderKey(
            geometrySignature: key.geometrySignature,
            densitySignature: CityDensity.signature(stages: renderStages),
            viewport: key.viewport,
            displayScale: key.displayScale,
            paletteBucket: key.paletteBucket,
            camera: CityCamera(
                scale: key.camera.scale,
                translation: CGSize(
                    width: key.camera.translation.width + pad,
                    height: key.camera.translation.height + pad
                )
            ),
            band: key.band
        )
        baseCoordinator.request(key: renderKey, delay: delay) {
            let content = Canvas { context, size in
                var renderer = CityRenderer(scape: renderScape, staticPaths: renderPaths, reduceMotion: renderReduceMotion)
                renderer.densityStages = renderStages
                renderer.drawBaseWorld(context: &context, size: size, sample: paletteSample(for: renderKey.paletteBucket), camera: renderKey.camera, band: renderKey.band)
            }
            let renderer = ImageRenderer(content: content.frame(width: paddedSize.width, height: paddedSize.height))
            renderer.scale = renderKey.displayScale
            return renderer.cgImage
        }
    }

    private func recordInteraction(at date: Date) {
        hover.lastInteraction = date
    }

    private func updateBand() {
        let nextBand = ZoomBand.next(from: band, scale: camera.scale)
        guard nextBand != band else { return }
        band = nextBand
    }

    @ViewBuilder
    private func sceneStateChip(refreshState: SnapshotRefreshState) -> some View {
        switch refreshState {
        case .unavailable:
            if store.lastErrorAt != nil || store.lastSuccessfulAt != nil {
                chipLabel(
                    title: "No data",
                    detail: "Check connection, then retry from the menu bar",
                    symbol: "exclamationmark.triangle",
                    tint: palette.status(.partial)
                )
            }
        case .refreshing where store.snapshot.nodes.isEmpty:
            chipLabel(
                title: "Surveying",
                detail: "Loading district data",
                symbol: "antenna.radiowave.left.and.right",
                tint: palette.accent
            )
        case .stale:
            VStack(alignment: .leading, spacing: 2) {
                chipLabel(
                    title: "Last known",
                    detail: "Data may be outdated",
                    symbol: "clock.arrow.circlepath",
                    tint: palette.status(.partial)
                )
                if let lastSuccessfulAt = store.lastSuccessfulAt {
                    (Text(AppShellTimestampLabel.successPrefix) + Text(lastSuccessfulAt, style: .relative))
                        .font(.caption2.monospaced())
                        .foregroundStyle(palette.secondary)
                        .padding(.leading, 2)
                }
            }
        case .fresh, .refreshing:
            EmptyView()
        }
    }

    private func chipLabel(
        title: String,
        detail: String,
        symbol: String,
        tint: Color
    ) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.caption2.weight(.bold))
                .foregroundStyle(tint)
            Text(title)
                .font(.caption2.weight(.semibold))
            Text(detail)
                .font(.caption2)
                .foregroundStyle(palette.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .background(palette.background.opacity(0.55), in: Capsule())
        .accessibilityElement(children: .combine)
    }



    @ViewBuilder
    private var zoomControls: some View {
        VStack(spacing: 3) {
            zoomControlButton(symbol: "plus.magnifyingglass", label: "Zoom in") {
                zoomFromControl(by: 1.4)
            }
            zoomControlButton(symbol: "minus.magnifyingglass", label: "Zoom out") {
                zoomFromControl(by: 1 / 1.4)
            }
            zoomControlButton(symbol: "arrow.counterclockwise", label: "Fit city") {
                resetFromControl()
            }
        }
        .padding(4)
        .background(.ultraThinMaterial, in: Capsule())
        .background(.black.opacity(0.48), in: Capsule())
        .padding(10)
    }

    private func zoomControlButton(symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private func zoomFromControl(by factor: CGFloat) {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return }
        recordInteraction(at: Date())
        zoom(
            by: factor,
            anchor: CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2),
            scape: scape,
            viewport: viewportSize
        )
    }

    private func resetFromControl() {
        recordInteraction(at: Date())
        selectedPlotID = nil
        resetCamera(scape: scape, viewport: viewportSize, animated: !reduceMotion)
    }


    @discardableResult
    private func rebuildScapeIfNeeded(snapshot: ClusterSnapshot) -> CityScape {
        let plan = CityScapeUpdatePolicy.plan(
            currentGeneratedAt: scapeGeneratedAt,
            currentGeometrySignature: scapeGeometrySignature,
            snapshot: snapshot
        )
        let updatedScape: CityScape
        switch plan {
        case .unchanged:
            return scape
        case let .activityOnly(nextGeometrySignature):
            updatedScape = scape.updatingActivity(from: snapshot)
            scapeGeometrySignature = nextGeometrySignature
        case let .fullBuild(nextGeometrySignature):
            let rebuiltScape = CityScape.build(snapshot: snapshot)
            updatedScape = rebuiltScape
            staticPaths = CitySceneStaticPaths(scape: rebuiltScape)
            scapeGeometrySignature = nextGeometrySignature
            // A full rebuild can retire per-GPU plot IDs; a selection that no
            // longer resolves would leave an invisible HUD and eat Esc presses.
            if let selectedPlotID,
               !rebuiltScape.plots.contains(where: { $0.id == selectedPlotID }) {
                self.selectedPlotID = nil
            }
        }
        scapeGeneratedAt = snapshot.generatedAt
        scape = updatedScape
        return updatedScape
    }


    private func cameraFit(for scape: CityScape, viewport: CGSize) -> CityCamera {
        return CityCamera.fitting(
            worldScreenBounds: Self.framedWorldBounds(scape: scape, staticPaths: staticPaths),
            in: viewport,
            margin: 24,
            labelInset: 30
        )
    }

    /// The default frame shows the whole valley: town plots plus the
    /// perimeter mountain ring, so the map reads as an enclosed diorama
    /// instead of a town floating on an unbounded meadow.
    static func framedWorldBounds(scape: CityScape, staticPaths: CitySceneStaticPaths) -> CGRect {
        let plotBounds = scape.plots
            .map { $0.screenBounds() }
            .reduce(CGRect.null) { $0.union($1) }
        // The diorama base extrudes ~15 units of soil strata below the lawn
        // plus its umbra; reserve that room so the fit never crops the walls.
        let ground = staticPaths.ground.boundingRect
        let groundedSlab = CGRect(
            x: ground.minX,
            y: ground.minY,
            width: ground.width,
            height: ground.height + 32
        )
        let terrainAndPlots = plotBounds.union(groundedSlab)
        return staticPaths.mountains.reduce(terrainAndPlots) { rect, mountain in
            rect.union(mountain.projectedBounds)
        }
    }

    private func sceneBounds(for scape: CityScape) -> CGRect {
        Self.framedWorldBounds(scape: scape, staticPaths: staticPaths)
    }
    private func pan(by delta: CGSize, scape: CityScape, viewport: CGSize) {
        var next = camera
        next.translation = CGSize(
            width: camera.translation.width + delta.width,
            height: camera.translation.height + delta.height
        )
        next.clampTranslation(worldScreenBounds: sceneBounds(for: scape), viewport: viewport)
        camera = next
    }

    private func zoom(by factor: CGFloat, anchor: CGPoint, scape: CityScape, viewport: CGSize) {
        var next = camera
        next.zoom(by: factor, anchor: anchor)
        next.clampTranslation(worldScreenBounds: sceneBounds(for: scape), viewport: viewport)
        camera = next
        updateBand()
    }

    private func focus(on plot: CityPlot, scape: CityScape, viewport: CGSize, animated: Bool) {
        let targetScale = max(3.5, camera.scale).clamped(to: CityCamera.scaleRange)
        let projectedCenter = IsoProjection.project(plot.x + plot.w / 2, plot.y + plot.d / 2)
        var target = CityCamera(
            scale: targetScale,
            translation: CGSize(
                width: viewport.width / 2 - projectedCenter.x * targetScale,
                height: viewport.height / 2 - projectedCenter.y * targetScale
            )
        )
        target.clampTranslation(worldScreenBounds: sceneBounds(for: scape), viewport: viewport)
        if animated {
            withAnimation(.easeInOut(duration: 0.28)) {
                camera = target
                updateBand()
            }
        } else {
            camera = target
            updateBand()
        }
    }

    private func handleTap(at point: CGPoint, scape: CityScape, date: Date, camera: CityCamera) {
        if let hit = CitySceneHitTest.citizen(
            at: point,
            in: scape,
            date: date,
            reduceMotion: reduceMotion,
            camera: camera
        ) {
            bubble = Bubble(
                plotID: hit.plot.id,
                citizenIndex: hit.citizenIndex,
                text: "\(hit.job.name) · \(DurationText.compact(hit.job.elapsedSeconds)) in",
                shownAt: date
            )
        } else {
            let plot = CitySceneHitTest.plot(at: point, in: scape, camera: camera)
            selectedPlotID = CityTapResolution.apply(
                intent: .select,
                plotID: plot?.id,
                selectedPlotID: selectedPlotID
            ).selectedPlotID
        }
    }

    private func resetCamera(scape: CityScape, viewport: CGSize, animated: Bool) {
        let target = cameraFit(for: scape, viewport: viewport)
        fittedCamera = target
        if animated {
            withAnimation(.easeInOut(duration: 0.28)) {
                camera = target
                updateBand()
            }
        } else {
            camera = target
            updateBand()
        }
    }




}
func neonPhaseOffset(for plotID: String) -> Int {
    plotID.utf8.reduce(0) { ($0 &* 31) &+ Int($1) } % 13
}

func growScale(sinceStart: TimeInterval, delay: TimeInterval, reduceMotion: Bool) -> CGFloat {
    guard !reduceMotion else { return 1 }
    let elapsed = min(max((sinceStart - delay) / 0.42, 0), 1)
    let u = elapsed - 1
    return CGFloat(1 + u * u * (2.70158 * u + 1.70158))
}

func paletteDayFraction(date: Date, demo: Bool, calendar: Calendar = .current) -> Double {
    if demo {
        return (date.timeIntervalSinceReferenceDate / 90).truncatingRemainder(dividingBy: 1)
    }
    let start = calendar.startOfDay(for: date)
    let elapsed = date.timeIntervalSince(start)
    return min(max(elapsed / 86_400, 0), 1.nextDown)
}

func quantizedLocalDayFraction(date: Date, cadence: TimeInterval, calendar: Calendar = .current) -> Double {
    let start = calendar.startOfDay(for: date)
    let elapsed = date.timeIntervalSince(start)
    let quantized = floor(elapsed / cadence) * cadence
    return min(max(quantized / 86_400, 0), 1.nextDown)
}



private struct ScrollWheelZoomCapture: NSViewRepresentable {
    let onScroll: (CGPoint, CGFloat) -> Void

    func makeNSView(context: Context) -> ScrollView {
        let view = ScrollView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: ScrollView, context: Context) {
        nsView.onScroll = onScroll
    }

    final class ScrollView: NSView {
        override var isFlipped: Bool { true }

        var onScroll: ((CGPoint, CGFloat) -> Void)?
        nonisolated(unsafe) private var scrollMonitor: Any?
        private weak var monitoredWindow: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if scrollMonitor != nil, monitoredWindow === window { return }
            removeScrollMonitor()
            guard let window else { return }
            monitoredWindow = window
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                let location = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(location) else { return event }
                self.onScroll?(location, event.scrollingDeltaY)
                return event
            }
        }

        deinit {
            if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        }

        override func scrollWheel(with event: NSEvent) {
            if scrollMonitor == nil {
                let location = convert(event.locationInWindow, from: nil)
                onScroll?(location, event.scrollingDeltaY)
            }
            super.scrollWheel(with: event)
        }

        private func removeScrollMonitor() {
            if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
            scrollMonitor = nil
            monitoredWindow = nil
        }
    }
}
