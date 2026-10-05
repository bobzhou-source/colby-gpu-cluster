import Foundation

func windowFillFraction(for node: ClusterNode) -> Double {
    node.jobs.compactMap(\.progress).max() ?? 0
}

func queueCarCount(pending: [PendingJob]) -> Int {
    pending.count
}

func sceneDimming(for state: SnapshotRefreshState) -> Double {
    switch state {
    case .fresh, .refreshing:
        0
    case .stale:
        0.35
    case .unavailable:
        1
    }
}


/// Street-band ambient car count: quiet when the cluster is idle, bustling under load.
func ambientTrafficCount(runningJobs: [ClusterJob]) -> Int {
    runningJobs.isEmpty ? 0 : min(18, 4 + runningJobs.count * 2)
}
