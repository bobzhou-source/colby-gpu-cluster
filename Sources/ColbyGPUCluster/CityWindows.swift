import Foundation

/// Bit-for-bit deterministic random primitives ported from the reference city's JavaScript helpers.
enum CityRandom {
    /// Stateful Mulberry32 pseudo-random generator with JavaScript's UInt32 overflow semantics.
    struct Mulberry32: Sendable {
        private var state: UInt32

        /// Creates a generator from a stable unsigned 32-bit seed.
        init(seed: UInt32) {
            state = seed
        }

        /// Returns the next pseudo-random fraction in the half-open interval `[0, 1)`.
        mutating func next() -> Double {
            state &+= 0x6D2B_79F5
            var value = (state ^ (state >> 15)) &* (1 | state)
            value = (value &+ ((value ^ (value >> 7)) &* (61 | value))) ^ value
            return Double(value ^ (value >> 14)) / 4_294_967_296
        }
    }

    /// FNV-1a hashes UTF-16 code units, exactly matching JavaScript's `strHash` input semantics.
    static func stringHash(_ string: String) -> UInt32 {
        string.utf16.reduce(UInt32(2_166_136_261)) { hash, codeUnit in
            (hash ^ UInt32(codeUnit)) &* 16_777_619
        }
    }

    /// Maps two integer inputs deterministically to a fraction in `[0, 1)`.
    static func hashFraction(_ first: Int, _ second: Int) -> Double {
        var value = UInt32(truncatingIfNeeded: first) &* 374_761_393
        value ^= UInt32(truncatingIfNeeded: second) &* 668_265_263
        value = (value ^ (value >> 13)) &* 1_274_126_177
        value ^= value >> 16
        return Double(value) / 4_294_967_296
    }
}

/// Deterministic load-first lighting for individual building windows.
enum CityWindows {
    /// Returns whether one window emits light for the requested job-pressure load.
    ///
    /// Load is the primary signal: it selects the participating fraction of windows.
    /// Time only adds a short, desynchronized twinkle-off interval for participating windows.

    /// Converts running Slurm jobs into scheduler job-participation pressure
    /// for window lighting. This is not measured GPU compute utilization;
    /// the denominator is total GRES capacity so mixed nodes stay honest.
    static func runningJobPressure(for node: ClusterNode) -> Double {
        let activeJobs = node.jobs.count { $0.state == "RUNNING" }
        return min(1, Double(activeJobs) / Double(max(1, node.totalGPUCount)))
    }

    /// Invalidates the retained facade layer whenever occupied GPU capacity
    /// or the per-plot building architecture (allocated/free/drained/unknown)
    /// changes.
    static func occupancySignature(for scape: CityScape) -> String {
        scape.sortedPlots.map { plot in
            let running = plot.node.jobs.count { $0.state == "RUNNING" }
            return "\(plot.id):\(running)/\(max(1, plot.node.gpuCount)):\(CalmCityStyle.buildingState(for: plot).rawValue)"
        }.joined(separator: "|")
    }

    /// Maps scheduler job pressure to the fraction of rooms that are visibly occupied.
    /// Full job participation peaks around sundown, then most rooms sleep by midnight;
    /// nodes without running jobs never synthesize occupied windows.
    static func occupancyFraction(jobPressure: Double, t: Double) -> Double {
        let pressure = min(1, max(0, jobPressure))
        let time = t - floor(t)
        let schedule: Double
        switch time {
        case 0..<0.18:
            schedule = interpolate(time, from: 0, to: 0.18, low: 0.28, high: 0.08)
        case 0.18..<0.30:
            schedule = 0.08
        case 0.30..<0.68:
            schedule = 0.06
        case 0.68..<0.78:
            schedule = interpolate(time, from: 0.68, to: 0.78, low: 0.12, high: 0.92)
        case 0.78..<0.90:
            schedule = interpolate(time, from: 0.78, to: 0.90, low: 0.92, high: 0.58)
        default:
            schedule = interpolate(time, from: 0.90, to: 1, low: 0.58, high: 0.28)
        }
        return pressure * schedule
    }

    private static func interpolate(
        _ value: Double,
        from lower: Double,
        to upper: Double,
        low: Double,
        high: Double
    ) -> Double {
        let progress = min(1, max(0, (value - lower) / max(upper - lower, 0.000_001)))
        return low + (high - low) * progress
    }

    /// Brightens completed floors and dims floors above a running job's wall-clock progress.
    static func floorLoadMultiplier(progress: Double?, rowFraction: Double) -> Double {
        guard let progress else { return 1.0 }
        return rowFraction <= min(max(progress, 0), 1) ? 1.35 : 0.45
    }

    static func isLit(buildingSeed: Int, sequence: Int, t: Double, load: Double) -> Bool {
        let participation = CityRandom.hashFraction(buildingSeed, sequence)
        guard participation < occupancyFraction(jobPressure: load, t: t) else { return false }

        let blinkCenter = CityRandom.hashFraction(buildingSeed &+ 0x51ED, sequence)
        let blinkPhase = (t * 24 + blinkCenter)
        let wrappedBlinkPhase = blinkPhase - floor(blinkPhase)
        return wrappedBlinkPhase >= 0.08
    }

}
