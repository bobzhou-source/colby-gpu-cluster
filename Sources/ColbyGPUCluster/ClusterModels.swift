import Foundation

enum NodeStatus: String, Codable, Sendable {
    case idle
    case partial
    case busy
    case drain
    case unknown
}

enum GPUTier: String, CaseIterable, Sendable {
    case h200, rtxpro6000, a100, l40s, l4, mig

    var shortLabel: String {
        switch self {
        case .h200: "H200"
        case .rtxpro6000: "RTX"
        case .a100: "A100"
        case .l40s: "L40S"
        case .l4: "L4"
        case .mig: "MIG"
        }
    }

    var displayName: String {
        switch self {
        case .h200: "H200"
        case .rtxpro6000: "RTX Pro 6000"
        case .a100: "A100"
        case .l40s: "L40S"
        case .l4: "L4"
        case .mig: "MIG slice"
        }
    }
}

struct TierEntry: Identifiable, Sendable {
    let node: ClusterNode
    let gres: GPUResource

    var id: String { "\(node.name):\(gres.profile)" }
}

struct TierSection: Identifiable, Sendable {
    let tier: GPUTier
    let entries: [TierEntry]

    var id: String { tier.rawValue }
    var openCount: Int {
        entries.reduce(0) { total, entry in
            guard entry.node.status != .drain && entry.node.status != .unknown else { return total }
            return total + entry.gres.free
        }
    }
    var soonestFreeSeconds: Int? {
        entries
            .filter { $0.node.status != .drain && $0.node.status != .unknown && $0.gres.free == 0 }
            .compactMap { $0.node.freeInSeconds }
            .min()
    }
}

struct ClusterHeadline: Equatable, Sendable {
    let primary: String
    let secondary: String?
    let statusKey: NodeStatus
}

struct ClusterJob: Identifiable, Hashable, Sendable {
    let id: String
    let user: String
    let name: String
    let state: String
    let elapsedSeconds: Int?
    let limitSeconds: Int?
    let remainingSeconds: Int?
    let nodeList: String
    let reason: String

    var progress: Double? {
        guard let elapsedSeconds, let limitSeconds, limitSeconds > 0 else { return nil }
        return min(1, max(0, Double(elapsedSeconds) / Double(limitSeconds)))
    }
}

struct GPUResource: Hashable, Sendable {
    let gpuType: String
    let profile: String
    let vramGB: Double
    let count: Int
    let used: Int

    var free: Int { max(0, count - used) }
}

struct ClusterNode: Identifiable, Hashable, Sendable {
    var id: String { name }

    let name: String
    let gres: [GPUResource]
    let state: String
    let status: NodeStatus
    let stateLabel: String
    var jobs: [ClusterJob]

    private var primaryGPU: GPUResource {
        precondition(!gres.isEmpty, "ClusterNode requires at least one GPU resource.")
        return gres[0]
    }

    var gpuType: String { primaryGPU.gpuType }
    var profile: String { primaryGPU.profile }
    var vramGB: Double { primaryGPU.vramGB }
    var gpuCount: Int { primaryGPU.count }
    var freeGPUCount: Int {
        (status == .drain || status == .unknown) ? 0 : gres.reduce(0) { $0 + $1.free }
    }
    var totalGPUCount: Int { gres.reduce(0) { $0 + $1.count } }
    var isIdle: Bool { freeGPUCount > 0 }

    var freeInSeconds: Int? {
        jobs.compactMap(\.remainingSeconds).max()
    }

    var freeInText: String {
        if status == .unknown { return "Availability unknown" }
        if status == .drain { return "Unavailable" }
        if freeGPUCount == totalGPUCount { return "Available now" }
        if freeGPUCount > 0 { return "\(freeGPUCount) of \(totalGPUCount) GPUs free" }
        guard let freeInSeconds else { return "Allocated · release time unknown" }
        return "Allocated · \(DurationText.compact(freeInSeconds)) wall limit left"
    }

    var determiningJob: ClusterJob? {
        jobs.max { ($0.remainingSeconds ?? Int.max) < ($1.remainingSeconds ?? Int.max) }
    }
}

struct PendingJob: Identifiable, Hashable, Sendable {
    let id: String
    let user: String
    let name: String
    let reason: String
    let limitSeconds: Int?
}

struct MenuBarSummary: Equatable, Sendable {
    enum Tower: Equatable, Sendable {
        case open
        case working
        case offline
    }

    let text: String
    let towers: [(tier: GPUTier, state: Tower)]

    static func == (lhs: MenuBarSummary, rhs: MenuBarSummary) -> Bool {
        lhs.text == rhs.text && lhs.towers.elementsEqual(rhs.towers) {
            $0.tier == $1.tier && $0.state == $1.state
        }
    }
}

struct ClusterSnapshot: Sendable {
    var generatedAt: Date
    var nodes: [ClusterNode]
    var pending: [PendingJob]

    static let empty = ClusterSnapshot(generatedAt: .now, nodes: [], pending: [])

    var freeGPUs: Int { nodes.reduce(0) { $0 + $1.freeGPUCount } }
    var totalGPUs: Int { nodes.reduce(0) { $0 + $1.totalGPUCount } }
    var busyCount: Int {
        let drainedGPUs = nodes.reduce(0) { total, node in
            total + ((node.status == .drain || node.status == .unknown) ? node.totalGPUCount : 0)
        }
        return totalGPUs - freeGPUs - drainedGPUs
    }

    private static func earliestSection(in sections: [TierSection]) -> TierSection? {
        var earliest: TierSection?

        for section in sections {
            guard let seconds = section.soonestFreeSeconds else { continue }
            guard let current = earliest, let currentSeconds = current.soonestFreeSeconds else {
                earliest = section
                continue
            }
            if seconds < currentSeconds {
                earliest = section
            }
        }

        return earliest
    }

    var tierSections: [TierSection] {
        GPUTier.allCases.compactMap { tier in
            let entries = nodes.flatMap { node in
                node.gres.compactMap { gres in
                    GPUTier(rawValue: gres.profile) == tier ? TierEntry(node: node, gres: gres) : nil
                }
            }
            .sorted {
                $0.node.name.localizedStandardCompare($1.node.name) == .orderedAscending
            }
            guard !entries.isEmpty else { return nil }
            return TierSection(tier: tier, entries: entries)
        }
    }

    var headline: ClusterHeadline {
        let sections = tierSections
        let bestOpenIndex = sections.firstIndex(where: { $0.openCount > 0 })
        let commuters = pending.count

        func appendingCommuters(to secondary: String?) -> String? {
            guard commuters > 0 else { return secondary }
            let commuterText = "\(commuters) commuter\(commuters == 1 ? "" : "s") at the bridge"
            guard let secondary else { return commuterText }
            return "\(secondary) · \(commuterText)"
        }

        if let bestOpenIndex {
            let bestOpen = sections[bestOpenIndex]
            let betterSection = Self.earliestSection(in: Array(sections[..<bestOpenIndex]))
            let secondary = betterSection.map {
                "Next best: \($0.tier.displayName) frees in ~\(DurationText.compact($0.soonestFreeSeconds))"
            }
            return ClusterHeadline(
                primary: "\(bestOpen.tier.displayName) is vacant",
                secondary: appendingCommuters(to: secondary),
                statusKey: .idle
            )
        }

        if let soonestSection = Self.earliestSection(in: sections) {
            return ClusterHeadline(
                primary: "All cities settled",
                secondary: appendingCommuters(
                    to: "Soonest: \(soonestSection.tier.displayName) frees in ~\(DurationText.compact(soonestSection.soonestFreeSeconds))"
                ),
                statusKey: .partial
            )
        }

        if nodes.contains(where: { $0.status != .drain }) {
            return ClusterHeadline(
                primary: "All cities settled",
                secondary: appendingCommuters(to: "No wall limits posted"),
                statusKey: .partial
            )
        }

        return ClusterHeadline(
            primary: "Province closed",
            secondary: appendingCommuters(to: "All cities are offline"),
            statusKey: .drain
        )
    }

    var menuBarSummary: MenuBarSummary {
        let towers = tierSections.flatMap { section in
            section.entries.map { entry in
                let state: MenuBarSummary.Tower
                if entry.node.status == .drain || entry.node.status == .unknown {
                    state = .offline
                } else if entry.gres.free > 0 {
                    state = .open
                } else {
                    state = .working
                }
                return (tier: section.tier, state: state)
            }
        }
        return MenuBarSummary(
            text: nodes.isEmpty ? "—" : "\(freeGPUs)/\(totalGPUs)",
            towers: towers
        )
    }
}

/// Freshness-bounded state for a service observation.  It remains independent
/// from AppKit/SwiftUI so refresh race ordering is unit-testable.
enum SnapshotRefreshState: String, Sendable {
    case fresh, refreshing, stale, unavailable
}

struct ServiceStatusSnapshot: Sendable {
    let sourceID: String
    let attemptID: String
    let sequence: UInt64
    let observedAt: Date
    let staleAfter: Date
    let refreshState: SnapshotRefreshState
    let errors: [String]
}

struct ServiceSnapshotGate: Sendable {
    private(set) var snapshot: ServiceStatusSnapshot?

    mutating func accept(_ candidate: ServiceStatusSnapshot, now: Date) -> Bool {
        guard candidate.observedAt <= now else { return false }
        if let current = snapshot {
            guard candidate.sourceID == current.sourceID,
                  candidate.attemptID == current.attemptID,
                  candidate.sequence > current.sequence
            else { return false }
        }
        snapshot = candidate
        return true
    }

    func freshness(at now: Date) -> SnapshotRefreshState {
        guard let snapshot else { return .unavailable }
        return now > snapshot.staleAfter ? .stale : snapshot.refreshState
    }
}

enum DurationText {
    static func compact(_ seconds: Int?) -> String {
        guard var seconds else { return "Unlimited" }
        seconds = max(0, seconds)
        if seconds < 90 { return "\(seconds)s" }
        if seconds < 3_600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return String(format: "%.1fh", Double(seconds) / 3_600) }
        return String(format: "%.1fd", Double(seconds) / 86_400)
    }
}
