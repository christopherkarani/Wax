import Foundation
import Testing
@testable import Wax
import WaxCore

/// A document -> chunk -> enrichment tree, built directly so the test does not
/// depend on chunking or async enrichment timing.
private struct FrameTree {
    let document: UInt64
    let chunk: UInt64
    let enrichment: UInt64
    let unrelated: UInt64
}

private func makeFrameTree(at url: URL, deleteDocumentFirst: Bool = false) async throws -> FrameTree {
    let wax = try await Wax.create(at: url)
    let session = try await wax.openSession(.readWrite(), config: WaxSession.Config(enableVectorSearch: false))

    var documentOptions = FrameMetaSubset()
    documentOptions.role = .document
    let document = try await wax.put(Data("basalt survey document".utf8), options: documentOptions)

    var chunkOptions = FrameMetaSubset()
    chunkOptions.role = .chunk
    chunkOptions.parentId = document
    chunkOptions.searchText = "basaltchunk survey notes"
    let chunk = try await wax.put(Data("basaltchunk survey notes".utf8), options: chunkOptions)
    try await session.indexText(frameId: chunk, text: "basaltchunk survey notes")

    var enrichmentOptions = FrameMetaSubset()
    enrichmentOptions.parentId = chunk
    enrichmentOptions.searchText = "basaltenrich summary"
    let enrichment = try await wax.put(Data("basaltenrich summary".utf8), options: enrichmentOptions)
    try await session.indexText(frameId: enrichment, text: "basaltenrich summary")

    let unrelated = try await wax.put(
        Data("granite reference card".utf8),
        options: FrameMetaSubset(searchText: "granite reference card")
    )
    try await session.indexText(frameId: unrelated, text: "granite reference card")

    if deleteDocumentFirst {
        // Pre-cascade stores: the document was deleted but its chunks were not.
        try await wax.delete(frameId: document)
    }
    try await session.commit()
    try await wax.commit()
    try await wax.close()
    return FrameTree(document: document, chunk: chunk, enrichment: enrichment, unrelated: unrelated)
}

private func textOnlyOrchestrator(at url: URL) async throws -> MemoryOrchestrator {
    var config = OrchestratorConfig.default
    config.enableVectorSearch = false
    return try await MemoryOrchestrator(at: url, config: config)
}

private func activeIDs(_ orchestrator: MemoryOrchestrator) async -> Set<UInt64> {
    Set(await orchestrator.wax.frameMetasIncludingPending().filter { $0.status == .active }.map(\.id))
}

@Test
func deleteCascadesTransitivelyToEnrichmentFrames() async throws {
    try await TempFiles.withTempFile { url in
        let tree = try await makeFrameTree(at: url)
        let orchestrator = try await textOnlyOrchestrator(at: url)

        try await orchestrator.delete(frameId: tree.document)

        #expect(await activeIDs(orchestrator) == [tree.unrelated])
        let hits = try await orchestrator.recallExecution(query: "basaltenrich", mode: .textOnly).context.items
        #expect(hits.isEmpty)
        try await orchestrator.close()
    }
}

@Test
func deletingAlreadyDeletedDocumentStillRemovesItsChunks() async throws {
    try await TempFiles.withTempFile { url in
        let tree = try await makeFrameTree(at: url, deleteDocumentFirst: true)
        let orchestrator = try await textOnlyOrchestrator(at: url)
        #expect(await activeIDs(orchestrator).contains(tree.chunk))

        try await orchestrator.delete(frameId: tree.document)

        #expect(await activeIDs(orchestrator) == [tree.unrelated])
        let hits = try await orchestrator.recallExecution(query: "basaltchunk", mode: .textOnly).context.items
        #expect(hits.isEmpty)
        try await orchestrator.close()
    }
}

@Test
func batchDeleteCommitsOnceAndRemovesEveryChunk() async throws {
    try await TempFiles.withTempFile { url in
        let orchestrator = try await textOnlyOrchestrator(at: url)
        let filler = String(
            repeating: "The survey crew logged stake heights, snow depth and meltwater flow at camp. ",
            count: 60
        )
        let longID = try await orchestrator.remember("Zirconium sample notes. " + filler).frameId
        let shortA = try await orchestrator.remember("Zirconium card A").frameId
        let shortB = try await orchestrator.remember("Zirconium card B").frameId
        let keep = try await orchestrator.remember("Zirconium card kept").frameId
        try await orchestrator.flush()

        let before = await orchestrator.runtimeStats().generation
        try await orchestrator.delete(frameIds: [longID, shortA, shortB])
        let after = await orchestrator.runtimeStats().generation
        #expect(after == before + 1)

        let remaining = try await orchestrator.recallExecution(query: "zirconium", mode: .textOnly).context
        #expect(Set(remaining.items.map(\.frameId)) == [keep])
        let crew = try await orchestrator.recallExecution(query: "meltwater stake heights", mode: .textOnly).context
        #expect(crew.items.isEmpty)
        try await orchestrator.close()
    }
}

@Test
func batchDeleteWithUnknownIDLeavesNothingPending() async throws {
    try await TempFiles.withTempFile { url in
        let memory = try await Memory(at: url, config: .init(enableVectorSearch: false))
        let keep = try await memory.save("Obsidian sample in tray four")
        try await memory.flush()

        await #expect(throws: (any Error).self) {
            try await memory.delete(frameIDs: [keep, 9_999_999])
        }
        try await memory.flush()

        let hits = try await memory.search("obsidian tray", options: .init(mode: .textOnly))
        #expect(hits.items.map(\.frameId).contains(keep))
        try await memory.close()
    }
}

// MARK: - Forget reports what a failed batch actually deleted

private struct InjectedDeleteFailure: Error {}

/// Fails the `failOn`-th call of `step`, counting from 1.
private final class DeleteStepFailer: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let step: MemoryOrchestrator.DeleteStep
    private let failOn: Int

    init(step: MemoryOrchestrator.DeleteStep, failOn: Int) {
        self.step = step
        self.failOn = failOn
    }

    func check(_ step: MemoryOrchestrator.DeleteStep, _ frameId: UInt64) throws {
        guard step == self.step else { return }
        lock.lock()
        calls += 1
        let current = calls
        lock.unlock()
        if current == failOn { throw InjectedDeleteFailure() }
    }
}

/// Forgets three one-frame memories with the `failOn`-th call of `step` failing.
/// Returns the reported result, how many of the three are deleted after
/// reopen, and how many are still found by search.
private func forgetWithFailure(
    at step: MemoryOrchestrator.DeleteStep,
    failOn: Int = 2,
    url: URL
) async throws -> (result: WaxMemoryToolResult, deletedAfterReopen: Int, searchableAfterReopen: Int) {
    let orchestrator = try await textOnlyOrchestrator(at: url)
    var ids: [UInt64] = []
    for label in ["one", "two", "three"] {
        ids.append(try await orchestrator.remember("Feldspar card \(label)").frameId)
    }
    try await orchestrator.flush()

    let failer = DeleteStepFailer(step: step, failOn: failOn)
    await orchestrator.setDeleteStepHookForTesting { try failer.check($0, $1) }
    let result = await WaxMemoryToolExecutor.execute(
        memory: Memory(orchestrator: orchestrator),
        config: WaxMemoryToolConfig(),
        action: .forget,
        query: "feldspar card"
    )
    await orchestrator.setDeleteStepHookForTesting(nil)
    try await orchestrator.close()

    let reopened = try await textOnlyOrchestrator(at: url)
    let live = await activeIDs(reopened)
    let hits = try await reopened.recallExecution(query: "feldspar card", mode: .textOnly).context.items
    try await reopened.close()
    let searchable = Set(hits.map(\.frameId)).intersection(ids).count
    return (result, ids.filter { !live.contains($0) }.count, searchable)
}

@Test
func forgetReportsTrueCountWhenSoftDeleteFailsPartWay() async throws {
    try await TempFiles.withTempFile { url in
        let outcome = try await forgetWithFailure(at: .softDelete, url: url)
        #expect(outcome.result.status == .error)
        #expect(outcome.deletedAfterReopen == 1)
        #expect(outcome.result.itemCount == outcome.deletedAfterReopen)
        #expect(outcome.result.message.contains("deleted 1 memory frame"))
        // The two frames that were not deleted are still searchable.
        #expect(outcome.searchableAfterReopen == 2)
    }
}

@Test
func forgetReportsTrueCountWhenIndexRemovalFails() async throws {
    try await TempFiles.withTempFile { url in
        // Index removal runs after every soft-delete, so all three are deleted.
        let outcome = try await forgetWithFailure(at: .indexRemoval, url: url)
        #expect(outcome.result.status == .error)
        #expect(outcome.deletedAfterReopen == 3)
        #expect(outcome.result.itemCount == 3)
        #expect(outcome.searchableAfterReopen == 0)
    }
}

@Test
func forgetReportsAllDeletedWhenFinalCommitFails() async throws {
    try await TempFiles.withTempFile { url in
        // Every soft-delete is already in the WAL when the commit fails.
        let outcome = try await forgetWithFailure(at: .commit, failOn: 1, url: url)
        #expect(outcome.result.status == .error)
        #expect(outcome.result.itemCount == 3)
        #expect(outcome.result.message.contains("deleted 3 memory frames"))
        #expect(outcome.deletedAfterReopen == 3)
        #expect(outcome.searchableAfterReopen == 0)
    }
}
