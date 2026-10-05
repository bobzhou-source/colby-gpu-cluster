import CoreGraphics
import Foundation

/// Job-progress-driven district density.
///
/// Every plot's maximum layout is generated once by `CityAtlasLayout`; each
/// element carries an immutable `revealStage`. A node's running-job progress
/// selects one of ten construction stages, and crossing a 10% boundary
/// unlocks only the newly assigned geometry. Refreshes therefore stay
/// visually stable, and the retained base re-renders exactly when a stage
/// boundary is crossed.
enum CityDensity {
    /// Number of construction stages past the baseline; stage 10 is the
    /// plot's precomputed maximum density.
    static let stageCount = 10

    /// Maps normalized job progress to a construction stage `0...10`.
    ///
    /// `nil`, non-finite, and non-positive progress values pin to the
    /// baseline: jobs without a valid wall-time limit must not invent
    /// progress.
    static func stage(progress: Double?) -> Int {
        guard let progress, progress.isFinite, progress > 0 else { return 0 }
        return min(stageCount, Int(min(1, progress) * 10))
    }

    /// Highest stage among the node's running jobs, so a nearly complete job
    /// keeps its district visibly dense while younger jobs run alongside.
    static func stage(for node: ClusterNode) -> Int {
        node.jobs.compactMap(\.progress).map { stage(progress: $0) }.max() ?? 0
    }

    /// Whether an element with `revealStage` is visible at `stage`.
    static func isRevealed(_ revealStage: Int, at stage: Int) -> Bool {
        revealStage <= stage
    }

    /// Deterministic reveal stage for the element at `index` inside a plot's
    /// maximum layout. The first `baseline` elements form the permanent idle
    /// silhouette (stage 0); the rest spread monotonically across stages
    /// `1...10` so every stage boundary unlocks a comparable slice.
    static func revealStage(index: Int, baseline: Int, total: Int) -> Int {
        guard index >= baseline, total > baseline else { return 0 }
        let extras = total - baseline
        return 1 + ((index - baseline) * stageCount) / extras
    }

    /// Number of visible massing tiers for a density building revealed at
    /// `revealStage` once the plot reaches `stage`. Baseline buildings
    /// (reveal stage 0) are always complete; density extras rise one tier per
    /// stage and always top out by stage 10.
    static func visibleTierCount(revealStage: Int, tierCount: Int, stage: Int) -> Int {
        guard tierCount > 0 else { return 0 }
        guard revealStage > 0 else { return tierCount }
        guard stage >= revealStage else { return 0 }
        let steps = min(tierCount - 1, stageCount - revealStage)
        guard steps > 0 else { return tierCount }
        let progressed = min(stage - revealStage, steps)
        return 1 + (progressed * (tierCount - 1)) / steps
    }

    /// Ambient street-activity fraction at `stage`. Activity trails
    /// structural density by one stage so freshly unlocked blocks read as
    /// under construction before they bustle.
    static func activityFraction(stage: Int) -> Double {
        let trailing = max(0, min(stageCount, stage) - 1)
        return 0.35 + 0.65 * Double(trailing) / Double(stageCount - 1)
    }

    /// Stable per-plot stage signature. The retained base render key embeds
    /// this string, so the base image is reused byte-identically while every
    /// plot stays inside its current stage and re-renders exactly on
    /// boundary crossings.
    static func signature(stages: [String: Int]) -> String {
        stages
            .filter { $0.value > 0 }
            .sorted { $0.key < $1.key }
            .map { "\($0.key):\($0.value)" }
            .joined(separator: ",")
    }

    /// Job-derived target stages for every plot in the scape.
    static func targetStages(scape: CityScape) -> [String: Int] {
        scape.plots.reduce(into: [:]) { $0[$1.id] = stage(for: $1.node) }
    }
}
