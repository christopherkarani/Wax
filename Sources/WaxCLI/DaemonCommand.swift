import ArgumentParser
import Foundation
import Wax
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

struct DaemonCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daemon",
        abstract: "Run the persistent local Wax broker"
    )

    @OptionGroup var store: VectorStoreOptions

    @Flag(
        name: .customLong("skip-prewarm"),
        help: "Accepted for compatibility. The broker uses lazy embedders and does not eagerly prewarm."
    )
    var skipPrewarm = false

    @Option(name: .customLong("socket-path"), help: "Listen on a Unix domain socket instead of stdio")
    var socketPath: String?

    @Option(name: .customLong("session-root"), help: "Directory for broker-managed virtual session stores")
    var sessionRoot = AgentBrokerPathing.defaultSessionRootPath

    @Option(name: .customLong("idle-timeout-secs"), help: "Exit after this many idle seconds in socket mode")
    var idleTimeoutSeconds = 300.0

    func runAsync() async throws {
        let service = try await AgentBrokerService(
            storePath: store.storePath,
            sessionRootPath: sessionRoot,
            noEmbedder: store.noEmbedder,
            embedderChoice: store.embedder.rawValue,
            requireVector: store.requireVector,
            embedderTuning: store.embedderTuning
        )

        do {
            if let socketPath {
                try await runSocketServer(
                    service: service,
                    at: socketPath,
                    idleTimeoutSeconds: idleTimeoutSeconds
                )
            } else {
                try await runLoop(
                    service: service,
                    input: FileHandle.standardInput,
                    output: FileHandle.standardOutput
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
    var maxRequestBytes: Int {
        configuredPositiveInt(envKey: "WAX_BROKER_MAX_REQUEST_BYTES", defaultValue: 1_048_576)
    }

    var socketReadTimeoutSeconds: Double {
        configuredPositiveDouble(envKey: "WAX_BROKER_SOCKET_READ_TIMEOUT_SECS", defaultValue: 5.0)
    }

    func runLoop(
        service: AgentBrokerService,
        input: FileHandle,
        output: FileHandle
    ) async throws {
        var pending = Data()
        var droppingOversizedEnvelope = false

        for try await byte in input.bytes {
            if byte == 0x0A {
                if droppingOversizedEnvelope {
                    try writeJSONLine(Self.requestTooLargeResponse(maxBytes: maxRequestBytes), to: output)
                    pending.removeAll(keepingCapacity: true)
                    droppingOversizedEnvelope = false
                    continue
                }

                let shouldExit = try await handleRequestEnvelope(pending, service: service, output: output)
                pending.removeAll(keepingCapacity: true)
                if shouldExit {
                    return
                }
                continue
            }

            if droppingOversizedEnvelope {
                continue
            }

            pending.append(byte)
            if pending.count > maxRequestBytes {
                pending.removeAll(keepingCapacity: true)
                droppingOversizedEnvelope = true
            }
        }

        if droppingOversizedEnvelope {
            try writeJSONLine(Self.requestTooLargeResponse(maxBytes: maxRequestBytes), to: output)
        } else if !pending.isEmpty {
            _ = try await handleRequestEnvelope(pending, service: service, output: output)
        }
    }

    func handleRequestEnvelope(
        _ envelope: Data,
        service: AgentBrokerService,
        output: FileHandle
    ) async throws -> Bool {
        let line = String(data: envelope, encoding: .utf8) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let request: AgentBrokerRequest
        do {
            request = try JSONDecoder().decode(AgentBrokerRequest.self, from: Data(trimmed.utf8))
        } catch {
            let response = AgentBrokerResponse(
                ok: false,
                error: "Invalid request: \(error.localizedDescription)"
            )
            try writeJSONLine(response, to: output)
            return false
        }

        let response = await service.handle(request)
        try writeJSONLine(response, to: output)
        return response.shouldExit
    }

    static func requestTooLargeResponse(maxBytes: Int) -> AgentBrokerResponse {
        AgentBrokerResponse(
            ok: false,
            error: "Broker request exceeds maximum envelope size of \(maxBytes) bytes"
        )
    }

    static func requestReadTimeoutResponse(timeoutSeconds: Double) -> AgentBrokerResponse {
        AgentBrokerResponse(
            ok: false,
            error: "Timed out waiting for complete broker request after \(timeoutSeconds) seconds"
        )
    }

    static func socketReadFailureResponse(_ error: Error) -> AgentBrokerResponse {
        AgentBrokerResponse(
            ok: false,
            error: "Invalid request: \(error.localizedDescription)"
        )
    }

    func readSocketRequestEnvelope(fd: Int32) throws -> Data? {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(socketReadTimeoutSeconds)

        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw BrokerDaemonReadError.timeout(socketReadTimeoutSeconds)
            }

            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let pollResult = poll(&descriptor, 1, Int32(max(1, remaining * 1000)))
            if pollResult == 0 {
                throw BrokerDaemonReadError.timeout(socketReadTimeoutSeconds)
            }
            if pollResult < 0 {
                if errno == EINTR { continue }
                throw CLIError("Broker request poll failed: \(String(cString: strerror(errno)))")
            }

            let bytesRead = read(fd, &buffer, buffer.count)
            if bytesRead > 0 {
                if let newline = buffer[..<bytesRead].firstIndex(of: 0x0A) {
                    let count = newline
                    guard result.count + count <= maxRequestBytes else {
                        throw BrokerDaemonReadError.tooLarge(maxRequestBytes)
                    }
                    result.append(buffer, count: count)
                    return result
                }
                guard result.count + bytesRead <= maxRequestBytes else {
                    throw BrokerDaemonReadError.tooLarge(maxRequestBytes)
                }
                result.append(buffer, count: bytesRead)
                continue
            }

            if bytesRead == 0 {
                return result.isEmpty ? nil : result
            }

            if errno == EINTR {
                continue
            }

            throw CLIError("Broker request read failed: \(String(cString: strerror(errno)))")
        }
    }

    func responseForReadError(_ readError: Error) -> AgentBrokerResponse {
        switch readError {
        case BrokerDaemonReadError.tooLarge(let maxBytes):
            return Self.requestTooLargeResponse(maxBytes: maxBytes)
        case BrokerDaemonReadError.timeout(let timeoutSeconds):
            return Self.requestReadTimeoutResponse(timeoutSeconds: timeoutSeconds)
        default:
            return Self.socketReadFailureResponse(readError)
        }
    }

    func configuredPositiveInt(envKey: String, defaultValue: Int) -> Int {
        guard let raw = ProcessInfo.processInfo.environment[envKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let value = Int(raw),
              value > 0 else {
            return defaultValue
        }
        return value
    }

    func configuredPositiveDouble(envKey: String, defaultValue: Double) -> Double {
        guard let raw = ProcessInfo.processInfo.environment[envKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let value = Double(raw),
              value > 0 else {
            return defaultValue
        }
        return value
    }

    func runSocketServer(
        service: AgentBrokerService,
        at rawSocketPath: String,
        idleTimeoutSeconds: Double
    ) async throws {
        let socketURL = URL(fileURLWithPath: AgentBrokerPathing.expandPath(rawSocketPath))
        let parent = socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        unlink(socketURL.path)

        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else {
            throw CLIError("Unable to create broker socket: \(String(cString: strerror(errno)))")
        }
        defer {
            close(listener)
            unlink(socketURL.path)
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

        let bindResult = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(listener, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            throw CLIError("Unable to bind broker socket at \(socketURL.path): \(String(cString: strerror(errno)))")
        }
        guard listen(listener, 16) == 0 else {
            throw CLIError("Unable to listen on broker socket: \(String(cString: strerror(errno)))")
        }
        _ = signal(SIGPIPE, SIG_IGN)

        let timeoutMS: Int32 = idleTimeoutSeconds > 0 ? Int32(idleTimeoutSeconds * 1000) : -1
        while true {
            var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            let pollResult = poll(&descriptor, 1, timeoutMS)
            if pollResult == 0 {
                return
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

            do {
                let shouldExit = try await handleSocketClient(service: service, fd: client)
                if shouldExit {
                    return
                }
            } catch {
                close(client)
                throw error
            }
        }
    }

    func handleSocketClient(service: AgentBrokerService, fd: Int32) async throws -> Bool {
        let fileHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let response: AgentBrokerResponse

        do {
            guard let data = try readSocketRequestEnvelope(fd: fd) else {
                try? fileHandle.close()
                return false
            }
            let line = String(data: data, encoding: .utf8) ?? ""
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                try? fileHandle.close()
                return false
            }
            do {
                let request = try JSONDecoder().decode(AgentBrokerRequest.self, from: Data(trimmed.utf8))
                response = await service.handle(request)
            } catch {
                response = AgentBrokerResponse(
                    ok: false,
                    error: "Invalid request: \(error.localizedDescription)"
                )
            }
        } catch {
            response = responseForReadError(error)
        }

        try writeJSONLine(response, to: fileHandle)
        try? fileHandle.close()
        return response.shouldExit
    }

    func writeJSONLine(_ response: AgentBrokerResponse, to output: FileHandle) throws {
        let data = try JSONEncoder().encode(response)
        output.write(data)
        output.write(Data([0x0A]))
    }
}

private enum BrokerDaemonReadError: LocalizedError {
    case tooLarge(Int)
    case timeout(Double)

    var errorDescription: String? {
        switch self {
        case .tooLarge(let maxBytes):
            return "Broker request exceeds maximum envelope size of \(maxBytes) bytes"
        case .timeout(let seconds):
            return "Timed out waiting for complete broker request after \(seconds) seconds"
        }
    }
}
