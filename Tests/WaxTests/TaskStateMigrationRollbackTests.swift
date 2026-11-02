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
        #expect(FileManager.default.fileExists(atPath: backup.path) == false)
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
