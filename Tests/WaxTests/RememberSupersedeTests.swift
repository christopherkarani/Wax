import Foundation
import Testing
@testable import Wax

/// 11/12 Jaccard on `MemorySemantics.similarity` (threshold is 0.88).
private let originalDecision = "Prefer project-scoped recall and never auto-widen an empty project lane."
private let similarDecision = "Prefer project-scoped recall and never auto-widen an empty project lane now."

private func withSupersedeBroker<T>(
    _ body: (AgentBrokerService) async throws -> T
) async throws -> T {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-supersede-\(UUID().uuidString)", isDirectory: true)
    let storeURL = rootURL.appendingPathComponent("memory.wax")
    let sessionRootURL = rootURL.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    var config = OrchestratorConfig.default
    config.enableVectorSearch = false
    config.enableTextSearch = true
    config.rag.searchMode = .hybrid(alpha: 0.5)
    config.liveSetRewriteSchedule = .disabled

    let service = try await AgentBrokerService(
        storePath: storeURL.path,
        sessionRootPath: sessionRootURL.path,
        noEmbedder: true,
        embedderChoice: "auto",
        requireVector: false,
        orchestratorConfig: config
    )
    do {
        let result = try await body(service)
        try await service.close()
        return result
    } catch {
        try? await service.close()
        throw error
    }
}

private func requireObject(_ value: AgentBrokerValue?) throws -> [String: AgentBrokerValue] {
    try #require(value?.objectValue)
}

private func requireFrameID(_ payload: [String: AgentBrokerValue]) throws -> UInt64 {
    let raw = try #require(payload["frame_id"]?.intValue)
    return UInt64(raw)
}

private func rememberDurable(
    _ service: AgentBrokerService,
    content: String,
    memoryType: String,
    project: String,
    durability: String = "durable",
    locked: Bool = false
) async throws -> UInt64 {
    var arguments: [String: AgentBrokerValue] = [
        "content": .string(content),
        "memory_type": .string(memoryType),
        "durability": .string(durability),
        "project": .string(project),
        "repo": .string(project),
    ]
    if locked {
        arguments["locked"] = .bool(true)
    }
    let write = await service.handle(.init(command: "remember", arguments: arguments))
    #expect(write.ok == true, "remember failed: \(write.error ?? "nil")")
    return try requireFrameID(try requireObject(write.payload))
}

private func recallPayload(
    _ service: AgentBrokerService,
    query: String,
    project: String
) async throws -> [String: AgentBrokerValue] {
    let recall = await service.handle(.init(
        command: "recall",
        arguments: [
            "query": .string(query),
            "mode": .string("text"),
            "scope": .string("project"),
            "project": .string(project),
            "repo": .string(project),
            "limit": .int(8),
        ]
    ))
    #expect(recall.ok == true, "recall failed: \(recall.error ?? "nil")")
    return try requireObject(recall.payload)
}

private func recallTexts(_ payload: [String: AgentBrokerValue]) -> [String] {
    (payload["results"]?.arrayValue ?? []).compactMap { hit in
        hit.objectValue?["text"]?.stringValue
    }
}

private func liveFrameIDs(_ service: AgentBrokerService) async throws -> Set<UInt64> {
    let documents = try await service.longTermMemory.corpusSourceDocuments()
    return Set(documents.map(\.frameId))
}

private func supersededBy(_ service: AgentBrokerService, frameID: UInt64) async -> UInt64? {
    let metas = await service.longTermMemory.wax.frameMetas()
    return metas.first(where: { $0.id == frameID })?.supersededBy
}

struct RememberSupersedeTests {
    @Test(arguments: ["decision", "lesson", "constraint", "fact"])
    func secondSimilarDurableFrameSupersedesTheFirst(_ memoryType: String) async throws {
        let project = "wax-supersede-\(memoryType)"
        try await withSupersedeBroker { service in
            let first = try await rememberDurable(
                service,
                content: originalDecision,
                memoryType: memoryType,
                project: project
            )
            let second = try await rememberDurable(
                service,
                content: similarDecision,
                memoryType: memoryType,
                project: project
            )
            #expect(first != second)

            let live = try await liveFrameIDs(service)
            #expect(live.contains(second))
            #expect(live.contains(first) == false)
            #expect(await supersededBy(service, frameID: first) == second)

            let recalled = try await recallPayload(
                service,
                query: "project-scoped recall auto-widen",
                project: project
            )
            let texts = recallTexts(recalled)
            #expect(texts.contains(where: { $0.contains("now") }))
            #expect(texts.contains(where: { $0.contains(originalDecision) }) == false)

            let oldMeta = try #require(
                await service.longTermMemory.wax.frameMetas().first { $0.id == first }
            )
            #expect(oldMeta.status == .active)
            #expect(oldMeta.supersededBy == second)
        }
    }

    @Test
    func lockedDurableDecisionIsNotAutoSuperseded() async throws {
        let project = "wax-supersede-locked-old"
        try await withSupersedeBroker { service in
            let locked = try await rememberDurable(
                service,
                content: originalDecision,
                memoryType: "decision",
                project: project,
                durability: "locked",
                locked: true
            )
            let second = try await rememberDurable(
                service,
                content: similarDecision,
                memoryType: "decision",
                project: project
            )

            let live = try await liveFrameIDs(service)
            #expect(live.contains(locked))
            #expect(live.contains(second))
            #expect(await supersededBy(service, frameID: locked) == nil)

            let recalled = try await recallPayload(
                service,
                query: "project-scoped recall auto-widen",
                project: project
            )
            let texts = recallTexts(recalled)
            #expect(texts.contains(where: { $0.contains(originalDecision) }))
            #expect(texts.contains(where: { $0.contains("now") }))
        }
    }

    @Test
    func lockedNewDecisionStillSupersedesUnlockedSimilar() async throws {
        let project = "wax-supersede-locked-new"
        try await withSupersedeBroker { service in
            let first = try await rememberDurable(
                service,
                content: originalDecision,
                memoryType: "decision",
                project: project
            )
            let lockedNew = try await rememberDurable(
                service,
                content: similarDecision,
                memoryType: "decision",
                project: project,
                durability: "locked",
                locked: true
            )

            let live = try await liveFrameIDs(service)
            #expect(live.contains(lockedNew))
            #expect(live.contains(first) == false)
            #expect(await supersededBy(service, frameID: first) == lockedNew)
        }
    }

    @Test
    func similarDurableDecisionsInDifferentProjectsDoNotSupersede() async throws {
        try await withSupersedeBroker { service in
            let first = try await rememberDurable(
                service,
                content: originalDecision,
                memoryType: "decision",
                project: "wax-supersede-alpha"
            )
            let second = try await rememberDurable(
                service,
                content: similarDecision,
                memoryType: "decision",
                project: "wax-supersede-beta"
            )

            let live = try await liveFrameIDs(service)
            #expect(live.contains(first))
            #expect(live.contains(second))
            #expect(await supersededBy(service, frameID: first) == nil)
            #expect(await supersededBy(service, frameID: second) == nil)
        }
    }

    @Test
    func similarDurableNotesDoNotSupersede() async throws {
        let project = "wax-supersede-notes"
        try await withSupersedeBroker { service in
            let first = try await rememberDurable(
                service,
                content: originalDecision,
                memoryType: "note",
                project: project
            )
            let second = try await rememberDurable(
                service,
                content: similarDecision,
                memoryType: "note",
                project: project
            )

            let live = try await liveFrameIDs(service)
            #expect(live.contains(first))
            #expect(live.contains(second))
            #expect(await supersededBy(service, frameID: first) == nil)
        }
    }

    @Test
    func similarSessionTaskStateDoesNotSupersede() async throws {
        let project = "wax-supersede-task-state"
        try await withSupersedeBroker { service in
            let started = await service.handle(.init(
                command: "session_start",
                arguments: [
                    "agent_id": .string("supersede-agent"),
                    "run_id": .string("supersede-task-state"),
                    "project": .string(project),
                    "repo": .string(project),
                ]
            ))
            #expect(started.ok == true, "session_start failed: \(started.error ?? "nil")")
            let sessionID = try #require(try requireObject(started.payload)["session_id"]?.stringValue)

            func rememberTaskState(_ content: String) async throws -> UInt64 {
                let write = await service.handle(.init(
                    command: "remember",
                    arguments: [
                        "content": .string(content),
                        "session_id": .string(sessionID),
                        "memory_type": .string("task_state"),
                        "durability": .string("working"),
                        "project": .string(project),
                        "repo": .string(project),
                    ]
                ))
                #expect(write.ok == true, "task_state remember failed: \(write.error ?? "nil")")
                return try requireFrameID(try requireObject(write.payload))
            }

            let firstID = try await rememberTaskState(originalDecision)
            let secondID = try await rememberTaskState(similarDecision)
            #expect(firstID != secondID)

            let uuid = try #require(UUID(uuidString: sessionID))
            let state = try #require(await service.activeSessions[uuid])
            let live = Set(try await state.memory.corpusSourceDocuments().map(\.frameId))
            #expect(live.contains(firstID))
            #expect(live.contains(secondID))
        }
    }
}
