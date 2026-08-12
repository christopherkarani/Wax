import Foundation
import Testing
import Wax
import WaxCore

@Test
func fastRAGIntegrationCreateRecallReopen() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()

        let payload = "Swift makes concurrency safe."
        let frameId = try await wax.put(Data(payload.utf8), options: FrameMetaSubset(searchText: payload))
        try await text.index(frameId: frameId, text: payload)
        try await text.commit()

        let builder = FastRAGContextBuilder()
        let ctx1 = try await builder.build(query: "concurrency", wax: wax)
        #expect(!ctx1.items.isEmpty)

        let baseName = url.deletingPathExtension().lastPathComponent
        let dir = url.deletingLastPathComponent()
        let contents = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        let related = contents.filter { $0.lastPathComponent.hasPrefix(baseName) }
        #expect(related.count == 1)
        #expect(related.first?.resolvingSymlinksInPath() == url.resolvingSymlinksInPath())

        try await wax.close()

        let reopened = try await Wax.open(at: url)
        let ctx2 = try await builder.build(query: "concurrency", wax: reopened)
        #expect(!ctx2.items.isEmpty)
        try await reopened.close()
    }
}
