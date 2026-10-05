import CoreGraphics
import Foundation
import SwiftUI
import XCTest
@testable import ColbyGPUCluster

@MainActor
final class CitySceneTests: XCTestCase {
    func testProjectionRoundTripsWorldCoordinatesAndPainterOrderGrowsWithDepth() {
        let xs: [CGFloat] = [-20, 0, 14.5, 50, 96]
        let ys: [CGFloat] = [-10, 0, 20, 44, 90]

        for x in xs {
            for y in ys {
                let roundTripped = IsoProjection.unproject(IsoProjection.project(x, y))
                XCTAssertEqual(roundTripped.x, x, accuracy: 1e-9, "x=\(x), y=\(y)")
                XCTAssertEqual(roundTripped.y, y, accuracy: 1e-9, "x=\(x), y=\(y)")
                XCTAssertGreaterThan(
                    IsoProjection.sortKey(x: x, y: y + 1),
                    IsoProjection.sortKey(x: x, y: y),
                    "Increasing depth must paint nearer objects later."
                )
            }
        }
    }

    func testCityScapePreservesTierAndNameOrderWithoutPlotOrBlockOverlap() throws {
        let scape = CityScape.build(snapshot: try snapshot(sinfo: """
        h200-01|idle|gpu:H200:1
        rtx-01|idle|gpu:RTX:1
        a100-01|idle|gpu:A100:1
        l40s-01|idle|gpu:L40S:1
        l4-beta|idle|gpu:L4:1
        l4-alpha|idle|gpu:L4:1
        mig-beta|idle|gpu:1g.20gb:1
        mig-alpha|idle|gpu:1g.20gb:1
        """))

        XCTAssertEqual(scape.blocks.map { $0.node.name }, ["h200-01", "rtx-01", "a100-01", "l40s-01", "l4-alpha", "l4-beta", "mig-alpha", "mig-beta"])
        XCTAssertEqual(scape.plots.count, 8)
        XCTAssertEqual(scape.localStreets.count, scape.plots.count)
        assertNoOverlap(scape)
    }

    func testCityScapeExpandsElevenPlotsAndGroupsThemByNode() throws {
        let scape = CityScape.build(snapshot: try snapshot(sinfo: """
        n10|idle|gpu:A100:2
        n14|idle|gpu:A100:1
        n15|idle|gpu:H200:4
        n16|idle|gpu:RTX:4
        """))

        XCTAssertEqual(scape.plots.count, 11)
        XCTAssertEqual(
            Dictionary(grouping: scape.plots, by: \.gres.profile).mapValues(\.count),
            ["h200": 4, "rtxpro6000": 4, "a100": 3]
        )
        let productionViewport = CGSize(width: 460, height: 600)
        let sceneBounds = scape.plots
            .map { $0.screenBounds() }
            .reduce(CGRect.null) { $0.union($1) }
        let camera = CityCamera.fitting(worldScreenBounds: sceneBounds, in: productionViewport, margin: 24)
        let renderedSceneRectangle = CGRect(origin: .zero, size: productionViewport).insetBy(dx: 24, dy: 24)
        for plot in scape.plots {
            XCTAssertTrue(
                renderedSceneRectangle.contains(plot.screenBounds(camera: camera)),
                "\(plot.id) must remain inside the production panel viewport after fitting."
            )
        }
        XCTAssertEqual(scape.blocks.map(\.id), ["n15", "n16", "n10", "n14"])
        XCTAssertEqual(scape.plots.map(\.id), [
            "n15-gpu1", "n15-gpu2", "n15-gpu3", "n15-gpu4",
            "n16-gpu1", "n16-gpu2", "n16-gpu3", "n16-gpu4",
            "n10-gpu1", "n10-gpu2", "n14",
        ])
        for block in scape.blocks {
            let plots = scape.plots.filter { $0.node.id == block.node.id }
            XCTAssertEqual(plots.map(\.id), block.plotIDs)
            XCTAssertEqual(plots.count, block.node.totalGPUCount)
            let blockRect = CGRect(x: block.bounds.x, y: block.bounds.y, width: block.bounds.w, height: block.bounds.d)
            XCTAssertTrue(plots.allSatisfy {
                blockRect.contains(CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.d))
            })
        }
        assertNoOverlap(scape)
    }

    func testCityScapeExpandsEveryGRESResourceWithStableResourceIDs() throws {
        let scape = CityScape.build(snapshot: try snapshot(sinfo: """
        n10|mix|gpu:A100:1,gpu:1g.20gb:4|gpu:A100:1(IDX:0),gpu:1g.20gb:0(IDX:N/A)
        """))

        XCTAssertEqual(scape.plots.map(\.id), [
            "n10-gpu1",
            "n10-mig-gpu1", "n10-mig-gpu2", "n10-mig-gpu3", "n10-mig-gpu4",
        ])
        XCTAssertEqual(scape.plots.map(\.gres.profile), ["a100", "mig", "mig", "mig", "mig"])
        XCTAssertEqual(scape.plots.map(\.mode), [.lit, .vacant, .vacant, .vacant, .vacant])
    }


    func testCityScapeMapsResourceUsageAndDrainedNodesToTheirSceneModes() throws {
        let snapshot = try snapshot(sinfo: """
        idle-01|idle|gpu:H200:1
        partial-01|mix|gpu:A100:1
        drained-01|drain*|gpu:L4:1
        """)
        let plotsByID = Dictionary(uniqueKeysWithValues: CityScape.build(snapshot: snapshot).plots.map { ($0.id, $0) })

        XCTAssertEqual(plotsByID["idle-01"]?.mode, .vacant)
        XCTAssertEqual(plotsByID["partial-01"]?.mode, .lit)
        XCTAssertEqual(plotsByID["drained-01"]?.mode, .closed)
    }

    func testCityScapeGeometrySignatureIgnoresActivityUsageJobsAndClosedness() throws {
        let idle = try snapshot(sinfo: """
        h200-01|idle|gpu:H200:2|gpu:H200:0(IDX:N/A)
        a100-01|idle|gpu:A100:1|gpu:A100:0(IDX:N/A)
        """)
        let active = try snapshot(
            sinfo: """
            a100-01|drain*|gpu:A100:1|gpu:A100:0(IDX:N/A)
            h200-01|mix|gpu:H200:2|gpu:H200:1(IDX:0)
            """,
            squeue: """
            101|alice|train-a|RUNNING|00:10:00|01:00:00|1|h200-01|h200-01
            102|bob|train-b|RUNNING|00:20:00|02:00:00|1|h200-01|h200-01
            """
        )

        XCTAssertEqual(CityScape.geometrySignature(of: idle), CityScape.geometrySignature(of: active))
    }

    func testCityScapeGeometrySignatureChangesWhenNodesAreAddedOrRemoved() throws {
        let base = try snapshot(sinfo: """
        h200-01|idle|gpu:H200:2
        a100-01|idle|gpu:A100:1
        """)
        let added = try snapshot(sinfo: """
        h200-01|idle|gpu:H200:2
        a100-01|idle|gpu:A100:1
        l4-01|idle|gpu:L4:1
        """)
        let removed = try snapshot(sinfo: """
        h200-01|idle|gpu:H200:2
        """)

        XCTAssertNotEqual(CityScape.geometrySignature(of: base), CityScape.geometrySignature(of: added))
        XCTAssertNotEqual(CityScape.geometrySignature(of: base), CityScape.geometrySignature(of: removed))
    }

    func testCityScapeUpdatePolicyUsesActivityOnlyForSameGeometrySignature() throws {
        let idle = try snapshot(sinfo: """
        h200-01|idle|gpu:H200:2|gpu:H200:0(IDX:N/A)
        a100-01|idle|gpu:A100:1|gpu:A100:0(IDX:N/A)
        """)
        var active = try snapshot(
            sinfo: """
            h200-01|mix|gpu:H200:2|gpu:H200:1(IDX:0)
            a100-01|alloc|gpu:A100:1|gpu:A100:1(IDX:0)
            """,
            squeue: "201|alice|train-a|RUNNING|00:10:00|01:00:00|1|h200-01|h200-01"
        )
        active.generatedAt = idle.generatedAt.addingTimeInterval(30)

        XCTAssertEqual(
            CityScapeUpdatePolicy.plan(
                currentGeneratedAt: idle.generatedAt,
                currentGeometrySignature: CityScape.geometrySignature(of: idle),
                snapshot: active
            ),
            .activityOnly(nextGeometrySignature: CityScape.geometrySignature(of: active))
        )
    }

    func testCityScapeActivityUpdateFromSnapshotPreservesStaticGeometryAndRefreshesModesAndJobs() throws {
        let idleSnapshot = try snapshot(sinfo: """
        h200-01|idle|gpu:H200:2|gpu:H200:0(IDX:N/A)
        a100-01|idle|gpu:A100:1|gpu:A100:0(IDX:N/A)
        """)
        let idleScape = CityScape.build(snapshot: idleSnapshot)
        let activeSnapshot = try snapshot(
            sinfo: """
            h200-01|mix|gpu:H200:2|gpu:H200:1(IDX:0)
            a100-01|alloc|gpu:A100:1|gpu:A100:1(IDX:0)
            """,
            squeue: """
            201|alice|train-a|RUNNING|00:10:00|01:00:00|1|h200-01|h200-01
            202|bob|train-b|RUNNING|00:20:00|02:00:00|1|a100-01|a100-01
            """
        )

        let updated = idleScape.updatingActivity(from: activeSnapshot)

        assertStaticGeometryEqual(updated, idleScape)
        XCTAssertEqual(updated.runningJobs.map(\.id), ["201", "202"])
        let updatedPlots = Dictionary(uniqueKeysWithValues: updated.plots.map { ($0.id, $0) })
        XCTAssertEqual(updatedPlots["h200-01-gpu1"]?.mode, .lit)
        XCTAssertEqual(updatedPlots["h200-01-gpu2"]?.mode, .vacant)
        XCTAssertEqual(updatedPlots["a100-01"]?.mode, .lit)
        XCTAssertEqual(updatedPlots["h200-01-gpu1"]?.node, activeSnapshot.nodes.first { $0.name == "h200-01" })
        XCTAssertEqual(updatedPlots["a100-01"]?.node, activeSnapshot.nodes.first { $0.name == "a100-01" })
    }

    func testStaticPathInputsRemainModeIndependent() throws {
        let idleScape = CityScape.build(snapshot: try snapshot(sinfo: """
        h200-01|idle|gpu:H200:2|gpu:H200:0(IDX:N/A)
        l4-01|idle|gpu:L4:1|gpu:L4:0(IDX:N/A)
        """))
        let closedAndBusyScape = CityScape.build(snapshot: try snapshot(
            sinfo: """
            h200-01|mix|gpu:H200:2|gpu:H200:1(IDX:0)
            l4-01|drain*|gpu:L4:1|gpu:L4:0(IDX:N/A)
            """,
            squeue: "301|alice|train|RUNNING|00:10:00|01:00:00|1|h200-01|h200-01"
        ))

        XCTAssertNotEqual(idleScape.plots.map(\.mode), closedAndBusyScape.plots.map(\.mode))
        assertStaticGeometryEqual(idleScape, closedAndBusyScape)
        XCTAssertEqual(
            CitySceneStaticPaths(scape: idleScape).geometrySignature,
            CitySceneStaticPaths(scape: closedAndBusyScape).geometrySignature
        )
    }

    func testDirectorAnimatesNewJobThenParksItAtLotCorner() throws {
        let idleScape = CityScape.build(snapshot: try snapshot(sinfo: "h200-01|idle|gpu:H200:1"))
        let runningScape = CityScape.build(snapshot: try snapshot(
            sinfo: "h200-01|alloc|gpu:H200:1",
            squeue: "100|alice|train|RUNNING|01:00:00|02:00:00|1|h200-01|h200-01"
        ))
        let director = CityDirector()
        let initialDate = Date(timeIntervalSince1970: 1_000)
        let arrivalDate = initialDate.addingTimeInterval(10)

        director.reconcile(scape: idleScape, date: initialDate, reduceMotion: false, band: .city)
        director.reconcile(scape: runningScape, date: arrivalDate, reduceMotion: false, band: .city)

        let arrivingCar = try XCTUnwrap(director.cars.only)
        XCTAssertEqual(arrivingCar.jobID, "100")
        XCTAssertEqual(arrivingCar.plotID, "h200-01")
        guard case let .arriving(start) = arrivingCar.phase else {
            return XCTFail("A newly observed job must commute in.")
        }
        XCTAssertEqual(start, arrivalDate)

        let midpoint = try XCTUnwrap(
            director.carWorldPos(arrivingCar, scape: runningScape, date: arrivalDate.addingTimeInterval(1))
        )
        let path = try XCTUnwrap(runningScape.entryPath(for: arrivingCar.plotID))
        XCTAssertTrue(isOnPath(midpoint, path: path), "An arriving car must remain on its entry path.")

        let parkedDate = arrivalDate.addingTimeInterval(2.5)
        director.reconcile(scape: runningScape, date: parkedDate, reduceMotion: false, band: .city)
        let parkedCar = try XCTUnwrap(director.cars.only)
        XCTAssertEqual(parkedCar.phase, .parked)

        let parkedPosition = try XCTUnwrap(director.carWorldPos(parkedCar, scape: runningScape, date: parkedDate))
        let plot = try XCTUnwrap(runningScape.plots.first { $0.id == parkedCar.plotID })
        XCTAssertEqual(parkedPosition.x, plot.lotCorner.x, accuracy: 1e-9)
        XCTAssertEqual(parkedPosition.y, plot.lotCorner.y, accuracy: 1e-9)
    }

    func testDirectorSpacesSameDirectionCarsAlongSharedRoute() throws {
        let idleScape = CityScape.build(snapshot: try snapshot(
            sinfo: "h200-01|idle|gpu:H200:1"
        ))
        let runningScape = CityScape.build(snapshot: try snapshot(
            sinfo: "h200-01|alloc|gpu:H200:1",
            squeue: """
            100|alice|train-a|RUNNING|00:10:00|02:00:00|1|h200-01|h200-01
            101|bob|train-b|RUNNING|00:10:00|02:00:00|1|h200-01|h200-01
            """
        ))
        let director = CityDirector()
        let initialDate = Date(timeIntervalSince1970: 1_000)
        let arrivalDate = initialDate.addingTimeInterval(10)

        director.reconcile(scape: idleScape, date: initialDate, reduceMotion: false, band: .city)
        director.reconcile(scape: runningScape, date: arrivalDate, reduceMotion: false, band: .city)

        let sampleDate = arrivalDate.addingTimeInterval(1)
        let positions = director.spacedCarPositions(
            plotID: "h200-01",
            scape: runningScape,
            date: sampleDate
        )
        let first = try XCTUnwrap(positions["h200-01|100"])
        let second = try XCTUnwrap(positions["h200-01|101"])
        let metrics = try XCTUnwrap(runningScape.entryRouteMetrics(for: "h200-01"))
        let raw = CGFloat(sampleDate.timeIntervalSince(arrivalDate) / CityDirector.commuteDuration)
        let leaderProgress = raw * raw * (3 - 2 * raw)
        let followerProgress = leaderProgress - 1.8 / metrics.length
        let expectedLeader = metrics.sample(progress: leaderProgress)
        let expectedFollower = metrics.sample(progress: followerProgress)

        XCTAssertEqual((leaderProgress - followerProgress) * metrics.length, 1.8, accuracy: 1e-9)
        XCTAssertEqual(first.x, expectedLeader.x + (expectedLeader.alongX ? 0 : -0.28), accuracy: 1e-9)
        XCTAssertEqual(first.y, expectedLeader.y + (expectedLeader.alongX ? -0.28 : 0), accuracy: 1e-9)
        XCTAssertEqual(second.x, expectedFollower.x + (expectedFollower.alongX ? 0 : -0.28), accuracy: 1e-9)
        XCTAssertEqual(second.y, expectedFollower.y + (expectedFollower.alongX ? -0.28 : 0), accuracy: 1e-9)
    }

    func testDirectorDefersConvoyFollowersUntilMinimumGapFitsOnRoute() throws {
        let idleScape = CityScape.build(snapshot: try snapshot(
            sinfo: "h200-01|idle|gpu:H200:1"
        ))
        let runningScape = CityScape.build(snapshot: try snapshot(
            sinfo: "h200-01|alloc|gpu:H200:1",
            squeue: """
            100|alice|train-a|RUNNING|00:10:00|02:00:00|1|h200-01|h200-01
            101|bob|train-b|RUNNING|00:10:00|02:00:00|1|h200-01|h200-01
            """
        ))
        let initialDate = Date(timeIntervalSince1970: 1_000)
        let transitionDate = initialDate.addingTimeInterval(10)

        let arrivingDirector = CityDirector()
        arrivingDirector.reconcile(scape: idleScape, date: initialDate, reduceMotion: false, band: .city)
        arrivingDirector.reconcile(scape: runningScape, date: transitionDate, reduceMotion: false, band: .city)
        let arrivals = arrivingDirector.spacedCarPositions(
            plotID: "h200-01",
            scape: runningScape,
            date: transitionDate
        )
        XCTAssertEqual(arrivals.count, 1)

        let leavingDirector = CityDirector()
        leavingDirector.reconcile(scape: runningScape, date: initialDate, reduceMotion: false, band: .city)
        leavingDirector.reconcile(scape: idleScape, date: transitionDate, reduceMotion: false, band: .city)
        let departures = leavingDirector.spacedCarPositions(
            plotID: "h200-01",
            scape: idleScape,
            date: transitionDate
        )
        XCTAssertEqual(departures.count, 1)
    }

    func testDirectorLeavesCarsOrRemovesThemForReducedMotionAndParksInitialJobs() throws {
        let runningScape = CityScape.build(snapshot: try snapshot(
            sinfo: "h200-01|alloc|gpu:H200:1",
            squeue: "100|alice|train|RUNNING|01:00:00|02:00:00|1|h200-01|h200-01"
        ))
        let idleScape = CityScape.build(snapshot: try snapshot(sinfo: "h200-01|idle|gpu:H200:1"))
        let initialDate = Date(timeIntervalSince1970: 1_000)
        let departureDate = initialDate.addingTimeInterval(10)

        let director = CityDirector()
        director.reconcile(scape: runningScape, date: initialDate, reduceMotion: false, band: .city)
        let initiallyParked = try XCTUnwrap(director.cars.only)
        XCTAssertEqual(initiallyParked.phase, .parked, "Initial jobs must not create an arrival storm.")

        director.reconcile(scape: idleScape, date: departureDate, reduceMotion: false, band: .city)
        let leavingCar = try XCTUnwrap(director.cars.only)
        guard case let .leaving(start) = leavingCar.phase else {
            return XCTFail("A disappeared job must commute out.")
        }
        XCTAssertEqual(start, departureDate)

        let reducedMotionDirector = CityDirector()
        reducedMotionDirector.reconcile(scape: runningScape, date: initialDate, reduceMotion: false, band: .city)
        reducedMotionDirector.reconcile(scape: idleScape, date: departureDate, reduceMotion: true, band: .city)
        XCTAssertTrue(reducedMotionDirector.cars.isEmpty, "Reduced motion must remove departing cars immediately.")
    }

    func testExpiredDepartureRenderingDoesNotMutateCommuterLifecycle() throws {
        let runningScape = CityScape.build(snapshot: try snapshot(
            sinfo: "h200-01|alloc|gpu:H200:1",
            squeue: "100|alice|train|RUNNING|01:00:00|02:00:00|1|h200-01|h200-01"
        ))
        let idleScape = CityScape.build(snapshot: try snapshot(sinfo: "h200-01|idle|gpu:H200:1"))
        let initialDate = Date(timeIntervalSince1970: 1_000)
        let departureDate = initialDate.addingTimeInterval(10)
        let director = CityDirector()

        director.reconcile(scape: runningScape, date: initialDate, reduceMotion: false, band: .city)
        director.reconcile(scape: idleScape, date: departureDate, reduceMotion: false, band: .city)
        let leavingCar = try XCTUnwrap(director.cars.only)

        _ = director.carWorldPos(
            leavingCar,
            scape: idleScape,
            date: departureDate.addingTimeInterval(CityDirector.commuteDuration + 0.1)
        )
        XCTAssertEqual(director.cars.count, 1, "Rendering must not expire commuters.")

        director.reconcile(
            scape: idleScape,
            date: departureDate.addingTimeInterval(CityDirector.commuteDuration + 0.1),
            reduceMotion: false,
            band: .city
        )
        XCTAssertTrue(director.cars.isEmpty, "Reconciliation owns departure expiry.")
    }

    func testDirectorKeepsEligibleJobsForCityAndStreetCourierSelection() throws {
        let runningScape = CityScape.build(snapshot: try snapshot(
            sinfo: "h200-01|alloc|gpu:H200:1",
            squeue: """
            100|alice|train-a|RUNNING|01:00:00|02:00:00|1|h200-01|h200-01
            101|alice|train-b|RUNNING|01:00:00|02:00:00|1|h200-01|h200-01
            102|alice|train-c|RUNNING|01:00:00|02:00:00|1|h200-01|h200-01
            """
        ))
        let date = Date(timeIntervalSince1970: 1_000)
        let cityDirector = CityDirector()
        let streetDirector = CityDirector()

        cityDirector.reconcile(scape: runningScape, date: date, reduceMotion: false, band: .city)
        streetDirector.reconcile(scape: runningScape, date: date, reduceMotion: false, band: .street)

        XCTAssertEqual(cityDirector.cars.map(\.jobID).sorted(), ["100", "101", "102"])
        XCTAssertEqual(streetDirector.cars.map(\.jobID).sorted(), ["100", "101", "102"])
    }

    func testDirectorDoesNotAnimateCarsWhenOnlyZoomBandChanges() throws {
        let scape = CityScape.build(snapshot: try snapshot(
            sinfo: "h200-01|alloc|gpu:H200:1",
            squeue: """
            100|alice|train-a|RUNNING|01:00:00|02:00:00|1|h200-01|h200-01
            101|alice|train-b|RUNNING|01:00:00|02:00:00|1|h200-01|h200-01
            102|alice|train-c|RUNNING|01:00:00|02:00:00|1|h200-01|h200-01
            """
        ))
        let director = CityDirector()
        let date = Date(timeIntervalSince1970: 1_000)

        director.reconcile(scape: scape, date: date, reduceMotion: false, band: .street)
        director.reconcile(scape: scape, date: date.addingTimeInterval(10), reduceMotion: false, band: .city)
        director.reconcile(scape: scape, date: date.addingTimeInterval(20), reduceMotion: false, band: .street)

        XCTAssertEqual(director.cars.map(\.jobID).sorted(), ["100", "101", "102"])
        XCTAssertTrue(director.cars.allSatisfy { $0.phase == .parked })
    }

    func testEntryPathsStartAtBridgeSideAvenueEndpointAndEndAtPlotLotCorner() throws {
        let scape = CityScape.build(snapshot: try snapshot(sinfo: """
        h200-01|idle|gpu:H200:2
        a100-01|idle|gpu:A100:1
        """))
        let bridgeSideEndpoint = (x: CGFloat(78), y: CGFloat(90))
        XCTAssertTrue(scape.avenue.contains { $0.0 == bridgeSideEndpoint.x && $0.1 == bridgeSideEndpoint.y })

        for plot in scape.plots {
            let path = try XCTUnwrap(scape.entryPath(for: plot.id))
            let start = try XCTUnwrap(path.first)
            let end = try XCTUnwrap(path.last)
            XCTAssertEqual(start.0, bridgeSideEndpoint.0, accuracy: 1e-9)
            XCTAssertEqual(start.1, bridgeSideEndpoint.1, accuracy: 1e-9)
            XCTAssertEqual(end.0, plot.lotCorner.x, accuracy: 1e-9)
            XCTAssertEqual(end.1, plot.lotCorner.y, accuracy: 1e-9)
            XCTAssertTrue(zip(path, path.dropFirst()).allSatisfy { start, end in
                start.0 == end.0 || start.1 == end.1
            })
        }
    }

    func testPedestrianPathHeadingUsesCurrentSegmentAndReversesOnReturnTravel() {
        let entryPath: [(CGFloat, CGFloat)] = [(0, 0), (10, 0), (10, 10)]
        let routeMetrics = CityWhimsy.RouteMetrics(entryPath)

        let outboundBeforeTurn = CityRenderer.pedestrianHeading(
            routeMetrics: routeMetrics,
            progress: 0.25,
            isReturning: false
        )
        let outboundAfterTurn = CityRenderer.pedestrianHeading(
            routeMetrics: routeMetrics,
            progress: 0.75,
            isReturning: false
        )
        let returningAfterTurn = CityRenderer.pedestrianHeading(
            routeMetrics: routeMetrics,
            progress: 0.75,
            isReturning: true
        )

        let east = IsoProjection.project(10, 0)
        let origin = IsoProjection.project(0, 0)
        let north = IsoProjection.project(10, 10)

        XCTAssertEqual(outboundBeforeTurn.width, east.x - origin.x, accuracy: 1e-9)
        XCTAssertEqual(outboundBeforeTurn.height, east.y - origin.y, accuracy: 1e-9)
        XCTAssertEqual(outboundAfterTurn.width, north.x - east.x, accuracy: 1e-9)
        XCTAssertEqual(outboundAfterTurn.height, north.y - east.y, accuracy: 1e-9)
        XCTAssertEqual(returningAfterTurn.width, east.x - north.x, accuracy: 1e-9)
        XCTAssertEqual(returningAfterTurn.height, east.y - north.y, accuracy: 1e-9)
    }

    func testSceneHUDUsesTrimmedStoredHostForCopiedCommand() {
        let defaults = UserDefaults.standard
        let key = "sshHost"
        let previousHost = defaults.object(forKey: key)
        defer {
            if let previousHost {
                defaults.set(previousHost, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        defaults.set("  research cluster; echo unsafe  ", forKey: key)

        let plot = CityPlot(
            node: ClusterNode(
                name: "a100-01",
                gpuType: "A100",
                profile: "a100",
                vramGB: 80,
                gpuCount: 1,
                state: "idle",
                status: .idle,
                stateLabel: "Idle",
                jobs: []
            ),
            gpuIndex: 1,
            gpuCount: 1,
            x: 0,
            y: 0,
            w: 8,
            d: 6,
            mode: .lit,
            buildings: [],
            hasCrane: false
        )
        let scene = CitySceneView(store: ClusterStore(), palette: AppTheme.graphite.palette)

        XCTAssertEqual(
            scene.hud(for: plot).model.command,
            "ssh 'research cluster; echo unsafe' 'sinfo -p gpu -N -h'"
        )
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
    private func assertNoOverlap(_ scape: CityScape) {
        for (index, plot) in scape.plots.enumerated() {
            let plotRect = CGRect(x: plot.x, y: plot.y, width: plot.w, height: plot.d)
            for other in scape.plots.dropFirst(index + 1) {
                let otherRect = CGRect(x: other.x, y: other.y, width: other.w, height: other.d)
                XCTAssertFalse(plotRect.intersects(otherRect), "\(plot.id) overlaps \(other.id)")
            }
        }
        for (index, block) in scape.blocks.enumerated() {
            let blockRect = CGRect(x: block.bounds.x, y: block.bounds.y, width: block.bounds.w, height: block.bounds.d)
            for other in scape.blocks.dropFirst(index + 1) {
                let otherRect = CGRect(x: other.bounds.x, y: other.bounds.y, width: other.bounds.w, height: other.bounds.d)
                XCTAssertFalse(blockRect.intersects(otherRect), "\(block.id) overlaps \(other.id)")
            }
        }
    }
    private func assertStaticGeometryEqual(_ lhs: CityScape, _ rhs: CityScape, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(lhs.plots.map(\.id), rhs.plots.map(\.id), file: file, line: line)
        XCTAssertEqual(lhs.sortedPlots.map(\.id), rhs.sortedPlots.map(\.id), file: file, line: line)
        for (left, right) in zip(lhs.plots, rhs.plots) {
            XCTAssertEqual(left.gpuIndex, right.gpuIndex, file: file, line: line)
            XCTAssertEqual(left.gpuCount, right.gpuCount, file: file, line: line)
            XCTAssertEqual(left.gres.profile, right.gres.profile, file: file, line: line)
            XCTAssertEqual(left.gres.count, right.gres.count, file: file, line: line)
            XCTAssertEqual(left.x, right.x, accuracy: 1e-9, file: file, line: line)
            XCTAssertEqual(left.y, right.y, accuracy: 1e-9, file: file, line: line)
            XCTAssertEqual(left.w, right.w, accuracy: 1e-9, file: file, line: line)
            XCTAssertEqual(left.d, right.d, accuracy: 1e-9, file: file, line: line)
            XCTAssertEqual(left.buildings, right.buildings, file: file, line: line)
            XCTAssertEqual(left.hasCrane, right.hasCrane, file: file, line: line)
            XCTAssertEqual(left.trees, right.trees, file: file, line: line)
            XCTAssertEqual(left.shops, right.shops, file: file, line: line)
            XCTAssertEqual(pointSignature(lhs.entryPath(for: left.id)), pointSignature(rhs.entryPath(for: right.id)), file: file, line: line)
        }
        XCTAssertEqual(lhs.blocks.map(\.id), rhs.blocks.map(\.id), file: file, line: line)
        for (left, right) in zip(lhs.blocks, rhs.blocks) {
            XCTAssertEqual(left.district, right.district, file: file, line: line)
            XCTAssertEqual(left.plotIDs, right.plotIDs, file: file, line: line)
            XCTAssertEqual(left.bounds.x, right.bounds.x, accuracy: 1e-9, file: file, line: line)
            XCTAssertEqual(left.bounds.y, right.bounds.y, accuracy: 1e-9, file: file, line: line)
            XCTAssertEqual(left.bounds.w, right.bounds.w, accuracy: 1e-9, file: file, line: line)
            XCTAssertEqual(left.bounds.d, right.bounds.d, accuracy: 1e-9, file: file, line: line)
        }
        XCTAssertEqual(nestedPointSignature(lhs.localStreets), nestedPointSignature(rhs.localStreets), file: file, line: line)
        XCTAssertEqual(pointSignature(lhs.lamps), pointSignature(rhs.lamps), file: file, line: line)
        XCTAssertEqual(lhs.furniture, rhs.furniture, file: file, line: line)
        XCTAssertEqual(lhs.sortedFurniture, rhs.sortedFurniture, file: file, line: line)
        XCTAssertEqual(pointSignature(lhs.avenue), pointSignature(rhs.avenue), file: file, line: line)
        XCTAssertEqual(routeSignature(lhs.trafficRouteMetrics), routeSignature(rhs.trafficRouteMetrics), file: file, line: line)
        XCTAssertEqual(pointSignature([lhs.bridgeDeck.min, lhs.bridgeDeck.max]), pointSignature([rhs.bridgeDeck.min, rhs.bridgeDeck.max]), file: file, line: line)
        XCTAssertEqual(pointSignature(lhs.river), pointSignature(rhs.river), file: file, line: line)
        XCTAssertEqual(lhs.plazas, rhs.plazas, file: file, line: line)
    }

    private func pointSignature(_ points: [(CGFloat, CGFloat)]?) -> [String] {
        pointSignature(points ?? [])
    }

    private func pointSignature(_ points: [(CGFloat, CGFloat)]) -> [String] {
        points.map { "\($0.0),\($0.1)" }
    }

    private func nestedPointSignature(_ points: [[(CGFloat, CGFloat)]]) -> [[String]] {
        points.map(pointSignature)
    }

    private func routeSignature(_ routes: [CityWhimsy.RouteMetrics]) -> [[String]] {
        routes.map { route in
            route.segments.map { "\($0.startX),\($0.startY),\($0.endX),\($0.endY),\($0.length),\($0.prefixLength)" } + ["length:\(route.length)"]
        }
    }
    func testCityScapeExposesIngressAndInternalLocalStreetsAfterAllocatorCutover() throws {
        let scape = CityScape.build(snapshot: try snapshot(sinfo: """
        h200-01|idle|gpu:H200:4
        l4-01|idle|gpu:L4:2
        """))
        XCTAssertGreaterThan(scape.localStreets.count, scape.plots.count)
        XCTAssertTrue(scape.localStreets.allSatisfy { $0.count >= 2 })
    }
    func testStreetFurnitureIsDeterministicAndClearOfPlotsAndRoadCenterlines() throws {
        let snapshot = try snapshot(sinfo: """
        h200-01|idle|gpu:H200:4
        a100-01|idle|gpu:A100:2
        """)
        let first = CityScape.build(snapshot: snapshot)
        let second = CityScape.build(snapshot: snapshot)

        XCTAssertEqual(first.furniture, second.furniture)
        XCTAssertFalse(first.furniture.isEmpty)
        for piece in first.furniture {
            XCTAssertGreaterThanOrEqual(
                first.localStreets.map { distance(from: (piece.x, piece.y), to: $0) }.min() ?? 0,
                0.55,
                "furniture must clear each local street centerline"
            )
            for plot in first.plots {
                XCTAssertFalse(
                    CGRect(x: plot.x, y: plot.y, width: plot.w, height: plot.d).insetBy(dx: -0.3, dy: -0.3).contains(CGPoint(x: piece.x, y: piece.y)),
                    "furniture must not occupy plot \(plot.id)"
                )
            }
        }
    }
    func testStaticSceneSidewalksCoverEveryStreetPairAndAvenuePair() throws {
        let scape = CityScape.build(snapshot: try snapshot(sinfo: """
        h200-01|idle|gpu:H200:2
        a100-01|idle|gpu:A100:1
        """))
        let paths = CitySceneStaticPaths(scape: scape)

        XCTAssertEqual(paths.sidewalks.count, scape.localStreets.count * 2 + 2)
        XCTAssertEqual(paths.geometrySignature[4], paths.sidewalks.count)
        XCTAssertEqual(paths.geometrySignature[5], 1)
    }
    func testBlobOcclusionHidesActorsBehindBuildingsAndKeepsFrontActorsVisible() throws {
        let scape = CityScape.build(snapshot: try snapshot(sinfo: "h200-01|idle|gpu:H200:1"))
        let plot = try XCTUnwrap(scape.plots.only)
        let field = CityOcclusionField(
            // Exercise building occlusion independently of nearby landmark geometry.
            occluders: CitySceneStaticPaths(scape: scape).occluders.filter { $0.plotID == plot.id },
            densityStages: Dictionary(uniqueKeysWithValues: scape.plots.map { ($0.id, CityDensity.stageCount) })
        )
        let building = try XCTUnwrap(plot.buildings.max { ($0.oy + $0.bd) < ($1.oy + $1.bd) })
        let bx = plot.x + building.ox, by = plot.y + building.oy
        XCTAssertTrue(
            field.isHidden(worldX: bx + building.bw / 2, worldY: by - 0.2, z: 0.5),
            "an actor just behind the back wall must be hidden by the building silhouette"
        )
        XCTAssertFalse(
            field.isHidden(worldX: bx + building.bw / 2, worldY: by + building.bd + 0.2, z: 0.5),
            "an actor just in front of the front wall must stay visible despite z-lift"
        )
    }

    func testPosedGolemOcclusionFollowsRaisedHeadWithoutSelfPunch() throws {
        let asleep = CityIsometricTitanGeometry(x: 0, y: 0)
        let awake = CityIsometricTitanGeometry(x: 0, y: 0, wake: 1, breath: 1)
        let top = try XCTUnwrap(awake.head.facets.first { $0.light == .top })
        let point = top.projectedPoints.reduce(CGPoint.zero) {
            CGPoint(x: $0.x + $1.x / CGFloat(top.projectedPoints.count),
                    y: $0.y + $1.y / CGFloat(top.projectedPoints.count))
        }
        let bounds = CGRect(x: point.x - 0.1, y: point.y - 0.1, width: 0.2, height: 0.2)
        func mask(for pose: CityIsometricTitanGeometry, excluding group: String? = nil) -> Path? {
            let field = CityOcclusionField(
                occluders: pose.dynamicSolids.map {
                    CitySceneStaticPaths.titanOccluder(solid: $0)
                },
                densityStages: [:]
            )
            return field.punchMask(
                worldX: awake.head.worldBounds.minX - 1,
                worldY: awake.head.worldBounds.minY - 1,
                spriteBounds: bounds,
                excluding: group
            )
        }
        XCTAssertFalse(mask(for: asleep)?.contains(point) ?? false)
        XCTAssertTrue(try XCTUnwrap(mask(for: awake)).contains(point))
        XCTAssertNil(mask(for: awake, excluding: "titan"))
    }

    func testHumanOcclusionMaskKeepsTheVisibleHalfAtBuildingEdges() throws {
        var silhouette = Path()
        silhouette.addRect(CGRect(x: 0, y: 0, width: 10, height: 10))
        let occluder = CitySceneStaticPaths.CachedOccluder(
            bounds: CGRect(x: 0, y: 0, width: 10, height: 10),
            silhouette: silhouette,
            rightWallX: 10,
            frontWallY: 10,
            plotID: "plot",
            revealStage: 0
        )
        let field = CityOcclusionField(occluders: [occluder], densityStages: [:])

        let mask = try XCTUnwrap(field.punchMask(
            worldX: 5,
            worldY: 5,
            spriteBounds: CGRect(x: 8, y: 4, width: 4, height: 4)
        ))

        XCTAssertTrue(mask.contains(CGPoint(x: 9, y: 6)))
        XCTAssertFalse(mask.contains(CGPoint(x: 11, y: 6)))
        XCTAssertNil(field.punchMask(
            worldX: 11,
            worldY: 5,
            spriteBounds: CGRect(x: 8, y: 4, width: 4, height: 4)
        ), "A person in front of a camera-facing wall must remain fully visible.")
    }
    func testGroundDynamicOcclusionPolicyHidesCarsAndTrafficLightsBehindBuildingFaces() throws {
        let scape = CityScape.build(snapshot: try snapshot(sinfo: "h200-01|idle|gpu:H200:1"))
        let plot = try XCTUnwrap(scape.plots.only)
        let field = CityOcclusionField(
            occluders: CitySceneStaticPaths(scape: scape).occluders.filter { $0.plotID == plot.id },
            densityStages: Dictionary(uniqueKeysWithValues: scape.plots.map { ($0.id, CityDensity.stageCount) })
        )
        let building = try XCTUnwrap(plot.buildings.max { ($0.oy + $0.bd) < ($1.oy + $1.bd) })
        let x = plot.x + building.ox + building.bw / 2
        let y = plot.y + building.oy - 0.2

        XCTAssertTrue(field.isHidden(worldX: x, worldY: y, z: 0.5), "cars must be occluded behind both building faces")
        XCTAssertTrue(field.isHidden(worldX: x, worldY: y, z: 1.1), "traffic-light housings must be occluded behind both building faces")
    }
    func testStaticScenePathsBuildDeterministicallyForAtlasGeometry() throws {
        let scape = CityScape.build(snapshot: try snapshot(sinfo: """
        h200-01|idle|gpu:H200:2
        a100-01|idle|gpu:A100:1
        """))

        let first = CitySceneStaticPaths(scape: scape)
        let second = CitySceneStaticPaths(scape: scape)

        XCTAssertGreaterThan(first.gridPathCount, 0)
        XCTAssertGreaterThan(first.roadPathCount, 0)
        XCTAssertGreaterThan(first.localStreetPathCount, 0)
        XCTAssertGreaterThan(first.laneMarkingPathCount, 0)
        XCTAssertEqual(first.sidewalks.count, scape.localStreets.count * 2 + 2)
        XCTAssertEqual(first.geometrySignature[4], first.sidewalks.count)
        XCTAssertEqual(first.geometrySignature[5], 1)
        XCTAssertEqual(first.geometrySignature, second.geometrySignature)
    }

    func testPlacementPlanResolvesDeterministicCommuteSeatsClearOfOccupancy() throws {
        let scape = CityScape.build(snapshot: try snapshot(sinfo: """
        h200-01|alloc|gpu:H200:4
        a100-01|alloc|gpu:A100:4
        l40s-01|alloc|gpu:L40S:4
        """))
        let first = CitySceneStaticPaths(scape: scape)
        let second = CitySceneStaticPaths(scape: scape)

        XCTAssertEqual(first.placement, second.placement)
        XCTAssertFalse(first.placement.commuteSpots.isEmpty)
        for (plotID, spots) in first.placement.commuteSpots {
            let plot = try XCTUnwrap(scape.plots.first { $0.id == plotID })
            for spot in spots {
                let footprint = CGRect(x: spot.x - 0.75, y: spot.y - 0.35, width: 1.5, height: 0.7)
                XCTAssertTrue(
                    first.occupancy.isClear(rect: footprint, blockedBy: [.building]),
                    "\(plotID) seat intersects a building"
                )
                XCTAssertTrue(
                    first.occupancy.isClear(
                        point: (spot.x, spot.y),
                        clearances: CityOccupancy.parkedCarBlockers
                    ),
                    "\(plotID) seat conflicts with resolved occupancy"
                )
                XCTAssertTrue(CGRect(x: plot.x, y: plot.y, width: plot.w, height: plot.d).contains(spot))
            }
        }
    }

    func testStaticGroundAndGridCoverEveryEnlargedLotWithPadding() throws {
        let scape = CityScape.build(snapshot: try snapshot(sinfo: """
        h200-01|idle|gpu:H200:4
        rtx-01|idle|gpu:RTX:4
        a100-01|idle|gpu:A100:4
        l40s-01|idle|gpu:L40S:4
        l4-01|idle|gpu:L4:4
        mig-01|idle|gpu:1g.20gb:4
        """))
        let paths = CitySceneStaticPaths(scape: scape)

        for plot in scape.plots {
            let lot = CGRect(x: plot.x, y: plot.y, width: plot.w, height: plot.d)
            XCTAssertTrue(paths.groundWorldBounds.contains(lot), "\(plot.id) extends beyond ground")
            XCTAssertTrue(paths.gridWorldBounds.contains(lot), "\(plot.id) extends beyond grid")
        }
    }

    func testNeonPhaseOffsetUsesStableUTF8Hash() {
        XCTAssertEqual(neonPhaseOffset(for: "h200-01"), 3)
        XCTAssertEqual(neonPhaseOffset(for: "h200-02"), 4)
    }
    func testRenderBoundsIncludeConstructionEnvelopeWhenOnlyOvershootRoofIsVisible() throws {
        let scape = CityScape.build(snapshot: try snapshot(sinfo: "h200-01|idle|gpu:H200:1"))
        let plot = try XCTUnwrap(scape.plots.only)
        let renderer = CityRenderer(
            scape: scape,
            staticPaths: CitySceneStaticPaths(scape: scape),
            reduceMotion: false
        )
        let rawHeight = max(CGFloat(10), try XCTUnwrap(plot.buildings.map(\.h).max()))
        let rawBounds = projectedBounds(for: plot, height: rawHeight)
        let envelopeHeight = max(CGFloat(10), rawHeight * constructionGrowScaleMaximum)
        let constructionEnvelopeBounds = projectedBounds(for: plot, height: envelopeHeight)
        let overshootOnlyViewport = CGRect(
            x: constructionEnvelopeBounds.minX,
            y: constructionEnvelopeBounds.minY,
            width: constructionEnvelopeBounds.width,
            height: (rawBounds.minY - constructionEnvelopeBounds.minY) / 2
        )

        XCTAssertGreaterThan(rawHeight, 10, "Fixture must be a high-rise.")
        XCTAssertFalse(rawBounds.intersects(overshootOnlyViewport), "The recorded roof is outside the viewport.")
        XCTAssertTrue(constructionEnvelopeBounds.intersects(overshootOnlyViewport))
        XCTAssertTrue(
            renderer.renderBounds(for: plot).intersects(overshootOnlyViewport),
            "The construction-envelope roof must keep the plot renderable."
        )
    }

    func testGrowScaleUsesBackOutConstructionCurveAndRespectsReducedMotion() {
        XCTAssertEqual(growScale(sinceStart: 0, delay: 0, reduceMotion: false), 0, accuracy: 1e-9)
        XCTAssertGreaterThan(growScale(sinceStart: 0.21, delay: 0, reduceMotion: false), 1.08)
        XCTAssertLessThan(growScale(sinceStart: 0.21, delay: 0, reduceMotion: false), 1.10)
        XCTAssertEqual(growScale(sinceStart: 0.42, delay: 0, reduceMotion: false), 1, accuracy: 1e-9)
        XCTAssertEqual(growScale(sinceStart: 0, delay: 0.3, reduceMotion: true), 1, accuracy: 1e-9)
    }

    func testQuantizedLocalDayFractionUsesStaticCadence() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let midnight = calendar.date(from: DateComponents(year: 2024, month: 1, day: 1))!
        let date = midnight.addingTimeInterval(43_201.19)

        XCTAssertEqual(
            quantizedLocalDayFraction(date: date, cadence: 0.35, calendar: calendar),
            43_200.85 / 86_400,
            accuracy: 1e-9
        )
    }

    func testPaletteDayFractionDemoWrapsEveryNinetySeconds() {
        let date = Date(timeIntervalSinceReferenceDate: 225)

        XCTAssertEqual(paletteDayFraction(date: date, demo: true), 0.5, accuracy: 1e-9)
    }

    func testPaletteDayFractionUsesInjectedCalendarForLocalTime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 5 * 3_600)!
        let midnight = calendar.date(from: DateComponents(year: 2024, month: 1, day: 1))!
        let date = midnight.addingTimeInterval(21_600)

        XCTAssertEqual(
            paletteDayFraction(date: date, demo: false, calendar: calendar),
            0.25,
            accuracy: 1e-9
        )
    }

    func testRetainedBasePolicyUsesBoundedCadenceAndInvalidationDelays() {
        XCTAssertEqual(CitySceneRenderPolicy.liveCadence(reduceMotion: false), 1 / 8, accuracy: 1e-12)
        XCTAssertEqual(CitySceneRenderPolicy.liveCadence(reduceMotion: true), 1, accuracy: 1e-12)
        XCTAssertEqual(CitySceneRenderPolicy.baseDelay(for: .camera, isVisible: true), .milliseconds(120))
        for invalidation in [CityBaseInvalidation.geometry, .palette, .displayScale, .visibility, .viewport] {
            XCTAssertEqual(CitySceneRenderPolicy.baseDelay(for: invalidation, isVisible: true), .zero)
        }
        XCTAssertNil(CitySceneRenderPolicy.baseDelay(for: .camera, isVisible: false))
    }

    func testRendererDetailPolicyKeepsFarTrafficAtEveryZoomBandAndScalesProvinceLife() {
        XCTAssertTrue(CityRenderer.drawsFarTraffic(in: .province))
        XCTAssertTrue(CityRenderer.drawsFarTraffic(in: .city))
        XCTAssertTrue(CityRenderer.drawsFarTraffic(in: .street))
    }

    func testCraneRenderingPolicyFollowsPlotEquipmentNotActivityMode() {
        for mode in [CityMode.lit, .half, .vacant, .closed] {
            XCTAssertTrue(CityRenderer.drawsCrane(hasCrane: true, mode: mode))
            XCTAssertFalse(CityRenderer.drawsCrane(hasCrane: false, mode: mode))
        }
    }

    func testProvinceActorsUseBoundsOnlyOcclusionPolicy() {
        XCTAssertTrue(CityRenderer.actorOcclusionUsesBoundsOnly(in: .province))
        XCTAssertFalse(CityRenderer.actorOcclusionUsesBoundsOnly(in: .city))
        XCTAssertFalse(CityRenderer.actorOcclusionUsesBoundsOnly(in: .street))
    }

    func testFacadeCellsAreShearedIntoIsometricFacePlanes() {
        let shear = 1.0 * IsoProjection.fy / IsoProjection.s
        var front = Path()
        CityRenderer.addFacadeCell(&front, center: CGPoint(x: 10, y: 10), halfW: 1, halfH: 1, sideFace: false)
        XCTAssertEqual(front.boundingRect.width, 2, accuracy: 0.001)
        XCTAssertEqual(front.boundingRect.height, 2 + 2 * shear, accuracy: 0.001, "front-face cell must shear with the +x facade slope, not stay an axis-aligned square")
        var side = Path()
        CityRenderer.addFacadeCell(&side, center: CGPoint(x: 10, y: 10), halfW: 1, halfH: 1, sideFace: true)
        XCTAssertEqual(side.boundingRect.height, 2 + 2 * shear, accuracy: 0.001)
        // Opposite shear directions: the shared left corner sits high on the front face, low on the side face.
        XCTAssertEqual((side.currentPoint?.y ?? 0) - (front.currentPoint?.y ?? 0), 2 * shear, accuracy: 0.001)
    }

    func testRendererLabelPlacementPolicyRejectsIntersectingGroups() {
        let candidates = [
            CGRect(x: 10, y: 10, width: 70, height: 30),
            CGRect(x: 45, y: 25, width: 60, height: 30),
            CGRect(x: 110, y: 10, width: 50, height: 20),
        ]

        XCTAssertEqual(
            CityRenderer.nonOverlappingLabelRects(candidates),
            [candidates[0], candidates[2]],
            "label groups must be emitted once and never overlap a previously emitted group"
        )
    }

    func testRendererWindowDensityAndShadowGeometryStayContinuousAcrossZoom() {
        XCTAssertEqual(CityRenderPolicies.windowFacadeOpacity(lod: CityDetailLevel(scale: 0.8, band: .province)), 0, accuracy: 1e-12)
        XCTAssertNotNil(
            CityRenderer.windowGrid(scale: 0.8, h: 9, bw: 5, bd: 4),
            "Window grid generation stays available; zero-fade opacity owns low-zoom rendering skip."
        )
        XCTAssertEqual(CityRenderer.windowGrid(scale: 1.9, h: 9, bw: 5, bd: 4), .init(rows: 2, frontColumns: 1, sideColumns: 1))
        XCTAssertEqual(CityRenderer.windowGrid(scale: 3.2, h: 9, bw: 5, bd: 4), .init(rows: 2, frontColumns: 2, sideColumns: 2))

        let city = try! XCTUnwrap(CityRenderer.windowGrid(scale: 1.9, h: 9, bw: 5, bd: 4))
        let middle = try! XCTUnwrap(CityRenderer.windowGrid(scale: 2.5, h: 9, bw: 5, bd: 4))
        let street = try! XCTUnwrap(CityRenderer.windowGrid(scale: 3.2, h: 9, bw: 5, bd: 4))
        XCTAssertLessThanOrEqual(city.rows, middle.rows)
        XCTAssertLessThanOrEqual(middle.rows, street.rows)

        let quad = CityRenderer.shadowQuad(x: 0, y: 0, bw: 4, bd: 3, h: 10)
        XCTAssertEqual(quad.count, 4)
        XCTAssertEqual(quad[2].x - quad[1].x, 8.84, accuracy: 1e-9)
        XCTAssertEqual(quad[2].y - quad[1].y, 4.68, accuracy: 1e-9)

        for band in [ZoomBand.province, .city, .street] {
            XCTAssertEqual(
                CityRenderPolicies.shadowCasterCount(buildingCount: 3, band: band),
                3,
                "Every zoom must retain the separated per-building shadows used by the close view."
            )
        }
    }

    func testCityStreetBandsRenderWalkersOnTheStreetGraph() {
        XCTAssertFalse(CityRenderPolicies.shouldDrawStrollers(band: .province))
        XCTAssertTrue(CityRenderPolicies.shouldDrawStrollers(band: .city))
        XCTAssertTrue(CityRenderPolicies.shouldDrawStrollers(band: .street))
    }

    func testLampGroundPoolsAndFixturesStraddlePlotGeometry() {
        XCTAssertEqual(
            CityRenderPolicies.streetFixtureCompositeOrder,
            [.groundLightPools, .depthSortedGeometry],
            "Ground illumination belongs below plot slabs; lamp fixtures and plots share world-depth ordering."
        )
    }

    func testForestTreesShareWorldDepthOrderingWithPlotSlabs() throws {
        let scape = CityScape.build(snapshot: try snapshot(sinfo: """
        h200-01|idle|gpu:H200:1
        """))
        let plot = try XCTUnwrap(scape.plots.first)
        let behind = Tree(x: plot.x - 1, y: plot.y - 1, size: 1)
        let inFront = Tree(x: plot.x + plot.w + 1, y: plot.y + plot.d + 1, size: 1)

        XCTAssertEqual(
            CityRenderer.baseWorldDepthItems(
                plots: [plot],
                forest: [behind, inFront],
                lamps: []
            ).map(\.kind),
            [.forestTree, .plot, .forestTree],
            "A foreground tree must paint after a farther plot slab instead of being buried under it."
        )
    }

    func testSleepingTitanMassesInterleaveWithForestDepth() {
        let titan = CityIsometricTitanGeometry(x: 10, y: 10)
        // The head assembly, the sky-side shoulder, and its arm draw in the
        // live overlay so wake/breath animate per frame; only the grounded
        // masses interleave with world depth here.
        let sortedKeys = titan.groundedSolids.map(\.sortKey)
        let interleavedKey = (sortedKeys[0] + sortedKeys[1]) / 2
        let betweenMasses = Tree(x: interleavedKey / 2, y: interleavedKey / 2, size: 1)

        let items = CityRenderer.baseWorldDepthItems(
            plots: [],
            forest: [betweenMasses],
            lamps: [],
            titan: titan
        )
        let titanCount = items.filter { $0.kind == .titan }.count
        let treeCount = items.filter { $0.kind == .forestTree }.count
        
        XCTAssertEqual(
            titanCount,
            titan.groundedSolids.count,
            "Every grounded titan solid must appear in the base depth queue."
        )
        XCTAssertEqual(treeCount, 1, "Exactly one synthetic forest tree.")
        
        let titanIndices = items.indices.filter { items[$0].kind == .titan }
        let treeIndex = try? XCTUnwrap(items.firstIndex { $0.kind == .forestTree })
        XCTAssertGreaterThanOrEqual(titanIndices.count, 2)
        if titanIndices.count >= 2, let treeIndex {
            XCTAssertTrue(
                treeIndex > titanIndices[0] && treeIndex < titanIndices[1],
                "World geometry between titan masses must remain visible instead of being covered by one aggregate draw."
            )
        }
    }

    func testHumanSilhouetteStaysSmallerThanFacadeWindowPitch() {
        XCTAssertLessThanOrEqual(CityRenderer.humanWorldHeight, 0.55)
        XCTAssertEqual(CityRenderer.maxBuildingWorldHeight, 20)
    }

    func testVisibleResidentsScaleWithGPUCapacityAndJobPressureButStayCapped() {
        XCTAssertEqual(CityRenderer.visibleResidentCount(gpuCount: 8, jobPressure: 1), 12)
        XCTAssertEqual(CityRenderer.visibleResidentCount(gpuCount: 8, jobPressure: 0.25), 6)
        XCTAssertEqual(CityRenderer.visibleResidentCount(gpuCount: 8, jobPressure: 0), 0)
    }

    func testPavilionWindowsUseJobPressureInsteadOfStaticNightHashes() {
        let building = BuildingSpec(
            ox: 1, oy: 2, bw: 5, bd: 4, h: 8,
            crackSeed: false,
            facade: RGB(r: 100, g: 120, b: 140)
        )
        let idle = (0..<200).count {
            CityRenderer.pavilionWindowIsLit(
                plotID: "occupancy", building: building, sequence: $0, t: 0.78, jobPressure: 0
            )
        }
        let busy = (0..<200).count {
            CityRenderer.pavilionWindowIsLit(
                plotID: "occupancy", building: building, sequence: $0, t: 0.78, jobPressure: 1
            )
        }

        XCTAssertEqual(idle, 0)
        XCTAssertGreaterThan(busy, 150)
    }

    func testVoxelTreeCanopyCountIsAlwaysOneThroughThreeForStableSeeds() {
        for index in 0..<128 {
            let count = CityRenderer.voxelTreeCanopyCount(x: CGFloat(index) * 0.37, y: CGFloat(index) * -0.61)
            XCTAssertTrue((1...3).contains(count), "seed \(index) produced \(count)")
        }
    }
    func testCachedOccludersMatchLegacyBuildingSilhouettesOnSceneProbeGrid() throws {
        let scape = CityScape.build(snapshot: try snapshot(sinfo: """
        h200-01|alloc|gpu:H200:1
        a100-01|alloc|gpu:A100:1
        """))
        let staticPaths = CitySceneStaticPaths(scape: scape)
        let fullyRevealed = Dictionary(uniqueKeysWithValues: scape.plots.map { ($0.id, 10) })
        let buildingPlotIDs = Set(scape.plots.map(\.id))
        let buildingOccluders = staticPaths.occluders.filter { buildingPlotIDs.contains($0.plotID) }
        let field = CityOcclusionField(occluders: buildingOccluders, densityStages: fullyRevealed)

        XCTAssertFalse(buildingOccluders.isEmpty)
        for x in stride(from: CGFloat(-8), through: 116, by: 4) {
            for y in stride(from: CGFloat(-8), through: 116, by: 4) {
                for z: CGFloat in [0.18, 0.5, 1.1] {
                    XCTAssertEqual(
                        legacyBlobIsOccluded(worldX: x, worldY: y, z: z, scape: scape),
                        field.isHidden(worldX: x, worldY: y, z: z),
                        "probe (\(x), \(y), \(z))"
                    )
                }
            }
        }
    }

    func testFutureDensityBuildingsDoNotOccludeActorsBeforeReveal() throws {
        let scape = CityScape.build(snapshot: try snapshot(sinfo: """
        h200-01|alloc|gpu:H200:1
        """))
        let paths = CitySceneStaticPaths(scape: scape)
        let future = try XCTUnwrap(paths.occluders.first { $0.revealStage > 0 })
        let hidden = CityOcclusionField(occluders: paths.occluders, densityStages: [:])
        let revealed = CityOcclusionField(
            occluders: paths.occluders,
            densityStages: [future.plotID: future.revealStage]
        )

        XCTAssertFalse(hidden.occluderIsActive(future))
        XCTAssertTrue(revealed.occluderIsActive(future))
    }

    func testSceneBuildPrecomputesRenderAndRouteCaches() throws {
        let scape = CityScape.build(snapshot: try snapshot(sinfo: "h200-01|idle|gpu:H200:1"))
        let staticPaths = CitySceneStaticPaths(scape: scape)

        XCTAssertEqual(staticPaths.renderBoundsByPlotID.count, scape.plots.count)
        XCTAssertFalse(staticPaths.avenuePath.cgPath.isEmpty)
        XCTAssertEqual(scape.sortedFurniture, scape.furniture.sorted { $0.x + $0.y < $1.x + $1.y })
        XCTAssertEqual(scape.trafficRouteMetrics.count, 1 + scape.localStreets.count)
        XCTAssertEqual(scape.entryRouteMetricsByPlotID.count, scape.plots.count)
        for plot in scape.plots {
            let metrics = try XCTUnwrap(scape.entryRouteMetrics(for: plot.id))
            let path = try XCTUnwrap(scape.entryPath(for: plot.id))
            let sampledStart = metrics.sample(progress: 0)
            let sampledEnd = metrics.sample(progress: 1)
            XCTAssertEqual(sampledStart.x, path[0].0, accuracy: 1e-9)
            XCTAssertEqual(sampledStart.y, path[0].1, accuracy: 1e-9)
            XCTAssertEqual(sampledEnd.x, path[path.count - 1].0, accuracy: 1e-9)
            XCTAssertEqual(sampledEnd.y, path[path.count - 1].1, accuracy: 1e-9)
        }
    }
    func testBubbleTimingIsVisibleForFourSecondsAndFadesDuringFinalHalfSecond() {
        let shown = Date(timeIntervalSinceReferenceDate: 1_000)

        XCTAssertEqual(CityBubbleTiming.opacity(shownAt: shown, now: shown.addingTimeInterval(3.49)), 1, accuracy: 1e-9)
        XCTAssertEqual(CityBubbleTiming.opacity(shownAt: shown, now: shown.addingTimeInterval(3.75)), 0.5, accuracy: 1e-9)
        XCTAssertEqual(CityBubbleTiming.opacity(shownAt: shown, now: shown.addingTimeInterval(4)), 0, accuracy: 1e-9)
    }

    func testTooltipPlateMeasuresAndClampsInsideCanvas() {
        let plate = CityTooltipLayout.plate(
            preferredSize: CGSize(width: 180, height: 22),
            anchoredAt: CGPoint(x: 195, y: 2),
            canvasSize: CGSize(width: 200, height: 100)
        )

        XCTAssertEqual(plate.maxX, 196, accuracy: 1e-9)
        XCTAssertEqual(plate.minY, 4, accuracy: 1e-9)
        XCTAssertTrue(CGRect(x: 4, y: 4, width: 192, height: 92).contains(plate))
    }

    func testWaterShimmerRequiresAtLeastTwoRiverPoints() {
        XCTAssertFalse(CityRenderPolicies.canDrawWaterShimmer([(0, 0)]))
        XCTAssertTrue(CityRenderPolicies.canDrawWaterShimmer([(0, 0), (1, 1)]))
        XCTAssertTrue(CityRenderPolicies.canDrawWaterShimmer([(0, 0), (1, 1), (2, 0)]))
    }

    func testSearchlightRequiresItsRooftopApexInsideVisibleWorldRect() {
        let visibleWorldRect = CGRect(x: 0, y: 0, width: 100, height: 80)
        let offscreenApex = CGPoint(x: -1, y: 40)
        let intrudingBeamBounds = CGRect(x: -1, y: 22, width: 34, height: 36)

        XCTAssertTrue(intrudingBeamBounds.intersects(visibleWorldRect), "Fixture requires a beam triangle that enters the viewport.")
        XCTAssertFalse(
            CityRenderPolicies.shouldDrawSearchlight(apex: offscreenApex, in: visibleWorldRect),
            "A beam whose off-screen rooftop apex is clipped must not paint its orphaned triangle."
        )
        for band in [ZoomBand.province, .city, .street] {
            XCTAssertTrue(
                CityRenderPolicies.shouldDrawSearchlight(apex: CGPoint(x: 0, y: 40), in: visibleWorldRect),
                "An on-screen rooftop apex must keep the H200 searchlight visible at \(band) zoom."
            )
        }
    }

    func testSearchlightGeometryKeepsOriginalConeAtLowScale() {
        let angle = Angle.radians(-0.85)
        let radians = angle.radians
        let dx = CGFloat(cos(radians))
        let dy = CGFloat(sin(radians))
        let apex = IsoProjection.project(0, 0, 0)
        let expectedTip = IsoProjection.project(dx * 26, dy * 26, 6)
        let expectedLeft = IsoProjection.project(dx * 26 - dy * 1.5, dy * 26 + dx * 1.5, 6)
        let expectedRight = IsoProjection.project(dx * 26 + dy * 1.5, dy * 26 - dx * 1.5, 6)

        let geometry = CityRenderPolicies.searchlightGeometry(apex: apex, angle: angle, cameraScale: 0.2)

        XCTAssertEqual(geometry.tip.x, expectedTip.x, accuracy: 1e-9)
        XCTAssertEqual(geometry.tip.y, expectedTip.y, accuracy: 1e-9)
        XCTAssertEqual(geometry.left.x, expectedLeft.x, accuracy: 1e-9)
        XCTAssertEqual(geometry.left.y, expectedLeft.y, accuracy: 1e-9)
        XCTAssertEqual(geometry.right.x, expectedRight.x, accuracy: 1e-9)
        XCTAssertEqual(geometry.right.y, expectedRight.y, accuracy: 1e-9)
    }

    func testSearchlightGeometryCapsScreenFootprintAndStaysVisibleAtEveryZoomBand() {
        let apex = CGPoint(x: 50, y: 40)
        let angle = Angle.radians(-0.85)
        let baseline = CityRenderPolicies.searchlightGeometry(apex: apex, angle: angle, cameraScale: 0.2)
        let baselineDirection = CGVector(dx: baseline.tip.x - apex.x, dy: baseline.tip.y - apex.y)

        for (scale, band) in [(CGFloat(1), ZoomBand.province), (3, .city), (8, .street)] {
            let geometry = CityRenderPolicies.searchlightGeometry(apex: apex, angle: angle, cameraScale: scale)
            let direction = CGVector(dx: geometry.tip.x - apex.x, dy: geometry.tip.y - apex.y)
            let crossProduct = baselineDirection.dx * direction.dy - baselineDirection.dy * direction.dx

            XCTAssertTrue(
                CityRenderPolicies.shouldDrawSearchlight(apex: apex, in: CGRect(x: 0, y: 0, width: 100, height: 80)),
                "The H200 searchlight must remain enabled at \(band) zoom."
            )
            XCTAssertGreaterThan(geometry.screenLength, 0, "The beam must retain nonzero length at \(band) zoom.")
            XCTAssertGreaterThan(geometry.screenHalfWidth, 0, "The beam must retain nonzero width at \(band) zoom.")
            XCTAssertLessThanOrEqual(geometry.screenLength, 80.000_001, "The beam must stay within its screen-length cap at \(band) zoom.")
            XCTAssertLessThanOrEqual(geometry.screenHalfWidth, 5.500_001, "The beam must stay within its screen half-width cap at \(band) zoom.")
            XCTAssertEqual(crossProduct, 0, accuracy: 1e-7, "Capping must preserve the searchlight sweep direction at \(band) zoom.")
        }
    }

    func testHeadlightConesAreStreetOnlyAndSubordinate() throws {
        XCTAssertNil(
            CityRenderPolicies.headlightCone(band: .province),
            "Province cars are pixel-scale; a cone per car outshines the searchlight and tells false stories."
        )
        XCTAssertNil(
            CityRenderPolicies.headlightCone(band: .city),
            "City-band headlight cones must not compete with the flagship searchlight."
        )
        let street = try XCTUnwrap(CityRenderPolicies.headlightCone(band: .street))
        XCTAssertLessThanOrEqual(street.length, 1.4, "Street cones stay half their former reach.")
        XCTAssertLessThanOrEqual(street.alpha, 0.10, "Headlights rank below windows in the light hierarchy.")
    }


    func testHardwareSignStatesTheFactOnceAndSkipsGPUOneOfOne() {
        XCTAssertEqual(
            CityRenderer.hardwareSignText(gpuIndex: 1, gpuCount: 1, gpuType: "H200", vramGB: 80),
            "H200 · POP 80 GB"
        )
        XCTAssertEqual(
            CityRenderer.hardwareSignText(gpuIndex: 2, gpuCount: 4, gpuType: "MIG", vramGB: 20),
            "GPU 2/4 · MIG · POP 20 GB"
        )
    }

    func testNegativeHorizontalHeadingMirrorsVoxelCitizen() {
        XCTAssertTrue(CityRenderPolicies.shouldMirrorBlob(heading: CGSize(width: -0.1, height: 3)))
        XCTAssertFalse(CityRenderPolicies.shouldMirrorBlob(heading: CGSize(width: 0, height: 3)))
    }

    func testDoubleTapIntentTakesPrecedenceOverSelectionIntent() {
        XCTAssertEqual(CityTapIntent.resolve(doubleTapRecognized: true), .focus)
        XCTAssertEqual(CityTapIntent.resolve(doubleTapRecognized: false), .select)
    }
    func testCitizenHitReturnsTheTappedCitizenIndexForMultiJobPlot() throws {
        let scape = CityScape.build(snapshot: try snapshot(
            sinfo: "h200-01|alloc|gpu:H200:1",
            squeue: """
            100|alice|train-a|RUNNING|01:00:00|02:00:00|1|h200-01|h200-01
            101|bob|train-b|RUNNING|01:00:00|02:00:00|1|h200-01|h200-01
            """
        ))
        let plot = try XCTUnwrap(scape.plots.only)
        XCTAssertEqual(plot.mode, .lit)
        XCTAssertEqual(plot.node.jobs.count, 2)
        let citizenIndex = 1
        let camera = CityCamera(scale: 20, translation: .zero)
        let offset = CGFloat(sin(Double(citizenIndex))) * 1.6
        let position = camera.apply(IsoProjection.project(
            plot.x + 1.6 + CGFloat(citizenIndex) * max(1, (plot.w - 3) / 5) + offset,
            plot.y + plot.d - 0.8,
            1
        ))

        let hit = try XCTUnwrap(
            CitySceneHitTest.citizen(
                at: position,
                in: scape,
                date: Date(timeIntervalSinceReferenceDate: 1_000),
                reduceMotion: true,
                camera: camera
            )
        )

        XCTAssertEqual(hit.citizenIndex, citizenIndex)
        XCTAssertEqual(hit.job.id, "101")
    }

    func testTooltipStyleUsesWhiteTextOnDarkPlate() {
        XCTAssertEqual(CityTooltipStyle.foreground, .white)
    }

    func testTapResolutionFocusClearsSelectionWhileSelectOpensHUD() {
        XCTAssertEqual(
            CityTapResolution.apply(intent: .focus, plotID: "n10", selectedPlotID: "n7"),
            CityTapResolution(selectedPlotID: nil, shouldFocus: true)
        )
        XCTAssertEqual(
            CityTapResolution.apply(intent: .select, plotID: "n10", selectedPlotID: nil),
            CityTapResolution(selectedPlotID: "n10", shouldFocus: false)
        )
    }

    private func legacyBlobIsOccluded(worldX: CGFloat, worldY: CGFloat, z: CGFloat, scape: CityScape) -> Bool {
        let point = IsoProjection.project(worldX, worldY, z)
        for plot in scape.plots {
            for building in plot.buildings {
                let bx = plot.x + building.ox
                let by = plot.y + building.oy
                guard worldX < bx + building.bw - 0.05, worldY < by + building.bd - 0.05 else { continue }
                var silhouette = Path()
                silhouette.addLines([
                    IsoProjection.project(bx, by, building.h),
                    IsoProjection.project(bx + building.bw, by, building.h),
                    IsoProjection.project(bx + building.bw, by, 0),
                    IsoProjection.project(bx + building.bw, by + building.bd, 0),
                    IsoProjection.project(bx, by + building.bd, 0),
                    IsoProjection.project(bx, by + building.bd, building.h),
                ])
                silhouette.closeSubpath()
                if silhouette.contains(point) { return true }
            }
        }
        return false
    }
    private func projectedBounds(for plot: CityPlot, height: CGFloat) -> CGRect {
        let corners = [
            IsoProjection.project(plot.x, plot.y),
            IsoProjection.project(plot.x + plot.w, plot.y),
            IsoProjection.project(plot.x, plot.y + plot.d),
            IsoProjection.project(plot.x + plot.w, plot.y + plot.d),
            IsoProjection.project(plot.x, plot.y, height),
            IsoProjection.project(plot.x + plot.w, plot.y, height),
            IsoProjection.project(plot.x, plot.y + plot.d, height),
            IsoProjection.project(plot.x + plot.w, plot.y + plot.d, height),
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

    private func snapshot(sinfo: String, squeue: String = "") throws -> ClusterSnapshot {
        try SlurmParser.parseSnapshot(
            """
            ===SINFO===
            \(sinfo)
            ===SQUEUE===
            \(squeue)
            ===RC=== 0 0
            """,
            now: Date(timeIntervalSince1970: 1_000)
        )
    }

    private func isOnPath(
        _ point: (x: CGFloat, y: CGFloat, alongX: Bool),
        path: [(CGFloat, CGFloat)]
    ) -> Bool {
        zip(path, path.dropFirst()).contains { start, end in
            let minX = min(start.0, end.0)
            let maxX = max(start.0, end.0)
            let minY = min(start.1, end.1)
            let maxY = max(start.1, end.1)
            let liesOnHorizontal = start.1 == end.1 && point.y == start.1 && point.x >= minX && point.x <= maxX
            let liesOnVertical = start.0 == end.0 && point.x == start.0 && point.y >= minY && point.y <= maxY
            return liesOnHorizontal || liesOnVertical
        }
    }
}

private extension Array {
    var only: Element? {
        count == 1 ? first : nil
    }
}
