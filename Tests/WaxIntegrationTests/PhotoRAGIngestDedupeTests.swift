import Testing
@testable import Wax

@Test
func photoRAGIngestDedupesPhotoIDsStably() {
    let input = [
        PhotoID(source: .photos, id: "A"),
        PhotoID(source: .photos, id: "B"),
        PhotoID(source: .photos, id: "A"),
        PhotoID(source: .photos, id: "C"),
        PhotoID(source: .photos, id: "B"),
        PhotoID(source: .photos, id: "D"),
        PhotoID(source: .photos, id: "D"),
    ]
    let output = PhotoRAGOrchestrator.dedupePhotoIDs(input)
    #expect(output == [
        PhotoID(source: .photos, id: "A"),
        PhotoID(source: .photos, id: "B"),
        PhotoID(source: .photos, id: "C"),
        PhotoID(source: .photos, id: "D"),
    ])
}

@Test
func photoRAGIngestDedupeTreatsSourceAsPartOfIdentity() {
    let mixed = [
        PhotoID(source: .photos, id: "A"),
        PhotoID(source: .file, id: "A"),
    ]
    #expect(PhotoRAGOrchestrator.dedupePhotoIDs(mixed) == mixed)
}
