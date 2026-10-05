import Foundation

enum ClusterClientError: LocalizedError, Sendable {
    case sshFailed(code: Int32, message: String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case let .sshFailed(code, message):
            return "SSH exited with status \(code): \(message)"
        case let .invalidResponse(message):
            return message
        }
    }
}

final class SSHProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var isCancelled = false

    func set(_ process: Process) {
        lock.lock()
        if isCancelled {
            lock.unlock()
            process.terminate()
            return
        }
        self.process = process
        lock.unlock()
    }

    func terminate() {
        lock.lock()
        isCancelled = true
        let process = process
        self.process = nil
        lock.unlock()
        process?.terminate()
    }
}

private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var isCancelled = false

    func set(_ task: Task<Void, Never>) {
        lock.lock()
        if isCancelled {
            lock.unlock()
            task.cancel()
            return
        }
        self.task = task
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let task = task
        self.task = nil
        lock.unlock()
        task?.cancel()
    }
}

struct SSHCommandResult: Sendable {
    let raw: String
    let exitStatus: Int32
    let timedOut: Bool
    let truncated: Bool
    let diagnostic: String
}

final class SSHOutputCapture: @unchecked Sendable {
    struct Result: Sendable {
        let raw: String
        let timedOut: Bool
        let truncated: Bool
    }

    private let lock = NSLock()
    private let maxBytes: Int
    private var data = Data()
    private var timedOut = false
    private var truncated = false

    init(maxBytes: Int) {
        self.maxBytes = max(0, maxBytes)
    }

    @discardableResult
    func append(_ chunk: Data) -> Bool {
        lock.lock()
        let exceededLimit = appendLocked(chunk)
        lock.unlock()
        return exceededLimit
    }

    func complete(with finalChunk: Data) -> Result {
        lock.lock()
        _ = appendLocked(finalChunk)
        let result = Result(
            raw: String(decoding: data, as: UTF8.self),
            timedOut: timedOut,
            truncated: truncated
        )
        lock.unlock()
        return result
    }

    func markTimedOut() {
        lock.lock()
        timedOut = true
        lock.unlock()
    }

    func finalReadLimit() -> Int {
        lock.lock()
        let remaining = maxBytes - data.count
        let limit = remaining == Int.max ? remaining : remaining + 1
        lock.unlock()
        return max(1, limit)
    }

    private func appendLocked(_ chunk: Data) -> Bool {
        let remaining = maxBytes - data.count
        guard chunk.count <= remaining else {
            if remaining > 0 {
                data.append(contentsOf: chunk.prefix(remaining))
            }
            let exceededLimit = !truncated
            truncated = true
            return exceededLimit
        }
        data.append(chunk)
        return false
    }
}

/// Every SSH poll shares one authenticated connection. Other users will not
/// have `ControlMaster` in `~/.ssh/config`, so the app supplies the options
/// itself: the master is created on first use, persists for eight hours, and
/// the socket lives under the app's own cache directory (mode 0700).
///
/// `%C` keeps the path short — ssh expands it to a hash of the local host,
/// remote host, port, and user, so two clusters never share a socket.
enum SSHMuxPolicy {
    static let bundleIdentifier = "edu.colby.gpu-cluster.community"
    static let controlPathSuffix = "ssh-%C"
    static let persistDuration = "8h"

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches", isDirectory: true)
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
    }

    static var controlPath: String {
        directory.appendingPathComponent(controlPathSuffix).path
    }

    /// Creates the socket directory 0700 once per process. A directory that
    /// cannot be prepared simply disables multiplexing rather than breaking SSH.
    static let isDirectoryReady: Bool = {
        let manager = FileManager.default
        do {
            try manager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            return true
        } catch {
            return manager.fileExists(atPath: directory.path)
        }
    }()

    /// Multiplexing options, or none when the socket directory is unusable.
    static var options: [String] {
        guard isDirectoryReady else { return [] }
        return [
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(controlPath)",
            "-o", "ControlPersist=\(persistDuration)",
        ]
    }
}

/// Best-effort teardown of the shared SSH master, so quitting the app does not
/// leave an authenticated connection parked for eight hours.
enum SSHMuxTeardown {
    static let defaultTimeout: TimeInterval = 2

    /// Runs `ssh -O exit` for the given host and returns once it finishes or the
    /// timeout elapses. Never throws and never reports failure: quitting must
    /// not be blocked by a cluster that is unreachable.
    @discardableResult
    static func exitMaster(host: String, timeout: TimeInterval = defaultTimeout) -> Bool {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, SSHMuxPolicy.isDirectoryReady else { return false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-O", "exit",
            "-o", "ControlPath=\(SSHMuxPolicy.controlPath)",
            "-o", "BatchMode=yes",
            trimmed,
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return false
        }

        let deadline = DispatchTime.now() + max(0, timeout)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline) {
            if process.isRunning { process.terminate() }
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

struct SSHCommandRunner: Sendable {
    typealias ArgumentBuilder = @Sendable (_ host: String, _ script: String) -> [String]

    static let defaultTimeout: TimeInterval = 25
    static let defaultMaxBytes = 2 * 1_024 * 1_024

    /// The exact argv the app hands to `/usr/bin/ssh`, multiplexing included.
    static func defaultArguments(host: String, script: String) -> [String] {
        [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=2",
        ] + SSHMuxPolicy.options + [
            host,
            script,
        ]
    }

    private let executableURL: URL
    private let arguments: ArgumentBuilder

    init() {
        executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        arguments = { host, script in
            Self.defaultArguments(host: host, script: script)
        }
    }

    init(executableURL: URL, arguments: @escaping ArgumentBuilder) {
        self.executableURL = executableURL
        self.arguments = arguments
    }

    func run(
        host: String,
        script: String,
        timeout: TimeInterval = Self.defaultTimeout,
        maxBytes: Int = Self.defaultMaxBytes
    ) async throws -> SSHCommandResult {
        let processBox = SSHProcessBox()
        let taskBox = TaskBox()
        let result: SSHCommandResult

        do {
            result = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let process = Process()
                    let output = Pipe()
                    let capture = SSHOutputCapture(maxBytes: maxBytes)
                    process.executableURL = executableURL
                    process.arguments = arguments(host, script)
                    process.standardOutput = output
                    process.standardError = output
                    output.fileHandleForReading.readabilityHandler = { handle in
                        let chunk = handle.availableData
                        guard !chunk.isEmpty else { return }
                        if capture.append(chunk) {
                            processBox.terminate()
                        }
                    }
                    process.terminationHandler = { finishedProcess in
                        taskBox.cancel()
                        output.fileHandleForReading.readabilityHandler = nil
                        let finalChunk = output.fileHandleForReading.readData(
                            ofLength: capture.finalReadLimit()
                        )
                        let captured = capture.complete(with: finalChunk)
                        let diagnostic = String(
                            captured.raw
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                .prefix(400)
                        )
                        continuation.resume(returning: SSHCommandResult(
                            raw: captured.raw,
                            exitStatus: finishedProcess.terminationStatus,
                            timedOut: captured.timedOut,
                            truncated: captured.truncated,
                            diagnostic: diagnostic
                        ))
                    }

                    do {
                        try process.run()
                        processBox.set(process)
                        if Task.isCancelled {
                            processBox.terminate()
                        }
                        let timeoutTask = Task {
                            let nanoseconds = Self.timeoutNanoseconds(timeout)
                            try? await Task.sleep(nanoseconds: nanoseconds)
                            guard !Task.isCancelled, process.isRunning else { return }
                            capture.markTimedOut()
                            processBox.terminate()
                        }
                        taskBox.set(timeoutTask)
                    } catch {
                        output.fileHandleForReading.readabilityHandler = nil
                        continuation.resume(throwing: error)
                    }
                }
            } onCancel: {
                processBox.terminate()
            }
        } catch {
            try Task.checkCancellation()
            throw error
        }

        try Task.checkCancellation()
        return result
    }

    private static func timeoutNanoseconds(_ timeout: TimeInterval) -> UInt64 {
        let seconds = max(0, timeout)
        let maximumSeconds = Double(UInt64.max) / 1_000_000_000
        return UInt64(min(seconds, maximumSeconds) * 1_000_000_000)
    }
}

struct ClusterClient: Sendable {
    static let remoteScript = """
    set -u
    echo '\(SlurmParser.sinfoMarker)'
    sinfo -p gpu -N -h --Format='NodeHost:|,StateCompact:|,Gres:|,GresUsed:' 2>&1
    sinfo_rc=$?
    echo '\(SlurmParser.squeueMarker)'
    squeue -p gpu -h -o '%i|%u|%j|%T|%M|%l|%D|%N|%R' 2>&1
    squeue_rc=$?
    echo "\(SlurmParser.rcMarker) ${sinfo_rc} ${squeue_rc}"
    """

    private let runner: SSHCommandRunner

    init(runner: SSHCommandRunner = SSHCommandRunner()) {
        self.runner = runner
    }

    func fetch(host: String) async throws -> ClusterSnapshot {
        let result = try await runner.run(
            host: host,
            script: Self.remoteScript
        )

        if result.timedOut {
            throw ClusterClientError.sshFailed(
                code: -1,
                message: "Timed out after 25s talking to \(host)"
            )
        }
        if result.exitStatus != 0 && !result.raw.contains(SlurmParser.rcMarker) {
            throw ClusterClientError.sshFailed(
                code: result.exitStatus,
                message: result.diagnostic
            )
        }
        return try SlurmParser.parseSnapshot(result.raw)
    }
}
