import Foundation
import Testing
@testable import Wax

@Test
func sessionOpenDoesNotDecodeRecallOrStringifyUUID() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = try String(
        contentsOf: repoRoot.appendingPathComponent("Sources/Wax/Broker/AgentBrokerService+Sessions.swift"),
        encoding: .utf8
    )
    let start = try #require(source.range(of: "func sessionOpen(_ command: BrokerCommand.SessionOpen)"))
    let end = try #require(source[start.upperBound...].range(of: "private func sessionBootstrapEnvironment("))
    let body = source[start.lowerBound..<end.lowerBound]
    #expect(
        !body.contains("Recall.decode"),
        "sessionOpen must construct typed recall, not BrokerCommand.Recall.decode"
    )
    #expect(
        !body.contains("uuidString"),
        "sessionOpen must keep UUID as UUID until SessionOpenAssembly packs the envelope"
    )
}

@Test
func sessionBootstrapProjectRecallKeepsTypedSessionUUID() {
    let sessionID = UUID()
    let recall = SessionBootstrap.projectRecall(
        query: "ship wax",
        sessionID: sessionID,
        project: "Wax",
        repo: "Wax",
        cwd: "/tmp"
    )
    #expect(recall.query == "ship wax")
    #expect(recall.scope == .project)
    #expect(recall.limit == 5)
    #expect(recall.searchTopK == 5)
    #expect(recall.mode == nil)
    #expect(recall.filters.sessionId == sessionID)
    #expect(recall.explicitProject == "Wax")
    #expect(recall.explicitRepo == "Wax")
    #expect(recall.clientCWD == "/tmp")
    #expect(recall.memoryTypes.isEmpty)
}

@Test
func sessionBootstrapPersonRecallUsesGlobalTextUserPreferenceLimit3() {
    let sessionID = UUID()
    let recall = SessionBootstrap.personRecall(
        sessionID: sessionID,
        project: "Wax",
        repo: "Wax",
        cwd: nil
    )
    #expect(recall.query == "facts about this person standing corrections")
    #expect(recall.scope == .global)
    #expect(recall.mode == .textOnly)
    #expect(recall.memoryTypes == [.userPreference])
    #expect(recall.limit == 3)
    #expect(recall.searchTopK == 3)
    #expect(recall.filters.sessionId == sessionID)
    #expect(recall.explicitProject == "Wax")
    #expect(recall.explicitRepo == "Wax")
}

@Test
func sessionBootstrapPersonRecallFailureYieldsNil() async {
    let payload = await SessionBootstrap.personPayload(
        sessionID: UUID(),
        project: nil,
        repo: nil,
        cwd: nil
    ) { _ in
        throw BrokerValidationError.invalid("person lane failed")
    }
    #expect(payload == nil)
}

@Test
func sessionHandoffFromLatestDropsWireExtrasThenCompactUsesTypedFields() async throws {
    let wire = AgentBrokerValue.object([
        "found": .bool(true),
        "content": .string("keep this"),
        "pending_tasks": .array([.string("t1")]),
        "frame_id": .from(9 as UInt64),
        "display_text": .string("keep this"),
    ])
    let typed = SessionHandoff(fromLatest: wire)
    #expect(typed == SessionHandoff(found: true, content: "keep this", pendingTasks: ["t1"]))
    let compacted = await SessionOpenAssembly.compactHandoff(
        typed,
        recallQuery: nil,
        tokenizer: .character
    )
    let object = try #require(compacted.objectValue)
    #expect(object["frame_id"] == nil)
    #expect(object["display_text"] == nil)
    #expect(object["content"]?.stringValue == "keep this")
    #expect(object["pending_tasks"] == .array([.string("t1")]))
}
