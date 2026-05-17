import Foundation

package struct BrokerSessionManifest: Codable, Sendable, Equatable {
    package enum Status: String, Codable, Sendable {
        case active
        case ended
    }

    package var sessionID: UUID
    package var agentID: String
    package var runID: String
    package var project: String?
    package var repo: String?
    package var storePath: String
    package var eventLogPath: String
    package var status: Status
    package var brokerLeaseOwnerID: String?
    package var leaseExpiresAtMs: Int64?
    package var createdAtMs: Int64
    package var updatedAtMs: Int64
    package var lastCheckpointAtMs: Int64?
    package var checkpointCount: Int
    package var lastHandoffAtMs: Int64?
    package var lastCompactionAtMs: Int64?
    package var latestSummary: String?
    package var latestHandoff: String?

    package init(
        sessionID: UUID,
        agentID: String,
        runID: String,
        project: String?,
        repo: String?,
        storePath: String,
        eventLogPath: String,
        status: Status,
        brokerLeaseOwnerID: String?,
        leaseExpiresAtMs: Int64?,
        createdAtMs: Int64,
        updatedAtMs: Int64,
        lastCheckpointAtMs: Int64? = nil,
        checkpointCount: Int = 0,
        lastHandoffAtMs: Int64? = nil,
        lastCompactionAtMs: Int64? = nil,
        latestSummary: String? = nil,
        latestHandoff: String? = nil
    ) {
        self.sessionID = sessionID
        self.agentID = agentID
        self.runID = runID
        self.project = project
        self.repo = repo
        self.storePath = storePath
        self.eventLogPath = eventLogPath
        self.status = status
        self.brokerLeaseOwnerID = brokerLeaseOwnerID
        self.leaseExpiresAtMs = leaseExpiresAtMs
        self.createdAtMs = createdAtMs
        self.updatedAtMs = updatedAtMs
        self.lastCheckpointAtMs = lastCheckpointAtMs
        self.checkpointCount = checkpointCount
        self.lastHandoffAtMs = lastHandoffAtMs
        self.lastCompactionAtMs = lastCompactionAtMs
        self.latestSummary = latestSummary
        self.latestHandoff = latestHandoff
    }
}

package struct BrokerSessionEvent: Codable, Sendable, Equatable {
    package enum Kind: String, Codable, Sendable {
        case started
        case resumed
        case remembered
        case retrievalHit
        case handoff
        case checkpoint
        case promotionReviewed
        case promotionWritten
        case markdownExported
        case ended
    }

    package var sessionID: UUID
    package var agentID: String
    package var runID: String
    package var timestampMs: Int64
    package var kind: Kind
    package var payload: [String: String]

    package init(
        sessionID: UUID,
        agentID: String,
        runID: String,
        timestampMs: Int64,
        kind: Kind,
        payload: [String: String] = [:]
    ) {
        self.sessionID = sessionID
        self.agentID = agentID
        self.runID = runID
        self.timestampMs = timestampMs
        self.kind = kind
        self.payload = payload
    }
}

package struct BrokerSessionRecallSignals: Sendable, Equatable {
    package var recallCount: Int
    package var uniqueQueryCount: Int
    package var lastRetrievedAtMs: Int64?
    package var averageScore: Float

    package init(
        recallCount: Int = 0,
        uniqueQueryCount: Int = 0,
        lastRetrievedAtMs: Int64? = nil,
        averageScore: Float = 0
    ) {
        self.recallCount = recallCount
        self.uniqueQueryCount = uniqueQueryCount
        self.lastRetrievedAtMs = lastRetrievedAtMs
        self.averageScore = averageScore
    }
}

package enum BrokerSessionPersistence {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder = JSONDecoder()

    package static func manifestURL(rootURL: URL, sessionID: UUID) -> URL {
        rootURL.appendingPathComponent("\(sessionID.uuidString).json")
    }

    package static func eventLogURL(rootURL: URL, sessionID: UUID) -> URL {
        rootURL.appendingPathComponent("\(sessionID.uuidString).events.jsonl")
    }

    package static func saveManifest(_ manifest: BrokerSessionManifest, to url: URL) throws {
        let data = try encoder.encode(manifest)
        try data.write(to: url, options: .atomic)
    }

    package static func loadManifest(at url: URL) throws -> BrokerSessionManifest {
        let data = try Data(contentsOf: url)
        return try decoder.decode(BrokerSessionManifest.self, from: data)
    }

    package static func loadManifest(rootURL: URL, sessionID: UUID) throws -> BrokerSessionManifest {
        try loadManifest(at: manifestURL(rootURL: rootURL, sessionID: sessionID))
    }

    package static func listManifests(rootURL: URL) throws -> [BrokerSessionManifest] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }

        return try urls.map(loadManifest(at:)).sorted { lhs, rhs in
            if lhs.updatedAtMs != rhs.updatedAtMs { return lhs.updatedAtMs > rhs.updatedAtMs }
            return lhs.sessionID.uuidString < rhs.sessionID.uuidString
        }
    }

    package static func appendEvent(_ event: BrokerSessionEvent, to url: URL) throws {
        let line = try encoder.encode(event) + Data([0x0A])
        if !FileManager.default.fileExists(atPath: url.path) {
            try line.write(to: url, options: .withoutOverwriting)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    package static func loadEvents(from url: URL) throws -> [BrokerSessionEvent] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return [] }

        var events: [BrokerSessionEvent] = []
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            events.append(try decoder.decode(BrokerSessionEvent.self, from: Data(line)))
        }
        return events
    }

    package static func recallSignals(
        from events: [BrokerSessionEvent]
    ) -> [UInt64: BrokerSessionRecallSignals] {
        var queryHashesByFrameID: [UInt64: Set<String>] = [:]
        var recallsByFrameID: [UInt64: Int] = [:]
        var lastRetrievedByFrameID: [UInt64: Int64] = [:]
        var scoreTotalsByFrameID: [UInt64: Float] = [:]

        for event in events where event.kind == .retrievalHit {
            guard let rawFrameID = event.payload["frame_id"],
                  let frameID = UInt64(rawFrameID) else {
                continue
            }
            recallsByFrameID[frameID, default: 0] += 1
            if let queryHash = event.payload["query_hash"], !queryHash.isEmpty {
                queryHashesByFrameID[frameID, default: []].insert(queryHash)
            }
            if let current = lastRetrievedByFrameID[frameID] {
                lastRetrievedByFrameID[frameID] = max(current, event.timestampMs)
            } else {
                lastRetrievedByFrameID[frameID] = event.timestampMs
            }
            if let rawScore = event.payload["score"], let score = Float(rawScore) {
                scoreTotalsByFrameID[frameID, default: 0] += score
            }
        }

        let frameIDs = Set(recallsByFrameID.keys).union(queryHashesByFrameID.keys).union(lastRetrievedByFrameID.keys)
        return frameIDs.reduce(into: [:]) { partial, frameID in
            let recallCount = recallsByFrameID[frameID, default: 0]
            partial[frameID] = BrokerSessionRecallSignals(
                recallCount: recallCount,
                uniqueQueryCount: queryHashesByFrameID[frameID]?.count ?? 0,
                lastRetrievedAtMs: lastRetrievedByFrameID[frameID],
                averageScore: recallCount > 0 ? (scoreTotalsByFrameID[frameID, default: 0] / Float(recallCount)) : 0
            )
        }
    }
}
