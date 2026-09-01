import Foundation
import Testing
@testable import Wax
import WaxCore

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
        #expect((durable.error ?? "").contains("task_state"))

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
        #expect((locked.error ?? "").contains("task_state"))

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
        #expect((scopeDurable.error ?? "").contains("scope durable forbids session_id"))

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
func unclassifiedSessionWritesStayWorkingNotesNotTaskState() async throws {
    try await withTaskStateBroker { service, _ in
        let started = await service.handle(.init(command: "session_start"))
        let sessionID = try #require(started.payload?.objectValue?["session_id"]?.stringValue)

        let durable = await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("Durable memory anchor: Wax is the long-term source of truth."),
                "memory_type": .string("decision"),
                "durability": .string("durable"),
            ]
        ))
        #expect(durable.ok)
        #expect(durable.payload?.objectValue?["memory_id"]?.stringValue == "durable:0")

        let appended = await service.handle(.init(
            command: "memory_append",
            arguments: [
                "content": .string("Working memory anchor: current task is OpenClaw adapter implementation."),
                "session_id": .string(sessionID),
            ]
        ))
        #expect(appended.ok)
        #expect(appended.payload?.objectValue?["memory_type"]?.stringValue == MemoryType.note.rawValue)
        #expect(appended.payload?.objectValue?["durability"]?.stringValue == MemoryDurability.working.rawValue)
        let workingID = try #require(appended.payload?.objectValue?["memory_id"]?.stringValue)
        #expect(workingID.hasPrefix("working:\(sessionID):"))

        let search = await service.handle(.init(
            command: "memory_search",
            arguments: [
                "query": .string("anchor"),
                "session_id": .string(sessionID),
                "topK": .int(6),
                "mode": .string("text"),
            ]
        ))
        #expect(search.ok)
        let results = try #require(search.payload?.objectValue?["results"]?.arrayValue)
        #expect(results.contains { $0.objectValue?["horizon"]?.stringValue == "working" })
        #expect(results.contains { $0.objectValue?["horizon"]?.stringValue == "durable" })
        #expect(results.contains { $0.objectValue?["memory_id"]?.stringValue == workingID })
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
        #expect((rejected.error ?? "").contains("task_state"))

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
func taskStateMigrationRejectsUnsafeDestinationPaths() async throws {
    try await withTaskStateBroker { service, rootURL in
        let directoryDestination = rootURL.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryDestination, withIntermediateDirectories: false)
        let directoryResponse = await service.handle(.init(
            command: "task_state_migrate",
            arguments: ["destination_path": .string(directoryDestination.path)]
        ))
        #expect(!directoryResponse.ok)

        let symlinkTarget = rootURL.appendingPathComponent("symlink-target", isDirectory: true)
        let symlinkParent = rootURL.appendingPathComponent("symlink-parent", isDirectory: true)
        try FileManager.default.createDirectory(at: symlinkTarget, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: symlinkParent, withDestinationURL: symlinkTarget)
        let symlinkResponse = await service.handle(.init(
            command: "task_state_migrate",
            arguments: [
                "destination_path": .string(
                    symlinkParent.appendingPathComponent("repaired.wax").path
                )
            ]
        ))
        #expect(!symlinkResponse.ok)
        #expect(!FileManager.default.fileExists(
            atPath: symlinkTarget.appendingPathComponent("repaired.wax").path
        ))

        let sourceURL = rootURL.appendingPathComponent("memory.wax")
        let sourceAlias = rootURL.appendingPathComponent("source-alias.wax")
        try FileManager.default.linkItem(at: sourceURL, to: sourceAlias)
        let aliasResponse = await service.handle(.init(
            command: "task_state_migrate",
            arguments: [
                "destination_path": .string(sourceAlias.path),
                "overwrite_destination": .bool(true),
            ]
        ))
        #expect(!aliasResponse.ok)

        let symlinkDestinationTarget = rootURL.appendingPathComponent("destination-target.wax")
        let symlinkDestination = rootURL.appendingPathComponent("destination-link.wax")
        try Data("sentinel".utf8).write(to: symlinkDestinationTarget)
        try FileManager.default.createSymbolicLink(
            at: symlinkDestination,
            withDestinationURL: symlinkDestinationTarget
        )
        let destinationSymlinkResponse = await service.handle(.init(
            command: "task_state_migrate",
            arguments: [
                "destination_path": .string(symlinkDestination.path),
                "overwrite_destination": .bool(true),
            ]
        ))
        #expect(!destinationSymlinkResponse.ok)
        #expect(String(data: try Data(contentsOf: symlinkDestinationTarget), encoding: .utf8) == "sentinel")

        let lockedDestination = rootURL.appendingPathComponent("locked-destination.wax")
        let lockedContents = Data("locked-sentinel".utf8)
        try lockedContents.write(to: lockedDestination)
        let lock = try FileLock.acquire(at: lockedDestination, mode: .exclusive)
        let lockedResponse = await service.handle(.init(
            command: "task_state_migrate",
            arguments: [
                "destination_path": .string(lockedDestination.path),
                "overwrite_destination": .bool(true),
            ]
        ))
        try lock.release()
        #expect(!lockedResponse.ok)
        #expect(try Data(contentsOf: lockedDestination) == lockedContents)
    }
}

@Test
func taskStateMigrationIsCopyFirstAuditedAndIdempotent() async throws {
    try await withTaskStateBroker { service, rootURL in
        let started = await service.handle(.init(command: "session_start"))
        let sessionID = try #require(started.payload?.objectValue?["session_id"]?.stringValue)
        let sessionUUID = try #require(UUID(uuidString: sessionID))
        let retainedEntity = EntityKey("project:wax")
        let retainedPredicate = PredicateKey("status")
        _ = try await service.longTermMemory.upsertEntity(
            key: retainedEntity,
            kind: "project",
            aliases: ["Wax"]
        )
        _ = try await service.longTermMemory.assertFact(
            subject: retainedEntity,
            predicate: retainedPredicate,
            object: .string("active")
        )
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
        config.enableStructuredMemory = true
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
        #expect(try await repaired.entity(forKey: retainedEntity)?.key == retainedEntity)
        let retainedFacts = try await repaired.facts(
            about: retainedEntity,
            predicate: retainedPredicate,
            limit: 20
        )
        #expect(retainedFacts.hits.contains { hit in
            if case .string(let value) = hit.fact.object {
                return value == "active"
            }
            return false
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
