import Foundation
import XCTest
@testable import ColbyGPUCluster

@MainActor final class CityWhimsyTests: XCTestCase {
    private let date = Date(timeIntervalSinceReferenceDate: 12_345)

    func testWhimsyOutputsAreDeterministicForIdenticalInputs() {
        let building = BuildingSpec(ox: 2, oy: 3, bw: 4, bd: 5, h: 9, crackSeed: false, facade: RGB(r: 100, g: 100, b: 100))
        let path: [(CGFloat, CGFloat)] = [(1, 2), (5, 2), (5, 6)]
        let routeMetrics = CityWhimsy.RouteMetrics(path)

        XCTAssertEqual(
            CityWhimsy.smokePuffs(plotID: "plot-a", plotOrigin: CGPoint(x: 20, y: 30), building: building, load: 0.75, date: date, reduceMotion: false),
            CityWhimsy.smokePuffs(plotID: "plot-a", plotOrigin: CGPoint(x: 20, y: 30), building: building, load: 0.75, date: date, reduceMotion: false)
        )
        XCTAssertEqual(CityWhimsy.ferry(date: date, reduceMotion: false), CityWhimsy.ferry(date: date, reduceMotion: false))
        XCTAssertEqual(CityWhimsy.antennaBlink(plotID: "plot-a", date: date), CityWhimsy.antennaBlink(plotID: "plot-a", date: date))
        XCTAssertEqual(
            CityWhimsy.pedestrians(plotID: "plot-a", count: 3, routeMetrics: routeMetrics, date: date, reduceMotion: false),
            CityWhimsy.pedestrians(plotID: "plot-a", count: 3, routeMetrics: routeMetrics, date: date, reduceMotion: false)
        )
        XCTAssertEqual(CityWhimsy.searchlightAngle(plotID: "plot-a", date: date), CityWhimsy.searchlightAngle(plotID: "plot-a", date: date))
    }

    func testActivitySceneIsDeterministicAndClearsFootprints() throws {
        let footprints = [CGRect(x: 12, y: 12, width: 6, height: 6)]
        let first = CityWhimsy.activityScene(plotID: "plot-a", x: 10, y: 10, w: 14, d: 12, footprints: footprints)
        let second = CityWhimsy.activityScene(plotID: "plot-a", x: 10, y: 10, w: 14, d: 12, footprints: footprints)

        XCTAssertEqual(first, second)
        let scene = try XCTUnwrap(first)
        XCTAssertGreaterThanOrEqual(scene.x, 10)
        XCTAssertLessThanOrEqual(scene.x, 24)
        XCTAssertGreaterThanOrEqual(scene.y, 10)
        XCTAssertLessThanOrEqual(scene.y, 22)
        for footprint in footprints {
            XCTAssertFalse(
                footprint
                    .insetBy(dx: -CityWhimsy.activityClearance, dy: -CityWhimsy.activityClearance)
                    .contains(CGPoint(x: scene.x, y: scene.y)),
                "activity anchor sits inside an inflated building footprint"
            )
        }
    }

    func testActivitySceneReturnsNilWhenEveryCornerIsBlocked() {
        // One footprint covering the whole plot leaves no clear apron corner.
        let blocked = CityWhimsy.activityScene(
            plotID: "plot-b",
            x: 0,
            y: 0,
            w: 10,
            d: 10,
            footprints: [CGRect(x: -2, y: -2, width: 14, height: 14)]
        )
        XCTAssertNil(blocked)

        // Plots too small for the apron inset never host a scene.
        XCTAssertNil(CityWhimsy.activityScene(plotID: "plot-c", x: 0, y: 0, w: 3.5, d: 8, footprints: []))
    }

    func testActivityKindVariesAcrossPlotIDs() {
        let kinds = Set((0..<24).compactMap { index in
            CityWhimsy.activityScene(plotID: "plot-\(index)", x: 0, y: 0, w: 16, d: 14, footprints: []).map(\.kind)
        })
        XCTAssertGreaterThanOrEqual(kinds.count, 3, "hash should spread scenes across several activity kinds")
    }

    func testBirdsAreDeterministicAndUseExactVFormationOffsets() {
        let flightDate = Date(timeIntervalSinceReferenceDate: 45 * 0.25)
        let birds = CityWhimsy.birds(date: flightDate, reduceMotion: false)

        XCTAssertEqual(birds, CityWhimsy.birds(date: flightDate, reduceMotion: false))
        XCTAssertEqual(birds.count, 5)
        XCTAssertEqual(birds[0].x, 30, accuracy: 0.0001)
        XCTAssertEqual(birds[0].y, 30 + 24 * sin(.pi * 0.25), accuracy: 0.0001)
        XCTAssertEqual(birds[0].z, 15, accuracy: 0.0001)
        XCTAssertEqual(birds[1].x - birds[0].x, -2.2, accuracy: 0.0001)
        XCTAssertEqual(birds[1].y - birds[0].y, 1.6, accuracy: 0.0001)
        XCTAssertEqual(birds[1].z - birds[0].z, -0.3, accuracy: 0.0001)
        XCTAssertEqual(birds[2].x - birds[0].x, -2.2, accuracy: 0.0001)
        XCTAssertEqual(birds[2].y - birds[0].y, -1.6, accuracy: 0.0001)
        XCTAssertEqual(birds[2].z - birds[0].z, -0.3, accuracy: 0.0001)
        XCTAssertEqual(birds[3].x - birds[0].x, -4.4, accuracy: 0.0001)
        XCTAssertEqual(birds[3].y - birds[0].y, 3.2, accuracy: 0.0001)
        XCTAssertEqual(birds[4].y - birds[0].y, -3.2, accuracy: 0.0001)
    }

    func testBirdFlightLoopPositionsMatchParametricPath() {
        for seconds in [44.955, 0.045] {
            let progress = seconds / 45
            let leader = try! XCTUnwrap(CityWhimsy.birds(date: Date(timeIntervalSinceReferenceDate: seconds), reduceMotion: false).first)

            XCTAssertEqual(leader.x, -20 + 200 * progress, accuracy: 0.0001)
            XCTAssertEqual(leader.y, 30 + 24 * sin(progress * .pi), accuracy: 0.0001)
            XCTAssertEqual(leader.z, 15, accuracy: 0.0001)
        }
    }

    func testSkyWhimsyReduceMotionUsesFrozenPoses() {
        let later = date.addingTimeInterval(99)
        let birds = CityWhimsy.birds(date: date, reduceMotion: true)
        let balloon = CityWhimsy.balloon(date: date, reduceMotion: true)

        XCTAssertEqual(birds, CityWhimsy.birds(date: later, reduceMotion: true))
        XCTAssertEqual(birds[0].x, 50, accuracy: 0.0001)
        XCTAssertEqual(birds[0].flapPhase, 0, accuracy: 0.0001)
        XCTAssertEqual(balloon, CityWhimsy.balloon(date: later, reduceMotion: true))
        XCTAssertEqual(balloon.x, 62, accuracy: 0.0001)
        XCTAssertEqual(balloon.y, 86, accuracy: 0.0001)
        XCTAssertEqual(balloon.z, 20, accuracy: 0.0001)
        XCTAssertEqual(balloon.bob, 0, accuracy: 0.0001)
    }

    func testBalloonIsDeterministicAndCyclesWarmTintsPerLoop() {
        let first = CityWhimsy.balloon(date: Date(timeIntervalSinceReferenceDate: 14), reduceMotion: false)
        let secondLoop = CityWhimsy.balloon(date: Date(timeIntervalSinceReferenceDate: 84), reduceMotion: false)
        let thirdLoop = CityWhimsy.balloon(date: Date(timeIntervalSinceReferenceDate: 154), reduceMotion: false)

        XCTAssertEqual(first, CityWhimsy.balloon(date: Date(timeIntervalSinceReferenceDate: 14), reduceMotion: false))
        XCTAssertEqual(first.x, 26, accuracy: 0.0001)
        XCTAssertEqual(first.y, 98, accuracy: 0.0001)
        XCTAssertEqual(first.z, 20, accuracy: 0.0001)
        XCTAssertEqual(first.bob, 2 * sin(.pi * 1.2), accuracy: 0.0001)
        XCTAssertNotEqual(first.tint, secondLoop.tint)
        XCTAssertEqual(first.tint, thirdLoop.tint)
    }

    func testReduceMotionUsesStaticRepresentativePoses() {
        let later = date.addingTimeInterval(99)
        let building = BuildingSpec(ox: 2, oy: 3, bw: 4, bd: 5, h: 9, crackSeed: false, facade: RGB(r: 100, g: 100, b: 100))
        let path: [(CGFloat, CGFloat)] = [(1, 2), (5, 2), (5, 6)]
        let routeMetrics = CityWhimsy.RouteMetrics(path)

        XCTAssertEqual(
            CityWhimsy.smokePuffs(plotID: "plot-a", plotOrigin: CGPoint(x: 20, y: 30), building: building, load: 0.8, date: date, reduceMotion: true),
            CityWhimsy.smokePuffs(plotID: "plot-a", plotOrigin: CGPoint(x: 20, y: 30), building: building, load: 0.8, date: later, reduceMotion: true)
        )
        XCTAssertEqual(CityWhimsy.ferry(date: date, reduceMotion: true), CityWhimsy.ferry(date: later, reduceMotion: true))
        XCTAssertEqual(
            CityWhimsy.pedestrians(plotID: "plot-a", count: 3, routeMetrics: routeMetrics, date: date, reduceMotion: true),
            CityWhimsy.pedestrians(plotID: "plot-a", count: 3, routeMetrics: routeMetrics, date: later, reduceMotion: true)
        )
        XCTAssertEqual(
            CityWhimsy.fireworkParticles(plotID: "plot-a", plotOrigin: CGPoint(x: 20, y: 30), sinceLaunch: 0.2, reduceMotion: true),
            CityWhimsy.fireworkParticles(plotID: "plot-a", plotOrigin: CGPoint(x: 20, y: 30), sinceLaunch: 3.5, reduceMotion: true)
        )
    }

    func testPedestrianTriangleWaveStaysWithinPathBounds() {
        let path: [(CGFloat, CGFloat)] = [(0, 0), (10, 0)]
        let routeMetrics = CityWhimsy.RouteMetrics(path)
        for second in stride(from: 0.0, through: 100.0, by: 0.25) {
            let walkers = CityWhimsy.pedestrians(
                plotID: "plot-a", count: 3, routeMetrics: routeMetrics,
                date: Date(timeIntervalSinceReferenceDate: second), reduceMotion: false
            )
            XCTAssertEqual(walkers.count, 3)
            for walker in walkers {
                XCTAssertGreaterThanOrEqual(walker.progress, 0)
                XCTAssertLessThanOrEqual(walker.progress, 1)
                XCTAssertGreaterThanOrEqual(walker.x, 0)
                XCTAssertLessThanOrEqual(walker.x, 10)
                XCTAssertGreaterThanOrEqual(walker.y, -0.22 - 1e-9)
                XCTAssertLessThanOrEqual(walker.y, 0.22 + 1e-9)
            }
        }
    }

    func testPedestriansMatchRouteMetricsSamplingDeterministically() {
        let routeMetrics = CityWhimsy.RouteMetrics([(0, 0), (8, 0), (8, 6)])
        let walkers = CityWhimsy.pedestrians(
            plotID: "plot-a",
            count: 3,
            routeMetrics: routeMetrics,
            date: date,
            reduceMotion: false
        )

        XCTAssertEqual(
            walkers,
            CityWhimsy.pedestrians(
                plotID: "plot-a",
                count: 3,
                routeMetrics: routeMetrics,
                date: date,
                reduceMotion: false
            )
        )
        for walker in walkers {
            let expected = routeMetrics.sample(progress: walker.progress)
            if expected.alongX {
                XCTAssertEqual(walker.x, expected.x, accuracy: 1e-9)
                XCTAssertLessThanOrEqual(abs(walker.y - expected.y), 0.22 + 1e-9)
            } else {
                XCTAssertLessThanOrEqual(abs(walker.x - expected.x), 0.22 + 1e-9)
                XCTAssertEqual(walker.y, expected.y, accuracy: 1e-9)
            }
        }
    }

    func testPedestriansKeepRightAndConvergeToCenterAtTurnarounds() {
        let routeMetrics = CityWhimsy.RouteMetrics([(0, 0), (10, 0)])
        var previousByIndex: [Int: CityWhimsy.Walker] = [:]
        var sawOutbound = false
        var sawReturning = false
        var sawTurnaround = false

        for second in stride(from: 0.0, through: 100.0, by: 0.02) {
            let walkers = CityWhimsy.pedestrians(
                plotID: "plot-a",
                count: 3,
                routeMetrics: routeMetrics,
                date: Date(timeIntervalSinceReferenceDate: second),
                reduceMotion: false
            )

            for (index, walker) in walkers.enumerated() {
                if walker.progress > 0.05, walker.progress < 0.95 {
                    if walker.isReturning {
                        sawReturning = true
                        XCTAssertGreaterThan(walker.y, 0)
                    } else {
                        sawOutbound = true
                        XCTAssertLessThan(walker.y, 0)
                    }
                }
                if let previous = previousByIndex[index],
                   previous.isReturning != walker.isReturning {
                    sawTurnaround = true
                    XCTAssertLessThan(abs(walker.y - previous.y), 0.02)
                }
                previousByIndex[index] = walker
            }
        }

        XCTAssertTrue(sawOutbound)
        XCTAssertTrue(sawReturning)
        XCTAssertTrue(sawTurnaround)
    }

    func testStrollersAreDeterministicForFixedDate() {
        let streets: [[(CGFloat, CGFloat)]] = [
            [(0, 0), (12, 0), (12, 8)],
            [(20, 4), (20, 18)],
        ]
        let strollers = CityWhimsy.strollers(
            localStreets: streets,
            runningJobCount: 3,
            date: date,
            reduceMotion: false
        )

        XCTAssertEqual(
            strollers,
            CityWhimsy.strollers(
                localStreets: streets,
                runningJobCount: 3,
                date: date,
                reduceMotion: false
            )
        )
    }

    func testStrollerCountScalesWithRunningJobsAndCapsAt28() {
        let streets: [[(CGFloat, CGFloat)]] = [
            [(0, 0), (12, 0)],
            [(20, 4), (20, 18)],
        ]

        XCTAssertEqual(CityWhimsy.strollers(localStreets: streets, runningJobCount: 0, date: date, reduceMotion: false).count, 4)
        XCTAssertEqual(CityWhimsy.strollers(localStreets: streets, runningJobCount: 3, date: date, reduceMotion: false).count, 13)
        XCTAssertEqual(CityWhimsy.strollers(localStreets: streets, runningJobCount: 99, date: date, reduceMotion: false).count, 28)
    }

    func testStrollersStayWithinStreetBoundsExpandedBySidewalkOffset() {
        let streets: [[(CGFloat, CGFloat)]] = [
            [(0, 0), (10, 0)],
            [(20, 0), (20, 10)],
        ]

        for second in stride(from: 0.0, through: 100.0, by: 0.25) {
            let strollers = CityWhimsy.strollers(
                localStreets: streets,
                runningJobCount: 8,
                date: Date(timeIntervalSinceReferenceDate: second),
                reduceMotion: false
            )
            XCTAssertEqual(strollers.count, 28)
            for stroller in strollers {
                XCTAssertTrue(streets.contains { street in
                    let xs = street.map(\.0)
                    let ys = street.map(\.1)
                    return stroller.x >= (xs.min()! - 0.6)
                        && stroller.x <= (xs.max()! + 0.6)
                        && stroller.y >= (ys.min()! - 0.6)
                        && stroller.y <= (ys.max()! + 0.6)
                })
            }
        }
    }

    func testStrollersFreezeAcrossDatesForReducedMotion() {
        let streets: [[(CGFloat, CGFloat)]] = [
            [(0, 0), (12, 0), (12, 8)],
            [(20, 4), (20, 18)],
        ]

        XCTAssertEqual(
            CityWhimsy.strollers(localStreets: streets, runningJobCount: 4, date: date, reduceMotion: true),
            CityWhimsy.strollers(localStreets: streets, runningJobCount: 4, date: date.addingTimeInterval(100), reduceMotion: true)
        )
    }
    func testShoppersAreDeterministicForFixedDate() {
        let stops: [(CGFloat, CGFloat)] = [(0, 0), (12, 0), (12, 8)]
        let shoppers = CityWhimsy.shoppers(shopStops: stops, runningJobCount: 3, date: date, reduceMotion: false)

        XCTAssertEqual(shoppers, CityWhimsy.shoppers(shopStops: stops, runningJobCount: 3, date: date, reduceMotion: false))
    }

    func testShopperCountScalesWithRunningJobsAndIsEmptyWithoutStops() {
        let stops: [(CGFloat, CGFloat)] = [(0, 0), (12, 0)]

        XCTAssertEqual(CityWhimsy.shoppers(shopStops: stops, runningJobCount: 0, date: date, reduceMotion: false).count, 2)
        XCTAssertEqual(CityWhimsy.shoppers(shopStops: stops, runningJobCount: 6, date: date, reduceMotion: false).count, 8)
        XCTAssertEqual(CityWhimsy.shoppers(shopStops: stops, runningJobCount: 99, date: date, reduceMotion: false).count, 10)
        XCTAssertTrue(CityWhimsy.shoppers(shopStops: [], runningJobCount: 99, date: date, reduceMotion: false).isEmpty)
    }

    func testShopperDwellFlagTogglesAcrossWalkCycle() {
        let stops: [(CGFloat, CGFloat)] = [(0, 0), (12, 0)]
        let poses = stride(from: 0.0, through: 20.0, by: 0.1).map {
            CityWhimsy.shoppers(shopStops: stops, runningJobCount: 0, date: Date(timeIntervalSinceReferenceDate: $0), reduceMotion: false)[0]
        }

        XCTAssertTrue(poses.contains(where: \.dwelling))
        XCTAssertTrue(poses.contains { !$0.dwelling })
    }

    func testShoppersFreezeAcrossDatesForReducedMotion() {
        let stops: [(CGFloat, CGFloat)] = [(0, 0), (12, 0), (12, 8)]

        XCTAssertEqual(
            CityWhimsy.shoppers(shopStops: stops, runningJobCount: 4, date: date, reduceMotion: true),
            CityWhimsy.shoppers(shopStops: stops, runningJobCount: 4, date: date.addingTimeInterval(100), reduceMotion: true)
        )
    }

    func testFireworkHasRocketAndBurstThenFadesToZero() {
        let launch = CityWhimsy.fireworkParticles(plotID: "plot-a", plotOrigin: CGPoint(x: 20, y: 30), sinceLaunch: 0.2, reduceMotion: false)
        let burst = CityWhimsy.fireworkParticles(plotID: "plot-a", plotOrigin: CGPoint(x: 20, y: 30), sinceLaunch: 1.2, reduceMotion: false)
        let expired = CityWhimsy.fireworkParticles(plotID: "plot-a", plotOrigin: CGPoint(x: 20, y: 30), sinceLaunch: 4, reduceMotion: false)

        XCTAssertEqual(launch.count, 1)
        XCTAssertTrue((13...17).contains(burst.count))
        XCTAssertTrue(burst.allSatisfy { $0.opacity > 0 })
        XCTAssertTrue(expired.allSatisfy { $0.opacity == 0 })
    }


    func testFarTrafficIsDeterministicAdvancesAndFreezesForReducedMotion() {
        let routes: [[(CGFloat, CGFloat)]] = [
            [(0, 0), (10, 0), (10, 10)],
            [(20, 0), (20, 20)],
        ]
        let later = date.addingTimeInterval(1)
        let first = CityWhimsy.farTraffic(routes: routes, date: date, reduceMotion: false)

        XCTAssertEqual(first, CityWhimsy.farTraffic(routes: routes, date: date, reduceMotion: false))
        XCTAssertLessThanOrEqual(first.count, 40)
        let denseRoutes = (0..<20).map { index in
            [(CGFloat(index) * 20, CGFloat.zero), (CGFloat(index) * 20 + 100, CGFloat.zero)]
        }
        XCTAssertEqual(CityWhimsy.farTraffic(routes: denseRoutes, date: date, reduceMotion: false).count, 40)

        XCTAssertNotEqual(first.map { [$0.x, $0.y] }, CityWhimsy.farTraffic(routes: routes, date: later, reduceMotion: false).map { [$0.x, $0.y] })
        XCTAssertEqual(
            CityWhimsy.farTraffic(routes: routes, date: date, reduceMotion: true),
            CityWhimsy.farTraffic(routes: routes, date: later, reduceMotion: true)
        )
        for car in first {
            XCTAssertTrue(routes.contains { route in point(car.x, car.y, liesOn: route) })
        }
    }
    func testRouteMetricsMatchLegacyPolylineSamplingAcrossDistancesAndRoutes() {
        let routes: [[(CGFloat, CGFloat)]] = [
            [(0, 0), (10, 0), (10, 10)],
            [(2, 3), (2, 3), (-4, 3), (-4, -5)],
            [(7, -2)],
        ]

        for route in routes {
            let metrics = CityWhimsy.RouteMetrics(route)
            let length = legacyPolylineLength(route)
            for distance in [CGFloat(-2), 0, length * 0.25, length * 0.5, length, length + 2] {
                let expected = legacyPoint(on: route, distance: distance, length: length)
                let actual = metrics.sample(distance: distance)
                XCTAssertEqual(actual.x, expected.x, accuracy: 1e-9, "route=\(route), distance=\(distance)")
                XCTAssertEqual(actual.y, expected.y, accuracy: 1e-9, "route=\(route), distance=\(distance)")
            }
        }
    }


    func testAllBandFlickerModelsAreDeterministicAndHaveTheirExpectedStates() {
        XCTAssertEqual(CityWhimsy.starTwinkle(index: 3, date: date), CityWhimsy.starTwinkle(index: 3, date: date))
        XCTAssertEqual(CityWhimsy.lampFlicker(lampIndex: 3, date: date), CityWhimsy.lampFlicker(lampIndex: 3, date: date))
        XCTAssertEqual(CityWhimsy.neonFlicker(seed: 3, broken: false, date: date), CityWhimsy.neonFlicker(seed: 3, broken: false, date: date))

        let lamps = (0...30).flatMap { lamp in
            stride(from: 0.0, through: 60.0, by: 0.04).map {
                CityWhimsy.lampFlicker(lampIndex: lamp, date: Date(timeIntervalSinceReferenceDate: $0))
            }
        }
        XCTAssertGreaterThan(lamps.filter { $0 == 1 }.count, lamps.count * 4 / 5)
        XCTAssertTrue(lamps.contains(0.35))

        let broken = stride(from: 0.0, through: 30.0, by: 0.4).map {
            CityWhimsy.neonFlicker(seed: 3, broken: true, date: Date(timeIntervalSinceReferenceDate: $0))
        }
        XCTAssertTrue(broken.contains(0.15))
        XCTAssertTrue(broken.contains(1))
    }

    func testCreatureEventsAreDeterministicBoundedAndFreezeForReducedMotion() {
        let bounds = CGRect(x: -20, y: 10, width: 180, height: 120)
        let later = date.addingTimeInterval(7)

        let kaiju = CityWhimsy.kaijuPose(date: date, reduceMotion: false, bounds: bounds)
        XCTAssertEqual(kaiju, CityWhimsy.kaijuPose(date: date, reduceMotion: false, bounds: bounds))
        XCTAssertNotEqual(kaiju, CityWhimsy.kaijuPose(date: later, reduceMotion: false, bounds: bounds))
        XCTAssertTrue(bounds.contains(CGPoint(x: kaiju.x, y: kaiju.y)))
        XCTAssertEqual(
            CityWhimsy.kaijuPose(date: date, reduceMotion: true, bounds: bounds),
            CityWhimsy.kaijuPose(date: later, reduceMotion: true, bounds: bounds)
        )

        let ufo = CityWhimsy.ufoEvent(date: date, reduceMotion: false, bounds: bounds)
        XCTAssertEqual(ufo, CityWhimsy.ufoEvent(date: date, reduceMotion: false, bounds: bounds))
        XCTAssertNotEqual(ufo, CityWhimsy.ufoEvent(date: later, reduceMotion: false, bounds: bounds))
        XCTAssertTrue(bounds.contains(CGPoint(x: ufo.x, y: ufo.y)))
        XCTAssertGreaterThan(ufo.altitude, 0)
        XCTAssertEqual(
            CityWhimsy.ufoEvent(date: date, reduceMotion: true, bounds: bounds),
            CityWhimsy.ufoEvent(date: later, reduceMotion: true, bounds: bounds)
        )
    }

    private func legacyPolylineLength(_ path: [(CGFloat, CGFloat)]) -> CGFloat {
        zip(path, path.dropFirst()).reduce(0) { total, segment in
            total + hypot(segment.1.0 - segment.0.0, segment.1.1 - segment.0.1)
        }
    }

    private func legacyPoint(
        on path: [(CGFloat, CGFloat)],
        distance: CGFloat,
        length: CGFloat
    ) -> (x: CGFloat, y: CGFloat) {
        guard path.count > 1, length > 0 else { return path.first ?? (0, 0) }
        var remaining = min(max(0, distance), length)
        for (start, end) in zip(path, path.dropFirst()) {
            let segmentLength = hypot(end.0 - start.0, end.1 - start.1)
            guard segmentLength > 0 else { continue }
            if remaining <= segmentLength {
                let fraction = remaining / segmentLength
                return (start.0 + (end.0 - start.0) * fraction, start.1 + (end.1 - start.1) * fraction)
            }
            remaining -= segmentLength
        }
        return path[path.count - 1]
    }

    private func point(_ x: CGFloat, _ y: CGFloat, liesOn route: [(CGFloat, CGFloat)]) -> Bool {
        zip(route, route.dropFirst()).contains { start, end in
            let dx = end.0 - start.0
            let dy = end.1 - start.1
            let lengthSquared = dx * dx + dy * dy
            guard lengthSquared > 0 else { return hypot(x - start.0, y - start.1) < 0.0001 }
            let projection = max(0, min(1, ((x - start.0) * dx + (y - start.1) * dy) / lengthSquared))
            return hypot(x - (start.0 + projection * dx), y - (start.1 + projection * dy)) < 0.0001
        }
    }

    private func node(status: NodeStatus) -> ClusterNode {
        ClusterNode(name: "h200-01", gpuType: "H200", profile: "h200", vramGB: 141, gpuCount: 1, state: status.rawValue, status: status, stateLabel: status.rawValue, jobs: status == .idle ? [] : [job()])
    }

    private func job() -> ClusterJob {
        ClusterJob(id: "job-1", user: "alice", name: "train", state: "RUNNING", elapsedSeconds: 1, limitSeconds: 10, remainingSeconds: 9, nodeList: "h200-01", reason: "h200-01")
    }
}
