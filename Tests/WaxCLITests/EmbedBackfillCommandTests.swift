import Foundation
import Testing
import Wax
import WaxCore
@testable import wax_cli

struct EmbedBackfillCommandTests {
    @Test func waxCLIExposesEmbedBackfillCommand() throws {
        let source = try String(
            contentsOfFile: "Sources/WaxCLI/WaxCLICommand.swift",
            encoding: .utf8
        )
        #expect(source.contains("EmbedBackfillCommand.self"))
    }

    @Test func embedBackfillRequiresDirectStoreFlag() throws {
        #expect(throws: (any Error).self) {
            _ = try EmbedBackfillCommand.parse([
                "--store-path", "/tmp/wax-backfill.wax",
                "--no-embedder",
            ])
        }
    }

    @Test func embedBackfillNoEmbedderFailsClosed() async throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-backfill-\(UUID().uuidString)")
            .appendingPathExtension("wax")
        defer { try? FileManager.default.removeItem(at: storeURL) }

        do {
            var config = OrchestratorConfig.default
            config.enableVectorSearch = false
            let memory = try await MemoryOrchestrator(at: storeURL, config: config)
            try await memory.remember("text-only frame must not invent vectors")
            try await memory.flush()
            try await memory.close()
        }

        var command = try EmbedBackfillCommand.parse([
            "--direct-store",
            "--no-embedder",
            "--store-path", storeURL.path,
            "--format", "json",
        ])
        do {
            try await command.runAsync()
            Issue.record("embed-backfill --no-embedder must fail closed")
        } catch let error as CLIError {
            #expect(error.message.lowercased().contains("embedder") || error.message.lowercased().contains("no-embedder"))
        } catch let error as WaxError {
            guard case .missingEmbedder = error else {
                Issue.record("expected WaxError.missingEmbedder, got \(error)")
                return
            }
        }

        let reopened = try await MemoryOrchestrator(at: storeURL, config: {
            var config = OrchestratorConfig.default
            config.enableVectorSearch = false
            return config
        }())
        let stats = await reopened.runtimeStats()
        #expect(stats.embeddingStatus == .disabled)
        try await reopened.close()
    }
}
