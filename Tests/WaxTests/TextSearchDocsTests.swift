import Foundation
import Testing

@Test
func textSearchDocsDoNotAdvertisePackageOnlyFTS5EngineAsPublicAPI() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let source = try String(
        contentsOf: repoRoot.appendingPathComponent("Sources/WaxTextSearch/FTS5SearchEngine.swift"),
        encoding: .utf8
    )
    #expect(source.contains("package actor FTS5SearchEngine"))

    for relativePath in textSearchDocPaths {
        let doc = try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)

        #expect(doc.contains("package-only"))
        #expect(doc.contains("not public API"))
        #expect(!doc.contains("The primary entry point is the ``FTS5SearchEngine`` actor"))
        #expect(!doc.contains("There are three ways to create an engine"))
        #expect(!doc.contains("`FTS5SearchEngine` is an actor that"))
        #expect(!doc.contains("``FTS5SearchEngine`` is an actor that"))
    }
}

@Test
func textSearchDocsDoNotAdvertisePackageOnlyTextSearchResultAsPublicAPI() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let source = try String(
        contentsOf: repoRoot.appendingPathComponent("Sources/WaxTextSearch/TextSearchResult.swift"),
        encoding: .utf8
    )
    #expect(source.contains("package struct TextSearchResult"))

    for relativePath in textSearchDocPaths {
        let doc = try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)

        #expect(!doc.contains("``TextSearchResult``"))
        #expect(!doc.contains("`TextSearchResult`"))
        #expect(!doc.contains("Each ``TextSearchResult`` contains"))
        #expect(!doc.contains("Each `TextSearchResult` contains"))
    }
}

@Test
func textSearchDocsDoNotShowPackageOnlyStructuredMemoryExamplesAsPublicAPI() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let source = try String(
        contentsOf: repoRoot.appendingPathComponent("Sources/WaxTextSearch/FTS5SearchEngine.swift"),
        encoding: .utf8
    )
    #expect(source.contains("package func upsertEntity"))
    #expect(source.contains("package func assertFact"))

    for relativePath in textSearchDocPaths {
        let doc = try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)

        #expect(!doc.contains("engine.upsertEntity"))
        #expect(!doc.contains("engine.assertFact"))
        #expect(!doc.contains("engine.facts"))
        #expect(!doc.contains("EntityKey("))
        #expect(!doc.contains("StructuredTimeRange("))
        #expect(!doc.contains("StructuredMemoryAsOf("))
    }
}

private let textSearchDocPaths = [
    "Sources/WaxTextSearch/WaxTextSearch.docc/Documentation.md",
    "Sources/WaxTextSearch/WaxTextSearch.docc/Articles/TextSearchEngine.md",
    "Resources/website/docs/text-search/text-search-engine.md",
]
