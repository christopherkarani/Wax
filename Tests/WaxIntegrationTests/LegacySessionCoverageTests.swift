import Foundation
import Testing
import Wax

@Test
func deprecatedTextSearchSessionCommitSwallowsMissingVectorStageError() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let frameId = try await wax.put(Data("text-only".utf8))
        try await wax.putEmbedding(frameId: frameId, vector: [1, 0])

        let session = try await wax.enableTextSearch()
        try await session.index(frameId: frameId, text: "text-only")

        // This commit path intentionally swallows the specific vector-stage error.
        try await session.commit(compact: true)

        do {
            try await wax.commit()
            #expect(Bool(false))
        } catch let error as WaxError {
            guard case .io(let reason) = error else {
                #expect(Bool(false))
                return
            }
            #expect(reason.contains("vector index must be staged before committing embeddings"))
        }

        try? await wax.close()
    }
}

@Test
func deprecatedStructuredMemorySessionCommitSwallowsMissingVectorStageError() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let frameId = try await wax.put(Data("structured".utf8))
        try await wax.putEmbedding(frameId: frameId, vector: [1, 0])

        let session = try await wax.structuredMemory()
        _ = try await session.upsertEntity(
            key: EntityKey("agent:legacy"),
            kind: "agent",
            aliases: ["legacy"],
            nowMs: 100
        )

        // This commit path intentionally swallows the specific vector-stage error.
        try await session.commit(compact: true)

        do {
            try await wax.commit()
            #expect(Bool(false))
        } catch let error as WaxError {
            guard case .io(let reason) = error else {
                #expect(Bool(false))
                return
            }
            #expect(reason.contains("vector index must be staged before committing embeddings"))
        }

        try? await wax.close()
    }
}

@Test
func deprecatedEnableVectorSearchFromManifestCoversMissingAndPresentManifest() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)

        do {
            _ = try await wax.enableVectorSearchFromManifest(preference: .cpuOnly)
            #expect(Bool(false))
        } catch let error as WaxError {
            guard case .io(let reason) = error else {
                #expect(Bool(false))
                return
            }
            #expect(reason.contains("vec index manifest missing"))
        }

        let session = try await wax.enableVectorSearch(
            metric: .cosine,
            dimensions: 2,
            preference: .cpuOnly
        )
        let frameId = try await wax.put(Data("vector-manifest".utf8))
        try await session.add(frameId: frameId, vector: [1, 0])
        try await session.commit()

        let fromManifest = try await wax.enableVectorSearchFromManifest(preference: .cpuOnly)
        #expect(await fromManifest.metric == .cosine)
        #expect(await fromManifest.dimensions == 2)

        try await wax.close()
    }
}
