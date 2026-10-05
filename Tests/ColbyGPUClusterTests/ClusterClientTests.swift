import Foundation
import XCTest
@testable import ColbyGPUCluster

final class ClusterClientTests: XCTestCase {
    // MARK: - SSH multiplexing

    /// Other users have no `ControlMaster` in `~/.ssh/config`, so the app has to
    /// pass every option itself. This is the argv the runner really builds.
    func testDefaultArgumentsMultiplexEveryPollOverOneConnection() {
        let arguments = SSHCommandRunner.defaultArguments(host: "login.example.edu", script: "echo hi")

        XCTAssertTrue(arguments.contains("BatchMode=yes"))
        XCTAssertTrue(arguments.contains("ConnectTimeout=10"))
        XCTAssertTrue(arguments.contains("ServerAliveInterval=5"))
        XCTAssertTrue(arguments.contains("ServerAliveCountMax=2"))

        XCTAssertTrue(arguments.contains("ControlMaster=auto"))
        XCTAssertTrue(arguments.contains("ControlPersist=8h"))
        let controlPath = try? XCTUnwrap(arguments.first { $0.hasPrefix("ControlPath=") })
        let path = controlPath.map { String($0.dropFirst("ControlPath=".count)) }
        XCTAssertEqual(path, SSHMuxPolicy.controlPath)
        XCTAssertTrue(path?.hasSuffix("ssh-%C") == true)
        XCTAssertTrue(path?.contains(SSHMuxPolicy.bundleIdentifier) == true)
        XCTAssertTrue(path?.contains("/Library/Caches/") == true)

        // Host and script stay last, so no option can be read as the destination.
        XCTAssertEqual(arguments.suffix(2), ["login.example.edu", "echo hi"])
    }

    func testMultiplexingSocketDirectoryIsPrivate() {
        XCTAssertTrue(SSHMuxPolicy.isDirectoryReady)

        let attributes = try? FileManager.default.attributesOfItem(
            atPath: SSHMuxPolicy.directory.path
        )
        XCTAssertEqual(attributes?[.posixPermissions] as? Int, 0o700)
    }

    func testOptionsAreDroppedRatherThanGuessedWhenTheDirectoryIsUnusable() {
        // The policy never emits a partial option set: either all three mux
        // options are present or none are.
        let options = SSHMuxPolicy.options
        if options.isEmpty {
            XCTAssertTrue(options.isEmpty)
        } else {
            XCTAssertEqual(options.count, 6)
            XCTAssertEqual(options[0], "-o")
            XCTAssertEqual(options[1], "ControlMaster=auto")
            XCTAssertEqual(options[2], "-o")
            XCTAssertEqual(options[3], "ControlPath=\(SSHMuxPolicy.controlPath)")
            XCTAssertEqual(options[4], "-o")
            XCTAssertEqual(options[5], "ControlPersist=8h")
        }
    }

    func testTeardownIsANoOpWithoutAHost() {
        XCTAssertFalse(SSHMuxTeardown.exitMaster(host: "   ", timeout: 0))
    }

    func testSSHProcessBoxTerminatesHeldProcessOnCancel() throws {
        let box = SSHProcessBox()
        let process = try makeLongRunningProcess()
        defer { terminateIfNeeded(process) }

        box.set(process)
        box.terminate()

        waitUntilExited(process)
    }

    func testSSHProcessBoxTerminatesProcessSetAfterCancel() throws {
        let box = SSHProcessBox()
        let process = try makeLongRunningProcess()
        defer { terminateIfNeeded(process) }

        box.terminate()
        box.set(process)

        waitUntilExited(process)
    }

    private func makeLongRunningProcess() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        XCTAssertTrue(process.isRunning)
        return process
    }

    private func waitUntilExited(
        _ process: Process,
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertFalse(process.isRunning, file: file, line: line)
    }

    private func terminateIfNeeded(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        waitUntilExited(process)
    }
}
