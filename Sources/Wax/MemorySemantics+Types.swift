import Foundation

package enum MemoryType: String, CaseIterable, Sendable {
    case note = "note"
    case taskState = "task_state"
    case userPreference = "user_preference"
    case decision = "decision"
    case lesson = "lesson"
    case handoff = "handoff"
    case constraint = "constraint"
    case fact = "fact"
}

package enum MemoryDurability: String, CaseIterable, Sendable {
    case ephemeral = "ephemeral"
    case working = "working"
    case durable = "durable"
    case locked = "locked"
}

package struct MemoryScopeContext: Sendable, Equatable {
    package var cwdPath: String?
    package var repoRootPath: String?
    package var repoName: String?
    package var projectName: String?

    package init(
        cwdPath: String? = nil,
        repoRootPath: String? = nil,
        repoName: String? = nil,
        projectName: String? = nil
    ) {
        self.cwdPath = cwdPath
        self.repoRootPath = repoRootPath
        self.repoName = repoName
        self.projectName = projectName
    }
}

package struct MemorySemanticInfo: Sendable, Equatable {
    package var type: MemoryType
    package var durability: MemoryDurability
    package var project: String?
    package var repo: String?
    package var createdAtMs: Int64?
    package var expiresAtMs: Int64?
    package var confidence: Float?
    package var isReviewed: Bool
    package var isExpired: Bool
}

package struct MemoryWriteSemantics: Sendable, Equatable {
    package var type: MemoryType?
    package var durability: MemoryDurability?
    package var project: String?
    package var repo: String?
    package var confidence: Float?
    package var expiresInDays: Int?
    package var reviewed: Bool
    package var lock: Bool
    package var checkoutStatus: MemoryCheckoutStatus?

    package init(
        type: MemoryType? = nil,
        durability: MemoryDurability? = nil,
        project: String? = nil,
        repo: String? = nil,
        confidence: Float? = nil,
        expiresInDays: Int? = nil,
        reviewed: Bool = false,
        lock: Bool = false,
        checkoutStatus: MemoryCheckoutStatus? = nil
    ) {
        self.type = type
        self.durability = durability
        self.project = project
        self.repo = repo
        self.confidence = confidence
        self.expiresInDays = expiresInDays
        self.reviewed = reviewed
        self.lock = lock
        self.checkoutStatus = checkoutStatus
    }
}

/// Closed session vs durable remember write after wire decode.
package enum RememberDestination: Sendable, Equatable {
    case session(sessionID: UUID, write: SessionRememberWrite)
    case durable(write: DurableRememberWrite)

    package var sessionID: UUID? {
        switch self {
        case .session(let sessionID, _):
            return sessionID
        case .durable:
            return nil
        }
    }

    package var writeSemantics: MemoryWriteSemantics {
        switch self {
        case .session(_, let write):
            return write.writeSemantics
        case .durable(let write):
            return write.writeSemantics
        }
    }

    /// Maps MCP remember fields into a destination that cannot name illegal combos.
    package static func decode(
        sessionID: UUID?,
        writeScope: RememberWriteScope?,
        semantics: MemoryWriteSemantics,
        metadata: [String: String]
    ) throws -> RememberDestination {
        let metadataType = metadata[MemoryMetadataKeys.type].flatMap(MemoryType.init(rawValue:))
        let resolvedType = semantics.type ?? metadataType ?? .note
        let metadataDurability = metadata[MemoryMetadataKeys.durability]
            .flatMap(MemoryDurability.init(rawValue:))
        let requestedDurability = semantics.lock
            ? MemoryDurability.locked
            : semantics.durability ?? metadataDurability
        let fields = RememberWriteFields(
            project: semantics.project,
            repo: semantics.repo,
            confidence: semantics.confidence,
            expiresInDays: semantics.expiresInDays,
            reviewed: semantics.reviewed,
            checkoutStatus: semantics.checkoutStatus
        )

        if resolvedType == .taskState {
            if writeScope == .durable {
                throw BrokerValidationError.invalid(
                    "task_state cannot use scope durable; use scope session with an active session_id"
                )
            }
            guard let sessionID else {
                throw BrokerValidationError.invalid(
                    "task_state requires an active session_id; durable task diaries are not supported"
                )
            }
            if semantics.lock
                || requestedDurability == .durable
                || requestedDurability == .locked
                || metadataDurability == .durable
                || metadataDurability == .locked {
                throw BrokerValidationError.invalid(
                    "task_state cannot use durability durable or locked; use working session memory"
                )
            }
            return .session(sessionID: sessionID, write: .taskState(fields: fields))
        }

        if writeScope == .durable, sessionID != nil {
            throw BrokerValidationError.invalid("scope durable forbids session_id")
        }
        if writeScope == .session, sessionID == nil {
            throw BrokerValidationError.invalid("scope session requires session_id")
        }

        // Type selects horizon. session_id does not hijack durable types;
        // explicit scope=session still forces a session write where legal.
        // Explicit ephemeral/working durability is a session intent: honor it
        // via session when a session exists instead of silently escalating
        // to durable. Without a session, reject with guidance.
        let typeSelectsSession = resolvedType == .note
            || resolvedType == .handoff
            || resolvedType == .taskState
        let requestsTransientDurability = requestedDurability == .ephemeral
            || requestedDurability == .working
        if let sessionID, writeScope == .session || typeSelectsSession || requestsTransientDurability {
            let sessionDurability: SessionRememberDurability
            switch requestedDurability {
            case .durable, .locked:
                throw BrokerValidationError.invalid(
                    "session writes cannot use durability durable or locked; use working session memory"
                )
            case .ephemeral:
                sessionDurability = .ephemeral
            case .working, .none:
                sessionDurability = .working
            }
            let sessionType = try SessionRememberType(memoryType: resolvedType)
            return .session(
                sessionID: sessionID,
                write: .typed(type: sessionType, durability: sessionDurability, fields: fields)
            )
        }

        if requestsTransientDurability {
            throw BrokerValidationError.invalid(
                "durability \(requestedDurability?.rawValue ?? "ephemeral") requires scope session with an active session_id; pass scope session or omit durability to use the memory_type default"
            )
        }

        let durableType = try DurableRememberType(memoryType: resolvedType)
        let durableDurability: DurableRememberDurability
        if semantics.lock || requestedDurability == .locked {
            durableDurability = .locked
        } else if requestedDurability == .durable {
            durableDurability = .durable
        } else if requestedDurability == nil {
            switch MemorySemantics.defaultDurability(for: resolvedType) {
            case .locked:
                durableDurability = .locked
            case .durable, .working, .ephemeral:
                durableDurability = .durable
            }
        } else {
            durableDurability = .durable
        }
        return .durable(
            write: DurableRememberWrite(type: durableType, durability: durableDurability, fields: fields)
        )
    }
}

package enum RememberWriteScope: String, Sendable, Equatable {
    case session
    case durable
}

package enum SessionRememberWrite: Sendable, Equatable {
    /// Session-local working state; durability is always `working`.
    case taskState(fields: RememberWriteFields)
    case typed(type: SessionRememberType, durability: SessionRememberDurability, fields: RememberWriteFields)

    package var writeSemantics: MemoryWriteSemantics {
        switch self {
        case .taskState(let fields):
            return MemoryWriteSemantics(
                type: .taskState,
                durability: .working,
                project: fields.project,
                repo: fields.repo,
                confidence: fields.confidence,
                expiresInDays: fields.expiresInDays,
                reviewed: fields.reviewed,
                lock: false,
                checkoutStatus: fields.checkoutStatus
            )
        case .typed(let type, let durability, let fields):
            return MemoryWriteSemantics(
                type: type.memoryType,
                durability: durability.memoryDurability,
                project: fields.project,
                repo: fields.repo,
                confidence: fields.confidence,
                expiresInDays: fields.expiresInDays,
                reviewed: fields.reviewed,
                lock: false,
                checkoutStatus: fields.checkoutStatus
            )
        }
    }
}

package enum SessionRememberType: Sendable, Equatable {
    case note
    case userPreference
    case decision
    case lesson
    case handoff
    case constraint
    case fact

    package var memoryType: MemoryType {
        switch self {
        case .note: return .note
        case .userPreference: return .userPreference
        case .decision: return .decision
        case .lesson: return .lesson
        case .handoff: return .handoff
        case .constraint: return .constraint
        case .fact: return .fact
        }
    }

    package init(memoryType: MemoryType) throws {
        switch memoryType {
        case .taskState:
            throw BrokerValidationError.invalid(
                "task_state cannot be a typed session write; use SessionRememberWrite.taskState"
            )
        case .note: self = .note
        case .userPreference: self = .userPreference
        case .decision: self = .decision
        case .lesson: self = .lesson
        case .handoff: self = .handoff
        case .constraint: self = .constraint
        case .fact: self = .fact
        }
    }
}

package enum SessionRememberDurability: Sendable, Equatable {
    case ephemeral
    case working

    package var memoryDurability: MemoryDurability {
        switch self {
        case .ephemeral: return .ephemeral
        case .working: return .working
        }
    }
}

package enum DurableRememberType: Sendable, Equatable {
    case note
    case userPreference
    case decision
    case lesson
    case handoff
    case constraint
    case fact

    package var memoryType: MemoryType {
        switch self {
        case .note: return .note
        case .userPreference: return .userPreference
        case .decision: return .decision
        case .lesson: return .lesson
        case .handoff: return .handoff
        case .constraint: return .constraint
        case .fact: return .fact
        }
    }

    package init(memoryType: MemoryType) throws {
        switch memoryType {
        case .taskState:
            throw BrokerValidationError.invalid(
                "task_state requires an active session_id; durable task diaries are not supported"
            )
        case .note: self = .note
        case .userPreference: self = .userPreference
        case .decision: self = .decision
        case .lesson: self = .lesson
        case .handoff: self = .handoff
        case .constraint: self = .constraint
        case .fact: self = .fact
        }
    }
}

package enum DurableRememberDurability: Sendable, Equatable {
    case durable
    case locked

    package var memoryDurability: MemoryDurability {
        switch self {
        case .durable: return .durable
        case .locked: return .locked
        }
    }
}

package struct RememberWriteFields: Sendable, Equatable {
    package var project: String?
    package var repo: String?
    package var confidence: Float?
    package var expiresInDays: Int?
    package var reviewed: Bool
    package var checkoutStatus: MemoryCheckoutStatus?

    package init(
        project: String? = nil,
        repo: String? = nil,
        confidence: Float? = nil,
        expiresInDays: Int? = nil,
        reviewed: Bool = false,
        checkoutStatus: MemoryCheckoutStatus? = nil
    ) {
        self.project = project
        self.repo = repo
        self.confidence = confidence
        self.expiresInDays = expiresInDays
        self.reviewed = reviewed
        self.checkoutStatus = checkoutStatus
    }
}

package struct DurableRememberWrite: Sendable, Equatable {
    package var type: DurableRememberType
    package var durability: DurableRememberDurability
    package var fields: RememberWriteFields

    package var writeSemantics: MemoryWriteSemantics {
        MemoryWriteSemantics(
            type: type.memoryType,
            durability: durability.memoryDurability,
            project: fields.project,
            repo: fields.repo,
            confidence: fields.confidence,
            expiresInDays: fields.expiresInDays,
            reviewed: fields.reviewed,
            lock: durability == .locked,
            checkoutStatus: fields.checkoutStatus
        )
    }
}
