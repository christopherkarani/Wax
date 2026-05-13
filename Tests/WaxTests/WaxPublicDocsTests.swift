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

private let waxSessionDocPaths = [
    "Sources/Wax/Wax.docc/Articles/SessionManagement.md",
    "Resources/website/docs/orchestrator/session-management.md",
]
