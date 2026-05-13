import Foundation
import Testing

@Test
func waxCoreDocsDoNotAdvertisePackageOnlyWaxActorAsPublicAPI() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let source = try String(
        contentsOf: repoRoot.appendingPathComponent("Sources/WaxCore/Wax.swift"),
        encoding: .utf8
    )
    #expect(source.contains("package actor Wax"))

    for relativePath in waxCoreDocPaths {
        let doc = try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)

        #expect(doc.contains("package-only"))
        #expect(doc.contains("not public API"))
        #expect(!doc.contains("Create, open, and interact with `.wax` memory files using the Wax actor."))
        #expect(!doc.contains("The primary entry point is the ``Wax`` actor"))
        #expect(!doc.contains("The primary entry point is the `Wax` actor"))
        #expect(!doc.contains("managed by the ``Wax`` actor"))
        #expect(!doc.contains("managed by the `Wax` actor"))
        #expect(!doc.contains("Wax.create("))
        #expect(!doc.contains("Wax.open("))
        #expect(!doc.contains("store.acquireWriterLease"))
        #expect(!doc.contains("store.putFrame"))
        #expect(!doc.contains("store.commit"))
        #expect(!doc.contains("store.releaseWriterLease"))
        #expect(!doc.contains("store.readPayload"))
        #expect(!doc.contains("store.close"))
    }
}

private let waxCoreDocPaths = [
    "Sources/WaxCore/WaxCore.docc/Documentation.md",
    "Sources/WaxCore/WaxCore.docc/Articles/GettingStarted.md",
    "Sources/WaxCore/WaxCore.docc/Articles/ConcurrencyModel.md",
    "Resources/website/docs/core/getting-started.md",
    "Resources/website/docs/core/concurrency-model.md",
]
