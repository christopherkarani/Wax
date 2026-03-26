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
        abstract: "Run a persistent JSONL Wax CLI session for repeated vector-capable operations"
    )

    @OptionGroup var store: VectorStoreOptions

    @Flag(
        name: .customLong("skip-prewarm"),
        help: "Skip explicit embedder prewarm on startup; the first vector operation will warm naturally"
    )
    var skipPrewarm = false

    @Option(name: .customLong("socket-path"), help: "Listen on a Unix domain socket instead of stdio")
    var socketPath: String?

    @Option(name: .customLong("idle-timeout-secs"), help: "Exit after this many idle seconds in socket mode")
    var idleTimeoutSeconds: Double = AgentDaemonTransport.idleTimeoutSeconds

    func runAsync() async throws {
        let url = try StoreSession.resolveURL(store.storePath)
        let requireVector = store.requireVector || !store.noEmbedder
        let memory = try await StoreSession.open(
            at: url,
            noEmbedder: store.noEmbedder,
            skipPrewarm: skipPrewarm,
            embedderChoice: store.embedder,
            requireVector: requireVector
        )

        let session = CLIDaemonSession(memory: memory)
        do {
            if let socketPath {
                try await session.runSocketServer(
                    at: socketPath,
                    idleTimeoutSeconds: idleTimeoutSeconds
                )
            } else {
                try await session.runLoop(
                    input: FileHandle.standardInput,
                    output: FileHandle.standardOutput
                )
            }
            try await memory.close()
        } catch {
            try? await memory.close()
            throw error
        }
    }
}

struct CLIDaemonRequest: Codable, Sendable {
    var id: String?
    var command: String
    var content: String?
    var query: String?
    var metadata: [String: String]?
    var mode: String?
    var topK: Int?
    var limit: Int?
}

struct CLIDaemonItem: Equatable, Sendable {
    var rank: Int
    var kind: String?
    var frameId: UInt64
    var score: Double
    var text: String?
    var preview: String?
    var sources: [String]
}

struct CLIDaemonStats: Equatable, Sendable {
    var storePath: String
    var frameCount: UInt64
    var pendingFrames: UInt64
    var vectorSearchEnabled: Bool
    var embedderModel: String?
}

enum CLIDaemonPayload: Equatable, Sendable {
    case remember(frameCount: UInt64, pendingFrames: UInt64, framesAdded: UInt64)
    case recall(query: String, totalTokens: Int, items: [CLIDaemonItem])
    case search(count: Int, items: [CLIDaemonItem])
    case stats(CLIDaemonStats)
    case flush(frameCount: UInt64, pendingFrames: UInt64)
    case shutdown

    func jsonObject() -> [String: Any] {
        switch self {
        case .remember(let frameCount, let pendingFrames, let framesAdded):
            return [
                "command": "remember",
                "frameCount": frameCount,
                "pendingFrames": pendingFrames,
                "framesAdded": framesAdded,
            ]
        case .recall(let query, let totalTokens, let items):
            return [
                "command": "recall",
                "query": query,
                "totalTokens": totalTokens,
                "count": items.count,
                "items": items.map(\.jsonObject),
            ]
        case .search(let count, let items):
            return [
                "command": "search",
                "count": count,
                "items": items.map(\.jsonObject),
            ]
        case .stats(let stats):
            return [
                "command": "stats",
                "storePath": stats.storePath,
                "frameCount": stats.frameCount,
                "pendingFrames": stats.pendingFrames,
                "vectorSearchEnabled": stats.vectorSearchEnabled,
                "embedderModel": stats.embedderModel as Any,
            ]
        case .flush(let frameCount, let pendingFrames):
            return [
                "command": "flush",
                "frameCount": frameCount,
                "pendingFrames": pendingFrames,
            ]
        case .shutdown:
            return ["command": "shutdown"]
        }
    }
}

struct CLIDaemonResponse: Equatable, Sendable {
    var id: String?
    var ok: Bool
    var payload: CLIDaemonPayload?
    var error: String?
    var shouldExit: Bool

    func jsonObject() -> [String: Any] {
        var object: [String: Any] = ["ok": ok]
        if let id {
            object["id"] = id
        }
        if let payload {
            object["result"] = payload.jsonObject()
        }
        if let error {
            object["error"] = error
        }
        return object
    }
}

actor CLIDaemonSession {
    private let memory: MemoryOrchestrator

    init(memory: MemoryOrchestrator) {
        self.memory = memory
    }

    func runLoop(input: FileHandle, output: FileHandle) async throws {
        for try await line in input.bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let response: CLIDaemonResponse
            do {
                let request = try JSONDecoder().decode(CLIDaemonRequest.self, from: Data(trimmed.utf8))
                response = await handle(request)
            } catch {
                response = CLIDaemonResponse(
                    id: nil,
                    ok: false,
                    payload: nil,
                    error: "Invalid request: \(error.localizedDescription)",
                    shouldExit: false
                )
            }

            try writeJSONLine(response.jsonObject(), to: output)
            if response.shouldExit {
                return
            }
        }
    }

    func runSocketServer(
        at rawSocketPath: String,
        idleTimeoutSeconds: Double
    ) async throws {
        let socketURL = URL(fileURLWithPath: Pathing.expandPath(rawSocketPath))
        let parent = socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        unlink(socketURL.path)

        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else {
            throw CLIError("Unable to create daemon socket: \(String(cString: strerror(errno)))")
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
            throw CLIError("Daemon socket path is too long: \(socketURL.path)")
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
            throw CLIError("Unable to bind daemon socket at \(socketURL.path): \(String(cString: strerror(errno)))")
        }
        guard listen(listener, 16) == 0 else {
            throw CLIError("Unable to listen on daemon socket: \(String(cString: strerror(errno)))")
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
                throw CLIError("Daemon poll failed: \(String(cString: strerror(errno)))")
            }

            let client = accept(listener, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                throw CLIError("Daemon accept failed: \(String(cString: strerror(errno)))")
            }

            do {
                try await handleSocketClient(fd: client)
            } catch {
                close(client)
                throw error
            }
        }
    }

    func handle(_ request: CLIDaemonRequest) async -> CLIDaemonResponse {
        do {
            let command = request.command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let payload: CLIDaemonPayload
            let shouldExit: Bool

            switch command {
            case "remember":
                payload = try await handleRemember(request)
                shouldExit = false
            case "recall":
                payload = try await handleRecall(request)
                shouldExit = false
            case "search":
                payload = try await handleSearch(request)
                shouldExit = false
            case "stats":
                payload = await handleStats()
                shouldExit = false
            case "flush":
                payload = try await handleFlush()
                shouldExit = false
            case "shutdown", "exit", "quit":
                payload = .shutdown
                shouldExit = true
            default:
                throw CLIError("Unsupported daemon command '\(request.command)'")
            }

            return CLIDaemonResponse(
                id: request.id,
                ok: true,
                payload: payload,
                error: nil,
                shouldExit: shouldExit
            )
        } catch {
            return CLIDaemonResponse(
                id: request.id,
                ok: false,
                payload: nil,
                error: error.localizedDescription,
                shouldExit: false
            )
        }
    }

    private func handleRemember(_ request: CLIDaemonRequest) async throws -> CLIDaemonPayload {
        let trimmed = request.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            throw CLIError("remember requires non-empty content")
        }

        let before = await memory.runtimeStats()
        try await memory.remember(trimmed, metadata: request.metadata ?? [:])
        try await memory.flush()
        let after = await memory.runtimeStats()

        let totalBefore = before.frameCount + before.pendingFrames
        let totalAfter = after.frameCount + after.pendingFrames
        let framesAdded = totalAfter >= totalBefore ? (totalAfter - totalBefore) : 0

        return .remember(
            frameCount: after.frameCount,
            pendingFrames: after.pendingFrames,
            framesAdded: framesAdded
        )
    }

    private func handleRecall(_ request: CLIDaemonRequest) async throws -> CLIDaemonPayload {
        let query = request.query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !query.isEmpty else {
            throw CLIError("recall requires a non-empty query")
        }

        let limit = request.limit ?? 5
        guard limit >= 1, limit <= 100 else {
            throw CLIError("limit must be between 1 and 100")
        }

        let context = try await memory.recall(query: query, frameFilter: nil)
        let items = context.items.prefix(limit).enumerated().map { index, item in
            CLIDaemonItem(
                rank: index + 1,
                kind: "\(item.kind)",
                frameId: item.frameId,
                score: Double(item.score),
                text: item.text,
                preview: nil,
                sources: []
            )
        }

        return .recall(query: context.query, totalTokens: context.totalTokens, items: items)
    }

    private func handleSearch(_ request: CLIDaemonRequest) async throws -> CLIDaemonPayload {
        let query = request.query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !query.isEmpty else {
            throw CLIError("search requires a non-empty query")
        }

        let topK = request.topK ?? 10
        guard topK >= 1, topK <= 200 else {
            throw CLIError("topK must be between 1 and 200")
        }

        let mode = (request.mode ?? "text").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let searchMode: MemoryOrchestrator.DirectSearchMode
        switch mode {
        case "text":
            searchMode = .text
        case "hybrid":
            searchMode = .hybrid(alpha: 0.5)
        default:
            throw CLIError("search mode must be one of: text, hybrid")
        }

        let hits = try await memory.search(query: query, mode: searchMode, topK: topK, frameFilter: nil)
        let items = hits.enumerated().map { index, hit in
            CLIDaemonItem(
                rank: index + 1,
                kind: nil,
                frameId: hit.frameId,
                score: Double(hit.score),
                text: nil,
                preview: hit.previewText,
                sources: hit.sources.map(\.rawValue)
            )
        }

        return .search(count: items.count, items: items)
    }

    private func handleStats() async -> CLIDaemonPayload {
        let stats = await memory.runtimeStats()
        return .stats(
            CLIDaemonStats(
                storePath: stats.storeURL.path,
                frameCount: stats.frameCount,
                pendingFrames: stats.pendingFrames,
                vectorSearchEnabled: stats.vectorSearchEnabled,
                embedderModel: stats.embedderIdentity?.model
            )
        )
    }

    private func handleFlush() async throws -> CLIDaemonPayload {
        try await memory.flush()
        let stats = await memory.runtimeStats()
        return .flush(frameCount: stats.frameCount, pendingFrames: stats.pendingFrames)
    }

    private func writeJSONLine(_ object: [String: Any], to output: FileHandle) throws {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        output.write(data)
        output.write(Data([0x0A]))
    }

    private func handleSocketClient(fd: Int32) async throws {
        let fileHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let data = try fileHandle.readToEnd() ?? Data()
        let response: CLIDaemonResponse

        if let line = String(data: data, encoding: .utf8)?
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            do {
                let request = try JSONDecoder().decode(CLIDaemonRequest.self, from: Data(line.utf8))
                response = await self.handle(request)
            } catch {
                response = CLIDaemonResponse(
                    id: nil,
                    ok: false,
                    payload: nil,
                    error: "Invalid request: \(error.localizedDescription)",
                    shouldExit: false
                )
            }
        } else {
            response = CLIDaemonResponse(
                id: nil,
                ok: false,
                payload: nil,
                error: "Invalid request: empty payload",
                shouldExit: false
            )
        }

        try writeJSONLine(response.jsonObject(), to: fileHandle)
        try? fileHandle.close()
    }
}

private extension CLIDaemonItem {
    var jsonObject: [String: Any] {
        var object: [String: Any] = [
            "rank": rank,
            "frameId": frameId,
            "score": score,
            "sources": sources,
        ]
        if let kind {
            object["kind"] = kind
        }
        if let text {
            object["text"] = text
        }
        if let preview {
            object["preview"] = preview
        }
        return object
    }
}
