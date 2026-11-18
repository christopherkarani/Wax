import Foundation
import Testing
import Wax
import WaxCore
@testable import wax_cli

/// Writes vectors under the pre-mean-pooling MiniLM identity.
private struct LegacyMiniLMEmbedder: EmbeddingProvider, Sendable {
    let dimensions = 384
    let normalize = true
    let identity: EmbeddingIdentity? = EmbeddingIdentity(
        provider: "Wax",
        model: "MiniLMAll",
        dimensions: 384,
        normalized: true
    )

    func embed(_ text: String) async throws -> [Float] {
        var vector = [Float](repeating: 0, count: dimensions)
        vector[abs(text.hashValue) % dimensions] = 1
        return vector
    }
}

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
                "--output", "/tmp/wax-backfill-out.wax",
            ])
        }
    }

    @Test func embedBackfillRefusesLiveFamilyPath() throws {
        #expect(throws: (any Error).self) {
            _ = try EmbedBackfillCommand.parse([
                "--direct-store",
                "--store-path", StoreSession.defaultStorePath,
                "--output", "/tmp/wax-backfill-out.wax",
            ])
        }
        #expect(throws: (any Error).self) {
            _ = try EmbedBackfillCommand.parse([
                "--direct-store",
                "--store-path", "~/.wax/memory.wax",
                "--output", "/tmp/wax-backfill-out.wax",
            ])
        }
        #expect(throws: (any Error).self) {
            _ = try EmbedBackfillCommand.parse([
                "--direct-store",
                "--store-path", "~/.wax/memory.wax ",
                "--output", "/tmp/wax-backfill-out.wax",
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
            "--output", FileManager.default.temporaryDirectory
                .appendingPathComponent("wax-backfill-out-\(UUID().uuidString).wax").path,
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
    @Test(.disabled(
        if: ProcessInfo.processInfo.environment["WAX_TEST_MINILM"] != "1",
        "Set WAX_TEST_MINILM=1 to run the end-to-end MiniLM re-embed"
    ))
    func embedBackfillReembedsStoreBoundToSupersededMiniLM() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-reembed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("stale.wax")
        let output = directory.appendingPathComponent("reembedded.wax")
        do {
            var config = OrchestratorConfig.default
            config.automaticallyReembedSupersededVectors = false
            let writer = try await MemoryOrchestrator(at: source, config: config, embedder: LegacyMiniLMEmbedder())
            try await writer.remember("The quarterly budget review moved to Thursday afternoon.")
            try await writer.remember("Grandma's apple pie needs a cold butter crust.")
            try await writer.close()
        }

        var command = try EmbedBackfillCommand.parse([
            "--direct-store",
            "--store-path", source.path,
            "--output", output.path,
            "--format", "json",
        ])
        try await command.runAsync()

        let sourceWax = try await Wax.open(at: source)
        let sourceModel: String? = await sourceWax.memoryBinding()?.embeddingModel
        try await sourceWax.close()
        #expect(sourceModel == "MiniLMAll")

        let outputWax = try await Wax.open(at: output)
        let outputModel: String? = await outputWax.memoryBinding()?.embeddingModel
        try await outputWax.close()
        #expect(outputModel == "MiniLMAll-mean")

        let reopened = try await StoreSession.open(at: output, requireVector: true)
        try await reopened.waitUntilReadyForRemember()
        let stats = await reopened.runtimeStats()
        let hits = try await reopened.search(query: "When is the budget review?", mode: .vectorOnly, topK: 1)
        try await reopened.close()
        #expect(!stats.vectorsNeedReembed)
        #expect(stats.framesWithoutVectors == 0)
        #expect(hits.first?.previewText?.contains("budget") == true)
    }
}
