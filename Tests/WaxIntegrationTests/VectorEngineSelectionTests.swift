import Testing
@testable import Wax

@Test func autoVectorEnginePrefersUSearchForLargeTopK() {
    let kind = UnifiedSearchEngineCache.autoEngineKind(for: 1_000, topK: 128)
    #expect(kind == .usearch)
}

@Test func autoVectorEnginePrefersMetalForSmallTopKAndCount() {
    let kind = UnifiedSearchEngineCache.autoEngineKind(for: 1_000, topK: 16)
    #expect(kind == .metal)
}
