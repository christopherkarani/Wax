import Foundation
import Testing
import WaxCore

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
        "WaxStats": "Sources/WaxCore/Wax+Introspection.swift",
        "WaxWALStats": "Sources/WaxCore/Wax+Introspection.swift",
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
        "PendingEmbeddingSnapshot": "Sources/WaxCore/Wax+Writes.swift",
        "AsyncReadWriteLock": "Sources/WaxCore/Concurrency/ReadWriteLock.swift",
        "AsyncMutex": "Sources/WaxCore/Concurrency/AsyncMutex.swift",
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
        // The guard is "not public API": package or internal declarations both satisfy
        // it. Match the declaration with word boundaries so e.g. `WALRecord` does not
        // match `WALRecordHeader`, and reject any `public` declaration of the symbol.
        let anyDecl = try Regex(#"\b(?:package|public)?\s*(?:final\s+)?(?:actor|struct|enum|class|protocol)\s+"# + symbol + #"\b"#)
        let publicDecl = try Regex(#"\bpublic\s+(?:final\s+)?(?:actor|struct|enum|class|protocol)\s+"# + symbol + #"\b"#)
        #expect(source.contains(anyDecl), "\(symbol) declaration not found in \(relativePath)")
        #expect(!source.contains(publicDecl), "\(symbol) in \(relativePath) must not be public API")
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

@Test
func docsDoNotAdvertiseNonexistentFramePayloadMethods() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    // `Wax` is split across Wax.swift and its Wax+*.swift extensions; scan all of them.
    let coreDirectory = repoRoot.appendingPathComponent("Sources/WaxCore")
    let waxSourceNames = try FileManager.default.contentsOfDirectory(atPath: coreDirectory.path)
        .filter { $0 == "Wax.swift" || ($0.hasPrefix("Wax+") && $0.hasSuffix(".swift")) }
        .sorted()
    try #require(waxSourceNames.contains("Wax.swift"))
    let waxSource = try waxSourceNames.map {
        try String(contentsOf: coreDirectory.appendingPathComponent($0), encoding: .utf8)
    }.joined(separator: "\n")
    #expect(!waxSource.contains("func putFrame("))
    #expect(!waxSource.contains("func frame("))
    #expect(!waxSource.contains("func readPayload("))

    for relativePath in framePayloadMethodDocPaths {
        let doc = try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
        #expect(!doc.contains("Wax.putFrame()"))
        #expect(!doc.contains(".putFrame("))
        #expect(!doc.contains(".frame("))
        #expect(!doc.contains(".readPayload("))
        #expect(!doc.contains("readPayload("))
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

private let framePayloadMethodDocPaths = [
    "Sources/Wax/Wax.docc/Articles/Architecture.md",
    "Resources/website/docs/architecture.md",
    "Sources/WaxCore/WaxCore.docc/Articles/GettingStarted.md",
    "Resources/website/docs/core/getting-started.md",
]

// MARK: - Wax guarded state stays inside the Wax sources

/// `Wax`'s commit-path state and helpers are `internal` only because `Wax` is split across
/// `Wax.swift` and its `Wax+*.swift` extensions; they must only be used under `opLock`
/// from those files. Any other WaxCore file that reaches them bypasses the lock.
@Test
func waxGuardedStateIsReferencedOnlyFromWaxSources() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let coreDirectory = repoRoot.appendingPathComponent("Sources/WaxCore")
    let relativePaths = try #require(FileManager.default.subpaths(atPath: coreDirectory.path))
    let scannedPaths = relativePaths
        .filter { $0.hasSuffix(".swift") && !isWaxActorSource($0) }
        .sorted()
    try #require(!scannedPaths.isEmpty)
    // Proves the scan recursed into subdirectories rather than only the top level.
    try #require(scannedPaths.contains("WAL/WALRingReader.swift"))

    var violations: [String] = []
    for relativePath in scannedPaths {
        let source = try String(
            contentsOf: coreDirectory.appendingPathComponent(relativePath),
            encoding: .utf8
        )
        violations += try waxGuardedStateReferences(in: source, relativePath: relativePath)
    }
    #expect(violations.isEmpty, "Wax guarded state referenced outside Wax.swift/Wax+*.swift: \(violations)")
}

@Test
func waxGuardedStateScanFlagsReferencesOutsideWaxSources() throws {
    let flagged = [
        "let toc = await wax.toc",
        "let header = await self.store?.header",
        "let pending = await wax.pendingMutations",
        "let count = await wax.toc.frames.count",
        "await wax.clearPendingMutations()",
        "_ = try await wax.applyPendingMutationsIntoTOC(&copy)",
        "extension Wax {\n    func peek() -> Int { toc.frames.count }\n}",
    ]
    for source in flagged {
        #expect(try !waxGuardedStateReferences(in: source, relativePath: "Search/New.swift").isEmpty, "\(source)")
    }
    // The same receiver is allowed only in the file whose own type owns that property.
    #expect(try !waxGuardedStateReferences(
        in: "let n = scan.pendingMutations.count",
        relativePath: "Search/New.swift"
    ).isEmpty)

    let allowed = [
        "let header = try WALRecordHeader.decode(from: data, offset: 0)",
        "self.pendingMutations = pendingMutations",
        "// wax.toc is guarded by opLock",
        "throw WaxError.invalidToc(reason: \"wax.toc must be at least 32 bytes\")",
        "extension WaxTOC {\n    var toc: Int { 0 }\n}",
    ]
    for source in allowed {
        #expect(try waxGuardedStateReferences(in: source, relativePath: "Search/New.swift").isEmpty, "\(source)")
    }
    #expect(try waxGuardedStateReferences(
        in: "let n = scan.pendingMutations.count",
        relativePath: "WAL/PendingReplayPolicy.swift"
    ).isEmpty)
}

/// `Wax.swift` and the `Wax+*.swift` extensions at the top of `Sources/WaxCore`.
private func isWaxActorSource(_ relativePath: String) -> Bool {
    !relativePath.contains("/")
        && (relativePath == "Wax.swift" || (relativePath.hasPrefix("Wax+") && relativePath.hasSuffix(".swift")))
}

/// Wax members reachable only because of the file split, and which must stay under `opLock`.
private let waxGuardedMembers = ["toc", "header", "pendingMutations", "clearPendingMutations", "applyPendingMutationsIntoTOC"]

/// Member accesses that name a guarded member but belong to another type, keyed by file:
/// `WALPendingScanResult.pendingMutations` is read through these receivers.
private let nonWaxGuardedNameReceivers: [String: Set<String>] = [
    "WAL/WALRingReader.swift": [")"],
    "WAL/PendingReplayPolicy.swift": ["scan"],
]

/// Returns a description of every line in `source` that reaches a guarded `Wax` member:
/// any use of a guarded helper name, any member access `x.toc`/`x.header`/`x.pendingMutations`
/// whose receiver is not `self` or an allow-listed non-Wax value, and any bare use of a
/// guarded name inside a file that extends `Wax`. Comments and string literals are ignored.
private func waxGuardedStateReferences(in source: String, relativePath: String) throws -> [String] {
    let names = waxGuardedMembers.joined(separator: "|")
    // Simple (ASCII) word boundaries: the default Unicode boundaries treat `a.b` as one
    // word, so `\b` would not match inside member chains such as `toc.frames`.
    let helperUse = try Regex(#"\b(?:clearPendingMutations|applyPendingMutationsIntoTOC)\b"#)
        .wordBoundaryKind(.simple)
    let memberAccess = try Regex(#"([A-Za-z_][A-Za-z0-9_]*|\))\s*\??\s*\.\s*(?:"# + names + #")\b"#)
        .wordBoundaryKind(.simple)
    let bareUse = try Regex(#"\b(?:"# + names + #")\b"#).wordBoundaryKind(.simple)
    let extendsWax = try Regex(#"\bextension\s+Wax\b"#).wordBoundaryKind(.simple)
    let stringLiteral = try Regex(#""(?:[^"\\]|\\.)*""#)

    let lines = source.components(separatedBy: "\n").map { line -> String in
        var code = line.replacing(stringLiteral, with: "\"\"")
        if let comment = code.range(of: "//") {
            code = String(code[..<comment.lowerBound])
        }
        return code
    }
    let fileExtendsWax = lines.contains { $0.contains(extendsWax) }
    let allowedReceivers = nonWaxGuardedNameReceivers[relativePath, default: []].union(["self"])

    var violations: [String] = []
    for (index, code) in lines.enumerated() {
        let location = "\(relativePath):\(index + 1): \(code.trimmingCharacters(in: .whitespaces))"
        if code.contains(helperUse) || (fileExtendsWax && code.contains(bareUse)) {
            violations.append(location)
            continue
        }
        for match in code.matches(of: memberAccess) {
            let receiver = match.output[1].substring.map(String.init) ?? ""
            if !allowedReceivers.contains(receiver) {
                violations.append(location)
                break
            }
        }
    }
    return violations
}
