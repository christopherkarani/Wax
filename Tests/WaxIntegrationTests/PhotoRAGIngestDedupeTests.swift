import Testing
@testable import Wax

@Test
func photoRAGIngestDedupesAssetIDsStably() {
    let input = ["A", "B", "A", "C", "B", "D", "D"]
    let output = PhotoRAGOrchestrator.dedupeAssetIDs(input)
    #expect(output == ["A", "B", "C", "D"])
}
