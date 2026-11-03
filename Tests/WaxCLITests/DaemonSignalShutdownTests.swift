#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import Wax
@testable import WaxCore
@testable import wax_cli

/// SIGTERM must shut the broker daemon down gracefully: finish the request in
/// flight, close the store, release its lock and remove the socket, then exit 0.
/// The client's SIGTERM grace before SIGKILL is 2s, so shutdown must beat it.
@Suite struct DaemonSignalShutdownTests {
    private static let clientTerminateGraceSeconds: TimeInterval = 2

    @Test(.timeLimit(.minutes(2)))
    func daemonSocketModeFinishesInFlightWorkAndExitsCleanlyOnSIGTERM() async throws {
        let fixture = try DaemonFixture()
        defer { fixture.remove() }
        let daemon = try fixture.launch(arguments: ["--socket-path", fixture.socketPath])
        defer { daemon.forceStop() }
        try await fixture.waitForSocket()

        // A client that has connected but not finished its request. It trickles
        // whitespace so the daemon's per-read timeout never ends the request.
        let inFlight = try SocketClient(path: fixture.socketPath)
        defer { inFlight.close() }
        let trickle = inFlight.startTrickle()

        // The accept loop takes connections in order, so once a later client is
        // answered, the trickling one has been accepted and is in flight.
        let stats = try await SocketClient.roundTrip(
            #"{"command":"stats","arguments":{}}"#,
            path: fixture.socketPath
        )
        #expect(stats.contains(#""ok":true"#), "stats failed: \(stats)")

        kill(daemon.pid, SIGTERM)
        await trickle.stop()
        let remembered = try await inFlight.finish(
            #"{"command":"remember","arguments":{"content":"\#(fixture.token) in flight at SIGTERM"}}"#
        )
        #expect(remembered.contains(#""ok":true"#), "in-flight remember failed: \(remembered)")

        let exit = try await daemon.waitForExit()
        #expect(exit.reason == .exit && exit.status == 0, "daemon exited with \(exit)")
        #expect(
            exit.elapsed < Self.clientTerminateGraceSeconds,
            "daemon took \(exit.elapsed)s to shut down, past the client's SIGTERM grace"
        )
        #expect(!FileManager.default.fileExists(atPath: fixture.socketPath), "socket was not removed")
        try fixture.expectStoreReleasedAndCommitted()
    }

    /// The stdio loop waits on stdin off the cooperative pool and sees the
    /// shutdown request while the client is quiet, even on a strict pool.
    @Test(.timeLimit(.minutes(2)))
    func daemonStdioModeExitsCleanlyOnSIGTERMOnAStrictCooperativePool() async throws {
        let fixture = try DaemonFixture()
        defer { fixture.remove() }
        let daemon = try fixture.launch(
            arguments: [],
            environment: ["LIBDISPATCH_COOPERATIVE_POOL_STRICT": "1"],
            stdio: true
        )
        defer { daemon.forceStop() }

        let remembered = try await daemon.stdioRoundTrip(
            #"{"command":"remember","arguments":{"content":"\#(fixture.token) over stdio"}}"#
        )
        #expect(remembered.contains(#""ok":true"#), "stdio remember failed: \(remembered)")

        // stdin stays open: the daemon is idle, waiting for the next request.
        kill(daemon.pid, SIGTERM)

        let exit = try await daemon.waitForExit()
        #expect(exit.reason == .exit && exit.status == 0, "daemon exited with \(exit)")
        #expect(
            exit.elapsed < Self.clientTerminateGraceSeconds,
            "daemon took \(exit.elapsed)s to shut down, past the client's SIGTERM grace"
        )
        try fixture.expectStoreReleasedAndCommitted()
    }
}

private struct DaemonFixture {
    let root: URL
    let token = "sigterm-\(UUID().uuidString.prefix(8).lowercased())"

    init() throws {
        // Short path: Unix socket paths are limited to about 104 bytes.
        root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("wxsg-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    var storeURL: URL { root.appendingPathComponent("daemon.wax") }
    var socketPath: String { root.appendingPathComponent("daemon.sock").path }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func launch(
        arguments: [String],
        environment: [String: String] = [:],
        stdio: Bool = false
    ) throws -> DaemonProcess {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try builtProductPath(named: "wax-cli"))
        process.arguments = [
            "daemon",
            "--store-path", storeURL.path,
            "--session-root", root.appendingPathComponent("sessions").path,
            "--no-embedder",
            "--idle-timeout-secs", "300",
        ] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdio ? stdin : FileHandle.nullDevice
        process.standardOutput = stdio ? stdout : FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return try DaemonProcess(process: process, stdin: stdin, stdout: stdout)
    }

    func waitForSocket() async throws {
        let deadline = Date().addingTimeInterval(60)
        while !FileManager.default.fileExists(atPath: socketPath) {
            guard Date() < deadline else { throw DaemonTestError("daemon never created \(socketPath)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// The lock is free and a fresh process reopens the store and finds the data.
    func expectStoreReleasedAndCommitted() throws {
        let lock = try FileLock.tryAcquire(at: storeURL, mode: .exclusive)
        #expect(lock != nil, "the daemon left the store locked")
        try lock?.release()

        let recall = Process()
        recall.executableURL = URL(fileURLWithPath: try builtProductPath(named: "wax-cli"))
        recall.arguments = [
            "recall", "--direct-store", "--store-path", storeURL.path,
            "--no-embedder", "--format", "json", token,
        ]
        let output = Pipe()
        recall.standardOutput = output
        recall.standardError = FileHandle.nullDevice
        try recall.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        recall.waitUntilExit()
        #expect(recall.terminationStatus == 0, "reopening the store failed: \(text)")
        #expect(text.contains(token), "committed memory missing after shutdown: \(text)")
    }
}

private struct DaemonExit: CustomStringConvertible {
    let reason: Process.TerminationReason
    let status: Int32
    /// Seconds from the waitForExit call to the exit.
    let elapsed: TimeInterval

    var description: String {
        "\(reason == .exit ? "exit" : "signal") \(status) after \(elapsed)s"
    }
}

private final class DaemonProcess: @unchecked Sendable {
    let process: Process
    let stdin: Pipe
    let stdout: Pipe
    private let exited = DispatchSemaphore(value: 0)

    init(process: Process, stdin: Pipe, stdout: Pipe) throws {
        self.process = process
        self.stdin = stdin
        self.stdout = stdout
        let exited = exited
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
    }

    var pid: pid_t { process.processIdentifier }

    /// Waits off the cooperative pool. The 60s bound only catches a hang.
    func waitForExit() async throws -> DaemonExit {
        let start = Date()
        let exited = exited
        let didExit = await BlockingWork.run { exited.wait(timeout: .now() + 60) == .success }
        guard didExit else { throw DaemonTestError("daemon \(pid) did not exit after SIGTERM") }
        return DaemonExit(
            reason: process.terminationReason,
            status: process.terminationStatus,
            elapsed: Date().timeIntervalSince(start)
        )
    }

    func stdioRoundTrip(_ line: String) async throws -> String {
        stdin.fileHandleForWriting.write(Data((line + "\n").utf8))
        let fd = stdout.fileHandleForReading.fileDescriptor
        return try await BlockingWork.run { try readLine(fd: fd) }
    }

    func forceStop() {
        if process.isRunning {
            kill(pid, SIGKILL)
            process.waitUntilExit()
        }
    }
}

private final class SocketClient: @unchecked Sendable {
    let fd: Int32

    init(path: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DaemonTestError("socket failed") }
        var noSIGPIPE: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSIGPIPE, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in bytes.enumerated() {
                buffer[index] = byte
            }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            Darwin.close(fd)
            throw DaemonTestError("connect to \(path) failed")
        }
    }

    func close() {
        Darwin.close(fd)
    }

    func send(_ text: String) throws {
        let bytes = Array(text.utf8)
        guard write(fd, bytes, bytes.count) == bytes.count else {
            throw DaemonTestError("socket write failed")
        }
    }

    /// Writes a space every 100ms on a GCD thread until stopped.
    func startTrickle() -> Trickle {
        let trickle = Trickle()
        let fd = fd
        DispatchQueue.global().async {
            while !trickle.isStopped {
                _ = write(fd, " ", 1)
                usleep(100_000)
            }
            trickle.markDone()
        }
        return trickle
    }

    /// Sends the rest of the request and reads the response line.
    func finish(_ line: String) async throws -> String {
        try send(line + "\n")
        shutdown(fd, SHUT_WR)
        let fd = fd
        return try await BlockingWork.run { try readLine(fd: fd) }
    }

    static func roundTrip(_ line: String, path: String) async throws -> String {
        let client = try SocketClient(path: path)
        defer { client.close() }
        return try await client.finish(line)
    }
}

private final class Trickle: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private let done = DispatchSemaphore(value: 0)

    var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    func markDone() {
        done.signal()
    }

    /// Returns once the trickle thread has made its last write.
    func stop() async {
        lock.withLock { stopped = true }
        let done = done
        await BlockingWork.run { done.wait() }
    }
}

/// Reads one newline-terminated line. The 30s poll bound only catches a hang.
private func readLine(fd: Int32) throws -> String {
    var buffer = Data()
    while true {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&descriptor, 1, 30_000)
        if ready < 0, errno == EINTR { continue }
        guard ready > 0 else { throw DaemonTestError("timed out waiting for a response line") }
        var chunk = [UInt8](repeating: 0, count: 4096)
        let count = read(fd, &chunk, chunk.count)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { break }
        buffer.append(contentsOf: chunk.prefix(count))
        if let newline = buffer.firstIndex(of: 0x0A) {
            return String(decoding: buffer[..<newline], as: UTF8.self)
        }
    }
    return String(decoding: buffer, as: UTF8.self)
}

private struct DaemonTestError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
#endif
