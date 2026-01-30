import Foundation
import Testing
@testable import Wax
@testable import WaxTextSearch

private func ftsDeserializeBenchEnabled() -> Bool {
    ProcessInfo.processInfo.environment["WAX_BENCHMARK_FTS_DESERIALIZE"] == "1"
}

private func walBenchEnabled() -> Bool {
    ProcessInfo.processInfo.environment["WAX_BENCHMARK_WAL"] == "1"
}

@discardableResult
private func timedMean(
    label: String,
    iterations: Int,
    _ block: @escaping @Sendable () async throws -> Void
) async throws -> Double {
    let clock = ContinuousClock()
    var samples: [Double] = []
    samples.reserveCapacity(iterations)
    for _ in 0..<iterations {
        let start = clock.now
        try await block()
        let duration = clock.now - start
        let seconds = Double(duration.components.seconds) +
            Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
        samples.append(seconds)
    }
    let mean = samples.reduce(0, +) / Double(max(1, samples.count))
    print("🧪 \(label): mean \(String(format: "%.5f", mean)) s")
    return mean
}

@Test func ftsDeserializeBenchmark() async throws {
    guard ftsDeserializeBenchEnabled() else { return }

    let scale = BenchmarkScale.standard
    let docCount = scale.documentCount
    let factory = BenchmarkTextFactory(sentencesPerDocument: scale.sentencesPerDocument)

    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()

        for index in 0..<docCount {
            let content = factory.makeDocument(index: index)
            let data = Data(content.utf8)
            let frameId = try await wax.put(data, options: FrameMetaSubset(searchText: content))
            try await text.index(frameId: frameId, text: content)
        }

        try await text.stageForCommit()
        try await wax.commit()
        try await wax.close()

        let reopened = try await Wax.open(at: url)
        guard let bytes = try await reopened.readCommittedLexIndexBytes() else {
            #expect(Bool(false))
            return
        }
        guard let region = try await reopened.readCommittedLexIndexMapped() else {
            #expect(Bool(false))
            return
        }

        let iterations = max(3, scale.iterations)
        _ = try await timedMean(label: "fts_deserialize_copy", iterations: iterations) {
            _ = try FTS5SearchEngine.deserialize(from: bytes)
        }
        _ = try await timedMean(label: "fts_deserialize_mmap", iterations: iterations) {
            _ = try FTS5SearchEngine.deserializeReadOnly(from: region)
        }
        try await reopened.close()
    }
}

@Test func walCommitBenchmark() async throws {
    guard walBenchEnabled() else { return }

    let scale = BenchmarkScale.standard
    let docCount = scale.documentCount
    let iterations = max(3, scale.iterations)
    let factory = BenchmarkTextFactory(sentencesPerDocument: scale.sentencesPerDocument)
    let clock = ContinuousClock()

    var putSamples: [Double] = []
    var commitSamples: [Double] = []
    putSamples.reserveCapacity(iterations)
    commitSamples.reserveCapacity(iterations)

    for _ in 0..<iterations {
        try await TempFiles.withTempFile { url in
            let wax = try await Wax.create(at: url)

            let putStart = clock.now
            for index in 0..<docCount {
                let content = factory.makeDocument(index: index)
                let data = Data(content.utf8)
                _ = try await wax.put(data, options: FrameMetaSubset(searchText: content))
            }
            let putDuration = clock.now - putStart
            let putSeconds = Double(putDuration.components.seconds) +
                Double(putDuration.components.attoseconds) / 1_000_000_000_000_000_000
            putSamples.append(putSeconds)

            let commitStart = clock.now
            try await wax.commit()
            let commitDuration = clock.now - commitStart
            let commitSeconds = Double(commitDuration.components.seconds) +
                Double(commitDuration.components.attoseconds) / 1_000_000_000_000_000_000
            commitSamples.append(commitSeconds)

            try await wax.close()
        }
    }

    let putMean = putSamples.reduce(0, +) / Double(max(1, putSamples.count))
    let commitMean = commitSamples.reduce(0, +) / Double(max(1, commitSamples.count))
    print("🧪 wal_put_\(docCount): mean \(String(format: "%.4f", putMean)) s")
    print("🧪 wal_commit_\(docCount): mean \(String(format: "%.4f", commitMean)) s")
}
