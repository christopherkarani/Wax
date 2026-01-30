import Testing
@testable import Wax
@testable import WaxTextSearch

@Test func readOnlyDeserializeSearchesCommittedIndex() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()

        let content = "swift concurrency and vector search"
        let frameId = try await wax.put(Data(content.utf8), options: FrameMetaSubset(searchText: content))
        try await text.index(frameId: frameId, text: content)
        try await text.stageForCommit()
        try await wax.commit()
        try await wax.close()

        let reopened = try await Wax.open(at: url)
        guard let region = try await reopened.readCommittedLexIndexMapped() else {
            #expect(Bool(false))
            return
        }

        let readOnly = try FTS5SearchEngine.deserializeReadOnly(from: region)
        let results = try await readOnly.search(query: "vector", topK: 5)
        #expect(results.count == 1)
        #expect(results.first?.frameId == frameId)
        try await reopened.close()
    }
}
