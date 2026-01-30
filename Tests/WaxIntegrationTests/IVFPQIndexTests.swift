import Testing
@testable import WaxVectorSearch

@Test func ivfpqClusterAssignmentMatchesIVF() async throws {
    let dimensions = 4
    let index = IVFPQIndex(dimensions: dimensions, numClusters: 2, numSubspaces: 2)
    let vectors: [[Float]] = [
        [0, 0, 0, 0],
        [1, 1, 1, 1],
        [10, 10, 10, 10],
        [11, 11, 11, 11]
    ]
    await index.train(vectors: vectors, ivfIterations: 5, pqIterations: 5)

    let frameIds: [UInt64] = [100, 101, 200, 201]
    await index.addBatch(frameIds: frameIds, vectors: vectors)

    for (frameId, vector) in zip(frameIds, vectors) {
        let assigned = await index.clusterIndex(for: frameId)
        let nearest = await index.nearestClusterIndex(for: vector)
        #expect(assigned == nearest)
    }
}
