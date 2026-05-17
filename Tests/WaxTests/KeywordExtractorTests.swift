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
func preservesTechnicalIdentifiers() {
    let text = "Atlas-10 uses Qwen2_5 with all-MiniLM-L6-v2 through wax-mcp and SwiftConcurrency."
    let keywords = KeywordExtractor.extract(from: text, topK: 10)

    #expect(keywords.contains("Atlas-10"))
    #expect(keywords.contains("Qwen2_5"))
    #expect(keywords.contains("all-MiniLM-L6-v2"))
    #expect(keywords.contains("wax-mcp"))
    #expect(keywords.contains("SwiftConcurrency"))
    #expect(!keywords.contains("atlas"))
    #expect(!keywords.contains("minilm"))
}

@Test
func doesNotPreserveOrdinaryHyphenatedProse() {
    let text = "State-of-the-art long-term system supports MCPServer and URLSession."
    let keywords = KeywordExtractor.extract(from: text, topK: 10)

    #expect(!keywords.contains("State-of-the-art"))
    #expect(!keywords.contains("state-of-the-art"))
    #expect(!keywords.contains("long-term"))
    #expect(keywords.contains("state"))
    #expect(keywords.contains("art"))
    #expect(keywords.contains("long"))
    #expect(keywords.contains("term"))
    #expect(keywords.contains("MCPServer"))
    #expect(keywords.contains("URLSession"))
    #expect(!keywords.contains("mcpserver"))
    #expect(!keywords.contains("urlsession"))
}

@Test
func emptyTextReturnsEmpty() {
    let keywords = KeywordExtractor.extract(from: "", topK: 10)
    #expect(keywords.isEmpty)
}
