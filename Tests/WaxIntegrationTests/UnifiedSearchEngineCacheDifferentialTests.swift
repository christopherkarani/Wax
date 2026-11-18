import Foundation
import Testing
@testable import Wax
import WaxCore
import WaxVectorSearch

/// The raw-search vector cache applies pending writes incrementally. These cases
/// pin that the cached engine always scores like a fresh `LoadedVectorSearchEngine.load`.
@Suite(.serialized)
struct UnifiedSearchEngineCacheDifferentialTests {
    private static let dims = 4

    private struct LCG {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state >> 33
        }
        mutating func float() -> Float { Float(next() % 10_000) / 10_000 - 0.5 }
        mutating func int(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
        mutating func vector() -> [Float] { VectorMath.normalizeL2((0..<dims).map { _ in float() }) }
    }

    /// Scores of every frame from the cached engine and from a fresh load, or nil
    /// when the store has nothing to search.
    private static func cachedAndFreshScores(
        _ wax: Wax,
        query: [Float],
        cache: UnifiedSearchEngineCache = .shared
    ) async throws -> (cached: [UInt64: Float], fresh: [UInt64: Float])? {
        guard let cached = try await cache.vectorEngine(
            for: wax, queryEmbeddingDimensions: dims, preference: .cpuOnly
        ) else { return nil }
        let fresh = try await LoadedVectorSearchEngine.load(
            from: wax, metric: .cosine, dimensions: dims, preference: .cpuOnly
        )
        let cachedHits = try await cached.search(vector: query, topK: 10_000)
        let freshHits = try await fresh.search(vector: query, topK: 10_000)
        return (
            Dictionary(cachedHits.map { ($0.frameId, $0.score) }, uniquingKeysWith: { first, _ in first }),
            Dictionary(freshHits.map { ($0.frameId, $0.score) }, uniquingKeysWith: { first, _ in first })
        )
    }

    private static func sameScores(_ lhs: [UInt64: Float], _ rhs: [UInt64: Float]) -> Bool {
        guard Set(lhs.keys) == Set(rhs.keys) else { return false }
        return lhs.allSatisfy { abs($0.value - (rhs[$0.key] ?? .nan)) < 1e-5 }
    }

    /// A store freed and replaced at the same address must not inherit the old
    /// store's cached engine: frame ids overlap, so B would be scored with A's vectors.
    @Test func reusedStoreAddressDoesNotInheritCachedEngine() async throws {
        var reusedAddresses = 0
        for attempt in 0..<200 where reusedAddresses < 5 {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("wax-cache-reuse-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            var storeAID: ObjectIdentifier?
            do {
                let storeA = try await Wax.create(at: dir.appendingPathComponent("a.wax"))
                for index in 0..<3 {
                    let id = try await storeA.put(Data("a\(index)".utf8))
                    try await storeA.putEmbedding(frameId: id, vector: VectorMath.normalizeL2([1, Float(index), 0, 0]))
                }
                _ = try await UnifiedSearchEngineCache.shared.vectorEngine(
                    for: storeA, queryEmbeddingDimensions: Self.dims, preference: .cpuOnly
                )
                storeAID = ObjectIdentifier(storeA)
                // Pending embeddings without a staged vector index make close throw
                // `.vectorIndexNotStaged`; the store is still released, which is all this needs.
                try? await storeA.close()
            }

            let storeB = try await Wax.create(at: dir.appendingPathComponent("b.wax"))
            guard ObjectIdentifier(storeB) == storeAID else {
                try? await storeB.close()
                continue
            }
            reusedAddresses += 1
            for index in 0..<5 {
                let id = try await storeB.put(Data("b\(index)".utf8))
                try await storeB.putEmbedding(frameId: id, vector: VectorMath.normalizeL2([0, 0, 1, Float(index)]))
            }
            let scores = try #require(try await Self.cachedAndFreshScores(storeB, query: VectorMath.normalizeL2([1, 0, 0, 0])))
            #expect(
                Self.sameScores(scores.cached, scores.fresh),
                "attempt \(attempt): store B was scored with store A's vectors: cached \(scores.cached) fresh \(scores.fresh)"
            )
            try? await storeB.close()
        }
        // Without a reuse the case above never ran. Heavily parallel runs may never
        // reuse an address, so record that as a known issue instead of failing;
        // a stale engine served during a reuse above is still a hard failure.
        let exercised = reusedAddresses > 0
        withKnownIssue("address reuse did not occur in this run", isIntermittent: true) {
            #expect(exercised, "no store address was reused; the regression was not exercised")
        }
    }

    /// Random puts, re-embeds, deletes, commits and searches (fixed seeds): every
    /// search's cached engine must score like a fresh rebuild.
    @Test(arguments: [UInt64(1), 2, 3, 4, 5, 6])
    func cachedEngineMatchesFreshLoadUnderRandomOperations(seed: UInt64) async throws {
        try await TempFiles.withTempFile { url in
            var rng = LCG(state: seed &* 7919)
            let wax = try await Wax.create(at: url)
            let session = try await wax.enableVectorSearch(dimensions: Self.dims, preference: .cpuOnly)
            var frames: [UInt64] = []
            var searches = 0
            var commits = 0
            var commitFailures = 0
            for step in 0..<100 {
                switch rng.int(10) {
                case 0...3:
                    frames.append(try await session.putWithEmbedding(Data("f\(step)".utf8), embedding: rng.vector()))
                case 4, 5:
                    // Re-embed an existing frame with a new vector of the same dimension.
                    guard !frames.isEmpty else { continue }
                    try await wax.putEmbedding(frameId: frames[rng.int(frames.count)], vector: rng.vector())
                case 6:
                    guard !frames.isEmpty else { continue }
                    try await wax.delete(frameId: frames.remove(at: rng.int(frames.count)))
                case 7:
                    // A commit can be refused (e.g. a pending re-embed of a deleted
                    // frame); the cache must stay correct either way.
                    do {
                        try await session.stageForCommit()
                        try await wax.commit()
                        commits += 1
                    } catch {
                        commitFailures += 1
                    }
                default:
                    guard let scores = try await Self.cachedAndFreshScores(wax, query: rng.vector()) else { continue }
                    searches += 1
                    #expect(
                        Self.sameScores(scores.cached, scores.fresh),
                        "seed \(seed) step \(step): cached \(scores.cached.count) frames vs fresh \(scores.fresh.count)"
                    )
                }
            }
            #expect(searches > 0)
            #expect(commits + commitFailures > 0)
            try? await wax.close()
        }
    }

    /// Searches racing a writer must leave the cache equal to a fresh rebuild.
    @Test func concurrentSearchesRacingWritesConverge() async throws {
        try await TempFiles.withTempFile { url in
            let wax = try await Wax.create(at: url)
            let session = try await wax.enableVectorSearch(dimensions: Self.dims, preference: .cpuOnly)
            _ = try await session.putWithEmbedding(Data("seed".utf8), embedding: VectorMath.normalizeL2([1, 0, 0, 0]))
            try await session.stageForCommit()
            try await wax.commit()

            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    var rng = LCG(state: 42)
                    for index in 0..<200 {
                        _ = try await session.putWithEmbedding(Data("w\(index)".utf8), embedding: rng.vector())
                    }
                }
                for searcher in 0..<4 {
                    group.addTask {
                        var rng = LCG(state: UInt64(100 + searcher))
                        for _ in 0..<150 {
                            _ = try await UnifiedSearchEngineCache.shared
                                .vectorEngine(for: wax, queryEmbeddingDimensions: Self.dims, preference: .cpuOnly)?
                                .search(vector: rng.vector(), topK: 5)
                        }
                    }
                }
                try await group.waitForAll()
            }

            let scores = try #require(
                try await Self.cachedAndFreshScores(wax, query: VectorMath.normalizeL2([0.3, 0.2, -0.1, 0.5]))
            )
            #expect(Self.sameScores(scores.cached, scores.fresh))
            #expect(scores.cached.count == 201)
            try await session.stageForCommit()
            try await wax.commit()
            try await wax.close()
        }
    }

    @TaskLocal private static var refreshLabel = ""

    /// Records which labelled task reached which refresh event, and parks chosen
    /// tasks at an event until the test releases them.
    private actor RefreshScript {
        enum Mark: Hashable, Sendable {
            case event(UnifiedSearchEngineCache.VectorRefreshEvent)
            case returned
        }

        private var parkRules: [String: UnifiedSearchEngineCache.VectorRefreshEvent]
        private var reached: [String: [Mark]] = [:]
        private var parked: [String: CheckedContinuation<Void, Never>] = [:]
        private var released: Set<String> = []
        private var observers: [(label: String, marks: Set<Mark>, continuation: CheckedContinuation<Void, Never>)] = []

        init(parkRules: [String: UnifiedSearchEngineCache.VectorRefreshEvent]) {
            self.parkRules = parkRules
        }

        func reach(_ mark: Mark, label: String) async {
            reached[label, default: []].append(mark)
            let satisfied = observers.filter { $0.label == label && $0.marks.contains(mark) }
            observers.removeAll { $0.label == label && $0.marks.contains(mark) }
            for observer in satisfied { observer.continuation.resume() }
            guard case .event(let event) = mark, parkRules[label] == event else { return }
            parkRules[label] = nil
            if released.contains(label) { return }
            await withCheckedContinuation { parked[label] = $0 }
        }

        /// Returns once `label` has reached any of `marks`.
        func waitFor(_ label: String, anyOf marks: Set<Mark>) async {
            if reached[label, default: []].contains(where: marks.contains) { return }
            await withCheckedContinuation { observers.append((label, marks, $0)) }
        }

        /// Resumes `label` if it is parked, or lets it pass its park point later.
        func release(_ label: String) {
            released.insert(label)
            parked.removeValue(forKey: label)?.resume()
        }
    }

    /// A reload that finishes after another search already advanced the cache must
    /// not inherit that search's watermark: the reloaded engine never saw those writes.
    /// A reloads and pauses before caching; B caches a newer engine; C applies a
    /// newer write to B's engine and pauses before recording it; then A, then C finish.
    @Test func overlappingRefreshesDoNotMarkUnappliedWritesAsSynced() async throws {
        try await TempFiles.withTempFile { url in
            let wax = try await Wax.create(at: url)
            let session = try await wax.enableVectorSearch(dimensions: Self.dims, preference: .cpuOnly)
            _ = try await session.putWithEmbedding(Data("seed".utf8), embedding: VectorMath.normalizeL2([1, 0, 0, 0]))
            try await session.stageForCommit()
            try await wax.commit()
            _ = try await session.putWithEmbedding(Data("p1".utf8), embedding: VectorMath.normalizeL2([0, 1, 0, 0]))

            let script = RefreshScript(parkRules: ["A": .loaded, "C": .synced])
            let cache = UnifiedSearchEngineCache { event in
                await script.reach(.event(event), label: Self.refreshLabel)
            }
            @Sendable func refresh(_ label: String) async throws {
                try await Self.$refreshLabel.withValue(label) {
                    _ = try await cache.vectorEngine(for: wax, queryEmbeddingDimensions: Self.dims, preference: .cpuOnly)
                    await script.reach(.returned, label: label)
                }
            }

            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await refresh("A") }
                await script.waitFor("A", anyOf: [.event(.loaded)])
                _ = try await session.putWithEmbedding(Data("p2".utf8), embedding: VectorMath.normalizeL2([0, 0, 1, 0]))
                group.addTask { try await refresh("B") }
                await script.waitFor("B", anyOf: [.returned, .event(.waitingForRefresh)])
                _ = try await session.putWithEmbedding(Data("p3".utf8), embedding: VectorMath.normalizeL2([0, 0, 0, 1]))
                group.addTask { try await refresh("C") }
                await script.waitFor("C", anyOf: [.event(.synced), .event(.waitingForRefresh)])
                await script.release("A")
                await script.waitFor("A", anyOf: [.returned])
                await script.release("C")
                try await group.waitForAll()
            }

            let scores = try #require(
                try await Self.cachedAndFreshScores(wax, query: VectorMath.normalizeL2([0.3, 0.2, -0.1, 0.5]), cache: cache)
            )
            #expect(Self.sameScores(scores.cached, scores.fresh), "cached \(scores.cached.keys.sorted()) fresh \(scores.fresh.keys.sorted())")
            #expect(scores.cached.count == 4)
            try await session.stageForCommit()
            try await wax.commit()
            try await wax.close()
        }
    }
}
