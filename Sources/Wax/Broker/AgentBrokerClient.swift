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
    package static let responseTimeoutSeconds = configuredSeconds(
        envKey: "WAX_BROKER_RESPONSE_TIMEOUT_SECS",
        defaultValue: 30.0
    )
    private static let maxSocketResponseBytes = 1_048_576

    package static func perform(
        request: AgentBrokerRequest,
        configuration: AgentBrokerConfiguration,
        shutdownIfStarted: Bool = false
    ) async throws -> AgentBrokerResponse {
        let startedBroker = try await ensureAvailable(configuration: configuration)
        do {
            guard let response = try sendIfAvailable(request, socketPath: configuration.socketPath) else {
                throw BrokerClientError("Broker did not respond after startup.")
            }
            if shutdownIfStarted, startedBroker, request.command != "shutdown" {
                try shutdownStartedBroker(configuration: configuration)
            }
            return response
        } catch {
            if shutdownIfStarted, startedBroker, request.command != "shutdown" {
                try? shutdownStartedBroker(configuration: configuration)
            }
            throw error
        }
    }

    package static func ping(configuration: AgentBrokerConfiguration) async throws -> AgentBrokerResponse {
        let _ = try await ensureAvailable(configuration: configuration)
        guard let response = try sendIfAvailable(
            AgentBrokerRequest(id: "__ping__", command: "stats"),
            socketPath: configuration.socketPath
        ) else {
            throw BrokerClientError("Broker did not respond after startup.")
        }
        return response
    }

    package static func shutdownOwnedBrokerIfReachable(
        configuration: AgentBrokerConfiguration
    ) throws {
        try shutdownStartedBroker(configuration: configuration)
    }

    package static func ensureAvailable(configuration: AgentBrokerConfiguration) async throws -> Bool {
        if let response = try sendIfAvailable(
            AgentBrokerRequest(id: "__ping__", command: "stats"),
            socketPath: configuration.socketPath,
            timeoutSeconds: min(5.0, responseTimeoutSeconds),
            treatTimeoutAsUnavailable: true
        ), response.ok {
            return false
        }

        if isSocketLive(socketPath: configuration.socketPath) {
            if let response = try sendIfAvailable(
                AgentBrokerRequest(id: "__ping__", command: "stats"),
                socketPath: configuration.socketPath,
                treatTimeoutAsUnavailable: true
            ), response.ok {
                return false
            }
            throw BrokerClientError(
                "Broker socket is live at \(configuration.socketPath) but did not answer; not starting a second daemon."
            )
        }

        return try startBrokerIfNeeded(configuration: configuration)
    }

    private static func startBrokerIfNeeded(configuration: AgentBrokerConfiguration) throws -> Bool {
        #if os(iOS) || os(tvOS) || os(watchOS)
        throw BrokerClientError("Starting a broker process is not supported on this platform.")
        #else
        guard FileManager.default.isExecutableFile(atPath: configuration.brokerExecutablePath) else {
            throw BrokerClientError(
                "Broker executable is not executable at \(configuration.brokerExecutablePath)"
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            configuration.brokerExecutablePath,
            "daemon",
            "--store-path", configuration.storePath,
            "--session-root", configuration.sessionRootPath,
            "--embedder", configuration.embedderChoice,
            "--socket-path", configuration.socketPath,
            "--idle-timeout-secs", String(idleTimeoutSeconds),
            "--skip-prewarm",
        ]
        process.arguments?.append(contentsOf: configuration.embedderTuning.daemonArguments())
        if configuration.noEmbedder {
            process.arguments?.append("--no-embedder")
        }
        if configuration.requireVector {
            process.arguments?.append("--require-vector")
        }
        process.environment = ProcessInfo.processInfo.environment

        let nullDevice = FileHandle(forWritingAtPath: "/dev/null")
        let stderrPipe = Pipe()
        process.standardInput = nullDevice
        process.standardOutput = nullDevice
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw BrokerClientError("Failed to start broker: \(error.localizedDescription)")
        }

        let deadline = Date().addingTimeInterval(startTimeoutSeconds)
        var observedExitStatus: Int32?
        var observedStderr: String?
        while Date() < deadline {
            if let response = try sendIfAvailable(
                AgentBrokerRequest(id: "__ping__", command: "stats"),
                socketPath: configuration.socketPath
            ), response.ok {
                if !process.isRunning {
                    return false
                }
                // Bind-first loser may still be exiting after the winner answered.
                Thread.sleep(forTimeInterval: 0.05)
                return process.isRunning
            }

            if !process.isRunning {
                observedExitStatus = process.terminationStatus
                if observedStderr == nil {
                    observedStderr = readPipeText(stderrPipe)
                }
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        if let response = try sendIfAvailable(
            AgentBrokerRequest(id: "__ping__", command: "stats"),
            socketPath: configuration.socketPath
        ), response.ok {
            return observedExitStatus == nil
        }

        terminateLaunchedBroker(process)

        if let observedExitStatus, observedExitStatus != EXIT_SUCCESS {
            let stderrSuffix: String
            if let observedStderr,
               !observedStderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                stderrSuffix = " stderr: \(observedStderr.trimmingCharacters(in: .whitespacesAndNewlines))"
            } else {
                stderrSuffix = ""
            }
            throw BrokerClientError(
                "Timed out waiting for broker startup after a peer exited with status \(observedExitStatus)\(stderrSuffix)"
            )
        }

        throw BrokerClientError("Timed out waiting for broker startup.")
        #endif
    }

    private static func terminateLaunchedBroker(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let stopBy = Date().addingTimeInterval(0.5)
        while process.isRunning, Date() < stopBy {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    private static func shutdownStartedBroker(configuration: AgentBrokerConfiguration) throws {
        guard FileManager.default.fileExists(atPath: configuration.socketPath) else {
            return
        }

        _ = try sendIfAvailable(
            AgentBrokerRequest(id: "__shutdown__", command: "shutdown"),
            socketPath: configuration.socketPath
        )

        let deadline = Date().addingTimeInterval(shutdownTimeoutSeconds)
        while Date() < deadline {
            if try brokerShutdownCompleted(
                socketPath: configuration.socketPath,
                storePath: configuration.storePath
            ) {
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
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
        try writeAll(fd, payload)
        try writeAll(fd, Data([0x0A]))
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
                let count = write(fd, base + sent, total - sent)
                if count < 0 {
                    if errno == EINTR { continue }
                    if errno == EPIPE {
                        throw BrokerClientError("Broker closed the connection while sending request")
                    }
                    throw BrokerClientError("Broker request write failed: \(String(cString: strerror(errno)))")
                }
                if count == 0 {
                    throw BrokerClientError("Broker closed the connection while sending request")
                }
                sent += count
            }
        }
    }

    private static func readSocketResponseLine(
        fd: Int32,
        timeoutSeconds: Double? = nil,
        treatTimeoutAsUnavailable: Bool = false
    ) throws -> String? {
        var buffer = Data()
        let timeoutMS = Int32((timeoutSeconds ?? responseTimeoutSeconds) * 1000)
        while true {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let pollResult = poll(&descriptor, 1, timeoutMS)
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

    private static func configuredSeconds(envKey: String, defaultValue: Double) -> Double {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env[envKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let seconds = Double(raw),
              seconds > 0 else {
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

private struct BrokerClientError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
