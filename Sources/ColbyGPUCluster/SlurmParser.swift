import Foundation

enum SlurmParser {
    static let sinfoMarker = "===SINFO==="
    static let squeueMarker = "===SQUEUE==="
    static let rcMarker = "===RC==="

    private struct GPUProfile: Sendable {
        let profile: String
        let vramGB: Double
    }

    private static let gpuProfiles: [String: GPUProfile] = [
        "A100": .init(profile: "a100", vramGB: 80),
        "H200": .init(profile: "h200", vramGB: 141),
        "RTX": .init(profile: "rtxpro6000", vramGB: 96),
        "L40S": .init(profile: "l40s", vramGB: 48),
        "L4": .init(profile: "l4", vramGB: 24),
        "1g.20gb": .init(profile: "mig", vramGB: 20),
    ]

    static func parseDuration(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !["UNLIMITED", "INVALID", "NOT_SET", "N/A"].contains(trimmed.uppercased())
        else { return nil }

        let dayParts = trimmed.split(separator: "-", maxSplits: 1).map(String.init)
        let days: Int
        let timeText: String
        if dayParts.count == 2 {
            guard let parsedDays = Int(dayParts[0]) else { return nil }
            days = parsedDays
            timeText = dayParts[1]
        } else {
            days = 0
            timeText = trimmed
        }

        let values = timeText.split(separator: ":").compactMap { Int($0) }
        guard values.count == timeText.split(separator: ":").count else { return nil }
        switch values.count {
        case 3: return days * 86_400 + values[0] * 3_600 + values[1] * 60 + values[2]
        case 2: return days * 86_400 + values[0] * 60 + values[1]
        case 1: return days * 86_400 + values[0]
        default: return nil
        }
    }

    static func splitSections(_ raw: String) -> (sinfo: String, squeue: String) {
        var section: String?
        var sinfo: [String] = []
        var squeue: [String] = []
        for line in raw.components(separatedBy: .newlines) {
            switch line.trimmingCharacters(in: .whitespaces) {
            case sinfoMarker: section = "sinfo"
            case squeueMarker: section = "squeue"
            case let marker where marker.hasPrefix(rcMarker): section = nil
            default:
                if section == "sinfo" { sinfo.append(line) }
                if section == "squeue" { squeue.append(line) }
            }
        }
        return (sinfo.joined(separator: "\n"), squeue.joined(separator: "\n"))
    }

    static func parseSnapshot(_ raw: String, now: Date = .now) throws -> ClusterSnapshot {
        guard raw.contains(sinfoMarker), raw.contains(squeueMarker) else {
            throw ClusterClientError.invalidResponse("The cluster returned no SLURM data.")
        }
        guard let rcLine = raw.components(separatedBy: .newlines).first(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix(rcMarker)
        }) else {
            throw ClusterClientError.invalidResponse("Truncated cluster response.")
        }
        let rcFields = rcLine
            .trimmingCharacters(in: .whitespaces)
            .split(separator: " ", omittingEmptySubsequences: true)
        guard rcFields.count == 3, rcFields[0] == Substring(rcMarker),
              let sinfoRC = Int32(rcFields[1]), let squeueRC = Int32(rcFields[2])
        else {
            throw ClusterClientError.invalidResponse("Truncated cluster response.")
        }

        let sections = splitSections(raw)
        if sinfoRC != 0 {
            throw ClusterClientError.invalidResponse(
                "sinfo failed (exit \(sinfoRC)): \(String(sections.sinfo.prefix(200)))"
            )
        }
        if squeueRC != 0 {
            throw ClusterClientError.invalidResponse(
                "squeue failed (exit \(squeueRC)): \(String(sections.squeue.prefix(200)))"
            )
        }

        var nodes = parseNodes(sections.sinfo)
        guard !nodes.isEmpty else {
            throw ClusterClientError.invalidResponse("SLURM returned no GPU nodes for partition gpu.")
        }
        let jobs = parseJobs(sections.squeue)
        let runningNodeLists = Dictionary(
            uniqueKeysWithValues: jobs.map { ($0.id, expandNodeList($0.nodeList)) }
        )

        for index in nodes.indices {
            nodes[index].jobs = jobs.filter { job in
                job.state == "RUNNING" && (runningNodeLists[job.id] ?? []).contains(nodes[index].name)
            }
        }

        let pending = jobs
            .filter { $0.state == "PENDING" }
            .map {
                PendingJob(
                    id: $0.id,
                    user: $0.user,
                    name: $0.name,
                    reason: $0.reason.isEmpty ? "Pending" : $0.reason,
                    limitSeconds: $0.limitSeconds
                )
            }
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }

        nodes.sort {
            if $0.isIdle != $1.isIdle { return $0.isIdle }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return ClusterSnapshot(generatedAt: now, nodes: nodes, pending: pending)
    }

    static func parseNodes(_ text: String) -> [ClusterNode] {
        text.components(separatedBy: .newlines).compactMap { line in
            let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 3 else { return nil }
            let nodeName = fields[0].trimmingCharacters(in: .whitespaces)
            let rawState = fields[1].trimmingCharacters(in: .whitespaces)
            // `StateCompact` appends flag characters to the base state
            // (`*` not responding, `~` powered down, `#` powering up,
            // `%` powering down, `!` pending power down, `@` pending reboot,
            // `^` reboot issued, `-` planned, `$` maintenance reservation,
            // `+` reservation). Availability comes from the base state.
            let state = rawState.trimmingCharacters(in: Self.stateFlagCharacters).lowercased()
            let usedByType = parseGRESCounts(fields.count >= 4 ? fields[3] : "")

            let gres = fields[2].split(separator: ",").compactMap { chunk -> GPUResource? in
                let parts = chunk.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
                guard parts.count >= 3, parts[0] == "gpu", let profile = gpuProfiles[parts[1]] else { return nil }
                let countText = parts[2].split(separator: "(", maxSplits: 1).first.map(String.init) ?? "1"
                let count = Int(countText) ?? 1
                let used = usedByType[parts[1]] ?? (state == "idle" ? 0 : count)
                return GPUResource(
                    gpuType: parts[1],
                    profile: profile.profile,
                    vramGB: profile.vramGB,
                    count: count,
                    used: used
                )
            }
            .sorted { $0.vramGB > $1.vramGB }
            guard !gres.isEmpty else { return nil }

            let statusAndLabel: (NodeStatus, String) = switch state {
            case "idle": (.idle, "Idle")
            case "mix": (.partial, "Partial")
            case "alloc", "comp": (.busy, state == "comp" ? "Completing" : "Allocated")
            case "drain", "drng", "drned", "resv", "down", "maint", "boot": (.drain, state.capitalized)
            default: (.unknown, state.isEmpty ? "Unknown" : state.capitalized)
            }
            return ClusterNode(
                name: nodeName,
                gres: gres,
                state: state,
                status: statusAndLabel.0,
                stateLabel: statusAndLabel.1,
                jobs: []
            )
        }
    }

    private static let stateFlagCharacters = CharacterSet(charactersIn: "*~#%!@^-$+")

    private static func parseGRESCounts(_ text: String) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: text.split(separator: ",").compactMap { chunk in
            let parts = chunk.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3, parts[0] == "gpu" else { return nil }
            let countText = parts[2].split(separator: "(", maxSplits: 1).first.map(String.init) ?? "0"
            return (parts[1], Int(countText) ?? 0)
        })
    }
    static func parseJobs(_ text: String) -> [ClusterJob] {
        text.components(separatedBy: .newlines).compactMap { line in
            let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 9 else { return nil }
            let elapsed = parseDuration(fields[4])
            let limit = parseDuration(fields[5])
            let remaining = elapsed.flatMap { elapsed in limit.map { max(0, $0 - elapsed) } }
            return ClusterJob(
                id: fields[0].trimmingCharacters(in: .whitespaces),
                user: fields[1].trimmingCharacters(in: .whitespaces),
                name: fields[2].trimmingCharacters(in: .whitespaces),
                state: fields[3].trimmingCharacters(in: .whitespaces),
                elapsedSeconds: elapsed,
                limitSeconds: limit,
                remainingSeconds: remaining,
                nodeList: fields[7].trimmingCharacters(in: .whitespaces),
                reason: fields[8].trimmingCharacters(in: CharacterSet(charactersIn: " ()"))
            )
        }
    }

    static func expandNodeList(_ raw: String) -> Set<String> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "(null)", trimmed.uppercased() != "N/A" else { return [] }

        var groups: [String] = []
        var current = ""
        var depth = 0
        for character in trimmed {
            switch character {
            case "[": depth += 1; current.append(character)
            case "]": depth = max(0, depth - 1); current.append(character)
            case "," where depth == 0: groups.append(current); current = ""
            default: current.append(character)
            }
        }
        if !current.isEmpty { groups.append(current) }

        return Set(groups.flatMap { group -> [String] in
            guard let open = group.firstIndex(of: "["), let close = group.lastIndex(of: "]"), open < close else {
                return [group]
            }
            let prefix = String(group[..<open])
            let inner = group[group.index(after: open)..<close]
            return inner.split(separator: ",").flatMap { component -> [String] in
                let bounds = component.split(separator: "-", maxSplits: 1).map(String.init)
                guard bounds.count == 2, let start = Int(bounds[0]), let end = Int(bounds[1]) else {
                    return [prefix + component]
                }
                let width = max(bounds[0].count, bounds[1].count)
                return (min(start, end)...max(start, end)).map {
                    prefix + String(format: "%0\(width)d", $0)
                }
            }
        })
    }
}
