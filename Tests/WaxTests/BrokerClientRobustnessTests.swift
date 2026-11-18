import Foundation
import Testing
@testable import Wax
import WaxCore
#if canImport(Darwin)
import Darwin
#endif

@Suite struct BrokerClientRobustnessTests {
    private static let envKey = "WAX_TEST_BROKER_SECS"

    /// `Double("inf")` parses, so an infinite or NaN timeout must fall back
    /// to the default like any other unusable value.
    @Test(arguments: ["inf", "+inf", "-inf", "infinity", "nan", "NaN", "0", "-1", "", "  ", "abc"])
    func configuredSecondsRejectsUnusableValues(raw: String) {
        let seconds = AgentBrokerClient.configuredSeconds(
            envKey: Self.envKey,
            defaultValue: 7,
            environment: [Self.envKey: raw]
        )
        #expect(seconds == 7)
    }

    /// A startup timeout says how long it waited and whether the broker was alive, so a
    /// slow host reads differently from a broker that crashed.
    @Test func startupTimeoutMessageSaysHowLongAndWhetherTheBrokerWasRunning() {
        let slow = AgentBrokerClient.startupTimeoutMessage(
            waited: .milliseconds(10_040),
            pid: 4242,
            runningAtDeadline: true,
            stderr: nil
        )
        #expect(slow == "Timed out waiting for broker startup after 10.0s (broker 4242 was running but never answered its socket).")

        let exited = AgentBrokerClient.startupTimeoutMessage(
            waited: .seconds(3),
            pid: 7,
            runningAtDeadline: false,
            stderr: "  lock held by another process\n"
        )
        #expect(exited == "Timed out waiting for broker startup after 3.0s (broker 7 had exited). stderr: lock held by another process")
    }

    @Test func configuredSecondsAcceptsPositiveFiniteValues() {
        let configured = AgentBrokerClient.configuredSeconds(
            envKey: Self.envKey,
            defaultValue: 7,
            environment: [Self.envKey: " 2.5 "]
        )
        let missing = AgentBrokerClient.configuredSeconds(
            envKey: Self.envKey,
            defaultValue: 7,
            environment: [:]
        )
        #expect(configured == 2.5)
        #expect(missing == 7)
    }

    #if os(macOS)
    /// A cancelled start must give the launched broker its SIGTERM grace. The
    /// child needs a moment to shut down cleanly, and writes its marker only
    /// if it is not SIGKILLed first.
    @Test(.timeLimit(.minutes(2)))
    func cancelledBrokerStartLetsTheBrokerExitOnSIGTERM() async throws {
        let fixture = try BrokerProcessFixture()
        defer { fixture.remove() }
        let marker = fixture.root.appendingPathComponent("clean-exit")
        let broker = try fixture.writeBroker(named: "cooperative-broker", script: """
        #!/bin/sh
        trap 'sleep 0.2; echo clean > "\(marker.path)"; exit 0' TERM
        echo ready > "\(fixture.readyMarker.path)"
        while :; do sleep 0.05; done
        """)

        let pid = try await fixture.cancelStartOnceReady(broker: broker)

        #expect(
            FileManager.default.fileExists(atPath: marker.path),
            "launched broker \(pid) was SIGKILLed before its SIGTERM shutdown finished"
        )
        #expect(!fixture.isAlive(pid), "launched broker \(pid) survived a cancelled start")
    }

    /// The grace is bounded: a broker that ignores SIGTERM is SIGKILLed.
    @Test(.timeLimit(.minutes(2)))
    func cancelledBrokerStartKillsABrokerThatIgnoresSIGTERM() async throws {
        let fixture = try BrokerProcessFixture()
        defer { fixture.remove() }
        let broker = try fixture.writeBroker(named: "stubborn-broker", script: """
        #!/bin/sh
        trap '' TERM
        echo ready > "\(fixture.readyMarker.path)"
        while :; do sleep 0.05; done
        """)

        let pid = try await fixture.cancelStartOnceReady(broker: broker)

        #expect(!fixture.isAlive(pid), "launched broker \(pid) survived a cancelled start")
    }

    // The tests below run the call on a one-thread FIFO executor with a sibling
    // task queued behind it. The sibling runs before the call returns only if
    // the call suspends, which a blocking call made inline never does. The
    // order is the proof; nothing here depends on timing.

    @Test func socketLivenessProbeDoesNotHoldTheCallersThread() async throws {
        guard #available(macOS 15.0, *) else { return }
        let fixture = try BrokerProcessFixture()
        defer { fixture.remove() }
        let listener = try fixture.listen(at: fixture.socketPath)
        defer { close(listener) }
        let socketPath = fixture.socketPath

        let (events, live) = await OneThreadExecutor.eventsAround {
            await AgentBrokerClient.isSocketLiveOffPool(socketPath: socketPath)
        }

        #expect(live)
        #expect(events == ["call-start", "sibling", "call-end"])
    }

    @Test func ownedBrokerPeerLookupDoesNotHoldTheCallersThread() async throws {
        guard #available(macOS 15.0, *) else { return }
        let fixture = try BrokerProcessFixture()
        defer { fixture.remove() }
        let listener = try fixture.listen(at: fixture.socketPath)
        defer { close(listener) }
        let socketPath = fixture.socketPath

        let (events, pid) = await OneThreadExecutor.eventsAround {
            await AgentBrokerClient.ownedBrokerPeerPIDOffPool(socketPath: socketPath)
        }

        // The listener is this test process, not wax-cli, so it is left alone.
        #expect(pid == nil)
        #expect(events == ["call-start", "sibling", "call-end"])
    }

    /// The store lock probe waits up to 50ms while the lock is held.
    @Test func shutdownCompletionProbeDoesNotHoldTheCallersThread() async throws {
        guard #available(macOS 15.0, *) else { return }
        let fixture = try BrokerProcessFixture()
        defer { fixture.remove() }
        let store = fixture.root.appendingPathComponent("store.wax")
        try Data("store".utf8).write(to: store)
        let held = try FileLock.acquire(at: store, mode: .exclusive, timeout: .seconds(5))
        defer { try? held.release() }
        let socketPath = fixture.socketPath

        let (events, completed) = await OneThreadExecutor.eventsAround {
            (try? await AgentBrokerClient.brokerShutdownCompletedOffPool(
                socketPath: socketPath,
                storePath: store.path
            )) ?? true
        }

        #expect(!completed, "a held store lock means shutdown is not complete")
        #expect(events == ["call-start", "sibling", "call-end"])
    }
    #endif
}

#if os(macOS)
private struct BrokerProcessFixture {
    let root: URL

    init() throws {
        // Short path: Unix socket paths are limited to about 104 bytes.
        root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("wxbr-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    var socketPath: String { root.appendingPathComponent("broker.sock").path }

    /// A broker script writes this once its SIGTERM trap is installed.
    var readyMarker: URL { root.appendingPathComponent("ready") }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func writeBroker(named name: String, script: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func isAlive(_ pid: pid_t) -> Bool {
        let alive = kill(pid, 0) == 0
        if alive {
            kill(pid, SIGKILL)
        }
        return alive
    }

    /// Starts `broker`, cancels the start once the broker has written
    /// ``readyMarker``, and returns the launched pid after the cancelled start
    /// has returned. Cancelling earlier would signal the shell before it
    /// installs its trap.
    func cancelStartOnceReady(broker: URL) async throws -> pid_t {
        let configuration = AgentBrokerConfiguration(
            brokerExecutablePath: broker.path,
            storePath: root.appendingPathComponent("store.wax").path,
            sessionRootPath: root.appendingPathComponent("sessions").path,
            socketPath: socketPath,
            embedderChoice: "minilm",
            noEmbedder: true,
            requireVector: false,
            embedderTuning: .fromEnvironment()
        )
        // The launch hook is the handshake, so there is no deadline to race.
        let (launches, launched) = AsyncStream.makeStream(of: pid_t.self)
        let start = Task {
            defer { launched.finish() }
            return try await AgentBrokerClient.ensureAvailable(
                configuration: configuration,
                // Far past any scheduler stall, so the start ends by cancellation.
                startTimeoutSecondsOverride: 600,
                onBrokerLaunched: { launched.yield($0) }
            )
        }
        guard let pid = await launches.first(where: { _ in true }) else {
            _ = try await start.value
            throw BrokerFixtureError("ensureAvailable returned without launching a broker")
        }
        // The test's time limit bounds this wait.
        while !FileManager.default.fileExists(atPath: readyMarker.path) {
            guard kill(pid, 0) == 0 else {
                start.cancel()
                throw BrokerFixtureError("launched broker \(pid) exited before it was ready")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        start.cancel()
        await #expect(throws: CancellationError.self) { try await start.value }
        return pid
    }

    func listen(at path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BrokerFixtureError("socket failed") }
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
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 8) == 0 else {
            close(fd)
            throw BrokerFixtureError("bind/listen failed at \(path)")
        }
        return fd
    }
}

private struct BrokerFixtureError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// A task executor with one thread that runs jobs in the order they arrive.
@available(macOS 15.0, *)
private final class OneThreadExecutor: TaskExecutor, @unchecked Sendable {
    private let condition = NSCondition()
    private var jobs: [UnownedJob] = []
    private var stopped = false

    init() {
        Thread { [self] in runJobs() }.start()
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        condition.lock()
        jobs.append(job)
        condition.signal()
        condition.unlock()
    }

    func stop() {
        condition.lock()
        stopped = true
        condition.signal()
        condition.unlock()
    }

    private func runJobs() {
        while true {
            condition.lock()
            while jobs.isEmpty, !stopped {
                condition.wait()
            }
            guard !jobs.isEmpty else {
                condition.unlock()
                return
            }
            let job = jobs.removeFirst()
            condition.unlock()
            job.runSynchronously(on: asUnownedTaskExecutor())
        }
    }

    /// Runs `call` on a fresh one-thread executor with a sibling task queued
    /// behind it, and returns the order of the call's start, the sibling, and
    /// the call's end.
    static func eventsAround<T: Sendable>(
        _ call: @escaping @Sendable () async -> T
    ) async -> ([String], T) {
        let executor = OneThreadExecutor()
        defer { executor.stop() }
        let log = EventLog()
        let result = await withTaskExecutorPreference(executor) {
            let sibling = Task(executorPreference: executor) { log.append("sibling") }
            log.append("call-start")
            let result = await call()
            log.append("call-end")
            await sibling.value
            return result
        }
        return (log.events, result)
    }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    func append(_ event: String) {
        lock.lock()
        recorded.append(event)
        lock.unlock()
    }

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}
#endif
