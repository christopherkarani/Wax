import Foundation
import Testing
@testable import Wax

private struct InstallFailure: LocalizedError {
    var errorDescription: String? { "verification failed" }
}

private func withRollbackRoot<T>(_ body: (URL) throws -> T) throws -> T {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-migrate-rollback-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    return try body(root)
}

@Test
func migrationRollbackRestoresBackupAndRethrowsInstallError() throws {
    try withRollbackRoot { root in
        let backup = root.appendingPathComponent(".dest-backup")
        let destination = root.appendingPathComponent("dest.wax")
        try Data("previous".utf8).write(to: backup)

        let error = AgentBrokerService.restoreTaskStateMigrationBackup(
            backup,
            to: destination,
            after: InstallFailure()
        )
        #expect(error is InstallFailure)
        #expect(try Data(contentsOf: destination) == Data("previous".utf8))
        #expect(!FileManager.default.fileExists(atPath: backup.path))
    }
}

@Test
func migrationRollbackFailureNamesTheBackupPath() throws {
    try withRollbackRoot { root in
        let backup = root.appendingPathComponent(".dest-backup")
        try Data("previous".utf8).write(to: backup)
        // Parent directory does not exist, so the restore move fails.
        let destination = root.appendingPathComponent("missing/dest.wax")

        let error = AgentBrokerService.restoreTaskStateMigrationBackup(
            backup,
            to: destination,
            after: InstallFailure()
        )
        let message = error.localizedDescription
        #expect(message.contains(backup.path))
        #expect(message.contains("verification failed"))
        #expect(FileManager.default.fileExists(atPath: backup.path))
    }
}

// `wax.migration.source_frame_id` is ordinary client metadata on remember.
// Two rows sharing it must fail verification, not trap the broker.
@Test
func migrationVerificationFailsOnDuplicateForgedSourceFrameID() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-migrate-forged-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let service = try await AgentBrokerService(
        storePath: root.appendingPathComponent("memory.wax").path,
        sessionRootPath: root.appendingPathComponent("sessions", isDirectory: true).path,
        noEmbedder: true,
        embedderChoice: "auto",
        requireVector: false
    )
    do {
        for content in ["First forged migration marker.", "Second forged migration marker."] {
            let remembered = await service.handle(.init(command: "remember", arguments: [
                "content": .string(content),
                "metadata": .object([MemoryMetadataKeys.migrationSourceFrameID: .string("7")]),
            ]))
            #expect(remembered.ok, "remember failed: \(remembered.error ?? "nil")")
        }
        let stored = try await service.longTermMemory.corpusSourceDocuments()
        #expect(stored.filter { $0.metadata[MemoryMetadataKeys.migrationSourceFrameID] == "7" }.count == 2)

        let migrated = await service.handle(.init(command: "task_state_migrate", arguments: [
            "destination_path": .string(root.appendingPathComponent("repaired.wax").path),
        ]))
        #expect(!migrated.ok)
        #expect((migrated.error ?? "").contains("verification"), "error: \(migrated.error ?? "nil")")
        try await service.close()
    } catch {
        try? await service.close()
        throw error
    }
}
