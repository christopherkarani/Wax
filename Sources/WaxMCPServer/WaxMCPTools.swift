#if MCPServer
import Foundation
import MCP
import Wax

enum WaxMCPTools {
    private static let maxContentBytes = 128 * 1024
    private static let maxTopK = 200
    private static let maxRecallLimit = 100
    private static let maxGraphLimit = 500
    private static let maxGraphIdentifierBytes = 256
    private static let maxGraphKindBytes = 64
    private static let graphIdentifierAllowedScalars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-")
    private static let graphKindAllowedScalars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")

    static func register(
        on server: Server,
        memory: MemoryOrchestrator,
        structuredMemoryEnabled: Bool
    ) async {
        _ = await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(
                tools: ToolSchemas.tools(structuredMemoryEnabled: structuredMemoryEnabled),
                nextCursor: nil
            )
        }

        _ = await server.withMethodHandler(CallTool.self) { params in
            await handleCall(params: params, memory: memory)
        }
    }

    static func handleCall(
        params: CallTool.Parameters,
        memory: MemoryOrchestrator
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
                return try await stats(memory: memory)
            case "wax_session_start":
                return await sessionStart(memory: memory)
            case "wax_session_end":
                return await sessionEnd(memory: memory)
            case "wax_handoff":
                return try await handoff(arguments: params.arguments, memory: memory)
            case "wax_handoff_latest":
                return try await handoffLatest(arguments: params.arguments, memory: memory)
            case "wax_entity_upsert":
                return try await entityUpsert(arguments: params.arguments, memory: memory)
            case "wax_fact_assert":
                return try await factAssert(arguments: params.arguments, memory: memory)
            case "wax_fact_retract":
                return try await factRetract(arguments: params.arguments, memory: memory)
            case "wax_facts_query":
                return try await factsQuery(arguments: params.arguments, memory: memory)
            case "wax_entity_resolve":
                return try await entityResolve(arguments: params.arguments, memory: memory)
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
        let sessionID = try parseOptionalSessionID(args)
        var metadata = try coerceMetadata(try args.optionalObject("metadata"))
        if let sessionID {
            metadata["session_id"] = sessionID.uuidString
        }

        let before = await memory.runtimeStats()
        try await memory.remember(content, metadata: metadata)
        let after = await memory.runtimeStats()

        let totalBefore = before.frameCount + before.pendingFrames
        let totalAfter = after.frameCount + after.pendingFrames
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
        let sessionFilter = try parseSessionFrameFilter(args)

        // NOTE: MemoryOrchestrator.recall() does not accept a limit parameter.
        // The orchestrator returns its own default item count, and we truncate
        // post-hoc. If the orchestrator's default is lower than the requested
        // limit, the user may receive fewer items than expected.
        let context = try await memory.recall(query: query, frameFilter: sessionFilter)
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
        let sessionFilter = try parseSessionFrameFilter(args)

        let mode: MemoryOrchestrator.DirectSearchMode
        switch modeRaw {
        case "text":
            mode = .text
        case "hybrid":
            mode = .hybrid(alpha: 0.5)
        default:
            throw ToolValidationError.invalid("mode must be one of: text, hybrid")
        }

        let hits = try await memory.search(query: query, mode: mode, topK: topK, frameFilter: sessionFilter)
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

    private static func stats(memory: MemoryOrchestrator) async throws -> CallTool.Result {
        let stats = await memory.runtimeStats()
        let sessionStats = try await memory.sessionRuntimeStats()

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
            "features": [
                "structuredMemoryEnabled": value(from: stats.structuredMemoryEnabled),
                "accessStatsScoringEnabled": value(from: stats.accessStatsScoringEnabled),
            ],
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
            "session": [
                "active": value(from: sessionStats.active),
                "session_id": sessionStats.sessionId.map { value(from: $0.uuidString) } ?? .null,
                "sessionFrameCount": value(from: sessionStats.sessionFrameCount),
                "sessionTokenEstimate": value(from: sessionStats.sessionTokenEstimate),
                "pendingFramesStoreWide": value(from: sessionStats.pendingFramesStoreWide),
                "countsIncludePending": value(from: sessionStats.countsIncludePending),
            ],
        ])
    }

    private static func sessionStart(memory: MemoryOrchestrator) async -> CallTool.Result {
        let sessionID = await memory.startSession()
        return jsonResult([
            "status": "ok",
            "session_id": value(from: sessionID.uuidString),
        ])
    }

    private static func sessionEnd(memory: MemoryOrchestrator) async -> CallTool.Result {
        await memory.endSession()
        return jsonResult([
            "status": "ok",
            "active": value(from: false),
        ])
    }

    private static func handoff(
        arguments: [String: Value]?,
        memory: MemoryOrchestrator
    ) async throws -> CallTool.Result {
        let args = ToolArguments(arguments)
        let content = try args.requiredString("content", maxBytes: maxContentBytes)
        let sessionID = try parseOptionalSessionID(args)
        let project = try args.optionalString("project")
        let pendingTasks = try args.optionalStringArray("pending_tasks") ?? []

        let frameId = try await memory.rememberHandoff(
            content: content,
            project: project,
            pendingTasks: pendingTasks,
            sessionId: sessionID
        )

        return jsonResult([
            "status": "ok",
            "frame_id": value(from: frameId),
        ])
    }

    private static func handoffLatest(
        arguments: [String: Value]?,
        memory: MemoryOrchestrator
    ) async throws -> CallTool.Result {
        let args = ToolArguments(arguments)
        let project = try args.optionalString("project")
        guard let latest = try await memory.latestHandoff(project: project) else {
            return jsonResult([
                "found": value(from: false),
            ])
        }

        return jsonResult([
            "found": value(from: true),
            "frame_id": value(from: latest.frameId),
            "timestamp_ms": value(from: latest.timestampMs),
            "project": latest.project.map(value(from:)) ?? .null,
            "pending_tasks": .array(latest.pendingTasks.map(value(from:))),
            "content": value(from: latest.content),
        ])
    }

    private static func entityUpsert(
        arguments: [String: Value]?,
        memory: MemoryOrchestrator
    ) async throws -> CallTool.Result {
        let args = ToolArguments(arguments)
        let key = try args.requiredString("key", maxBytes: maxGraphIdentifierBytes)
        let kind = try args.requiredString("kind", maxBytes: maxGraphKindBytes)
        let aliases = try args.optionalStringArray("aliases") ?? []
        let commit = try args.optionalBool("commit") ?? true

        try validateEntityKey(key, field: "key")
        try validateGraphKind(kind, field: "kind")

        let entityID = try await memory.upsertEntity(
            key: EntityKey(key),
            kind: kind,
            aliases: aliases,
            commit: commit
        )

        return jsonResult([
            "status": "ok",
            "entity_id": value(from: entityID.rawValue),
            "key": value(from: key),
            "committed": value(from: commit),
        ])
    }

    private static func factAssert(
        arguments: [String: Value]?,
        memory: MemoryOrchestrator
    ) async throws -> CallTool.Result {
        let args = ToolArguments(arguments)
        let subject = try args.requiredString("subject", maxBytes: maxGraphIdentifierBytes)
        let predicate = try args.requiredString("predicate", maxBytes: maxGraphIdentifierBytes)
        let objectValue = try args.requiredValue("object")
        let validFrom = try args.optionalInt64("valid_from")
        let validTo = try args.optionalInt64("valid_to")
        let commit = try args.optionalBool("commit") ?? true

        try validateEntityKey(subject, field: "subject")
        try validatePredicateKey(predicate, field: "predicate")
        let object = try parseFactValue(objectValue)

        let factID = try await memory.assertFact(
            subject: EntityKey(subject),
            predicate: PredicateKey(predicate),
            object: object,
            validFromMs: validFrom,
            validToMs: validTo,
            commit: commit
        )
        return jsonResult([
            "status": "ok",
            "fact_id": value(from: factID.rawValue),
            "committed": value(from: commit),
        ])
    }

    private static func factRetract(
        arguments: [String: Value]?,
        memory: MemoryOrchestrator
    ) async throws -> CallTool.Result {
        let args = ToolArguments(arguments)
        let factIDRaw = try args.requiredInt64("fact_id")
        let atMs = try args.optionalInt64("at_ms")
        let commit = try args.optionalBool("commit") ?? true
        try await memory.retractFact(
            factId: FactRowID(rawValue: factIDRaw),
            atMs: atMs,
            commit: commit
        )
        return jsonResult([
            "status": "ok",
            "fact_id": value(from: factIDRaw),
            "committed": value(from: commit),
        ])
    }

    private static func factsQuery(
        arguments: [String: Value]?,
        memory: MemoryOrchestrator
    ) async throws -> CallTool.Result {
        let args = ToolArguments(arguments)
        let subjectRaw = try args.optionalString("subject")
        if let subjectRaw {
            try validateEntityKey(subjectRaw, field: "subject")
        }
        let predicateRaw = try args.optionalString("predicate")
        if let predicateRaw {
            try validatePredicateKey(predicateRaw, field: "predicate")
        }
        let subject = subjectRaw.map { EntityKey($0) }
        let predicate = predicateRaw.map { PredicateKey($0) }
        let asOf = try args.optionalInt64("as_of") ?? Int64.max
        let limit = try args.optionalInt("limit") ?? 20
        guard limit > 0, limit <= maxGraphLimit else {
            throw ToolValidationError.invalid("limit must be between 1 and \(maxGraphLimit)")
        }

        let result = try await memory.facts(
            about: subject,
            predicate: predicate,
            asOfMs: asOf,
            limit: limit
        )

        let hits = result.hits.map { hit -> Value in
            [
                "fact_id": value(from: hit.factId.rawValue),
                "subject": value(from: hit.fact.subject.rawValue),
                "predicate": value(from: hit.fact.predicate.rawValue),
                "object": valueFromFactValue(hit.fact.object),
                "is_open_ended": value(from: hit.isOpenEnded),
                "evidence_count": value(from: hit.evidence.count),
            ]
        }

        return jsonResult([
            "count": value(from: result.hits.count),
            "truncated": value(from: result.wasTruncated),
            "hits": .array(hits),
        ])
    }

    private static func entityResolve(
        arguments: [String: Value]?,
        memory: MemoryOrchestrator
    ) async throws -> CallTool.Result {
        let args = ToolArguments(arguments)
        let alias = try args.requiredString("alias", maxBytes: maxContentBytes)
        let limit = try args.optionalInt("limit") ?? 10
        guard limit > 0, limit <= 100 else {
            throw ToolValidationError.invalid("limit must be between 1 and 100")
        }
        let matches = try await memory.resolveEntities(matchingAlias: alias, limit: limit)
        let payload = matches.map { match -> Value in
            [
                "id": value(from: match.id),
                "key": value(from: match.key.rawValue),
                "kind": value(from: match.kind),
            ]
        }
        return jsonResult([
            "count": value(from: matches.count),
            "entities": .array(payload),
        ])
    }

    private static func parseSessionFrameFilter(_ args: ToolArguments) throws -> FrameFilter? {
        guard let sessionID = try parseOptionalSessionID(args) else { return nil }
        return FrameFilter(
            metadataFilter: MetadataFilter(requiredEntries: ["session_id": sessionID.uuidString])
        )
    }

    private static func parseOptionalSessionID(_ args: ToolArguments) throws -> UUID? {
        guard let sessionID = try args.optionalString("session_id") else { return nil }
        guard let parsed = UUID(uuidString: sessionID) else {
            throw ToolValidationError.invalid("session_id must be a valid UUID")
        }
        return parsed
    }

    private static func parseFactValue(_ value: Value) throws -> FactValue {
        switch value {
        case .string(let string):
            return .string(string)
        case .int(let int):
            return .int(Int64(int))
        case .double(let double):
            guard double.isFinite else {
                throw ToolValidationError.invalid("object must be finite")
            }
            return .double(double)
        case .bool(let bool):
            return .bool(bool)
        case .object(let object):
            return try parseTypedFactObject(object)
        default:
            throw ToolValidationError.invalid(
                "object must be a primitive or typed object ({entity}, {time_ms}, {data_base64}, or {type,value})"
            )
        }
    }

    private static func parseTypedFactObject(_ object: [String: Value]) throws -> FactValue {
        if let type = valueAsString(object["type"]) {
            guard let wrapped = object["value"] else {
                throw ToolValidationError.invalid("object.value is required when object.type is provided")
            }
            return try parseTypedFactEnvelope(type: type, value: wrapped)
        }

        if let entity = valueAsString(object["entity"]) {
            try validateEntityKey(entity, field: "object.entity")
            return .entity(EntityKey(entity))
        }

        if let timeMs = try valueAsInt64(object["time_ms"], field: "object.time_ms") {
            return .timeMs(timeMs)
        }

        if let base64 = valueAsString(object["data_base64"]) {
            guard let decoded = Data(base64Encoded: base64) else {
                throw ToolValidationError.invalid("object.data_base64 must be valid base64")
            }
            return .data(decoded)
        }

        throw ToolValidationError.invalid(
            "typed object must be one of: {entity}, {time_ms}, {data_base64}, or {type,value}"
        )
    }

    private static func parseTypedFactEnvelope(type: String, value: Value) throws -> FactValue {
        switch type.lowercased() {
        case "entity":
            guard case .string(let raw) = value else {
                throw ToolValidationError.invalid("object.value must be a string when object.type=entity")
            }
            try validateEntityKey(raw, field: "object.value")
            return .entity(EntityKey(raw))
        case "time_ms":
            let timestamp = try valueAsInt64(value, field: "object.value")
            guard let timestamp else {
                throw ToolValidationError.invalid("object.value must be an integer when object.type=time_ms")
            }
            return .timeMs(timestamp)
        case "data_base64":
            guard case .string(let base64) = value else {
                throw ToolValidationError.invalid("object.value must be a string when object.type=data_base64")
            }
            guard let decoded = Data(base64Encoded: base64) else {
                throw ToolValidationError.invalid("object.value must be valid base64 when object.type=data_base64")
            }
            return .data(decoded)
        case "string":
            guard case .string(let raw) = value else {
                throw ToolValidationError.invalid("object.value must be a string when object.type=string")
            }
            return .string(raw)
        case "int", "integer":
            let intValue = try valueAsInt64(value, field: "object.value")
            guard let intValue else {
                throw ToolValidationError.invalid("object.value must be an integer when object.type=int")
            }
            return .int(intValue)
        case "double", "number":
            guard let double = valueAsDouble(value), double.isFinite else {
                throw ToolValidationError.invalid("object.value must be a finite number when object.type=double")
            }
            return .double(double)
        case "bool", "boolean":
            guard case .bool(let bool) = value else {
                throw ToolValidationError.invalid("object.value must be a boolean when object.type=bool")
            }
            return .bool(bool)
        default:
            throw ToolValidationError.invalid(
                "object.type must be one of: entity, time_ms, data_base64, string, int, double, bool"
            )
        }
    }

    private static func valueFromFactValue(_ factValue: FactValue) -> Value {
        switch factValue {
        case .string(let string):
            return .string(string)
        case .int(let int):
            return value(from: int)
        case .double(let double):
            return value(from: double)
        case .bool(let bool):
            return value(from: bool)
        case .data(let data):
            return .object([
                "data_base64": .string(data.base64EncodedString()),
            ])
        case .timeMs(let timestamp):
            return .object([
                "time_ms": value(from: timestamp),
            ])
        case .entity(let key):
            return .object([
                "entity": .string(key.rawValue),
            ])
        }
    }

    private static func validateEntityKey(_ value: String, field: String) throws {
        try validateGraphIdentifier(value, field: field, requireNamespace: true)
    }

    private static func validatePredicateKey(_ value: String, field: String) throws {
        try validateGraphIdentifier(value, field: field, requireNamespace: false)
    }

    private static func validateGraphIdentifier(
        _ value: String,
        field: String,
        requireNamespace: Bool
    ) throws {
        guard !value.isEmpty else {
            throw ToolValidationError.invalid("\(field) must not be empty")
        }
        guard value.utf8.count <= maxGraphIdentifierBytes else {
            throw ToolValidationError.invalid("\(field) exceeds max size (\(maxGraphIdentifierBytes) bytes)")
        }
        guard value.unicodeScalars.allSatisfy({ graphIdentifierAllowedScalars.contains($0) }) else {
            throw ToolValidationError.invalid(
                "\(field) contains invalid characters; allowed: letters, digits, ., _, :, -"
            )
        }
        if requireNamespace {
            let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
                throw ToolValidationError.invalid("\(field) must be namespaced as '<namespace>:<id>'")
            }
        }
    }

    private static func validateGraphKind(_ value: String, field: String) throws {
        guard !value.isEmpty else {
            throw ToolValidationError.invalid("\(field) must not be empty")
        }
        guard value.utf8.count <= maxGraphKindBytes else {
            throw ToolValidationError.invalid("\(field) exceeds max size (\(maxGraphKindBytes) bytes)")
        }
        guard value.unicodeScalars.allSatisfy({ graphKindAllowedScalars.contains($0) }) else {
            throw ToolValidationError.invalid(
                "\(field) contains invalid characters; allowed: letters, digits, ., _, -"
            )
        }
    }

    private static func valueAsString(_ value: Value?) -> String? {
        guard let value else { return nil }
        guard case .string(let string) = value else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func valueAsInt64(_ value: Value?, field: String) throws -> Int64? {
        guard let value else { return nil }
        switch value {
        case .int(let int):
            return Int64(int)
        case .double(let double):
            guard double.isFinite else {
                throw ToolValidationError.invalid("\(field) must be an integer")
            }
            let truncated = double.rounded(.towardZero)
            guard truncated == double else {
                throw ToolValidationError.invalid("\(field) must be an integer")
            }
            guard truncated >= Double(Int64.min), truncated <= Double(Int64.max) else {
                throw ToolValidationError.invalid("\(field) is out of range")
            }
            return Int64(truncated)
        case .string(let string):
            guard let parsed = Int64(string) else {
                throw ToolValidationError.invalid("\(field) must be an integer, got '\(string)'")
            }
            return parsed
        default:
            return nil
        }
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
                    resource: .text(json, uri: "wax://tool/result", mimeType: "application/json")
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
        let json = encodeJSON(payload) ?? "{\"code\":\(escapeJSONString(code)),\"message\":\(escapeJSONString(message))}"
        return CallTool.Result(
            content: [
                .text(message),
                .resource(
                    resource: .text(json, uri: "wax://errors/\(code)", mimeType: "application/json")
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

    /// Wraps a string in double-quotes with proper JSON escaping.
    /// Used as a fallback when `encodeJSON` fails.
    private static func escapeJSONString(_ value: String) -> String {
        var result = "\""
        for char in value {
            switch char {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default: result.append(char)
            }
        }
        result += "\""
        return result
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

    private static func value(from value: Int64) -> Value {
        if value >= Int64(Int.min), value <= Int64(Int.max) {
            return .int(Int(value))
        }
        return .string(String(value))
    }

    private static func value(from value: Double) -> Value {
        if value.isFinite {
            return .double(value)
        }
        // JSON has no representation for NaN/Infinity; return a descriptive
        // string so consumers can see the original value instead of a silent null.
        return .string(String(value))
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
            guard let parsed = Int(string) else {
                throw ToolValidationError.invalid("\(key) must be an integer, got '\(string)'")
            }
            return parsed
        default:
            throw ToolValidationError.invalid("\(key) must be an integer")
        }
    }

    func optionalBool(_ key: String) throws -> Bool? {
        guard let value = values[key] else { return nil }
        switch value {
        case .bool(let bool):
            return bool
        case .string(let raw):
            switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "on":
                return true
            case "0", "false", "no", "off":
                return false
            default:
                throw ToolValidationError.invalid("\(key) must be a boolean")
            }
        default:
            throw ToolValidationError.invalid("\(key) must be a boolean")
        }
    }

    func requiredInt64(_ key: String) throws -> Int64 {
        guard let value = try optionalInt64(key) else {
            throw ToolValidationError.missing(key)
        }
        return value
    }

    func optionalInt64(_ key: String) throws -> Int64? {
        guard let value = values[key] else { return nil }
        switch value {
        case .int(let int):
            return Int64(int)
        case .double(let double):
            guard double.isFinite else {
                throw ToolValidationError.invalid("\(key) must be an integer")
            }
            let truncated = double.rounded(.towardZero)
            guard truncated == double else {
                throw ToolValidationError.invalid("\(key) must be an integer")
            }
            guard truncated >= Double(Int64.min), truncated <= Double(Int64.max) else {
                throw ToolValidationError.invalid("\(key) is out of range")
            }
            return Int64(truncated)
        case .string(let string):
            guard let parsed = Int64(string) else {
                throw ToolValidationError.invalid("\(key) must be an integer, got '\(string)'")
            }
            return parsed
        default:
            throw ToolValidationError.invalid("\(key) must be an integer")
        }
    }

    func requiredValue(_ key: String) throws -> Value {
        guard let value = values[key] else {
            throw ToolValidationError.missing(key)
        }
        return value
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
                throw ToolValidationError.invalid("\(key) must not contain empty values")
            }
            return trimmed
        }
        return parsed
    }

    func optionalStringArray(_ key: String) throws -> [String]? {
        guard values[key] != nil else { return nil }
        return try requiredStringArray(key)
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
