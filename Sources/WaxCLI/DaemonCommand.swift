import ArgumentParser
import Foundation
import Wax
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
    #if canImport(Darwin)
    var unixStreamSocketType: Int32 { SOCK_STREAM }
    #elseif canImport(Glibc)
    var unixStreamSocketType: Int32 { Int32(SOCK_STREAM.rawValue) }
    #endif

    func runLoop(
        service: AgentBrokerService,
        input: FileHandle,
        output: FileHandle
    ) async throws {
        var buffered = Data()
        while true {
            let chunk = try input.read(upToCount: 4096) ?? Data()
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

    func runSocketServer(
        service: AgentBrokerService,
        at rawSocketPath: String,
        idleTimeoutSeconds: Double
    ) async throws {
        let socketURL = URL(fileURLWithPath: AgentBrokerPathing.expandPath(rawSocketPath))
        let parent = socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        unlink(socketURL.path)

        let listener = socket(AF_UNIX, unixStreamSocketType, 0)
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
        let data = try fileHandle.readToEnd() ?? Data()
        let response: AgentBrokerResponse

        if let line = String(data: data, encoding: .utf8)?
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            do {
                let request = try JSONDecoder().decode(AgentBrokerRequest.self, from: Data(line.utf8))
                response = await service.handle(request)
            } catch {
                response = AgentBrokerResponse(
                    ok: false,
                    error: "Invalid request: \(error.localizedDescription)"
                )
            }
        } else {
            response = AgentBrokerResponse(ok: false, error: "Invalid request: empty payload")
        }

        try writeJSONLine(response, to: fileHandle)
        try? fileHandle.close()
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
            let response = AgentBrokerResponse(
                ok: false,
                error: "Invalid request: \(error.localizedDescription)"
            )
            try writeJSONLine(response, to: output)
            return
        }

        let response = await service.handle(request)
        try writeJSONLine(response, to: output)
        if response.shouldExit {
            throw ExitRequested()
        }
    }

    func writeJSONLine(_ response: AgentBrokerResponse, to output: FileHandle) throws {
        let data = try JSONEncoder().encode(response)
        output.write(data)
        output.write(Data([0x0A]))
    }
}

private struct ExitRequested: Error {}
