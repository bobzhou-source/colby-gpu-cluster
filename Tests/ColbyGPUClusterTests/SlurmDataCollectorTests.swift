import Foundation
import XCTest
@testable import ColbyGPUCluster

final class SlurmDataCollectorTests: XCTestCase {
    func testDomainTTLsMatchTheLowFrequencyPollingPlan() {
        XCTAssertEqual(SlurmDataCommands.ttl(for: .nodesResources), 60)
        XCTAssertEqual(SlurmDataCommands.ttl(for: .activeJobs), 60)
        XCTAssertEqual(SlurmDataCommands.ttl(for: .priorityScheduling), 60)
        XCTAssertEqual(SlurmDataCommands.ttl(for: .stepsRuntime), 300)
        XCTAssertEqual(SlurmDataCommands.ttl(for: .schedulerDiagnostics), 300)
        XCTAssertEqual(SlurmDataCommands.ttl(for: .accounting), 1_800)
        XCTAssertEqual(SlurmDataCommands.ttl(for: .policy), 1_800)
        XCTAssertEqual(SlurmDataCommands.ttl(for: .controllerConfiguration), 3_600)
        XCTAssertEqual(SlurmDataCommands.ttl(for: .partitions), 3_600)
        XCTAssertEqual(SlurmDataCommands.ttl(for: .resourceCatalog), 3_600)
    }

    /// The collector must run one SSH command per due domain, and nothing for a domain whose
    /// TTL has not elapsed. `force` remains an explicit override.
    func testDomainsNotPastTTLAreNotRunAgain() async throws {
        let probe = try CountingRunner()
        defer { probe.cleanUp() }
        let collector = SlurmDataCollector(runner: probe.runner)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let domainCount = SlurmDataDomain.allCases.count

        _ = await collector.fetch(host: "probe-host", now: start)
        XCTAssertEqual(probe.count(), domainCount)

        // Only the 60 s domains have expired; the 300 s/1 800 s/3 600 s domains stay cached.
        _ = await collector.fetch(host: "probe-host", now: start.addingTimeInterval(30))
        XCTAssertEqual(probe.count(), domainCount, "no domain has passed its TTL yet")

        _ = await collector.fetch(host: "probe-host", now: start.addingTimeInterval(61))
        XCTAssertEqual(probe.count(), domainCount + 3, "only the 60 s domains are due")

        _ = await collector.fetch(host: "probe-host", force: true, now: start.addingTimeInterval(62))
        XCTAssertEqual(probe.count(), 2 * domainCount + 3, "force re-runs every domain")
    }

    /// A runner that counts invocations instead of contacting a host.
    private struct CountingRunner {
        let runner: SSHCommandRunner
        private let counterURL: URL
        private let directory: URL

        init() throws {
            let directory = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("slurm-collector-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let counterURL = directory.appendingPathComponent("invocations")
            try "".write(to: counterURL, atomically: true, encoding: .utf8)
            let executableURL = directory.appendingPathComponent("count-invocation.sh")
            try """
            #!/bin/sh
            printf 'x\n' >> '\(counterURL.path)'
            """.write(to: executableURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: executableURL.path
            )

            self.directory = directory
            self.counterURL = counterURL
            self.runner = SSHCommandRunner(executableURL: executableURL) { host, script in
                [host, script]
            }
        }

        func count() -> Int {
            let text = (try? String(contentsOf: counterURL, encoding: .utf8)) ?? ""
            return text.filter { $0 == "x" }.count
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
