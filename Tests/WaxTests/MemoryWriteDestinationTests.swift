import Foundation
import Testing
@testable import Wax

struct MemoryWriteDestinationTests {
    @Test
    func rememberDestinationSessionTaskStateForcesWorking() throws {
        let sessionID = UUID()
        let destination = try RememberDestination.decode(
            sessionID: sessionID,
            writeScope: .session,
            semantics: MemoryWriteSemantics(type: .taskState, durability: .ephemeral),
            metadata: [:]
        )
        guard case .session(let decodedSessionID, let write) = destination else {
            Issue.record("expected session destination")
            return
        }
        #expect(decodedSessionID == sessionID)
        guard case .taskState = write else {
            Issue.record("expected taskState write")
            return
        }
        #expect(destination.writeSemantics.type == .taskState)
        #expect(destination.writeSemantics.durability == .working)
        #expect(destination.writeSemantics.lock == false)
        #expect(destination.sessionID == sessionID)
    }

    @Test
    func rememberDestinationRejectsTaskStateWithoutSession() {
        #expect(throws: BrokerValidationError.self) {
            _ = try RememberDestination.decode(
                sessionID: nil,
                writeScope: nil,
                semantics: MemoryWriteSemantics(type: .taskState),
                metadata: [:]
            )
        }
        do {
            _ = try RememberDestination.decode(
                sessionID: nil,
                writeScope: nil,
                semantics: MemoryWriteSemantics(type: .taskState),
                metadata: [:]
            )
            Issue.record("expected throw")
        } catch let error as BrokerValidationError {
            #expect(String(describing: error).contains("task_state requires an active session_id"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test
    func rememberDestinationRejectsTaskStateDurableLockedAndDurableScope() {
        let sessionID = UUID()
        do {
            _ = try RememberDestination.decode(
                sessionID: sessionID,
                writeScope: nil,
                semantics: MemoryWriteSemantics(type: .taskState, durability: .durable),
                metadata: [:]
            )
            Issue.record("expected throw")
        } catch let error as BrokerValidationError {
            #expect(String(describing: error).contains("task_state cannot use durability durable or locked"))
        } catch {
            Issue.record("unexpected error \(error)")
        }

        do {
            _ = try RememberDestination.decode(
                sessionID: sessionID,
                writeScope: nil,
                semantics: MemoryWriteSemantics(type: .taskState, lock: true),
                metadata: [:]
            )
            Issue.record("expected throw")
        } catch let error as BrokerValidationError {
            #expect(String(describing: error).contains("task_state cannot use durability durable or locked"))
        } catch {
            Issue.record("unexpected error \(error)")
        }

        do {
            _ = try RememberDestination.decode(
                sessionID: sessionID,
                writeScope: .durable,
                semantics: MemoryWriteSemantics(type: .taskState),
                metadata: [:]
            )
            Issue.record("expected throw")
        } catch let error as BrokerValidationError {
            #expect(String(describing: error).contains("task_state cannot use scope durable"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test
    func rememberDestinationDurableHasNoSessionID() throws {
        let destination = try RememberDestination.decode(
            sessionID: nil,
            writeScope: .durable,
            semantics: MemoryWriteSemantics(type: .decision, durability: .durable),
            metadata: [:]
        )
        guard case .durable(let write) = destination else {
            Issue.record("expected durable destination")
            return
        }
        #expect(write.type == .decision)
        #expect(write.durability == .durable)
        #expect(destination.sessionID == nil)
    }

    @Test
    func rememberWireDecodeRejectsScopeDurableWithSessionID() {
        do {
            _ = try BrokerCommand.decode(
                command: "remember",
                arguments: [
                    "content": .string("x"),
                    "session_id": .string("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"),
                    "scope": .string("durable"),
                ]
            )
            Issue.record("expected throw")
        } catch let error as BrokerValidationError {
            #expect(String(describing: error).contains("scope durable forbids session_id"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test
    func rememberWireDecodeMapsClosedDestination() throws {
        let sessionID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let decoded = try BrokerCommand.decode(
            command: "remember",
            arguments: [
                "content": .string("working task state"),
                "session_id": .string(sessionID.uuidString),
                "scope": .string("session"),
                "memory_type": .string("task_state"),
                "durability": .string("ephemeral"),
            ]
        )
        guard case .remember(let remember) = decoded else {
            Issue.record("expected remember")
            return
        }
        #expect(remember.destination == .session(sessionID: sessionID, write: .taskState(fields: RememberWriteFields())))
        #expect(remember.sessionID == sessionID)
        #expect(remember.writeScope == .session)
        #expect(remember.writeSemantics.type == .taskState)
        #expect(remember.writeSemantics.durability == .working)
    }

    @Test(arguments: [
        MemoryType.decision,
        MemoryType.lesson,
        MemoryType.fact,
        MemoryType.constraint,
        MemoryType.userPreference,
    ])
    func rememberDestinationDurableTypesStayDurableWhenSessionIDPresent(_ type: MemoryType) throws {
        let destination = try RememberDestination.decode(
            sessionID: UUID(),
            writeScope: nil,
            semantics: MemoryWriteSemantics(type: type),
            metadata: [:]
        )
        guard case .durable(let write) = destination else {
            Issue.record("expected durable destination for \(type.rawValue)")
            return
        }
        #expect(write.type.memoryType == type)
        #expect(write.durability == .durable)
        #expect(destination.sessionID == nil)
    }

    @Test(arguments: [MemoryDurability.working, MemoryDurability.ephemeral, MemoryDurability.durable])
    func rememberDestinationDurableTypeIgnoresSessionDurabilityWhenSessionIDPresent(
        _ durability: MemoryDurability
    ) throws {
        let destination = try RememberDestination.decode(
            sessionID: UUID(),
            writeScope: nil,
            semantics: MemoryWriteSemantics(type: .decision, durability: durability),
            metadata: [:]
        )
        guard case .durable(let write) = destination else {
            Issue.record("expected durable destination")
            return
        }
        #expect(write.type == .decision)
        #expect(write.durability == .durable)
        #expect(destination.sessionID == nil)
    }

    @Test
    func rememberDestinationDurableTypeWithSessionIDAcceptsLocked() throws {
        let destination = try RememberDestination.decode(
            sessionID: UUID(),
            writeScope: nil,
            semantics: MemoryWriteSemantics(type: .lesson, lock: true),
            metadata: [:]
        )
        guard case .durable(let write) = destination else {
            Issue.record("expected durable destination")
            return
        }
        #expect(write.type == .lesson)
        #expect(write.durability == .locked)
        #expect(destination.sessionID == nil)
    }

    @Test
    func rememberDestinationExplicitScopeSessionForcesSessionForDecision() throws {
        let sessionID = UUID()
        let destination = try RememberDestination.decode(
            sessionID: sessionID,
            writeScope: .session,
            semantics: MemoryWriteSemantics(type: .decision, durability: .working),
            metadata: [:]
        )
        guard case .session(let decodedSessionID, let write) = destination else {
            Issue.record("expected session destination")
            return
        }
        #expect(decodedSessionID == sessionID)
        guard case .typed(let type, let durability, _) = write else {
            Issue.record("expected typed session write")
            return
        }
        #expect(type == .decision)
        #expect(durability == .working)
    }

    @Test
    func rememberDestinationExplicitScopeSessionRejectsDurableDurability() {
        do {
            _ = try RememberDestination.decode(
                sessionID: UUID(),
                writeScope: .session,
                semantics: MemoryWriteSemantics(type: .decision, durability: .durable),
                metadata: [:]
            )
            Issue.record("expected throw")
        } catch let error as BrokerValidationError {
            #expect(String(describing: error).contains("session writes cannot use durability durable or locked"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test
    func rememberDestinationNoteUsesSessionWhenSessionIDPresent() throws {
        let sessionID = UUID()
        let destination = try RememberDestination.decode(
            sessionID: sessionID,
            writeScope: nil,
            semantics: MemoryWriteSemantics(type: .note),
            metadata: [:]
        )
        guard case .session(let decodedSessionID, let write) = destination else {
            Issue.record("expected session destination")
            return
        }
        #expect(decodedSessionID == sessionID)
        guard case .typed(let type, let durability, _) = write else {
            Issue.record("expected typed session write")
            return
        }
        #expect(type == .note)
        #expect(durability == .working)
    }

    @Test
    func rememberDestinationNoteUsesDurableWhenSessionIDOmitted() throws {
        let destination = try RememberDestination.decode(
            sessionID: nil,
            writeScope: nil,
            semantics: MemoryWriteSemantics(type: .note),
            metadata: [:]
        )
        guard case .durable(let write) = destination else {
            Issue.record("expected durable destination")
            return
        }
        #expect(write.type == .note)
        #expect(write.durability == .durable)
    }

    @Test
    func rememberDestinationHandoffUsesSessionWhenSessionIDPresent() throws {
        let sessionID = UUID()
        let destination = try RememberDestination.decode(
            sessionID: sessionID,
            writeScope: nil,
            semantics: MemoryWriteSemantics(type: .handoff),
            metadata: [:]
        )
        guard case .session(let decodedSessionID, let write) = destination else {
            Issue.record("expected session destination")
            return
        }
        #expect(decodedSessionID == sessionID)
        guard case .typed(let type, let durability, _) = write else {
            Issue.record("expected typed session write")
            return
        }
        #expect(type == .handoff)
        #expect(durability == .working)
    }
}
