import Foundation
import XCTest
@testable import ColbyGPUCluster

/// Decoding of Colby HPC's public HTML GPU page. The fixture is the live
/// `https://hpc.colby.edu/public/gpu.html` captured on 2026-10-08.
final class HTMLStatusPageMapperTests: XCTestCase {
    private func fixtureData() throws -> Data {
        let url = Bundle.module.url(forResource: "colby-hpc-gpu", withExtension: "html", subdirectory: "Resources")
            ?? Bundle.module.url(forResource: "colby-hpc-gpu", withExtension: "html")
        return try Data(contentsOf: try XCTUnwrap(url, "missing fixture colby-hpc-gpu.html"))
    }

    func testLiveColbyPageMapsEveryNodeWithSchedulerCounts() throws {
        let snapshot = try HTMLStatusPageMapper.snapshot(from: fixtureData(), now: Date(timeIntervalSince1970: 0))

        XCTAssertEqual(snapshot.nodes.map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending },
                       ["n1", "n2", "n7", "n8", "n10", "n15", "n16"])
        XCTAssertEqual(snapshot.totalGPUs, 16)
        // n1 is draining, so its GPUs are not free even though the page lists them.
        XCTAssertEqual(snapshot.freeGPUs, 10)
        XCTAssertTrue(snapshot.pending.isEmpty)
        XCTAssertFalse(snapshot.queuePublished)

        let draining = try XCTUnwrap(snapshot.nodes.first { $0.name == "n1" })
        XCTAssertEqual(draining.status, .drain)
        XCTAssertEqual(draining.stateLabel, "Draining")
        XCTAssertEqual(draining.freeGPUCount, 0)

        let full = try XCTUnwrap(snapshot.nodes.first { $0.name == "n15" })
        XCTAssertEqual(full.profile, "h200")
        XCTAssertEqual(full.gpuCount, 4)
        XCTAssertEqual(full.freeGPUCount, 0)

        let rtx = try XCTUnwrap(snapshot.nodes.first { $0.name == "n16" })
        XCTAssertEqual(rtx.profile, "rtxpro6000")
        XCTAssertEqual(rtx.freeGPUCount, 4)
    }

    func testLastUpdatedIsReadAsColbyLocalTime() throws {
        let snapshot = try HTMLStatusPageMapper.snapshot(from: fixtureData(), now: Date(timeIntervalSince1970: 0))
        // "2026-10-08 19:23:02 EDT" is 23:23:02 UTC.
        XCTAssertEqual(snapshot.generatedAt, ISO8601Parsing.date("2026-10-08T23:23:02Z"))
    }

    func testMultiTypeNodesMatchAllocationByTypeAndClampToTotal() throws {
        let html = """
        <table><tbody>
        <tr><td><strong>n9</strong></td><td>mixed</td><td>A100:2,L4:1</td><td>L4:3,A100:1</td></tr>
        <tr><td><strong>n3</strong></td><td>idle</td><td>none</td><td>none</td></tr>
        </tbody></table>
        """
        let snapshot = try HTMLStatusPageMapper.snapshot(from: Data(html.utf8), now: Date(timeIntervalSince1970: 7))

        // A row with no parseable GPU resources is not a GPU node.
        XCTAssertEqual(snapshot.nodes.map(\.name), ["n9"])
        let node = try XCTUnwrap(snapshot.nodes.first)
        XCTAssertEqual(node.gres.map(\.gpuType), ["A100", "L4"])
        XCTAssertEqual(node.gres.map(\.used), [1, 1])
        XCTAssertEqual(node.freeGPUCount, 1)
        XCTAssertEqual(snapshot.generatedAt, Date(timeIntervalSince1970: 7))
    }

    func testHTMLWithoutANodeTableIsRejected() {
        XCTAssertThrowsError(try HTMLStatusPageMapper.snapshot(from: Data("<html><body>Not Found</body></html>".utf8))) {
            XCTAssertEqual($0 as? StatusFeedError, .unreadableHTML)
        }
    }

    func testSinfoFlagSuffixesKeepTheBaseStateAvailability() throws {
        // gpu.html publishes sinfo's long state with flag suffixes; `mixed-`
        // (planned by backfill) showed up live on n15 on 2026-10-08.
        let html = """
        <table><tbody>
        <tr><td>n15</td><td>mixed-</td><td>H200:4</td><td>H200:2</td></tr>
        <tr><td>n2</td><td>idle*</td><td>L40S:2</td><td>L40S:0</td></tr>
        <tr><td>n7</td><td>drained$</td><td>L4:1</td><td>L4:0</td></tr>
        </tbody></table>
        """
        let nodes = try HTMLStatusPageMapper.snapshot(from: Data(html.utf8)).nodes
        let planned = try XCTUnwrap(nodes.first { $0.name == "n15" })
        XCTAssertEqual(planned.status, .partial)
        XCTAssertEqual(planned.state, "mixed")
        XCTAssertEqual(planned.stateLabel, "Partial · held for a queued job")
        XCTAssertEqual(planned.freeGPUCount, 2)

        let silent = try XCTUnwrap(nodes.first { $0.name == "n2" })
        XCTAssertEqual(silent.status, .drain)
        XCTAssertEqual(silent.stateLabel, "Not responding")
        XCTAssertEqual(silent.freeGPUCount, 0)

        XCTAssertEqual(nodes.first { $0.name == "n7" }?.status, .drain)
    }

    func testHTTPClientRoutesHTMLAndJSONBodiesToTheirMappers() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureURLProtocol.self]
        let client = HTTPStatusClient(session: URLSession(configuration: configuration))

        FixtureURLProtocol.body = try fixtureData()
        let html = try await client.fetch(urlString: "https://status.test/gpu.html")
        XCTAssertEqual(html.totalGPUs, 16)

        FixtureURLProtocol.body = Data(#"{"schema": "colby-gpu-status/1", "nodes": []}"#.utf8)
        let json = try await client.fetch(urlString: "https://status.test/status.json")
        XCTAssertTrue(json.nodes.isEmpty)
    }

    func testTheDefaultSourceIsColbysPublicPageNotSSH() {
        let source = ClusterSourceResolution.source(
            kind: ClusterSourceKind.statusPage.rawValue,
            url: ClusterSourceDefaults.statusPageURL,
            host: ""
        )
        XCTAssertFalse(source.usesSSH)
        XCTAssertTrue(source.isConfigured)
    }
}

/// Serves `body` for every request so the HTTP client runs without a network.
private final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
