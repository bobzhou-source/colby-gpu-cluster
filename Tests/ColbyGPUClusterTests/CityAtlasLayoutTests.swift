import CoreGraphics
import Foundation
import XCTest
@testable import ColbyGPUCluster

final class CityAtlasLayoutTests: XCTestCase {
    func testDistrictStyleCatalogExposesDesignTokensForEveryDistrict() throws {
        let expected: [CityDistrict: (
            accent: RGB,
            facades: [RGB],
            trees: ClosedRange<Int>,
            shopChance: Double,
            rowGap: CGFloat
        )] = [
            .metropolis: (
                RGB(r: 120, g: 190, b: 255),
                [RGB(r: 77, g: 182, b: 226), RGB(r: 108, g: 146, b: 235), RGB(r: 94, g: 208, b: 192)],
                2...4,
                0.85,
                14
            ),
            .large: (
                RGB(r: 255, g: 170, b: 90),
                [RGB(r: 255, g: 138, b: 101), RGB(r: 255, g: 177, b: 109), RGB(r: 240, g: 112, b: 132)],
                3...5,
                0.7,
                12
            ),
            .mid: (
                RGB(r: 130, g: 220, b: 150),
                [RGB(r: 112, g: 206, b: 140), RGB(r: 156, g: 220, b: 118), RGB(r: 84, g: 190, b: 168)],
                3...6,
                0.5,
                12
            ),
            .town: (
                RGB(r: 255, g: 214, b: 110),
                [RGB(r: 255, g: 205, b: 92), RGB(r: 250, g: 177, b: 96), RGB(r: 255, g: 224, b: 130)],
                4...7,
                0.4,
                10
            ),
            .hamlet: (
                RGB(r: 236, g: 148, b: 210),
                [RGB(r: 240, g: 144, b: 196), RGB(r: 196, g: 152, b: 240), RGB(r: 255, g: 170, b: 180)],
                4...8,
                0.3,
                10
            ),
        ]

        XCTAssertEqual(Set(CityDistrict.allCases), Set(expected.keys))
        for district in CityDistrict.allCases {
            let style = DistrictStyle.style(for: district)
            let values = try XCTUnwrap(expected[district])
            XCTAssertEqual(style.accent, values.accent, "\(district) accent")
            XCTAssertEqual(style.facadeFamilies, values.facades, "\(district) facade families")
            XCTAssertEqual(style.facadeFamilies.count, 3, "\(district) facade family count")
            XCTAssertEqual(style.treeTarget, values.trees, "\(district) tree target")
            XCTAssertEqual(style.shopChance, values.shopChance, accuracy: 1e-12, "\(district) shop chance")
            XCTAssertEqual(style.rowGap, values.rowGap, "\(district) row gap")
        }
    }

    func testPlaceNeverDropsAnyDistrictForOneThroughThirtyTwoNodes() {
        for count in 1...32 {
            let nodes = (0..<count).map { index in
                node(name: String(format: "node-%02d", index), tier: GPUTier.allCases[index % GPUTier.allCases.count], gpuCount: (index % 8) + 1)
            }
            let result = CityAtlasLayout.place(snapshot: snapshot(nodes))
            XCTAssertEqual(result.plots.count, nodes.reduce(0) { $0 + max(1, $1.gpuCount) }, "count=\(count)")
            XCTAssertEqual(Set(result.plots.map(\.id)).count, result.plots.count, "count=\(count)")
            XCTAssertEqual(Set(result.blocks.map(\.id)), Set(nodes.map(\.id)), "count=\(count)")
        }
    }

    func testPlaceIsDeterministicAndKeepsStableDistrictIDs() {
        let input = snapshot([
            node(name: "a100-b", tier: .a100, gpuCount: 2),
            node(name: "h200-a", tier: .h200, gpuCount: 4),
            node(name: "a100-a", tier: .a100, gpuCount: 1),
        ])
        let first = CityAtlasLayout.place(snapshot: input)
        let second = CityAtlasLayout.place(snapshot: input)

        XCTAssertEqual(first.plots.map(\.id), ["h200-a-gpu1", "h200-a-gpu2", "h200-a-gpu3", "h200-a-gpu4", "a100-a", "a100-b-gpu1", "a100-b-gpu2"])
        XCTAssertEqual(first.plots.map { [$0.x, $0.y, $0.w, $0.d] }, second.plots.map { [$0.x, $0.y, $0.w, $0.d] })
        XCTAssertEqual(first.blocks.map { [$0.bounds.x, $0.bounds.y, $0.bounds.w, $0.bounds.d] }, second.blocks.map { [$0.bounds.x, $0.bounds.y, $0.bounds.w, $0.bounds.d] })
        XCTAssertEqual(first.avenue.map { [$0.0, $0.1] }, second.avenue.map { [$0.0, $0.1] })
    }

    func testGeneratedGeometryPropsAreStableWhenOnlyAllocationAndJobsDiffer() {
        let idle = CityScape.build(snapshot: snapshot([
            node(name: "phase-23", tier: .h200, gpuCount: 2, used: 0, jobs: []),
        ]))
        let active = CityScape.build(snapshot: snapshot([
            node(name: "phase-23", tier: .h200, gpuCount: 2, used: 2, jobs: [
                ClusterJob(
                    id: "job-100",
                    user: "alice",
                    name: "train",
                    state: "RUNNING",
                    elapsedSeconds: 120,
                    limitSeconds: 600,
                    remainingSeconds: 480,
                    nodeList: "phase-23",
                    reason: ""
                ),
            ]),
        ]))

        XCTAssertNotEqual(idle.plots.map(\.mode), active.plots.map(\.mode))
        XCTAssertEqual(layoutSignature(for: idle), layoutSignature(for: active))
    }

    func testPlaceStartsOneRowPerNonEmptyDistrictWithStyleGaps() throws {
        let result = CityAtlasLayout.place(snapshot: snapshot([
            node(name: "metro", tier: .h200, gpuCount: 1),
            node(name: "large", tier: .rtxpro6000, gpuCount: 1),
            node(name: "mid", tier: .a100, gpuCount: 1),
            node(name: "town", tier: .l4, gpuCount: 1),
            node(name: "hamlet", tier: .mig, gpuCount: 1),
        ]))
        let blockByID = Dictionary(uniqueKeysWithValues: result.blocks.map { ($0.id, $0) })
        let metro = try XCTUnwrap(blockByID["metro"])
        let large = try XCTUnwrap(blockByID["large"])
        let mid = try XCTUnwrap(blockByID["mid"])
        let town = try XCTUnwrap(blockByID["town"])
        let hamlet = try XCTUnwrap(blockByID["hamlet"])

        XCTAssertEqual(result.blocks.map { $0.bounds.x }, Array(repeating: CGFloat(84), count: 5))
        XCTAssertEqual(result.blocks.map(\.district), [.metropolis, .large, .mid, .town, .hamlet])
        XCTAssertEqual(Set(result.blocks.map { $0.bounds.y }).count, 5)
        XCTAssertEqual(metro.bounds.y, 94, accuracy: 1e-9)
        XCTAssertEqual(large.bounds.y, metro.bounds.y + metro.bounds.d + DistrictStyle.style(for: .metropolis).rowGap, accuracy: 1e-9)
        XCTAssertEqual(mid.bounds.y, large.bounds.y + large.bounds.d + DistrictStyle.style(for: .large).rowGap, accuracy: 1e-9)
        XCTAssertEqual(town.bounds.y, mid.bounds.y + mid.bounds.d + DistrictStyle.style(for: .mid).rowGap, accuracy: 1e-9)
        XCTAssertEqual(hamlet.bounds.y, town.bounds.y + town.bounds.d + DistrictStyle.style(for: .town).rowGap, accuracy: 1e-9)
    }

    func testAddingNodeOnlyShiftsLaterBlocksWithinSameDistrict() throws {
        let base = CityAtlasLayout.place(snapshot: snapshot([
            node(name: "metro-a", tier: .h200, gpuCount: 1),
            node(name: "metro-z", tier: .h200, gpuCount: 1),
            node(name: "mid-a", tier: .a100, gpuCount: 1),
            node(name: "town-a", tier: .l4, gpuCount: 1),
        ]))
        let expanded = CityAtlasLayout.place(snapshot: snapshot([
            node(name: "metro-a", tier: .h200, gpuCount: 1),
            node(name: "metro-b", tier: .h200, gpuCount: 1),
            node(name: "metro-z", tier: .h200, gpuCount: 1),
            node(name: "mid-a", tier: .a100, gpuCount: 1),
            node(name: "town-a", tier: .l4, gpuCount: 1),
        ]))
        let basePositions = blockPositionsByID(base.blocks)
        let expandedPositions = blockPositionsByID(expanded.blocks)

        XCTAssertEqual(expandedPositions["metro-a"], basePositions["metro-a"])
        XCTAssertEqual(expandedPositions["metro-b"]?[0], basePositions["metro-z"]?[0])
        XCTAssertGreaterThan(try XCTUnwrap(expandedPositions["metro-z"]?[0]), try XCTUnwrap(basePositions["metro-z"]?[0]))
        XCTAssertEqual(expandedPositions["mid-a"], basePositions["mid-a"])
        XCTAssertEqual(expandedPositions["town-a"], basePositions["town-a"])
    }

    func testAvenueLocalStreetsAndEntryPathsExposeRowEntriesForEveryBlock() throws {
        let input = snapshot([
            node(name: "metro", tier: .h200, gpuCount: 1),
            node(name: "mid", tier: .a100, gpuCount: 2),
            node(name: "town", tier: .l4, gpuCount: 1),
        ])
        let result = CityAtlasLayout.place(snapshot: input)
        let scape = CityScape.build(snapshot: input)
        let spineX = CGFloat(78)
        let finalRowEntryY = try XCTUnwrap(result.blocks.map { $0.bounds.y }.max()) - 4
        let historicalTerminusIndex = try XCTUnwrap(result.avenue.firstIndex {
            $0.0 == spineX && $0.1 == 90
        })
        let rowEntryYs = result.blocks.map { $0.bounds.y - 4 }.reduce(into: [CGFloat]()) { entries, rowY in
            if entries.last != rowY {
                entries.append(rowY)
            }
        }
        let spineYProgression = result.avenue[historicalTerminusIndex...]
            .filter { $0.0 == spineX }
            .map(\.1)
        let spineTraversals = result.avenue.indices.dropLast().compactMap { index -> [CGFloat]? in
            guard index >= historicalTerminusIndex else { return nil }
            let start = result.avenue[index]
            let end = result.avenue[result.avenue.index(after: index)]
            guard start.0 == spineX, end.0 == spineX, start.1 != end.1 else { return nil }
            return [start.1, end.1]
        }

        XCTAssertEqual(historicalTerminusIndex, 7)
        XCTAssertEqual(spineYProgression.first, rowEntryYs.first)
        XCTAssertEqual(spineYProgression, spineYProgression.sorted())
        XCTAssertEqual(spineTraversals, zip(rowEntryYs, rowEntryYs.dropFirst()).map { [$0.0, $0.1] })
        XCTAssertTrue(result.avenue.contains { $0.0 == spineX && $0.1 == finalRowEntryY })
        for (index, segment) in zip(result.avenue.indices, zip(result.avenue, result.avenue.dropFirst())) {
            let (start, end) = segment
            XCTAssertTrue(
                start.0 == end.0 || start.1 == end.1,
                "avenue segment \(index) must be axis-aligned: \(start) -> \(end)"
            )
        }
        for block in result.blocks {
            let rowY = block.bounds.y - 4
            let blockEntry = (x: block.bounds.x + block.bounds.w / 2, y: rowY)
            XCTAssertTrue(result.avenue.contains { $0.0 == spineX && $0.1 == rowY }, "\(block.id) row must touch spine")
            XCTAssertTrue(result.avenue.contains { $0.0 == blockEntry.x && $0.1 == blockEntry.y }, "\(block.id) must have avenue entry")

            let plots = result.plots.filter { $0.node.id == block.id }
            for plot in plots {
                let street = try XCTUnwrap(result.localStreets.first { path in
                    guard let start = path.first, let end = path.last else { return false }
                    return start.0 == blockEntry.x
                        && start.1 == blockEntry.y
                        && end.0 == plot.x + plot.w / 2
                        && end.1 == plot.y + plot.d / 2
                }, "\(plot.id) must have a local street from its row entry")
                XCTAssertTrue(zip(street, street.dropFirst()).allSatisfy { start, end in
                    start.0 == end.0 || start.1 == end.1
                })

                let entryPath = try XCTUnwrap(scape.entryPath(for: plot.id))
                XCTAssertTrue(entryPath.contains { $0.0 == blockEntry.x && $0.1 == blockEntry.y }, "\(plot.id) entry path must include its row entry")
                let finalPoint = try XCTUnwrap(entryPath.last)
                XCTAssertEqual(finalPoint.0, plot.lotCorner.x, accuracy: 1e-9)
                XCTAssertEqual(finalPoint.1, plot.lotCorner.y, accuracy: 1e-9)
            }
        }
    }

    func testPlaceKeepsEachNodesDistrictsInsideOneContiguousNonOverlappingBlock() {
        let result = CityAtlasLayout.place(snapshot: snapshot([
            node(name: "one", tier: .h200, gpuCount: 1),
            node(name: "two", tier: .a100, gpuCount: 2),
            node(name: "four", tier: .l4, gpuCount: 4),
            node(name: "eight", tier: .mig, gpuCount: 8),
        ]))

        for block in result.blocks {
            let blockRect = rect(block.bounds)
            let plots = result.plots.filter { $0.node.id == block.node.id }
            XCTAssertEqual(plots.map(\.id), block.plotIDs)
            XCTAssertEqual(plots.count, max(1, block.node.gpuCount))
            for (index, plot) in plots.enumerated() {
                let plotRect = CGRect(x: plot.x, y: plot.y, width: plot.w, height: plot.d)
                XCTAssertTrue(blockRect.contains(plotRect), "\(plot.id) escapes \(block.id)")
                for other in plots.dropFirst(index + 1) {
                    XCTAssertFalse(plotRect.intersects(CGRect(x: other.x, y: other.y, width: other.w, height: other.d)), "\(plot.id) overlaps \(other.id)")
                }
            }
            XCTAssertEqual(CGFloat(plots.reduce(0) { $0 + Int($1.w * $1.d) }), plots.reduce(0) { $0 + $1.w * $1.d })
        }
    }

    func testPlaceDoesNotOverlapBlocksAndPreservesTierThenNameOrderAlongSpine() {
        let result = CityAtlasLayout.place(snapshot: snapshot([
            node(name: "z-h200", tier: .h200, gpuCount: 1),
            node(name: "a-h200", tier: .h200, gpuCount: 1),
            node(name: "z-a100", tier: .a100, gpuCount: 1),
            node(name: "a-l4", tier: .l4, gpuCount: 1),
        ]))
        XCTAssertEqual(result.blocks.map { $0.node.name }, ["a-h200", "z-h200", "z-a100", "a-l4"])
        XCTAssertEqual(result.blocks.prefix(2).map { $0.bounds.x }, result.blocks.prefix(2).map { $0.bounds.x }.sorted())
        XCTAssertEqual(result.blocks.dropFirst(2).map { $0.bounds.x }, [84, 84])
        for (index, block) in result.blocks.enumerated() {
            for other in result.blocks.dropFirst(index + 1) {
                XCTAssertFalse(rect(block.bounds).intersects(rect(other.bounds)), "\(block.id) overlaps \(other.id)")
            }
        }

        let large = CityAtlasLayout.place(snapshot: snapshot((0..<32).map {
            node(name: String(format: "overflow-%02d", $0), tier: .h200, gpuCount: 8)
        }))
        XCTAssertGreaterThan(large.avenue.last?.0 ?? 0, 78)
    }

    func testGeneratedTiersCoverBuildingHeightWithIncreasingSetbacks() {
        let result = CityAtlasLayout.place(snapshot: snapshot([
            node(name: "tower", tier: .h200, gpuCount: 1),
            node(name: "campus", tier: .l4, gpuCount: 2),
        ]))

        for building in result.plots.flatMap(\.buildings) {
            XCTAssertEqual(building.tiers.first?.f0 ?? -1, 0, accuracy: CGFloat(1e-9))
            XCTAssertEqual(building.tiers.last?.f1 ?? -1, 1, accuracy: CGFloat(1e-9))
            XCTAssertTrue(zip(building.tiers, building.tiers.dropFirst()).allSatisfy { current, next in
                current.f0 < current.f1
                    && current.f1 == next.f0
                    && current.inset <= next.inset
            })
        }
    }

    func testGeneratedTreesStayOnTheirLotApronOutsideBuildingFootprints() {
        let result = CityAtlasLayout.place(snapshot: snapshot([
            node(name: "idle-campus", tier: .l4, gpuCount: 2),
        ]))

        for plot in result.plots where plot.mode == .lit || plot.mode == .vacant {
            XCTAssertTrue((3...7).contains(plot.trees.count), "\(plot.id) has an invalid tree count")
            let lot = CGRect(x: plot.x, y: plot.y, width: plot.w, height: plot.d)
            let footprints = plot.buildings.map {
                CGRect(x: plot.x + $0.ox, y: plot.y + $0.oy, width: $0.bw, height: $0.bd)
            }
            for tree in plot.trees {
                XCTAssertTrue(lot.contains(CGPoint(x: tree.x, y: tree.y)), "\(plot.id) tree escapes lot")
                XCTAssertFalse(footprints.contains { $0.contains(CGPoint(x: tree.x, y: tree.y)) }, "\(plot.id) tree overlaps footprint")
            }
        }
    }

    func testGeneratedBuildingsMatchKindCountsAndStayInsideLotMargin() {
        let result = CityAtlasLayout.place(snapshot: snapshot([
            node(name: "metro", tier: .h200, gpuCount: 1),
            node(name: "large", tier: .rtxpro6000, gpuCount: 1),
            node(name: "mid", tier: .a100, gpuCount: 1),
            node(name: "town", tier: .l4, gpuCount: 1),
            node(name: "hamlet", tier: .mig, gpuCount: 1),
        ]))
        let expected = [
            (count: 10, w: CGFloat(38), d: CGFloat(26)),
            (count: 8, w: CGFloat(30), d: CGFloat(20)),
            (count: 6, w: CGFloat(25), d: CGFloat(18)),
            (count: 4, w: CGFloat(19), d: CGFloat(14)),
            (count: 3, w: CGFloat(14), d: CGFloat(10)),
        ]

        for (plot, expectation) in zip(result.plots, expected) {
            XCTAssertEqual(plot.w, expectation.w, "\(plot.id)")
            XCTAssertEqual(plot.d, expectation.d, "\(plot.id)")
            XCTAssertEqual(plot.buildings.count, expectation.count, "\(plot.id)")
            for building in plot.buildings {
                XCTAssertGreaterThanOrEqual(building.ox, 1, "\(plot.id)")
                XCTAssertGreaterThanOrEqual(building.oy, 1, "\(plot.id)")
                XCTAssertLessThanOrEqual(building.ox + building.bw, plot.w - 1 + 1e-9, "\(plot.id)")
                XCTAssertLessThanOrEqual(building.oy + building.bd, plot.d - 1 + 1e-9, "\(plot.id)")
            }
        }
    }

    func testBuildingMassingUsesLargerCapacityScale() {
        XCTAssertEqual(CityAtlasLayout.buildingHeightScale, 1.2, accuracy: 1e-12)
    }

    func testMetropolisBuildingGridFootprintsDoNotOverlap() throws {
        let result = CityAtlasLayout.place(snapshot: snapshot([
            node(name: "metro", tier: .h200, gpuCount: 1),
        ]))
        let plot = try XCTUnwrap(result.plots.first)
        let footprints = plot.buildings.map {
            CGRect(x: $0.ox, y: $0.oy, width: $0.bw, height: $0.bd)
        }

        for (index, footprint) in footprints.enumerated() {
            for other in footprints.dropFirst(index + 1) {
                XCTAssertFalse(footprint.intersects(other))
            }
        }
    }

    func testLampPositionsAreSidewalkOffsetAndClearOfPlotFootprints() {
        let result = CityAtlasLayout.place(snapshot: snapshot([
            node(name: "lamp-block", tier: .a100, gpuCount: 4),
        ]))
        let lamps = CityAtlasLayout.lampPositions(localStreets: result.localStreets, plots: result.plots)

        XCTAssertFalse(lamps.isEmpty)
        for lamp in lamps {
            XCTAssertTrue(result.plots.allSatisfy { plot in
                !CGRect(x: plot.x, y: plot.y, width: plot.w, height: plot.d)
                    .insetBy(dx: -0.4, dy: -0.4)
                    .contains(CGPoint(x: lamp.0, y: lamp.1))
            }, "lamp must clear every plot footprint")
            XCTAssertGreaterThanOrEqual(
                result.localStreets.map { distance(from: lamp, to: $0) }.min() ?? 0,
                0.4,
                "lamp must be offset from the street centerline"
            )
        }
    }

    func testLampPositionsPreserveSixUnitSpacingOnStraightStreet() {
        let lamps = CityAtlasLayout.lampPositions(localStreets: [[(0, 0), (20, 0)]], plots: [])

        XCTAssertGreaterThan(lamps.count, 1)
        for (start, end) in zip(lamps, lamps.dropFirst()) {
            XCTAssertEqual(hypot(end.0 - start.0, end.1 - start.1), 6, accuracy: 0.1)
        }
    }

    func testMultiPlotBlocksReceiveInternalStreetsWithinGaps() {
        let result = CityAtlasLayout.place(snapshot: snapshot([
            node(name: "quad", tier: .a100, gpuCount: 4),
            node(name: "double", tier: .l4, gpuCount: 2),
        ]))
        let ingressStreetCount = result.plots.count
        let internalStreets = Array(result.localStreets.dropFirst(ingressStreetCount))

        XCTAssertFalse(internalStreets.isEmpty)
        for street in internalStreets {
            let block = try! XCTUnwrap(result.blocks.first { block in
                street.allSatisfy {
                    $0.0 >= block.bounds.x && $0.0 <= block.bounds.x + block.bounds.w
                        && $0.1 >= block.bounds.y && $0.1 <= block.bounds.y + block.bounds.d
                }
            })
            let plots = result.plots.filter { $0.node.id == block.id }
            XCTAssertTrue(street.allSatisfy { point in
                plots.allSatisfy { plot in
                    !CGRect(x: plot.x, y: plot.y, width: plot.w, height: plot.d)
                        .insetBy(dx: -0.25, dy: -0.25)
                        .contains(CGPoint(x: point.0, y: point.1))
                }
            })
        }
    }

    func testFixtureGenerationPreservesExistingBuildingGeometryAndTrees() {
        let result = CityAtlasLayout.place(snapshot: snapshot([
            node(name: "fixture-regression", tier: .h200, gpuCount: 1),
            node(name: "fixture-campus", tier: .l4, gpuCount: 1),
        ]))
        let signature = result.plots.map { plot in
            "\(plot.id):" + plot.buildings.map {
                String(format: "%.6f,%.6f,%.6f,%.6f,%.6f", $0.ox, $0.oy, $0.bw, $0.bd, $0.h)
            }.joined(separator: "|") + ";" + plot.trees.map {
                String(format: "%.6f,%.6f,%.6f", $0.x, $0.y, $0.size)
            }.joined(separator: "|")
        }.joined(separator: "\n")

        XCTAssertEqual(signature, """
fixture-regression:2.578111,1.661411,6.537554,7.237237,8.500634|11.718646,1.829340,6.444702,5.508334,7.905174|19.000000,1.939873,8.154873,5.718143,7.504783|28.669126,1.893944,8.322591,6.989512,5.545447|2.266870,9.000000,7.576659,6.845652,4.690678|10.190539,9.558749,7.688119,5.527589,8.715693|19.035453,9.060945,8.136457,6.579245,12.555531|29.196977,10.298365,6.630378,5.475202,12.736131|1.823635,17.000000,6.763083,6.808863,4.826994|10.000000,19.032919,8.286001,5.926343,9.831526;86.471828,97.388088,0.332395|104.415953,112.000127,0.360366
fixture-campus:2.866207,1.554918,5.968414,4.580775,2.371895|10.110614,1.101325,7.889386,5.063631,3.286686|2.164823,8.164194,7.310895,4.343946,6.274846|10.560412,7.000000,7.439588,4.604974,3.894202;84.358317,134.459164,0.285573|90.199311,141.859028,0.237802|102.239039,142.828915,0.350426|94.481482,144.859681,0.264785|96.249563,134.820219,0.230114|85.593524,138.491349,0.314046|89.978798,135.060988,0.293697
""")
    }
    func testBuildingDefaultsHaveNoFixturesOrNeonSign() {
        let facade = RGB(r: 100, g: 100, b: 100)
        let building = BuildingSpec(ox: 1, oy: 2, bw: 3, bd: 4, h: 5, crackSeed: false, facade: facade)

        XCTAssertEqual(building.facade, facade)
        XCTAssertEqual(building.fixtures, [])
        XCTAssertNil(building.neonSign)
    }

    func testFixtureAndNeonGenerationIsDeterministicAndHasOneRadarDish() {
        let input = snapshot([
            node(name: "tower", tier: .h200, gpuCount: 2),
            node(name: "campus", tier: .a100, gpuCount: 1),
        ])
        let first = CityAtlasLayout.place(snapshot: input)
        let second = CityAtlasLayout.place(snapshot: input)
        let buildings = first.plots.flatMap(\.buildings)

        XCTAssertEqual(first.plots.flatMap(\.buildings).map(\.fixtures), second.plots.flatMap(\.buildings).map(\.fixtures))
        XCTAssertEqual(first.plots.flatMap(\.buildings).map(\.neonSign), second.plots.flatMap(\.buildings).map(\.neonSign))
        XCTAssertEqual(buildings.flatMap(\.fixtures).filter { if case .radarDish = $0 { true } else { false } }.count, 1)
        for building in buildings {
            let roofInset = building.tiers.last?.inset ?? 0
            for fixture in building.fixtures {
                if case let .acUnit(dx, dy) = fixture {
                    XCTAssertLessThanOrEqual(abs(dx), max(0, building.bw / 2 - roofInset))
                    XCTAssertLessThanOrEqual(abs(dy), max(0, building.bd / 2 - roofInset))
                }
            }
        }
    }
    private func distance(from point: (CGFloat, CGFloat), to street: [(CGFloat, CGFloat)]) -> CGFloat {
        zip(street, street.dropFirst()).map { start, end in
            let dx = end.0 - start.0, dy = end.1 - start.1
            let lengthSquared = dx * dx + dy * dy
            guard lengthSquared > 0 else { return hypot(point.0 - start.0, point.1 - start.1) }
            let t = min(1, max(0, ((point.0 - start.0) * dx + (point.1 - start.1) * dy) / lengthSquared))
            return hypot(point.0 - (start.0 + dx * t), point.1 - (start.1 + dy * t))
        }.min() ?? .greatestFiniteMagnitude
    }
    private func snapshot(_ nodes: [ClusterNode]) -> ClusterSnapshot {
        ClusterSnapshot(generatedAt: .distantPast, nodes: nodes, pending: [])
    }

    private func node(name: String, tier: GPUTier, gpuCount: Int) -> ClusterNode {
        ClusterNode(name: name, gpuType: tier.shortLabel, profile: tier.rawValue, vramGB: 80, gpuCount: gpuCount, state: "idle", status: .idle, stateLabel: "idle", jobs: [])
    }

    private func node(name: String, tier: GPUTier, gpuCount: Int, used: Int, jobs: [ClusterJob]) -> ClusterNode {
        ClusterNode(
            name: name,
            gres: [GPUResource(gpuType: tier.shortLabel, profile: tier.rawValue, vramGB: 80, count: gpuCount, used: used)],
            state: "idle",
            status: .idle,
            stateLabel: "idle",
            jobs: jobs
        )
    }

    private func layoutSignature(for scape: CityScape) -> [PlotLayoutSignature] {
        scape.plots.map { plot in
            PlotLayoutSignature(
                id: plot.id,
                frame: [plot.x, plot.y, plot.w, plot.d],
                buildings: plot.buildings,
                trees: plot.trees,
                shops: plot.shops
            )
        }
    }

    private func rect(_ bounds: (x: CGFloat, y: CGFloat, w: CGFloat, d: CGFloat)) -> CGRect {
        CGRect(x: bounds.x, y: bounds.y, width: bounds.w, height: bounds.d)
    }

    private func blockPositionsByID(_ blocks: [CityBlock]) -> [String: [CGFloat]] {
        Dictionary(uniqueKeysWithValues: blocks.map {
            ($0.id, [$0.bounds.x, $0.bounds.y, $0.bounds.w, $0.bounds.d])
        })
    }

    func testPlaceConnectsEveryDistrictToItsBlocksArterialEntryWithAxisAlignedLocalStreet() {
        let result = CityAtlasLayout.place(snapshot: snapshot([
            node(name: "double", tier: .a100, gpuCount: 2),
            node(name: "quad", tier: .l4, gpuCount: 4),
        ]))
        XCTAssertGreaterThan(result.localStreets.count, result.plots.count)

        for (plot, street) in zip(result.plots, result.localStreets.prefix(result.plots.count)) {
            let block = try! XCTUnwrap(result.blocks.first { $0.id == plot.node.id })
            let first = try! XCTUnwrap(street.first)
            let last = try! XCTUnwrap(street.last)
            let entry = (x: block.bounds.x + block.bounds.w / 2, y: block.bounds.y - 4)
            let centre = (x: plot.x + plot.w / 2, y: plot.y + plot.d / 2)
            XCTAssertEqual(first.0, entry.x, accuracy: 1e-9)
            XCTAssertEqual(first.1, entry.y, accuracy: 1e-9)
            XCTAssertEqual(last.0, centre.x, accuracy: 1e-9)
            XCTAssertEqual(last.1, centre.y, accuracy: 1e-9)
            XCTAssertTrue(result.avenue.contains { $0.0 == entry.x && $0.1 == entry.y })
            XCTAssertTrue(zip(street, street.dropFirst()).allSatisfy { start, end in
                start.0 == end.0 || start.1 == end.1
            })
            let blockRect = rect(block.bounds)
            XCTAssertTrue(street.dropFirst().allSatisfy { point in
                blockRect.contains(CGPoint(x: point.0, y: point.1))
            })
        }
    }
}

private struct PlotLayoutSignature: Equatable {
    let id: String
    let frame: [CGFloat]
    let buildings: [BuildingSpec]
    let trees: [Tree]
    let shops: [ShopSpec]
}
