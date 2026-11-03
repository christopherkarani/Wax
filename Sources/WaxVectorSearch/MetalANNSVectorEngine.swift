#if canImport(Metal) && canImport(MetalANNS)
import Accelerate
import Foundation
import Metal
import MetalANNS
import os
import WaxCore

package actor MetalANNSVectorEngine: VectorSearchEngine {
    package static let autoThreshold = 10_000

    /// Runs at the start of every graph build. Test seam for holding or failing a build.
    package typealias GraphBuildHook = @Sendable () async throws -> Void

    private typealias ReadyIndex = VectorIndex<UInt64, VectorIndexState.Ready>

    private static let logger = Logger(subsystem: "com.wax.vectorsearch", category: "MetalANNSVectorEngine")

    private let metric: VectorMetric
    package let dimensions: Int
    private let configuration: IndexConfiguration
    private let graphBuildHook: GraphBuildHook?

    /// Graph over `vectors`/`frameIds`, which are the source of truth. While it is `nil`,
    /// searches scan `vectors` exactly and a background build is scheduled.
    private var index: ReadyIndex?
    /// Bumped on every change to `vectors`/`frameIds`. A graph built from a snapshot is
    /// installed only if the generation is unchanged when the build finishes.
    private var mutationGeneration: UInt64 = 0
    /// Generation of the last mutation that was not a pure append (remove, overwrite,
    /// deserialize). A build whose snapshot is newer than this saw only appends since, so
    /// it can be installed and caught up instead of discarded.
    private var lastNonAppendGeneration: UInt64 = 0
    /// `lastNonAppendGeneration` when a stale build was discarded. Until a search sees no
    /// non-append mutation since the previous check, no new build starts, so removes or
    /// overwrites faster than a build don't keep restarting it. Appends don't delay a
    /// build: a build that saw only appends is caught up instead of discarded.
    private var rebuildDebounceGeneration: UInt64?
    /// The single in-flight background graph build, if any.
    private var graphBuildTask: Task<Void, Never>?
    /// Generation whose graph build failed; no retry until the next mutation.
    private var failedGraphBuildGeneration: UInt64?
    /// Graph builds that threw. Searches keep using the exact scan when this happens.
    package private(set) var graphBuildFailureCount = 0
    /// Ids soft-deleted from `index`; MetalANNS keeps them reserved until the graph is rebuilt.
    private var softDeletedFrameIds: Set<UInt64> = []
    private var frameIds: [UInt64] = []
    private var positions: [UInt64: Int] = [:]
    private var vectors: [Float] = []
    private var dirty = false
    /// Rows dropped from the last loaded segment because they held non-finite values.
    package private(set) var droppedNonFiniteRowCount = 0

    package static var isAvailable: Bool {
        MTLCreateSystemDefaultDevice() != nil
    }

    package init(metric: VectorMetric, dimensions: Int) throws {
        try self.init(metric: metric, dimensions: dimensions, searchMode: .exact)
    }

    package init(
        metric: VectorMetric,
        dimensions: Int,
        searchMode: MetalANNS.SearchMode,
        degree: Int? = nil,
        graphBuildHook: GraphBuildHook? = nil
    ) throws {
        guard dimensions > 0 else {
            throw WaxError.invalidToc(reason: "dimensions must be > 0")
        }
        guard dimensions <= Constants.maxEmbeddingDimensions else {
            throw WaxError.capacityExceeded(
                limit: UInt64(Constants.maxEmbeddingDimensions),
                requested: UInt64(dimensions)
            )
        }
        self.metric = metric
        self.dimensions = dimensions
        var configuration = IndexConfiguration.default
        configuration.metric = metric.toMetalANNSMetric()
        configuration.searchMode = searchMode
        if let degree {
            configuration.degree = degree
        }
        self.configuration = configuration
        self.graphBuildHook = graphBuildHook
    }

    /// Cancellation is advisory: a pending build stops before the MetalANNS build call, but
    /// a GPU build already in progress runs to completion and its result is dropped.
    deinit {
        graphBuildTask?.cancel()
    }

    /// Whether searches currently go through the MetalANNS graph.
    package var isGraphReady: Bool {
        index != nil
    }

    /// Waits for the in-flight background graph build, if any, to finish.
    package func waitForPendingGraphBuild() async {
        await graphBuildTask?.value
    }

    package static func load(from wax: Wax, metric: VectorMetric, dimensions: Int) async throws -> MetalANNSVectorEngine {
        let engine = try MetalANNSVectorEngine(metric: metric, dimensions: dimensions)
        if let staged = await wax.readStagedVecIndexBytes() {
            try await engine.deserialize(staged.bytes)
        } else if let bytes = try await wax.readCommittedVecIndexBytes() {
            try await engine.deserialize(bytes)
        }
        let pending = await wax.pendingEmbeddingMutations(since: nil)
        if !pending.embeddings.isEmpty {
            try await engine.addBatch(
                frameIds: pending.embeddings.map(\.frameId),
                vectors: pending.embeddings.map(\.vector)
            )
        }
        return engine
    }

    package func add(frameId: UInt64, vector: [Float]) async throws {
        try validate(vector)
        let stored = preparedVector(vector)
        mutationGeneration &+= 1

        if let existingIndex = positions[frameId] {
            overwriteVector(at: existingIndex, with: stored)
            lastNonAppendGeneration = mutationGeneration
            // MetalANNS has no in-place update; rebuild lazily from the stored vectors.
            invalidateIndex()
        } else {
            positions[frameId] = frameIds.count
            frameIds.append(frameId)
            vectors.append(contentsOf: stored)
            await insertIntoIndex([VectorRecord(id: frameId, vector: stored)])
        }
        dirty = true
    }

    package func addBatch(frameIds: [UInt64], vectors newVectors: [[Float]]) async throws {
        guard !frameIds.isEmpty else { return }
        guard frameIds.count == newVectors.count else {
            throw WaxError.encodingError(reason: "addBatch: frameIds.count != vectors.count")
        }
        for vector in newVectors {
            try validate(vector)
        }
        mutationGeneration &+= 1

        var newRecords: [VectorRecord<UInt64>] = []
        newRecords.reserveCapacity(frameIds.count)
        var overwroteExisting = false

        for (frameId, vector) in zip(frameIds, newVectors) {
            let stored = preparedVector(vector)
            if let existingIndex = positions[frameId] {
                overwriteVector(at: existingIndex, with: stored)
                overwroteExisting = true
            } else {
                positions[frameId] = self.frameIds.count
                self.frameIds.append(frameId)
                self.vectors.append(contentsOf: stored)
                newRecords.append(VectorRecord(id: frameId, vector: stored))
            }
        }

        if overwroteExisting {
            lastNonAppendGeneration = mutationGeneration
            // MetalANNS has no in-place update; rebuild lazily from the stored vectors.
            invalidateIndex()
        } else {
            await insertIntoIndex(newRecords)
        }
        dirty = true
    }

    package func remove(frameId: UInt64) async throws {
        guard let indexToRemove = positions.removeValue(forKey: frameId) else { return }
        mutationGeneration &+= 1
        lastNonAppendGeneration = mutationGeneration
        let lastIndex = frameIds.count - 1
        if indexToRemove != lastIndex {
            let movedFrameId = frameIds[lastIndex]
            overwriteVector(at: indexToRemove, withSliceFrom: lastIndex)
            frameIds[indexToRemove] = movedFrameId
            positions[movedFrameId] = indexToRemove
        }
        frameIds.removeLast()
        vectors.removeLast(dimensions)
        if !canBuildIndex {
            invalidateIndex()
        } else if let index {
            do {
                try await index.delete(id: frameId)
                softDeletedFrameIds.insert(frameId)
            } catch {
                invalidateIndex()
            }
        }
        dirty = true
    }

    package func search(vector query: [Float], topK: Int) async throws -> [(frameId: UInt64, score: Float)] {
        try validate(query)
        guard !frameIds.isEmpty else { return [] }
        let prepared = preparedVector(query)
        guard let index else {
            scheduleGraphBuildIfNeeded()
            return exactHits(for: prepared, topK: topK)
        }
        let results = try await index.search(query: prepared, topK: topK)
        return hits(from: results)
    }

    package struct SearchTiming: Sendable {
        package var prepareMs: Double
        package var indexMs: Double
        package var mapMs: Double
        package var totalMs: Double
    }

    package func searchTimed(
        vector query: [Float],
        topK: Int
    ) async throws -> (hits: [(frameId: UInt64, score: Float)], timing: SearchTiming) {
        let totalStart = CFAbsoluteTimeGetCurrent()
        try validate(query)
        guard !frameIds.isEmpty else {
            return ([], SearchTiming(prepareMs: 0, indexMs: 0, mapMs: 0, totalMs: 0))
        }
        let prepareStart = CFAbsoluteTimeGetCurrent()
        let prepared = preparedVector(query)
        let prepareMs = (CFAbsoluteTimeGetCurrent() - prepareStart) * 1_000
        let indexStart = CFAbsoluteTimeGetCurrent()
        guard let index else {
            scheduleGraphBuildIfNeeded()
            let mapped = exactHits(for: prepared, topK: topK)
            let indexMs = (CFAbsoluteTimeGetCurrent() - indexStart) * 1_000
            let totalMs = (CFAbsoluteTimeGetCurrent() - totalStart) * 1_000
            return (mapped, SearchTiming(prepareMs: prepareMs, indexMs: indexMs, mapMs: 0, totalMs: totalMs))
        }
        let results = try await index.search(query: prepared, topK: topK)
        let indexMs = (CFAbsoluteTimeGetCurrent() - indexStart) * 1_000
        let mapStart = CFAbsoluteTimeGetCurrent()
        let mapped = hits(from: results)
        let mapMs = (CFAbsoluteTimeGetCurrent() - mapStart) * 1_000
        let totalMs = (CFAbsoluteTimeGetCurrent() - totalStart) * 1_000
        return (mapped, SearchTiming(prepareMs: prepareMs, indexMs: indexMs, mapMs: mapMs, totalMs: totalMs))
    }

    package func stageForCommit(into wax: Wax) async throws {
        try await stageForCommit(into: wax, coverage: .latestPending)
    }

    package func stageForCommit(into wax: Wax, coverage: StagedVecIndexCoverage) async throws {
        guard dirty else { return }
        let blob = try VectorSerializer.serializeFlatVectors(
            vectors,
            frameIds: frameIds,
            metric: metric,
            dimensions: dimensions
        )
        try await wax.stageVecIndexForNextCommit(
            bytes: blob,
            vectorCount: UInt64(frameIds.count),
            dimension: UInt32(dimensions),
            similarity: metric.toVecSimilarity(),
            coverage: coverage
        )
        dirty = false
    }

    private func deserialize(_ data: Data) async throws {
        let decoded = try VectorSerializer.decodeVecSegment(from: data)
        switch decoded {
        case .metal(let info, let decodedVectors, let decodedFrameIds):
            guard info.dimension == UInt32(dimensions) else {
                throw WaxError.invalidToc(reason: "vec dimension mismatch: expected \(dimensions), got \(info.dimension)")
            }
            guard info.similarity == metric.toVecSimilarity() else {
                throw WaxError.invalidToc(
                    reason: "vec similarity mismatch: expected \(metric.toVecSimilarity()), got \(info.similarity)"
                )
            }
            guard decodedVectors.count == Int(info.vectorCount) * dimensions else {
                throw WaxError.invalidToc(reason: "vec vector count mismatch")
            }
            guard decodedFrameIds.count == Int(info.vectorCount) else {
                throw WaxError.invalidToc(reason: "vec frameId count mismatch")
            }
            frameIds = decodedFrameIds
            vectors = decodedVectors
            positions.removeAll(keepingCapacity: true)
            positions.reserveCapacity(decodedFrameIds.count)
            for (index, frameId) in decodedFrameIds.enumerated() {
                positions[frameId] = index
            }
            mutationGeneration &+= 1
            lastNonAppendGeneration = mutationGeneration
            await buildGraphNow()
            droppedNonFiniteRowCount = info.droppedNonFiniteRowCount
            // Rewrite a clean segment on the next commit when rows were dropped.
            dirty = info.droppedNonFiniteRowCount > 0
        }
    }

    /// MetalANNS reports distances (lower is better): cosine `1 - cos`, inner product `-dot`,
    /// L2 squared distance. Convert to the similarity scale AccelerateVectorEngine returns
    /// (higher is better) and order best-first with a frameId tie-break. This only orders
    /// the set MetalANNS returned; which of several items tied at the k-th place make it
    /// into that set is decided by MetalANNS. Non-finite scores are dropped, as are ids no
    /// longer stored (removed while the graph search was suspended).
    private func hits(from neighbors: [VectorNeighbor<UInt64>]) -> [(frameId: UInt64, score: Float)] {
        neighbors
            .filter { positions[$0.id] != nil }
            .map { (frameId: $0.id, score: metric.score(fromDistance: $0.score)) }
            .filter { $0.score.isFinite }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score { return lhs.frameId < rhs.frameId }
                return lhs.score > rhs.score
            }
    }

    /// MetalANNS graph construction requires more nodes than the graph degree.
    private var canBuildIndex: Bool {
        frameIds.count > configuration.degree
    }

    /// Exact scan used while there is no current graph (the store is too small for one, or a
    /// build is pending or failed). Scores use the
    /// same scale and ordering as AccelerateVectorEngine (cosine/dot: dot product of the
    /// stored and prepared query vectors; L2: negative squared distance).
    private func exactHits(for query: [Float], topK: Int) -> [(frameId: UInt64, score: Float)] {
        guard !frameIds.isEmpty else { return [] }
        var scores = [Float](repeating: 0, count: frameIds.count)
        let length = vDSP_Length(dimensions)
        vectors.withUnsafeBufferPointer { rows in
            query.withUnsafeBufferPointer { queryBuffer in
                guard let rowBase = rows.baseAddress, let queryBase = queryBuffer.baseAddress else { return }
                for row in frameIds.indices {
                    let rowStart = rowBase + row * dimensions
                    var value: Float = 0
                    switch metric {
                    case .cosine, .dot:
                        vDSP_dotpr(rowStart, 1, queryBase, 1, &value, length)
                    case .l2:
                        vDSP_distancesq(rowStart, 1, queryBase, 1, &value, length)
                        value = -value
                    }
                    scores[row] = value
                }
            }
        }
        let limit = min(max(topK, 1), frameIds.count)
        return VectorTopK.select(frameIds: frameIds, scores: scores, limit: limit)
    }

    /// Applies new-id inserts to the graph incrementally when MetalANNS can take them;
    /// otherwise drops the graph so the next search rebuilds it from `vectors`.
    /// MetalANNS 0.3.0 cannot re-insert an id it soft-deleted, and inserts past the capacity
    /// fixed when the graph was built throw. The graph is a derived cache, so any insert
    /// failure is handled by rebuilding rather than by failing an add whose data is stored.
    private func insertIntoIndex(_ records: [VectorRecord<UInt64>]) async {
        guard let index, !records.isEmpty else { return }
        guard !records.contains(where: { softDeletedFrameIds.contains($0.id) }) else {
            invalidateIndex()
            return
        }
        do {
            if records.count == 1, let record = records.first {
                try await index.insert(record)
            } else {
                try await index.batchInsert(records)
            }
        } catch {
            invalidateIndex()
        }
    }

    private func invalidateIndex() {
        index = nil
        softDeletedFrameIds.removeAll()
    }

    /// Starts a background graph build from a snapshot of the stored vectors, unless one is
    /// already running, the store is too small, the build for this generation failed, or a
    /// stale build was just discarded and mutations are still arriving (debounce).
    /// Searches never wait on it; they scan exactly until a current graph is installed.
    private func scheduleGraphBuildIfNeeded() {
        guard index == nil,
              graphBuildTask == nil,
              canBuildIndex,
              failedGraphBuildGeneration != mutationGeneration
        else { return }
        if let debounce = rebuildDebounceGeneration, debounce != lastNonAppendGeneration {
            rebuildDebounceGeneration = lastNonAppendGeneration
            return
        }
        let generation = mutationGeneration
        let rows = matrixVectors()
        let ids = frameIds
        let configuration = configuration
        let hook = graphBuildHook
        // Weak: a pending build must not keep a discarded engine alive.
        graphBuildTask = Task { [weak self] in
            let result = await Self.buildGraph(rows: rows, ids: ids, configuration: configuration, hook: hook)
            await self?.finishBackgroundGraphBuild(result, generation: generation, snapshotCount: ids.count)
        }
    }

    private func finishBackgroundGraphBuild(
        _ result: Result<ReadyIndex, any Error>,
        generation: UInt64,
        snapshotCount: Int
    ) async {
        graphBuildTask = nil
        await installGraph(result, generation: generation, snapshotCount: snapshotCount)
    }

    /// Builds the graph inline (used on load), under the same generation rule.
    private func buildGraphNow() async {
        invalidateIndex()
        guard canBuildIndex else { return }
        let generation = mutationGeneration
        let snapshotCount = frameIds.count
        let result = await Self.buildGraph(
            rows: matrixVectors(),
            ids: frameIds,
            configuration: configuration,
            hook: graphBuildHook
        )
        await installGraph(result, generation: generation, snapshotCount: snapshotCount)
    }

    /// Installs a built graph if it is still valid for the stored vectors:
    /// - no mutation since its snapshot: install as is;
    /// - only appends since its snapshot: install, then insert the appended rows (they are
    ///   exactly `frameIds[snapshotCount...]`, since appends never reorder);
    /// - otherwise: discard it, and debounce the next build.
    /// A failed build is logged and not retried until the next mutation.
    private func installGraph(
        _ result: Result<ReadyIndex, any Error>,
        generation: UInt64,
        snapshotCount: Int
    ) async {
        switch result {
        case .success(let built):
            guard index == nil else { return }
            guard lastNonAppendGeneration <= generation else {
                rebuildDebounceGeneration = lastNonAppendGeneration
                return
            }
            index = built
            softDeletedFrameIds.removeAll()
            rebuildDebounceGeneration = nil
            guard frameIds.count > snapshotCount else { return }
            let appended = (snapshotCount..<frameIds.count).map { row in
                let start = row * dimensions
                return VectorRecord(id: frameIds[row], vector: Array(vectors[start..<(start + dimensions)]))
            }
            // Appends that arrive during this await see the installed graph and insert
            // themselves; any insert failure drops the graph for a rebuild as usual.
            await insertIntoIndex(appended)
        case .failure(is CancellationError):
            // Not a build failure: leave the retry state alone so the next search can build.
            return
        case .failure(let error):
            graphBuildFailureCount += 1
            failedGraphBuildGeneration = generation
            let reason = String(describing: error)
            Self.logger.error(
                "MetalANNS graph build failed; exact search until the next mutation: \(reason, privacy: .public)"
            )
        }
    }

    private static func buildGraph(
        rows: [[Float]],
        ids: [UInt64],
        configuration: IndexConfiguration,
        hook: GraphBuildHook?
    ) async -> Result<ReadyIndex, any Error> {
        // Cancellation is checked before the build only: a GPU build already in progress
        // runs to completion, and a finished graph is still worth installing.
        do {
            try await hook?()
            try Task.checkCancellation()
            let builder = VectorIndex<UInt64, VectorIndexState.Unbuilt>(configuration: configuration)
            return .success(try await builder.build(vectors: rows, ids: ids))
        } catch {
            return .failure(error)
        }
    }

    private func matrixVectors() -> [[Float]] {
        guard !frameIds.isEmpty else { return [] }
        var rows: [[Float]] = []
        rows.reserveCapacity(frameIds.count)
        for index in frameIds.indices {
            let start = index * dimensions
            rows.append(Array(vectors[start..<(start + dimensions)]))
        }
        return rows
    }

    private func overwriteVector(at index: Int, with vector: [Float]) {
        let start = index * dimensions
        for dim in 0..<dimensions {
            vectors[start + dim] = vector[dim]
        }
    }

    private func overwriteVector(at index: Int, withSliceFrom sourceIndex: Int) {
        guard index != sourceIndex else { return }
        let sourceStart = sourceIndex * dimensions
        let targetStart = index * dimensions
        for dim in 0..<dimensions {
            vectors[targetStart + dim] = vectors[sourceStart + dim]
        }
    }

    private func preparedVector(_ vector: [Float]) -> [Float] {
        guard metric == .cosine, !vector.isEmpty else { return vector }
        let norm = sqrt(vector.reduce(into: Float.zero) { partial, value in
            partial += value * value
        })
        guard norm > 0 else { return vector }
        if abs(norm - 1) < 0.001 { return vector }
        return vector.map { value in value / norm }
    }

    private func validate(_ vector: [Float]) throws {
        try VectorValidation.validate(vector, dimensions: dimensions)
    }
}

private extension VectorMetric {
    func toMetalANNSMetric() -> Metric {
        switch self {
        case .cosine:
            return .cosine
        case .dot:
            return .innerProduct
        case .l2:
            return .l2
        }
    }
}
#endif
