import Foundation

/// Independently collected Slurm surfaces. Each domain has its own freshness and
/// failure state so an optional command cannot invalidate unrelated data.
enum SlurmDataDomain: String, CaseIterable, Sendable {
    case controllerConfiguration
    case partitions
    case nodesResources
    case resourceCatalog
    case activeJobs
    case stepsRuntime
    case priorityScheduling
    case schedulerDiagnostics
    case accounting
    case policy
}

/// The result of the most recent attempt to collect a domain.
enum SlurmCollectionStatus: String, Sendable {
    case fresh
    case stale
    case partial
    case empty
    case unavailable
    case denied
}

/// The wire format expected from one allow-listed command section.
enum SlurmParserKind: String, Sendable {
    case pipeTable
    case keyValueRecord
    case keyValueLines
    case hierarchicalKeyValue
    case plainLines
}

/// One parsed row or record. Known fields remain separate from unrecognized
/// fields so future Slurm additions survive parsing without becoming schema.
struct SlurmRecord: Equatable, Sendable {
    let fields: [String: String]
    let unknownFields: [String: String]

    init(fields: [String: String], unknownFields: [String: String] = [:]) {
        self.fields = fields
        self.unknownFields = unknownFields
    }

    subscript(field: String) -> String? {
        fields[field] ?? unknownFields[field]
    }

    /// A complete view for generic consumers. A recognized field wins if a
    /// malformed response supplies the same key in both collections.
    var allFields: [String: String] {
        unknownFields.merging(fields) { _, recognized in recognized }
    }
}

/// A named parsed section. `columns` is deliberately an array: presentation
/// and positional parsing must not depend on dictionary iteration order.
struct SlurmTable: Equatable, Sendable {
    let name: String
    let columns: [String]
    let records: [SlurmRecord]

    init(name: String, columns: [String], records: [SlurmRecord]) {
        self.name = name
        self.columns = columns
        self.records = records
    }
}

/// Exit and capture metadata for one fixed command in a domain refresh.
/// Diagnostics are expected to be bounded by the collector before storage.
struct SlurmCommandObservation: Equatable, Sendable {
    let commandID: String
    let parserKind: SlurmParserKind
    let status: SlurmCollectionStatus
    let exitCode: Int32?
    let timedOut: Bool
    let truncated: Bool
    let diagnostic: String?

    init(
        commandID: String,
        parserKind: SlurmParserKind,
        status: SlurmCollectionStatus,
        exitCode: Int32?,
        timedOut: Bool = false,
        truncated: Bool = false,
        diagnostic: String? = nil
    ) {
        self.commandID = commandID
        self.parserKind = parserKind
        self.status = status
        self.exitCode = exitCode
        self.timedOut = timedOut
        self.truncated = truncated
        self.diagnostic = diagnostic
    }
}

/// Latest parsed tables for one domain. Table order is stable, and merging a
/// partial result replaces tables by name while retaining omitted tables.
struct SlurmDomainData: Equatable, Sendable {
    let tables: [SlurmTable]

    static let empty = SlurmDomainData(tables: [])

    init(tables: [SlurmTable]) {
        self.tables = tables
    }

    func table(named name: String) -> SlurmTable? {
        tables.first { $0.name == name }
    }

    func merging(_ partial: SlurmDomainData) -> SlurmDomainData {
        var merged = tables
        var indicesByName: [String: Int] = [:]
        indicesByName.reserveCapacity(merged.count + partial.tables.count)

        for (index, table) in merged.enumerated() {
            indicesByName[table.name] = index
        }

        for table in partial.tables {
            if let index = indicesByName[table.name] {
                merged[index] = table
            } else {
                indicesByName[table.name] = merged.count
                merged.append(table)
            }
        }

        return SlurmDomainData(tables: merged)
    }
}

/// Current attempt metadata plus the latest usable value for a domain. `data`
/// may therefore be non-nil when `status` describes a failed current attempt.
struct SlurmDomainObservation: Equatable, Sendable {
    let domain: SlurmDataDomain
    let observedAt: Date
    let expiresAt: Date
    let status: SlurmCollectionStatus
    let commands: [SlurmCommandObservation]
    let data: SlurmDomainData?

    init(
        domain: SlurmDataDomain,
        observedAt: Date,
        expiresAt: Date,
        status: SlurmCollectionStatus,
        commands: [SlurmCommandObservation],
        data: SlurmDomainData?
    ) {
        self.domain = domain
        self.observedAt = observedAt
        self.expiresAt = expiresAt
        self.status = status
        self.commands = commands
        self.data = data
    }

    /// Applies a newer attempt while preserving the receiver's last-good data
    /// when the attempt cannot provide a complete replacement.
    func merging(_ refresh: SlurmDomainObservation) -> SlurmDomainObservation {
        precondition(domain == refresh.domain, "Cannot merge different Slurm domains")

        let mergedData: SlurmDomainData?
        switch refresh.status {
        case .fresh:
            mergedData = refresh.data
        case .empty:
            mergedData = refresh.data ?? .empty
        case .partial:
            switch (data, refresh.data) {
            case let (current?, partial?):
                mergedData = current.merging(partial)
            case let (_, partial?):
                mergedData = partial
            case let (current?, nil):
                mergedData = current
            case (nil, nil):
                mergedData = nil
            }
        case .stale, .unavailable, .denied:
            mergedData = data
        }

        return SlurmDomainObservation(
            domain: refresh.domain,
            observedAt: refresh.observedAt,
            expiresAt: refresh.expiresAt,
            status: refresh.status,
            commands: refresh.commands,
            data: mergedData
        )
    }
}

/// Versioned, in-memory aggregate published alongside the existing city
/// snapshot. It intentionally contains no raw command output or UI state.
struct SlurmDataSnapshot: Equatable, Sendable {
    static let currentVersion = 1
    static let empty = SlurmDataSnapshot(
        host: nil,
        generatedAt: .distantPast,
        observations: [:]
    )

    let version: Int
    private(set) var host: String?
    private(set) var generatedAt: Date
    private(set) var observations: [SlurmDataDomain: SlurmDomainObservation]

    init(
        version: Int = SlurmDataSnapshot.currentVersion,
        host: String?,
        generatedAt: Date,
        observations: [SlurmDataDomain: SlurmDomainObservation] = [:]
    ) {
        self.version = version
        self.host = host
        self.generatedAt = generatedAt
        self.observations = observations
    }

    subscript(domain: SlurmDataDomain) -> SlurmDomainObservation? {
        observations[domain]
    }

    mutating func update(with refresh: SlurmDomainObservation, generatedAt: Date) {
        if let current = observations[refresh.domain] {
            observations[refresh.domain] = current.merging(refresh)
        } else {
            observations[refresh.domain] = refresh
        }
        self.generatedAt = generatedAt
    }

    func updating(
        with refresh: SlurmDomainObservation,
        generatedAt: Date
    ) -> SlurmDataSnapshot {
        var updated = self
        updated.update(with: refresh, generatedAt: generatedAt)
        return updated
    }

    /// Invalidates all cached domains when the SSH destination changes.
    /// Returns whether invalidation occurred.
    @discardableResult
    mutating func reset(forHost newHost: String?, at date: Date) -> Bool {
        guard newHost != host else { return false }
        host = newHost
        generatedAt = date
        observations.removeAll(keepingCapacity: true)
        return true
    }
}
