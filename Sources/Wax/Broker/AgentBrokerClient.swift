import Foundation
import WaxCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

package enum AgentBrokerClient {
    #if canImport(Darwin)
    private static let unixStreamSocketType: Int32 = SOCK_STREAM
    private static let socketShutdownWrite: Int32 = SHUT_WR
    #elseif canImport(Glibc)
    private static let unixStreamSocketType: Int32 = Int32(SOCK_STREAM.rawValue)
    private static let socketShutdownWrite: Int32 = Int32(SHUT_WR)
    #endif

    private static var startTimeoutSeconds: TimeInterval {
        configuredSeconds(
            envKey: "WAX_BROKER_START_TIMEOUT_SECS",
            defaultValue: 10.0
        )
    }

    private static let idleTimeoutSeconds = configuredSeconds(
        envKey: "WAX_BROKER_IDLE_TIMEOUT_SECS",
        defaultValue: 300.0
    )

    private static let shutdownTimeoutSeconds = configuredSeconds(
        envKey: "WAX_BROKER_SHUTDOWN_TIMEOUT_SECS",
        defaultValue: 2.0
    )
    /// Defaults past the broker's embedder wait so a slow-but-successful
    /// remember is not reported as a client timeout.
    package static let responseTimeoutSeconds = configuredSeconds(
        envKey: "WAX_BROKER_RESPONSE_TIMEOUT_SECS",
        defaultValue: BrokerLimits.defaultClientResponseTimeoutSeconds
    )
    private static let pollInterval: Duration = .milliseconds(50)
    private static let maxSocketResponseBytes = 1_048_576

    /// Silence window after our spawned peer exits before startup fails.
    /// A bind-race winner answers within milliseconds; anything longer
    /// means no broker will ever serve this socket.
    private static let peerExitGrace: Duration = .seconds(1)

    /// How long a cancelled or failed start lets the launched broker exit on SIGTERM
    /// before it is SIGKILLed, so a broker mid-write can close its store cleanly.
    private static let terminateGraceSeconds: TimeInterval = 2.0

    /// Upper bound on waiting for a SIGKILLed broker to be reaped. A child stuck in
    /// uninterruptible I/O cannot die until that I/O ends, so the wait must not be open-ended.
    private static let reapTimeoutSeconds: TimeInterval = 5.0

    private static func isLockContention(_ stderr: String) -> Bool {
        let lowered = stderr.lowercased()
        return lowered.contains("lock unavailable") || lowered.contains("exclusive lock")
    }

    package static func perform(
        request: AgentBrokerRequest,
        configuration: AgentBrokerConfiguration,
        shutdownIfStarted: Bool = false
    ) async throws -> AgentBrokerResponse {
        let startedBroker = try await ensureAvailable(configuration: configuration)
        do {
            guard let response = try await sendOffPool(request, socketPath: configuration.socketPath) else {
                throw BrokerClientError("Broker did not respond after startup.")
            }
            if shutdownIfStarted, startedBroker, request.command != "shutdown" {
                try await shutdownStartedBroker(configuration: configuration)
            }
            return response
        } catch {
            if shutdownIfStarted, startedBroker, request.command != "shutdown" {
                try? await shutdownStartedBroker(configuration: configuration)
            }
            throw error
        }
    }

    /// Probe an already-running broker. Never starts a process or a second writer.
    package static func probe(
        request: AgentBrokerRequest,
        configuration: AgentBrokerConfiguration,
        timeoutSeconds: TimeInterval = 1.5
    ) throws -> AgentBrokerResponse? {
        try sendIfAvailable(
            request,
            socketPath: configuration.socketPath,
            timeoutSeconds: timeoutSeconds,
            treatTimeoutAsUnavailable: true
        )
    }

    /// ``probe(request:configuration:timeoutSeconds:)`` for async callers: the
    /// round trip runs off the cooperative pool.
    package static func probeOffPool(
        request: AgentBrokerRequest,
        configuration: AgentBrokerConfiguration,
        timeoutSeconds: TimeInterval = 1.5
    ) async throws -> AgentBrokerResponse? {
        try await sendOffPool(
            request,
            socketPath: configuration.socketPath,
            timeoutSeconds: timeoutSeconds,
            treatTimeoutAsUnavailable: true
        )
    }

    package static func ping(configuration: AgentBrokerConfiguration) async throws -> AgentBrokerResponse {
        let _ = try await ensureAvailable(configuration: configuration)
        guard let response = try await sendOffPool(
            AgentBrokerRequest(id: "__ping__", command: "stats"),
            socketPath: configuration.socketPath
        ) else {
            throw BrokerClientError("Broker did not respond after startup.")
        }
        return response
    }

    /// Synchronous on purpose: callers run it from `defer`, which cannot
    /// await. Async paths use ``shutdownStartedBroker(configuration:)``.
    package static func shutdownOwnedBrokerIfReachable(
        configuration: AgentBrokerConfiguration
    ) throws {
        guard try requestShutdown(configuration: configuration) else { return }
        let deadline = ContinuousClock.Instant.deadline(afterSeconds: shutdownTimeoutSeconds)
        while ContinuousClock.now < deadline {
            if try brokerShutdownCompleted(
                socketPath: configuration.socketPath,
                storePath: configuration.storePath
            ) {
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    /// - Parameter onBrokerLaunched: Called with the child's pid right after this call
    ///   launches a broker process. Not called when a running broker is reused.
    package static func ensureAvailable(
        configuration: AgentBrokerConfiguration,
        startTimeoutSecondsOverride: TimeInterval? = nil,
        onBrokerLaunched: (@Sendable (pid_t) -> Void)? = nil
    ) async throws -> Bool {
        let pingTimeout = min(5.0, responseTimeoutSeconds)
        if let response = try await sendOffPool(
            AgentBrokerRequest(id: "__ping__", command: "stats"),
            socketPath: configuration.socketPath,
            timeoutSeconds: pingTimeout,
            treatTimeoutAsUnavailable: true
        ), response.ok {
            return false
        }

        if await isSocketLiveOffPool(socketPath: configuration.socketPath) {
            if let response = try await sendOffPool(
                AgentBrokerRequest(id: "__ping__", command: "stats"),
                socketPath: configuration.socketPath,
                timeoutSeconds: pingTimeout,
                treatTimeoutAsUnavailable: true
            ), response.ok {
                return false
            }
            if try await restartMuteOwnedBroker(configuration: configuration) {
                return try await startBrokerIfNeeded(
                    configuration: configuration,
                    timeoutSeconds: startTimeoutSecondsOverride ?? startTimeoutSeconds,
                    onBrokerLaunched: onBrokerLaunched
                )
            }
            throw BrokerUnresponsiveError(
                "Broker socket is live at \(configuration.socketPath) but did not answer (socket_live=true answered=false committed=false). Not starting a second daemon. Restart wax-mcp or `launchctl kickstart -k gui/$(id -u)/ai.wax.mcp-http`, then session_open with conversation_id. Do not invent a session_id."
            )
        }

        return try await startBrokerIfNeeded(
            configuration: configuration,
            timeoutSeconds: startTimeoutSecondsOverride ?? startTimeoutSeconds,
            onBrokerLaunched: onBrokerLaunched
        )
    }

    private static func startBrokerIfNeeded(
        configuration: AgentBrokerConfiguration,
        timeoutSeconds: TimeInterval,
        onBrokerLaunched: (@Sendable (pid_t) -> Void)?
    ) async throws -> Bool {
        #if os(iOS) || os(tvOS) || os(watchOS)
        throw BrokerClientError("Starting a broker process is not supported on this platform.")
        #else
        guard FileManager.default.isExecutableFile(atPath: configuration.brokerExecutablePath) else {
            throw BrokerClientError(
                "Broker executable is not executable at \(configuration.brokerExecutablePath)"
            )
        }

        let process = ChildProcess()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            configuration.brokerExecutablePath,
            "daemon",
            "--store-path", configuration.storePath,
            "--session-root", configuration.sessionRootPath,
            "--embedder", configuration.embedderChoice,
            "--socket-path", configuration.socketPath,
            "--idle-timeout-secs", String(idleTimeoutSeconds),
        ]
        process.arguments?.append(contentsOf: configuration.embedderTuning.daemonArguments())
        if configuration.noEmbedder {
            process.arguments?.append("--no-embedder")
        }
        if configuration.requireVector {
            process.arguments?.append("--require-vector")
        }
        process.environment = ProcessInfo.processInfo.environment

        // Keep stdin and stdout on separate descriptors. Foundation may close a
        // shared descriptor while it configures the child process stdio actions.
        guard let nullInput = FileHandle(forReadingAtPath: "/dev/null"),
              let nullOutput = FileHandle(forWritingAtPath: "/dev/null") else {
            let reason = String(cString: strerror(errno))
            throw BrokerClientError("Unable to open /dev/null for broker stdio: \(reason)")
        }
        let stderrPipe = Pipe()
        process.standardInput = nullInput
        process.standardOutput = nullOutput
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw BrokerClientError("Failed to start broker: \(error.localizedDescription)")
        }
        onBrokerLaunched?(process.processIdentifier)

        let launchedAt = ContinuousClock.now
        let deadline = ContinuousClock.Instant.deadline(afterSeconds: timeoutSeconds)
        var observedExitStatus: Int32?
        var observedStderr: String?
        var peerExitNotedAt: ContinuousClock.Instant?
        var failedFast = false
        while ContinuousClock.now < deadline {
            if let response = try await sendOffPool(
                AgentBrokerRequest(id: "__ping__", command: "stats"),
                socketPath: configuration.socketPath
            ), response.ok {
                if !process.isRunning {
                    return false
                }
                // Bind-first loser may still be exiting after the winner answered.
                // The broker is up; cancellation must not turn that into a throw.
                try? await Task.sleep(for: pollInterval)
                return process.isRunning
            }

            if !process.isRunning {
                observedExitStatus = process.terminationStatus
                if observedStderr == nil {
                    observedStderr = await BlockingWork.run { readPipeText(stderrPipe) }
                }
                if peerExitNotedAt == nil {
                    peerExitNotedAt = ContinuousClock.now
                }
            } else {
                peerExitNotedAt = nil
            }
            // Fail fast once our peer is dead and silent past the grace
            // window: no broker will ever serve this socket. The grace
            // preserves the bind-first-loser race (a concurrent winner
            // answers within milliseconds), and the post-loop ping below
            // remains the last chance for a slow winner.
            if let noted = peerExitNotedAt,
               noted.duration(to: .now) > peerExitGrace {
                failedFast = true
                break
            }
            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                // Cancelled mid-start: do not leave the launched daemon orphaned.
                await terminateLaunchedBroker(process)
                throw error
            }
        }

        if let response = try await sendOffPool(
            AgentBrokerRequest(id: "__ping__", command: "stats"),
            socketPath: configuration.socketPath
        ), response.ok {
            return observedExitStatus == nil
        }

        // Recorded before the cleanup below stops it. A broker still running at the
        // deadline was slow or stuck; one that had exited crashed or lost a race.
        let runningAtDeadline = process.isRunning
        await terminateLaunchedBroker(process)

        if let observedExitStatus, observedExitStatus != EXIT_SUCCESS {
            let stderrSuffix: String
            if let observedStderr,
               !observedStderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                stderrSuffix = " stderr: \(observedStderr.trimmingCharacters(in: .whitespacesAndNewlines))"
            } else {
                stderrSuffix = ""
            }
            let lead = failedFast
                ? "Broker startup failed: peer exited with status \(observedExitStatus)\(stderrSuffix)"
                : "Timed out waiting for broker startup after a peer exited with status \(observedExitStatus)\(stderrSuffix)"
            var message = lead
            if let observedStderr, Self.isLockContention(observedStderr) {
                message += " Another Wax server holds this store with a different configuration. Use identical server settings so both attach to one broker daemon, or share a single HTTP server (http://127.0.0.1:3000/mcp) across clients."
            }
            throw BrokerClientError(message)
        }

        throw BrokerClientError(Self.startupTimeoutMessage(
            waited: launchedAt.duration(to: .now),
            pid: process.processIdentifier,
            runningAtDeadline: runningAtDeadline,
            stderr: observedStderr
        ))
        #endif
    }

    /// Says how long the start waited and whether the broker was still running, so a
    /// timeout on a loaded host can be told from a broker that hung or crashed.
    static func startupTimeoutMessage(
        waited: Duration,
        pid: pid_t,
        runningAtDeadline: Bool,
        stderr: String?
    ) -> String {
        let seconds = Double(waited.components.seconds)
            + Double(waited.components.attoseconds) / 1_000_000_000_000_000_000
        var message = "Timed out waiting for broker startup after \(String(format: "%.1f", seconds))s"
        message += runningAtDeadline
            ? " (broker \(pid) was running but never answered its socket)."
            : " (broker \(pid) had exited)."
        if let stderr = stderr?.trimmingCharacters(in: .whitespacesAndNewlines), !stderr.isEmpty {
            message += " stderr: \(stderr.suffix(2_000))"
        }
        return message
    }

    /// Returns only after the launched broker has exited, so a cancelled or failed
    /// start never hands control back while the child still holds the socket or store.
    ///
    /// SIGTERM first, then SIGKILL after ``terminateGraceSeconds``. The waits run off
    /// the cooperative pool, where a cancelled caller cannot cut the grace short or
    /// skip the reap, and the reap is bounded so a child in uninterruptible I/O
    /// cannot hang the caller.
    private static func terminateLaunchedBroker(_ process: ChildProcess) async {
        guard process.isRunning else { return }
        let stillRunning = await BlockingWork.run {
            process.terminate()
            if !waitForExit(process, seconds: terminateGraceSeconds) {
                kill(process.processIdentifier, SIGKILL)
            }
            return !waitForExit(process, seconds: reapTimeoutSeconds)
        }
        if stillRunning {
            WaxDiagnostics.logSwallowed(
                BrokerClientError(
                    "Launched broker \(process.processIdentifier) was still running \(reapTimeoutSeconds)s after SIGKILL."
                ),
                context: "broker start cleanup",
                fallback: "return without reaping the launched broker"
            )
        }
    }

    /// Blocks until `process` exits or `seconds` pass. Returns whether it exited.
    private static func waitForExit(_ process: ChildProcess, seconds: TimeInterval) -> Bool {
        let deadline = ContinuousClock.Instant.deadline(afterSeconds: seconds)
        while process.isRunning, ContinuousClock.now < deadline {
            usleep(10_000)
        }
        return !process.isRunning
    }

    /// Sends `shutdown` when the socket exists. Returns false when there is no socket.
    private static func requestShutdown(configuration: AgentBrokerConfiguration) throws -> Bool {
        guard FileManager.default.fileExists(atPath: configuration.socketPath) else {
            return false
        }
        _ = try sendIfAvailable(
            AgentBrokerRequest(id: "__shutdown__", command: "shutdown"),
            socketPath: configuration.socketPath
        )
        return true
    }

    private static func shutdownStartedBroker(configuration: AgentBrokerConfiguration) async throws {
        guard try await BlockingWork.run({ try requestShutdown(configuration: configuration) }) else { return }
        let deadline = ContinuousClock.Instant.deadline(afterSeconds: shutdownTimeoutSeconds)
        while ContinuousClock.now < deadline {
            if try await brokerShutdownCompletedOffPool(
                socketPath: configuration.socketPath,
                storePath: configuration.storePath
            ) {
                return
            }
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: pollInterval)
        }
    }

    /// True when the broker socket is gone and the store file is no longer exclusively locked.
    ///
    /// A still-held store lock is "not done yet", not a hard failure: the daemon can unlink
    /// its socket before `flock` is released, and a 50ms probe would otherwise throw
    /// `WaxError.lockUnavailable` out of the shutdown retry loop.
    package static func brokerShutdownCompleted(
        socketPath: String,
        storePath: String
    ) throws -> Bool {
        guard !FileManager.default.fileExists(atPath: socketPath) else {
            return false
        }

        do {
            try StoreLockProbe.preflightExclusiveAccess(
                at: URL(fileURLWithPath: storePath),
                timeout: .milliseconds(50)
            )
            return true
        } catch let error as WaxError {
            if case .lockUnavailable = error {
                return false
            }
            throw error
        }
    }

    /// ``brokerShutdownCompleted(socketPath:storePath:)`` for async callers: the store
    /// lock probe waits up to 50ms, so it runs off the cooperative pool.
    package static func brokerShutdownCompletedOffPool(
        socketPath: String,
        storePath: String
    ) async throws -> Bool {
        // A socket file means not done, decided without blocking. Skip the hop:
        // on a busy pool, resuming after it can take seconds.
        guard !FileManager.default.fileExists(atPath: socketPath) else {
            return false
        }
        return try await BlockingWork.run {
            try brokerShutdownCompleted(socketPath: socketPath, storePath: storePath)
        }
    }

    /// ``isSocketLive(socketPath:)`` for async callers: the connect runs off the
    /// cooperative pool.
    package static func isSocketLiveOffPool(socketPath: String) async -> Bool {
        // No socket file means no listener, decided without blocking.
        guard FileManager.default.fileExists(atPath: socketPath) else {
            return false
        }
        return await BlockingWork.run { isSocketLive(socketPath: socketPath) }
    }

    /// Returns whether a Unix-domain listener is accepting connections at `socketPath`.
    /// Never creates, replaces, or unlinks the path.
    package static func isSocketLive(socketPath: String) -> Bool {
        guard FileManager.default.fileExists(atPath: socketPath) else { return false }
        let fd = socket(AF_UNIX, unixStreamSocketType, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var address = sockaddr_un()
        #if canImport(Darwin)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: CChar.self, repeating: 0)
            for (index, byte) in pathBytes.enumerated() {
                buffer[index] = byte
            }
        }
        let connectResult = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return connectResult == 0
    }

    /// Kill a mute `wax-cli` broker we can identify, then let `startBrokerIfNeeded` relaunch it.
    /// Foreign listeners (tests, other apps) are left alone.
    private static func restartMuteOwnedBroker(configuration: AgentBrokerConfiguration) async throws -> Bool {
        #if canImport(Darwin) || os(Linux)
        guard let pid = await ownedBrokerPeerPIDOffPool(socketPath: configuration.socketPath) else {
            return false
        }
        kill(pid, SIGTERM)
        let deadline = ContinuousClock.Instant.deadline(afterSeconds: 2)
        while ContinuousClock.now < deadline, !Task.isCancelled {
            let stillRunning = kill(pid, 0) == 0
            if !stillRunning, await !isSocketLiveOffPool(socketPath: configuration.socketPath) {
                return true
            }
            try? await Task.sleep(for: pollInterval)
        }
        // Escalate even when cancelled: a SIGTERM'd, still-mute broker must not linger.
        kill(pid, SIGKILL)
        try? await Task.sleep(for: .milliseconds(150))
        try Task.checkCancellation()
        return await !isSocketLiveOffPool(socketPath: configuration.socketPath)
        #else
        return false
        #endif
    }

    #if canImport(Darwin)
    /// The pid of the `wax-cli` process listening at `socketPath`, or nil for no
    /// listener or a foreign one. The connect runs off the cooperative pool.
    package static func ownedBrokerPeerPIDOffPool(socketPath: String) async -> pid_t? {
        await BlockingWork.run {
            guard let pid = peerPID(socketPath: socketPath), isWaxCLIProcess(pid: pid) else {
                return nil
            }
            return pid
        }
    }

    private static func peerPID(socketPath: String) -> pid_t? {
        let fd = socket(AF_UNIX, unixStreamSocketType, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: CChar.self, repeating: 0)
            for (index, byte) in pathBytes.enumerated() {
                buffer[index] = byte
            }
        }
        let connected = withUnsafePointer(to: &address) { pointer -> Bool in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard connected else { return nil }
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        let result = getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length)
        return result == 0 && pid > 1 ? pid : nil
    }

    private static func isWaxCLIProcess(pid: pid_t) -> Bool {
        var buffer = [CChar](repeating: 0, count: 4096)
        let count = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard count > 0 else { return false }
        let path = String(decoding: buffer.prefix(Int(count)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name == "wax-cli"
    }
    #elseif os(Linux)
    /// The pid of the `wax-cli` process listening at `socketPath`, or nil for no
    /// listener, a foreign one, or one owned by another user. The connect runs
    /// off the cooperative pool.
    package static func ownedBrokerPeerPIDOffPool(socketPath: String) async -> pid_t? {
        await BlockingWork.run {
            guard let peer = peerCredentials(socketPath: socketPath),
                  peer.uid == geteuid(),
                  let path = executablePath(pid: peer.pid),
                  executableName(fromProcExeLink: path) == "wax-cli" else {
                return nil
            }
            return peer.pid
        }
    }

    /// The pid and effective uid of the process that called `listen` on the socket
    /// at `socketPath`, from `SO_PEERCRED`. Nil when nothing accepts connections there.
    package static func peerCredentials(socketPath: String) -> (pid: pid_t, uid: uid_t)? {
        let fd = socket(AF_UNIX, unixStreamSocketType, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { (buffer: UnsafeMutableRawBufferPointer) in
            buffer.initializeMemory(as: CChar.self, repeating: 0)
            for (index, byte) in pathBytes.enumerated() {
                buffer[index] = byte
            }
        }
        let connected = withUnsafePointer(to: &address) { (pointer: UnsafePointer<sockaddr_un>) -> Bool in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { (sockaddrPointer: UnsafePointer<sockaddr>) -> Bool in
                connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard connected else { return nil }
        // `struct ucred` (pid_t pid, uid_t uid, gid_t gid). Glibc hides it behind
        // _GNU_SOURCE, which Swift does not import, so it is spelled as a tuple.
        var credentials: (pid: pid_t, uid: uid_t, gid: gid_t) = (0, 0, 0)
        var length = socklen_t(MemoryLayout<(pid_t, uid_t, gid_t)>.size)
        let result = getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &credentials, &length)
        guard result == 0,
              length == socklen_t(MemoryLayout<(pid_t, uid_t, gid_t)>.size),
              credentials.pid > 1 else {
            return nil
        }
        return (credentials.pid, credentials.uid)
    }

    /// The target of `/proc/<pid>/exe`, or nil when the process is gone or not readable.
    package static func executablePath(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = readlink("/proc/\(pid)/exe", &buffer, buffer.count - 1)
        guard count > 0 else { return nil }
        return String(decoding: buffer.prefix(count).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The file name in a `/proc/<pid>/exe` link. The kernel appends " (deleted)" once
    /// the binary is unlinked, as an upgrade does while the old broker keeps running.
    package static func executableName(fromProcExeLink link: String) -> String {
        let deletedMarker = " (deleted)"
        let path = link.hasSuffix(deletedMarker) ? String(link.dropLast(deletedMarker.count)) : link
        return URL(fileURLWithPath: path).lastPathComponent
    }
    #endif

    /// ``sendIfAvailable(_:socketPath:timeoutSeconds:treatTimeoutAsUnavailable:)`` for async
    /// callers. A round trip blocks its thread for the broker's whole command, up to
    /// `responseTimeoutSeconds`, so it must not hold a cooperative thread.
    private static func sendOffPool(
        _ request: AgentBrokerRequest,
        socketPath: String,
        timeoutSeconds: Double? = nil,
        treatTimeoutAsUnavailable: Bool = false
    ) async throws -> AgentBrokerResponse? {
        // No socket file means no broker, which `sendIfAvailable` reports
        // without blocking. Skip the hop: on a busy pool, resuming after it
        // can take seconds.
        guard FileManager.default.fileExists(atPath: socketPath) else {
            return nil
        }
        return try await BlockingWork.run {
            try sendIfAvailable(
                request,
                socketPath: socketPath,
                timeoutSeconds: timeoutSeconds,
                treatTimeoutAsUnavailable: treatTimeoutAsUnavailable
            )
        }
    }

    private static func sendIfAvailable(
        _ request: AgentBrokerRequest,
        socketPath: String,
        timeoutSeconds: Double? = nil,
        treatTimeoutAsUnavailable: Bool = false
    ) throws -> AgentBrokerResponse? {
        guard FileManager.default.fileExists(atPath: socketPath) else {
            return nil
        }

        let fd = socket(AF_UNIX, unixStreamSocketType, 0)
        guard fd >= 0 else {
            return nil
        }
        defer { close(fd) }
        configureNoSIGPIPE(fd)

        var address = sockaddr_un()
        #if canImport(Darwin)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        address.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw BrokerClientError("Broker socket path is too long: \(socketPath)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: CChar.self, repeating: 0)
            for (index, byte) in pathBytes.enumerated() {
                buffer[index] = byte
            }
        }

        let connectResult = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            if errno == ECONNREFUSED || errno == ENOENT {
                return nil
            }
            throw BrokerClientError("Unable to connect to broker socket at \(socketPath)")
        }

        let payload = try JSONEncoder().encode(request)
        do {
            try writeAll(fd, payload)
            try writeAll(fd, Data([0x0A]))
        } catch let error as BrokerClientError where treatTimeoutAsUnavailable && error.isTransientDisconnect {
            return nil
        }
        shutdown(fd, socketShutdownWrite)

        guard let line = try readSocketResponseLine(
            fd: fd,
            timeoutSeconds: timeoutSeconds ?? responseTimeoutSeconds,
            treatTimeoutAsUnavailable: treatTimeoutAsUnavailable
        ) else {
            return nil
        }
        return try JSONDecoder().decode(AgentBrokerResponse.self, from: Data(line.utf8))
    }

    private static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            var sent = 0
            let total = rawBuffer.count
            while sent < total {
                #if canImport(Darwin)
                let count = write(fd, base + sent, total - sent)
                #else
                let count = send(fd, base + sent, total - sent, Int32(MSG_NOSIGNAL))
                #endif
                if count < 0 {
                    if errno == EINTR { continue }
                    if errno == EPIPE {
                        throw BrokerClientError(
                            "Broker closed the connection while sending request",
                            isTransientDisconnect: true
                        )
                    }
                    throw BrokerClientError("Broker request write failed: \(String(cString: strerror(errno)))")
                }
                if count == 0 {
                    throw BrokerClientError(
                        "Broker closed the connection while sending request",
                        isTransientDisconnect: true
                    )
                }
                sent += count
            }
        }
    }

    private static func configureNoSIGPIPE(_ fd: Int32) {
        #if canImport(Darwin)
        var enabled: Int32 = 1
        _ = setsockopt(
            fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &enabled,
            socklen_t(MemoryLayout<Int32>.size)
        )
        #endif
    }

    /// `poll` timeout for the time left before a deadline. Rounds up so a
    /// sub-millisecond remainder still polls once (≥ 1ms) instead of reading as
    /// an immediate timeout; 0 only once the deadline has passed.
    package static func pollTimeoutMilliseconds(remaining seconds: TimeInterval) -> Int32 {
        guard seconds > 0 else { return 0 }
        return Int32(min(Double(Int32.max), (seconds * 1000).rounded(.up)))
    }

    private static func readSocketResponseLine(
        fd: Int32,
        timeoutSeconds: Double? = nil,
        treatTimeoutAsUnavailable: Bool = false
    ) throws -> String? {
        var buffer = Data()
        // One overall deadline: a broker trickling bytes must not reset the clock per chunk.
        let deadline = ContinuousClock.Instant.deadline(afterSeconds: timeoutSeconds ?? responseTimeoutSeconds)
        while true {
            let remainingMS = pollTimeoutMilliseconds(remaining: deadline.secondsRemaining)
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let pollResult = remainingMS > 0 ? poll(&descriptor, 1, remainingMS) : 0
            if pollResult == 0 {
                if treatTimeoutAsUnavailable {
                    return nil
                }
                throw BrokerClientError("Timed out waiting for broker response")
            }
            if pollResult < 0 {
                if errno == EINTR { continue }
                throw BrokerClientError("Broker response poll failed: \(String(cString: strerror(errno)))")
            }

            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = recv(fd, &chunk, chunk.count, 0)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw BrokerClientError("Broker response read failed: \(String(cString: strerror(errno)))")
            }

            buffer.append(contentsOf: chunk.prefix(count))
            guard buffer.count <= maxSocketResponseBytes else {
                throw BrokerClientError("Broker response exceeds \(maxSocketResponseBytes) bytes")
            }
            if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[..<newlineIndex], as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return line.isEmpty ? nil : line
            }
        }

        guard !buffer.isEmpty else { return nil }
        let line = String(decoding: buffer, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return line.isEmpty ? nil : line
    }

    /// A positive, finite number of seconds from `envKey`, else `defaultValue`.
    /// `inf` and `nan` parse as doubles but are not usable timeouts.
    package static func configuredSeconds(
        envKey: String,
        defaultValue: Double,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Double {
        guard let raw = environment[envKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let seconds = Double(raw),
              seconds.isFinite, seconds > 0 else {
            return defaultValue
        }
        return seconds
    }

    private static func readPipeText(_ pipe: Pipe) -> String? {
        let data = try? pipe.fileHandleForReading.readToEnd()
        guard let data, !data.isEmpty else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

/// The broker socket accepts connections but never answers. Typed so the
/// MCP layer maps it to `broker_unresponsive` without parsing messages.
package struct BrokerUnresponsiveError: LocalizedError, Sendable {
    package let message: String

    package init(_ message: String) {
        self.message = message
    }

    package var errorDescription: String? { message }
}

private struct BrokerClientError: LocalizedError {
    let message: String
    let isTransientDisconnect: Bool

    init(_ message: String, isTransientDisconnect: Bool = false) {
        self.message = message
        self.isTransientDisconnect = isTransientDisconnect
    }

    var errorDescription: String? { message }
}
