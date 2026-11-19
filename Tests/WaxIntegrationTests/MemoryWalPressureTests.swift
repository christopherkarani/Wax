import Foundation
import Testing
import Wax
import WaxCore
import WaxTestSupport

/// `Memory` stages its own vector index and commits before the WAL fills, so an app never has
/// to call `flush()` to keep saving. A 64 KiB WAL fills after a few hundred embedded saves.
private enum WalPressure {
    static let walSize: UInt64 = 64 * 1024
    static let dimensions = 16

    static func config() -> Memory.Config {
        Memory.Config(embedding: .custom(SeededHashEmbedder(dimensions: dimensions)))
    }

    static func passage(_ index: Int) -> String {
        "WAL pressure passage \(index) about topic \(index % 7) and detail \(index * 31 % 101)."
    }

    /// Long enough to be cut into many chunks whose search text alone overflows the WAL.
    static func longDocument() -> String {
        (0..<8_000).map { "word\($0 % 997)x\($0)" }.joined(separator: " ")
    }

    static func createSmallWalStore(at url: URL) async throws {
        let wax = try await Wax.create(at: url, walSize: walSize)
        try await wax.close()
    }
}

@Test func memorySavesPastWalCapacityWithoutFlush() async throws {
    try await TempFiles.withTempFile { url in
        try await WalPressure.createSmallWalStore(at: url)
        let count = 600

        let memory = try await Memory(at: url, config: WalPressure.config())
        var ids: [UInt64] = []
        for index in 0..<count {
            ids.append(try await memory.save(WalPressure.passage(index), metadata: ["row": String(index)]))
        }
        #expect(Set(ids).count == count)
        try await memory.close()

        let reopened = try await Memory(at: url, config: WalPressure.config())
        let stats = await reopened.stats()
        #expect(stats.frameCount == UInt64(count))
        #expect(stats.pendingFrames == 0)
        #expect(stats.framesWithoutVectors == 0)
        for index in [0, 1, count / 2, count - 1] {
            let results = try await reopened.search(
                WalPressure.passage(index),
                options: .init(topK: 1, mode: .vectorOnly)
            )
            #expect(results.items.first?.metadata["row"] == String(index))
        }
        try await reopened.close()
    }
}

@Test func memorySavesMultiChunkDocumentLargerThanWalWithoutFlush() async throws {
    try await TempFiles.withTempFile { url in
        try await WalPressure.createSmallWalStore(at: url)
        let document = WalPressure.longDocument()
        #expect(document.utf8.count > Int(WalPressure.walSize))

        let memory = try await Memory(at: url, config: WalPressure.config())
        let documentId = try await memory.save(document, metadata: ["kind": "long"])
        try await memory.save(WalPressure.passage(0), metadata: ["row": "0"])
        try await memory.flush()
        let stats = await memory.stats()
        #expect(stats.frameCount > 2)
        #expect(stats.pendingFrames == 0)
        #expect(stats.framesWithoutVectors == 0)

        // A second save of the same document is still a duplicate across the auto-commits.
        #expect(try await memory.save(document, metadata: ["kind": "long"]) == documentId)
        try await memory.close()
    }
}

@Test func memoryConcurrentSavesPastWalCapacityWithoutFlush() async throws {
    try await TempFiles.withTempFile { url in
        try await WalPressure.createSmallWalStore(at: url)
        let writers = 8
        let perWriter = 75

        let memory = try await Memory(at: url, config: WalPressure.config())
        try await withThrowingTaskGroup(of: Void.self) { group in
            for writer in 0..<writers {
                group.addTask {
                    for offset in 0..<perWriter {
                        let index = writer * perWriter + offset
                        try await memory.save(WalPressure.passage(index), metadata: ["row": String(index)])
                    }
                }
            }
            try await group.waitForAll()
        }
        try await memory.flush()
        let stats = await memory.stats()
        #expect(stats.frameCount == UInt64(writers * perWriter))
        #expect(stats.framesWithoutVectors == 0)
        try await memory.close()
    }
}

@Test func memoryBackfillPastWalCapacityWithoutFlush() async throws {
    try await TempFiles.withTempFile { url in
        try await WalPressure.createSmallWalStore(at: url)
        let count = 600
        do {
            let textOnly = try await Memory(
                at: url,
                config: Memory.Config(enableVectorSearch: false, requireOnDeviceProviders: false)
            )
            for index in 0..<count {
                try await textOnly.save(WalPressure.passage(index), metadata: ["row": String(index)])
            }
            try await textOnly.close()
        }

        let memory = try await Memory(at: url, config: WalPressure.config())
        #expect(try await memory.backfillUnembedded() == UInt64(count))
        try await memory.close()

        let reopened = try await Memory(at: url, config: WalPressure.config())
        let stats = await reopened.stats()
        #expect(stats.frameCount == UInt64(count))
        #expect(stats.framesWithoutVectors == 0)
        for index in [0, 1, count / 2, count - 1] {
            let results = try await reopened.search(
                WalPressure.passage(index),
                options: .init(topK: 1, mode: .vectorOnly)
            )
            #expect(results.items.first?.metadata["row"] == String(index))
        }
        try await reopened.close()
    }
}
