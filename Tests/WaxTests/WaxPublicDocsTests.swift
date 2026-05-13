import Foundation
import Testing

@Test
func waxDocsDoNotAdvertisePackageOnlyWaxSessionAsPublicAPI() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let source = try String(
        contentsOf: repoRoot.appendingPathComponent("Sources/Wax/WaxSession.swift"),
        encoding: .utf8
    )
    #expect(source.contains("package actor WaxSession"))

    let moduleDoc = try String(
        contentsOf: repoRoot.appendingPathComponent("Sources/Wax/Wax.docc/Documentation.md"),
        encoding: .utf8
    )
    #expect(!moduleDoc.contains("**``WaxSession``**"))
    #expect(!moduleDoc.contains("- ``WaxSession``"))

    for relativePath in waxSessionDocPaths {
        let doc = try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)

        #expect(doc.contains("package-only"))
        #expect(doc.contains("not public API"))
        #expect(!doc.contains("provides a unified interface for frame operations, search, and structured memory"))
        #expect(!doc.contains("let session = WaxSession("))
        #expect(!doc.contains("WaxSession(wax:"))
        #expect(!doc.contains("WaxSession.Config"))
        #expect(!doc.contains("``WaxSession/Config``"))
        #expect(!doc.contains("`WaxSession/Config`"))
    }
}

@Test
func sessionDocsDoNotAdvertiseNonexistentTextPutOverloads() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let source = try String(
        contentsOf: repoRoot.appendingPathComponent("Sources/Wax/WaxSession.swift"),
        encoding: .utf8
    )
    #expect(source.contains("package func put(\n        _ content: Data"))
    #expect(!source.contains("func put(text:"))
    #expect(!source.contains("func putBatch(\n        texts:"))

    for relativePath in waxSessionDocPaths {
        let doc = try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)

        #expect(!doc.contains("session.put(text:"))
        #expect(!doc.contains("timestamp: nowMs"))
        #expect(!doc.contains("embedding: vectorData"))
        #expect(!doc.contains("putBatch(\n    texts:"))
    }
}

@Test
func unifiedSearchDocsDoNotConstructPackageOnlySearchRequestAsPublicAPI() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let requestSource = try String(
        contentsOf: repoRoot.appendingPathComponent("Sources/Wax/UnifiedSearch/SearchRequest.swift"),
        encoding: .utf8
    )
    #expect(requestSource.contains("package struct SearchRequest"))
    #expect(requestSource.contains("package init("))

    let moduleDoc = try String(
        contentsOf: repoRoot.appendingPathComponent("Sources/Wax/Wax.docc/Documentation.md"),
        encoding: .utf8
    )
    #expect(!moduleDoc.contains("- ``SearchRequest``"))

    for relativePath in waxUnifiedSearchDocPaths {
        let doc = try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)

        #expect(doc.contains("package-only"))
        #expect(doc.contains("not public API"))
        #expect(!doc.contains("Configure searches with ``SearchRequest``"))
        #expect(!doc.contains("Configure searches with `SearchRequest`"))
        #expect(!doc.contains("let request = SearchRequest("))
        #expect(!doc.contains("var request = SearchRequest("))
        #expect(!doc.contains("session.search(request)"))
        #expect(!doc.contains("``SearchMode`` controls"))
        #expect(!doc.contains("`SearchMode` controls"))
        #expect(!doc.contains("``SearchResponse`` contains"))
        #expect(!doc.contains("`SearchResponse` contains"))
    }
}

private let waxSessionDocPaths = [
    "Sources/Wax/Wax.docc/Articles/SessionManagement.md",
    "Resources/website/docs/orchestrator/session-management.md",
]

private let waxUnifiedSearchDocPaths = [
    "Sources/Wax/Wax.docc/Articles/UnifiedSearch.md",
    "Resources/website/docs/orchestrator/unified-search.md",
]
