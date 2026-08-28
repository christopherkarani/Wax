import Foundation
import Testing
@testable import Wax

#if MCPServer
import MCP
@testable import wax_mcp

private func withTaskStateBroker<T>(
    _ body: (AgentBrokerService, URL) async throws -> T
) async throws -> T {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-task-state-\(UUID().uuidString)", isDirectory: true)
    let storeURL = rootURL.appendingPathComponent("memory.wax")
    let sessionRootURL = rootURL.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let service = try await AgentBrokerService(
        storePath: storeURL.path,
        sessionRootPath: sessionRootURL.path,
        noEmbedder: true,
        embedderChoice: "auto",
        requireVector: false
    )
    do {
        let result = try await body(service, rootURL)
        try await service.close()
        return result
    } catch {
        try? await service.close()
        throw error
    }
}

@Test
func taskStateWritesRequireSessionAndWorkingDurability() async throws {
    try await withTaskStateBroker { service, _ in
        let missingSession = await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("orphan task state"),
                "memory_type": .string("task_state"),
            ]
        ))
        #expect(!missingSession.ok)
        #expect((missingSession.error ?? "").contains("task_state"))

        let started = await service.handle(.init(command: "session_start"))
        let sessionID = try #require(started.payload?.objectValue?["session_id"]?.stringValue)
        let durable = await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("durable diary is forbidden"),
                "session_id": .string(sessionID),
                "memory_type": .string("task_state"),
                "durability": .string("durable"),
            ]
        ))
        #expect(!durable.ok)

        let locked = await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("locked diary is forbidden"),
                "session_id": .string(sessionID),
                "memory_type": .string("task_state"),
                "locked": .bool(true),
            ]
        ))
        #expect(!locked.ok)

        let scopeDurable = await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("durable scope is forbidden"),
                "session_id": .string(sessionID),
                "scope": .string("durable"),
                "memory_type": .string("task_state"),
            ]
        ))
        #expect(!scopeDurable.ok)

        let valid = await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("working task state"),
                "session_id": .string(sessionID),
                "memory_type": .string("task_state"),
                "durability": .string("ephemeral"),
            ]
        ))
        #expect(valid.ok)
        #expect(valid.payload?.objectValue?["durability"]?.stringValue == "working")

        let session = try await service.memory(for: UUID(uuidString: sessionID))
        let documents = try await session.corpusSourceDocuments()
        #expect(documents.count == 1)
        let metadata = try #require(documents.first?.metadata)
        #expect(metadata[MemoryMetadataKeys.type] == MemoryType.taskState.rawValue)
        #expect(metadata[MemoryMetadataKeys.durability] == MemoryDurability.working.rawValue)
        #expect(metadata["session_id"] == sessionID)
    }
}

@Test
func knowledgeCaptureTaskStateUsesSessionLane() async throws {
    try await withTaskStateBroker { service, _ in
        let rejected = await service.handle(.init(
            command: "knowledge_capture",
            arguments: [
                "content": .string("knowledge diary without session"),
                "memory_type": .string("task_state"),
            ]
        ))
        #expect(!rejected.ok)

        let started = await service.handle(.init(command: "session_start"))
        let sessionID = try #require(started.payload?.objectValue?["session_id"]?.stringValue)
        let captured = await service.handle(.init(
            command: "knowledge_capture",
            arguments: [
                "content": .string("knowledge task state"),
                "session_id": .string(sessionID),
                "scope": .string("session"),
                "memory_type": .string("task_state"),
            ]
        ))
        #expect(captured.ok)
        let session = try await service.memory(for: UUID(uuidString: sessionID))
        let documents = try await session.corpusSourceDocuments()
        #expect(documents.count == 1)
        #expect(documents.first?.metadata[MemoryMetadataKeys.durability] == MemoryDurability.working.rawValue)
    }
}

@Test
func markdownTaskStateImportIsRejectedBeforeDurableWrite() async throws {
    try await withTaskStateBroker { service, rootURL in
        let text = "legacy Markdown task state"
        let marker = MarkdownProjectionMarker(
            sourceKind: MarkdownProjectionKind.memory.rawValue,
            hash: AgentBrokerService.stableHash(text),
            memoryType: MemoryType.taskState.rawValue,
            durability: MemoryDurability.durable.rawValue
        )
        let renderedLine = await service.renderManagedMarkdownLine(text: text, marker: marker)
        let markdown = "## task_state\n\(renderedLine)\n"
        let memoryURL = rootURL.appendingPathComponent("MEMORY.md")
        try markdown.write(to: memoryURL, atomically: true, encoding: .utf8)

        let response = await service.handle(.init(
            command: "markdown_sync",
            arguments: ["root_dir": .string(rootURL.path)]
        ))
        #expect(!response.ok)
        #expect((response.error ?? "").contains("task_state"))
        #expect(try await service.longTermMemory.corpusSourceDocuments().isEmpty)
    }
}

@Test
func taskStateMigrationIsCopyFirstAuditedAndIdempotent() async throws {
    try await withTaskStateBroker { service, rootURL in
        let started = await service.handle(.init(command: "session_start"))
        let sessionID = try #require(started.payload?.objectValue?["session_id"]?.stringValue)
        let sessionUUID = try #require(UUID(uuidString: sessionID))
        try await service.longTermMemory.remember(
            "legacy task state with valid provenance",
            metadata: [
                MemoryMetadataKeys.type: MemoryType.taskState.rawValue,
                MemoryMetadataKeys.durability: MemoryDurability.durable.rawValue,
                "session_id": sessionID,
            ]
        )
        try await service.longTermMemory.remember(
            "legacy orphan task state",
            metadata: [
                MemoryMetadataKeys.type: MemoryType.taskState.rawValue,
                MemoryMetadataKeys.durability: MemoryDurability.locked.rawValue,
                "session_id": UUID().uuidString,
            ]
        )
        try await service.longTermMemory.remember(
            "ordinary durable memory",
            metadata: [
                MemoryMetadataKeys.type: MemoryType.decision.rawValue,
                MemoryMetadataKeys.durability: MemoryDurability.durable.rawValue,
            ]
        )
        try await service.longTermMemory.flush()

        let destination = rootURL.appendingPathComponent("repaired.wax")
        let dryRun = await service.handle(.init(
            command: "task_state_migrate",
            arguments: [
                "destination_path": .string(destination.path),
                "dry_run": .bool(true),
            ]
        ))
        #expect(dryRun.ok)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(dryRun.payload?.objectValue?["rehomed_document_count"]?.intValue == 1)
        #expect(dryRun.payload?.objectValue?["quarantined_document_count"]?.intValue == 1)

        let migrated = await service.handle(.init(
            command: "task_state_migrate",
            arguments: ["destination_path": .string(destination.path)]
        ))
        #expect(migrated.ok)
        #expect(migrated.payload?.objectValue?["verified"]?.boolValue == true)
        #expect(migrated.payload?.objectValue?["source_preserved"]?.boolValue == true)

        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.enableStructuredMemory = false
        let repaired = try await MemoryOrchestrator(at: destination, config: config)
        let repairedDocuments = try await repaired.corpusSourceDocuments()
        #expect(repairedDocuments.count == 3)
        #expect(repairedDocuments.contains {
            $0.metadata[MemoryMetadataKeys.type] == MemoryType.taskState.rawValue &&
                $0.metadata[MemoryMetadataKeys.durability] == MemoryDurability.working.rawValue &&
                $0.metadata["session_id"] == sessionUUID.uuidString
        })
        #expect(repairedDocuments.contains {
            $0.metadata[MemoryMetadataKeys.migrationAction] == "quarantine" &&
                $0.metadata[MemoryMetadataKeys.type] == MemoryType.note.rawValue
        })
        try await repaired.close()

        let second = await service.handle(.init(
            command: "task_state_migrate",
            arguments: ["destination_path": .string(destination.path)]
        ))
        #expect(second.ok)
        #expect(second.payload?.objectValue?["idempotent"]?.boolValue == true)

        let dropDestination = rootURL.appendingPathComponent("repaired-drop.wax")
        let dropped = await service.handle(.init(
            command: "task_state_migrate",
            arguments: [
                "destination_path": .string(dropDestination.path),
                "orphan_policy": .string("drop"),
            ]
        ))
        #expect(dropped.ok)
        #expect(dropped.payload?.objectValue?["dropped_document_count"]?.intValue == 1)
        #expect(dropped.payload?.objectValue?["quarantined_document_count"]?.intValue == 0)
    }
}
#endif
