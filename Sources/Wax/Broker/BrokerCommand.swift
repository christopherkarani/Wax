import Foundation
import WaxCore

/// Closed `knowledge_capture` graph write after wire decode.
/// Incomplete subject/predicate/object triples fail at decode.
package enum KnowledgeGraphWrite: Sendable, Equatable {
    case none
    case entity(key: EntityKey, kind: String, aliases: [String])
    case fact(
        subject: EntityKey,
        predicate: PredicateKey,
        object: FactValue,
        kind: String,
        aliases: [String]
    )
}

/// Typed broker command decoded from the wire (`command` + `arguments`).
///
/// Decode is the single validation + parse boundary. Handlers take typed
/// payloads and do not re-parse argument bags.
package enum BrokerCommand: Sendable, Equatable {
    case remember(Remember)
    case recall(Recall)
    case search(Search)
    case memorySearch(MemorySearch)
    case sessionStart(SessionStart)
    case sessionResume(SessionResume)
    case sessionEnd(SessionEnd)
    case handoff(Handoff)
    case handoffLatest(HandoffLatest)
    case memoryGet(MemoryGet)
    case memoryHealth
    case stats(Stats)
    case flush
    case markdownSync(MarkdownSync)
    case entityUpsert(EntityUpsert)
    case entityResolve(EntityResolve)
    case factRetract(FactRetract)
    /// `shutdown` / `exit` / `quit` — same handler, exits the broker process.
    case shutdown
    case sessionSynthesize(SessionSynthesize)
    case knowledgeCapture(KnowledgeCapture)
    case sessionClose(SessionClose)
    case sessionOpen(SessionOpen)
    case compactContext(CompactContext)
    case markdownExport(MarkdownExport)
    case taskStateMigrate(TaskStateMigrate)
    case factsQuery(FactsQuery)
    case memoryPromote(MemoryPromote)
    case promote(MemoryPromote)
    case factAssert(FactAssert)
    case corpusSearch(CorpusSearch)
    case memoryMaintain(MemoryMaintain)
    /// Readiness probe. Answered without waiting for running commands, so a
    /// broker busy with a long one is not taken for a mute one.
    case ping

    package struct Remember: Sendable, Equatable {
        package var content: String
        package var destination: RememberDestination
        package var metadata: [String: String]
        package var cwd: String?
        /// Wire `session_id`. Durable types may still carry this for project stamp
        /// even though `destination.sessionID` is nil.
        package var clientSessionID: UUID? = nil

        package var sessionID: UUID? { destination.sessionID }
        package var writeSemantics: MemoryWriteSemantics { destination.writeSemantics }
        package var writeScope: RememberWriteScope {
            switch destination {
            case .session: return .session
            case .durable: return .durable
            }
        }
    }

    package struct ParsedSearchFilters: Sendable, Equatable {
        package var sessionId: UUID?
        package var frameFilter: FrameFilter?
        package var timeRange: SearchTimeRange?
        package var summary: AgentBrokerValue
    }

    package struct Recall: Sendable, Equatable {
        package var query: String
        package var limit: Int
        package var searchTopK: Int
        package var identity: RecallIdentity
        package var mode: SearchMode?
        package var filters: ParsedSearchFilters
        package var explicitProject: String?
        package var explicitRepo: String?
        package var clientCWD: String?
        package var verbosity: ResponseVerbosity = .compact
        package var memoryTypes: [MemoryType] = []
        package var includeWorking: Bool = false

        package var scope: LayeredRecall.Scope { identity.scope }
        /// Working-lane session. Wire `filters.sessionId` is a parse snapshot and
        /// must not be used as a second source of truth after decode.
        package var sessionID: UUID? { identity.sessionID }
    }

    package struct Search: Sendable, Equatable {
        package var query: String
        package var mode: SearchMode
        package var topK: Int
        package var filters: ParsedSearchFilters
    }

    package struct MemorySearch: Sendable, Equatable {
        package var query: String
        package var mode: SearchMode
        package var topK: Int
        /// Wire `session_id` before handler resolution. Omitted id may still mean
        /// the one live session; do not treat this pair as ``MemorySearchIdentity``.
        package var clientSessionID: UUID?
        package var requestedHorizons: HorizonSet

        package var sessionID: UUID? { clientSessionID }
        package var horizons: HorizonSet { requestedHorizons }
    }

    package struct SessionStart: Sendable, Equatable {
        package var sessionID: UUID?
        package var agentID: String?
        package var runID: String?
        package var cwd: String?
        package var project: String?
        package var repo: String?
        package var conversationID: String? = nil
    }

    package struct SessionResume: Sendable, Equatable {
        package var sessionID: UUID?
        package var agentID: String?
        package var runID: String?
    }

    package struct SessionEnd: Sendable, Equatable {
        package var sessionID: UUID?
    }

    package struct Handoff: Sendable, Equatable {
        package var content: String
        package var sessionID: UUID?
        package var project: String?
        package var pendingTasks: [String]
    }

    package struct HandoffLatest: Sendable, Equatable {
        package var project: String?
    }

    package struct MemoryGet: Sendable, Equatable {
        package var memoryID: MemoryID
    }

    package struct Stats: Sendable, Equatable {
        package var sessionID: UUID?
    }

    package struct MemoryMaintain: Sendable, Equatable {
        package var apply: Bool
        package var forceReclaim: Bool
    }

    package struct MarkdownSync: Sendable, Equatable {
        package var rootDir: String
        package var dryRun: Bool
    }

    package struct EntityUpsert: Sendable, Equatable {
        package var key: EntityKey
        package var kind: String
        package var aliases: [String]
    }

    package struct EntityResolve: Sendable, Equatable {
        package var alias: String
        package var limit: Int
    }

    package struct FactRetract: Sendable, Equatable {
        package var factID: FactRowID
        package var atMs: Int64?
    }

    package struct SessionSynthesize: Sendable, Equatable {
        package var sessionID: UUID?
        package var minimumConfidence: Float?
        package var minimumRecallCount: Int?
        package var maxCandidates: Int?
    }

    package struct KnowledgeCapture: Sendable, Equatable {
        package var content: String
        package var destination: RememberDestination
        package var metadata: [String: String]
        package var cwd: String?
        package var graphWrite: KnowledgeGraphWrite

        package var sessionID: UUID? { destination.sessionID }
        package var writeSemantics: MemoryWriteSemantics { destination.writeSemantics }
        package var writeScope: RememberWriteScope {
            switch destination {
            case .session: return .session
            case .durable: return .durable
            }
        }
    }

    package struct SessionClose: Sendable, Equatable {
        package var sessionID: UUID?
        package var content: String
        package var project: String?
        package var pendingTasks: [String]
        /// False when the close carries no human-authored handoff (transport
        /// teardown): the session still ends, but nothing is persisted as a
        /// handoff. Defaults true so explicit closes keep recording.
        package var recordHandoff: Bool = true
    }

    package struct SessionOpen: Sendable, Equatable {
        package var project: String?
        package var repo: String?
        package var agentID: String?
        package var runID: String?
        package var recallQuery: String?
        package var cwd: String?
        package var conversationID: String? = nil
        package var sessionID: UUID? = nil
    }

    package struct CompactContext: Sendable, Equatable {
        package var query: String
        package var sessionID: UUID?
        package var tokenBudget: Int
        package var maxItems: Int
        package var mode: SearchMode
    }

    package struct MarkdownExport: Sendable, Equatable {
        package var outputDir: String
        package var sessionID: UUID?
        package var project: String?
        package var allProjects: Bool
        package var cwd: String?
    }

    package struct TaskStateMigrate: Sendable, Equatable {
        package var destinationPath: String
        package var dryRun: Bool
        package var orphanPolicy: TaskStateOrphanPolicy
        package var overwriteDestination: Bool
    }

    package struct FactsQuery: Sendable, Equatable {
        package var subject: EntityKey?
        package var predicate: PredicateKey?
        package var asOfMs: Int64?
        package var systemAsOfMs: Int64?
        package var validAsOfMs: Int64?
        package var limit: Int
    }

    package struct MemoryPromote: Sendable, Equatable {
        package var sessionID: UUID?
        package var approve: Bool
        package var frameID: UInt64?
        package var content: String?
        package var metadata: [String: String]
        package var writeSemantics: MemoryWriteSemantics
        package var cwd: String?
        package var minimumConfidence: Float?
        package var minimumRecallCount: Int?
        package var maxCandidates: Int?
    }

    package struct FactAssert: Sendable, Equatable {
        package var subject: EntityKey
        package var predicate: PredicateKey
        package var object: FactValue
        package var relation: VersionRelation
        package var validFromMs: Int64?
        package var validToMs: Int64?
        /// Parsed at decode; omitted evidence is empty.
        package var evidence: [StructuredEvidence]
    }

    package struct CorpusSearch: Sendable, Equatable {
        package var query: String
        package var recursive: Bool
        package var rebuild: Bool
        package var mode: SearchMode
        package var topK: Int
        package var expand: Bool = false
        package var sessionID: UUID? = nil
    }

    /// Validates the argument surface and decodes a typed command.
    package static func decode(
        command rawCommand: String,
        arguments: [String: AgentBrokerValue]
    ) throws -> BrokerCommand {
        let command = try BrokerCommandCatalog.validateArgumentSurface(
            command: rawCommand,
            providedKeys: Set(arguments.keys)
        )
        let args = BrokerArguments(arguments)
        switch command {
        case "remember":
            return .remember(try Remember.decode(args))
        case "recall":
            return .recall(try Recall.decode(args))
        case "search":
            return .search(try Search.decode(args))
        case "memory_search":
            return .memorySearch(try MemorySearch.decode(args))
        case "session_start":
            return .sessionStart(try SessionStart.decode(args))
        case "session_resume":
            return .sessionResume(try SessionResume.decode(args))
        case "session_end":
            return .sessionEnd(try SessionEnd.decode(args))
        case "handoff":
            return .handoff(try Handoff.decode(args))
        case "handoff_latest":
            return .handoffLatest(try HandoffLatest.decode(args))
        case "memory_get":
            return .memoryGet(try MemoryGet.decode(args))
        case "memory_health":
            return .memoryHealth
        case "stats":
            return .stats(try Stats.decode(args))
        case "flush":
            return .flush
        case "markdown_sync":
            return .markdownSync(try MarkdownSync.decode(args))
        case "entity_upsert":
            return .entityUpsert(try EntityUpsert.decode(args))
        case "entity_resolve":
            return .entityResolve(try EntityResolve.decode(args))
        case "fact_retract":
            return .factRetract(try FactRetract.decode(args))
        case "shutdown":
            return .shutdown
        case "session_synthesize":
            return .sessionSynthesize(try SessionSynthesize.decode(args))
        case "knowledge_capture":
            return .knowledgeCapture(try KnowledgeCapture.decode(args))
        case "session_close":
            return .sessionClose(try SessionClose.decode(args))
        case "session_open":
            return .sessionOpen(try SessionOpen.decode(args))
        case "compact_context":
            return .compactContext(try CompactContext.decode(args))
        case "markdown_export":
            return .markdownExport(try MarkdownExport.decode(args))
        case "task_state_migrate":
            return .taskStateMigrate(try TaskStateMigrate.decode(args))
        case "facts_query":
            return .factsQuery(try FactsQuery.decode(args))
        case "memory_promote":
            return .memoryPromote(try MemoryPromote.decode(args, defaultApprove: false))
        case "promote":
            return .promote(try MemoryPromote.decode(args, defaultApprove: true))
        case "fact_assert":
            return .factAssert(try FactAssert.decode(args))
        case "corpus_search":
            return .corpusSearch(try CorpusSearch.decode(args))
        case "memory_maintain":
            return .memoryMaintain(try MemoryMaintain.decode(args))
        case "ping":
            return .ping
        default:
            throw BrokerValidationError.invalid("Unknown broker command '\(command)'.")
        }
    }
}

package enum ResponseVerbosity: String, Sendable, Equatable {
    case compact
    case verbose
}
