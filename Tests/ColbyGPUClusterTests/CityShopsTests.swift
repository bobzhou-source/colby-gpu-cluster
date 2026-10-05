import CoreGraphics
import Foundation
import XCTest
@testable import ColbyGPUCluster

final class CityShopsTests: XCTestCase {
    func testShopGenerationIsDeterministic() {
        let input = snapshot([
            node(name: "commerce-a", tier: .h200, state: "alloc", gpuCount: 2),
            node(name: "commerce-b", tier: .a100, state: "mix", gpuCount: 1),
        ])

        let first = CityScape.build(snapshot: input)
        let second = CityScape.build(snapshot: input)

        XCTAssertEqual(first.plots.map(\.shops), second.plots.map(\.shops))
    }

    func testShopsAreLimitedToEligibleBuildingsAndStreetFacingEdges() {
        let scape = CityScape.build(snapshot: snapshot([
            node(name: "lit", tier: .h200, state: "alloc", gpuCount: 2),
            node(name: "half", tier: .a100, state: "mix", gpuCount: 2),
            node(name: "vacant", tier: .l4, state: "idle", gpuCount: 2),
            node(name: "closed", tier: .mig, state: "drain*", gpuCount: 2),
        ]))

        for plot in scape.plots {
            XCTAssertLessThanOrEqual(plot.shops.count, 2, plot.id)
            for shop in plot.shops {
                let building = try! XCTUnwrap(plot.buildings.first { building in
                    guard building.h <= 6 else { return false }
                    let x = plot.x + building.ox
                    let y = plot.y + building.oy
                    if shop.facingX {
                        return abs(shop.x - (x + building.bw)) < 1e-9 && shop.y >= y && shop.y <= y + building.bd
                    }
                    return abs(shop.y - (y + building.bd)) < 1e-9 && shop.x >= x && shop.x <= x + building.bw
                }, "\(plot.id) shop must be on an eligible building's street-facing edge")
                XCTAssertLessThanOrEqual(building.h, 6)
            }
        }
    }

    func testPlazasAreDeterministicAndKeepClearingsFreeOfBuildings() {
        let input = snapshot([
            node(name: "plaza-a", tier: .h200, state: "alloc", gpuCount: 4),
            node(name: "plaza-b", tier: .a100, state: "alloc", gpuCount: 2),
        ])
        let first = CityScape.build(snapshot: input)
        let second = CityScape.build(snapshot: input)

        XCTAssertEqual(first.plazas, second.plazas)
        XCTAssertEqual(first.plazas.map(\.blockID), Set(first.plazas.map(\.blockID)).sorted())
        XCTAssertFalse(first.plazas.isEmpty, "fixture blocks are large enough to host a courtyard plaza")
        for plaza in first.plazas {
            let clearArea = CGRect(x: plaza.x - 1.5, y: plaza.y - 1.5, width: 3, height: 3)
            let block = try! XCTUnwrap(first.blocks.first { $0.id == plaza.blockID })
            let host = first.plots.first { plot in
                block.plotIDs.contains(plot.id)
                    && CGRect(x: plot.x, y: plot.y, width: plot.w, height: plot.d).contains(CGPoint(x: plaza.x, y: plaza.y))
            }
            XCTAssertNotNil(host, "\(plaza.blockID) plaza must sit inside one of its block's plots")
            if let host {
                XCTAssertFalse(host.buildings.contains { building in
                    clearArea.intersects(CGRect(
                        x: host.x + building.ox,
                        y: host.y + building.oy,
                        width: building.bw,
                        height: building.bd
                    ))
                }, "\(plaza.blockID) plaza clearing overlaps a building")
            }
        }
    }

    func testShopDressingAndPlazaPoliciesFollowLODFade() {
        let lower = CityDetailLevel(scale: 2.0, band: .province)
        let middleProvince = CityDetailLevel(scale: 2.3, band: .province)
        let full = CityDetailLevel(scale: 2.6, band: .street)

        XCTAssertEqual(CityRenderPolicies.shopDressingOpacity(lod: lower), 0, accuracy: 1e-12)
        XCTAssertEqual(CityRenderPolicies.plazaOpacity(lod: lower), 0, accuracy: 1e-12)
        XCTAssertEqual(CityRenderPolicies.shopDressingOpacity(lod: middleProvince), 0.5, accuracy: 1e-12)
        XCTAssertEqual(CityRenderPolicies.plazaOpacity(lod: middleProvince), 0.5, accuracy: 1e-12)
        XCTAssertEqual(CityRenderPolicies.shopAwningOpacity(isOpen: true, lod: middleProvince), 0.46, accuracy: 1e-12)
        XCTAssertEqual(CityRenderPolicies.shopAwningOpacity(isOpen: false, lod: middleProvince), 0.175, accuracy: 1e-12)
        XCTAssertEqual(CityRenderPolicies.shopDressingOpacity(lod: full), 1, accuracy: 1e-12)
    }

    func testDoorGlowKeepsExistingBandGateForOpenShops() {
        XCTAssertFalse(CityRenderPolicies.shouldDrawShopDoorGlow(isOpen: true, band: .province))
        XCTAssertTrue(CityRenderPolicies.shouldDrawShopDoorGlow(isOpen: true, band: .city))
        XCTAssertTrue(CityRenderPolicies.shouldDrawShopDoorGlow(isOpen: true, band: .street))
        XCTAssertFalse(CityRenderPolicies.shouldDrawShopDoorGlow(isOpen: false, band: .street))
    }

    private func snapshot(_ nodes: [ClusterNode]) -> ClusterSnapshot {
        ClusterSnapshot(generatedAt: .distantPast, nodes: nodes, pending: [])
    }

    private func node(name: String, tier: GPUTier, state: String, gpuCount: Int) -> ClusterNode {
        ClusterNode(name: name, gpuType: tier.shortLabel, profile: tier.rawValue, vramGB: 80, gpuCount: gpuCount, state: state, status: .idle, stateLabel: state, jobs: [])
    }
}
