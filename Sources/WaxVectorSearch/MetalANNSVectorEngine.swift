#if canImport(Metal) && canImport(MetalANNS)
import Accelerate
import Foundation
import Metal
import MetalANNS
import os
import WaxCore

package actor MetalANNSVectorEngine: VectorSearchEngine {
    package static let autoThreshold = 10_000
    /// Store size from which flat searches shortlist rows by sign code and rescore them
    /// exactly (see ``SignCodeIndex``) instead of scanning every Float32 row. Smaller
    /// stores keep the full exact scan.
    package static let defaultQuantizedScanMinVectorCount = 50_000

    /// Runs at the start of every graph build. Test seam for holding or failing a build.
    package typealias GraphBuildHook = @Sendable () async throws -> Void

    private typealias ReadyIndex = VectorIndex<UInt64, VectorIndexState.Ready>

    private static let logger = Logger(subsystem: "com.wax.vectorsearch", category: "MetalANNSVectorEngine")

    private let metric: VectorMetric
    package let dimensions: Int
    private let configuration: IndexConfiguration
    private let graphBuildHook: GraphBuildHook?
    private let quantizedScanMinVectorCount: Int

    /// Graph over `vectors`/`frameIds`, which are the source of truth. While it is `nil`,
    /// searches scan `vectors` (see `flatHits`), and a background build is scheduled when the graph
    /// would serve searches (see `graphServesSearches`).
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
    private var frameIds: [UInt64] = []
    private var positions: [UInt64: Int] = [:]
    private var vectors: [Float] = []
    /// Sign codes of `vectors`, row for row. Encoded by the first search that uses them,
    /// then kept in step with every mutation; `nil` until then and after a reload.
    private var signCodes: SignCodeIndex?
    /// Searches answered by the sign-code shortlist plus exact rescore.
    package private(set) var quantizedScanCount = 0
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
        exactSearchMaxVectorCount: Int? = nil,
        quantizedScanMinVectorCount: Int? = nil,
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
        if let exactSearchMaxVectorCount {
            configuration.exactSearchMaxVectorCount = max(0, exactSearchMaxVectorCount)
        }
        self.configuration = configuration
        self.graphBuildHook = graphBuildHook
        self.quantizedScanMinVectorCount = max(1, quantizedScanMinVectorCount ?? Self.defaultQuantizedScanMinVectorCount)
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

    /// Frame IDs that currently have a vector here.
    package func storedFrameIds() -> Set<UInt64> {
        Set(frameIds)
    }

    /// Waits for the in-flight background graph build, if any, to finish.
    package func waitForPendingGraphBuild() async {
        await graphBuildTask?.value
    }

    /// - Parameter exactSearchMaxVectorCount: Overrides the MetalANNS exact flat-scan cap;
    ///   `nil` keeps the MetalANNS default. A test seam for exercising the graph path.
    package static func load(
        from wax: Wax,
        metric: VectorMetric,
        dimensions: Int,
        exactSearchMaxVectorCount: Int? = nil
    ) async throws -> MetalANNSVectorEngine {
        try await load(
            from: wax,
            committed: try await wax.readCommittedVectors(),
            metric: metric,
            dimensions: dimensions,
            exactSearchMaxVectorCount: exactSearchMaxVectorCount
        )
    }

    /// Loads `committed` (what ``Wax/readCommittedVectors()`` returned) plus the store's
    /// pending vector changes.
    package static func load(
        from wax: Wax,
        committed: CommittedVectors?,
        metric: VectorMetric,
        dimensions: Int,
        exactSearchMaxVectorCount: Int? = nil
    ) async throws -> MetalANNSVectorEngine {
        let engine = try MetalANNSVectorEngine(
            metric: metric,
            dimensions: dimensions,
            searchMode: .exact,
            exactSearchMaxVectorCount: exactSearchMaxVectorCount
        )
        if let committed {
            try await engine.loadCommitted(committed)
        }
        let pending = await wax.pendingEmbeddingMutations(since: nil)
        if !pending.embeddings.isEmpty {
            try await engine.addBatch(
                frameIds: pending.embeddings.map(\.frameId),
                vectors: pending.embeddings.map(\.vector)
            )
        }
        for frameId in pending.removedFrameIds {
            try await engine.remove(frameId: frameId)
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
            signCodes?.append(rows: stored)
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
                signCodes?.append(rows: stored)
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
        signCodes?.removeSwappingLast(row: indexToRemove)
        if !canBuildIndex {
            invalidateIndex()
        } else if let index {
            do {
                try await index.delete(id: frameId)
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
            return flatHits(for: prepared, topK: topK)
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
            let mapped = flatHits(for: prepared, topK: topK)
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

    /// Records the index's dimension and similarity for the commit; the commit writes the
    /// pending embeddings and removals themselves from the WAL.
    package func stageForCommit(into wax: Wax) async throws {
        try await wax.setVectorIndexConfiguration(dimension: UInt32(dimensions), similarity: metric.toVecSimilarity())
        dirty = false
    }

    private func loadCommitted(_ committed: CommittedVectors) async throws {
        try VectorPreparation.validateCommitted(committed, dimensions: dimensions, metric: metric)
        frameIds = committed.frameIds
        vectors = VectorPreparation.preparedRows(committed.vectors, dimensions: dimensions, metric: metric)
        signCodes = nil
        positions.removeAll(keepingCapacity: true)
        positions.reserveCapacity(frameIds.count)
        for (index, frameId) in frameIds.enumerated() {
            positions[frameId] = index
        }
        mutationGeneration &+= 1
        lastNonAppendGeneration = mutationGeneration
        await buildGraphNow()
        droppedNonFiniteRowCount = committed.droppedNonFiniteRowCount
        dirty = false
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
            .map { (frameId: $0.id, score: metric.score(fromDistance: $0.distance)) }
            .filter { $0.score.isFinite }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score { return lhs.frameId < rhs.frameId }
                return lhs.score > rhs.score
            }
    }

    /// A graph is built only when it would serve searches; one over no more nodes than its
    /// degree is no faster than the exact scan.
    private var canBuildIndex: Bool {
        graphServesSearches && frameIds.count > configuration.degree
    }

    /// Whether MetalANNS would search a graph at the current size. In `.exact` mode it answers
    /// every search up to `exactSearchMaxVectorCount` vectors with a flat scan, so a graph
    /// built there would never be read; this engine scans `vectors` exactly instead.
    private var graphServesSearches: Bool {
        configuration.searchMode != .exact || frameIds.count > configuration.exactSearchMaxVectorCount
    }

    /// Flat search used while there is no current graph: the sign-code shortlist plus exact
    /// rescore for large stores where it applies, else the full exact scan.
    private func flatHits(for query: [Float], topK: Int) -> [(frameId: UInt64, score: Float)] {
        guard let rows = shortlistRows(for: query, topK: topK) else {
            return exactHits(for: query, topK: topK)
        }
        quantizedScanCount += 1
        return rescoredHits(rows: rows, query: query, topK: topK)
    }

    /// Rows worth rescoring for `query`, or `nil` when the full exact scan should run: a
    /// store below the threshold, L2 (sign codes estimate dot products), vectors too narrow
    /// for a sign code to rank them, or a shortlist that would cover much of the store.
    private func shortlistRows(for query: [Float], topK: Int) -> [Int]? {
        let rowCount = frameIds.count
        guard rowCount >= quantizedScanMinVectorCount,
              metric != .l2,
              dimensions >= SignCodeIndex.minDimensions
        else { return nil }
        let limit = SignCodeIndex.candidateCount(topK: topK)
        guard limit <= rowCount / 4 else { return nil }
        let codes = signCodes ?? SignCodeIndex(dimensions: dimensions, rows: vectors)
        signCodes = codes
        return codes.candidates(for: query, limit: limit)
    }

    /// Exact scores for `rows`, ranked like ``exactHits(for:topK:)``.
    private func rescoredHits(rows: [Int], query: [Float], topK: Int) -> [(frameId: UInt64, score: Float)] {
        var scores = [Float](repeating: 0, count: rows.count)
        let length = vDSP_Length(dimensions)
        vectors.withUnsafeBufferPointer { stored in
            query.withUnsafeBufferPointer { queryBuffer in
                scores.withUnsafeMutableBufferPointer { scoreBuffer in
                    guard let storedBase = stored.baseAddress,
                          let queryBase = queryBuffer.baseAddress,
                          let scoreBase = scoreBuffer.baseAddress
                    else { return }
                    for (slot, row) in rows.enumerated() {
                        vDSP_dotpr(storedBase + row * dimensions, 1, queryBase, 1, scoreBase + slot, length)
                    }
                }
            }
        }
        let limit = min(max(topK, 1), rows.count)
        return VectorTopK.select(frameIds: rows.map { frameIds[$0] }, scores: scores, limit: limit)
    }

    /// Exact scan used while there is no current graph (exact mode at or below the flat-scan
    /// cap, a store too small for a graph, or a build that is pending or failed). Scores use
    /// the same scale and ordering as AccelerateVectorEngine (cosine/dot: dot product of the
    /// stored and prepared query vectors; L2: negative squared distance).
    private func exactHits(for query: [Float], topK: Int) -> [(frameId: UInt64, score: Float)] {
        guard !frameIds.isEmpty else { return [] }
        var scores = [Float](repeating: 0, count: frameIds.count)
        let rowCount = frameIds.count
        let length = vDSP_Length(dimensions)
        vectors.withUnsafeBufferPointer { rows in
            query.withUnsafeBufferPointer { queryBuffer in
                scores.withUnsafeMutableBufferPointer { scoreBuffer in
                    guard let rowBase = rows.baseAddress,
                          let queryBase = queryBuffer.baseAddress,
                          let scoreBase = scoreBuffer.baseAddress
                    else { return }
                    switch metric {
                    case .cosine, .dot:
                        // One matrix-vector product over the row-major store, as Accelerate does.
                        vDSP_mmul(rowBase, 1, queryBase, 1, scoreBase, 1, vDSP_Length(rowCount), 1, length)
                    case .l2:
                        for row in 0..<rowCount {
                            var value: Float = 0
                            vDSP_distancesq(rowBase + row * dimensions, 1, queryBase, 1, &value, length)
                            scoreBase[row] = -value
                        }
                    }
                }
            }
        }
        let limit = min(max(topK, 1), frameIds.count)
        return VectorTopK.select(frameIds: frameIds, scores: scores, limit: limit)
    }

    /// Applies new-id inserts (including re-adds of removed ids) to the graph incrementally.
    /// The graph is a derived cache, so an insert failure drops it for a rebuild from
    /// `vectors` rather than failing an add whose data is stored.
    private func insertIntoIndex(_ records: [VectorRecord<UInt64>]) async {
        guard let index, !records.isEmpty else { return }
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
        let rows = vectors
        let ids = frameIds
        let dimension = dimensions
        let configuration = configuration
        let hook = graphBuildHook
        // Weak: a pending build must not keep a discarded engine alive.
        graphBuildTask = Task { [weak self] in
            let result = await Self.buildGraph(
                flatVectors: rows,
                dimension: dimension,
                ids: ids,
                configuration: configuration,
                hook: hook
            )
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

    /// Builds the graph inline (used on load when the graph would serve searches), under the
    /// same generation rule.
    private func buildGraphNow() async {
        invalidateIndex()
        guard canBuildIndex else { return }
        let generation = mutationGeneration
        let snapshotCount = frameIds.count
        let result = await Self.buildGraph(
            flatVectors: vectors,
            dimension: dimensions,
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
        flatVectors: [Float],
        dimension: Int,
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
            return .success(
                try await builder.build(flatVectors: flatVectors, dimension: dimension, ids: ids)
            )
        } catch {
            return .failure(error)
        }
    }

    private func overwriteVector(at index: Int, with vector: [Float]) {
        let start = index * dimensions
        // One mutation per row: per-element subscript writes cost a uniqueness check each, and
        // Swift 6.2 debug builds copied the whole store on every one of them.
        vectors.replaceSubrange(start..<(start + dimensions), with: vector)
        signCodes?.replace(row: index, with: vector)
    }

    private func overwriteVector(at index: Int, withSliceFrom sourceIndex: Int) {
        guard index != sourceIndex else { return }
        let sourceStart = sourceIndex * dimensions
        let targetStart = index * dimensions
        let dimensions = dimensions
        vectors.withUnsafeMutableBufferPointer { rows in
            for dim in 0..<dimensions {
                rows[targetStart + dim] = rows[sourceStart + dim]
            }
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
