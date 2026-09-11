import Foundation

/// Remember response assembly and durable auto-supersede selection policy.
/// Store I/O (`remember`, `supersede`, `flush`, session events) stays on the broker.
package enum RememberAssembly {
    package static let autoSupersedeSimilarityThreshold: Float = 0.88
    package static let autoSupersedeMaxMatches = 32
    package static let autoSupersedeTypes: Set<MemoryType> = [
        .decision, .lesson, .constraint, .fact, .userPreference,
    ]

    /// Corpus row shape for pure supersede selection (no orchestrator dependency).
    package struct Candidate: Sendable, Equatable {
        package var frameId: UInt64
        package var text: String
        package var metadata: [String: String]

        package init(frameId: UInt64, text: String, metadata: [String: String]) {
            self.frameId = frameId
            self.text = text
            self.metadata = metadata
        }
    }

    /// Wire payload for a completed remember. Keys stay stable for MCP/CLI clients.
    ///
    /// `sessionID` is the destination store (nil = durable). `echoedSessionID` is the
    /// bound connection session so durable writes do not look failed (`session_id: null`).
    package static func payload(
        frameId: UInt64,
        framesAdded: UInt64,
        frameCount: UInt64,
        pendingFrames: UInt64,
        sessionID: UUID?,
        echoedSessionID: UUID? = nil,
        metadata: [String: String],
        inferredScope: MemoryScopeContext = MemoryScopeContext(),
        deduplicated: Bool,
        searchable: Bool
    ) -> AgentBrokerValue {
        let scope = sessionID == nil ? "durable" : "session"
        let memoryID = sessionID.map {
            "working:\($0.uuidString):\(frameId)"
        } ?? "durable:\(frameId)"
        let project = metadata[MemoryMetadataKeys.project] ?? inferredScope.projectName
        let repo = metadata[MemoryMetadataKeys.repo] ?? inferredScope.repoName
        let unresolvedProject = project?.isEmpty != false
        var display = "Remembered. \(framesAdded) frame(s) added (\(frameCount) total, \(pendingFrames) pending)."
        if unresolvedProject {
            display += " Project unresolved; default recall will miss this unless you pass project/repo or scope=global."
        }
        var payload: [String: AgentBrokerValue] = [
            "status": .string("ok"),
            "committed": .bool(true),
            "frame_id": .from(frameId),
            "memory_id": .string(memoryID),
            "framesAdded": .from(framesAdded),
            "frameCount": .from(frameCount),
            "pendingFrames": .from(pendingFrames),
            "scope": .string(scope),
            "session_id": .from((echoedSessionID ?? sessionID)?.uuidString),
            "memory_type": .string(metadata[MemoryMetadataKeys.type] ?? MemoryType.note.rawValue),
            "durability": .string(metadata[MemoryMetadataKeys.durability] ?? MemoryDurability.working.rawValue),
            "deduplicated": .bool(deduplicated),
            "searchable": .bool(searchable),
            "unresolved_project": .bool(unresolvedProject),
            "display_text": .string(display),
        ]
        if let project, !project.isEmpty {
            payload["project"] = .string(project)
        }
        if let repo, !repo.isEmpty {
            payload["repo"] = .string(repo)
        }
        if unresolvedProject {
            payload["next_action"] = .string("pass project/repo or recall with scope=global")
        }
        return .object(payload)
    }

    /// Cheap gate before corpus I/O: session writes and non-policy types never scan.
    package static func isAutoSupersedeEligible(
        sessionID: UUID?,
        metadata: [String: String],
        nowMs: Int64
    ) -> Bool {
        guard sessionID == nil else { return false }
        let info = MemorySemantics.parse(metadata: metadata, nowMs: nowMs)
        guard autoSupersedeTypes.contains(info.type) else { return false }
        guard info.durability == .durable || info.durability == .locked else { return false }
        return info.project != nil
    }

    /// Same-project Jaccard ≥ 0.88 retires prior unsuperseded durable twins.
    /// Locked others stay live. Returns candidate frame IDs; broker still supersedes + flushes.
    package static func selectSupersedeFrameIDs(
        sessionID: UUID?,
        newFrameId: UInt64,
        content: String,
        metadata: [String: String],
        documents: [Candidate],
        nowMs: Int64
    ) -> [UInt64] {
        guard isAutoSupersedeEligible(sessionID: sessionID, metadata: metadata, nowMs: nowMs) else {
            return []
        }
        let info = MemorySemantics.parse(metadata: metadata, nowMs: nowMs)
        guard let project = info.project else { return [] }

        var selected: [UInt64] = []
        selected.reserveCapacity(min(documents.count, autoSupersedeMaxMatches))
        for document in documents {
            guard selected.count < autoSupersedeMaxMatches else { break }
            guard document.frameId != newFrameId else { continue }
            let other = MemorySemantics.parse(metadata: document.metadata, nowMs: nowMs)
            guard other.type == info.type else { continue }
            guard other.project == project else { continue }
            guard other.durability == .durable else { continue }
            let similarity = MemorySemantics.similarity(lhs: content, rhs: document.text)
            guard similarity >= autoSupersedeSimilarityThreshold else { continue }
            selected.append(document.frameId)
        }
        return selected
    }
}
