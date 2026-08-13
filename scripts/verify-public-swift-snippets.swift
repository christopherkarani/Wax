#!/usr/bin/env swift
import Foundation

/// Extracts fenced `swift` blocks that carry a `compile` marker from README.md,
/// Wax DocC articles, `Resources/skills/public/wax/SKILL.md`, and public skill
/// templates. Materializes each snippet into a nested SwiftPM consumer package
/// and compiles it with Swift 6.2 strict concurrency.
///
/// Compile marker convention (info-string tokens after the language):
///   ```swift compile
///       Typecheck this fence in the default-trait consumer AND the traits-off
///       consumer (`traits: []`).
///   ```swift compile trait:MiniLMEmbeddings
///       Typecheck only in the default-trait consumer. Excluded from traits-off.
///       Replace MiniLMEmbeddings with any Wax package trait name as needed.
///
/// Every fence whose info string mentions `compile` MUST be extracted. An
/// unclosed fence, a parse anomaly, a swallowed marked fence, or a malformed
/// marker (`compile=true`, `{compile}`, `Swift compile`) fails the run.
/// Closing fences match the same or greater tick length at column 0; an inner
/// ``` in a comment or string does not close the block.
///
/// Foundation Models snippets that wrap API calls in `#if canImport(FoundationModels)`
/// are reported as SKIP (not PASS) when that import is false on the host.
///
/// Documented fixture tokens (replaced before compile, nowhere else):
///   __WAX_STORE_URL__  -> URL(fileURLWithPath: "/tmp/wax-docs-fixture.wax")
///   __WAX_PHOTO_URL__  -> URL(fileURLWithPath: "/tmp/wax-docs-fixture.png")
///   __WAX_VIDEO_URL__  -> URL(fileURLWithPath: "/tmp/wax-docs-fixture.mp4")
///
/// Declaration-only snippets get a sibling Harness.swift `@main` so they can live
/// in an executable target. Snippets that already contain `@main` or top-level
/// statements are written verbatim as main.swift.
///
/// Flags:
///   --self-test              Run parser negative/positive fixtures and exit
///   --markdown-root PATH     Collect markdown from PATH instead of the repo docs

struct Snippet: Sendable {
    var sourcePath: String
    var index: Int
    var infoString: String
    var code: String
    var requiredTrait: String?
}

struct VerifierError: Error, CustomStringConvertible {
    var message: String
    var description: String { message }
}

#if canImport(FoundationModels)
let hostHasFoundationModels = true
#else
let hostHasFoundationModels = false
#endif

let fileManager = FileManager.default
let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let scriptsDir = scriptURL.deletingLastPathComponent()
let repoRoot = scriptsDir.deletingLastPathComponent()

let fixtureReplacements: [(String, String)] = [
    ("__WAX_STORE_URL__", #"URL(fileURLWithPath: "/tmp/wax-docs-fixture.wax")"#),
    ("__WAX_PHOTO_URL__", #"URL(fileURLWithPath: "/tmp/wax-docs-fixture.png")"#),
    ("__WAX_VIDEO_URL__", #"URL(fileURLWithPath: "/tmp/wax-docs-fixture.mp4")"#),
]

func fail(_ message: String) -> Never {
    fputs("error: \(message)\n", stderr)
    exit(1)
}

func relativePath(_ url: URL) -> String {
    let root = repoRoot.path.hasSuffix("/") ? repoRoot.path : repoRoot.path + "/"
    let path = url.path
    if path.hasPrefix(root) {
        return String(path.dropFirst(root.count))
    }
    return path
}

struct Options {
    var selfTest = false
    var markdownRoot: URL?
}

func parseOptions() -> Options {
    var options = Options()
    let args = Array(CommandLine.arguments.dropFirst())
    var index = 0
    while index < args.count {
        let arg = args[index]
        if arg == "--self-test" {
            options.selfTest = true
        } else if arg == "--markdown-root" {
            index += 1
            guard index < args.count else { fail("--markdown-root requires a path") }
            options.markdownRoot = URL(fileURLWithPath: args[index]).standardizedFileURL
        } else if arg.hasPrefix("--markdown-root=") {
            let path = String(arg.dropFirst("--markdown-root=".count))
            options.markdownRoot = URL(fileURLWithPath: path).standardizedFileURL
        } else {
            fail("unknown argument: \(arg)")
        }
        index += 1
    }
    return options
}

func collectMarkdownFiles(markdownRoot: URL?) -> [URL] {
    if let override = markdownRoot {
        var files: [URL] = []
        let enumerator = fileManager.enumerator(
            at: override,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension.lowercased() == "md" {
                files.append(url)
            }
        }
        if files.isEmpty {
            fail("no markdown files under \(override.path)")
        }
        return files.sorted { $0.path < $1.path }
    }

    var files: [URL] = [
        repoRoot.appendingPathComponent("README.md"),
        repoRoot.appendingPathComponent("Resources/skills/public/wax/SKILL.md"),
    ]
    let doccRoot = repoRoot.appendingPathComponent("Sources/Wax/Wax.docc")
    let enumerator = fileManager.enumerator(
        at: doccRoot,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    )
    while let url = enumerator?.nextObject() as? URL {
        if url.pathExtension.lowercased() == "md" {
            files.append(url)
        }
    }
    let templatesRoot = repoRoot.appendingPathComponent("Resources/skills/public/wax/templates")
    let templateEnumerator = fileManager.enumerator(
        at: templatesRoot,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    )
    while let url = templateEnumerator?.nextObject() as? URL {
        if url.pathExtension.lowercased() == "md" {
            files.append(url)
        }
    }
    return files.sorted { $0.path < $1.path }
}

func parseOpeningFence(_ line: String) -> (tickCount: Int, infoString: String)? {
    var index = line.startIndex
    while index < line.endIndex && (line[index] == " " || line[index] == "\t") {
        index = line.index(after: index)
    }
    guard index < line.endIndex, line[index] == "`" else { return nil }
    var ticks = 0
    var cursor = index
    while cursor < line.endIndex && line[cursor] == "`" {
        ticks += 1
        cursor = line.index(after: cursor)
    }
    guard ticks >= 3 else { return nil }
    let info = String(line[cursor...]).trimmingCharacters(in: .whitespacesAndNewlines)
    return (ticks, info)
}

/// Closing fence: same or greater tick length, backticks at column 0, no info string.
func parseClosingFence(_ line: String) -> Int? {
    guard line.first == "`" else { return nil }
    var ticks = 0
    var cursor = line.startIndex
    while cursor < line.endIndex && line[cursor] == "`" {
        ticks += 1
        cursor = line.index(after: cursor)
    }
    guard ticks >= 3 else { return nil }
    let rest = line[cursor...].trimmingCharacters(in: .whitespacesAndNewlines)
    guard rest.isEmpty else { return nil }
    return ticks
}

func infoTokens(_ infoString: String) -> [String] {
    infoString.split(whereSeparator: { $0.isWhitespace }).map(String.init)
}

func shouldExtract(infoString: String) -> Bool {
    let tokens = infoTokens(infoString)
    return tokens.first == "swift" && tokens.contains("compile")
}

func mentionsCompile(_ infoString: String) -> Bool {
    infoTokens(infoString).contains { token in
        token.lowercased().contains("compile")
    }
}

func requiredTrait(infoString: String) -> String? {
    for token in infoTokens(infoString) {
        if token.hasPrefix("trait:") {
            let name = String(token.dropFirst("trait:".count))
            if !name.isEmpty { return name }
        }
    }
    return nil
}

func isFoundationModelsGated(_ snippet: Snippet) -> Bool {
    snippet.code.contains("canImport(FoundationModels)")
}

func extractSnippets(from text: String, sourcePath: String) throws -> [Snippet] {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    var snippets: [Snippet] = []
    var index = 0
    var snippetIndex = 0
    while index < lines.count {
        let line = String(lines[index])
        guard let opening = parseOpeningFence(line) else {
            index += 1
            continue
        }
        var bodyLines: [String] = []
        var cursor = index + 1
        var closed = false
        while cursor < lines.count {
            let candidate = String(lines[cursor])
            if let closingTicks = parseClosingFence(candidate), closingTicks >= opening.tickCount {
                closed = true
                break
            }
            if let inner = parseOpeningFence(candidate), mentionsCompile(inner.infoString) {
                throw VerifierError(
                    message: "compile-marked fence at \(sourcePath):\(cursor + 1) was swallowed by an earlier unclosed fence (opened at line \(index + 1))"
                )
            }
            bodyLines.append(candidate)
            cursor += 1
        }
        if !closed {
            throw VerifierError(
                message: "unclosed fenced code block in \(sourcePath) (opening ```\(opening.infoString) at line \(index + 1))"
            )
        }
        if shouldExtract(infoString: opening.infoString) {
            snippetIndex += 1
            let body = bodyLines.joined(separator: "\n")
            snippets.append(
                Snippet(
                    sourcePath: sourcePath,
                    index: snippetIndex,
                    infoString: opening.infoString,
                    code: applyFixtures(body),
                    requiredTrait: requiredTrait(infoString: opening.infoString)
                )
            )
        } else if mentionsCompile(opening.infoString) {
            throw VerifierError(
                message: "compile-marked fence was not extracted in \(sourcePath):\(index + 1) (info string: '\(opening.infoString)')"
            )
        }
        index = cursor + 1
    }
    return snippets
}

func extractSnippets(from url: URL) throws -> [Snippet] {
    let text = try String(contentsOf: url, encoding: .utf8)
    return try extractSnippets(from: text, sourcePath: relativePath(url))
}

func applyFixtures(_ code: String) -> String {
    var result = code
    for (token, replacement) in fixtureReplacements {
        result = result.replacingOccurrences(of: token, with: replacement)
    }
    return result
}

func isDeclarationOnly(_ code: String) -> Bool {
    if code.contains("@main") { return false }
    let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { line in
            guard !line.isEmpty else { return false }
            return !line.hasPrefix("//") && !line.hasPrefix("/*") && !line.hasPrefix("*")
        }
    let statementPrefixes = ["try ", "try? ", "try! ", "print(", "precondition(", "#expect("]
    for line in lines {
        if line.hasPrefix("import ") || line.hasPrefix("#if") || line.hasPrefix("#else")
            || line.hasPrefix("#endif") || line.hasPrefix("#available")
        {
            continue
        }
        if statementPrefixes.contains(where: { line.hasPrefix($0) }) {
            return false
        }
        if line.hasPrefix("let ") || line.hasPrefix("var ") {
            return false
        }
    }
    return true
}

func writeSnippet(_ snippet: Snippet, to directory: URL) throws {
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let code = snippet.code.hasSuffix("\n") ? snippet.code : snippet.code + "\n"
    if isDeclarationOnly(code) {
        try code.write(
            to: directory.appendingPathComponent("Snippet.swift"),
            atomically: true,
            encoding: .utf8
        )
        let harness = """
        @main
        enum __WaxSnippetHarness {
            static func main() async {}
        }
        """
        try harness.write(
            to: directory.appendingPathComponent("Harness.swift"),
            atomically: true,
            encoding: .utf8
        )
    } else {
        try code.write(
            to: directory.appendingPathComponent("main.swift"),
            atomically: true,
            encoding: .utf8
        )
    }
}

func swiftIdentifier(_ raw: String) -> String {
    let mapped = raw.map { character -> Character in
        character.isLetter || character.isNumber ? character : "_"
    }
    var value = String(mapped)
    if value.first?.isNumber == true {
        value = "S" + value
    }
    if value.isEmpty { value = "Snippet" }
    return value
}

func materializeConsumer(at fixtureRoot: URL, snippets: [Snippet], traitsClause: String) throws {
    var targetDecls: [String] = []
    for (offset, snippet) in snippets.enumerated() {
        let name = "Snippet\(String(format: "%03d", offset + 1))_\(swiftIdentifier(snippet.sourcePath))_\(snippet.index)"
        let dir = fixtureRoot.appendingPathComponent("Sources/\(name)", isDirectory: true)
        try writeSnippet(snippet, to: dir)
        targetDecls.append(
            """
                    .executableTarget(
                        name: "\(name)",
                        dependencies: [.product(name: "Wax", package: "Wax")],
                        swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
                    )
            """
        )
    }
    let waxPath = repoRoot.path
    let manifest = """
    // swift-tools-version: 6.2
    import PackageDescription

    let package = Package(
        name: "WaxPublicSnippetConsumer",
        platforms: [.iOS(.v17), .macOS(.v14)],
        dependencies: [.package(name: "Wax", path: "\(waxPath)"\(traitsClause))],
        targets: [
    \(targetDecls.joined(separator: ",\n"))
        ]
    )
    """
    try manifest.write(
        to: fixtureRoot.appendingPathComponent("Package.swift"),
        atomically: true,
        encoding: .utf8
    )
}

func swiftBuild(packagePath: URL) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
        "swift", "build",
        "--package-path", packagePath.path,
        "--disable-sandbox",
    ]
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        fail("failed to launch swift build: \(error)")
    }
    if process.terminationStatus != 0 {
        fail("snippet consumer package failed to compile (exit \(process.terminationStatus))")
    }
}

func expectExtractFailure(name: String, text: String, containing: String) {
    do {
        _ = try extractSnippets(from: text, sourcePath: name)
        fail("self-test \(name): expected extraction to fail")
    } catch let error as VerifierError {
        if error.message.localizedCaseInsensitiveContains(containing) {
            print("SELF-TEST PASS: \(name)")
        } else {
            fail("self-test \(name): expected error containing '\(containing)', got '\(error.message)'")
        }
    } catch {
        fail("self-test \(name): unexpected error \(error)")
    }
}

func expectExtract(name: String, text: String, bodyContains: String, count: Int = 1) {
    do {
        let snippets = try extractSnippets(from: text, sourcePath: name)
        guard snippets.count == count else {
            fail("self-test \(name): expected \(count) snippet(s), got \(snippets.count)")
        }
        guard snippets.contains(where: { $0.code.contains(bodyContains) }) else {
            fail("self-test \(name): extracted body missing '\(bodyContains)'")
        }
        print("SELF-TEST PASS: \(name)")
    } catch {
        fail("self-test \(name): unexpected failure \(error)")
    }
}

func runParserSelfTests() {
    expectExtractFailure(
        name: "unclosed-marked-fence",
        text: """
        # Fixture
        ```swift compile
        import Foundation
        import Wax
        """,
        containing: "unclosed"
    )

    expectExtractFailure(
        name: "swallowed-marked-fence",
        text: """
        ```swift
        import Foundation
        ```swift compile
        import Wax
        func demo() {}
        ```
        """,
        containing: "swallowed"
    )

    expectExtractFailure(
        name: "malformed-compile-equals",
        text: """
        ```swift compile=true
        import Wax
        ```
        """,
        containing: "not extracted"
    )

    expectExtractFailure(
        name: "wrong-case-language",
        text: """
        ```Swift compile
        import Wax
        ```
        """,
        containing: "not extracted"
    )

    expectExtract(
        name: "inner-ticks-do-not-truncate",
        text: """
        ```swift compile
        import Foundation
        import Wax
        func demo() {
            // ```
            RemovedAPI()
        }
        ```
        """,
        bodyContains: "RemovedAPI()"
    )

    expectExtract(
        name: "four-tick-marked-fence",
        text: """
        ````swift compile
        import Foundation
        import Wax
        func fourTick() {}
        ````
        """,
        bodyContains: "func fourTick()"
    )

    expectExtract(
        name: "trait-marker-parsed",
        text: """
        ```swift compile trait:MiniLMEmbeddings
        import Wax
        func traitDemo() {}
        ```
        """,
        bodyContains: "func traitDemo()"
    )

    print("GREEN: snippet verifier parser self-tests passed")
}

let options = parseOptions()
if options.selfTest {
    runParserSelfTests()
    exit(0)
}

let markdownFiles = collectMarkdownFiles(markdownRoot: options.markdownRoot)
var snippets: [Snippet] = []
for file in markdownFiles {
    do {
        snippets.append(contentsOf: try extractSnippets(from: file))
    } catch let error as VerifierError {
        fail(error.message)
    } catch {
        fail("failed to read \(relativePath(file)): \(error)")
    }
}

if snippets.isEmpty {
    fail("no ```swift compile snippets found in README.md, Wax DocC, SKILL.md, or public skill templates")
}

print("Wax public snippet verifier")
print("  repo:     \(repoRoot.path)")
print("  snippets: \(snippets.count)")
print("  host FM:  \(hostHasFoundationModels ? "available" : "unavailable")")
for snippet in snippets {
    var tags: [String] = []
    if let trait = snippet.requiredTrait {
        tags.append("trait:\(trait)")
    }
    if isFoundationModelsGated(snippet) {
        tags.append("FM-gated")
    }
    let suffix = tags.isEmpty ? "" : " [\(tags.joined(separator: ", "))]"
    print("  - \(snippet.sourcePath)#\(snippet.index) (\(snippet.infoString))\(suffix)")
}

let fixtureRoot = fileManager.temporaryDirectory
    .appendingPathComponent("wax-snippet-verify-\(UUID().uuidString)", isDirectory: true)
try fileManager.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: fixtureRoot) }

let defaultRoot = fixtureRoot.appendingPathComponent("default", isDirectory: true)
do {
    try materializeConsumer(at: defaultRoot, snippets: snippets, traitsClause: "")
} catch {
    fail("failed to materialize default-trait consumer: \(error)")
}
print("Building default-trait consumer (\(snippets.count) snippets)...")
swiftBuild(packagePath: defaultRoot)

let traitsOffSnippets = snippets.filter { $0.requiredTrait == nil }
if traitsOffSnippets.isEmpty {
    fail("no trait-agnostic snippets to compile with traits: []")
}
let traitsOffRoot = fixtureRoot.appendingPathComponent("traits-off", isDirectory: true)
do {
    try materializeConsumer(at: traitsOffRoot, snippets: traitsOffSnippets, traitsClause: ", traits: []")
} catch {
    fail("failed to materialize traits-off consumer: \(error)")
}
print("Building traits-off consumer (\(traitsOffSnippets.count) snippets)...")
swiftBuild(packagePath: traitsOffRoot)

let fmGated = snippets.filter(isFoundationModelsGated)
if !hostHasFoundationModels && !fmGated.isEmpty {
    print("SKIP: \(fmGated.count) Foundation Models snippets typecheck-skipped (canImport(FoundationModels) is false on this host)")
    for snippet in fmGated {
        print("  SKIP \(snippet.sourcePath)#\(snippet.index)")
    }
    let typechecked = snippets.count - fmGated.count
    print("GREEN: \(typechecked) public Swift snippets compiled with strict concurrency (\(fmGated.count) FM skipped)")
} else {
    print("GREEN: \(snippets.count) public Swift snippets compiled with strict concurrency")
}
print("TRAITS-OFF: \(traitsOffSnippets.count) trait-agnostic snippets compiled with traits: []")
