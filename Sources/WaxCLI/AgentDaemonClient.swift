import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum AgentDaemonPolicy {
    static func daemonDisabled() -> Bool {
        let env = ProcessInfo.processInfo.environment
        return env["WAX_CLI_DISABLE_DAEMON"] == "1"
    }

    static func shouldUseDaemonForRemember(store: VectorStoreOptions) -> Bool {
        !daemonDisabled() && !store.noEmbedder
    }

    static func shouldUseDaemonForRecall(store: VectorStoreOptions) -> Bool {
        !daemonDisabled() && !store.noEmbedder
    }

    static func shouldUseDaemonForSearch(store: VectorStoreOptions, mode: String) -> Bool {
        !daemonDisabled() && !store.noEmbedder && mode == "hybrid"
    }
}

enum AgentDaemonTransport {
    static let startTimeoutSeconds = configuredSeconds(
        envKey: "WAX_CLI_DAEMON_START_TIMEOUT_SECS",
        defaultValue: 5.0
    )
    static let idleTimeoutSeconds = configuredSeconds(
        envKey: "WAX_CLI_DAEMON_IDLE_TIMEOUT_SECS",
        defaultValue: 300.0
    )

    static func perform(
        request: CLIDaemonRequest,
        storePath: String,
        embedderChoice: EmbedderChoice
    ) throws -> CLIDaemonResponse? {
        let config = try configuration(
            storePath: storePath,
            embedderChoice: embedderChoice
        )

        if let response = try sendIfAvailable(request, socketPath: config.socketPath) {
            return response
        }

        guard try startDaemonIfNeeded(config: config) else {
            return nil
        }
        return try sendIfAvailable(request, socketPath: config.socketPath)
    }

    static func configuration(
        storePath: String,
        embedderChoice: EmbedderChoice
    ) throws -> AgentDaemonConfiguration {
        let expandedStore = Pathing.expandPath(storePath)
        let socketRoot = daemonDirectory()
        try FileManager.default.createDirectory(at: socketRoot, withIntermediateDirectories: true)

        let key = "\(expandedStore)|\(embedderChoice.rawValue)"
        let socketName = "\(stableHexHash(key)).sock"
        let socketPath = socketRoot.appendingPathComponent(socketName).path
        let cliPath = try Pathing.resolveSelfExecutablePath()

        return AgentDaemonConfiguration(
            cliPath: cliPath,
            storePath: expandedStore,
            socketPath: socketPath,
            embedderChoice: embedderChoice
        )
    }

    private static func startDaemonIfNeeded(config: AgentDaemonConfiguration) throws -> Bool {
        let cliURL = URL(fileURLWithPath: config.cliPath)
        guard FileManager.default.isExecutableFile(atPath: cliURL.path) else {
            writeStderr("Warning: unable to auto-start Wax CLI daemon because wax-cli is not executable at \(config.cliPath). Falling back to one-shot CLI.")
            return false
        }

        let nullDevice = FileHandle(forWritingAtPath: "/dev/null")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            config.cliPath,
            "daemon",
            "--store-path", config.storePath,
            "--embedder", config.embedderChoice.rawValue,
            "--require-vector",
            "--skip-prewarm",
            "--socket-path", config.socketPath,
            "--idle-timeout-secs", String(AgentDaemonTransport.idleTimeoutSeconds),
        ]
        process.environment = ProcessInfo.processInfo.environment
        process.standardInput = nullDevice
        process.standardOutput = nullDevice
        process.standardError = nullDevice

        do {
            try process.run()
        } catch {
            writeStderr("Warning: failed to auto-start Wax CLI daemon (\(error.localizedDescription)). Falling back to one-shot CLI.")
            return false
        }

        let deadline = Date().addingTimeInterval(startTimeoutSeconds)
        while Date() < deadline {
            if let response = try sendIfAvailable(
                CLIDaemonRequest(id: "__ping__", command: "stats"),
                socketPath: config.socketPath
            ) {
                return response.ok
            }

            if !process.isRunning, process.terminationStatus != EXIT_SUCCESS {
                writeStderr("Warning: Wax CLI daemon exited during startup. Falling back to one-shot CLI.")
                return false
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        writeStderr("Warning: timed out waiting for Wax CLI daemon startup. Falling back to one-shot CLI.")
        return false
    }

    private static func sendIfAvailable(
        _ request: CLIDaemonRequest,
        socketPath: String
    ) throws -> CLIDaemonResponse? {
        guard FileManager.default.fileExists(atPath: socketPath) else {
            return nil
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
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
            throw CLIError("Daemon socket path is too long: \(socketPath)")
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
            return nil
        }

        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let payload = try JSONEncoder().encode(request)
        handle.write(payload)
        handle.write(Data([0x0A]))
        shutdown(fd, SHUT_WR)

        let data = try handle.readToEnd() ?? Data()
        guard let line = String(data: data, encoding: .utf8)?
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return nil
        }
        return try CLIDaemonResponse.decode(from: Data(line.utf8))
    }

    private static func daemonDirectory() -> URL {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["WAX_CLI_DAEMON_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return URL(fileURLWithPath: Pathing.expandPath(raw), isDirectory: true)
        }

        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
            .appendingPathComponent("waxmcp", isDirectory: true)
            .appendingPathComponent("cli-daemon", isDirectory: true)
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

    private static func stableHexHash(_ text: String) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(hash, radix: 16)
    }
}

struct AgentDaemonConfiguration: Equatable {
    let cliPath: String
    let storePath: String
    let socketPath: String
    let embedderChoice: EmbedderChoice
}

extension CLIDaemonResponse {
    static func decode(from data: Data) throws -> CLIDaemonResponse {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CLIError("Invalid daemon response")
        }

        let id = object["id"] as? String
        let ok = object["ok"] as? Bool ?? false
        let error = object["error"] as? String
        let payload = try decodePayload(from: object["result"] as? [String: Any])

        return CLIDaemonResponse(
            id: id,
            ok: ok,
            payload: payload,
            error: error,
            shouldExit: payload == .shutdown
        )
    }

    private static func decodePayload(from object: [String: Any]?) throws -> CLIDaemonPayload? {
        guard let object else { return nil }
        guard let command = object["command"] as? String else {
            throw CLIError("Invalid daemon response payload")
        }

        switch command {
        case "remember":
            return .remember(
                frameCount: decodeUInt64(object["frameCount"]),
                pendingFrames: decodeUInt64(object["pendingFrames"]),
                framesAdded: decodeUInt64(object["framesAdded"])
            )
        case "recall":
            return .recall(
                query: object["query"] as? String ?? "",
                totalTokens: object["totalTokens"] as? Int ?? 0,
                items: try decodeItems(from: object["items"] as? [[String: Any]] ?? [])
            )
        case "search":
            return .search(
                count: object["count"] as? Int ?? 0,
                items: try decodeItems(from: object["items"] as? [[String: Any]] ?? [])
            )
        case "stats":
            return .stats(
                CLIDaemonStats(
                    storePath: object["storePath"] as? String ?? "",
                    frameCount: decodeUInt64(object["frameCount"]),
                    pendingFrames: decodeUInt64(object["pendingFrames"]),
                    vectorSearchEnabled: object["vectorSearchEnabled"] as? Bool ?? false,
                    embedderModel: object["embedderModel"] as? String
                )
            )
        case "flush":
            return .flush(
                frameCount: decodeUInt64(object["frameCount"]),
                pendingFrames: decodeUInt64(object["pendingFrames"])
            )
        case "shutdown":
            return .shutdown
        default:
            throw CLIError("Unsupported daemon response command '\(command)'")
        }
    }

    private static func decodeItems(from rawItems: [[String: Any]]) throws -> [CLIDaemonItem] {
        rawItems.map { raw in
            CLIDaemonItem(
                rank: raw["rank"] as? Int ?? 0,
                kind: raw["kind"] as? String,
                frameId: decodeUInt64(raw["frameId"]),
                score: raw["score"] as? Double ?? 0,
                text: raw["text"] as? String,
                preview: raw["preview"] as? String,
                sources: raw["sources"] as? [String] ?? []
            )
        }
    }

    private static func decodeUInt64(_ value: Any?) -> UInt64 {
        switch value {
        case let number as NSNumber:
            return number.uint64Value
        case let text as String:
            return UInt64(text) ?? 0
        default:
            return 0
        }
    }
}
