import Foundation
import Testing
import Wax
import WaxCore
import WaxTextSearch
import WaxVectorSearch

@Test
func optimizeSurrogatesCreatesSurrogateFramesAndExcludesFromDefaultSearch() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.chunking = .tokenCount(targetTokens: 8, overlapTokens: 2)
        config.rag = FastRAGConfig(
            maxContextTokens: 80,
            expansionMaxTokens: 30,
            snippetMaxTokens: 15,
            maxSnippets: 10,
            searchTopK: 25,
            searchMode: .textOnly
        )

        let sentence = "Swift concurrency uses actors and tasks. Actors isolate mutable state."
        let content = Array(repeating: sentence, count: 40).joined(separator: " ")
        let expectedChunks = await TextChunker.chunk(text: content, strategy: config.chunking)

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        try await orchestrator.remember(content, metadata: ["source": "test"])
        try await orchestrator.flush()

        let report = try await orchestrator.optimizeSurrogates()
        #expect(report.generatedSurrogates == expectedChunks.count)

        try await orchestrator.close()

        let wax = try await Wax.open(at: url)
        let stats = await wax.stats()
        #expect(stats.frameCount == UInt64(1 + expectedChunks.count + expectedChunks.count))

        let metas = await wax.frameMetas()
        let surrogates = metas.filter { $0.kind == "surrogate" }
        #expect(surrogates.count == expectedChunks.count)
        #expect(surrogates.allSatisfy { $0.metadata?.entries["source_frame_id"] != nil })
        #expect(surrogates.allSatisfy { $0.metadata?.entries["surrogate_algo"] != nil })
        #expect(surrogates.allSatisfy { $0.metadata?.entries["surrogate_version"] != nil })
        #expect(surrogates.allSatisfy { $0.metadata?.entries["source_content_hash"] != nil })
        #expect(surrogates.allSatisfy { $0.metadata?.entries["surrogate_max_tokens"] != nil })

        let search = try await wax.search(.init(query: "actors", mode: .textOnly, topK: 50))
        for result in search.results {
            let meta = try await wax.frameMeta(frameId: result.frameId)
            #expect(meta.kind != "surrogate")
        }

        try await wax.close()
    }
}

@Test
func denseCachedRecallIncludesSurrogatesInContext() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.chunking = .tokenCount(targetTokens: 8, overlapTokens: 2)
        config.rag = FastRAGConfig(
            mode: .denseCached,
            maxContextTokens: 120,
            expansionMaxTokens: 30,
            snippetMaxTokens: 12,
            maxSnippets: 10,
            maxSurrogates: 4,
            surrogateMaxTokens: 20,
            searchTopK: 25,
            searchMode: .textOnly
        )

        let sentence = "Swift concurrency uses actors and tasks. Actors isolate mutable state."
        let content = Array(repeating: sentence, count: 40).joined(separator: " ")
        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        try await orchestrator.remember(content)
        try await orchestrator.flush()
        _ = try await orchestrator.optimizeSurrogates()

        let ctx = try await orchestrator.recall(query: "actors")
        #expect(ctx.items.contains { $0.kind == .surrogate })
        #expect(ctx.items.filter { $0.kind == .expanded }.count <= 1)

        // Ensure packing order: expansion first (if present), then surrogates, then snippets.
        if ctx.items.contains(where: { $0.kind == .expanded }) {
            #expect(ctx.items.first?.kind == .expanded)
            #expect(ctx.items.dropFirst().contains { $0.kind == .surrogate })
        }

        try await orchestrator.close()
    }
}

@Test
func optimizeSurrogatesWithoutExplicitFlushStillGeneratesSurrogatesForNewChunks() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.chunking = .tokenCount(targetTokens: 8, overlapTokens: 2)
        config.rag = FastRAGConfig(
            mode: .denseCached,
            maxContextTokens: 120,
            expansionMaxTokens: 30,
            snippetMaxTokens: 12,
            maxSnippets: 10,
            maxSurrogates: 4,
            surrogateMaxTokens: 20,
            searchTopK: 25,
            searchMode: .textOnly
        )

        let sentence = "Swift concurrency uses actors and tasks. Actors isolate mutable state."
        let content = Array(repeating: sentence, count: 40).joined(separator: " ")
        let expectedChunks = await TextChunker.chunk(text: content, strategy: config.chunking)

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        try await orchestrator.remember(content)

        let report = try await orchestrator.optimizeSurrogates()
        #expect(report.generatedSurrogates == expectedChunks.count)

        let ctx = try await orchestrator.recall(query: "actors")
        #expect(ctx.items.contains { $0.kind == .surrogate })

        try await orchestrator.close()
    }
}

@Test
func optimizeSurrogatesSkipsUpToDateSurrogatesByDefault() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.chunking = .tokenCount(targetTokens: 8, overlapTokens: 2)

        let sentence = "Swift concurrency uses actors and tasks. Actors isolate mutable state."
        let content = Array(repeating: sentence, count: 40).joined(separator: " ")
        let expectedChunks = await TextChunker.chunk(text: content, strategy: config.chunking)

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        try await orchestrator.remember(content)
        try await orchestrator.flush()

        let first = try await orchestrator.optimizeSurrogates()
        #expect(first.generatedSurrogates == expectedChunks.count)

        let second = try await orchestrator.optimizeSurrogates()
        #expect(second.generatedSurrogates == 0)
        #expect(second.supersededSurrogates == 0)
        #expect(second.skippedUpToDate == expectedChunks.count)

        try await orchestrator.close()

        let wax = try await Wax.open(at: url)
        let metas = await wax.frameMetas()
        let activeSurrogates = metas.filter { $0.kind == "surrogate" && $0.status == .active && $0.supersededBy == nil }
        #expect(activeSurrogates.count == expectedChunks.count)
        try await wax.close()
    }
}

@Test
func optimizeSurrogatesRegeneratesWhenSurrogateMaxTokensChanges() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.chunking = .tokenCount(targetTokens: 8, overlapTokens: 2)

        let sentence = "Swift concurrency uses actors and tasks. Actors isolate mutable state."
        let content = Array(repeating: sentence, count: 40).joined(separator: " ")
        let expectedChunks = await TextChunker.chunk(text: content, strategy: config.chunking)

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        try await orchestrator.remember(content)
        try await orchestrator.flush()

        let first = try await orchestrator.optimizeSurrogates(options: .init(surrogateMaxTokens: 10))
        #expect(first.generatedSurrogates == expectedChunks.count)

        let second = try await orchestrator.optimizeSurrogates(options: .init(surrogateMaxTokens: 20))
        #expect(second.generatedSurrogates == expectedChunks.count)
        #expect(second.supersededSurrogates == expectedChunks.count)
        #expect(second.skippedUpToDate == 0)

        try await orchestrator.close()
    }
}

@Test
func optimizeSurrogatesOverwriteExistingRegeneratesAndSupersedes() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.chunking = .tokenCount(targetTokens: 8, overlapTokens: 2)

        let sentence = "Swift concurrency uses actors and tasks. Actors isolate mutable state."
        let content = Array(repeating: sentence, count: 40).joined(separator: " ")
        let expectedChunks = await TextChunker.chunk(text: content, strategy: config.chunking)

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        try await orchestrator.remember(content)
        try await orchestrator.flush()

        _ = try await orchestrator.optimizeSurrogates()
        let overwrite = try await orchestrator.optimizeSurrogates(options: .init(overwriteExisting: true))
        #expect(overwrite.generatedSurrogates == expectedChunks.count)
        #expect(overwrite.supersededSurrogates == expectedChunks.count)

        try await orchestrator.close()

        let wax = try await Wax.open(at: url)
        let metas = await wax.frameMetas()
        let allSurrogates = metas.filter { $0.kind == "surrogate" }
        let activeSurrogates = allSurrogates.filter { $0.status == .active && $0.supersededBy == nil }
        let supersededSurrogates = allSurrogates.filter { $0.supersededBy != nil }
        #expect(activeSurrogates.count == expectedChunks.count)
        #expect(supersededSurrogates.count == expectedChunks.count)
        try await wax.close()
    }
}

@Test
func optimizeSurrogatesRespectsMaxFramesLimit() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.chunking = .tokenCount(targetTokens: 8, overlapTokens: 2)

        let sentence = "Swift concurrency uses actors and tasks. Actors isolate mutable state."
        let content = Array(repeating: sentence, count: 40).joined(separator: " ")

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        try await orchestrator.remember(content)
        try await orchestrator.flush()

        let report = try await orchestrator.optimizeSurrogates(options: .init(maxFrames: 2))
        #expect(report.eligibleFrames == 2)
        #expect(report.generatedSurrogates == 2)
        #expect(report.didTimeout == false)

        try await orchestrator.close()

        let wax = try await Wax.open(at: url)
        let metas = await wax.frameMetas()
        let activeSurrogates = metas.filter { $0.kind == "surrogate" && $0.status == .active && $0.supersededBy == nil }
        #expect(activeSurrogates.count == 2)

        let sourceIds = Set(activeSurrogates.compactMap { $0.metadata?.entries["source_frame_id"] }.compactMap(UInt64.init))
        #expect(sourceIds == Set<UInt64>([1, 2]))
        try await wax.close()
    }
}

@Test
func optimizeSurrogatesMaxWallTimeZeroDoesNoWorkAndFlagsTimeout() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.chunking = .tokenCount(targetTokens: 8, overlapTokens: 2)

        let sentence = "Swift concurrency uses actors and tasks. Actors isolate mutable state."
        let content = Array(repeating: sentence, count: 40).joined(separator: " ")

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        try await orchestrator.remember(content)
        try await orchestrator.flush()

        let report = try await orchestrator.optimizeSurrogates(options: .init(maxWallTimeMs: 0))
        #expect(report.generatedSurrogates == 0)
        #expect(report.didTimeout == true)

        try await orchestrator.close()
    }
}

@Test
func denseCachedRecallDoesNotDuplicateSnippetsForSurrogateSources() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.chunking = .tokenCount(targetTokens: 8, overlapTokens: 2)
        config.rag = FastRAGConfig(
            mode: .denseCached,
            maxContextTokens: 200,
            expansionMaxTokens: 20,
            snippetMaxTokens: 12,
            maxSnippets: 10,
            maxSurrogates: 3,
            surrogateMaxTokens: 10,
            searchTopK: 25,
            searchMode: .textOnly
        )

        let sentence = "Swift concurrency uses actors and tasks. Actors isolate mutable state."
        let content = Array(repeating: sentence, count: 40).joined(separator: " ")
        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        try await orchestrator.remember(content)
        try await orchestrator.flush()
        _ = try await orchestrator.optimizeSurrogates()

        let ctx = try await orchestrator.recall(query: "actors")
        try await orchestrator.close()

        let wax = try await Wax.open(at: url)
        let surrogateSourceIds: Set<UInt64> = try await {
            var ids: Set<UInt64> = []
            for item in ctx.items where item.kind == .surrogate {
                let meta = try await wax.frameMeta(frameId: item.frameId)
                let raw = meta.metadata?.entries["source_frame_id"]
                let id = raw.flatMap(UInt64.init)
                #expect(id != nil)
                if let id { ids.insert(id) }
            }
            return ids
        }()

        let snippetFrameIds = Set(ctx.items.filter { $0.kind == .snippet }.map(\.frameId))
        #expect(snippetFrameIds.isDisjoint(with: surrogateSourceIds))
        try await wax.close()
    }
}

@Test
func optimizeSurrogatesSkipsUpToDateAndOverwritesWhenRequested() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.chunking = .tokenCount(targetTokens: 8, overlapTokens: 2)

        let sentence = "Swift concurrency uses actors and tasks. Actors isolate mutable state."
        let content = Array(repeating: sentence, count: 30).joined(separator: " ")

        do {
            let orchestrator = try await MemoryOrchestrator(at: url, config: config)
            try await orchestrator.remember(content)
            try await orchestrator.flush()

            let report = try await orchestrator.optimizeSurrogates()
            #expect(report.generatedSurrogates > 0)

            try await orchestrator.close()
        }

        var chunkId: UInt64?
        var initialSurrogateId: UInt64?
        do {
            let wax = try await Wax.open(at: url)
            let metas = await wax.frameMetas()
            chunkId = metas.first(where: { $0.role == .chunk })?.id
            if let chunkId {
                initialSurrogateId = await wax.surrogateFrameId(sourceFrameId: chunkId)
            }
            #expect(chunkId != nil)
            #expect(initialSurrogateId != nil)
            try await wax.close()
        }

        do {
            let orchestrator = try await MemoryOrchestrator(at: url, config: config)
            let skipped = try await orchestrator.optimizeSurrogates()
            #expect(skipped.generatedSurrogates == 0)
            #expect(skipped.skippedUpToDate > 0)

            let overwritten = try await orchestrator.optimizeSurrogates(
                options: MaintenanceOptions(overwriteExisting: true)
            )
            #expect(overwritten.generatedSurrogates > 0)
            #expect(overwritten.supersededSurrogates > 0)

            try await orchestrator.close()
        }

        do {
            let wax = try await Wax.open(at: url)
            guard let chunkId, let initialSurrogateId else {
                #expect(Bool(false))
                try await wax.close()
                return
            }
            let newSurrogateId = await wax.surrogateFrameId(sourceFrameId: chunkId)
            #expect(newSurrogateId != nil)
            #expect(newSurrogateId != initialSurrogateId)
            if let newSurrogateId {
                let oldMeta = try await wax.frameMeta(frameId: initialSurrogateId)
                #expect(oldMeta.supersededBy == newSurrogateId)
            }
            try await wax.close()
        }
    }
}

@Test
func optimizeSurrogatesHonorsMaxFrames() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.chunking = .tokenCount(targetTokens: 6, overlapTokens: 1)

        let sentence = "Swift concurrency uses actors and tasks. Actors isolate mutable state."
        let content = Array(repeating: sentence, count: 24).joined(separator: " ")

        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        try await orchestrator.remember(content)
        try await orchestrator.flush()

        let report = try await orchestrator.optimizeSurrogates(options: .init(maxFrames: 1))
        #expect(report.generatedSurrogates == 1)

        try await orchestrator.close()

        let wax = try await Wax.open(at: url)
        let surrogates = await wax.frameMetas().filter { $0.kind == "surrogate" }
        #expect(surrogates.count == 1)
        try await wax.close()
    }
}
