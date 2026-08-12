import Foundation
import Testing
import Wax
import WaxCore

@Test
func surrogateFrameIdReturnsNilWhenSourceFrameDeleted() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)

        let sourceText = "Swift concurrency uses actors."
        let sourceId = try await wax.put(Data(sourceText.utf8), options: FrameMetaSubset(role: .chunk, searchText: sourceText))

        var meta = Metadata()
        meta.entries["source_frame_id"] = String(sourceId)
        meta.entries["surrogate_algo"] = "test_v1"
        meta.entries["surrogate_version"] = "1"
        meta.entries["source_content_hash"] = "deadbeef"

        var subset = FrameMetaSubset()
        subset.kind = "surrogate"
        subset.role = .system
        subset.metadata = meta

        let surrogateId = try await wax.put(Data("surrogate".utf8), options: subset)
        try await wax.commit()

        #expect(await wax.surrogateFrameId(sourceFrameId: sourceId) == surrogateId)

        try await wax.delete(frameId: sourceId)
        try await wax.commit()

        #expect(await wax.surrogateFrameId(sourceFrameId: sourceId) == nil)
        try await wax.close()
    }
}

@Test
func surrogateFrameIdReturnsNilWhenSourceFrameSuperseded() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)

        let sourceText = "Swift concurrency uses tasks."
        let sourceId = try await wax.put(Data(sourceText.utf8), options: FrameMetaSubset(role: .chunk, searchText: sourceText))

        var meta = Metadata()
        meta.entries["source_frame_id"] = String(sourceId)
        meta.entries["surrogate_algo"] = "test_v1"
        meta.entries["surrogate_version"] = "1"
        meta.entries["source_content_hash"] = "deadbeef"

        var subset = FrameMetaSubset()
        subset.kind = "surrogate"
        subset.role = .system
        subset.metadata = meta

        _ = try await wax.put(Data("surrogate".utf8), options: subset)
        try await wax.commit()

        let replacementText = "Swift concurrency uses structured tasks."
        let replacementId = try await wax.put(
            Data(replacementText.utf8),
            options: FrameMetaSubset(role: .chunk, searchText: replacementText)
        )
        try await wax.supersede(supersededId: sourceId, supersedingId: replacementId)
        try await wax.commit()

        #expect(await wax.surrogateFrameId(sourceFrameId: sourceId) == nil)
        try await wax.close()
    }
}
