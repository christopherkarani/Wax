import Foundation
import Testing
import Wax

/// Keeps website / DocC copy-paste samples honest against the public `Memory` API.
enum DocumentationPaths {
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static var websiteDocs: URL {
        repoRoot.appendingPathComponent("Resources/website/docs")
    }

    static var doccArticles: URL {
        repoRoot.appendingPathComponent("Sources/Wax/Wax.docc/Articles")
    }
}

@Test
func websiteIOSDocsDoNotAdvertisePackageOnlyOrchestrator() throws {
    let iosDir = DocumentationPaths.websiteDocs.appendingPathComponent("ios")
    let files = try FileManager.default.contentsOfDirectory(
        at: iosDir,
        includingPropertiesForKeys: nil
    )
    #expect(!files.isEmpty)

    for file in files where file.pathExtension == "md" {
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(
            !text.contains("MemoryOrchestrator"),
            "\(file.lastPathComponent) must not teach MemoryOrchestrator to app developers"
        )
        #expect(
            !text.contains("await memory.foundationModelsSession"),
            "\(file.lastPathComponent): foundationModelsSession is synchronous"
        )
        #expect(
            !text.contains("await memory.foundationModelsTools"),
            "\(file.lastPathComponent): foundationModelsTools is synchronous"
        )
    }

    let intro = try String(
        contentsOf: DocumentationPaths.websiteDocs.appendingPathComponent("intro.md"),
        encoding: .utf8
    )
    #expect(intro.contains("`Memory`"))
    #expect(intro.contains("Foundation Models"))
}

@Test
func websiteGettingStartedUsesPublicMemoryQuickStart() throws {
    let path = DocumentationPaths.websiteDocs
        .appendingPathComponent("ios/getting-started.md")
    let text = try String(contentsOf: path, encoding: .utf8)

    #expect(text.contains("import Foundation\nimport Wax"))
    #expect(text.contains("let memory = try await Memory(at: url)"))
    #expect(text.contains("try await memory.save("))
    #expect(text.contains("try await memory.search("))
    #expect(text.contains("URL.documentsDirectory"))
    #expect(text.contains("https://github.com/christopherkarani/Wax.git"))
    #expect(text.contains("branch: \"main\""))
    #expect(!text.contains("from: \"0.1.24\""))
    #expect(!text.contains("MemoryOrchestrator"))
    #expect(!text.contains("remember("))
    #expect(!text.contains("recall(query:"))
}

@Test
func websiteFoundationModelsGuideMatchesPublicSessionAPI() throws {
    let path = DocumentationPaths.websiteDocs
        .appendingPathComponent("ios/foundation-models.md")
    let text = try String(contentsOf: path, encoding: .utf8)

    #expect(text.contains("import FoundationModels"))
    #expect(text.contains("memory.foundationModelsSession("))
    #expect(text.contains("FoundationModelsMemorySessionConfig"))
    #expect(text.contains("foundationModelsTools(kit:"))
    #expect(text.contains("WaxFoundationModelsAvailability"))
    #expect(text.contains("openFoundationModelsSession"))
    #expect(text.contains("respondDetailed"))
    #expect(text.contains("streamResponseAndCollect"))
    #expect(!text.contains("await memory.foundationModelsSession"))
    #expect(!text.contains("MemoryOrchestrator"))
}

@Test
func doccFoundationModelsDoesNotAwaitSynchronousSessionFactory() throws {
    let path = DocumentationPaths.doccArticles
        .appendingPathComponent("FoundationModels.md")
    let text = try String(contentsOf: path, encoding: .utf8)

    #expect(text.contains("let session = memory.foundationModelsSession("))
    #expect(!text.contains("await memory.foundationModelsSession"))
    #expect(!text.contains("await memory.foundationModelsTools"))
}

@Test
func documentationQuickStartSaveSearchRoundTrip() async throws {
    try await TempFiles.withTempFile { url in
        let memory = try await Memory(at: url) { config in
            config.enableVectorSearch = false
        }

        try await memory.save("The user is building a habit tracker in SwiftUI.")
        try await memory.save("Preferred theme: dark mode.")

        let results = try await memory.search(
            "What is the user building?",
            options: .init(mode: .textOnly, topK: 5)
        )
        #expect(!results.items.isEmpty)
        let joined = results.items.map(\.text).joined(separator: "\n")
        #expect(joined.localizedCaseInsensitiveContains("habit tracker"))

        if let diagnostics = results.diagnostics {
            #expect(diagnostics.effectiveMode.contains("text") || diagnostics.effectiveMode.contains("hybrid"))
        }

        try await memory.close()
    }
}

@Test
func documentationMemoryAPITextOnlyConfigOpens() async throws {
    try await TempFiles.withTempFile { url in
        let memory = try await Memory(at: url) { config in
            config.enableTextSearch = true
            config.enableVectorSearch = false
            config.ingestConcurrency = 1
            config.ingestBatchSize = 32
        }

        try await memory.save(
            "Had coffee with Alice. She mentioned the Q4 roadmap.",
            metadata: ["source": "docs"]
        )
        let results = try await memory.search(
            "Alice roadmap",
            options: .init(mode: .textOnly)
        )
        #expect(results.totalTokens >= 0)

        let stats = await memory.stats()
        #expect(stats.vectorSearchEnabled == false)

        try await memory.close()
    }
}
