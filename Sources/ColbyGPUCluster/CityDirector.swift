import CoreGraphics
import Foundation
import Observation
import SwiftUI

@MainActor @Observable
final class CityDirector {
    struct CommuteCar: Identifiable {
        enum Phase: Equatable {
            case arriving(start: Date)
            case parked
            case leaving(start: Date)
        }

        let jobID: String
        let plotID: String
        /// Body paint in RGB token space so the renderer can nightify it.
        let colorToken: RGB
        var phase: Phase

        var id: String { "\(plotID)|\(jobID)" }
    }

    static let commuteDuration: TimeInterval = 2.4

    /// One in-flight construction animation: a plot rising from its settled
    /// stage toward a higher job-progress target.
    struct DensityTransition: Equatable {
        let fromStage: Int
        let toStage: Int
        let start: Date
    }

    static let densityTransitionDuration: TimeInterval = 1.15


    private(set) var cars: [CommuteCar] = []
    /// Plots whose node recently finished a job: plot id -> launch date for
    /// the celebratory firework. Entries expire after the burst plays out.
    private(set) var celebrationsByPlot: [String: Date] = [:]

    /// Settled per-plot density stage: what the retained base renders.
    private(set) var settledStages: [String: Int] = [:]
    /// Active construction animations keyed by plot id.
    private(set) var densityTransitions: [String: CityDirector.DensityTransition] = [:]

    private var seenJobIDsByPlot: [String: Set<String>] = [:]
    private var hasReconciled = false


    func reconcile(scape: CityScape, date: Date, reduceMotion: Bool, band: ZoomBand) {

        promoteArrivalsAndExpireDepartures(at: date)
        celebrationsByPlot = celebrationsByPlot.filter { date.timeIntervalSince($0.value) < 3.5 }

        let plotsByID = Dictionary(uniqueKeysWithValues: scape.plots.map { ($0.id, $0) })
        let currentPlotIDs = Set(plotsByID.keys)
        let disappearedPlotIDs = Set(seenJobIDsByPlot.keys).subtracting(currentPlotIDs)

        for plotID in disappearedPlotIDs {
            seenJobIDsByPlot.removeValue(forKey: plotID)
            celebrationsByPlot.removeValue(forKey: plotID)
            settledStages.removeValue(forKey: plotID)
            densityTransitions.removeValue(forKey: plotID)
        }
        if !disappearedPlotIDs.isEmpty {
            cars.removeAll { disappearedPlotIDs.contains($0.plotID) }
        }


        reconcileDensity(scape: scape, date: date)

        for plot in scape.plots {
            let plotID = plot.id
            let isEligible = plot.mode == .lit || plot.mode == .half
            let previousObservedJobIDs = seenJobIDsByPlot[plotID, default: []]
            let jobsForCars = band == .province ? [] : plot.node.jobs
            let observedJobIDs = Set(plot.node.jobs.map(\.id))
            let renderedJobIDs = isEligible ? Set(jobsForCars.map(\.id)) : []
            let jobsByID = Dictionary(uniqueKeysWithValues: plot.node.jobs.map { ($0.id, $0) })

            if !hasReconciled {
                for jobID in renderedJobIDs {
                    addOrUpdateCar(
                        jobID: jobID,
                        plotID: plotID,
                        colorToken: carColorRGB(for: jobsByID[jobID]?.user ?? jobID),
                        phase: .parked
                    )
                }
            } else if reduceMotion {
                for jobID in renderedJobIDs {
                    addOrUpdateCar(
                        jobID: jobID,
                        plotID: plotID,
                        colorToken: carColorRGB(for: jobsByID[jobID]?.user ?? jobID),
                        phase: .parked
                    )
                }
                cars.removeAll { $0.plotID == plotID && !renderedJobIDs.contains($0.jobID) }
            } else {
                let arrivingJobIDs = observedJobIDs.subtracting(previousObservedJobIDs)
                let departedJobIDs = previousObservedJobIDs.subtracting(observedJobIDs)

                for jobID in renderedJobIDs {
                    if arrivingJobIDs.contains(jobID) {
                        addOrUpdateCar(
                            jobID: jobID,
                            plotID: plotID,
                            colorToken: carColorRGB(for: jobsByID[jobID]?.user ?? jobID),
                            phase: .arriving(start: date)
                        )
                    } else if !cars.contains(where: { $0.jobID == jobID && $0.plotID == plotID }) {
                        addOrUpdateCar(
                            jobID: jobID,
                            plotID: plotID,
                            colorToken: carColorRGB(for: jobsByID[jobID]?.user ?? jobID),
                            phase: .parked
                        )
                    }
                }
                for jobID in departedJobIDs {
                    setPhase(for: jobID, in: plotID, to: .leaving(start: date))
                }
                // A freed job earns the plot a firework burst.
                if !departedJobIDs.isEmpty {
                    celebrationsByPlot[plotID] = date
                }
                cars.removeAll {
                    $0.plotID == plotID &&
                    !renderedJobIDs.contains($0.jobID) &&
                    !departedJobIDs.contains($0.jobID)
                }
            }


            seenJobIDsByPlot[plotID] = observedJobIDs
        }

        reconcileTitanWake(scape: scape, date: date)
        hasReconciled = true
    }

    // MARK: - Titan wake

    /// Eased 0..1 wakefulness target for the corner titan; 1 only when every
    /// allocatable GPU in the atlas is running work.
    private(set) var titanWakeTarget: Double = 0
    private var titanWakeFrom: Double = 0
    private var titanWakeStart: Date = .distantPast
    static let titanWakeEase: TimeInterval = 1.6

    /// Displayed wake at `date`: a smoothstep ease from the value captured
    /// when the target last changed, so allocation flips read as stirring.
    func titanWake(at date: Date) -> Double {
        let progress = min(1, max(0, date.timeIntervalSince(titanWakeStart) / Self.titanWakeEase))
        let eased = progress * progress * (3 - 2 * progress)
        return titanWakeFrom + (titanWakeTarget - titanWakeFrom) * eased
    }

    private func reconcileTitanWake(scape: CityScape, date: Date) {
        var total = 0
        var used = 0
        var seen = Set<String>()
        for plot in scape.plots where seen.insert(plot.node.name).inserted {
            total += plot.node.totalGPUCount
            used += plot.node.totalGPUCount - plot.node.freeGPUCount
        }
        let fraction = total > 0 ? Double(used) / Double(total) : 0
        // Stirs from 50% upward; fully awake when every GPU is taken. The
        // old 80% floor never fired on a real cluster - busy days sit at
        // 50-90%, and the titan slept through all of them.
        let target = min(1, max(0, (fraction - 0.5) / 0.5))
        let shaped = target * target * (3 - 2 * target)
        guard abs(shaped - titanWakeTarget) > 0.01 else { return }
        titanWakeFrom = titanWake(at: date)
        titanWakeTarget = shaped
        titanWakeStart = date
    }

    /// Advances per-plot density toward job-derived targets. First reconcile
    /// adopts targets silently; later rises start a construction animation
    /// that the settled base picks up once the transition expires, and drops
    /// (job finished or vanished) settle immediately - the city calmly thins
    /// out rather than playing a demolition.
    private func reconcileDensity(scape: CityScape, date: Date) {
        for plot in scape.plots {
            let plotID = plot.id
            let target = CityDensity.stage(for: plot.node)
            guard hasReconciled else {
                settledStages[plotID] = target
                continue
            }
            if let transition = densityTransitions[plotID] {
                if date.timeIntervalSince(transition.start) >= Self.densityTransitionDuration {
                    settledStages[plotID] = transition.toStage
                    densityTransitions[plotID] = nil
                } else if target < transition.toStage {
                    // Target fell mid-rise: cancel and settle down at once.
                    densityTransitions[plotID] = nil
                    settledStages[plotID] = target
                    continue
                } else if target > transition.toStage {
                    densityTransitions[plotID] = DensityTransition(
                        fromStage: transition.fromStage,
                        toStage: target,
                        start: transition.start
                    )
                    continue
                } else {
                    continue
                }
            }
            let settled = settledStages[plotID] ?? 0
            if target > settled {
                densityTransitions[plotID] = DensityTransition(fromStage: settled, toStage: target, start: date)
            } else if target < settled {
                settledStages[plotID] = target
            } else if settledStages[plotID] == nil {
                settledStages[plotID] = target
            }
        }
    }

    /// Settled stages with any expired transitions folded in at `date`, so
    /// per-frame consumers see the finished stage even between reconciles.
    func effectiveStages(at date: Date) -> [String: Int] {
        guard !densityTransitions.isEmpty else { return settledStages }
        var stages = settledStages
        for (plotID, transition) in densityTransitions
        where date.timeIntervalSince(transition.start) >= Self.densityTransitionDuration {
            stages[plotID] = transition.toStage
        }
        return stages
    }

    /// Transitions still animating at `date`.
    func activeDensityTransitions(at date: Date) -> [String: DensityTransition] {
        densityTransitions.filter { date.timeIntervalSince($0.value.start) < Self.densityTransitionDuration }
    }

    func carWorldPos(
        _ car: CommuteCar,
        scape: CityScape,
        date: Date
    ) -> (x: CGFloat, y: CGFloat, alongX: Bool)? {

        switch car.phase {
        case .parked:
            guard let plot = scape.plots.first(where: { $0.id == car.plotID }) else {
                return nil
            }
            // Route anchor only: the renderer re-seats parked cars into
            // validated curb slots (buildings can cover the authored corner).
            return (plot.lotCorner.x, plot.lotCorner.y, true)
        case let .arriving(start):
            guard let metrics = scape.entryRouteMetrics(for: car.plotID) else { return nil }
            return metrics.sample(progress: easedProgress(since: start, at: date))
        case let .leaving(start):
            guard let metrics = scape.entryRouteMetrics(for: car.plotID) else { return nil }
            return metrics.sample(progress: 1 - easedProgress(since: start, at: date))
        }
    }

    /// Route-following positions for all non-parked cars of a plot with a
    /// minimum following gap and right-hand lanes. Cars per direction are
    /// sorted by (progress, id); a car closer than `minGap` behind its leader
    /// is held back. Deterministic for a fixed car set and date.
    func spacedCarPositions(
        plotID: String,
        scape: CityScape,
        date: Date
    ) -> [String: (x: CGFloat, y: CGFloat, alongX: Bool)] {
        guard let metrics = scape.entryRouteMetrics(for: plotID), metrics.length > 0 else {
            return [:]
        }
        enum Direction {
            case arriving
            case leaving
        }
        let moving: [(id: String, progress: CGFloat, direction: Direction)] = cars.compactMap { car in
            guard car.plotID == plotID else { return nil }
            switch car.phase {
            case let .arriving(start):
                return (car.id, easedProgress(since: start, at: date), .arriving)
            case let .leaving(start):
                return (car.id, easedProgress(since: start, at: date), .leaving)
            case .parked:
                return nil
            }
        }
        let minGap = 1.8 / metrics.length
        var result: [String: (x: CGFloat, y: CGFloat, alongX: Bool)] = [:]
        for direction in [Direction.arriving, Direction.leaving] {
            let convoy = moving
                .filter { $0.direction == direction }
                .sorted {
                    $0.progress == $1.progress
                        ? $0.id < $1.id
                        : $0.progress > $1.progress
                }
            var leaderProgress = CGFloat.infinity
            for car in convoy {
                let clamped = min(car.progress, leaderProgress - minGap)
                guard clamped >= 0 else { continue }
                leaderProgress = clamped
                let sampled = metrics.sample(
                    progress: direction == .arriving ? clamped : 1 - clamped
                )
                let lane: CGFloat = (direction == .arriving ? -1 : 1) * 0.28
                result[car.id] = (
                    sampled.x + (sampled.alongX ? 0 : lane),
                    sampled.y + (sampled.alongX ? lane : 0),
                    sampled.alongX
                )
            }
        }
        return result
    }


    private func promoteArrivalsAndExpireDepartures(at date: Date) {
        cars = cars.compactMap { car in
            switch car.phase {
            case let .arriving(start) where date.timeIntervalSince(start) >= Self.commuteDuration:
                return CommuteCar(jobID: car.jobID, plotID: car.plotID, colorToken: car.colorToken, phase: .parked)
            case let .leaving(start) where date.timeIntervalSince(start) >= Self.commuteDuration:
                return nil
            default:
                return car
            }
        }
    }

    private func addOrUpdateCar(jobID: String, plotID: String, colorToken: RGB, phase: CommuteCar.Phase) {
        cars.removeAll { $0.jobID == jobID && $0.plotID == plotID }
        cars.append(CommuteCar(jobID: jobID, plotID: plotID, colorToken: colorToken, phase: phase))
    }

    private func setPhase(for jobID: String, in plotID: String, to phase: CommuteCar.Phase) {
        guard let index = cars.firstIndex(where: { $0.jobID == jobID && $0.plotID == plotID }) else {
            return
        }
        cars[index].phase = phase
    }

    private func easedProgress(since start: Date, at date: Date) -> CGFloat {
        let raw = max(0, min(1, date.timeIntervalSince(start) / Self.commuteDuration))
        let t = CGFloat(raw)
        return t * t * (3 - 2 * t)
    }

}
