import Foundation

package struct BrokerPayloadDecodeError: Error, LocalizedError, Equatable, Sendable {
    package enum Reason: Equatable, Sendable {
        case payloadNotAnObject
        case missingKey(String)
        case invalidValue(key: String, expected: String)
    }

    package let reason: Reason

    package init(reason: Reason) {
        self.reason = reason
    }

    package var errorDescription: String? {
        switch reason {
        case .payloadNotAnObject:
            return "Broker returned an unexpected payload"
        case .missingKey(let key):
            return "Broker response payload is missing key '\(key)'"
        case .invalidValue(let key, let expected):
            return "Broker response payload key '\(key)' is not \(expected)"
        }
    }
}

package struct BrokerCommandFailedError: Error, LocalizedError, Equatable, Sendable {
    package let message: String

    package init(message: String) {
        self.message = message
    }

    package var errorDescription: String? { message }
}

package struct BrokerRecallRow: Sendable, Equatable {
    package let rank: Int
    package let kind: String?
    package let frameId: UInt64
    package let score: Double
    package let text: String

    package init(rank: Int, kind: String?, frameId: UInt64, score: Double, text: String) {
        self.rank = rank
        self.kind = kind
        self.frameId = frameId
        self.score = score
        self.text = text
    }

    package init(_ payload: [String: AgentBrokerValue]) throws {
        try self.init(
            rank: decodeInt(requiredValue(payload, "rank"), key: "rank"),
            kind: decodeOptionalString(payload["kind"], key: "kind"),
            frameId: decodeUInt64(requiredValue(payload, "frameId"), key: "frameId"),
            score: decodeDouble(requiredValue(payload, "score"), key: "score"),
            text: decodeString(requiredValue(payload, "text"), key: "text")
        )
    }
}

package struct BrokerRecallResult: Sendable, Equatable {
    package let query: String
    package let totalTokens: Int
    package let items: [BrokerRecallRow]

    package init(_ payload: [String: AgentBrokerValue]) throws {
        query = try decodeString(requiredValue(payload, "query"), key: "query")
        totalTokens = try decodeInt(requiredValue(payload, "total_tokens"), key: "total_tokens")
        items = try decodedObjectArray(requiredValue(payload, "results"), key: "results")
            .map(BrokerRecallRow.init)
    }
}

package struct BrokerSearchRow: Sendable, Equatable {
    package let rank: Int
    package let frameId: UInt64
    package let score: Double
    package let sources: [String]
    package let preview: String

    package init(
        rank: Int,
        frameId: UInt64,
        score: Double,
        sources: [String],
        preview: String
    ) {
        self.rank = rank
        self.frameId = frameId
        self.score = score
        self.sources = sources
        self.preview = preview
    }

    package init(_ payload: [String: AgentBrokerValue]) throws {
        try self.init(
            rank: decodeInt(requiredValue(payload, "rank"), key: "rank"),
            frameId: decodeUInt64(requiredValue(payload, "frameId"), key: "frameId"),
            score: decodeDouble(requiredValue(payload, "score"), key: "score"),
            sources: decodedStringArray(requiredValue(payload, "sources"), key: "sources"),
            preview: decodeString(requiredValue(payload, "preview"), key: "preview")
        )
    }
}

package struct BrokerSearchResult: Sendable, Equatable {
    package let items: [BrokerSearchRow]

    package init(_ payload: [String: AgentBrokerValue]) throws {
        items = try decodedObjectArray(requiredValue(payload, "results"), key: "results")
            .map(BrokerSearchRow.init)
    }
}

package struct BrokerRememberResult: Sendable, Equatable {
    package let framesAdded: Int
    package let frameCount: Int
    package let pendingFrames: Int

    package init(framesAdded: Int, frameCount: Int, pendingFrames: Int) {
        self.framesAdded = framesAdded
        self.frameCount = frameCount
        self.pendingFrames = pendingFrames
    }

    package init(_ payload: [String: AgentBrokerValue]) throws {
        framesAdded = try decodeInt(requiredValue(payload, "framesAdded"), key: "framesAdded")
        frameCount = try decodeInt(requiredValue(payload, "frameCount"), key: "frameCount")
        pendingFrames = try decodeInt(requiredValue(payload, "pendingFrames"), key: "pendingFrames")
    }
}

package struct BrokerStatsSummary: Sendable, Equatable {
    package let storePath: String?
    package let frameCount: Int
    package let pendingFrames: Int
    package let generation: Int
    package let diskBytes: Int64
    package let vectorSearchEnabled: Bool
    package let embeddingStatus: String?

    package init(_ payload: [String: AgentBrokerValue]) throws {
        storePath = try decodeOptionalString(payload["storePath"], key: "storePath")
        frameCount = try decodeInt(requiredValue(payload, "frameCount"), key: "frameCount")
        pendingFrames = try decodeInt(requiredValue(payload, "pendingFrames"), key: "pendingFrames")
        generation = try decodeInt(requiredValue(payload, "generation"), key: "generation")
        diskBytes = try decodeInt64(requiredValue(payload, "diskBytes"), key: "diskBytes")
        vectorSearchEnabled = try decodeBool(requiredValue(payload, "vectorSearchEnabled"), key: "vectorSearchEnabled")
        embeddingStatus = try decodeOptionalString(payload["embeddingStatus"], key: "embeddingStatus")
    }
}

package struct BrokerStatsResponse: Sendable, Equatable {
    package let summary: BrokerStatsSummary
    package let payload: [String: AgentBrokerValue]

    package init(_ payload: [String: AgentBrokerValue]) throws {
        summary = try BrokerStatsSummary(payload)
        self.payload = payload
    }
}

private func requiredValue(
    _ payload: [String: AgentBrokerValue],
    _ key: String
) throws -> AgentBrokerValue {
    guard let value = payload[key] else {
        throw BrokerPayloadDecodeError(reason: .missingKey(key))
    }
    return value
}

private func decodeString(_ value: AgentBrokerValue, key: String) throws -> String {
    guard let string = value.stringValue else {
        throw BrokerPayloadDecodeError(reason: .invalidValue(key: key, expected: "a string"))
    }
    return string
}

private func decodeOptionalString(_ value: AgentBrokerValue?, key: String) throws -> String? {
    guard let value else { return nil }
    if case .null = value { return nil }
    return try decodeString(value, key: key)
}

private func decodeInt(_ value: AgentBrokerValue, key: String) throws -> Int {
    guard let raw = value.intValue, let integer = Int(exactly: raw) else {
        throw BrokerPayloadDecodeError(reason: .invalidValue(key: key, expected: "an integer"))
    }
    return integer
}

private func decodeInt64(_ value: AgentBrokerValue, key: String) throws -> Int64 {
    guard let raw = value.intValue else {
        throw BrokerPayloadDecodeError(reason: .invalidValue(key: key, expected: "an integer"))
    }
    return raw
}

private func decodeUInt64(_ value: AgentBrokerValue, key: String) throws -> UInt64 {
    guard let raw = value.intValue, let unsigned = UInt64(exactly: raw) else {
        throw BrokerPayloadDecodeError(reason: .invalidValue(key: key, expected: "a non-negative integer"))
    }
    return unsigned
}

private func decodeDouble(_ value: AgentBrokerValue, key: String) throws -> Double {
    guard let double = value.doubleValue else {
        throw BrokerPayloadDecodeError(reason: .invalidValue(key: key, expected: "a number"))
    }
    return double
}

private func decodeBool(_ value: AgentBrokerValue, key: String) throws -> Bool {
    guard let bool = value.boolValue else {
        throw BrokerPayloadDecodeError(reason: .invalidValue(key: key, expected: "a boolean"))
    }
    return bool
}

private func decodedObjectArray(
    _ value: AgentBrokerValue,
    key: String
) throws -> [[String: AgentBrokerValue]] {
    guard let elements = value.arrayValue else {
        throw BrokerPayloadDecodeError(reason: .invalidValue(key: key, expected: "an array"))
    }
    return try elements.map { element in
        guard let object = element.objectValue else {
            throw BrokerPayloadDecodeError(reason: .invalidValue(key: key, expected: "objects"))
        }
        return object
    }
}

private func decodedStringArray(_ value: AgentBrokerValue, key: String) throws -> [String] {
    guard let elements = value.arrayValue else {
        throw BrokerPayloadDecodeError(reason: .invalidValue(key: key, expected: "an array"))
    }
    return try elements.enumerated().map { index, element in
        guard let string = element.stringValue else {
            throw BrokerPayloadDecodeError(
                reason: .invalidValue(key: "\(key)[\(index)]", expected: "a string")
            )
        }
        return string
    }
}

fileprivate extension AgentBrokerClient {
    static func performCommand(
        _ request: AgentBrokerRequest,
        configuration: AgentBrokerConfiguration,
        shutdownIfStarted: Bool
    ) async throws -> [String: AgentBrokerValue] {
        let response = try await perform(
            request: request,
            configuration: configuration,
            shutdownIfStarted: shutdownIfStarted
        )
        guard response.ok else {
            throw BrokerCommandFailedError(message: response.error ?? "Broker command failed")
        }
        guard let payload = response.payload, let object = payload.objectValue else {
            throw BrokerPayloadDecodeError(reason: .payloadNotAnObject)
        }
        return object
    }
}

package extension AgentBrokerClient {
    static func performRecall(
        query: String,
        limit: Int,
        configuration: AgentBrokerConfiguration,
        shutdownIfStarted: Bool = true
    ) async throws -> BrokerRecallResult {
        try BrokerRecallResult(
            try await performCommand(
                AgentBrokerRequest(
                    command: "recall",
                    arguments: [
                        "query": .string(query),
                        "limit": .from(limit),
                    ]
                ),
                configuration: configuration,
                shutdownIfStarted: shutdownIfStarted
            )
        )
    }

    static func performSearch(
        query: String,
        mode: String,
        topK: Int,
        configuration: AgentBrokerConfiguration,
        shutdownIfStarted: Bool = true
    ) async throws -> BrokerSearchResult {
        try BrokerSearchResult(
            try await performCommand(
                AgentBrokerRequest(
                    command: "search",
                    arguments: [
                        "query": .string(query),
                        "mode": .string(mode),
                        "topK": .from(topK),
                    ]
                ),
                configuration: configuration,
                shutdownIfStarted: shutdownIfStarted
            )
        )
    }

    static func performRemember(
        content: String,
        metadata: [String: String],
        configuration: AgentBrokerConfiguration,
        shutdownIfStarted: Bool = true
    ) async throws -> BrokerRememberResult {
        try BrokerRememberResult(
            try await performCommand(
                AgentBrokerRequest(
                    command: "remember",
                    arguments: [
                        "content": .string(content),
                        "metadata": .object(metadata.mapValues(AgentBrokerValue.string)),
                    ]
                ),
                configuration: configuration,
                shutdownIfStarted: shutdownIfStarted
            )
        )
    }

    static func performStats(
        configuration: AgentBrokerConfiguration,
        shutdownIfStarted: Bool = true
    ) async throws -> BrokerStatsResponse {
        try BrokerStatsResponse(
            try await performCommand(
                AgentBrokerRequest(command: "stats", arguments: [:]),
                configuration: configuration,
                shutdownIfStarted: shutdownIfStarted
            )
        )
    }
}
