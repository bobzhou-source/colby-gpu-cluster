import Foundation

/// Where a snapshot comes from. Two shapes exist: an SSH session that runs SLURM
/// commands, and a published JSON status feed.
enum ClusterSourceKind: String, CaseIterable, Sendable {
    case statusPage
    case ssh

    var title: String {
        switch self {
        case .statusPage: "Status page URL"
        case .ssh: "SSH"
        }
    }
}

enum ClusterSource: Hashable, Sendable {
    case ssh(host: String)
    case statusPage(url: String)

    /// Trimmed SSH host, or `nil` for a status-page source.
    var sshHost: String? {
        guard case let .ssh(host) = self else { return nil }
        return host.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Trimmed status-page URL, or `nil` for an SSH source.
    var statusPageURL: String? {
        guard case let .statusPage(url) = self else { return nil }
        return url.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var usesSSH: Bool {
        if case .ssh = self { true } else { false }
    }

    /// Stable identity for attribution and in-flight supersession. Never shown.
    var identity: String {
        switch self {
        case let .ssh(host): "ssh:\(host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
        case let .statusPage(url): "http:\(url.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }

    var isConfigured: Bool {
        switch self {
        case let .ssh(host):
            return !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case let .statusPage(url):
            let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsed = URL(string: trimmed) else { return false }
            return parsed.scheme != nil && parsed.host != nil
        }
    }

    /// What to name this source in the UI.
    var displayName: String {
        switch self {
        case let .ssh(host):
            let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
            return host.isEmpty ? "no SSH host" : host
        case let .statusPage(url):
            let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsed = URL(string: trimmed), let host = parsed.host else { return "no status page" }
            return host
        }
    }

    var unconfiguredMessage: String {
        switch self {
        case .ssh: "No SSH host configured — set one in Settings."
        case .statusPage: "No status page URL configured — set one in Settings."
        }
    }
}

/// The picker stores a raw kind string; the resolution rule lives here so every
/// window agrees. A status-page kind with no URL falls back to SSH rather than
/// silently doing nothing.
enum ClusterSourceResolution {
    static func source(kind: String, url: String, host: String) -> ClusterSource {
        switch ClusterSourceKind(rawValue: kind) ?? .statusPage {
        case .ssh:
            return .ssh(host: host)
        case .statusPage:
            return url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .ssh(host: host)
                : .statusPage(url: url)
        }
    }
}

// MARK: - Hardware profiles

/// Maps a human-readable GPU name from a status feed onto the app's tier
/// profiles. Unknown names stay intact so they still render as themselves.
enum GPUHardwareProfile {
    static func lookup(_ gpuType: String) -> (profile: String, vramGB: Double) {
        let upper = gpuType.uppercased()
        if upper.contains("H200") { return ("h200", 141) }
        if upper.contains("RTX") { return ("rtxpro6000", 96) }
        if upper.contains("A100") { return ("a100", 80) }
        if upper.contains("L40S") { return ("l40s", 48) }
        if upper.contains("L4") { return ("l4", 24) }
        if upper.contains("MIG") { return ("mig", 20) }
        if let slice = migSliceVRAM(gpuType) { return ("mig", slice) }
        return (gpuType.lowercased(), 0)
    }

    /// MIG slice names look like `1g.20gb` / `3g.40gb`; the trailing number is
    /// the slice's memory in GB.
    private static func migSliceVRAM(_ gpuType: String) -> Double? {
        let lower = gpuType.lowercased()
        guard lower.hasSuffix("gb"),
              let separator = lower.firstIndex(of: "g"),
              lower[lower.index(after: separator)...].hasPrefix("."),
              let value = Double(lower.dropLast(2).split(separator: ".").last ?? ""),
              value > 0
        else { return nil }
        return value
    }
}

// MARK: - HTTP source

enum ClusterSourceDefaults {
    /// Colby HPC's public GPU node-status page. Reading it needs no SSH login
    /// or cluster account, so it is the out-of-the-box source.
    static let statusPageURL = "https://hpc.colby.edu/public/gpu.html"
}

enum StatusFeedError: LocalizedError, Sendable, Equatable {
    case invalidURL(String)
    case badStatus(Int)
    case emptyBody
    case malformedJSON(reason: String)
    case unsupportedRoot
    case unsupportedSchema(String?)
    case unreadableHTML

    var errorDescription: String? {
        switch self {
        case let .invalidURL(url):
            return "Not a usable status page URL: \(url)"
        case let .badStatus(code):
            return "Status page returned HTTP \(code)."
        case .emptyBody:
            return "Status page returned an empty body."
        case let .malformedJSON(reason):
            return "Status feed is not valid JSON: \(reason)"
        case .unsupportedRoot:
            return "Status feed is not a JSON object."
        case let .unsupportedSchema(schema):
            let found = schema.map { "\($0)" } ?? "none"
            return "Status feed schema is \(found); expected \(StatusFeedMapper.supportedSchema)."
        case .unreadableHTML:
            return "Status page is HTML but has no node table this app can read."
        }
    }
}

/// Fetches a published `colby-gpu-status/1` JSON document, or Colby HPC's HTML
/// node-status table, over HTTP and maps it into the same `ClusterSnapshot` the
/// SSH source produces.
struct HTTPStatusClient: Sendable {
    static let defaultTimeout: TimeInterval = 25
    static let maximumPayloadBytes = 8 * 1_024 * 1_024

    private let session: URLSession
    private let now: @Sendable () -> Date

    init(session: URLSession = .shared, now: @escaping @Sendable () -> Date = { Date() }) {
        self.session = session
        self.now = now
    }

    func fetch(urlString: String) async throws -> ClusterSnapshot {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil, url.host != nil else {
            throw StatusFeedError.invalidURL(trimmed)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.defaultTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json, text/html;q=0.9", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw StatusFeedError.badStatus(http.statusCode)
        }
        guard !data.isEmpty else { throw StatusFeedError.emptyBody }
        guard data.count <= Self.maximumPayloadBytes else {
            throw StatusFeedError.badStatus(data.count)
        }
        if HTMLStatusPageMapper.looksLikeHTML(data) {
            return try HTMLStatusPageMapper.snapshot(from: data, now: now())
        }
        return try StatusFeedMapper.snapshot(from: data, now: now())
    }
}

// MARK: - Feed mapping

/// Decodes the published status contract into the app's snapshot model.
/// Unknown fields are ignored; missing optional fields degrade to empty or nil.
enum StatusFeedMapper {
    static let supportedSchema = "colby-gpu-status/1"

    static func snapshot(from data: Data, now: Date = Date()) throws -> ClusterSnapshot {
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw StatusFeedError.malformedJSON(reason: error.localizedDescription)
        }
        guard let document = root as? [String: Any] else {
            throw StatusFeedError.unsupportedRoot
        }
        let schema = document["schema"] as? String
        guard schema == supportedSchema else {
            throw StatusFeedError.unsupportedSchema(schema)
        }

        let generatedAt = ISO8601Parsing.date(document["generated_at"]) ?? now
        var nodes = (document["nodes"] as? [Any] ?? []).compactMap(node(from:))
        let jobs = (document["jobs"] as? [Any] ?? []).compactMap(job(from:))

        for index in nodes.indices {
            nodes[index].jobs = jobs.filter { job in
                job.state == "RUNNING" && job.nodeList
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .contains(nodes[index].name)
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

        return ClusterSnapshot(generatedAt: generatedAt, nodes: nodes, pending: pending)
    }

    private static func node(from raw: Any) -> ClusterNode? {
        guard let entry = raw as? [String: Any],
              let name = string(entry["name"]),
              !name.isEmpty
        else { return nil }

        let gpuType = string(entry["gpu_type"]) ?? "Unknown"
        let total = max(0, integer(entry["gpus_total"]) ?? 0)
        let used = min(total, max(0, integer(entry["gpus_used"]) ?? 0))
        let hardware = GPUHardwareProfile.lookup(gpuType)
        let state = (string(entry["state"]) ?? "unknown").lowercased()
        let (status, label) = statusAndLabel(forFeedState: state, reason: string(entry["reason"]))

        return ClusterNode(
            name: name,
            gres: [GPUResource(
                gpuType: gpuType,
                profile: hardware.profile,
                vramGB: hardware.vramGB,
                count: total,
                used: used
            )],
            state: state,
            status: status,
            stateLabel: label,
            jobs: []
        )
    }

    private static func job(from raw: Any) -> ClusterJob? {
        guard let entry = raw as? [String: Any],
              let id = string(entry["id"]),
              !id.isEmpty
        else { return nil }

        let state = (string(entry["state"]) ?? "").uppercased()
        let elapsed = integer(entry["elapsed_s"])
        let limit = integer(entry["time_limit_s"])
        let remaining: Int? = {
            guard let elapsed, let limit else { return nil }
            return max(0, limit - elapsed)
        }()
        let nodes = (entry["nodes"] as? [Any] ?? []).compactMap { string($0) }

        return ClusterJob(
            id: id,
            user: string(entry["user"]) ?? "",
            name: string(entry["name"]) ?? "",
            state: state,
            elapsedSeconds: elapsed,
            limitSeconds: limit,
            remainingSeconds: remaining,
            nodeList: nodes.joined(separator: ","),
            reason: string(entry["reason"]) ?? ""
        )
    }

    static func statusAndLabel(forFeedState state: String, reason: String?) -> (NodeStatus, String) {
        switch state {
        case "idle": return (.idle, "Idle")
        case "mixed": return (.partial, "Partial")
        case "allocated": return (.busy, "Allocated")
        case "drain", "drained": return (.drain, "Drain")
        case "draining": return (.drain, "Draining")
        case "down": return (.drain, "Down")
        case "maint": return (.drain, "Maintenance")
        case "reserved": return (.drain, "Reserved")
        case "": return (.unknown, "Unknown")
        default:
            if let reason, !reason.isEmpty { return (.unknown, reason) }
            return (.unknown, state.capitalized)
        }
    }

    private static func string(_ raw: Any?) -> String? {
        guard let text = raw as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func integer(_ raw: Any?) -> Int? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let value = number.doubleValue
        guard value.isFinite, value >= Double(Int.min), value <= Double(Int.max) else { return nil }
        return Int(value)
    }
}

// MARK: - Dates

enum ISO8601Parsing {
    /// Parses an RFC 3339 / ISO 8601 instant with a zone offset. A zone-less
    /// string is not a timestamp (it would be a guess), so it returns `nil`.
    ///
    /// The formatter is created per call: `ISO8601DateFormatter` is not
    /// `Sendable`, and one document parses exactly one timestamp.
    static func date(_ raw: Any?) -> Date? {
        guard let text = raw as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = formatter.date(from: trimmed) { return parsed }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: trimmed)
    }
}
