import ArgumentParser
import Foundation
import Wax
import WaxCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct DaemonCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daemon",
        abstract: "Run the persistent local Wax broker"
    )

    @OptionGroup var store: VectorStoreOptions

    @Flag(
        name: .customLong("skip-prewarm"),
        help: "Skip background embedder prewarm. Cold first writes may then wait on MiniLM."
    )
    var skipPrewarm = false

    @Option(name: .customLong("socket-path"), help: "Listen on a Unix domain socket instead of stdio")
    var socketPath: String?

    @Option(name: .customLong("session-root"), help: "Directory for broker-managed virtual session stores")
    var sessionRoot = AgentBrokerPathing.defaultSessionRootPath

    @Option(name: .customLong("idle-timeout-secs"), help: "Exit after this many idle seconds in socket mode")
    var idleTimeoutSeconds = 300.0

    @Option(name: .customLong("max-clients"), help: "Most socket clients served at once; more are refused as busy")
    var maxClients = 64

    func validate() throws {
        guard maxClients > 0 else {
            throw ValidationError("--max-clients must be at least 1")
        }
    }

    func runAsync() async throws {
        // Before the store opens: SIGTERM's default action would kill the
        // broker mid-write, which is what the client's SIGTERM grace exists to avoid.
        let shutdown = DaemonShutdown()
        let signalSources = installShutdownSignalHandlers(shutdown)
        defer { signalSources.forEach { $0.cancel() } }

        let service = try await AgentBrokerService(
            storePath: store.storePath,
            sessionRootPath: AgentBrokerPathing.resolveSessionRootPath(
                storePath: store.storePath,
                sessionRootPath: sessionRoot
            ),
            noEmbedder: store.noEmbedder,
            embedderChoice: store.embedder.rawValue,
            requireVector: store.requireVector,
            enableAccessStatsScoring: featureFlagEnabled(
                "WAX_MCP_FEATURE_ACCESS_STATS",
                default: true
            ),
            embedderTuning: store.embedderTuning
        )

        if !store.noEmbedder, !skipPrewarm {
            Task {
                await service.prewarmEmbedder()
            }
        }

        do {
            if let socketPath {
                try await runSocketServer(
                    service: service,
                    at: socketPath,
                    idleTimeoutSeconds: idleTimeoutSeconds,
                    shutdown: shutdown
                )
            } else {
                try await runLoop(
                    service: service,
                    input: FileHandle.standardInput,
                    output: FileHandle.standardOutput,
                    shutdown: shutdown
                )
            }
            try await service.close()
        } catch {
            try? await service.close()
            throw error
        }
    }
}

private extension DaemonCommand {
    #if canImport(Darwin)
    var unixStreamSocketType: Int32 { SOCK_STREAM }
    #elseif canImport(Glibc)
    var unixStreamSocketType: Int32 { Int32(SOCK_STREAM.rawValue) }
    #endif
    var maxSocketRequestBytes: Int { 1_048_576 }
    /// A client must send its whole request within this many seconds of being
    /// accepted. One deadline, so trickled bytes cannot hold a client thread.
    var socketRequestReadSeconds: TimeInterval { 5 }
    /// How long shutdown waits for requests already in `service.handle`. Well
    /// under the client's 2s SIGTERM grace; `service.close()` then queues behind
    /// any command still holding the store's locks.
    var socketShutdownDrainSeconds: TimeInterval { 1 }
    /// How often the accept and stdin loops check for a shutdown request.
    var shutdownPollSliceMS: Int32 { 200 }

    func runLoop(
        service: AgentBrokerService,
        input: FileHandle,
        output: FileHandle,
        shutdown: DaemonShutdown
    ) async throws {
        var buffered = Data()
        let daemon = self
        let inputDescriptor = input.fileDescriptor
        while true {
            // Waiting on stdin blocks for as long as the client is quiet, so it
            // must not hold a cooperative thread. Nil means shutdown was requested.
            guard let chunk = try await BlockingWork.run({
                try daemon.readStdioChunk(fd: inputDescriptor, shutdown: shutdown)
            }) else {
                return
            }
            if chunk.isEmpty {
                if !buffered.isEmpty {
                    do {
                        try await handleRequestLine(
                            String(decoding: buffered, as: UTF8.self),
                            service: service,
                            output: output
                        )
                    } catch is ExitRequested {
                        return
                    }
                }
                return
            }
            buffered.append(chunk)

            while let newlineIndex = buffered.firstIndex(of: 0x0A) {
                let lineData = buffered[..<newlineIndex]
                buffered.removeSubrange(...newlineIndex)
                do {
                    try await handleRequestLine(
                        String(decoding: lineData, as: UTF8.self),
                        service: service,
                        output: output
                    )
                } catch is ExitRequested {
                    return
                }
            }
        }
    }

    /// Reads the next chunk of stdin, polling in slices so a shutdown request is
    /// seen. Returns empty data at EOF and nil once shutdown is requested. Blocks
    /// its thread, so callers run it off the pool.
    func readStdioChunk(fd: Int32, shutdown: DaemonShutdown) throws -> Data? {
        while !shutdown.isRequested {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let pollResult = poll(&descriptor, 1, shutdownPollSliceMS)
            if pollResult == 0 { continue }
            if pollResult < 0 {
                if errno == EINTR { continue }
                throw CLIError("Broker stdin poll failed: \(String(cString: strerror(errno)))")
            }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = read(fd, &chunk, chunk.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw CLIError("Broker stdin read failed: \(String(cString: strerror(errno)))")
            }
            return Data(chunk.prefix(count))
        }
        return nil
    }

    func runSocketServer(
        service: AgentBrokerService,
        at rawSocketPath: String,
        idleTimeoutSeconds: Double,
        shutdown: DaemonShutdown
    ) async throws {
        let socketURL = URL(fileURLWithPath: AgentBrokerPathing.expandPath(rawSocketPath))
        let parent = socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        // A signal during store open: close the store without ever listening.
        if shutdown.isRequested { return }
        if AgentBrokerClient.isSocketLive(socketPath: socketURL.path) {
            throw CLIError("Broker already running at \(socketURL.path)")
        }

        let listener = socket(AF_UNIX, unixStreamSocketType, 0)
        guard listener >= 0 else {
            throw CLIError("Unable to create broker socket: \(String(cString: strerror(errno)))")
        }
        var boundOwnSocket = false
        defer {
            close(listener)
            if boundOwnSocket {
                unlink(socketURL.path)
            }
        }

        var address = sockaddr_un()
        #if canImport(Darwin)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        address.sun_family = sa_family_t(AF_UNIX)

        let socketBytes = Array(socketURL.path.utf8)
        guard socketBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw CLIError("Broker socket path is too long: \(socketURL.path)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: CChar.self, repeating: 0)
            for (index, byte) in socketBytes.enumerated() {
                buffer[index] = byte
            }
        }

        var bindResult = bindUnixSocket(listener, address: &address)
        if bindResult != 0, errno == EADDRINUSE {
            if AgentBrokerClient.isSocketLive(socketPath: socketURL.path) {
                throw CLIError("Broker already running at \(socketURL.path)")
            }
            try removeExistingSocket(at: socketURL.path)
            bindResult = bindUnixSocket(listener, address: &address)
        }
        guard bindResult == 0 else {
            throw CLIError("Unable to bind broker socket at \(socketURL.path): \(String(cString: strerror(errno)))")
        }
        boundOwnSocket = true
        guard listen(listener, 16) == 0 else {
            throw CLIError("Unable to listen on broker socket: \(String(cString: strerror(errno)))")
        }

        let inflight = SocketInflight()
        var loopError: Error?
        let daemon = self
        do {
            // The accept loop blocks in poll for the daemon's whole life. On a
            // cooperative thread it would starve the client tasks it spawns.
            try await BlockingWork.run {
                try daemon.acceptClients(
                    listener: listener,
                    service: service,
                    inflight: inflight,
                    idleTimeoutSeconds: idleTimeoutSeconds,
                    shutdown: shutdown
                )
            }
        } catch {
            loopError = error
        }

        await drainHandledRequests(inflight)
        if let loopError {
            throw loopError
        }
    }

    /// Accepts clients until a client or a signal requests shutdown, or the broker
    /// is idle for `idleTimeoutSeconds`. Blocks its thread, so callers run it off the pool.
    func acceptClients(
        listener: Int32,
        service: AgentBrokerService,
        inflight: SocketInflight,
        idleTimeoutSeconds: Double,
        shutdown: DaemonShutdown
    ) throws {
        var lastActivity = Date()
        while !inflight.shouldStop, !shutdown.isRequested {
            var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            let pollResult = poll(&descriptor, 1, shutdownPollSliceMS)
            if pollResult == 0 {
                if idleTimeoutSeconds > 0,
                   Date().timeIntervalSince(lastActivity) >= idleTimeoutSeconds,
                   !inflight.hasClients {
                    return
                }
                continue
            }
            if pollResult < 0 {
                if errno == EINTR { continue }
                throw CLIError("Broker poll failed: \(String(cString: strerror(errno)))")
            }

            let client = accept(listener, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                throw CLIError("Broker accept failed: \(String(cString: strerror(errno)))")
            }

            lastActivity = Date()
            guard inflight.admitClient(limit: maxClients) else {
                rejectBusyClient(client)
                continue
            }
            let readDeadline = Date().addingTimeInterval(socketRequestReadSeconds)
            Task {
                defer { inflight.clientDone() }
                do {
                    let shouldExit = try await handleSocketClient(
                        service: service,
                        fd: client,
                        readDeadline: readDeadline,
                        inflight: inflight
                    )
                    if shouldExit {
                        inflight.requestStop()
                    }
                } catch {
                    // FileHandle owns the accepted fd. A dead peer must not
                    // double-close it or skip inflight.leave().
                }
            }
        }
    }

    /// Stops new requests from reaching the service, then waits a bounded time
    /// for the ones already in it. Clients still sending a request are not
    /// waited for: the process exits under them once the store is closed.
    func drainHandledRequests(_ inflight: SocketInflight) async {
        inflight.startDraining()
        let drainDeadline = Date().addingTimeInterval(socketShutdownDrainSeconds)
        while inflight.isHandling, Date() < drainDeadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Answers a client past the cap with a busy failure and closes it. Best
    /// effort: the client may already be gone, so a failed send is ignored.
    func rejectBusyClient(_ fd: Int32) {
        defer { close(fd) }
        let response = AgentBrokerResponse.failure(
            message: "Broker is serving its limit of \(maxClients) clients; retry shortly"
        )
        guard let encoded = try? JSONEncoder().encode(response) else { return }
        let line = encoded + Data([0x0A])
        #if canImport(Darwin)
        var noSIGPIPE: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSIGPIPE, socklen_t(MemoryLayout<Int32>.size))
        let flags: Int32 = 0
        #else
        let flags = Int32(MSG_NOSIGNAL)
        #endif
        _ = line.withUnsafeBytes { buffer in
            send(fd, buffer.baseAddress, buffer.count, flags)
        }
    }

    func bindUnixSocket(_ listener: Int32, address: inout sockaddr_un) -> Int32 {
        withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(listener, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    func handleSocketClient(
        service: AgentBrokerService,
        fd: Int32,
        readDeadline: Date,
        inflight: SocketInflight
    ) async throws -> Bool {
        let fileHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let response: AgentBrokerResponse
        let daemon = self

        // The read polls until its deadline and the write blocks on a slow
        // reader; neither may hold a cooperative thread.
        let read = try await BlockingWork.run {
            try daemon.readSocketRequestLine(fd: fd, deadline: readDeadline)
        }
        switch read {
        case .timedOut:
            response = AgentBrokerResponse.failure(
                message: "Invalid request: not received within \(Int(socketRequestReadSeconds))s"
            )
        case .empty:
            response = AgentBrokerResponse.failure(message: "Invalid request: empty payload")
        case .line(let line):
            guard let handled = await handleRequest(line, service: service, inflight: inflight) else {
                try? fileHandle.close()
                return false
            }
            response = handled
        }

        try await BlockingWork.run {
            try daemon.writeJSONLine(response, to: fileHandle)
            try? fileHandle.close()
        }
        return response.shouldExit
    }

    func handleRequestLine(
        _ line: String,
        service: AgentBrokerService,
        output: FileHandle
    ) async throws {
        let trimmed = line.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let request: AgentBrokerRequest
        do {
            request = try JSONDecoder().decode(AgentBrokerRequest.self, from: Data(trimmed.utf8))
        } catch {
            let response = AgentBrokerResponse.failure(
                message: "Invalid request: \(error.localizedDescription)"
            )
            try await writeJSONLineOffPool(response, to: output)
            return
        }

        let response = await service.handle(request)
        try await writeJSONLineOffPool(response, to: output)
        if response.shouldExit {
            throw ExitRequested()
        }
    }

    /// Decodes and runs one request. Nil when shutdown has begun draining, so
    /// nothing reaches the service once the store may be closing.
    func handleRequest(
        _ line: String,
        service: AgentBrokerService,
        inflight: SocketInflight
    ) async -> AgentBrokerResponse? {
        let request: AgentBrokerRequest
        do {
            request = try JSONDecoder().decode(AgentBrokerRequest.self, from: Data(line.utf8))
        } catch {
            return AgentBrokerResponse.failure(message: "Invalid request: \(error.localizedDescription)")
        }
        guard inflight.beginHandling() else { return nil }
        let response = await service.handle(request)
        inflight.endHandling()
        return response
    }

    /// Reads one request line, giving up at `deadline`. Blocks its thread, so
    /// callers run it off the pool.
    func readSocketRequestLine(fd: Int32, deadline: Date) throws -> SocketRequestRead {
        var buffer = Data()
        while true {
            let remainingMS = AgentBrokerClient.pollTimeoutMilliseconds(remaining: deadline.timeIntervalSinceNow)
            guard remainingMS > 0 else { return .timedOut }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let pollResult = poll(&descriptor, 1, remainingMS)
            if pollResult == 0 { continue }
            if pollResult < 0 {
                if errno == EINTR { continue }
                throw CLIError("Broker client poll failed: \(String(cString: strerror(errno)))")
            }

            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = recv(fd, &chunk, chunk.count, 0)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw CLIError("Broker client read failed: \(String(cString: strerror(errno)))")
            }

            buffer.append(contentsOf: chunk.prefix(count))
            guard buffer.count <= maxSocketRequestBytes else {
                throw CLIError("Broker socket request exceeds \(maxSocketRequestBytes) bytes")
            }
            if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                return SocketRequestRead(buffer[..<newlineIndex])
            }
        }
        return SocketRequestRead(buffer)
    }

    func removeExistingSocket(at path: String) throws {
        var existing = stat()
        if lstat(path, &existing) != 0 {
            if errno == ENOENT { return }
            throw CLIError("Unable to inspect broker socket path \(path): \(String(cString: strerror(errno)))")
        }

        guard existing.st_mode & S_IFMT == S_IFSOCK else {
            throw CLIError("Refusing to replace non-socket file at broker socket path: \(path)")
        }

        guard unlink(path) == 0 else {
            throw CLIError("Unable to remove stale broker socket at \(path): \(String(cString: strerror(errno)))")
        }
    }

    /// A write blocks while the reader is slow, so it must not hold a cooperative thread.
    func writeJSONLineOffPool(_ response: AgentBrokerResponse, to output: FileHandle) async throws {
        let daemon = self
        try await BlockingWork.run { try daemon.writeJSONLine(response, to: output) }
    }

    func writeJSONLine(_ response: AgentBrokerResponse, to output: FileHandle) throws {
        let data = try JSONEncoder().encode(response)
        output.write(data)
        output.write(Data([0x0A]))
    }
}

private struct ExitRequested: Error {}

private enum SocketRequestRead: Sendable {
    case line(String)
    case empty
    case timedOut

    init(_ bytes: Data) {
        let line = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        self = line.isEmpty ? .empty : .line(line)
    }
}

/// Set by SIGTERM or SIGINT. The accept and stdin loops stop taking work once it
/// is set; the daemon then drains only the requests already in the service, so a
/// client still sending one cannot hold it, closes the store and exits 0.
private final class DaemonShutdown: @unchecked Sendable {
    private let lock = NSLock()
    private var signalsReceived = 0

    /// Records a signal. Returns true for the first one.
    func recordSignal() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        signalsReceived += 1
        return signalsReceived == 1
    }

    var isRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return signalsReceived > 0
    }
}

/// The first SIGTERM or SIGINT shuts the daemon down gracefully; a second one
/// exits at once, so a wedged shutdown never needs SIGKILL. `_exit` skips atexit
/// handlers and stdio flushing, which may themselves be what is wedged.
private func installShutdownSignalHandlers(_ shutdown: DaemonShutdown) -> [DispatchSourceSignal] {
    ShutdownSignals.observe { signalNumber in
        if !shutdown.recordSignal() {
            _exit(128 + signalNumber)
        }
    }
}

/// Counts accepted socket clients, for the cap and the idle timeout, and the
/// requests inside `service.handle`, which are the only ones shutdown waits for.
private final class SocketInflight: @unchecked Sendable {
    private let lock = NSLock()
    private var clients = 0
    private var handling = 0
    private var draining = false
    private var stop = false

    /// Takes a client slot. False once `limit` clients are being served.
    func admitClient(limit: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard clients < limit else { return false }
        clients += 1
        return true
    }

    func clientDone() {
        lock.lock()
        clients = max(0, clients - 1)
        lock.unlock()
    }

    var hasClients: Bool {
        lock.lock()
        defer { lock.unlock() }
        return clients > 0
    }

    /// Admits a request to the service. False once draining has started.
    func beginHandling() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !draining else { return false }
        handling += 1
        return true
    }

    func endHandling() {
        lock.lock()
        handling = max(0, handling - 1)
        lock.unlock()
    }

    func startDraining() {
        lock.lock()
        draining = true
        lock.unlock()
    }

    var isHandling: Bool {
        lock.lock()
        defer { lock.unlock() }
        return handling > 0
    }

    func requestStop() {
        lock.lock()
        stop = true
        lock.unlock()
    }

    var shouldStop: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stop
    }
}

private func featureFlagEnabled(_ key: String, default defaultValue: Bool) -> Bool {
    let env = ProcessInfo.processInfo.environment
    guard let raw = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
          !raw.isEmpty
    else {
        return defaultValue
    }

    switch raw.lowercased() {
    case "1", "true", "yes", "on":
        return true
    case "0", "false", "no", "off":
        return false
    default:
        return defaultValue
    }
}
