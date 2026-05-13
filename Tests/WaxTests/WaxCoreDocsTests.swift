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

@Test
func waxCoreDocCTopicsDoNotLinkPackageOnlySymbols() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let packageOnlySymbols = [
        "Wax": "Sources/WaxCore/Wax.swift",
        "WaxOptions": "Sources/WaxCore/WaxOptions.swift",
        "WaxStats": "Sources/WaxCore/Wax.swift",
        "WaxWALStats": "Sources/WaxCore/Wax.swift",
        "WaxHeaderPage": "Sources/WaxCore/FileFormat/WaxHeaderPage.swift",
        "WaxFooter": "Sources/WaxCore/FileFormat/WaxFooter.swift",
        "WaxTOC": "Sources/WaxCore/FileFormat/WaxTOC.swift",
        "FrameMeta": "Sources/WaxCore/FileFormat/FrameMeta.swift",
        "FrameRole": "Sources/WaxCore/FileFormat/WaxEnums.swift",
        "FrameStatus": "Sources/WaxCore/FileFormat/WaxEnums.swift",
        "CanonicalEncoding": "Sources/WaxCore/FileFormat/WaxEnums.swift",
        "WALRecord": "Sources/WaxCore/WAL/WALRecord.swift",
        "WALEntry": "Sources/WaxCore/WAL/PendingMutation.swift",
        "WALFsyncPolicy": "Sources/WaxCore/WAL/WALRingWriter.swift",
        "WALRingWriter": "Sources/WaxCore/WAL/WALRingWriter.swift",
        "WALRingReader": "Sources/WaxCore/WAL/WALRingReader.swift",
        "BinaryEncoder": "Sources/WaxCore/BinaryCodec/BinaryEncoder.swift",
        "BinaryDecoder": "Sources/WaxCore/BinaryCodec/BinaryDecoder.swift",
        "BinaryEncodable": "Sources/WaxCore/BinaryCodec/BinaryEncodable.swift",
        "BinaryDecodable": "Sources/WaxCore/BinaryCodec/BinaryEncodable.swift",
        "EntityKey": "Sources/WaxCore/StructuredMemory/EntityKey.swift",
        "PredicateKey": "Sources/WaxCore/StructuredMemory/PredicateKey.swift",
        "FactValue": "Sources/WaxCore/StructuredMemory/FactValue.swift",
        "StructuredFact": "Sources/WaxCore/StructuredMemory/StructuredFacts.swift",
        "StructuredFactHit": "Sources/WaxCore/StructuredMemory/StructuredFacts.swift",
        "StructuredFactsResult": "Sources/WaxCore/StructuredMemory/StructuredFacts.swift",
        "StructuredEvidence": "Sources/WaxCore/StructuredMemory/StructuredEvidence.swift",
        "StructuredMemoryQueryContext": "Sources/WaxCore/StructuredMemory/StructuredMemoryQueryContext.swift",
        "StructuredMemoryAsOf": "Sources/WaxCore/StructuredMemory/StructuredMemoryAsOf.swift",
        "PutFrame": "Sources/WaxCore/WAL/PendingMutation.swift",
        "DeleteFrame": "Sources/WaxCore/WAL/PendingMutation.swift",
        "SupersedeFrame": "Sources/WaxCore/WAL/PendingMutation.swift",
        "PutEmbedding": "Sources/WaxCore/WAL/PendingMutation.swift",
        "PendingEmbeddingSnapshot": "Sources/WaxCore/Wax.swift",
        "AsyncReadWriteLock": "Sources/WaxCore/Concurrency/ReadWriteLock.swift",
        "AsyncMutex": "Sources/WaxCore/Concurrency/AsyncMutex.swift",
        "ReadWriteLock": "Sources/WaxCore/Concurrency/ReadWriteLock.swift",
        "UnfairLock": "Sources/WaxCore/Concurrency/ReadWriteLock.swift",
        "FileLock": "Sources/WaxCore/IO/FileLock.swift",
        "BlockingIOExecutor": "Sources/WaxCore/IO/BlockingIOExecutor.swift",
        "WaxWriterPolicy": "Sources/WaxCore/WaxWriterPolicy.swift",
        "FDFile": "Sources/WaxCore/IO/FDFile.swift",
    ]

    for (symbol, relativePath) in packageOnlySymbols {
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
        #expect(source.contains("package actor \(symbol)")
            || source.contains("package struct \(symbol)")
            || source.contains("package enum \(symbol)")
            || source.contains("package final class \(symbol)")
            || source.contains("package protocol \(symbol)"))
    }

    let doc = try String(
        contentsOf: repoRoot.appendingPathComponent("Sources/WaxCore/WaxCore.docc/Documentation.md"),
        encoding: .utf8
    )
    let topics = try #require(doc.components(separatedBy: "## Topics").last)

    for symbol in packageOnlySymbols.keys {
        #expect(!topics.contains("- ``\(symbol)``"))
    }

    #expect(topics.contains("- ``WaxError``"))
}

@Test
func waxCoreStructuredMemoryDocsDoNotAdvertisePackageOnlyTypesAsPublicAPI() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let packageOnlySources = [
        "Sources/WaxCore/StructuredMemory/EntityKey.swift",
        "Sources/WaxCore/StructuredMemory/PredicateKey.swift",
        "Sources/WaxCore/StructuredMemory/FactValue.swift",
        "Sources/WaxCore/StructuredMemory/StructuredEvidence.swift",
        "Sources/WaxCore/StructuredMemory/StructuredMemoryAsOf.swift",
        "Sources/WaxCore/StructuredMemory/StructuredTimeRange.swift",
        "Sources/WaxTextSearch/FTS5SearchEngine.swift",
    ]

    for relativePath in packageOnlySources {
        let source = try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
        #expect(source.contains("package struct")
            || source.contains("package enum")
            || source.contains("package actor"))
    }

    for relativePath in waxCoreStructuredMemoryDocPaths {
        let doc = try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)

        #expect(doc.contains("package-only"))
        #expect(doc.contains("not public API"))
        #expect(!doc.contains("``EntityKey``"))
        #expect(!doc.contains("`EntityKey`"))
        #expect(!doc.contains("EntityKey("))
        #expect(!doc.contains("``PredicateKey``"))
        #expect(!doc.contains("`PredicateKey`"))
        #expect(!doc.contains("PredicateKey("))
        #expect(!doc.contains("``FactValue``"))
        #expect(!doc.contains("`FactValue`"))
        #expect(!doc.contains("``StructuredTimeRange``"))
        #expect(!doc.contains("`StructuredTimeRange`"))
        #expect(!doc.contains("``StructuredMemoryAsOf``"))
        #expect(!doc.contains("`StructuredMemoryAsOf`"))
        #expect(!doc.contains("``StructuredEvidence``"))
        #expect(!doc.contains("`StructuredEvidence`"))
        #expect(!doc.contains("StructuredEvidence("))
        #expect(!doc.contains("``FactRowID``"))
        #expect(!doc.contains("`FactRowID`"))
        #expect(!doc.contains("engine.retractFact"))
        #expect(!doc.contains("FTS5SearchEngine"))
    }
}

private let waxCoreDocPaths = [
    "Sources/WaxCore/WaxCore.docc/Documentation.md",
    "Sources/WaxCore/WaxCore.docc/Articles/GettingStarted.md",
    "Sources/WaxCore/WaxCore.docc/Articles/ConcurrencyModel.md",
    "Resources/website/docs/core/getting-started.md",
    "Resources/website/docs/core/concurrency-model.md",
]

private let waxCoreStructuredMemoryDocPaths = [
    "Sources/WaxCore/WaxCore.docc/Articles/StructuredMemory.md",
    "Resources/website/docs/core/structured-memory.md",
]
