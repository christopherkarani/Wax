import Testing
@testable import Wax

@Test
func extractsTopKeywords() {
    let text = "Swift concurrency enables structured concurrency patterns with actors and async await"
    let keywords = KeywordExtractor.extract(from: text, topK: 5)
    #expect(keywords.contains("concurrency"))
    #expect(keywords.contains("swift"))
    #expect(keywords.count <= 5)
    #expect(!keywords.contains("and"))
    #expect(!keywords.contains("with"))
}

@Test
func emptyTextReturnsEmpty() {
    let keywords = KeywordExtractor.extract(from: "", topK: 10)
    #expect(keywords.isEmpty)
}
