import Foundation
import Testing

@Test
func vectorSearchDocsDoNotAdvertisePackageOnlyProtocolAsPublicAPI() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let source = try String(
        contentsOf: repoRoot.appendingPathComponent("Sources/WaxVectorSearch/VectorSearchEngine.swift"),
        encoding: .utf8
    )
    #expect(source.contains("package protocol VectorSearchEngine"))

    for relativePath in vectorSearchDocPaths {
        let doc = try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)

        #expect(doc.contains("package-only"))
        #expect(doc.contains("not public API"))
        #expect(!doc.contains("ships two ``VectorSearchEngine`` implementations"))
        #expect(!doc.contains("ships two `VectorSearchEngine` implementations"))
        #expect(!doc.contains("implement the ``VectorSearchEngine`` protocol"))
        #expect(!doc.contains("Both engines share the ``VectorSearchEngine`` protocol"))
        #expect(!doc.contains("Both engines share the `VectorSearchEngine` protocol"))
        #expect(!doc.contains("- ``VectorSearchEngine``"))
    }
}

@Test
func vectorSearchDocsDoNotClaimProtocolHasStreamingBatchAPI() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let protocolSource = try String(
        contentsOf: repoRoot.appendingPathComponent("Sources/WaxVectorSearch/VectorSearchEngine.swift"),
        encoding: .utf8
    )
    #expect(!protocolSource.contains("addBatchStreaming"))

    for relativePath in vectorSearchDocPaths {
        let doc = try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
        #expect(!doc.contains("addBatchStreaming"))
    }
}

private let vectorSearchDocPaths = [
    "Sources/WaxVectorSearch/WaxVectorSearch.docc/Documentation.md",
    "Sources/WaxVectorSearch/WaxVectorSearch.docc/Articles/VectorSearchEngines.md",
    "Resources/website/docs/vector-search/vector-search-engines.md",
]
