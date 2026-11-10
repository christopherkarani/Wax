import Foundation
import Testing
@testable import Wax
import WaxCore

/// The session commit of a frame import: its text postings stay unseen until the store commit
/// publishes the frames, and its vectors reach the vector engine.
private enum SessionImport {
    static let dimensions = 8

    static func vector(_ index: Int) -> [Float] {
        let raw: [Float] = (0..<dimensions).map { (component: Int) -> Float in
            Float((index * 7 + component * 13) % 97) + 1
        }
        let norm = raw.reduce(Float(0)) { (sum: Float, value: Float) -> Float in sum + value * value }.squareRoot()
        return raw.map { (value: Float) -> Float in value / norm }
    }

    static func options(_ text: String) -> FrameMetaSubset {
        var options = FrameMetaSubset(role: .document)
        options.searchText = text
        return options
    }
}

private actor SearchTaskBox {
    private(set) var task: Task<(hits: [UInt64], committedFrames: UInt64), any Error>?
    func set(_ task: Task<(hits: [UInt64], committedFrames: UInt64), any Error>) { self.task = task }
}

private struct VectorLoadFault: Error {}

@Test func textSearchesDuringAnImportCommitNeverSeeItsUncommittedFrames() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let session = try await wax.openSession(.readWrite(), config: WaxSession.Config(enableVectorSearch: false))
        let seedText = "a lighthouse keeper's notes"
        let seed = try await session.put(Data(seedText.utf8), options: SessionImport.options(seedText))
        try await session.indexText(frameId: seed, text: seedText)
        try await session.commit()

        #expect(try await wax.beginFrameImport())
        let texts: [String] = (0..<300).map { (index: Int) -> String in "lighthouse lighthouse beacon \(index)" }
        let ids = try await wax.importFrames(
            texts.map { (text: String) -> Data in Data(text.utf8) },
            options: texts.map(SessionImport.options)
        )

        // A search started while the import's postings are indexed and staged, before the
        // store commit, returns only frames committed by the time it returns.
        let box = SearchTaskBox()
        await session.setFrameImportCommitHookForTesting {
            let search = Task { () async throws -> (hits: [UInt64], committedFrames: UInt64) in
                let hits = try await session.searchText(query: "lighthouse", topK: 50)
                let committed = await wax.stats().frameCount
                return (hits.map(\.frameId), committed)
            }
            await box.set(search)
            try? await Task.sleep(for: .milliseconds(300))
        }
        let pairs: [(frameId: UInt64, text: String)] = zip(ids, texts).map { (frameId: UInt64, text: String) in
            (frameId: frameId, text: text)
        }
        try await session.commitFrameImport(texts: pairs, hasVectors: false, memoryBinding: nil)
        await session.setFrameImportCommitHookForTesting(nil)

        let search = try #require(await box.task)
        let observed = try await search.value
        #expect(!observed.hits.isEmpty)
        #expect(
            observed.hits.allSatisfy { (frameId: UInt64) -> Bool in frameId < observed.committedFrames },
            "hits \(observed.hits.prefix(5)) with \(observed.committedFrames) committed frames"
        )
        #expect(await wax.stats().frameCount == 301)
        try await wax.close()
    }
}

@Test func importVectorsReachSearchWhenLoadingThemIntoTheEngineFails() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let session = try await wax.openSession(
            .readWrite(),
            config: WaxSession.Config(enableTextSearch: false, vectorDimensions: SessionImport.dimensions)
        )
        let seed = try await session.put(Data("seed".utf8), embedding: SessionImport.vector(1_000))
        try await session.commit()

        #expect(try await wax.beginFrameImport())
        let count = 40
        let ids = try await wax.importFrames(
            (0..<count).map { (index: Int) -> Data in Data("imported \(index)".utf8) },
            options: Array(repeating: FrameMetaSubset(role: .document), count: count)
        )
        try await wax.importEmbeddings(frameIds: ids, vectors: (0..<count).map(SessionImport.vector))
        await session.failNextFrameImportVectorLoadForTesting(VectorLoadFault())
        try await session.commitFrameImport(texts: [], hasVectors: true, memoryBinding: nil)

        for index in [0, 7, count - 1] {
            let request = try SearchRequest(lane: .vectorOnly(embedding: SessionImport.vector(index)), topK: 1)
            let response = try await session.search(request)
            #expect(response.results.first?.frameId == ids[index], "imported frame \(index)")
        }
        let seedHit = try await session.search(try SearchRequest(lane: .vectorOnly(embedding: SessionImport.vector(1_000)), topK: 1))
        #expect(seedHit.results.first?.frameId == seed)
        try await wax.close()
    }
}
