import Foundation
import Testing
import Wax
import WaxTestSupport

// Every flush commits a full text index and vector index. The store must reuse the space the
// superseded ones held, so its size follows the saved data and not the number of flushes.

private func storeBytes(saving count: Int, flushEvery: Int) async throws -> UInt64 {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-flush-size-" + UUID().uuidString)
        .appendingPathExtension("wax")
    defer { try? FileManager.default.removeItem(at: url) }
    var config = Memory.Config.default
    config.enableStructuredMemory = false
    config.embedding = .custom(SeededHashEmbedder(dimensions: 384))
    let memory = try await Memory(at: url, config: config)
    for index in 0..<count {
        let text = "passage \(index) about topic \(index % 17) with words alpha\(index) beta\(index % 29) "
            + String(repeating: "filler text for the index ", count: 8)
        try await memory.save(text, metadata: ["doc_id": String(index)])
        if (index + 1) % flushEvery == 0 {
            try await memory.flush()
        }
    }
    try await memory.flush()
    try await memory.close()
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
}

@Test func storeSizeDoesNotGrowWithFlushCount() async throws {
    let count = 600
    // One saved document gives the fixed part of the file: header pages and the WAL ring.
    let fixed = try await storeBytes(saving: 1, flushEvery: 1)
    let flushedOnce = try await storeBytes(saving: count, flushEvery: count)
    let flushedOften = try await storeBytes(saving: count, flushEvery: 20)

    let live = flushedOnce - fixed
    let often = flushedOften - fixed
    // 30 flushes without reuse keep about 15 index snapshots; with reuse the holes stay
    // within about one extra copy of the live data.
    #expect(often <= live * 5 / 2, "data after 30 flushes \(often) B vs one flush \(live) B")
}
