import Foundation

actor SlurmDataCollector {
    private static let maximumConcurrentProcesses = 3
    private static let maximumCaptureBytes = 2 * 1_024 * 1_024
    private static let maximumDiagnosticCharacters = 400

    private struct PendingRefresh: Sendable {
        let domain: SlurmDataDomain
        let observedAt: Date
    }

    private let runner: SSHCommandRunner
    private let processLimiter: SlurmSSHProcessLimiter

    private var snapshot: SlurmDataSnapshot = .empty
    private var cacheGeneration = 0
    private var pendingRefreshes: [SlurmDataDomain: Date] = [:]
    private var refreshingDomains: Set<SlurmDataDomain> = []
    private var refreshTask: Task<Void, Never>?

    init(runner: SSHCommandRunner = SSHCommandRunner()) {
        self.runner = runner
        processLimiter = SlurmSSHProcessLimiter(
            maximumConcurrentProcesses: Self.maximumConcurrentProcesses
        )
    }

    func fetch(
        host: String,
        force: Bool = false,
        now: Date = Date()
    ) async -> SlurmDataSnapshot {
        resetIfNeeded(for: host, at: now)

        let dueDomains = SlurmDataDomain.allCases.filter { domain in
            force || snapshot[domain].map { $0.expiresAt <= now } ?? true
        }

        for domain in dueDomains where !refreshingDomains.contains(domain) {
            if let pendingDate = pendingRefreshes[domain] {
                pendingRefreshes[domain] = max(pendingDate, now)
            } else {
                pendingRefreshes[domain] = now
            }
        }

        if refreshTask == nil, !pendingRefreshes.isEmpty {
            let generation = cacheGeneration
            refreshTask = Task {
                await runRefreshLoop(host: host, generation: generation)
            }
        }

        let task = refreshTask
        await task?.value
        return snapshot
    }

    private func resetIfNeeded(for host: String, at date: Date) {
        guard snapshot.host != host else { return }

        cacheGeneration &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        pendingRefreshes.removeAll(keepingCapacity: true)
        refreshingDomains.removeAll(keepingCapacity: true)
        snapshot.reset(forHost: host, at: date)
    }

    private func runRefreshLoop(host: String, generation: Int) async {
        while generation == cacheGeneration, snapshot.host == host {
            let batch = SlurmDataDomain.allCases.compactMap { domain -> PendingRefresh? in
                guard let observedAt = pendingRefreshes.removeValue(forKey: domain) else {
                    return nil
                }
                return PendingRefresh(domain: domain, observedAt: observedAt)
            }

            guard !batch.isEmpty else {
                refreshTask = nil
                return
            }

            refreshingDomains.formUnion(batch.map(\.domain))
            let observations = await collect(batch, from: host)

            guard generation == cacheGeneration, snapshot.host == host else {
                return
            }

            refreshingDomains.subtract(batch.map(\.domain))
            let generatedAt = batch.map(\.observedAt).max() ?? snapshot.generatedAt
            for observation in observations {
                snapshot.update(with: observation, generatedAt: generatedAt)
            }

            if pendingRefreshes.isEmpty {
                refreshTask = nil
                return
            }
        }
    }

    private func collect(
        _ batch: [PendingRefresh],
        from host: String
    ) async -> [SlurmDomainObservation] {
        let runner = runner
        let processLimiter = processLimiter

        return await withTaskGroup(of: SlurmDomainObservation.self) { group in
            for refresh in batch {
                group.addTask {
                    let domain = refresh.domain
                    let definitions = SlurmDataCommands.definitions(for: domain)
                    let ttl = SlurmDataCommands.ttl(for: domain)

                    do {
                        let result = try await processLimiter.run {
                            try await runner.run(
                                host: host,
                                script: SlurmDataCommands.script(for: domain),
                                timeout: Self.timeout(for: domain),
                                maxBytes: Self.maximumCaptureBytes
                            )
                        }
                        return SlurmDataParser.parse(
                            domain: domain,
                            definitions: definitions,
                            result: result,
                            observedAt: refresh.observedAt,
                            ttl: ttl
                        )
                    } catch {
                        return Self.unavailableObservation(
                            domain: domain,
                            definitions: definitions,
                            error: error,
                            observedAt: refresh.observedAt,
                            ttl: ttl
                        )
                    }
                }
            }

            var observations: [SlurmDomainObservation] = []
            observations.reserveCapacity(batch.count)
            for await observation in group {
                observations.append(observation)
            }
            return observations
        }
    }

    private static func timeout(for domain: SlurmDataDomain) -> TimeInterval {
        switch domain {
        case .partitions, .nodesResources, .activeJobs, .priorityScheduling:
            return 20
        case .controllerConfiguration, .stepsRuntime, .schedulerDiagnostics:
            return 30
        case .resourceCatalog, .accounting, .policy:
            return 45
        }
    }

    private static func unavailableObservation(
        domain: SlurmDataDomain,
        definitions: [SlurmCommandDefinition],
        error: any Error,
        observedAt: Date,
        ttl: TimeInterval
    ) -> SlurmDomainObservation {
        let diagnostic = boundedDiagnostic("SSH transport failed: \(error.localizedDescription)")
        let commands = definitions.map { definition in
            SlurmCommandObservation(
                commandID: definition.id,
                parserKind: definition.parserKind,
                status: .unavailable,
                exitCode: nil,
                diagnostic: diagnostic
            )
        }

        return SlurmDomainObservation(
            domain: domain,
            observedAt: observedAt,
            expiresAt: observedAt.addingTimeInterval(ttl),
            status: .unavailable,
            commands: commands,
            data: nil
        )
    }

    private static func boundedDiagnostic(_ diagnostic: String) -> String {
        String(diagnostic.prefix(maximumDiagnosticCharacters))
    }
}

private actor SlurmSSHProcessLimiter {
    private let maximumConcurrentProcesses: Int
    private var activeProcessCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var nextWaiterIndex = 0

    init(maximumConcurrentProcesses: Int) {
        precondition(maximumConcurrentProcesses > 0)
        self.maximumConcurrentProcesses = maximumConcurrentProcesses
    }

    func run<Result: Sendable>(
        _ operation: @Sendable () async throws -> Result
    ) async throws -> Result {
        await acquire()

        do {
            try Task.checkCancellation()
            let result = try await operation()
            release()
            return result
        } catch {
            release()
            throw error
        }
    }

    private func acquire() async {
        if activeProcessCount < maximumConcurrentProcesses {
            activeProcessCount += 1
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        guard nextWaiterIndex < waiters.count else {
            activeProcessCount -= 1
            if nextWaiterIndex > 0 {
                waiters.removeAll(keepingCapacity: true)
                nextWaiterIndex = 0
            }
            return
        }

        let continuation = waiters[nextWaiterIndex]
        nextWaiterIndex += 1
        continuation.resume()
    }
}
