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
        // Parenthesized, optional, subscripted and closure-argument receivers.
        "let toc = (await wax).toc",
        "let toc = wax!.toc",
        "let toc = stores[0].toc",
        "let tocs = stores.map { $0.toc }",
        // Member chains split across lines.
        "let toc = wax\n    .toc",
        "let count = await wax?\n    .pendingMutations.count",
        // The WAL writer, the staged vector index and the `*Locked`/`*Unlocked` helpers.
        "let wal = await wax.wal",
        "let staged = await wax.stagedVecIndex",
        "try await wax.commitLocked()",
        "let metas = await wax.frameMetasIncludingPendingUnlocked(frameIds: ids)",
        "extension Wax {\n    func size() -> UInt64 { wal.writePos }\n}",
        "extension Wax {\n    func flush() async throws { try await commitLocked() }\n}",
        "extension Wax {\n    func dims() -> Int? { stagedVecIndex?.dimension }\n}",
        // Code inside string interpolation, after a raw string, and key paths.
        "log(\"n \\(await wax.pendingMutations.count)\")",
        "let p = #\"\\\"#; let t = wax.toc; print(\"x\")",
        "let tocs = stores.map(\\.toc)",
        "let s = #\"\\#(wax.toc)\"#",
        "let s = \"\"\"\n    \\(wax.toc)\n    \"\"\"",
        "log(\"\\(label(\")\")) \\(wax.toc)\")",
        "/* a /* b */ c */ let t = wax.toc",
        // A `"` inside a regex literal opens no string, and an unterminated single-line string
        // ends at its line. CRLF line endings end `//` comments.
        "let r = /a\"b/; let t = wax.toc",
        "let r = #/a\"b/#; let t = wax.toc",
        "let r = ##/a\"b/##; let t = wax.toc",
        "let r = /a\"b/\nlet t = wax.toc",
        "let s = \"unterminated\nlet t = wax.toc",
        "// note\r\nlet t = wax.toc",
    ]
    for source in flagged {
        #expect(try !waxGuardedStateReferences(in: source, relativePath: "Search/New.swift").isEmpty, "\(source)")
    }
    // A multi-line chain is reported on the line that names the member.
    #expect(try waxGuardedStateReferences(in: "let toc = wax\n    .toc", relativePath: "Search/New.swift")
        == ["Search/New.swift:2: .toc"])
    // Comments and multi-line strings keep their newlines, so later line numbers do not move.
    #expect(try waxGuardedStateReferences(
        in: "/* a\n b */ let s = \"\"\"\n    text\n    \"\"\"\nlet toc = wax.toc",
        relativePath: "Search/New.swift"
    ) == ["Search/New.swift:5: let toc = wax.toc"])
    #expect(try waxGuardedStateReferences(
        in: "// a\r\n/* b\r\n */\r\nlet toc = wax.toc\r\n",
        relativePath: "Search/New.swift"
    ) == ["Search/New.swift:4: let toc = wax.toc"])
    // The file-scoped allow-list names the call whose result is read, not any `)` receiver.
    #expect(try !waxGuardedStateReferences(
        in: "let toc = (await wax).toc",
        relativePath: "WAL/WALRingReader.swift"
    ).isEmpty)
    #expect(try !waxGuardedStateReferences(
        in: "let pending = try await wax.pendingSnapshot().pendingMutations",
        relativePath: "WAL/WALRingReader.swift"
    ).isEmpty)
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
        "let size = options.walSize",
        "private var isLocked = false",
        "if !self.isLocked { isLocked = true }",
        "let held = await mutex.isLocked",
        "let s = \"\"\"\n    wax.toc\n    \"\"\"",
        "let s = #\"wax.toc \\(wax.toc)\"#",
        "/* outer /* inner */ wax.toc */",
        "let url = \"https://example.com\"; let n = 1",
        "let r = /wax.toc/",
        "let r = #/wax.toc/#",
        "let ratio = a / b / c; let s = \"wax.toc\"",
        "let n = (a)/b/c; let s = \"wax.toc\"",
    ]
    for source in allowed {
        #expect(try waxGuardedStateReferences(in: source, relativePath: "Search/New.swift").isEmpty, "\(source)")
    }
    #expect(try waxGuardedStateReferences(
        in: "let n = scan.pendingMutations.count",
        relativePath: "WAL/PendingReplayPolicy.swift"
    ).isEmpty)
    #expect(try waxGuardedStateReferences(
        in: "try scanPendingMutationsWithState(from: position, committedSeq: seq).pendingMutations",
        relativePath: "WAL/WALRingReader.swift"
    ).isEmpty)
    #expect(try waxGuardedStateReferences(
        in: "try scanPendingMutationsWithState(from: position, committedSeq: seq)\n    .pendingMutations",
        relativePath: "WAL/WALRingReader.swift"
    ).isEmpty)
}

/// `Wax.swift` and the `Wax+*.swift` extensions at the top of `Sources/WaxCore`.
private func isWaxActorSource(_ relativePath: String) -> Bool {
    !relativePath.contains("/")
        && (relativePath == "Wax.swift" || (relativePath.hasPrefix("Wax+") && relativePath.hasSuffix(".swift")))
}

/// Wax members reachable only because of the file split, and which must stay under `opLock`:
/// the named state and helpers, plus every `*Locked` / `*Unlocked` helper (they assume the
/// caller already holds `opLock`). `is…` names such as `AsyncMutex.isLocked` are state queries,
/// not helpers, so they are excluded.
private let waxGuardedMemberPattern: String = #"(?:toc|header|wal|pendingMutations|stagedVecIndex|"#
    + #"clearPendingMutations|applyPendingMutationsIntoTOC|"#
    + #"(?!is[A-Z])[A-Za-z_][A-Za-z0-9_]*(?:Locked|Unlocked))"#

/// Member accesses that name a guarded member but belong to another type, keyed by file.
/// `WALPendingScanResult.pendingMutations` is read through these receivers. A call result is
/// spelled `name()`, so only that call's result is allowed, not every parenthesized receiver.
private let nonWaxGuardedNameReceivers: [String: Set<String>] = [
    "WAL/WALRingReader.swift": ["scanPendingMutationsWithState()"],
    "WAL/PendingReplayPolicy.swift": ["scan"],
]

/// Returns a description of every line in `source` that reaches a guarded `Wax` member:
/// any use of a guarded helper name, any member access `x.toc` / `x.wal` / `x.commitLocked()`
/// (also when split across lines) whose receiver is not `self` or an allow-listed non-Wax
/// value, and any bare use of a guarded name inside a file that extends `Wax`. Comments and
/// string literal text are ignored; code inside string interpolation is scanned.
private func waxGuardedStateReferences(in source: String, relativePath: String) throws -> [String] {
    // Simple (ASCII) word boundaries: the default Unicode boundaries treat `a.b` as one
    // word, so `\b` would not match inside member chains such as `toc.frames`.
    let helperUse = try Regex(#"\b(?:clearPendingMutations|applyPendingMutationsIntoTOC)\b"#)
        .wordBoundaryKind(.simple)
    // The receiver is an identifier, `$0`, the closing `)` / `]` of a call, parenthesized
    // expression or subscript, or the `\` of a key path. `\s` also matches newlines, so
    // `wax\n    .toc` is one access.
    let memberAccess = try Regex(
        #"([A-Za-z_][A-Za-z0-9_]*|\$[0-9]+|[)\]]|\\)\s*[?!]?\s*\.\s*"# + waxGuardedMemberPattern + #"\b"#
    ).wordBoundaryKind(.simple)
    let bareUse = try Regex(#"\b"# + waxGuardedMemberPattern + #"\b"#).wordBoundaryKind(.simple)
    let extendsWax = try Regex(#"\bextension\s+Wax\b"#).wordBoundaryKind(.simple)

    let code = swiftCodeOnly(source)
    let lines = code.components(separatedBy: "\n")
    let fileExtendsWax = code.contains(extendsWax)
    let allowedReceivers = nonWaxGuardedNameReceivers[relativePath, default: []].union(["self"])

    var flaggedLines = Set<Int>()
    for (index, line) in lines.enumerated()
    where line.contains(helperUse) || (fileExtendsWax && line.contains(bareUse)) {
        flaggedLines.insert(index)
    }
    for match in code.matches(of: memberAccess) {
        let receiverRange = try #require(match.output[1].range)
        if !allowedReceivers.contains(receiverName(in: code, endingAt: receiverRange)) {
            // Report the line that names the member: the last line of the match.
            flaggedLines.insert(code[..<match.range.upperBound].filter { $0 == "\n" }.count)
        }
    }
    return flaggedLines.sorted().map { index in
        "\(relativePath):\(index + 1): \(lines[index].trimmingCharacters(in: .whitespaces))"
    }
}

/// The receiver as the allow-list spells it: the identifier itself or, for a closing `)` / `]`,
/// the identifier directly before its matching opener followed by `()` / `[]`. So
/// `scan(from: x).pendingMutations` has receiver `scan()` and `(await wax).toc` has `()`.
private func receiverName(in code: String, endingAt range: Range<String.Index>) -> String {
    let token = code[range]
    guard let close = token.first, close == ")" || close == "]" else { return String(token) }
    let open: Character = close == ")" ? "(" : "["
    var depth = 0
    var index = range.lowerBound
    while true {
        if code[index] == close {
            depth += 1
        } else if code[index] == open {
            depth -= 1
            if depth == 0 { break }
        }
        guard index > code.startIndex else { return "\(open)\(close)" }
        index = code.index(before: index)
    }
    var start = index
    while start > code.startIndex {
        let previous = code.index(before: start)
        guard code[previous].isLetter || code[previous].isNumber || code[previous] == "_" else { break }
        start = previous
    }
    return "\(code[start..<index])\(open)\(close)"
}

/// `source` with comments and the text of string and regex literals removed. Every line break
/// is kept as `\n` (CRLF included), so line numbers do not move, and the code inside `\(…)`
/// interpolations is kept so it is scanned too. Handles `//` and nested `/* */` comments,
/// `"…"` and `"""…"""` strings, raw strings with any number of `#` (whose interpolation is
/// spelled `\#(…)`), `#/…/#` regex literals, and bare `/…/` regex literals in expression
/// position. An unterminated single-line string or bare regex ends at its line.
private func swiftCodeOnly(_ source: String) -> String {
    var lexer = SwiftCodeLexer(source: Array(source))
    lexer.copyCode(insideInterpolation: false)
    return lexer.output
}

private struct SwiftCodeLexer {
    let source: [Character]
    var index = 0
    var output = ""

    init(source: [Character]) {
        self.source = source
    }

    private func hasPrefix(_ text: String) -> Bool {
        var position = index
        for character in text {
            guard position < source.count, source[position] == character else { return false }
            position += 1
        }
        return true
    }

    /// Copies code to `output`. Inside an interpolation it stops after the `)` that closes it.
    mutating func copyCode(insideInterpolation: Bool) {
        var depth = 0
        while index < source.count {
            if hasPrefix("//") {
                while index < source.count, !source[index].isNewline { index += 1 }
            } else if hasPrefix("/*") {
                skipBlockComment()
            } else if let hashes = openingHashes(before: "\"") {
                skipString(hashes: hashes)
            } else if let hashes = openingHashes(before: "/"), hashes > 0 {
                skipExtendedRegex(hashes: hashes)
            } else if let end = bareRegexEnd() {
                index = end
                output.append("\"\"")
            } else {
                let character = source[index]
                index += 1
                if insideInterpolation, character == "(" {
                    depth += 1
                } else if insideInterpolation, character == ")" {
                    if depth == 0 { return }
                    depth -= 1
                }
                output.append(character.isNewline ? "\n" : character)
            }
        }
    }

    /// The number of `#` before `delimiter` at `index`, or nil when `delimiter` does not follow.
    private func openingHashes(before delimiter: Character) -> Int? {
        var position = index
        while position < source.count, source[position] == "#" { position += 1 }
        guard position < source.count, source[position] == delimiter else { return nil }
        return position - index
    }

    private mutating func skipBlockComment() {
        var depth = 0
        while index < source.count {
            if hasPrefix("/*") {
                depth += 1
                index += 2
            } else if hasPrefix("*/") {
                depth -= 1
                index += 2
                if depth == 0 { return }
            } else {
                if source[index].isNewline { output.append("\n") }
                index += 1
            }
        }
    }

    /// Skips a string opened at `index` by `hashes` `#` and `"` or `"""`, writing `""` for it
    /// plus its line breaks and the code of each interpolation.
    private mutating func skipString(hashes: Int) {
        let delimiter = String(repeating: "#", count: hashes)
        index += hashes
        let multiline = hasPrefix("\"\"\"")
        let quote = multiline ? "\"\"\"" : "\""
        index += quote.count
        let terminator = quote + delimiter
        let escape = "\\" + delimiter
        output.append("\"")
        while index < source.count {
            // A single-line string cannot span lines; stop there if it is unterminated.
            if !multiline, source[index].isNewline { break }
            if hasPrefix(terminator) {
                index += terminator.count
                break
            }
            if hasPrefix(escape) {
                index += escape.count
                guard index < source.count else { break }
                if source[index] == "(" {
                    index += 1
                    output.append("(")
                    copyCode(insideInterpolation: true)
                    output.append(")")
                    continue
                }
                // A line continuation: the line break is handled at the top of the loop.
                if source[index].isNewline { continue }
            }
            if source[index].isNewline { output.append("\n") }
            index += 1
        }
        output.append("\"")
    }

    /// Skips a `#/…/#` regex literal opened at `index` by `hashes` `#`, writing `""` for it
    /// plus its line breaks.
    private mutating func skipExtendedRegex(hashes: Int) {
        let terminator = "/" + String(repeating: "#", count: hashes)
        index += hashes + 1
        while index < source.count, !hasPrefix(terminator) {
            if source[index].isNewline { output.append("\n") }
            index += 1
        }
        index = min(index + terminator.count, source.count)
        output.append("\"\"")
    }

    /// The index just past a bare `/…/` regex literal at `index`, or nil. Swift parses one only
    /// in expression position and never with whitespace after the opening `/`. To stay
    /// conservative it must follow `(`, `[`, `{`, `,`, `=`, `:`, `;`, `!`, `&`, `|` or `?` (or
    /// open the file) and close on the same line; anything else is a division operator.
    private func bareRegexEnd() -> Int? {
        guard source[index] == "/", index + 1 < source.count, !source[index + 1].isWhitespace else {
            return nil
        }
        if let previous = output.last(where: { !$0.isWhitespace }), !"([{,=:;!&|?".contains(previous) {
            return nil
        }
        var position = index + 1
        while position < source.count, !source[position].isNewline {
            if source[position] == "/" { return position + 1 }
            // `\/` does not close the literal; a `\` before a line break does not continue it.
            if source[position] == "\\", position + 1 < source.count, !source[position + 1].isNewline {
                position += 1
            }
            position += 1
        }
        return nil
    }
}
