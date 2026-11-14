import Foundation
import WaxCore

/// Closed recall scope together with the working-lane session id after wire decode.
///
/// `.session` requires a UUID. `.project` and `.global` keep an optional working
/// session so MCP can still consult that lane.
package enum RecallIdentity: Sendable, Equatable {
    case project(workingSessionID: UUID?)
    case session(workingSessionID: UUID)
    case global(workingSessionID: UUID?)

    package var scope: LayeredRecall.Scope {
        switch self {
        case .project: return .project
        case .session: return .session
        case .global: return .global
        }
    }

    package var sessionID: UUID? {
        switch self {
        case .project(let sessionID), .global(let sessionID):
            return sessionID
        case .session(let sessionID):
            return sessionID
        }
    }

    package static func make(
        scope: LayeredRecall.Scope,
        sessionID: UUID?
    ) throws -> RecallIdentity {
        switch scope {
        case .project:
            return .project(workingSessionID: sessionID)
        case .session:
            guard let sessionID else {
                throw BrokerValidationError.invalid("scope session requires session_id")
            }
            return .session(workingSessionID: sessionID)
        case .global:
            return .global(workingSessionID: sessionID)
        }
    }
}

/// Post-resolution layered search identity.
///
/// Working requires a session UUID. Unscoped working and empty horizons are not
/// cases — they fail at ``make(sessionID:horizons:)`` / ``unscoped(_:)`` /
/// ``session(sessionID:horizons:)``.
package struct MemorySearchIdentity: Sendable, Equatable {
    private enum Kind: Sendable, Equatable {
        case unscoped(HorizonSet)
        case session(sessionID: UUID, horizons: HorizonSet)
    }

    private let kind: Kind

    package var sessionID: UUID? {
        switch kind {
        case .unscoped:
            return nil
        case .session(let sessionID, _):
            return sessionID
        }
    }

    package var horizons: HorizonSet {
        switch kind {
        case .unscoped(let horizons), .session(_, let horizons):
            return horizons
        }
    }

    /// Non-nil only when a session identity includes `.working`.
    package var workingSessionID: UUID? {
        switch kind {
        case .session(let sessionID, let horizons):
            return horizons.contains(.working) ? sessionID : nil
        case .unscoped:
            return nil
        }
    }

    /// True only on session identity when horizons contain `.working`.
    package var includesWorking: Bool { workingSessionID != nil }

    package static func unscoped(_ horizons: HorizonSet) throws -> MemorySearchIdentity {
        try make(sessionID: nil, horizons: horizons)
    }

    package static func session(
        sessionID: UUID,
        horizons: HorizonSet
    ) throws -> MemorySearchIdentity {
        try make(sessionID: sessionID, horizons: horizons)
    }

    package static func make(
        sessionID: UUID?,
        horizons: HorizonSet
    ) throws -> MemorySearchIdentity {
        guard !horizons.isEmpty else {
            throw BrokerValidationError.invalid(
                "memory search identity requires a non-empty horizon set"
            )
        }
        if let sessionID {
            return MemorySearchIdentity(kind: .session(sessionID: sessionID, horizons: horizons))
        }
        if horizons.contains(.working) {
            throw BrokerValidationError.invalid("working horizon requires a session_id")
        }
        return MemorySearchIdentity(kind: .unscoped(horizons))
    }
}

/// Non-lane retrieval control bits. Ranking reasons stay open explanation strings.
package struct HitFlags: OptionSet, Sendable, Hashable {
    package let rawValue: UInt8

    package init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    package static let ownerCard = HitFlags(rawValue: 1 << 0)
    package static let unlandedDemoted = HitFlags(rawValue: 1 << 1)
}

/// Broker Layered recall: scope/identity, multi-horizon fetch/merge, project filter.
/// Feeds recall, layered search, and Compact assembly.
/// Does not own Ranking scores, Recall assembly packing, Compact assembly packing,
/// MCP payloads, or session rebind.
package enum LayeredRecall {
    package enum Horizon: String, Sendable {
        case working
        case episodic
        case durable
    }

    package enum Scope: String, Sendable {
        case project
        case session
        case global
    }

    package struct Identity: Sendable, Equatable {
        package var project: String?
        package var repo: String?

        package init(project: String? = nil, repo: String? = nil) {
            self.project = project
            self.repo = repo
        }
    }

    package struct Hit: Sendable, Equatable {
        package var id: MemoryID
        package var agentID: String?
        package var runID: String?
        package var conversationID: String?
        package var score: Float
        package var text: String
        package var preview: String
        package var metadata: [String: String]
        package var explanations: [String]
        package var timestampMs: Int64
        package var kind: RAGContext.ItemKind
        package var sources: [RAGContext.Source]
        package var collapsedCount: Int
        package var flags: HitFlags

        package var reference: String { id.wire }
        package var horizon: Horizon { id.horizon }
        package var sessionID: UUID? { id.sessionID }
        package var frameID: UInt64 { id.frameID }

        package init(
            id: MemoryID,
            agentID: String? = nil,
            runID: String? = nil,
            conversationID: String? = nil,
            score: Float,
            text: String,
            preview: String,
            metadata: [String: String],
            explanations: [String],
            timestampMs: Int64,
            kind: RAGContext.ItemKind = .snippet,
            sources: [RAGContext.Source] = [],
            collapsedCount: Int = 1,
            flags: HitFlags = []
        ) {
            self.id = id
            self.agentID = agentID
            self.runID = runID
            self.conversationID = conversationID
            self.score = score
            self.text = text
            self.preview = preview
            self.metadata = metadata
            self.explanations = explanations
            self.timestampMs = timestampMs
            self.kind = kind
            self.sources = sources
            self.collapsedCount = max(1, collapsedCount)
            self.flags = flags
        }
    }

    package typealias MemoryReference = MemoryID

    package struct WorkingLane: Sendable {
        package var sessionID: UUID
        package var agentID: String?
        package var runID: String?
        package var conversationID: String?
        package var updatedAtMs: Int64
        package var project: String?
        package var repo: String?
        package var memory: MemoryOrchestrator

        package init(
            sessionID: UUID,
            agentID: String?,
            runID: String?,
            updatedAtMs: Int64,
            project: String?,
            repo: String?,
            memory: MemoryOrchestrator,
            conversationID: String? = nil
        ) {
            self.sessionID = sessionID
            self.agentID = agentID
            self.runID = runID
            self.conversationID = conversationID
            self.updatedAtMs = updatedAtMs
            self.project = project
            self.repo = repo
            self.memory = memory
        }
    }

    /// Coerced tool args; Layered recall owns what the fields mean.
    package struct RecallRequest: Sendable {
        package var query: String
        package var identity: RecallIdentity
        package var limit: Int
        package var searchTopK: Int
        package var mode: SearchModeRequest?
        package var explicitProject: String?
        package var explicitRepo: String?
        package var clientCWD: String?
        package var frameFilter: FrameFilter?
        package var timeRange: SearchTimeRange?
        package var memoryTypes: [MemoryType]
        package var includeWorking: Bool

        package var scope: Scope { identity.scope }
        package var sessionID: UUID? { identity.sessionID }

        /// Working lane is conversation-scoped: it enters recall only through
        /// an explicit session scope or an explicit `include_working` opt-in.
        /// A merely present session id (project/global identity, MCP injection)
        /// never implies it.
        package var includesWorkingLane: Bool {
            scope == .session || includeWorking
        }

        /// Recall fetches working + durable; episodic stays a memory_search /
        /// compact lane. Gated requests fetch durable only.
        package var fetchHorizons: HorizonSet {
            includesWorkingLane ? [.working, .durable] : [.durable]
        }

        package init(
            query: String,
            identity: RecallIdentity,
            limit: Int,
            searchTopK: Int,
            mode: SearchModeRequest? = nil,
            explicitProject: String? = nil,
            explicitRepo: String? = nil,
            clientCWD: String? = nil,
            frameFilter: FrameFilter? = nil,
            timeRange: SearchTimeRange? = nil,
            memoryTypes: [MemoryType] = [],
            includeWorking: Bool = false
        ) {
            self.query = query
            self.identity = identity
            self.limit = limit
            self.searchTopK = searchTopK
            self.mode = mode
            self.explicitProject = explicitProject
            self.explicitRepo = explicitRepo
            self.clientCWD = clientCWD
            self.frameFilter = frameFilter
            self.timeRange = timeRange
            self.memoryTypes = memoryTypes
            self.includeWorking = includeWorking
        }
    }

    package struct SearchRequest: Sendable {
        package var query: String
        package var mode: SearchModeRequest
        package var topK: Int
        package var identity: MemorySearchIdentity

        package var sessionID: UUID? { identity.sessionID }
        package var horizons: HorizonSet { identity.horizons }

        package init(
            query: String,
            mode: SearchModeRequest,
            topK: Int,
            identity: MemorySearchIdentity
        ) {
            self.query = query
            self.mode = mode
            self.topK = topK
            self.identity = identity
        }

        package init(
            query: String,
            mode: SearchModeRequest,
            topK: Int,
            sessionID: UUID? = nil,
            horizons: HorizonSet
        ) throws {
            try self.init(
                query: query,
                mode: mode,
                topK: topK,
                identity: MemorySearchIdentity.make(sessionID: sessionID, horizons: horizons)
            )
        }
    }

    package struct ScopeDropped: Sendable, Equatable {
        package struct Entry: Sendable, Equatable {
            package var project: String?
            package var repo: String?
            package var score: Float
            package var preview: String

            package init(project: String?, repo: String?, score: Float, preview: String) {
                self.project = project
                self.repo = repo
                self.score = score
                self.preview = preview
            }
        }

        package var count: Int
        package var top: [Entry]
        package var hint: String

        package init(count: Int = 0, top: [Entry] = [], hint: String = "") {
            self.count = count
            self.top = top
            self.hint = hint
        }

        package static let empty = ScopeDropped()
    }

    /// Broker-only retrieval outcome across working/durable lanes.
    /// `"mixed"` / `"n/a"` are wire strings here — they are not
    /// ``RAGContext/QueryEmbeddingState`` cases.
    package enum LaneDiagnostics: Sendable, Equatable {
        case unavailable
        case uniform(RAGContext.Diagnostics)
        case mixed(requested: SearchMode)

        package var wireRequestedMode: String {
            switch self {
            case .unavailable:
                return "n/a"
            case .uniform(let diagnostics):
                return diagnostics.requestedMode.diagnosticsSummary
            case .mixed(let requested):
                return requested.diagnosticsSummary
            }
        }

        package var wireEffectiveMode: String {
            switch self {
            case .unavailable:
                return "n/a"
            case .uniform(let diagnostics):
                return diagnostics.effectiveMode.diagnosticsSummary
            case .mixed:
                return "mixed"
            }
        }

        package var wireQueryEmbeddingState: String {
            switch self {
            case .unavailable:
                return "n/a"
            case .uniform(let diagnostics):
                return diagnostics.queryEmbeddingState.rawValue
            case .mixed:
                return "mixed"
            }
        }
    }

    package struct RecallResult: Sendable {
        package var hits: [Hit]
        package var scope: Scope
        package var identity: Identity
        package var projectMiss: Bool
        package var scopeMissMessage: String?
        package var scopeDropped: ScopeDropped = .empty
        package var diagnostics: LaneDiagnostics
        package var searchTopK: Int
        package var retrievalTopK: Int
        package var limit: Int
        package var collapsed: Int = 0

        package var requestedModeSummary: String { diagnostics.wireRequestedMode }
        package var effectiveModeSummary: String { diagnostics.wireEffectiveMode }
        package var queryEmbeddingState: String { diagnostics.wireQueryEmbeddingState }
    }

    package struct EpisodicLaneHit: Sendable {
        package var frameID: UInt64
        package var score: Float
        package var previewText: String?
        package var metadata: [String: String]
        package var explanations: [String]
        package var canonicalFrameID: UInt64?
        package var recallCount: Int?
        package var uniqueQueryCount: Int?

        package init(
            frameID: UInt64,
            score: Float,
            previewText: String?,
            metadata: [String: String],
            explanations: [String],
            canonicalFrameID: UInt64?,
            recallCount: Int? = nil,
            uniqueQueryCount: Int? = nil
        ) {
            self.frameID = frameID
            self.score = score
            self.previewText = previewText
            self.metadata = metadata
            self.explanations = explanations
            self.canonicalFrameID = canonicalFrameID
            self.recallCount = recallCount
            self.uniqueQueryCount = uniqueQueryCount
        }
    }

    /// Store accessors at the Layered recall seam. Broker supplies these; module owns policy.
    package struct Stores: Sendable {
        package var longTermMemory: MemoryOrchestrator
        package var workingLane: @Sendable (UUID) -> WorkingLane?
        package var inferWriteScope: @Sendable (_ sessionID: UUID?, _ clientCWD: String?) -> Identity
        package var preview: @Sendable (String?) -> String
        package var canonicalFrameID: @Sendable (UInt64, MemoryOrchestrator) async -> UInt64?
        package var endedSessions: any EndedSessionStore
        package var nowMs: @Sendable () -> Int64

        package init(
            longTermMemory: MemoryOrchestrator,
            workingLane: @escaping @Sendable (UUID) -> WorkingLane?,
            inferWriteScope: @escaping @Sendable (UUID?, String?) -> Identity,
            preview: @escaping @Sendable (String?) -> String,
            canonicalFrameID: @escaping @Sendable (UInt64, MemoryOrchestrator) async -> UInt64?,
            endedSessions: any EndedSessionStore,
            nowMs: @escaping @Sendable () -> Int64 = { BrokerClock.nowMs() }
        ) {
            self.longTermMemory = longTermMemory
            self.workingLane = workingLane
            self.inferWriteScope = inferWriteScope
            self.preview = preview
            self.canonicalFrameID = canonicalFrameID
            self.endedSessions = endedSessions
            self.nowMs = nowMs
        }
    }

    package struct HorizonLanes: Sendable {
        package var working: [Hit]
        package var episodic: [Hit]
        package var durable: [Hit]
        package var identity: Identity
        package var workingExecution: MemoryOrchestrator.RecallExecution?
        package var durableExecution: MemoryOrchestrator.RecallExecution?
    }
}
