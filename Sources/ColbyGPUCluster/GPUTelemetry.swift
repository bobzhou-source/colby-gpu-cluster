import Foundation

/// How much a caller may trust a GPU telemetry snapshot at a given instant.
enum GPUTelemetryFreshness: Equatable, Sendable {
    /// Sample timestamp is inside the live window and the last read succeeded.
    case fresh
    /// A real measurement exists but it is older than the live window, or the last read failed.
    case stale
    /// Nothing measured is available (no sample, or the sample claims an implausible future time).
    case unavailable
}

/// One physically reported GPU. Every metric stays optional: a device that did not report a
/// value is `nil`, never `0`.
struct GPUDeviceTelemetry: Equatable, Sendable {
    var index: Int
    var name: String
    var utilizationPercent: Double?
    var memoryUsedMiB: Double?
    var memoryTotalMiB: Double?
    var powerDrawWatts: Double?
    var temperatureCelsius: Double?

    init(
        index: Int,
        name: String,
        utilizationPercent: Double? = nil,
        memoryUsedMiB: Double? = nil,
        memoryTotalMiB: Double? = nil,
        powerDrawWatts: Double? = nil,
        temperatureCelsius: Double? = nil
    ) {
        self.index = index
        self.name = name
        self.utilizationPercent = utilizationPercent
        self.memoryUsedMiB = memoryUsedMiB
        self.memoryTotalMiB = memoryTotalMiB
        self.powerDrawWatts = powerDrawWatts
        self.temperatureCelsius = temperatureCelsius
    }
}

/// Measured GPU state for one scheduler node.
///
/// Aggregates only describe the devices that actually reported. Sums that would silently treat a
/// missing reading as zero are withheld (`nil`) instead.
struct GPUNodeTelemetry: Equatable, Sendable {
    var name: String
    var devices: [GPUDeviceTelemetry]

    init(name: String, devices: [GPUDeviceTelemetry]) {
        self.name = name
        self.devices = devices
    }

    /// Physical devices present in the sample for this node.
    var deviceCount: Int { devices.count }

    /// Devices that reported a usable utilization percentage.
    var reportingDeviceCount: Int {
        var count = 0
        for device in devices where device.utilizationPercent != nil {
            count += 1
        }
        return count
    }

    /// Mean of the reported utilization percentages, or `nil` when nothing reported.
    var utilizationPercent: Double? {
        var total = 0.0
        var count = 0
        for device in devices {
            guard let value = device.utilizationPercent else { continue }
            total += value
            count += 1
        }
        guard count > 0 else { return nil }
        return total / Double(count)
    }

    /// True when at least one present device withheld its utilization reading.
    var isPartial: Bool { reportingDeviceCount != deviceCount }

    /// Summed used memory, only when every device reported both used and total memory.
    var memoryUsedMiB: Double? { pairedMemory?.used }

    /// Summed total memory, only when every device reported both used and total memory.
    var memoryTotalMiB: Double? { pairedMemory?.total }

    /// Summed board power, only when every device reported power.
    var powerDrawWatts: Double? {
        guard !devices.isEmpty else { return nil }
        var total = 0.0
        for device in devices {
            guard let value = device.powerDrawWatts else { return nil }
            total += value
        }
        return total
    }

    /// Hottest reported device temperature; partial coverage is acceptable for a maximum.
    var temperatureCelsius: Double? {
        var hottest: Double?
        for device in devices {
            guard let value = device.temperatureCelsius else { continue }
            if let current = hottest {
                hottest = Swift.max(current, value)
            } else {
                hottest = value
            }
        }
        return hottest
    }

    private var pairedMemory: (used: Double, total: Double)? {
        guard !devices.isEmpty else { return nil }
        var used = 0.0
        var total = 0.0
        for device in devices {
            guard let deviceUsed = device.memoryUsedMiB, let deviceTotal = device.memoryTotalMiB else {
                return nil
            }
            used += deviceUsed
            total += deviceTotal
        }
        return (used, total)
    }
}

/// One decoded telemetry sample: the measured GPU state of a cluster at a single instant.
struct GPUTelemetrySnapshot: Equatable, Sendable {
    /// Longest age still considered live.
    static let freshWindow: TimeInterval = 60
    /// Clock-skew tolerance for samples stamped slightly in the future.
    static let futureTolerance: TimeInterval = 5

    static let empty = GPUTelemetrySnapshot()

    /// True when nothing has been read yet — no sample, no node, no failure.
    /// The HUD uses this to decide whether a telemetry file is attached at all,
    /// independently of which cluster data source is in use.
    var isEmpty: Bool {
        sampledAt == nil && nodes.isEmpty && readError == nil
    }

    /// Timestamp carried by the sample itself — never the file's modification time.
    var sampledAt: Date?
    /// Measured nodes keyed by scheduler node name.
    var nodes: [String: GPUNodeTelemetry]
    /// Description of the most recent read failure, if the last attempt failed.
    var readError: String?
    /// File the reading came from, for source visibility in Settings.
    var sourcePath: String?

    init(
        sampledAt: Date? = nil,
        nodes: [String: GPUNodeTelemetry] = [:],
        readError: String? = nil,
        sourcePath: String? = nil
    ) {
        self.sampledAt = sampledAt
        self.nodes = nodes
        self.readError = readError
        self.sourcePath = sourcePath
    }

    func freshness(at now: Date) -> GPUTelemetryFreshness {
        guard let sampledAt else { return .unavailable }
        let age = now.timeIntervalSince(sampledAt)
        if age < -Self.futureTolerance { return .unavailable }
        if readError != nil { return .stale }
        return age <= Self.freshWindow ? .fresh : .stale
    }

    /// Keeps the last good reading visible while marking why it stopped updating.
    func markingReadError(_ message: String) -> GPUTelemetrySnapshot {
        var copy = self
        copy.readError = message
        return copy
    }
}

enum GPUTelemetryError: LocalizedError, Sendable, Equatable {
    case missingFile(path: String)
    case unreadable(path: String, reason: String)
    case tooLarge(path: String, limitBytes: Int)
    case malformedJSON(reason: String)
    case unsupportedShape(reason: String)

    var errorDescription: String? {
        switch self {
        case let .missingFile(path):
            return "No GPU telemetry file at \(path)."
        case let .unreadable(path, reason):
            return "Could not read GPU telemetry at \(path): \(reason)"
        case let .tooLarge(path, limitBytes):
            return "GPU telemetry file at \(path) exceeds the \(limitBytes / (1_024 * 1_024)) MiB read limit."
        case let .malformedJSON(reason):
            return "GPU telemetry file is not valid JSON: \(reason)"
        case let .unsupportedShape(reason):
            return "GPU telemetry file has an unsupported shape: \(reason)"
        }
    }
}

/// Reads an optional, user-selected local JSON telemetry file. It never launches a process,
/// opens a connection, or starts collection — it only decodes what some other tool already wrote.
enum GPUTelemetryReader {
    /// Ledgers are small; anything larger is a wrong file, not a telemetry feed.
    static let maximumPayloadBytes = 16 * 1_024 * 1_024

    /// Empty configuration disables local telemetry; `~` is expanded for the opt-in path.
    static func resolvedPath(_ configured: String) -> String {
        let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return (trimmed as NSString).expandingTildeInPath
    }

    static func read(path: String) async throws -> GPUTelemetrySnapshot {
        let source = resolvedPath(path)
        let data = try loadBounded(at: source)
        return try snapshot(from: data, sourcePath: source)
    }

    /// Decodes an already-loaded payload. Split out so parsing is testable without touching disk.
    static func snapshot(from data: Data, sourcePath: String?) throws -> GPUTelemetrySnapshot {
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw GPUTelemetryError.malformedJSON(reason: error.localizedDescription)
        }
        let samples = try Self.samples(in: root)
        guard let newest = newestSample(in: samples) else {
            return GPUTelemetrySnapshot(sampledAt: nil, nodes: [:], readError: nil, sourcePath: sourcePath)
        }
        return GPUTelemetrySnapshot(
            sampledAt: newest.timestamp,
            nodes: nodes(from: newest.sample),
            readError: nil,
            sourcePath: sourcePath
        )
    }

    // MARK: - Loading

    private static func loadBounded(at path: String) throws -> Data {
        let url = URL(fileURLWithPath: path)
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            if !FileManager.default.fileExists(atPath: path) {
                throw GPUTelemetryError.missingFile(path: path)
            }
            throw GPUTelemetryError.unreadable(path: path, reason: error.localizedDescription)
        }
        defer { try? handle.close() }
        do {
            let data = try handle.read(upToCount: maximumPayloadBytes + 1) ?? Data()
            guard data.count <= maximumPayloadBytes else {
                throw GPUTelemetryError.tooLarge(path: path, limitBytes: maximumPayloadBytes)
            }
            return data
        } catch let error as GPUTelemetryError {
            throw error
        } catch {
            throw GPUTelemetryError.unreadable(path: path, reason: error.localizedDescription)
        }
    }

    // MARK: - Shape resolution

    /// The three shapes this reader accepts:
    /// 1. a state ledger — `telemetry.last_poll.result.samples`
    /// 2. a `telemetry poll` / `telemetry export` projection — `{ "samples": [...] }`
    /// 3. a bare single sample — `{ "timestamp": ..., "nodes": [...] }`
    private static func samples(in root: Any) throws -> [[String: Any]] {
        guard let dict = root as? [String: Any] else {
            throw GPUTelemetryError.unsupportedShape(
                reason: "expected a JSON object at the document root"
            )
        }
        if let telemetry = dict["telemetry"] as? [String: Any] {
            if let list = value(at: ["last_poll", "result", "samples"], in: telemetry) as? [Any] {
                return dictionaries(in: list)
            }
            // A ledger that exists but has recorded no poll result is empty, not malformed.
            return []
        }
        if let list = dict["samples"] as? [Any] {
            return dictionaries(in: list)
        }
        if dict["nodes"] is [Any] {
            return [dict]
        }
        let keys = dict.keys.sorted().prefix(8).joined(separator: ", ")
        throw GPUTelemetryError.unsupportedShape(
            reason: "no telemetry samples found (top-level keys: \(keys.isEmpty ? "none" : keys))"
        )
    }

    private static func dictionaries(in list: [Any]) -> [[String: Any]] {
        list.compactMap { $0 as? [String: Any] }
    }

    private static func value(at keyPath: [String], in dict: [String: Any]) -> Any? {
        var current: Any? = dict
        for key in keyPath {
            guard let level = current as? [String: Any] else { return nil }
            current = level[key]
        }
        return current
    }

    /// Newest by the sample's own timestamp. Ledger `updated_at` and file mtime describe when the
    /// file was touched, not when the GPUs were measured, so they are never used.
    private static func newestSample(
        in samples: [[String: Any]]
    ) -> (sample: [String: Any], timestamp: Date?)? {
        var newest: (sample: [String: Any], timestamp: Date)?
        var fallback: [String: Any]?
        for sample in samples {
            fallback = sample
            guard let timestamp = self.timestamp(of: sample) else { continue }
            if let current = newest, current.timestamp > timestamp { continue }
            newest = (sample, timestamp)
        }
        if let newest {
            return (newest.sample, newest.timestamp)
        }
        guard let fallback else { return nil }
        // Samples exist but none carries a usable timestamp: expose the readings with an unknown
        // age rather than pretending they are current.
        return (fallback, nil)
    }

    /// Only the sample's canonical `timestamp` counts as a measurement time, and only when it
    /// carries a zone: a zone-less string would be a guess about when the GPUs were read.
    private static func timestamp(of sample: [String: Any]) -> Date? {
        guard let text = sample["timestamp"] as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(trimmed) {
            return date
        }
        return try? Date.ISO8601FormatStyle().parse(trimmed)
    }

    // MARK: - Node and device decoding

    private static func nodes(from sample: [String: Any]) -> [String: GPUNodeTelemetry] {
        guard let rawNodes = sample["nodes"] as? [Any] else { return [:] }
        var result: [String: GPUNodeTelemetry] = [:]
        var explicitIndices: [String: Set<Int>] = [:]
        for raw in rawNodes {
            guard let entry = raw as? [String: Any] else { continue }
            guard let name = nodeName(in: entry) else { continue }
            var node = result[name] ?? GPUNodeTelemetry(name: name, devices: [])
            var seen = explicitIndices[name, default: []]
            let rawDevices = entry["gpus"] as? [Any] ?? []
            for rawDevice in rawDevices {
                guard let deviceEntry = rawDevice as? [String: Any] else { continue }
                let explicitIndex = integer(deviceEntry["index"])
                if let explicitIndex {
                    // A repeated node/device identifier is the same physical GPU listed twice;
                    // counting it again would inflate both coverage and the sums.
                    guard seen.insert(explicitIndex).inserted else { continue }
                }
                node.devices.append(
                    device(from: deviceEntry, index: explicitIndex ?? node.devices.count)
                )
            }
            explicitIndices[name] = seen
            result[name] = node
        }
        return result
    }

    private static func nodeName(in entry: [String: Any]) -> String? {
        guard let name = entry["node"] as? String else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func device(from entry: [String: Any], index: Int) -> GPUDeviceTelemetry {
        GPUDeviceTelemetry(
            index: index,
            name: (entry["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            utilizationPercent: percent(entry["utilization_percent"]),
            memoryUsedMiB: nonNegative(entry["memory_used_mib"]),
            memoryTotalMiB: nonNegative(entry["memory_total_mib"]),
            powerDrawWatts: nonNegative(entry["power_draw_watts"]),
            temperatureCelsius: temperature(entry["temperature_celsius"])
        )
    }

    // MARK: - Scalar validation

    /// Out-of-range or non-finite percentages are unknown readings, not clamped measurements.
    private static func percent(_ raw: Any?) -> Double? {
        guard let value = double(raw), value.isFinite, value >= 0, value <= 100 else { return nil }
        return value
    }

    private static func nonNegative(_ raw: Any?) -> Double? {
        guard let value = double(raw), value.isFinite, value >= 0 else { return nil }
        return value
    }

    private static func temperature(_ raw: Any?) -> Double? {
        guard let value = double(raw), value.isFinite, value > -273.15 else { return nil }
        return value
    }

    /// `null`, booleans, and anything non-numeric are absent readings, never coerced values.
    private static func double(_ raw: Any?) -> Double? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        return number.doubleValue
    }

    private static func integer(_ raw: Any?) -> Int? {
        guard let value = double(raw), value.isFinite,
              value >= Double(Int.min), value <= Double(Int.max)
        else { return nil }
        return Int(value)
    }
}

/// Defaults keys shared by the store and Settings. The optional feed is bound to a host so a
/// snapshot from one cluster is never attributed to another.
enum GPUTelemetrySettings {
    static let pathKey = "gpuTelemetryPath"
    static let hostKey = "gpuTelemetryHost"
    static let defaultHost = ""
}
