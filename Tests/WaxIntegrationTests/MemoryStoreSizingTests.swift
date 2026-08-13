import Foundation
#if canImport(Darwin)
import Darwin
#endif
import Testing
import Wax
import WaxCore

@Suite("MemoryStoreSizingTests")
struct MemoryStoreSizingTests {
    private static let fourMiB: UInt64 = 4 * 1024 * 1024
    private static let eightMiB: UInt64 = 8 * 1024 * 1024
    private static let oneMiB: UInt64 = 1 * 1024 * 1024
    private static let legacy256MiB: UInt64 = 256 * 1024 * 1024
    private static let walRecordHeaderMinimum = Constants.walRecordHeaderSize

    @Test
    func newMemoryStoreUsesFourMiBPublicWalDefault() async throws {
        try await TempFiles.withTempFile { url in
            let memory = try await Memory(at: url, config: .init(enableVectorSearch: false))
            try await memory.save("small payload")
            try await memory.close()

            let sizes = try StoreFileSize.measure(url)
            #expect(
                sizes.logical < Self.eightMiB,
                "logical=\(sizes.logical) allocated=\(sizes.allocated) statAllocated=\(sizes.statAllocated)"
            )

            let walSize = try await Self.headerWalSize(at: url)
            #expect(walSize == Memory.Config.defaultWalSizeBytes)
            #expect(Memory.Config.defaultWalSizeBytes == Self.fourMiB)
        }
    }

    @Test
    func configuredOneMiBWalStaysNearOneMiBLogical() async throws {
        try await TempFiles.withTempFile { url in
            let memory = try await Memory(
                at: url,
                config: .init(enableVectorSearch: false, walSizeBytes: Self.oneMiB)
            )
            try await memory.save("one-mib payload")
            try await memory.close()

            let sizes = try StoreFileSize.measure(url)
            #expect(
                sizes.logical < 3 * 1024 * 1024,
                "logical=\(sizes.logical) allocated=\(sizes.allocated)"
            )
            #expect(try await Self.headerWalSize(at: url) == Self.oneMiB)
        }
    }

    @Test
    func walSizeBelowRecordHeaderThrowsInvalidConfigurationBeforeOpen() async throws {
        try await TempFiles.withTempFile { url in
            let config = Memory.Config(
                enableVectorSearch: false,
                walSizeBytes: Self.walRecordHeaderMinimum - 1
            )
            do {
                _ = try await Memory(at: url, config: config)
                Issue.record("expected WaxError.invalidConfiguration for WAL size \(Self.walRecordHeaderMinimum - 1)")
            } catch let error as WaxError {
                guard case .invalidConfiguration(let reason) = error else {
                    Issue.record("expected WaxError.invalidConfiguration, got \(error)")
                    return
                }
                #expect(reason.contains("\(Self.walRecordHeaderMinimum)"))
            }
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test
    func zeroWalSizeThrowsInvalidConfiguration() async throws {
        try await TempFiles.withTempFile { url in
            do {
                _ = try await Memory(
                    at: url,
                    config: .init(enableVectorSearch: false, walSizeBytes: 0)
                )
                Issue.record("expected WaxError.invalidConfiguration for WAL size 0")
            } catch let error as WaxError {
                guard case .invalidConfiguration = error else {
                    Issue.record("expected WaxError.invalidConfiguration, got \(error)")
                    return
                }
            }
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test
    func defaultPublicWalTriggersAtLeastThreeProactiveCommits() async throws {
        try await TempFiles.withTempFile { url in
            var config = OrchestratorConfig.default
            config.enableVectorSearch = false
            config.walSizeBytes = Memory.Config.defaultWalSizeBytes
            let orchestrator = try await MemoryOrchestrator(at: url, config: config)

            var acknowledged: [String] = []
            var autoCommits: UInt64 = 0
            // 80% of the 4 MiB public WAL is 3.2 MiB per proactive commit. Each
            // remember must refill that threshold; 8 KiB × 400 only covers one cycle.
            for index in 0..<1_500 {
                let text = "proactive-commit-\(index)-" + String(repeating: "p", count: 32_768)
                try await orchestrator.remember(text)
                acknowledged.append(text)
                autoCommits = (await orchestrator.runtimeStats()).wal.autoCommitCount
                if autoCommits >= 3 { break }
            }
            #expect(autoCommits >= 3, "autoCommitCount=\(autoCommits) after \(acknowledged.count) writes")
            #expect(!acknowledged.isEmpty)

            try await orchestrator.close()
            try await Self.assertAcknowledgedTextsSurviveReopen(at: url, texts: acknowledged)
        }
    }

    @Test
    func defaultPublicWalCommitsUnderPendingEmbeddingPressureAndSurvivesReopen() async throws {
        try await TempFiles.withTempFile { url in
            var config = OrchestratorConfig.default
            config.enableVectorSearch = true
            config.enableTextSearch = true
            config.vectorEnginePreference = .cpuOnly
            config.walSizeBytes = Memory.Config.defaultWalSizeBytes
            let orchestrator = try await MemoryOrchestrator(
                at: url,
                config: config,
                embedder: DeterministicTextEmbedder(dimensions: 2)
            )

            var acknowledged: [String] = []
            var autoCommits: UInt64 = 0
            for index in 0..<1_500 {
                let text = "embed-pressure-\(index)-" + String(repeating: "e", count: 32_768)
                try await orchestrator.remember(text)
                acknowledged.append(text)
                autoCommits = (await orchestrator.runtimeStats()).wal.autoCommitCount
                if autoCommits >= 1 { break }
            }
            #expect(
                autoCommits >= 1,
                "pending embeddings must not block 4 MiB WAL pressure commits; autoCommitCount=\(autoCommits) after \(acknowledged.count) writes"
            )
            #expect(!acknowledged.isEmpty)

            try await orchestrator.close()

            let inspect = try await WaxCore.Wax.open(at: url)
            let committedTexts = Set((await inspect.frameMetas()).compactMap(\.searchText))
            try await inspect.close()

            var reopenConfig = OrchestratorConfig.default
            reopenConfig.enableVectorSearch = true
            reopenConfig.enableTextSearch = true
            reopenConfig.vectorEnginePreference = .cpuOnly
            let reopened = try await MemoryOrchestrator(
                at: url,
                config: reopenConfig,
                embedder: DeterministicTextEmbedder(dimensions: 2)
            )
            for text in acknowledged {
                let prefix = String(text.prefix(24))
                #expect(
                    committedTexts.contains { $0.hasPrefix(prefix) },
                    "missing acknowledged embedded text prefix \(prefix) after reopen"
                )
            }
            try await reopened.close()
        }
    }

    @Test
    func reopenAcrossTwoCloseCyclesPreservesAcknowledgedFrames() async throws {
        try await TempFiles.withTempFile { url in
            let texts = (0..<8).map { "n-minus-cycle-\($0)-unique-payload" }
            do {
                let memory = try await Memory(at: url, config: .init(enableVectorSearch: false))
                for text in texts {
                    try await memory.save(text)
                }
                try await memory.flush()
                try await Self.assertNoDuplicateFrameIDs(in: memory, query: "n-minus-cycle")
                try await memory.close()
            }

            // N-1
            do {
                let memory = try await Memory(at: url, config: .init(enableVectorSearch: false))
                try await Self.assertAllTextsPresent(in: memory, texts: texts)
                try await Self.assertNoDuplicateFrameIDs(in: memory, query: "n-minus-cycle")
                try await memory.close()
            }

            // N-2
            do {
                let memory = try await Memory(at: url, config: .init(enableVectorSearch: false))
                try await Self.assertAllTextsPresent(in: memory, texts: texts)
                try await Self.assertNoDuplicateFrameIDs(in: memory, query: "n-minus-cycle")
                try await memory.close()
            }
        }
    }

    @Test
    func reopeningLegacy256MiBStoreDoesNotRewriteLayout() async throws {
        try await TempFiles.withTempFile { url in
            do {
                let wax = try await Wax.create(at: url, walSize: Self.legacy256MiB)
                _ = try await wax.put(
                    Data("legacy-256mib-seed".utf8),
                    options: FrameMetaSubset(searchText: "legacy-256mib-seed")
                )
                try await wax.commit()
                try await wax.close()
            }

            let before = try StoreFileSize.measure(url)
            #expect(before.logical > 200 * 1024 * 1024)
            #expect(try await Self.headerWalSize(at: url) == Self.legacy256MiB)

            let memory = try await Memory(
                at: url,
                config: .init(enableVectorSearch: false, walSizeBytes: Memory.Config.defaultWalSizeBytes)
            )
            let stats = await memory.stats()
            #expect(stats.frameCount >= 1)
            try await memory.save("legacy-reopen-new-frame")
            try await memory.flush()
            let found = try await memory.search("legacy-reopen-new-frame", options: .init(mode: .textOnly))
            #expect(!found.items.isEmpty)
            try await memory.close()

            let after = try StoreFileSize.measure(url)
            #expect(try await Self.headerWalSize(at: url) == Self.legacy256MiB)
            #expect(after.logical > 200 * 1024 * 1024)
            #expect(after.logical >= before.logical)
        }
    }

    private static func headerWalSize(at url: URL) async throws -> UInt64 {
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        let orchestrator = try await MemoryOrchestrator(at: url, config: config)
        let walSize = (await orchestrator.runtimeStats()).wal.walSize
        try await orchestrator.close()
        return walSize
    }

    private static func assertAcknowledgedTextsSurviveReopen(at url: URL, texts: [String]) async throws {
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        let reopened = try await MemoryOrchestrator(at: url, config: config)
        for text in texts {
            let prefix = String(text.prefix(24))
            let ctx = try await reopened.recall(query: prefix)
            #expect(
                ctx.items.contains { $0.text.contains(prefix) },
                "missing acknowledged text prefix \(prefix)"
            )
        }
        let ids = ctxFrameIDs(try await reopened.recall(query: "proactive-commit"))
        #expect(Set(ids).count == ids.count)
        try await reopened.close()

        let memory = try await Memory(at: url, config: .init(enableVectorSearch: false))
        try await assertNoDuplicateFrameIDs(in: memory, query: "proactive-commit")
        try await memory.close()
    }

    private static func assertAllTextsPresent(in memory: Memory, texts: [String]) async throws {
        for text in texts {
            let results = try await memory.search(text, options: .init(topK: 10, mode: .textOnly))
            #expect(
                results.items.contains { $0.text.contains(text) },
                "missing \(text) after reopen"
            )
        }
    }

    private static func assertNoDuplicateFrameIDs(in memory: Memory, query: String) async throws {
        let results = try await memory.search(query, options: .init(topK: 200, mode: .textOnly))
        let ids = results.items.map(\.frameId)
        #expect(Set(ids).count == ids.count)
    }

    private static func ctxFrameIDs(_ context: RAGContext) -> [UInt64] {
        context.items.map(\.frameId)
    }
}

private enum StoreFileSize {
    static func measure(_ url: URL) throws -> (logical: UInt64, allocated: UInt64, statAllocated: UInt64) {
        let values = try url.resourceValues(
            forKeys: [.fileSizeKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey]
        )
        let logical = UInt64(max(0, values.fileSize ?? 0))
        let allocatedValue = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0
        let allocated = UInt64(max(0, allocatedValue))
        return (logical: logical, allocated: allocated, statAllocated: statAllocatedBytes(url))
    }

    static func statAllocatedBytes(_ url: URL) -> UInt64 {
        #if canImport(Darwin)
        var st = stat()
        let ok = url.path.withCString { path in
            stat(path, &st) == 0
        }
        guard ok else { return 0 }
        return UInt64(st.st_blocks) * 512
        #else
        return 0
        #endif
    }
}
