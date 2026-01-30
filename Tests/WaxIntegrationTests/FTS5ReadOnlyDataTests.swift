import Testing
import WaxCore
import WaxTextSearch

@Test func fts5DeserializeReadOnlyFromData() async throws {
    let engine = try FTS5SearchEngine.inMemory()
    try await engine.index(frameId: 1, text: "hello wax")
    try await engine.index(frameId: 2, text: "another document")

    let serialized = try await engine.serialize()
    let readOnlyEngine = try FTS5SearchEngine.deserializeReadOnly(from: serialized)

    let results = try await readOnlyEngine.search(query: "hello", topK: 10)
    #expect(results.contains(where: { $0.frameId == 1 }))

    var didThrow = false
    do {
        try await readOnlyEngine.index(frameId: 3, text: "should fail")
    } catch {
        didThrow = true
    }
    #expect(didThrow)
}
