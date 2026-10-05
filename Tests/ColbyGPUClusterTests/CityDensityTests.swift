import XCTest
@testable import ColbyGPUCluster

final class CityDensityTests: XCTestCase {
    private func job(id: String, elapsed: Int?, limit: Int?) -> ClusterJob {
        ClusterJob(
            id: id,
            user: "user-\(id)",
            name: "train-\(id)",
            state: "RUNNING",
            elapsedSeconds: elapsed,
            limitSeconds: limit,
            remainingSeconds: nil,
            nodeList: "n1",
            reason: "None"
        )
    }

    private func node(jobs: [ClusterJob]) -> ClusterNode {
        ClusterNode(
            name: "n1",
            gres: [GPUResource(gpuType: "h200", profile: "h200", vramGB: 141, count: 1, used: jobs.isEmpty ? 0 : 1)],
            state: "up",
            status: jobs.isEmpty ? .idle : .busy,
            stateLabel: "up",
            jobs: jobs
        )
    }

    func testStageMapsProgressDecilesWithExactBoundaries() {
        XCTAssertEqual(CityDensity.stage(progress: nil), 0)
        XCTAssertEqual(CityDensity.stage(progress: -0.2), 0)
        XCTAssertEqual(CityDensity.stage(progress: 0), 0)
        XCTAssertEqual(CityDensity.stage(progress: 0.0999), 0)
        XCTAssertEqual(CityDensity.stage(progress: 0.1), 1)
        XCTAssertEqual(CityDensity.stage(progress: 0.55), 5)
        XCTAssertEqual(CityDensity.stage(progress: 0.9999), 9)
        XCTAssertEqual(CityDensity.stage(progress: 1), 10)
        XCTAssertEqual(CityDensity.stage(progress: 3.5), 10)
        XCTAssertEqual(CityDensity.stage(progress: .nan), 0)
        XCTAssertEqual(CityDensity.stage(progress: .infinity), 0)
    }

    func testNodeStageUsesHighestValidRunningJobProgress() {
        XCTAssertEqual(CityDensity.stage(for: node(jobs: [])), 0)
        // Jobs without a wall-time limit contribute nothing.
        XCTAssertEqual(CityDensity.stage(for: node(jobs: [job(id: "a", elapsed: 500, limit: nil)])), 0)
        XCTAssertEqual(
            CityDensity.stage(for: node(jobs: [
                job(id: "a", elapsed: 20, limit: 100),
                job(id: "b", elapsed: 87, limit: 100),
                job(id: "c", elapsed: nil, limit: 100),
            ])),
            8
        )
    }

    func testRevealStagesKeepBaselineAndSpreadExtrasMonotonically() {
        // Baseline elements stay at stage zero.
        for index in 0..<3 {
            XCTAssertEqual(CityDensity.revealStage(index: index, baseline: 3, total: 10), 0)
        }
        let extras = (3..<10).map { CityDensity.revealStage(index: $0, baseline: 3, total: 10) }
        XCTAssertEqual(extras, extras.sorted(), "reveal order must follow layout order")
        XCTAssertTrue(extras.allSatisfy { (1...10).contains($0) }, "extras spread inside 1...10, got \(extras)")
        XCTAssertEqual(extras.first, 1, "first extra unlocks at the first boundary")
        // A plot whose layout has no extras never reveals anything new.
        XCTAssertEqual(CityDensity.revealStage(index: 2, baseline: 3, total: 3), 0)
    }

    func testVisibleTierCountRisesAndTopsOutByStageTen() {
        // Baseline buildings are always complete.
        XCTAssertEqual(CityDensity.visibleTierCount(revealStage: 0, tierCount: 3, stage: 0), 3)
        // Hidden until revealed.
        XCTAssertEqual(CityDensity.visibleTierCount(revealStage: 4, tierCount: 3, stage: 3), 0)
        // Rises one tier per stage from its reveal boundary.
        XCTAssertEqual(CityDensity.visibleTierCount(revealStage: 4, tierCount: 3, stage: 4), 1)
        XCTAssertEqual(CityDensity.visibleTierCount(revealStage: 4, tierCount: 3, stage: 5), 2)
        XCTAssertEqual(CityDensity.visibleTierCount(revealStage: 4, tierCount: 3, stage: 6), 3)
        // Late reveals compress so stage ten is always complete.
        XCTAssertEqual(CityDensity.visibleTierCount(revealStage: 10, tierCount: 3, stage: 10), 3)
        XCTAssertEqual(CityDensity.visibleTierCount(revealStage: 9, tierCount: 3, stage: 10), 3)
    }

    func testActivityFractionTrailsStructureAndReachesFullAtMaximum() {
        XCTAssertEqual(CityDensity.activityFraction(stage: 0), 0.35, accuracy: 1e-9)
        XCTAssertEqual(
            CityDensity.activityFraction(stage: 1),
            CityDensity.activityFraction(stage: 0),
            accuracy: 1e-9,
            "activity trails structure by one stage"
        )
        let fractions = (0...10).map { CityDensity.activityFraction(stage: $0) }
        XCTAssertEqual(fractions, fractions.sorted())
        XCTAssertEqual(CityDensity.activityFraction(stage: 10), 1, accuracy: 1e-9)
    }

    func testSignatureIsStableSortedAndOmitsBaselinePlots() {
        XCTAssertEqual(CityDensity.signature(stages: [:]), "")
        XCTAssertEqual(CityDensity.signature(stages: ["b": 0, "a": 0]), "")
        XCTAssertEqual(
            CityDensity.signature(stages: ["b": 3, "a": 10, "c": 0]),
            "a:10,b:3"
        )
    }

    // MARK: - Director transitions

    @MainActor
    private func scape(progress: Double?) -> CityScape {
        let jobs = progress.map { p in
            [job(id: "j", elapsed: Int(p * 1_000), limit: 1_000)]
        } ?? []
        let snapshot = ClusterSnapshot(
            generatedAt: Date(timeIntervalSinceReferenceDate: 700_000_000),
            nodes: [node(jobs: jobs)],
            pending: []
        )
        return CityScape.build(snapshot: snapshot)
    }

    @MainActor
    func testDirectorAnimatesRisesAndSettlesDropsImmediately() {
        let director = CityDirector()
        let t0 = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let first = scape(progress: 0.25)
        guard let plotID = first.plots.first(where: { $0.node.name == "n1" })?.id else {
            return XCTFail("expected a plot for node n1")
        }

        // First reconcile adopts the current stage silently: relaunching the
        // app over a half-done job must not replay construction.
        director.reconcile(scape: first, date: t0, reduceMotion: false, band: .city)
        XCTAssertEqual(director.effectiveStages(at: t0)[plotID], 2)
        XCTAssertTrue(director.activeDensityTransitions(at: t0).isEmpty)

        // A later rise starts one animated transition toward the target.
        let t1 = t0.addingTimeInterval(30)
        director.reconcile(scape: scape(progress: 0.55), date: t1, reduceMotion: false, band: .city)
        XCTAssertEqual(director.activeDensityTransitions(at: t1)[plotID]?.fromStage, 2)
        XCTAssertEqual(director.activeDensityTransitions(at: t1)[plotID]?.toStage, 5)
        XCTAssertEqual(director.effectiveStages(at: t1)[plotID], 2, "base keeps the settled stage while rising")

        // Expiry folds the finished stage into effective stages even before
        // the next reconcile, then reconcile retires the transition.
        let t2 = t1.addingTimeInterval(CityDirector.densityTransitionDuration + 0.1)
        XCTAssertEqual(director.effectiveStages(at: t2)[plotID], 5)
        XCTAssertTrue(director.activeDensityTransitions(at: t2).isEmpty)
        director.reconcile(scape: scape(progress: 0.55), date: t2, reduceMotion: false, band: .city)
        XCTAssertEqual(director.effectiveStages(at: t2)[plotID], 5)

        // A drop (job finished/vanished) settles down at once - no demolition.
        let t3 = t2.addingTimeInterval(30)
        director.reconcile(scape: scape(progress: nil), date: t3, reduceMotion: false, band: .city)
        XCTAssertEqual(director.effectiveStages(at: t3)[plotID], 0)
        XCTAssertTrue(director.activeDensityTransitions(at: t3).isEmpty)
    }
}
