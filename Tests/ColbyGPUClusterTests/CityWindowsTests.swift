import Foundation
import XCTest
@testable import ColbyGPUCluster

final class CityWindowsTests: XCTestCase {
    func testJobPressureControlsSundownLitFraction() {
        let litCount = (0..<400).count {
            CityWindows.isLit(buildingSeed: 0x1234_5678, sequence: $0, t: 0.78, load: 0.7)
        }

        XCTAssertGreaterThanOrEqual(Double(litCount) / 400, 0.55)
        XCTAssertLessThanOrEqual(Double(litCount) / 400, 0.75)
    }

    func testPressuredBuildingsPeakAtSundownAndMostlySleepByMidnight() {
        let sundown = CityWindows.occupancyFraction(jobPressure: 1, t: 0.78)
        let midnight = CityWindows.occupancyFraction(jobPressure: 1, t: 0)
        let idle = CityWindows.occupancyFraction(jobPressure: 0, t: 0.78)

        XCTAssertGreaterThanOrEqual(sundown, 0.85)
        XCTAssertLessThanOrEqual(midnight, 0.35)
        XCTAssertLessThan(midnight, sundown)
        XCTAssertEqual(idle, 0)
    }

    func testOccupancyRemainsMonotonicWithJobPressureAcrossDayCycle() {
        for t in stride(from: 0.0, to: 1.0, by: 0.025) {
            XCTAssertLessThanOrEqual(
                CityWindows.occupancyFraction(jobPressure: 0.25, t: t),
                CityWindows.occupancyFraction(jobPressure: 0.75, t: t)
            )
        }
    }

    func testHigherLoadIsASupersetOfLowerLoad() {
        for t in stride(from: 0.0, to: 1.0, by: 0.025) {
            for sequence in 0..<512 {
                let low = CityWindows.isLit(buildingSeed: 0xCAFE_BABE, sequence: sequence, t: t, load: 0.35)
                let high = CityWindows.isLit(buildingSeed: 0xCAFE_BABE, sequence: sequence, t: t, load: 0.85)
                XCTAssertFalse(low && !high, "sequence=\(sequence), t=\(t)")
            }
        }
    }

    func testLightingIsDeterministic() {
        let first = (0..<96).map { CityWindows.isLit(buildingSeed: 0x1234_5678, sequence: $0, t: 0.81, load: 0.75) }
        let second = (0..<96).map { CityWindows.isLit(buildingSeed: 0x1234_5678, sequence: $0, t: 0.81, load: 0.75) }

        XCTAssertEqual(first, second)
    }

    func testParticipatingWindowBlinksOff() {
        let seed = 0x0BAD_F00D
        let occupancy = CityWindows.occupancyFraction(jobPressure: 0.7, t: 0.78)
        let sequence = try! XCTUnwrap((0..<400).first {
            CityRandom.hashFraction(seed, $0) < occupancy
        })

        let blinkedOff = stride(from: 0.75, to: 0.85, by: 0.0005).contains { t in
            !CityWindows.isLit(buildingSeed: seed, sequence: sequence, t: t, load: 0.7)
        }

        XCTAssertTrue(blinkedOff)
    }

    func testConcurrentActiveJobsIncreaseWindowParticipationRegardlessOfProgress() {
        let fewActive = node(gpuCount: 4, jobs: [job(id: "nearly-finished", elapsed: 99, limit: 100)])
        let manyActive = node(gpuCount: 4, jobs: [
            job(id: "early-1", elapsed: 1, limit: 100),
            job(id: "early-2", elapsed: 2, limit: 100),
            job(id: "early-3", elapsed: 3, limit: 100),
        ])
        let fewLoad = CityWindows.runningJobPressure(for: fewActive)
        let manyLoad = CityWindows.runningJobPressure(for: manyActive)
        let fewLit = (0..<800).count {
            CityWindows.isLit(buildingSeed: 0x5EED, sequence: $0, t: 0.4, load: fewLoad)
        }
        let manyLit = (0..<800).count {
            CityWindows.isLit(buildingSeed: 0x5EED, sequence: $0, t: 0.4, load: manyLoad)
        }

        XCTAssertEqual(fewLoad, 0.25, accuracy: 1e-12)
        XCTAssertEqual(manyLoad, 0.75, accuracy: 1e-12)
        XCTAssertGreaterThanOrEqual(manyLit, fewLit)
    }

    func testFloorLoadMultiplierDefaultsToNeutralWithoutProgress() {
        XCTAssertEqual(CityWindows.floorLoadMultiplier(progress: nil, rowFraction: 0.9), 1.0, accuracy: 1e-12)
    }

    func testFloorLoadMultiplierLightsProgressBoundaryAndDimsAboveIt() {
        XCTAssertEqual(CityWindows.floorLoadMultiplier(progress: 0.5, rowFraction: 0.5), 1.35, accuracy: 1e-12)
        XCTAssertEqual(CityWindows.floorLoadMultiplier(progress: 0.5, rowFraction: 0.500_001), 0.45, accuracy: 1e-12)
    }

    func testFloorLoadMultiplierClampsProgress() {
        XCTAssertEqual(CityWindows.floorLoadMultiplier(progress: -1, rowFraction: 0), 1.35, accuracy: 1e-12)
        XCTAssertEqual(CityWindows.floorLoadMultiplier(progress: 2, rowFraction: 1), 1.35, accuracy: 1e-12)
    }

    func testOccupancySignatureSeparatesBuildingStatesAtEqualRunningJobCount() {
        // One RUNNING job on the same two-GPU H200 node every time; only the
        // per-plot operational state varies, yet each state must mint a
        // distinct retained-facade cache identity.
        let signatures = Set([
            CityWindows.occupancySignature(for: mixedScape(status: .busy, used: 1)),
            CityWindows.occupancySignature(for: mixedScape(status: .busy, used: 2)),
            CityWindows.occupancySignature(for: mixedScape(status: .drain, used: 1)),
            CityWindows.occupancySignature(for: mixedScape(status: .unknown, used: 1)),
        ])

        XCTAssertEqual(signatures.count, 4)
    }


    /// Mixed-GRES two-node scape: an H200 node whose two plots carry the
    /// state under test, plus a constant fully-allocated L4 node.
    private func mixedScape(status: NodeStatus, used: Int) -> CityScape {
        let h200 = ClusterNode(
            name: "h200-01",
            gres: [GPUResource(gpuType: "H200", profile: "h200", vramGB: 141, count: 2, used: used)],
            state: status.rawValue,
            status: status,
            stateLabel: status.rawValue,
            jobs: [job(id: "h200-job", elapsed: 30, limit: 100)]
        )
        let l4 = ClusterNode(
            name: "l4-01",
            gres: [GPUResource(gpuType: "L4", profile: "l4", vramGB: 48, count: 1, used: 1)],
            state: "alloc",
            status: .busy,
            stateLabel: "Allocated",
            jobs: [job(id: "l4-job", elapsed: 5, limit: 100)]
        )

        return CityScape.build(snapshot: ClusterSnapshot(generatedAt: .distantPast, nodes: [h200, l4], pending: []))
    }

    private func node(gpuCount: Int, jobs: [ClusterJob]) -> ClusterNode {
        ClusterNode(
            name: "n15",
            gpuType: "H200",
            profile: "h200",
            vramGB: 141,
            gpuCount: gpuCount,
            state: "alloc",
            status: .busy,
            stateLabel: "Allocated",
            jobs: jobs
        )
    }

    private func job(id: String, elapsed: Int, limit: Int) -> ClusterJob {
        ClusterJob(
            id: id,
            user: "alice",
            name: "train",
            state: "RUNNING",
            elapsedSeconds: elapsed,
            limitSeconds: limit,
            remainingSeconds: limit - elapsed,
            nodeList: "n15",
            reason: ""
        )
    }
}
