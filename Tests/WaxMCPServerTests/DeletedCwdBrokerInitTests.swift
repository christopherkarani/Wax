import Foundation
import Testing
@testable import Wax

@Suite(.serialized)
struct DeletedCwdBrokerInitTests {
    @Test
    func agentBrokerServiceInitCompletesWhenCurrentDirectoryIsDeleted() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-deleted-cwd-broker-\(UUID().uuidString)", isDirectory: true)
        let storeURL = rootURL.appendingPathComponent("memory.wax")
        let sessionRootURL = rootURL.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let fileManager = FileManager.default
        let original = fileManager.currentDirectoryPath
        let doomed = fileManager.temporaryDirectory
            .appendingPathComponent("wax-deleted-cwd-init-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: doomed, withIntermediateDirectories: true)
        guard fileManager.changeCurrentDirectoryPath(doomed.path) else {
            Issue.record("failed to enter temporary directory \(doomed.path)")
            return
        }
        try fileManager.removeItem(at: doomed)
        defer {
            if !original.isEmpty {
                _ = fileManager.changeCurrentDirectoryPath(original)
            }
        }

        let service = try await withThrowingTaskGroup(of: AgentBrokerService.self) { group in
            group.addTask {
                try await AgentBrokerService(
                    storePath: storeURL.path,
                    sessionRootPath: sessionRootURL.path,
                    noEmbedder: true,
                    embedderChoice: "auto",
                    requireVector: false
                )
            }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw TimeoutError()
            }
            guard let first = try await group.next() else {
                throw TimeoutError()
            }
            group.cancelAll()
            return first
        }
        try await service.close()
    }
}

private struct TimeoutError: Error {}
