#if MCPServer
import Foundation
import Testing
import WaxCore
@testable import Wax

struct BrokerDomainDecodeTests {
    @Test
    func memoryGetDecodeRejectsBareFrameIDBeforeHandle() {
        #expect(
            throws: BrokerValidationError.invalid(
                "memory_id must be in the form '<horizon>:<frame>' or '<horizon>:<session_id>:<frame>'"
            )
        ) {
            _ = try BrokerCommand.decode(
                command: "memory_get",
                arguments: ["memory_id": .string("12")]
            )
        }
    }

    @Test
    func factAssertDecodeRejectsUnknownRelation() {
        #expect(
            throws: BrokerValidationError.invalid(
                "relation must be one of: sets, updates, extends, retracts"
            )
        ) {
            _ = try BrokerCommand.decode(
                command: "fact_assert",
                arguments: [
                    "subject": .string("project:wax"),
                    "predicate": .string("owns"),
                    "object": .string("broker memory"),
                    "relation": .string("nope"),
                ]
            )
        }
    }

    @Test
    func memoryGetDecodeAcceptsDurableFrameID() throws {
        let decoded = try BrokerCommand.decode(
            command: "memory_get",
            arguments: ["memory_id": .string("durable:12")]
        )
        guard case .memoryGet(let payload) = decoded else {
            Issue.record("expected memory_get")
            return
        }
        #expect(payload.memoryID == .durable(frameID: 12))
    }

    @Test
    func factAssertDecodeYieldsDomainTypes() throws {
        let decoded = try BrokerCommand.decode(
            command: "fact_assert",
            arguments: [
                "subject": .string("project:wax"),
                "predicate": .string("owns"),
                "object": .string("broker memory"),
                "relation": .string("updates"),
            ]
        )
        guard case .factAssert(let payload) = decoded else {
            Issue.record("expected fact_assert")
            return
        }
        #expect(payload.subject == EntityKey("project:wax"))
        #expect(payload.predicate == PredicateKey("owns"))
        #expect(payload.object == .string("broker memory"))
        #expect(payload.relation == .updates)
    }

    @Test
    func factRetractAndFactsQueryAndEntityUpsertDecodeDomainKeys() throws {
        let retract = try BrokerCommand.decode(
            command: "fact_retract",
            arguments: ["fact_id": .int(9)]
        )
        guard case .factRetract(let retracted) = retract else {
            Issue.record("expected fact_retract")
            return
        }
        #expect(retracted.factID == FactRowID(rawValue: 9))

        let query = try BrokerCommand.decode(
            command: "facts_query",
            arguments: [
                "subject": .string("project:wax"),
                "predicate": .string("owns"),
            ]
        )
        guard case .factsQuery(let facts) = query else {
            Issue.record("expected facts_query")
            return
        }
        #expect(facts.subject == EntityKey("project:wax"))
        #expect(facts.predicate == PredicateKey("owns"))

        let upsert = try BrokerCommand.decode(
            command: "entity_upsert",
            arguments: [
                "key": .string("project:wax"),
                "kind": .string("project"),
            ]
        )
        guard case .entityUpsert(let entity) = upsert else {
            Issue.record("expected entity_upsert")
            return
        }
        #expect(entity.key == EntityKey("project:wax"))
        #expect(entity.kind == "project")
    }
}
#endif
