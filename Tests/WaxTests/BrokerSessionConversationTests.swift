import Foundation
import Testing
@testable import Wax

@Test
func oldSessionManifestsDecodeWithoutConversationID() throws {
    let json = """
    {
      "sessionID": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
      "agentID": "legacy-agent",
      "runID": "legacy-run",
      "storePath": "/tmp/legacy.wax",
      "eventLogPath": "/tmp/legacy.events.jsonl",
      "status": "active",
      "createdAtMs": 1,
      "updatedAtMs": 1
    }
    """
    let manifest = try JSONDecoder().decode(BrokerSessionManifest.self, from: Data(json.utf8))
    #expect(manifest.conversationID == nil)
    #expect(manifest.agentID == "legacy-agent")
}

@Test
func sessionManifestRoundTripsOptionalConversationID() throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-conversation-roundtrip-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let sessionID = UUID()
    let original = conversationManifest(
        sessionID: sessionID,
        conversationID: "conv-unique-1"
    )
    try BrokerSessionPersistence.saveManifest(
        original,
        to: BrokerSessionPersistence.manifestURL(rootURL: rootURL, sessionID: sessionID)
    )
    let loaded = try BrokerSessionPersistence.loadManifest(rootURL: rootURL, sessionID: sessionID)
    #expect(loaded.conversationID == "conv-unique-1")
    #expect(loaded.sessionID == sessionID)
}

@Test
func findActiveReturnsUniqueActiveConversationMatch() throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-conversation-unique-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let uniqueID = UUID()
    let endedID = UUID()
    try saveConversationManifest(
        conversationManifest(sessionID: uniqueID, conversationID: "thread-a"),
        rootURL: rootURL
    )
    try saveConversationManifest(
        conversationManifest(
            sessionID: endedID,
            runID: "other",
            conversationID: "thread-a",
            status: .ended
        ),
        rootURL: rootURL
    )
    try saveConversationManifest(
        conversationManifest(
            sessionID: UUID(),
            runID: "other-active",
            conversationID: "thread-b"
        ),
        rootURL: rootURL
    )

    let match = try BrokerSessionPersistence.findActive(conversationID: "thread-a", rootURL: rootURL)
    let found = try #require(match)
    #expect(found.sessionID == uniqueID)
    #expect(found.conversationID == "thread-a")
    #expect(
        try BrokerSessionPersistence.findConversation(conversationID: "thread-a", rootURL: rootURL)?
            .sessionID == uniqueID
    )
}

@Test
func findConversationReturnsLatestEndedWhenNoActiveMatch() throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-conversation-ended-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let older = UUID()
    let newer = UUID()
    try saveConversationManifest(
        conversationManifest(
            sessionID: older,
            conversationID: "thread-ended",
            status: .ended,
            updatedAtMs: 10
        ),
        rootURL: rootURL
    )
    try saveConversationManifest(
        conversationManifest(
            sessionID: newer,
            runID: "later",
            conversationID: "thread-ended",
            status: .ended,
            updatedAtMs: 20
        ),
        rootURL: rootURL
    )

    #expect(try BrokerSessionPersistence.findActive(conversationID: "thread-ended", rootURL: rootURL) == nil)
    let match = try #require(
        try BrokerSessionPersistence.findConversation(conversationID: "thread-ended", rootURL: rootURL)
    )
    #expect(match.sessionID == newer)
}

@Test
func findActiveReturnsNilWhenConversationHasZeroOrManyActiveMatches() throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-conversation-nonunique-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    #expect(try BrokerSessionPersistence.findActive(conversationID: "missing", rootURL: rootURL) == nil)

    try saveConversationManifest(
        conversationManifest(sessionID: UUID(), runID: "a", conversationID: "dup-thread"),
        rootURL: rootURL
    )
    try saveConversationManifest(
        conversationManifest(sessionID: UUID(), runID: "b", conversationID: "dup-thread"),
        rootURL: rootURL
    )
    #expect(try BrokerSessionPersistence.findActive(conversationID: "dup-thread", rootURL: rootURL) == nil)
    #expect(try BrokerSessionPersistence.findActive(conversationID: "   ", rootURL: rootURL) == nil)
}

@Test
func sessionOpenDecodeParsesOptionalConversationID() throws {
    let withID = try BrokerCommand.SessionOpen.decode(
        BrokerArguments(["conversation_id": .string("  conv-open  "), "project": .string("Wax")])
    )
    #expect(withID.conversationID == "conv-open")
    #expect(withID.project == "Wax")

    let omitted = try BrokerCommand.SessionOpen.decode(BrokerArguments([:]))
    #expect(omitted.conversationID == nil)

    let blank = try BrokerCommand.SessionOpen.decode(
        BrokerArguments(["conversation_id": .string("   "), "repo": .string("Wax")])
    )
    #expect(blank.conversationID == nil)
    #expect(blank.repo == "Wax")
}

@Test
func sessionStartDecodeParsesOptionalConversationID() throws {
    let withID = try BrokerCommand.SessionStart.decode(
        BrokerArguments([
            "conversation_id": .string("conv-start"),
            "agent_id": .string("grok"),
            "run_id": .string("run-1"),
        ])
    )
    #expect(withID.conversationID == "conv-start")
    #expect(withID.agentID == "grok")
    #expect(withID.runID == "run-1")

    let omitted = try BrokerCommand.SessionStart.decode(BrokerArguments([:]))
    #expect(omitted.conversationID == nil)

    let blank = try BrokerCommand.SessionStart.decode(
        BrokerArguments(["conversation_id": .string("")])
    )
    #expect(blank.conversationID == nil)
}

@Test
func sessionStartPersistsConversationIDOntoTheLiveManifest() async throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-conversation-start-\(UUID().uuidString)", isDirectory: true)
    let storeURL = rootURL.appendingPathComponent("memory.wax")
    let sessionRootURL = rootURL.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: sessionRootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let service = try await AgentBrokerService(
        storePath: storeURL.path,
        sessionRootPath: sessionRootURL.path,
        noEmbedder: true,
        embedderChoice: "auto",
        requireVector: false
    )
    do {
        let conversationID = "conv-start-persist-\(UUID().uuidString)"
        let started = await service.handle(.init(
            command: "session_start",
            arguments: [
                "agent_id": .string("conv-start-agent"),
                "run_id": .string("conv-start-run"),
                "project": .string("conv-start-project"),
                "conversation_id": .string(conversationID),
            ]
        ))
        #expect(started.ok == true, "session_start failed: \(started.error ?? "nil")")
        let sessionID = try #require(started.payload?.objectValue?["session_id"]?.stringValue)
        let uuid = try #require(UUID(uuidString: sessionID))
        let stamped = try BrokerSessionPersistence.loadManifest(rootURL: sessionRootURL, sessionID: uuid)
        #expect(stamped.conversationID == conversationID)

        let match = try BrokerSessionPersistence.findActive(
            conversationID: conversationID,
            rootURL: sessionRootURL
        )
        #expect(match?.sessionID == uuid)
        try await service.close()
    } catch {
        try? await service.close()
        throw error
    }
}

@Test
func sessionOpenAndStartStillDecodeWhenConversationIDIsOmitted() throws {
    let open = try BrokerCommand.decode(
        command: "session_open",
        arguments: ["project": .string("wax"), "recall_query": .string("prior work")]
    )
    guard case .sessionOpen(let opened) = open else {
        Issue.record("expected session_open")
        return
    }
    #expect(opened.project == "wax")
    #expect(opened.recallQuery == "prior work")
    #expect(opened.conversationID == nil)

    let start = try BrokerCommand.decode(
        command: "session_start",
        arguments: ["agent_id": .string("agent"), "run_id": .string("run")]
    )
    guard case .sessionStart(let started) = start else {
        Issue.record("expected session_start")
        return
    }
    #expect(started.agentID == "agent")
    #expect(started.runID == "run")
    #expect(started.conversationID == nil)
}

@Test
func sessionOpenAndStartSchemasIncludeOptionalConversationID() throws {
    for name in ["session_open", "session_start"] {
        let entry = try #require(BrokerCommandCatalog.entry(for: name))
        let schema = BrokerCommandCatalog.schema(for: entry)
        let root = try #require(schema.objectValue)
        guard let propertiesValue = root["properties"],
              let properties = propertiesValue.objectValue,
              let requiredValue = root["required"],
              let required = requiredValue.arrayValue
        else {
            Issue.record("schema for \(name) is not a well-formed object")
            continue
        }
        #expect(properties["conversation_id"] != nil)
        #expect(required.isEmpty)
    }
    let openEntry = try #require(BrokerCommandCatalog.entry(for: "session_open"))
    let openProperties = try #require(
        BrokerCommandCatalog.schema(for: openEntry).objectValue?["properties"]?.objectValue
    )
    #expect(openProperties["project"] != nil)
    let startEntry = try #require(BrokerCommandCatalog.entry(for: "session_start"))
    let startProperties = try #require(
        BrokerCommandCatalog.schema(for: startEntry).objectValue?["properties"]?.objectValue
    )
    #expect(startProperties["agent_id"] != nil)
}

private func conversationManifest(
    sessionID: UUID,
    agentID: String = "agent",
    runID: String = "run",
    conversationID: String? = nil,
    status: BrokerSessionManifest.Status = .active,
    updatedAtMs: Int64 = 1
) -> BrokerSessionManifest {
    BrokerSessionManifest(
        sessionID: sessionID,
        agentID: agentID,
        runID: runID,
        project: nil,
        repo: nil,
        storePath: "/tmp/\(sessionID.uuidString).wax",
        eventLogPath: "/tmp/\(sessionID.uuidString).events.jsonl",
        status: status,
        brokerLeaseOwnerID: nil,
        leaseExpiresAtMs: nil,
        createdAtMs: 1,
        updatedAtMs: updatedAtMs,
        conversationID: conversationID
    )
}

private func saveConversationManifest(_ manifest: BrokerSessionManifest, rootURL: URL) throws {
    try BrokerSessionPersistence.saveManifest(
        manifest,
        to: BrokerSessionPersistence.manifestURL(rootURL: rootURL, sessionID: manifest.sessionID)
    )
}
