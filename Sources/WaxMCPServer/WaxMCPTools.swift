#if MCPServer
import Foundation
import MCP
import Wax

enum WaxMCPTools {
    private static let maxContentBytes = 128 * 1024
    private static let maxTopK = 200
    private static let maxRecallLimit = 100
    private static let maxVideoPaths = 50

    static func register(
        on server: Server,
        memory: MemoryOrchestrator,
        video: VideoRAGOrchestrator?,
        photo: PhotoRAGOrchestrator?
    ) async {
        _ = await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: ToolSchemas.allTools, nextCursor: nil)
        }

        _ = await server.withMethodHandler(CallTool.self) { params in
            await handleCall(params: params, memory: memory, video: video, photo: photo)
        }
    }

    static func handleCall(
        params: CallTool.Parameters,
        memory: MemoryOrchestrator,
        video: VideoRAGOrchestrator?,
        photo: PhotoRAGOrchestrator?
    ) async -> CallTool.Result {
        do {
            switch params.name {
            case "wax_remember":
                return try await remember(arguments: params.arguments, memory: memory)
            case "wax_recall":
                return try await recall(arguments: params.arguments, memory: memory)
            case "wax_search":
                return try await search(arguments: params.arguments, memory: memory)
            case "wax_flush":
                return try await flush(memory: memory)
            case "wax_stats":
                return await stats(memory: memory)
            case "wax_video_ingest":
                return try await videoIngest(arguments: params.arguments, video: video)
            case "wax_video_recall":
                return try await videoRecall(arguments: params.arguments, video: video)
            case "wax_photo_ingest":
                _ = photo
                return redirectToSoju()
            case "wax_photo_recall":
                _ = photo
                return redirectToSoju()
            default:
                return errorResult(
                    message: "Unknown tool '\(params.name)'.",
                    code: "unknown_tool"
                )
            }
        } catch let error as ToolValidationError {
            return errorResult(message: error.localizedDescription, code: "invalid_arguments")
        } catch {
            return errorResult(message: error.localizedDescription, code: "execution_failed")
        }
    }

    private static func remember(
        arguments: [String: Value]?,
        memory: MemoryOrchestrator
    ) async throws -> CallTool.Result {
        let args = ToolArguments(arguments)
        let content = try args.requiredString("content", maxBytes: maxContentBytes)
        let metadata = try coerceMetadata(try args.optionalObject("metadata"))

        let before = await memory.runtimeStats()
        try await memory.remember(content, metadata: metadata)
        let after = await memory.runtimeStats()

        let totalBefore = before.frameCount &+ before.pendingFrames
        let totalAfter = after.frameCount &+ after.pendingFrames
        let added = totalAfter >= totalBefore ? (totalAfter - totalBefore) : 0

        return jsonResult([
            "status": "ok",
            "framesAdded": value(from: added),
            "frameCount": value(from: after.frameCount),
            "pendingFrames": value(from: after.pendingFrames),
        ])
    }

    private static func recall(
        arguments: [String: Value]?,
        memory: MemoryOrchestrator
    ) async throws -> CallTool.Result {
        let args = ToolArguments(arguments)
        let query = try args.requiredString("query", maxBytes: maxContentBytes)
        let limit = try args.optionalInt("limit") ?? 5
        guard limit > 0, limit <= maxRecallLimit else {
            throw ToolValidationError.invalid("limit must be between 1 and \(maxRecallLimit)")
        }

        let context = try await memory.recall(query: query)
        let selected = context.items.prefix(limit)
        var lines: [String] = []
        lines.reserveCapacity(selected.count + 2)
        lines.append("Query: \(context.query)")
        lines.append("Total tokens: \(context.totalTokens)")

        for (index, item) in selected.enumerated() {
            lines.append(
                "\(index + 1). [\(item.kind)] frame=\(item.frameId) score=\(String(format: "%.4f", item.score)) \(item.text)"
            )
        }

        return textResult(lines.joined(separator: "\n"))
    }

    private static func search(
        arguments: [String: Value]?,
        memory: MemoryOrchestrator
    ) async throws -> CallTool.Result {
        let args = ToolArguments(arguments)
        let query = try args.requiredString("query", maxBytes: maxContentBytes)
        let modeRaw = try args.optionalString("mode")?.lowercased() ?? "hybrid"
        let topK = try args.optionalInt("topK") ?? 10
        guard topK > 0, topK <= maxTopK else {
            throw ToolValidationError.invalid("topK must be between 1 and \(maxTopK)")
        }

        let mode: MemoryOrchestrator.DirectSearchMode
        switch modeRaw {
        case "text":
            mode = .text
        case "hybrid":
            mode = .hybrid(alpha: 0.5)
        default:
            throw ToolValidationError.invalid("mode must be one of: text, hybrid")
        }

        let hits = try await memory.search(query: query, mode: mode, topK: topK)
        let lines = hits.enumerated().map { index, hit in
            let row: Value = [
                "rank": value(from: index + 1),
                "frameId": value(from: hit.frameId),
                "score": value(from: Double(hit.score)),
                "sources": .array(hit.sources.map { .string($0.rawValue) }),
                "preview": value(from: hit.previewText ?? ""),
            ]
            return encodeJSON(row) ?? "{}"
        }
        return textResult(lines.joined(separator: "\n"))
    }

    private static func flush(memory: MemoryOrchestrator) async throws -> CallTool.Result {
        try await memory.flush()
        let stats = await memory.runtimeStats()
        return textResult("Flushed. \(stats.frameCount) frames now searchable.")
    }

    private static func stats(memory: MemoryOrchestrator) async -> CallTool.Result {
        let stats = await memory.runtimeStats()

        let diskBytes: UInt64 = {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: stats.storeURL.path),
                  let size = attrs[.size] as? NSNumber
            else {
                return 0
            }
            return size.uint64Value
        }()

        let embedder: Value = {
            guard let identity = stats.embedderIdentity else { return .null }
            return [
                "provider": value(from: identity.provider ?? ""),
                "model": value(from: identity.model ?? ""),
                "dimensions": value(from: identity.dimensions ?? 0),
                "normalized": value(from: identity.normalized ?? false),
            ]
        }()

        return jsonResult([
            "frameCount": value(from: stats.frameCount),
            "pendingFrames": value(from: stats.pendingFrames),
            "generation": value(from: stats.generation),
            "diskBytes": value(from: diskBytes),
            "storePath": value(from: stats.storeURL.path),
            "vectorSearchEnabled": value(from: stats.vectorSearchEnabled),
            "embedder": embedder,
            "wal": [
                "walSize": value(from: stats.wal.walSize),
                "writePos": value(from: stats.wal.writePos),
                "checkpointPos": value(from: stats.wal.checkpointPos),
                "pendingBytes": value(from: stats.wal.pendingBytes),
                "committedSeq": value(from: stats.wal.committedSeq),
                "lastSeq": value(from: stats.wal.lastSeq),
                "wrapCount": value(from: stats.wal.wrapCount),
                "checkpointCount": value(from: stats.wal.checkpointCount),
            ],
        ])
    }

    private static func videoIngest(
        arguments: [String: Value]?,
        video: VideoRAGOrchestrator?
    ) async throws -> CallTool.Result {
        guard let video else {
            return errorResult(
                message: "Video RAG is unavailable in this runtime.",
                code: "video_unavailable"
            )
        }

        let args = ToolArguments(arguments)
        let paths = try args.requiredStringArray("paths")
        guard !paths.isEmpty else {
            throw ToolValidationError.missing("paths")
        }
        guard paths.count <= maxVideoPaths else {
            throw ToolValidationError.invalid("paths supports up to \(maxVideoPaths) files per call")
        }

        let customID = try args.optionalString("id")
        if customID != nil, paths.count != 1 {
            throw ToolValidationError.invalid("id can only be used when exactly one path is provided")
        }

        var files: [VideoFile] = []
        files.reserveCapacity(paths.count)

        for (index, path) in paths.enumerated() {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ToolValidationError.invalid("video file does not exist: \(path)")
            }

            let generatedID: String = {
                if let customID { return customID }
                let stem = url.deletingPathExtension().lastPathComponent
                if paths.count == 1 {
                    return stem
                }
                return "\(stem)-\(index + 1)"
            }()
            files.append(VideoFile(id: generatedID, url: url))
        }

        try await video.ingest(files: files)
        try await video.flush()

        return jsonResult([
            "status": "ok",
            "ingested": value(from: files.count),
            "ids": .array(files.map { .string($0.id) }),
        ])
    }

    private static func videoRecall(
        arguments: [String: Value]?,
        video: VideoRAGOrchestrator?
    ) async throws -> CallTool.Result {
        guard let video else {
            return errorResult(
                message: "Video RAG is unavailable in this runtime.",
                code: "video_unavailable"
            )
        }

        let args = ToolArguments(arguments)
        let query = try args.requiredString("query", maxBytes: maxContentBytes)
        let limit = try args.optionalInt("limit") ?? 5
        guard limit > 0, limit <= maxRecallLimit else {
            throw ToolValidationError.invalid("limit must be between 1 and \(maxRecallLimit)")
        }

        let timeRange: ClosedRange<Date>? = try {
            guard let object = try args.optionalObject("time_range") else { return nil }
            guard let start = valueAsDouble(object["start"]),
                  let end = valueAsDouble(object["end"])
            else {
                throw ToolValidationError.invalid("time_range requires numeric start and end")
            }
            guard start <= end else {
                throw ToolValidationError.invalid("time_range.start must be <= time_range.end")
            }
            return Date(timeIntervalSince1970: start)...Date(timeIntervalSince1970: end)
        }()

        let response = try await video.recall(
            VideoQuery(
                text: query,
                timeRange: timeRange,
                resultLimit: limit
            )
        )

        var lines: [String] = []
        lines.reserveCapacity(response.items.count * 3)
        for item in response.items {
            for segment in item.segments {
                let row: Value = [
                    "videoSource": value(from: sourceName(item.videoID.source)),
                    "videoId": value(from: item.videoID.id),
                    "startMs": value(from: UInt64(max(0, segment.startMs))),
                    "endMs": value(from: UInt64(max(0, segment.endMs))),
                    "score": value(from: Double(segment.score)),
                    "snippet": value(from: segment.transcriptSnippet ?? ""),
                ]
                lines.append(encodeJSON(row) ?? "{}")
            }
        }

        return textResult(lines.joined(separator: "\n"))
    }

    private static func redirectToSoju() -> CallTool.Result {
        textResult(ToolSchemas.sojuMessage)
    }

    private static func coerceMetadata(_ metadata: [String: Value]?) throws -> [String: String] {
        guard let metadata else { return [:] }
        var output: [String: String] = [:]
        output.reserveCapacity(metadata.count)

        for (key, value) in metadata {
            switch value {
            case .null:
                continue
            case .string(let string):
                output[key] = string
            case .int(let int):
                output[key] = String(int)
            case .double(let double):
                output[key] = String(double)
            case .bool(let bool):
                output[key] = bool ? "true" : "false"
            case .data(_, _), .array(_), .object(_):
                throw ToolValidationError.invalid("metadata.\(key) must be a scalar")
            }
        }
        return output
    }

    private static func textResult(_ text: String) -> CallTool.Result {
        CallTool.Result(content: [.text(text)], isError: false)
    }

    private static func jsonResult(_ value: Value) -> CallTool.Result {
        let json = encodeJSON(value) ?? "{}"
        return CallTool.Result(
            content: [
                .text(json),
                .resource(
                    uri: "wax://tool/result",
                    mimeType: "application/json",
                    text: json
                ),
            ],
            isError: false
        )
    }

    private static func errorResult(message: String, code: String) -> CallTool.Result {
        let payload: Value = [
            "code": value(from: code),
            "message": value(from: message),
        ]
        let json = encodeJSON(payload) ?? #"{"code":"\#(code)","message":"\#(message)"}"#
        return CallTool.Result(
            content: [
                .text(message),
                .resource(
                    uri: "wax://errors/\(code)",
                    mimeType: "application/json",
                    text: json
                ),
            ],
            isError: true
        )
    }

    private static func encodeJSON(_ value: Value) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func value(from value: UInt64) -> Value {
        if value <= UInt64(Int.max) {
            return .int(Int(value))
        }
        return .string(String(value))
    }

    private static func value(from value: Int) -> Value {
        .int(value)
    }

    private static func value(from value: Double) -> Value {
        if value.isFinite {
            return .double(value)
        }
        return .null
    }

    private static func value(from value: String) -> Value {
        .string(value)
    }

    private static func value(from value: Bool) -> Value {
        .bool(value)
    }

    private static func valueAsDouble(_ value: Value?) -> Double? {
        guard let value else { return nil }
        switch value {
        case .double(let double):
            return double
        case .int(let int):
            return Double(int)
        case .string(let string):
            return Double(string)
        default:
            return nil
        }
    }

    private static func sourceName(_ source: VideoID.Source) -> String {
        switch source {
        case .photos:
            return "photos"
        case .file:
            return "file"
        }
    }
}

private struct ToolArguments {
    let values: [String: Value]

    init(_ values: [String: Value]?) {
        self.values = values ?? [:]
    }

    func requiredString(_ key: String, maxBytes: Int? = nil) throws -> String {
        guard let value = values[key] else {
            throw ToolValidationError.missing(key)
        }
        guard case .string(let string) = value else {
            throw ToolValidationError.invalid("\(key) must be a string")
        }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ToolValidationError.invalid("\(key) must not be empty")
        }
        if let maxBytes, trimmed.utf8.count > maxBytes {
            throw ToolValidationError.invalid("\(key) exceeds max size (\(maxBytes) bytes)")
        }
        return trimmed
    }

    func optionalString(_ key: String) throws -> String? {
        guard let value = values[key] else { return nil }
        guard case .string(let string) = value else {
            throw ToolValidationError.invalid("\(key) must be a string")
        }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func optionalInt(_ key: String) throws -> Int? {
        guard let value = values[key] else { return nil }
        switch value {
        case .int(let int):
            return int
        case .double(let double):
            guard double.isFinite else {
                throw ToolValidationError.invalid("\(key) must be an integer")
            }
            let truncated = double.rounded(.towardZero)
            guard truncated == double else {
                throw ToolValidationError.invalid("\(key) must be an integer")
            }
            guard truncated >= Double(Int.min), truncated <= Double(Int.max) else {
                throw ToolValidationError.invalid("\(key) is out of range")
            }
            return Int(truncated)
        case .string(let string):
            return Int(string)
        default:
            throw ToolValidationError.invalid("\(key) must be an integer")
        }
    }

    func requiredStringArray(_ key: String) throws -> [String] {
        guard let value = values[key] else {
            throw ToolValidationError.missing(key)
        }
        guard case .array(let array) = value else {
            throw ToolValidationError.invalid("\(key) must be an array of strings")
        }
        let parsed = try array.map { element -> String in
            guard case .string(let string) = element else {
                throw ToolValidationError.invalid("\(key) must contain only strings")
            }
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw ToolValidationError.invalid("\(key) must not contain empty paths")
            }
            return trimmed
        }
        return parsed
    }

    func optionalObject(_ key: String) throws -> [String: Value]? {
        guard let value = values[key] else { return nil }
        guard let object = value.objectValue else {
            throw ToolValidationError.invalid("\(key) must be an object")
        }
        return object
    }
}

private enum ToolValidationError: LocalizedError {
    case missing(String)
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .missing(let key):
            return "Missing required argument '\(key)'."
        case .invalid(let message):
            return message
        }
    }
}
#endif
