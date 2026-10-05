import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import ColbyGPUCluster

@MainActor final class CityLiveDetailTests: XCTestCase {
    func testWindowFillFractionUsesTheMostCompleteKnownJobAndDefaultsToZero() {
        let runningNode = node(jobs: [
            job(id: "running-low", elapsed: 15, limit: 100),
            job(id: "running-high", elapsed: 90, limit: 100),
            job(id: "unbounded", elapsed: nil, limit: nil),
        ])

        XCTAssertEqual(windowFillFraction(for: runningNode), 0.9, accuracy: 1e-12)
        XCTAssertEqual(windowFillFraction(for: node(jobs: [])), 0)
        XCTAssertEqual(windowFillFraction(for: node(jobs: [job(id: "unbounded", elapsed: nil, limit: nil)])), 0)
    }

    func testQueueCarCountHasOneCarForEveryPendingJob() {
        XCTAssertEqual(queueCarCount(pending: []), 0)
        XCTAssertEqual(queueCarCount(pending: [pending(id: "1"), pending(id: "2"), pending(id: "3"), pending(id: "4"), pending(id: "5")]), 5)
    }

    func testJobPlateLinesExcludeNonRunningJobs() {
        XCTAssertEqual(CityRenderer.jobPlateLines(node: node(jobs: [
            job(id: "queued", state: "PENDING"),
            job(id: "completed", state: "COMPLETED"),
        ])), [])
    }

    func testJobPlateLinesFormatRunningJobWithRemainingTime() {
        XCTAssertEqual(CityRenderer.jobPlateLines(node: node(jobs: [
            job(id: "job-1", elapsed: 120, limit: 600, remaining: 480),
        ])), ["job-1 alice · 2m · 8m left"])
    }

    func testJobPlateLinesUsesNoWallForUnboundedRunningJob() {
        XCTAssertEqual(CityRenderer.jobPlateLines(node: node(jobs: [
            job(id: "job-1", elapsed: nil, limit: nil, remaining: nil),
        ])), ["job-1 alice · 0m · no wall"])
    }

    func testJobPlateLinesLimitsRunningJobsAndReportsOverflow() {
        XCTAssertEqual(CityRenderer.jobPlateLines(node: node(jobs: [
            job(id: "job-1"),
            job(id: "job-2"),
            job(id: "job-3"),
        ])), [
            "job-1 alice · 1s · 9s left",
            "job-2 alice · 1s · 9s left",
            "+1 more",
        ])
    }
    func testCommuterQueueAnchorsPreserveAuthoredPositionsAndExtendForEveryPendingJob() {
        let scape = CityScape.build(snapshot: ClusterSnapshot(generatedAt: .distantPast, nodes: [], pending: []))
        let anchors = scape.commuterQueueAnchors(count: 6)

        XCTAssertEqual(anchors.count, 6)
        XCTAssertEqual(anchors[0].0, 76.4, accuracy: 1e-12)
        XCTAssertEqual(anchors[3].1, 97.2, accuracy: 1e-12)
        XCTAssertEqual(anchors[4].0, 76.4, accuracy: 1e-12)
        XCTAssertEqual(anchors[5].1, 101.0, accuracy: 1e-12)
    }

    func testSceneDimmingMapsEveryFreshnessStateExactly() {
        XCTAssertEqual(sceneDimming(for: .fresh), 0)
        XCTAssertEqual(sceneDimming(for: .refreshing), 0)
        XCTAssertEqual(sceneDimming(for: .stale), 0.35)
        XCTAssertEqual(sceneDimming(for: .unavailable), 1)
    }
    func testStoreRefreshStateUsesLoadingErrorAgeAndRefreshingFacts() {
        let now = Date(timeIntervalSince1970: 10_000)
        let store = ClusterStore()
        XCTAssertEqual(store.refreshState(at: now, staleAfter: 40), .unavailable)
        store.isRefreshing = true
        XCTAssertEqual(store.refreshState(at: now, staleAfter: 40), .refreshing)
        store.hasLoaded = true
        store.isRefreshing = false
        store.snapshot = ClusterSnapshot(generatedAt: now.addingTimeInterval(-41), nodes: [], pending: [])
        XCTAssertEqual(store.refreshState(at: now, staleAfter: 40), .stale)
        store.snapshot = ClusterSnapshot(generatedAt: now, nodes: [node(jobs: [])], pending: [])
        XCTAssertEqual(store.refreshState(at: now, staleAfter: 40), .fresh)
        store.isRefreshing = true
        XCTAssertEqual(store.refreshState(at: now, staleAfter: 40), .refreshing)
        store.errorMessage = "ssh unavailable"
        XCTAssertEqual(store.refreshState(at: now, staleAfter: 40), .stale)
    }


    func testAmbientTrafficCountIsQuietWhenIdleAndScalesWithLoad() {
        let jobs = [job(id: "1"), job(id: "2"), job(id: "3"), job(id: "4"), job(id: "5"), job(id: "6"), job(id: "7"), job(id: "8"), job(id: "9")]

        XCTAssertEqual(ambientTrafficCount(runningJobs: []), 0)
        XCTAssertEqual(ambientTrafficCount(runningJobs: Array(jobs.prefix(2))), 8)
        XCTAssertEqual(ambientTrafficCount(runningJobs: jobs), 18)
        XCTAssertLessThan(ambientTrafficCount(runningJobs: Array(jobs.prefix(3))), ambientTrafficCount(runningJobs: jobs))
    }



    func testCommuteCarColorsAreKeyedByUserNotJobID() {
        let date = Date(timeIntervalSinceReferenceDate: 1_000)
        let scape = CityScape.build(snapshot: ClusterSnapshot(
            generatedAt: date,
            nodes: [node(jobs: [
                job(id: "same-a", user: "alice"),
                job(id: "same-b", user: "alice"),
            ])],
            pending: []
        ))
        let director = CityDirector()

        director.reconcile(scape: scape, date: date, reduceMotion: false, band: .street)

        XCTAssertEqual(director.cars.count, 2)
        XCTAssertEqual(Set(director.cars.map { colorSignature($0.colorToken.color) }), Set([colorSignature(carColor(for: "alice"))]))
    }


    func testBlockScopedStreetLifeUsesLocalDeduplicatedRunningJobs() {
        let date = Date(timeIntervalSinceReferenceDate: 1_000)
        let busyJobs = [
            job(id: "busy-a", user: "alice"),
            job(id: "busy-b", user: "bob"),
        ]
        let busyNode = node(name: "busy-node", jobs: busyJobs)
        let idleNode = node(name: "idle-node", status: .idle, jobs: [])
        let busyBlock = CityBlock(
            node: busyNode,
            district: .mid,
            plotIDs: ["busy-a", "busy-b"],
            bounds: (x: 0, y: 0, w: 40, d: 20)
        )
        let idleBlock = CityBlock(
            node: idleNode,
            district: .mid,
            plotIDs: ["idle"],
            bounds: (x: 50, y: 0, w: 20, d: 20)
        )
        let plots = [
            plot(node: busyNode, id: "busy-a", x: 0, y: 0, shops: [shop(x: 3, y: 4)]),
            plot(node: busyNode, id: "busy-b", x: 20, y: 0, shops: [shop(x: 23, y: 4)]),
            plot(node: idleNode, id: "idle", x: 50, y: 0, shops: [shop(x: 53, y: 4)]),
        ]

        let busyCount = CityRenderer.runningJobCount(in: busyBlock, plots: plots)
        let idleCount = CityRenderer.runningJobCount(in: idleBlock, plots: plots)
        let routeMetrics = CityWhimsy.RouteMetrics([(0, 0), (10, 0)])
        let busyPedestrians = CityWhimsy.pedestrians(
            plotID: "busy-a",
            count: busyCount,
            routeMetrics: routeMetrics,
            date: date,
            reduceMotion: true
        )
        let idlePedestrians = CityWhimsy.pedestrians(
            plotID: "idle",
            count: idleCount,
            routeMetrics: routeMetrics,
            date: date,
            reduceMotion: true
        )
        let busyShoppers = CityWhimsy.shoppers(
            shopStops: CityRenderer.shopStops(in: busyBlock, plots: plots),
            runningJobCount: busyCount,
            date: date,
            reduceMotion: true
        )
        let idleShoppers = CityWhimsy.shoppers(
            shopStops: CityRenderer.shopStops(in: idleBlock, plots: plots),
            runningJobCount: idleCount,
            date: date,
            reduceMotion: true
        )

        XCTAssertEqual(busyCount, 2)
        XCTAssertEqual(idleCount, 0)
        XCTAssertGreaterThan(busyPedestrians.count, idlePedestrians.count)
        XCTAssertGreaterThan(busyShoppers.count, idleShoppers.count)
    }

    func testDirectorKeepsSeparateCarsForSameJobAcrossGPUPlots() {
        let date = Date(timeIntervalSinceReferenceDate: 1_000)
        let scape = CityScape.build(snapshot: ClusterSnapshot(
            generatedAt: date,
            nodes: [
                ClusterNode(
                    name: "a100-01",
                    gpuType: "A100",
                    profile: "a100",
                    vramGB: 80,
                    gpuCount: 2,
                    state: "alloc",
                    status: .busy,
                    stateLabel: "Allocated",
                    jobs: [job(id: "shared-job")]
                )
            ],
            pending: []
        ))
        let director = CityDirector()

        director.reconcile(scape: scape, date: date, reduceMotion: false, band: .street)
        director.reconcile(scape: scape, date: date.addingTimeInterval(1), reduceMotion: false, band: .street)

        XCTAssertEqual(director.cars.count, 2)
        XCTAssertEqual(Set(director.cars.map(\.id)).count, 2)
        XCTAssertEqual(Set(director.cars.map(\.jobID)), ["shared-job"])
        XCTAssertEqual(Set(director.cars.map(\.plotID)).count, 2)
    }

    private func node(name: String = "a100-01", status: NodeStatus = .busy, jobs: [ClusterJob]) -> ClusterNode {
        ClusterNode(name: name, gpuType: "A100", profile: "a100", vramGB: 80, gpuCount: 1, state: "alloc", status: status, stateLabel: "Allocated", jobs: jobs)
    }

    private func job(id: String, user: String = "alice", state: String = "RUNNING", elapsed: Int? = 1, limit: Int? = 10, remaining: Int? = 9) -> ClusterJob {
        ClusterJob(id: id, user: user, name: "train", state: state, elapsedSeconds: elapsed, limitSeconds: limit, remainingSeconds: remaining, nodeList: "a100-01", reason: "a100-01")
    }

    private func pending(id: String) -> PendingJob {
        PendingJob(id: id, user: "alice", name: "queued", reason: "Resources", limitSeconds: 3_600)
    }

    private func plot(node: ClusterNode, id: String, x: CGFloat, y: CGFloat, shops: [ShopSpec]) -> CityPlot {
        CityPlot(
            node: node,
            gpuIndex: 1,
            gpuCount: 1,
            plotID: id,
            x: x,
            y: y,
            w: 18,
            d: 18,
            mode: .lit,
            buildings: [BuildingSpec(ox: 2, oy: 2, bw: 4, bd: 5, h: 8, crackSeed: false, facade: RGB(r: 100, g: 110, b: 120))],
            hasCrane: false,
            shops: shops
        )
    }

    private func shop(x: CGFloat, y: CGFloat) -> ShopSpec {
        ShopSpec(kind: .cafe, x: x, y: y, facingX: true, accent: 0)
    }

    private func colorSignature(_ color: Color) -> String {
        let converted = NSColor(color).usingColorSpace(.sRGB)!
        return String(
            format: "%.3f:%.3f:%.3f:%.3f",
            converted.redComponent,
            converted.greenComponent,
            converted.blueComponent,
            converted.alphaComponent
        )
    }
}
