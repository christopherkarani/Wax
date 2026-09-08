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
    package var endedAtMs: Int64?
    package var harvestedAtMs: Int64?
    package var promotedCount: Int
    package var reclaimAfterMs: Int64?
    package var reclaimedAtMs: Int64?
    package var harvestError: String?
    package var conversationID: String?

    private enum CodingKeys: String, CodingKey {
        case sessionID
        case agentID
        case runID
        case project
        case repo
        case storePath
        case eventLogPath
        case status
        case brokerLeaseOwnerID
        case leaseExpiresAtMs
        case createdAtMs
        case updatedAtMs
        case lastCheckpointAtMs
        case checkpointCount
        case lastHandoffAtMs
        case lastCompactionAtMs
        case latestSummary
        case latestHandoff
        case endedAtMs
        case harvestedAtMs
        case promotedCount
        case reclaimAfterMs
        case reclaimedAtMs
        case harvestError
        case conversationID
    }

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
        latestHandoff: String? = nil,
        endedAtMs: Int64? = nil,
        harvestedAtMs: Int64? = nil,
        promotedCount: Int = 0,
        reclaimAfterMs: Int64? = nil,
        reclaimedAtMs: Int64? = nil,
        harvestError: String? = nil,
        conversationID: String? = nil
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
        self.endedAtMs = endedAtMs
        self.harvestedAtMs = harvestedAtMs
        self.promotedCount = promotedCount
        self.reclaimAfterMs = reclaimAfterMs
        self.reclaimedAtMs = reclaimedAtMs
        self.harvestError = harvestError
        self.conversationID = conversationID
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(UUID.self, forKey: .sessionID)
        agentID = try container.decode(String.self, forKey: .agentID)
        runID = try container.decode(String.self, forKey: .runID)
        project = try container.decodeIfPresent(String.self, forKey: .project)
        repo = try container.decodeIfPresent(String.self, forKey: .repo)
        storePath = try container.decode(String.self, forKey: .storePath)
        eventLogPath = try container.decode(String.self, forKey: .eventLogPath)
        status = try container.decode(Status.self, forKey: .status)
        brokerLeaseOwnerID = try container.decodeIfPresent(String.self, forKey: .brokerLeaseOwnerID)
        leaseExpiresAtMs = try container.decodeIfPresent(Int64.self, forKey: .leaseExpiresAtMs)
        createdAtMs = try container.decode(Int64.self, forKey: .createdAtMs)
        updatedAtMs = try container.decode(Int64.self, forKey: .updatedAtMs)
        lastCheckpointAtMs = try container.decodeIfPresent(Int64.self, forKey: .lastCheckpointAtMs)
        checkpointCount = try container.decodeIfPresent(Int.self, forKey: .checkpointCount) ?? 0
        lastHandoffAtMs = try container.decodeIfPresent(Int64.self, forKey: .lastHandoffAtMs)
        lastCompactionAtMs = try container.decodeIfPresent(Int64.self, forKey: .lastCompactionAtMs)
        latestSummary = try container.decodeIfPresent(String.self, forKey: .latestSummary)
        latestHandoff = try container.decodeIfPresent(String.self, forKey: .latestHandoff)
        endedAtMs = try container.decodeIfPresent(Int64.self, forKey: .endedAtMs)
        harvestedAtMs = try container.decodeIfPresent(Int64.self, forKey: .harvestedAtMs)
        promotedCount = try container.decodeIfPresent(Int.self, forKey: .promotedCount) ?? 0
        reclaimAfterMs = try container.decodeIfPresent(Int64.self, forKey: .reclaimAfterMs)
        reclaimedAtMs = try container.decodeIfPresent(Int64.self, forKey: .reclaimedAtMs)
        harvestError = try container.decodeIfPresent(String.self, forKey: .harvestError)
        conversationID = try container.decodeIfPresent(String.self, forKey: .conversationID)
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

package enum BrokerSessionPersistenceError: LocalizedError, Equatable {
    case manifestNotFound(sessionID: UUID)
    case manifestUnreadable(sessionID: UUID?)

    package var errorDescription: String? {
        switch self {
        case .manifestNotFound(let sessionID):
            return "No session manifest found for session_id \(sessionID.uuidString)"
        case .manifestUnreadable(let sessionID):
            if let sessionID {
                return "Unable to read session manifest for session_id \(sessionID.uuidString)"
            }
            return "Unable to read session manifest"
        }
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
        let sessionID = UUID(uuidString: url.deletingPathExtension().lastPathComponent)
        guard FileManager.default.fileExists(atPath: url.path) else {
            if let sessionID {
                throw BrokerSessionPersistenceError.manifestNotFound(sessionID: sessionID)
            }
            throw BrokerSessionPersistenceError.manifestUnreadable(sessionID: nil)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw BrokerSessionPersistenceError.manifestUnreadable(sessionID: sessionID)
        }
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

        let sessionManifestURLs = urls.filter { url in
            UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil
        }
        return try sessionManifestURLs.map(loadManifest(at:)).sorted { lhs, rhs in
            if lhs.updatedAtMs != rhs.updatedAtMs { return lhs.updatedAtMs > rhs.updatedAtMs }
            return lhs.sessionID.uuidString < rhs.sessionID.uuidString
        }
    }

    package static func findActive(
        conversationID: String,
        agentID: String? = nil,
        project: String? = nil,
        repo: String? = nil,
        rootURL: URL
    ) throws -> BrokerSessionManifest? {
        let trimmed = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let matches = try listManifests(rootURL: rootURL).filter { manifest in
            guard manifest.status == .active, manifest.conversationID == trimmed else {
                return false
            }
            if let agentID, manifest.agentID != agentID { return false }
            if let project, manifest.project != project { return false }
            if let repo, manifest.repo != repo { return false }
            return true
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
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
            guard let event = try? decoder.decode(BrokerSessionEvent.self, from: Data(line)) else {
                continue
            }
            events.append(event)
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
