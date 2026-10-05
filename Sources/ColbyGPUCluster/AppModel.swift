import Foundation
import Observation

/// The one collection entry point the store needs. Injecting it lets tests prove that a
/// failed snapshot suppresses scheduler polling without launching real SSH commands.
protocol SlurmDataCollecting: Actor {
    func fetch(host: String, force: Bool, now: Date) async -> SlurmDataSnapshot
}

extension SlurmDataCollector: SlurmDataCollecting {}

@MainActor
@Observable
final class ClusterStore {
    static let shared = ClusterStore()

    var fetchSnapshot: @Sendable (ClusterSource) async throws -> ClusterSnapshot
    private(set) var slurmDataSnapshot: SlurmDataSnapshot = .empty
    private(set) var gpuTelemetry: GPUTelemetrySnapshot = .empty

    var snapshot: ClusterSnapshot = .empty
    var isRefreshing = false
    var hasLoaded = false
    var errorMessage: String?
    var lastErrorAt: Date?
    private(set) var lastSuccessfulAt: Date?
    private(set) var consecutiveSnapshotFailures = 0
    private let slurmDataCollector: any SlurmDataCollecting
    private let telemetryDefaults: UserDefaults
    private let readGPUTelemetry: @Sendable (String) async throws -> GPUTelemetrySnapshot
    private var pendingRefreshSource: ClusterSource?
    private var pendingForceSlurmData = false
    private var requestedSlurmDataHost: String?
    private var snapshotFailureSource: String?
    /// Identity of the feed the current reading is attributed to: source plus bound host.
    private var gpuTelemetryAttribution: GPUTelemetryAttribution?
    /// Bumped whenever the source or host changes so a slow in-flight read cannot land late.
    private var gpuTelemetryGeneration = 0

    init(
        fetchSnapshot: @escaping @Sendable (ClusterSource) async throws -> ClusterSnapshot = { source in
            switch source {
            case let .ssh(host):
                return try await ClusterClient().fetch(host: host)
            case let .statusPage(url):
                return try await HTTPStatusClient().fetch(urlString: url)
            }
        },
        slurmDataCollector: any SlurmDataCollecting = SlurmDataCollector(),
        telemetryDefaults: UserDefaults = .standard,
        readGPUTelemetry: @escaping @Sendable (String) async throws -> GPUTelemetrySnapshot = { path in
            try await GPUTelemetryReader.read(path: path)
        }
    ) {
        self.fetchSnapshot = fetchSnapshot
        self.slurmDataCollector = slurmDataCollector
        self.telemetryDefaults = telemetryDefaults
        self.readGPUTelemetry = readGPUTelemetry
    }

    /// Convenience for the SSH source; the status-page source has no host.
    func refresh(host: String, forceSlurmData: Bool = false) async {
        await refresh(source: .ssh(host: host), forceSlurmData: forceSlurmData)
    }

    func refresh(source: ClusterSource, forceSlurmData: Bool = false) async {
        guard !isRefreshing else {
            pendingRefreshSource = source
            pendingForceSlurmData = pendingForceSlurmData || forceSlurmData
            return
        }
        var source = source
        var forceSlurmData = forceSlurmData
        guard source.isConfigured else {
            errorMessage = source.unconfiguredMessage
            lastErrorAt = .now
            hasLoaded = true
            return
        }
        isRefreshing = true
        defer {
            isRefreshing = false
            hasLoaded = true
        }
        while true {
            if snapshotFailureSource != source.identity {
                snapshotFailureSource = source.identity
                consecutiveSnapshotFailures = 0
            }
            // The local telemetry feed is independent of the cluster source: it must load whether
            // or not the snapshot fetch below succeeds.
            await refreshGPUTelemetry(host: telemetryBindingHost(for: source))
            do {
                snapshot = try await fetchSnapshot(source)
                errorMessage = nil
                lastErrorAt = nil
                lastSuccessfulAt = snapshot.generatedAt
                consecutiveSnapshotFailures = 0
                // Domain collection is SSH-only; the published feed already carries the
                // scheduler surfaces it knows about, and there is no session to run commands in.
                if let host = source.sshHost {
                    startSlurmDataRefresh(host: host, force: forceSlurmData)
                }
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
                lastErrorAt = .now
                consecutiveSnapshotFailures = min(consecutiveSnapshotFailures + 1, 64)
            }

            guard let pendingSource = pendingRefreshSource else { break }
            let shouldForceSlurmData = pendingForceSlurmData
            self.pendingRefreshSource = nil
            self.pendingForceSlurmData = false
            source = pendingSource
            guard source.isConfigured else { break }
            forceSlurmData = shouldForceSlurmData
        }
    }

    /// The host a telemetry reading is bound to. SSH is bound to the host it
    /// polls; a status page has no host, so the configured feed host stands in.
    private func telemetryBindingHost(for source: ClusterSource) -> String {
        switch source {
        case let .ssh(host):
            return host.trimmingCharacters(in: .whitespacesAndNewlines)
        case .statusPage:
            return (telemetryDefaults.string(forKey: GPUTelemetrySettings.hostKey) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func startSlurmDataRefresh(host: String, force: Bool) {
        requestedSlurmDataHost = host
        let collector = slurmDataCollector
        Task { @MainActor [weak self] in
            let nextSnapshot = await collector.fetch(host: host, force: force, now: Date())
            guard let self,
                  self.requestedSlurmDataHost == host,
                  nextSnapshot.host == host
            else { return }
            if self.slurmDataSnapshot.host == host,
               self.slurmDataSnapshot.generatedAt > nextSnapshot.generatedAt {
                return
            }
            self.slurmDataSnapshot = nextSnapshot
        }
    }

    /// Loads the optional local telemetry feed. Reading happens off the main thread inside
    /// `GPUTelemetryReader`; nothing here starts collection or contacts the cluster.
    func refreshGPUTelemetry(host: String) async {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = GPUTelemetryReader.resolvedPath(
            telemetryDefaults.string(forKey: GPUTelemetrySettings.pathKey) ?? ""
        )
        let boundHost = (telemetryDefaults.string(forKey: GPUTelemetrySettings.hostKey)
            ?? GPUTelemetrySettings.defaultHost)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let attribution = GPUTelemetryAttribution(
            sourcePath: source,
            host: host,
            boundHost: boundHost
        )

        if gpuTelemetryAttribution != attribution {
            // Source, active host, or binding changed: the previous reading describes a different
            // feed, so drop it instead of relabelling it.
            gpuTelemetryAttribution = attribution
            gpuTelemetry = .empty
        }

        // Every invocation supersedes the one before it, so a slow read — from an old source, an
        // old binding, or simply an earlier overlapping refresh — can never land last.
        gpuTelemetryGeneration &+= 1
        let generation = gpuTelemetryGeneration

        guard !source.isEmpty,
              !boundHost.isEmpty,
              boundHost.caseInsensitiveCompare(host) == .orderedSame
        else {
            // Unconfigured or bound to another cluster: showing the feed here would be a lie.
            gpuTelemetry = .empty
            return
        }

        do {
            let next = try await readGPUTelemetry(source)
            guard generation == gpuTelemetryGeneration else { return }
            gpuTelemetry = next
        } catch is CancellationError {
        } catch {
            guard generation == gpuTelemetryGeneration else { return }
            // Keep the last good reading visible, flagged as no longer updating.
            var failed = gpuTelemetry.markingReadError(error.localizedDescription)
            failed.sourcePath = source
            gpuTelemetry = failed
        }
    }

    func refreshAfterWake(host: String) async {
        await refresh(host: host)
    }

    func refreshAfterWake(source: ClusterSource) async {
        await refresh(source: source)
    }

    func refreshState(at now: Date, staleAfter: TimeInterval) -> SnapshotRefreshState {
        guard hasLoaded else {
            return isRefreshing ? .refreshing : .unavailable
        }
        if errorMessage != nil {
            return snapshot.nodes.isEmpty ? .unavailable : .stale
        }
        if isRefreshing {
            return .refreshing
        }
        return now.timeIntervalSince(snapshot.generatedAt) <= staleAfter ? .fresh : .stale
    }
}

/// Which feed a stored GPU reading came from: the file, the host it was refreshed for, and the
/// host the feed is bound to. Any change invalidates the previous reading.
private struct GPUTelemetryAttribution: Equatable {
    let sourcePath: String
    let host: String
    let boundHost: String
}

struct RefreshConfiguration: Hashable {
    let source: ClusterSource
    let enabled: Bool
    let interval: Int

    init(source: ClusterSource, enabled: Bool, interval: Int) {
        self.source = source
        self.enabled = enabled
        self.interval = interval
    }

    /// Convenience for the SSH source, which callers identify by host.
    init(host: String, enabled: Bool, interval: Int) {
        self.init(source: .ssh(host: host), enabled: enabled, interval: interval)
    }
}
