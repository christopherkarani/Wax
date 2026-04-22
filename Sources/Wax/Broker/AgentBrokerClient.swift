import Foundation
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

    private static let startTimeoutSeconds = configuredSeconds(
        envKey: "WAX_BROKER_START_TIMEOUT_SECS",
        defaultValue: 5.0
    )

    private static let idleTimeoutSeconds = configuredSeconds(
        envKey: "WAX_BROKER_IDLE_TIMEOUT_SECS",
        defaultValue: 300.0
    )

    private static let shutdownTimeoutSeconds = configuredSeconds(
        envKey: "WAX_BROKER_SHUTDOWN_TIMEOUT_SECS",
        defaultValue: 2.0
    )

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
            socketPath: configuration.socketPath
        ), response.ok {
            return false
        }

        return try startBrokerIfNeeded(configuration: configuration)
    }

    private static func startBrokerIfNeeded(configuration: AgentBrokerConfiguration) throws -> Bool {
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
                return true
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
            if !FileManager.default.fileExists(atPath: configuration.socketPath) {
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private static func sendIfAvailable(
        _ request: AgentBrokerRequest,
        socketPath: String
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
                try? FileManager.default.removeItem(atPath: socketPath)
                return nil
            }
            throw BrokerClientError("Unable to connect to broker socket at \(socketPath)")
        }

        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let payload = try JSONEncoder().encode(request)
        handle.write(payload)
        handle.write(Data([0x0A]))
        shutdown(fd, socketShutdownWrite)

        let data = try handle.readToEnd() ?? Data()
        guard let line = String(data: data, encoding: .utf8)?
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return nil
        }
        return try JSONDecoder().decode(AgentBrokerResponse.self, from: Data(line.utf8))
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
