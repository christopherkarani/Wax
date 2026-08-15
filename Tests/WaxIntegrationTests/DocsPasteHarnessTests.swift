import Foundation
import Testing
import Wax

// MARK: - Pasteable samples (kept in lockstep with Resources/website/docs/ios)

/// Mirrors `waxQuickStart` from `ios/getting-started.md`.
func docsPaste_waxQuickStart(storeURL: URL) async throws -> String {
    let memory = try await Memory(at: storeURL) { config in
        // Force text-only so the sample runs on Linux CI without CoreML/MiniLM.
        config.enableVectorSearch = false
    }

    try await memory.save("The user is building a habit tracker in SwiftUI.")
    try await memory.save("Preferred theme: dark mode.")

    let results = try await memory.search(
        "What is the user building?",
        options: .init(mode: .textOnly)
    )
    guard let best = results.items.first?.text else {
        struct DocsPasteError: Error, CustomStringConvertible {
            var description: String
        }
        throw DocsPasteError(description: "docs paste quick start returned no hits")
    }
    try await memory.close()
    return best
}

/// Mirrors diagnostics sample from `ios/getting-started.md`.
func docsPaste_waxPrintSearchDiagnostics(storeURL: URL) async throws -> (
    requested: String,
    effective: String,
    vectorEnabled: Bool
) {
    let memory = try await Memory(at: storeURL) { config in
        config.enableVectorSearch = false
    }

    try await memory.save("Q4 roadmap notes with Alice.")
    let results = try await memory.search("roadmap", options: .init(mode: .textOnly))
    guard let diagnostics = results.diagnostics else {
        struct DocsPasteError: Error, CustomStringConvertible {
            var description: String
        }
        throw DocsPasteError(description: "docs paste diagnostics missing RAGContext.diagnostics")
    }

    let stats = await memory.stats()
    try await memory.close()
    return (
        diagnostics.requestedMode,
        diagnostics.effectiveMode,
        stats.vectorSearchEnabled
    )
}

/// Mirrors Memory API save + search + lifecycle samples.
func docsPaste_memoryAPIRoundTrip(storeURL: URL) async throws -> Int {
    let memory = try await Memory(at: storeURL) { config in
        config.enableTextSearch = true
        config.enableVectorSearch = false
        config.ingestConcurrency = 1
        config.ingestBatchSize = 32
    }

    try await memory.save("Had coffee with Alice. She mentioned the Q4 roadmap.")
    try await memory.save(
        "Team standup notes",
        metadata: ["source": "standup", "day": "2026-08-15"]
    )
    try await memory.flush()

    let lexical = try await memory.search(
        "Alice roadmap",
        options: .init(mode: .textOnly)
    )

    do {
        _ = try await memory.search(
            "roadmap discussion",
            options: .init(mode: .vectorOnly)
        )
        Issue.record("vectorOnly should fail without an embedder")
    } catch {
        // Expected when vector search is disabled / no embedder.
    }

    let hybrid = try await memory.search(
        "Alice roadmap",
        options: .init(mode: .hybrid(alpha: 0.7), topK: 12)
    )
    #expect(hybrid.items.count >= 0)

    let stats = await memory.stats()
    #expect(stats.vectorSearchEnabled == false)

    try await memory.close()
    return lexical.items.count
}

/// Mirrors custom embedder shape + `.custom` wiring from `ios/memory-api.md`.
actor DocsPasteMyEmbedder: EmbeddingProvider {
    let dimensions = 384
    let normalize = true
    let identity: EmbeddingIdentity? = .init(
        provider: "Local",
        model: "v1",
        dimensions: 384,
        normalized: true
    )

    func embed(_ text: String) async throws -> [Float] {
        var vector = [Float](repeating: 0, count: dimensions)
        let hash = text.utf8.reduce(0) { $0 &+ Int($1) }
        for i in 0..<dimensions {
            vector[i] = Float((hash &+ i) % 100) / 100.0
        }
        let norm = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
        if normalize, norm > 0 {
            for i in 0..<dimensions { vector[i] /= norm }
        }
        return vector
    }
}

func docsPaste_customEmbedderRoundTrip(storeURL: URL) async throws -> Int {
    let embedder = DocsPasteMyEmbedder()
    let memory = try await Memory(at: storeURL) { config in
        config.embedding = .custom(embedder)
    }
    try await memory.save("User prefers Vim keybindings.")
    let results = try await memory.search(
        "editor preferences",
        options: .init(mode: .hybrid(alpha: 0.5), topK: 5)
    )
    try await memory.close()
    return results.items.count
}

// MARK: - Executable validation

@Test
func docsPasteQuickStartRuns() async throws {
    try await TempFiles.withTempFile { url in
        let text = try await docsPaste_waxQuickStart(storeURL: url)
        #expect(text.localizedCaseInsensitiveContains("habit tracker"))
    }
}

@Test
func docsPasteDiagnosticsAndStatsRun() async throws {
    try await TempFiles.withTempFile { url in
        let result = try await docsPaste_waxPrintSearchDiagnostics(storeURL: url)
        #expect(!result.requested.isEmpty)
        #expect(!result.effective.isEmpty)
        #expect(result.vectorEnabled == false)
    }
}

@Test
func docsPasteMemoryAPIRoundTripRuns() async throws {
    try await TempFiles.withTempFile { url in
        let hits = try await docsPaste_memoryAPIRoundTrip(storeURL: url)
        #expect(hits >= 1)
    }
}

@Test
func docsPasteCustomEmbedderRuns() async throws {
    try await TempFiles.withTempFile { url in
        let hits = try await docsPaste_customEmbedderRoundTrip(storeURL: url)
        #expect(hits >= 1)
    }
}

// MARK: - Markdown paste-contract checks

@Test
func iosDocsSnippetsAreCompleteFunctionsNotBareTopLevelAwait() throws {
    let iosDir = DocumentationPaths.websiteDocs.appendingPathComponent("ios")
    let files = try FileManager.default.contentsOfDirectory(
        at: iosDir,
        includingPropertiesForKeys: nil
    )

    for file in files where file.pathExtension == "md" {
        let text = try String(contentsOf: file, encoding: .utf8)
        let blocks = text.components(separatedBy: "```swift")
        for (index, block) in blocks.dropFirst().enumerated() {
            let code = String(block.split(separator: "```", maxSplits: 1).first ?? "")
            let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            // Package.swift fragments are not executable app pastes.
            if trimmed.hasPrefix("dependencies:") || trimmed.hasPrefix(".target(") {
                continue
            }
            // SwiftUI view-modifier call sites are pasted onto an existing View.
            if trimmed.hasPrefix(".task") || trimmed.hasPrefix("Text(") {
                continue
            }

            let isTypeOrFunc =
                trimmed.contains("func ")
                || trimmed.contains("struct ")
                || trimmed.contains("actor ")
                || trimmed.contains("@available")
            #expect(
                isTypeOrFunc,
                "\(file.lastPathComponent) swift block #\(index + 1) must be a complete pasteable type/func, not a bare fragment"
            )

            #expect(
                !trimmed.contains("defer { try? await"),
                "\(file.lastPathComponent) block #\(index + 1): defer cannot await"
            )
        }
    }
}

@Test
func iosDocsPinMainNotBrokenRelease024() throws {
    let gettingStarted = try String(
        contentsOf: DocumentationPaths.websiteDocs.appendingPathComponent("ios/getting-started.md"),
        encoding: .utf8
    )
    #expect(gettingStarted.contains("branch: \"main\""))
    #expect(gettingStarted.contains("0.1.24") == false || gettingStarted.contains("package-only"))
    #expect(!gettingStarted.contains("from: \"0.1.24\""))

    let fm = try String(
        contentsOf: DocumentationPaths.websiteDocs.appendingPathComponent("ios/foundation-models.md"),
        encoding: .utf8
    )
    #expect(fm.contains("func chatWithMemory()"))
    #expect(fm.contains("WaxFoundationModelsAvailability.current()"))
    #expect(!fm.contains("await memory.foundationModelsSession"))
}

#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Test
func docsPasteFoundationModelsSessionCompilesAndCloses() async throws {
    try await TempFiles.withTempFile { url in
        let memory = try await Memory(at: url) { config in
            config.enableVectorSearch = false
        }
        let session = memory.foundationModelsSession(
            instructions: "You are a helpful assistant with durable on-device memory."
        )
        _ = makeConfiguredSessionForDocs(memory: memory)
        _ = memory.foundationModelsTools(kit: .focusedWithForget)

        switch WaxFoundationModelsAvailability.current() {
        case .available:
            // Device-dependent generation — do not require Apple Intelligence in CI.
            break
        case .unavailable:
            break
        }

        let fresh = await session.resetConversationPreservingMemory()
        try await fresh.close()
        try await session.close()
        try await memory.close()
    }
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
private func makeConfiguredSessionForDocs(memory: Memory) -> WaxFoundationModelSession {
    var configuration = FoundationModelsMemorySessionConfig.default
    configuration.contextStrategy = .hybrid
    configuration.persistencePolicy = .userAndAssistant
    configuration.embeddingPolicy = .automatic
    configuration.toolKit = .focused
    return memory.foundationModelsSession(
        instructions: "Be concise.",
        configuration: configuration
    )
}
#endif
