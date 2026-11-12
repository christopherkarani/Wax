#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import Wax
@testable import WaxCore
@testable import wax_cli

/// SIGTERM must shut the broker daemon down gracefully: drop clients still
/// sending a request, close the store, release its lock and remove the socket,
/// then exit 0. The client's SIGTERM grace before SIGKILL is 2s, so shutdown
/// must beat it, measured from the kill.
@Suite struct DaemonSignalShutdownTests {
    private static let clientTerminateGraceSeconds: TimeInterval = 2

    /// A client trickling one byte every 0.5s never finishes its request. It
    /// must not hold shutdown past the grace or keep the store open.
    @Test(.timeLimit(.minutes(2)))
    func daemonSocketModeDropsASlowClientAndExitsCleanlyOnSIGTERM() async throws {
        let fixture = try DaemonFixture()
        defer { fixture.remove() }
        // Shutdown must drop the slow client. With the 5s read deadline, a loaded runner can
        // answer it with a deadline error before the test gets to SIGTERM.
        let daemon = try fixture.launch(
            arguments: ["--socket-path", fixture.socketPath],
            environment: DaemonFixture.longReadDeadline
        )
        defer { daemon.forceStop() }
        try await fixture.waitForSocket(daemon)

        let remembered = try await SocketClient.roundTrip(
            #"{"command":"remember","arguments":{"content":"\#(fixture.token) before SIGTERM"}}"#,
            path: fixture.socketPath
        )
        #expect(remembered.contains(#""ok":true"#), "remember failed: \(remembered)")

        let slow = try SocketClient(path: fixture.socketPath)
        defer { slow.close() }
        let trickle = slow.startTrickle(everyMicroseconds: 500_000)

        // The accept loop takes connections in order, so once a later client is
        // answered, the slow one has been accepted.
        let stats = try await SocketClient.roundTrip(
            #"{"command":"stats","arguments":{}}"#,
            path: fixture.socketPath
        )
        #expect(stats.contains(#""ok":true"#), "stats failed: \(stats)")

        let killedAt = Date()
        kill(daemon.pid, SIGTERM)
        let exit = try await daemon.waitForExit(since: killedAt)
        await trickle.stop()

        #expect(exit.reason == .exit && exit.status == 0, "daemon exited with \(exit)")
        #expect(
            exit.elapsed < Self.clientTerminateGraceSeconds,
            "daemon took \(exit) from SIGTERM, past the client's SIGTERM grace; \(fixture.shutdownTimeline(since: killedAt))"
        )
        #expect(!FileManager.default.fileExists(atPath: fixture.socketPath), "socket was not removed")
        let fd = slow.fd
        let slowResponse = try await BlockingWork.run { try readLine(fd: fd) }
        #expect(slowResponse.isEmpty, "the slow client was answered instead of dropped: \(slowResponse)")
        try await fixture.expectStoreReleasedAndCommitted()
    }

    /// One read deadline from accept: trickled bytes must not keep a request
    /// open, and the daemon goes on serving other clients.
    @Test(.timeLimit(.minutes(2)))
    func daemonSocketModeEndsARequestAtItsReadDeadline() async throws {
        let fixture = try DaemonFixture()
        defer { fixture.remove() }
        let daemon = try fixture.launch(arguments: ["--socket-path", fixture.socketPath])
        defer { daemon.forceStop() }
        try await fixture.waitForSocket(daemon)

        let slow = try SocketClient(path: fixture.socketPath)
        defer { slow.close() }
        let trickle = slow.startTrickle(everyMicroseconds: 500_000)
        let fd = slow.fd
        let response = try await BlockingWork.run { try readLine(fd: fd) }
        await trickle.stop()
        #expect(response.contains(#""ok":false"#), "slow request was not failed: \(response)")
        #expect(response.contains("not received within"), "unexpected response: \(response)")

        let stats = try await SocketClient.roundTrip(
            #"{"command":"stats","arguments":{}}"#,
            path: fixture.socketPath
        )
        #expect(stats.contains(#""ok":true"#), "stats failed after the deadline: \(stats)")
    }

    /// Each client holds a thread, so clients past the cap get a busy failure
    /// at once instead of a thread, and a freed slot serves again.
    @Test(.timeLimit(.minutes(2)))
    func daemonSocketModeRefusesClientsPastItsCap() async throws {
        let fixture = try DaemonFixture()
        defer { fixture.remove() }
        let daemon = try fixture.launch(
            arguments: ["--socket-path", fixture.socketPath, "--max-clients", "2"],
            environment: DaemonFixture.longReadDeadline
        )
        defer { daemon.forceStop() }
        try await fixture.waitForSocket(daemon)

        // Two clients that have not sent yet hold both slots until they do.
        let holders = try [SocketClient(path: fixture.socketPath), SocketClient(path: fixture.socketPath)]
        defer { holders.forEach { $0.close() } }

        // Accepted after both holders, so it finds the cap full.
        let refused = try await SocketClient.roundTrip(
            #"{"command":"stats","arguments":{}}"#,
            path: fixture.socketPath
        )
        #expect(refused.contains(#""ok":false"#), "a client past the cap was served: \(refused)")
        #expect(refused.contains("limit of 2 clients"), "unexpected refusal: \(refused)")

        for holder in holders {
            let answered = try await holder.finish(#"{"command":"stats","arguments":{}}"#)
            #expect(answered.contains(#""ok":true"#), "a holder was not served: \(answered)")
        }
        // A slot frees just after its response is written, so a client right
        // behind it may still be refused once.
        let served = try await fixture.roundTripUntilAdmitted(#"{"command":"stats","arguments":{}}"#)
        #expect(served.contains(#""ok":true"#), "freed slots did not serve again: \(served)")
    }

    /// A client that closes before its response must not kill the daemon:
    /// the write fails with EPIPE, and the next client is served.
    @Test(.timeLimit(.minutes(2)))
    func daemonSocketModeSurvivesAClientThatLeavesBeforeItsResponse() async throws {
        let fixture = try DaemonFixture()
        defer { fixture.remove() }
        let daemon = try fixture.launch(
            arguments: ["--socket-path", fixture.socketPath],
            environment: fixture.holdEnvironment(command: "stats")
        )
        defer { daemon.forceStop() }
        try await fixture.waitForSocket(daemon)

        let leaver = try SocketClient(path: fixture.socketPath)
        try leaver.send(#"{"command":"stats","arguments":{}}"# + "\n")
        try await fixture.waitForMarker("held", daemon: daemon)
        leaver.close()
        try fixture.releaseHeldCommand()
        try await fixture.waitForMarker("responded", daemon: daemon)

        #expect(daemon.process.isRunning, "the daemon died writing to a client that had left")
        let stats = try await SocketClient.roundTrip(
            #"{"command":"stats","arguments":{}}"#,
            path: fixture.socketPath
        )
        #expect(stats.contains(#""ok":true"#), "the next client was not served: \(stats)")
    }

    /// SIGTERM while a command is in the service: that command finishes and is
    /// answered, a request arriving during the drain is refused with a
    /// response, and the daemon then closes the store and exits 0.
    ///
    /// The command is held inside the service, so closing waits for it however
    /// long the test takes to send the late request, and the late client's read
    /// deadline is long for the same reason.
    @Test(.timeLimit(.minutes(2)))
    func daemonDrainAnswersTheInFlightCommandAndRefusesNewOnes() async throws {
        let fixture = try DaemonFixture()
        defer { fixture.remove() }
        let daemon = try fixture.launch(
            arguments: ["--socket-path", fixture.socketPath],
            environment: fixture.holdEnvironment(command: "stats", inService: true)
                .merging(DaemonFixture.longReadDeadline) { _, new in new }
        )
        defer { daemon.forceStop() }
        try await fixture.waitForSocket(daemon)

        let inFlight = try SocketClient(path: fixture.socketPath)
        defer { inFlight.close() }
        try inFlight.send(#"{"command":"stats","arguments":{}}"# + "\n")
        try await fixture.waitForMarker("held", daemon: daemon)

        // Accepted before SIGTERM (connections are accepted in order, and the
        // remember after it is answered), but it sends only once draining.
        let late = try SocketClient(path: fixture.socketPath)
        defer { late.close() }
        let remembered = try await SocketClient.roundTrip(
            #"{"command":"remember","arguments":{"content":"\#(fixture.token) before SIGTERM"}}"#,
            path: fixture.socketPath
        )
        #expect(remembered.contains(#""ok":true"#), "remember failed: \(remembered)")

        kill(daemon.pid, SIGTERM)
        try await fixture.waitForMarker("draining", daemon: daemon)
        let refused = try await late.finish(
            #"{"command":"remember","arguments":{"content":"sent during the drain"}}"#
        )
        #expect(refused.contains(#""ok":false"#), "a request sent during the drain was served: \(refused)")
        #expect(refused.contains("shutting down"), "unexpected refusal: \(refused)")

        try fixture.releaseHeldCommand()
        let fd = inFlight.fd
        let answered = try await BlockingWork.run { try readLine(fd: fd) }
        #expect(answered.contains(#""ok":true"#), "the in-flight command was not answered: \(answered)")

        let exit = try await daemon.waitForExit(since: Date())
        #expect(exit.reason == .exit && exit.status == 0, "daemon exited with \(exit)")
        #expect(!FileManager.default.fileExists(atPath: fixture.socketPath), "socket was not removed")
        try await fixture.expectStoreReleasedAndCommitted()
    }

    /// A command still running when the drain bound passes must not keep the
    /// store open: the daemon closes it and exits within the grace anyway.
    @Test(.timeLimit(.minutes(2)))
    func daemonClosesTheStoreWhenACommandOutlastsTheDrainBound() async throws {
        let fixture = try DaemonFixture()
        defer { fixture.remove() }
        let daemon = try fixture.launch(
            arguments: ["--socket-path", fixture.socketPath],
            environment: fixture.holdEnvironment(command: "stats")
        )
        defer { daemon.forceStop() }
        try await fixture.waitForSocket(daemon)

        let remembered = try await SocketClient.roundTrip(
            #"{"command":"remember","arguments":{"content":"\#(fixture.token) before SIGTERM"}}"#,
            path: fixture.socketPath
        )
        #expect(remembered.contains(#""ok":true"#), "remember failed: \(remembered)")

        // Held for good: the test never releases it.
        let stuck = try SocketClient(path: fixture.socketPath)
        defer { stuck.close() }
        try stuck.send(#"{"command":"stats","arguments":{}}"# + "\n")
        try await fixture.waitForMarker("held", daemon: daemon)

        let killedAt = Date()
        kill(daemon.pid, SIGTERM)
        let exit = try await daemon.waitForExit(since: killedAt)

        #expect(exit.reason == .exit && exit.status == 0, "daemon exited with \(exit)")
        #expect(
            exit.elapsed < Self.clientTerminateGraceSeconds,
            "daemon took \(exit) from SIGTERM, past the client's SIGTERM grace; \(fixture.shutdownTimeline(since: killedAt))"
        )
        #expect(!FileManager.default.fileExists(atPath: fixture.socketPath), "socket was not removed")
        try await fixture.expectStoreReleasedAndCommitted()
    }

    /// A command already running inside the service holds the store's locks.
    /// The 1s drain does not bound it: closing waits for it, its response is
    /// still delivered, and only then does the daemon exit 0.
    @Test(.timeLimit(.minutes(2)))
    func daemonShutdownWaitsForARunningCommandAndDeliversItsResponse() async throws {
        let fixture = try DaemonFixture()
        defer { fixture.remove() }
        let daemon = try fixture.launch(
            arguments: ["--socket-path", fixture.socketPath],
            environment: fixture.holdEnvironment(command: "stats", inService: true)
        )
        defer { daemon.forceStop() }
        try await fixture.waitForSocket(daemon)

        let remembered = try await SocketClient.roundTrip(
            #"{"command":"remember","arguments":{"content":"\#(fixture.token) before SIGTERM"}}"#,
            path: fixture.socketPath
        )
        #expect(remembered.contains(#""ok":true"#), "remember failed: \(remembered)")

        let running = try SocketClient(path: fixture.socketPath)
        defer { running.close() }
        try running.send(#"{"command":"stats","arguments":{}}"# + "\n")
        try await fixture.waitForMarker("held", daemon: daemon)

        kill(daemon.pid, SIGTERM)
        // Past the drain bound: the store is closing, behind the running command.
        try await fixture.waitForMarker("closing", daemon: daemon)
        #expect(daemon.process.isRunning, "the daemon exited under a running command")

        try fixture.releaseHeldCommand()
        let fd = running.fd
        let answered = try await BlockingWork.run { try readLine(fd: fd) }
        #expect(answered.contains(#""ok":true"#), "the running command was not answered: \(answered)")

        let exit = try await daemon.waitForExit(since: Date())
        #expect(exit.reason == .exit && exit.status == 0, "daemon exited with \(exit)")
        #expect(!FileManager.default.fileExists(atPath: fixture.socketPath), "socket was not removed")
        try await fixture.expectStoreReleasedAndCommitted()
    }

    /// While a running command holds graceful shutdown, a second signal exits
    /// at once instead of waiting for it.
    @Test(.timeLimit(.minutes(2)))
    func daemonSecondSignalForcesExitWhileACommandHoldsShutdown() async throws {
        let fixture = try DaemonFixture()
        defer { fixture.remove() }
        let daemon = try fixture.launch(
            arguments: ["--socket-path", fixture.socketPath],
            environment: fixture.holdEnvironment(command: "stats", inService: true)
        )
        defer { daemon.forceStop() }
        try await fixture.waitForSocket(daemon)

        let running = try SocketClient(path: fixture.socketPath)
        defer { running.close() }
        try running.send(#"{"command":"stats","arguments":{}}"# + "\n")
        try await fixture.waitForMarker("held", daemon: daemon)
        kill(daemon.pid, SIGTERM)
        try await fixture.waitForMarker("closing", daemon: daemon)

        let secondSignalAt = Date()
        kill(daemon.pid, SIGTERM)
        let exit = try await daemon.waitForExit(since: secondSignalAt)
        #expect(
            exit.reason == .exit && exit.status == 128 + SIGTERM,
            "a second SIGTERM did not force the exit: \(exit)"
        )
        #expect(
            exit.elapsed < Self.clientTerminateGraceSeconds,
            "daemon took \(exit) after the second SIGTERM; \(fixture.shutdownTimeline(since: secondSignalAt))"
        )
    }

    /// Each client still sending its request holds a GCD worker thread while
    /// its read waits. Enough of them fill the worker pool, which can stall
    /// closing the store. The first SIGTERM must still start shutdown, and a
    /// second must still force the exit. This checks the behaviour only. It
    /// also passes with the signal handler on `.global()`, so it does not show
    /// that `ShutdownSignals.handlerQueue` is needed.
    @Test(.timeLimit(.minutes(3)))
    func daemonHandlesSignalsWhileWaitingClientsFillTheWorkerPool() async throws {
        let workers = try constrainedWorkerThreadLimit()
        let fixture = try DaemonFixture()
        defer { fixture.remove() }
        let daemon = try fixture.launch(
            arguments: ["--socket-path", fixture.socketPath, "--max-clients", String(workers + 16)],
            environment: DaemonFixture.longReadDeadline
        )
        defer { daemon.forceStop() }
        try await fixture.waitForSocket(daemon)

        var waiting: [SocketClient] = []
        defer { waiting.forEach { $0.close() } }
        for _ in 0..<(workers + 8) {
            waiting.append(try await SocketClient.connectWhenBacklogAllows(path: fixture.socketPath))
        }

        kill(daemon.pid, SIGTERM)
        try await fixture.waitForMarker("closing", daemon: daemon)

        // Closing may itself wait for a worker thread; the second signal must not.
        let secondSignalAt = Date()
        if daemon.process.isRunning {
            kill(daemon.pid, SIGTERM)
        }
        let exit = try await daemon.waitForExit(since: secondSignalAt)
        #expect(
            exit.reason == .exit && [0, 128 + SIGTERM].contains(exit.status),
            "the daemon did not shut down on SIGTERM: \(exit)"
        )
        #expect(
            exit.elapsed < Self.clientTerminateGraceSeconds,
            "daemon took \(exit) after the second SIGTERM; \(fixture.shutdownTimeline(since: secondSignalAt))"
        )
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
        let killedAt = Date()
        kill(daemon.pid, SIGTERM)

        let exit = try await daemon.waitForExit(since: killedAt)
        #expect(exit.reason == .exit && exit.status == 0, "daemon exited with \(exit)")
        #expect(
            exit.elapsed < Self.clientTerminateGraceSeconds,
            "daemon took \(exit) from SIGTERM, past the client's SIGTERM grace; \(fixture.shutdownTimeline(since: killedAt))"
        )
        try await fixture.expectStoreReleasedAndCommitted()
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
        try FileManager.default.createDirectory(at: hooksDirectory, withIntermediateDirectories: true)
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
        let hooks = ["WAX_BROKER_TEST_HOOKS_DIR": hooksDirectory.path]
        process.environment = ProcessInfo.processInfo.environment
            .merging(hooks) { _, new in new }
            .merging(environment) { _, new in new }
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdio ? stdin : FileHandle.nullDevice
        process.standardOutput = stdio ? stdout : FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return try DaemonProcess(process: process, stdin: stdin, stdout: stdout)
    }

    /// Waits until the daemon accepts connections. The socket file appears at
    /// bind, before listen, and a probe connection would take a client slot, so
    /// this waits for the daemon's `listening` marker.
    func waitForSocket(_ daemon: DaemonProcess) async throws {
        try await waitForMarker("listening", daemon: daemon)
    }

    var hooksDirectory: URL { root.appendingPathComponent("hooks", isDirectory: true) }

    /// Environment for `DaemonTestHooks`: holds `command` until released, once
    /// admitted or, with `inService`, inside the service's locks.
    func holdEnvironment(command: String, inService: Bool = false) -> [String: String] {
        [
            "WAX_BROKER_TEST_HOLD_COMMAND": command,
            "WAX_BROKER_TEST_HOLD_POINT": inService ? "service" : "admitted",
        ]
    }

    func releaseHeldCommand() throws {
        let release = hooksDirectory.appendingPathComponent("release").path
        guard FileManager.default.createFile(atPath: release, contents: nil) else {
            throw DaemonTestError("could not create \(release)")
        }
    }

    /// Waits for a hook marker. Fails at once if the daemon exits first; the
    /// 60s bound only catches a hang.
    func waitForMarker(_ name: String, daemon: DaemonProcess) async throws {
        let marker = hooksDirectory.appendingPathComponent(name).path
        let deadline = Date().addingTimeInterval(60)
        while !FileManager.default.fileExists(atPath: marker) {
            guard daemon.process.isRunning else {
                throw DaemonTestError("daemon exited (\(daemon.process.terminationStatus)) before \(name)")
            }
            guard Date() < deadline else { throw DaemonTestError("daemon never wrote \(name)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// The lock is free and a fresh process reopens the store and finds the data.
    /// The recall runs off the cooperative pool.
    func expectStoreReleasedAndCommitted() async throws {
        let lock = try FileLock.tryAcquire(at: storeURL, mode: .exclusive)
        #expect(lock != nil, "the daemon left the store locked")
        try lock?.release()

        let executable = URL(fileURLWithPath: try builtProductPath(named: "wax-cli"))
        let arguments = [
            "recall", "--direct-store", "--store-path", storeURL.path,
            "--no-embedder", "--format", "json", token,
        ]
        let (status, text) = try await BlockingWork.run { () throws -> (Int32?, String) in
            let recall = Process()
            recall.executableURL = executable
            recall.arguments = arguments
            let output = Pipe()
            recall.standardOutput = output
            recall.standardError = FileHandle.nullDevice
            try recall.run()
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return (recall.waitForExit(timeout: 120), text)
        }
        #expect(status == 0, "reopening the store failed: \(text)")
        #expect(text.contains(token), "committed memory missing after shutdown: \(text)")
    }

    /// When the daemon reached each shutdown marker, in seconds after `start`,
    /// so a slow exit shows where its time went.
    func shutdownTimeline(since start: Date) -> String {
        let stages = ["signalled", "draining", "closing", "closed"].map { name -> String in
            let path = hooksDirectory.appendingPathComponent(name).path
            guard let data = FileManager.default.contents(atPath: path),
                  let time = Double(String(decoding: data, as: UTF8.self)) else {
                return "\(name) -"
            }
            return "\(name) +\(String(format: "%.3f", time - start.timeIntervalSince1970))s"
        }
        return stages.joined(separator: ", ")
    }

    /// Sends `line` until it is not refused for the client cap. The 30s bound
    /// only catches a slot that never frees.
    func roundTripUntilAdmitted(_ line: String) async throws -> String {
        let deadline = Date().addingTimeInterval(30)
        while true {
            let response = try await SocketClient.roundTrip(line, path: socketPath)
            guard response.contains("clients; retry shortly"), Date() < deadline else { return response }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Gives each client this long to send its request, instead of 5s, so a
    /// client the test is still holding is not cut off while the test waits.
    static let longReadDeadline = ["WAX_BROKER_TEST_READ_DEADLINE_SECS": "120"]
}

private struct DaemonExit: CustomStringConvertible {
    let reason: Process.TerminationReason
    let status: Int32
    /// Seconds from the signal to the exit, timed when the process ended.
    let elapsed: TimeInterval
    /// Seconds from the signal until this test saw the exit. On a starved
    /// cooperative pool this lags `elapsed` by however long the await took to
    /// resume, which says nothing about the daemon.
    let observedAfter: TimeInterval

    var description: String {
        "\(reason == .exit ? "exit" : "signal") \(status) after \(elapsed)s (seen after \(observedAfter)s)"
    }
}

private final class DaemonProcess: @unchecked Sendable {
    let process: Process
    let stdin: Pipe
    let stdout: Pipe
    private let exited = DispatchSemaphore(value: 0)
    private let exitClock = ExitClock()

    init(process: Process, stdin: Pipe, stdout: Pipe) throws {
        self.process = process
        self.stdin = stdin
        self.stdout = stdout
        let exited = exited
        let exitClock = exitClock
        // Foundation calls this on its own queue as it reaps the child, so the
        // time does not depend on when the test's tasks next get a thread.
        process.terminationHandler = { _ in
            exitClock.stop()
            exited.signal()
        }
        try process.run()
    }

    var pid: pid_t { process.processIdentifier }

    /// Waits off the cooperative pool. `start` is when the signal was sent, so
    /// the elapsed time covers everything the daemon did after it. The 60s
    /// bound only catches a hang.
    func waitForExit(since start: Date) async throws -> DaemonExit {
        let exited = exited
        let didExit = await BlockingWork.run { exited.wait(timeout: .now() + 60) == .success }
        guard didExit, let exitedAt = exitClock.stoppedAt else {
            throw DaemonTestError("daemon \(pid) did not exit after SIGTERM")
        }
        return DaemonExit(
            reason: process.terminationReason,
            status: process.terminationStatus,
            elapsed: exitedAt.timeIntervalSince(start),
            observedAfter: Date().timeIntervalSince(start)
        )
    }

    func stdioRoundTrip(_ line: String) async throws -> String {
        stdin.fileHandleForWriting.write(Data((line + "\n").utf8))
        let fd = stdout.fileHandleForReading.fileDescriptor
        return try await BlockingWork.run { try readLine(fd: fd) }
    }

    /// Bounded, so a lost exit notification cannot hang the test's teardown.
    func forceStop() {
        if process.isRunning {
            kill(pid, SIGKILL)
            process.waitForExit(timeout: 10)
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
            let reason = String(cString: strerror(errno))
            Darwin.close(fd)
            throw DaemonTestError("connect to \(path) failed: \(reason)")
        }
    }

    func close() {
        Darwin.close(fd)
    }

    func send(_ text: String) throws {
        let bytes = Array(text.utf8)
        let sent = write(fd, bytes, bytes.count)
        guard sent == bytes.count else {
            let reason = sent < 0 ? String(cString: strerror(errno)) : "short write of \(sent) bytes"
            throw DaemonTestError("socket write failed: \(reason)")
        }
    }

    /// Writes a space on a GCD thread at the given interval until stopped.
    func startTrickle(everyMicroseconds interval: useconds_t) -> Trickle {
        let trickle = Trickle()
        let fd = fd
        // Its own serial queue, not `.global()`: GCD runs `.global()` work only as fast as the
        // cores allow, so on a busy 3-core runner the loop could wait past the test's
        // 2-minute limit to start, and `stop()` waited for it to finish.
        DispatchQueue(label: "com.wax.tests.trickle").async {
            while !trickle.isStopped {
                _ = write(fd, " ", 1)
                usleep(interval)
            }
            trickle.markDone()
        }
        return trickle
    }

    /// Sends the request and reads the response line. A daemon that refuses a
    /// client may answer and close before reading the request, so a write the
    /// peer has closed (EPIPE) still reads what the daemon sent.
    func finish(_ line: String) async throws -> String {
        let bytes = Array((line + "\n").utf8)
        if write(fd, bytes, bytes.count) != bytes.count, errno != EPIPE {
            throw DaemonTestError("socket write failed: \(String(cString: strerror(errno)))")
        }
        shutdown(fd, SHUT_WR)
        let fd = fd
        return try await BlockingWork.run { try readLine(fd: fd) }
    }

    /// Connects, retrying while the daemon's listen backlog is full. The 30s
    /// bound only catches an accept loop that stopped.
    static func connectWhenBacklogAllows(path: String) async throws -> SocketClient {
        let deadline = Date().addingTimeInterval(30)
        while true {
            do {
                return try SocketClient(path: path)
            } catch where Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    static func roundTrip(_ line: String, path: String) async throws -> String {
        let client = try SocketClient(path: path)
        defer { client.close() }
        return try await client.finish(line)
    }
}

/// When the daemon process ended.
private final class ExitClock: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped: Date?

    func stop() {
        lock.withLock { stopped = Date() }
    }

    var stoppedAt: Date? {
        lock.withLock { stopped }
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

/// How many worker threads GCD runs at once for its non-overcommit queues,
/// such as `.global()` and the queues that target it.
private func constrainedWorkerThreadLimit() throws -> Int {
    var limit: UInt32 = 0
    var size = MemoryLayout<UInt32>.size
    guard sysctlbyname("kern.wq_max_constrained_threads", &limit, &size, nil, 0) == 0, limit > 0 else {
        throw DaemonTestError("could not read kern.wq_max_constrained_threads")
    }
    return Int(limit)
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
