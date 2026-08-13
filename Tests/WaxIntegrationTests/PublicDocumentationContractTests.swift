import Foundation
import Testing

/// Documentation contract for Task 13: public examples must match the shipping
/// `Memory(at:config:)` API, compile-marked snippets must exist, and size/trait/store
/// claims must be honest. Snippet compilation itself is owned by
/// `scripts/verify-public-swift-snippets.swift`.
@Suite("PublicDocumentationContractTests")
struct PublicDocumentationContractTests {
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static let publicDocRelativePaths = [
        "README.md",
        "Sources/Wax/Wax.docc/Documentation.md",
        "Sources/Wax/Wax.docc/Articles/GettingStarted.md",
        "Sources/Wax/Wax.docc/Articles/SessionManagement.md",
        "Sources/Wax/Wax.docc/Articles/FoundationModels.md",
        "Sources/Wax/Wax.docc/Articles/MigratingToMemoryConfigEmbedding.md",
        "Sources/Wax/Wax.docc/Articles/StructuredMemory.md",
        "Sources/Wax/Wax.docc/Articles/PhotoRAG.md",
        "Sources/Wax/Wax.docc/Articles/VideoRAG.md",
        "Sources/Wax/Wax.docc/Articles/RAGPipeline.md",
        "Resources/skills/public/wax/SKILL.md",
        "Resources/skills/public/wax/references/public-api.md",
        "Resources/skills/public/wax/references/constraints.md",
        "Resources/skills/public/wax/templates/init-store-embedder.md",
        "Resources/skills/public/wax/templates/remember-recall-lifecycle.md",
        "Resources/skills/public/wax/templates/hybrid-search.md",
        "Resources/skills/public/wax/templates/maintenance.md",
        "Resources/skills/public/wax/templates/video-rag-transcripts.md",
    ]

    private static let compileRequiredRelativePaths = [
        "README.md",
        "Sources/Wax/Wax.docc/Articles/GettingStarted.md",
        "Sources/Wax/Wax.docc/Articles/SessionManagement.md",
        "Sources/Wax/Wax.docc/Articles/FoundationModels.md",
        "Sources/Wax/Wax.docc/Articles/StructuredMemory.md",
        "Sources/Wax/Wax.docc/Articles/PhotoRAG.md",
        "Sources/Wax/Wax.docc/Articles/VideoRAG.md",
        "Sources/Wax/Wax.docc/Articles/RAGPipeline.md",
        "Resources/skills/public/wax/templates/init-store-embedder.md",
        "Resources/skills/public/wax/templates/remember-recall-lifecycle.md",
        "Resources/skills/public/wax/templates/hybrid-search.md",
        "Resources/skills/public/wax/templates/maintenance.md",
        "Resources/skills/public/wax/templates/video-rag-transcripts.md",
    ]

    /// Migration before/after blocks may quote the removed initializer.
    private static let removedInitializerExemptRelativePaths: Set<String> = [
        "Sources/Wax/Wax.docc/Articles/MigratingToMemoryConfigEmbedding.md",
    ]

    @Test
    func requiredPublicDocumentationFilesExist() throws {
        for relativePath in Self.publicDocRelativePaths {
            let url = Self.repoRoot.appendingPathComponent(relativePath)
            #expect(
                FileManager.default.fileExists(atPath: url.path),
                "missing required documentation file \(relativePath)"
            )
        }
    }

    @Test
    func removedMemoryEmbeddingInitializersAreGoneFromPublicDocs() throws {
        let forbidden = [
            "Memory(at: storeURL, embedding:",
            "Memory(\n    at: storeURL,\n    embedding:",
            "Memory(at: url, embedding:",
            "Memory(at: <STORE_URL>, embedding:",
            "``Memory/init(at:config:embedding:)``",
            "`Memory/init(at:config:embedding:)`",
            "init(at:config:embedding:)",
        ]
        for relativePath in Self.publicDocRelativePaths
        where !Self.removedInitializerExemptRelativePaths.contains(relativePath) {
            let text = try Self.read(relativePath)
            for token in forbidden {
                #expect(
                    !text.contains(token),
                    "\(relativePath) still documents removed initializer token: \(token)"
                )
            }
        }
    }

    @Test
    func publicDocsLinkTheShippingMemoryInitializer() throws {
        let session = try Self.read("Sources/Wax/Wax.docc/Articles/SessionManagement.md")
        #expect(session.contains("``Memory/init(at:config:)``"))
        #expect(!session.contains("``Memory/init(at:config:embedding:)``"))

        let gettingStarted = try Self.read("Sources/Wax/Wax.docc/Articles/GettingStarted.md")
        #expect(
            gettingStarted.contains("Memory(at:") && gettingStarted.contains("config"),
            "GettingStarted must show Memory(at:config:) or the configure-closure form"
        )
    }

    @Test
    func customEmbedderExampleIsInputDependentAndRanksIntendedMatch() throws {
        let surfaces = [
            "Sources/Wax/Wax.docc/Articles/GettingStarted.md",
            "Resources/skills/public/wax/SKILL.md",
            "Resources/skills/public/wax/templates/init-store-embedder.md",
        ]
        for relativePath in surfaces {
            let text = try Self.read(relativePath)
            #expect(
                !text.contains("[Float](repeating: 0.0, count:"),
                "\(relativePath) still presents an all-zero embedding vector"
            )
            #expect(
                !text.contains("[Float](repeating: 0, count:"),
                "\(relativePath) still presents an all-zero embedding vector"
            )
            #expect(
                text.contains("dimensions = 4") || text.contains("dimensions: Int = 4"),
                "\(relativePath) must use the Task 1 four-dimensional docs embedder"
            )
            #expect(
                text.localizedCaseInsensitiveContains("password"),
                "\(relativePath) must store two items and rank the password match first"
            )
        }
    }

    @Test
    func packageDeclarationsPinVersion020AndDocumentTraits() throws {
        let readme = try Self.read("README.md")
        let gettingStarted = try Self.read("Sources/Wax/Wax.docc/Articles/GettingStarted.md")
        let combined = readme + "\n" + gettingStarted

        #expect(combined.contains(
            #".package(url: "https://github.com/christopherkarani/Wax.git", from: "0.2.0")"#
        ))
        #expect(combined.contains(
            #".package(url: "https://github.com/christopherkarani/Wax.git", from: "0.2.0", traits: [])"#
        ))
        #expect(combined.contains(
            #".package(url: "https://github.com/christopherkarani/Wax.git", from: "0.2.0", traits: ["ArcticEmbeddings"])"#
        ))
        #expect(combined.contains("MiniLMEmbeddings"))
        #expect(combined.contains("approximately 43 MiB") || combined.contains("~43 MiB"))
        #expect(combined.contains("approximately 32 MiB") || combined.contains("~32 MiB"))
        #expect(combined.contains("swift-nio") || combined.contains("SwiftNIO"))
        #expect(combined.localizedCaseInsensitiveContains("GRDB"))
        #expect(combined.contains("MetalANNS"))
        #expect(combined.contains("swift-crypto"))
        #expect(combined.contains("swift-asn1"))
    }

    @Test
    func storeSizeLanguageStatesLogicalAndAllocatedBehavior() throws {
        let readme = try Self.read("README.md")
        let gettingStarted = try Self.read("Sources/Wax/Wax.docc/Articles/GettingStarted.md")
        let combined = readme + "\n" + gettingStarted
        #expect(combined.contains("4 MiB") || combined.contains("4 MiB"))
        #expect(combined.contains("256 MiB") || combined.contains("256 MiB"))
        #expect(combined.localizedCaseInsensitiveContains("logical"))
        #expect(combined.localizedCaseInsensitiveContains("allocated"))
        #expect(combined.localizedCaseInsensitiveContains("close"))
        #expect(
            !readme.contains("iCloud Drive, Dropbox, AirDrop — whatever you already use."),
            "README must not claim arbitrary cloud-sync safety"
        )
    }

    @Test
    func compileMarkedSnippetsCoverReadmeDocCAndTemplates() throws {
        for relativePath in Self.compileRequiredRelativePaths {
            let text = try Self.read(relativePath)
            #expect(
                text.contains("```swift compile"),
                "\(relativePath) must contain at least one fenced swift block with a compile marker"
            )
        }
    }

    @Test
    func publicDocsExposeStructuredPhotoAndVideoFacades() throws {
        let structured = try Self.read("Sources/Wax/Wax.docc/Articles/StructuredMemory.md")
        #expect(structured.contains("upsertEntity"))
        #expect(structured.contains("resolveEntities"))
        #expect(structured.contains("assertFact"))
        #expect(structured.contains("retractFact"))
        #expect(structured.contains(".hits"))
        #expect(structured.contains("enableStructuredMemory"))

        let photo = try Self.read("Sources/Wax/Wax.docc/Articles/PhotoRAG.md")
        #expect(photo.contains("PhotoMemory.open"))
        #expect(photo.contains("MultimodalEmbeddingProvider"))
        #expect(photo.contains("onDeviceOnly"))
        #expect(photo.contains("assetID"))
        #expect(photo.contains("thumbnail"))
        #expect(!photo.contains("`EmbeddingProvider`"))
        #expect(!photo.contains("``EmbeddingProvider``"))

        let video = try Self.read("Sources/Wax/Wax.docc/Articles/VideoRAG.md")
        #expect(video.contains("VideoMemory.open"))
        #expect(video.contains("VideoTranscriptProvider"))
        #expect(video.contains("ingest(files:"))

        let catalog = try Self.read("Sources/Wax/Wax.docc/Documentation.md")
        #expect(catalog.contains("<doc:StructuredMemory>"))
        #expect(catalog.contains("<doc:MigratingToMemoryConfigEmbedding>"))
        #expect(!catalog.contains("Package-only advanced surfaces** — Photo RAG, Video RAG"))
    }

    @Test
    func ragAndEnrichmentPublicConfigIsDocumented() throws {
        let rag = try Self.read("Sources/Wax/Wax.docc/Articles/RAGPipeline.md")
        #expect(rag.contains("Memory.RAGConfig") || rag.contains("``Memory/RAGConfig``"))
        #expect(rag.contains("maxContextTokens"))
        #expect(rag.contains("searchTopK"))
        #expect(rag.contains("answerRerankWindow"))
        #expect(rag.contains("answerDistractorPenalty"))
        #expect(rag.contains("EnrichmentPolicy") || rag.contains("``Memory/EnrichmentPolicy``"))

        let api = try Self.read("Resources/skills/public/wax/references/public-api.md")
        #expect(api.contains("EnrichmentPolicy"))
        #expect(!api.contains("enableAsyncEnrichment"))
        #expect(api.contains("PhotoMemory"))
        #expect(api.contains("VideoMemory"))
        #expect(api.contains("upsertEntity"))
    }

    @Test
    func foundationModelsDocsMatchOwningFactoryAndTypedErrors() throws {
        let fm = try Self.read("Sources/Wax/Wax.docc/Articles/FoundationModels.md")
        #expect(fm.contains("makeFoundationModelsSession"))
        #expect(fm.contains("WaxFoundationModelsError"))
        #expect(fm.contains("WaxGenerationStream"))
        #expect(fm.contains("openFoundationModelsTools"))
        #expect(fm.contains("ownsMemoryStore") || fm.contains("owns the store"))
    }

    @Test
    func skillAndTemplatesUsePublicMemoryConfigEmbedding() throws {
        let skill = try Self.read("Resources/skills/public/wax/SKILL.md")
        #expect(skill.contains("config.embedding = .custom"))
        #expect(skill.contains("PhotoMemory") || skill.contains("structured"))
        #expect(!skill.contains("MemoryOrchestrator(at:"))

        let lifecycle = try Self.read(
            "Resources/skills/public/wax/templates/remember-recall-lifecycle.md"
        )
        #expect(!lifecycle.contains("embedding: <EMBEDDER_TYPE>()"))
        #expect(lifecycle.contains("config.embedding") || lifecycle.contains(".custom("))
    }

    private static func read(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
