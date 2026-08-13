#!/usr/bin/env swift
import Foundation

/// Extracts fenced `swift` blocks that carry a `compile` / `compile-package` /
/// `compile run` marker from README.md, Wax DocC articles,
/// `Resources/skills/public/wax/SKILL.md`, and public skill templates.
/// Public `compile` snippets are materialized into a nested SwiftPM consumer
/// package and compiled with Swift 6.2 strict concurrency and
/// `-warnings-as-errors`. `compile run` snippets are executed after a successful
/// build (non-zero exit fails the verifier). `compile-package` snippets are
/// typechecked as extra targets in an overlay of this package (same package
/// identity as Wax), so `package` APIs such as `MemoryOrchestrator` and
/// `FastRAGConfig` are visible — they are NOT compiled as a downstream consumer.
///
/// Compile marker convention (info-string tokens after the language):
///   ```swift compile
///       Typecheck this fence in the default-trait consumer AND the traits-off
///       consumer (`traits: []`).
///   ```swift compile run
///       Same as `compile`, then execute the generated consumer. Declaration
///       snippets must expose a top-level `func` which the harness invokes.
///   ```swift compile trait:MiniLMEmbeddings
///       Typecheck only in the default-trait consumer. Excluded from traits-off.
///       Replace MiniLMEmbeddings with any Wax package trait name as needed.
///   ```swift compile-package
///       Typecheck against package targets (overlay of this package), not a
///       downstream `import Wax` consumer. Use for package-only DocC samples.
///
/// Every fence whose info string mentions `compile` MUST be extracted. An
/// unclosed fence, a parse anomaly, a swallowed marked fence, a malformed
/// marker (`compile=true`, `{compile}`, `Swift compile`), or a marked fence
/// whose body is only comments/blank lines fails the run.
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
///   --self-test-fixtures     Run /tmp negative build/run fixtures and exit
///   --markdown-root PATH     Collect markdown from PATH instead of the repo docs

struct Snippet: Sendable {
    var sourcePath: String
    var index: Int
    var infoString: String
    var code: String
    var requiredTrait: String?
    var shouldRun: Bool
    var isPackageOnly: Bool
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
    var selfTestFixtures = false
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
        } else if arg == "--self-test-fixtures" {
            options.selfTestFixtures = true
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
    guard tokens.first == "swift" else { return false }
    return tokens.contains("compile") || tokens.contains("compile-package")
}

func isPackageOnly(infoString: String) -> Bool {
    infoTokens(infoString).contains("compile-package")
}

func shouldRun(infoString: String) -> Bool {
    let tokens = infoTokens(infoString)
    return tokens.contains("compile") && tokens.contains("run") && !tokens.contains("compile-package")
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
            guard containsSwiftCode(body) else {
                throw VerifierError(
                    message: "comment-only or empty compile-marked fence in \(sourcePath):\(index + 1)"
                )
            }
            snippets.append(
                Snippet(
                    sourcePath: sourcePath,
                    index: snippetIndex,
                    infoString: opening.infoString,
                    code: applyFixtures(body),
                    requiredTrait: requiredTrait(infoString: opening.infoString),
                    shouldRun: shouldRun(infoString: opening.infoString),
                    isPackageOnly: isPackageOnly(infoString: opening.infoString)
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

func containsSwiftCode(_ code: String) -> Bool {
    for rawLine in code.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { continue }
        if line.hasPrefix("//") { continue }
        if line.hasPrefix("/*") || line.hasPrefix("*") || line.hasPrefix("*/") { continue }
        return true
    }
    return false
}

struct TopLevelFunction {
    var name: String
    var isAsync: Bool
    var isThrows: Bool
}

func topLevelFunctions(in code: String) -> [TopLevelFunction] {
    var functions: [TopLevelFunction] = []
    for rawLine in code.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(rawLine)
        if line.hasPrefix(" ") || line.hasPrefix("\t") { continue }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("func ") else { continue }
        let rest = trimmed.dropFirst(5)
        guard let nameEnd = rest.firstIndex(of: "(") else { continue }
        let name = String(rest[..<nameEnd]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { continue }
        functions.append(
            TopLevelFunction(
                name: name,
                isAsync: trimmed.contains(" async"),
                isThrows: trimmed.contains("throws")
            )
        )
    }
    return functions
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
    let functions = topLevelFunctions(in: snippet.code)
    if snippet.shouldRun, !snippet.code.contains("@main"), !functions.isEmpty {
        try code.write(
            to: directory.appendingPathComponent("Snippet.swift"),
            atomically: true,
            encoding: .utf8
        )
        let calls = functions.map { function -> String in
            let name = function.name
            switch (function.isAsync, function.isThrows) {
            case (true, true): return "        try await \(name)()"
            case (true, false): return "        await \(name)()"
            case (false, true): return "        try \(name)()"
            case (false, false): return "        \(name)()"
            }
        }.joined(separator: "\n")
        let harness = """
        @main
        enum __WaxSnippetHarness {
            static func main() async throws {
        \(calls)
            }
        }
        """
        try harness.write(
            to: directory.appendingPathComponent("Harness.swift"),
            atomically: true,
            encoding: .utf8
        )
    } else if snippet.shouldRun, functions.isEmpty, isDeclarationOnly(code) {
        throw VerifierError(
            message: "compile run snippet \(snippet.sourcePath)#\(snippet.index) has no invocable top-level function or statements"
        )
    } else if isDeclarationOnly(code) {
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

func snippetTargetName(_ snippet: Snippet, offset: Int) -> String {
    "Snippet\(String(format: "%03d", offset + 1))_\(swiftIdentifier(snippet.sourcePath))_\(snippet.index)"
}

func runProcess(arguments: [String], failMessage: String) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        fail("\(failMessage): \(error)")
    }
    return process.terminationStatus
}

func captureProcess(arguments: [String]) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        fail("failed to launch \(arguments.joined(separator: " ")): \(error)")
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    return (process.terminationStatus, output)
}

func swiftBuild(packagePath: URL, product: String? = nil) {
    var arguments = [
        "swift", "build",
        "--package-path", packagePath.path,
        "--disable-sandbox",
        "-Xswiftc", "-warnings-as-errors",
    ]
    if let product {
        arguments += ["--product", product]
    }
    let status = runProcess(
        arguments: arguments,
        failMessage: "failed to launch swift build"
    )
    if status != 0 {
        fail("snippet package failed to compile (exit \(status))")
    }
}

func swiftBinPath(packagePath: URL) -> String {
    let captured = captureProcess(
        arguments: [
            "swift", "build",
            "--package-path", packagePath.path,
            "--show-bin-path",
            "--disable-sandbox",
        ]
    )
    if captured.status != 0 {
        fail("swift build --show-bin-path failed (exit \(captured.status)): \(captured.output)")
    }
    let path = captured.output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty else { fail("swift build --show-bin-path returned empty path") }
    return path
}

func runExecutable(at url: URL, label: String) {
    let status = runProcess(
        arguments: [url.path],
        failMessage: "failed to launch \(label)"
    )
    if status != 0 {
        fail("compile run snippet \(label) exited \(status)")
    }
}

func materializeConsumer(at fixtureRoot: URL, snippets: [Snippet], traitsClause: String) throws {
    var targetDecls: [String] = []
    for (offset, snippet) in snippets.enumerated() {
        let name = snippetTargetName(snippet, offset: offset)
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

func cloneTree(from source: URL, to destination: URL) throws {
    try fileManager.createDirectory(
        at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    if fileManager.fileExists(atPath: destination.path) {
        try fileManager.removeItem(at: destination)
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/cp")
    process.arguments = ["-cR", source.path, destination.path]
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        try fileManager.copyItem(at: source, to: destination)
        return
    }
    if process.terminationStatus != 0 {
        try fileManager.copyItem(at: source, to: destination)
    }
}

func materializePackageOverlay(at overlayRoot: URL, snippets: [Snippet]) throws {
    try fileManager.createDirectory(at: overlayRoot, withIntermediateDirectories: true)
    try cloneTree(
        from: repoRoot.appendingPathComponent("Sources"),
        to: overlayRoot.appendingPathComponent("Sources")
    )
    try cloneTree(
        from: repoRoot.appendingPathComponent("Tests"),
        to: overlayRoot.appendingPathComponent("Tests")
    )
    var manifest = try String(
        contentsOf: repoRoot.appendingPathComponent("Package.swift"),
        encoding: .utf8
    )
    var appends: [String] = []
    for (offset, snippet) in snippets.enumerated() {
        let name = snippetTargetName(snippet, offset: offset)
        let dir = overlayRoot.appendingPathComponent("PackageSnippets/\(name)", isDirectory: true)
        try writeSnippet(snippet, to: dir)
        appends.append(
            """
            package.targets.append(
                .executableTarget(
                    name: "\(name)",
                    dependencies: ["Wax", "WaxCore"],
                    path: "PackageSnippets/\(name)",
                    swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
                )
            )
            """
        )
    }
    manifest += "\n" + appends.joined(separator: "\n") + "\n"
    try manifest.write(
        to: overlayRoot.appendingPathComponent("Package.swift"),
        atomically: true,
        encoding: .utf8
    )
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

    expectExtract(
        name: "compile-run-marker-parsed",
        text: """
        ```swift compile run
        import Wax
        func rankingDemo() async throws {}
        ```
        """,
        bodyContains: "func rankingDemo()"
    )

    expectExtract(
        name: "compile-package-marker-parsed",
        text: """
        ```swift compile-package
        import Wax
        func packageDemo() {
            _ = FastRAGConfig()
        }
        ```
        """,
        bodyContains: "FastRAGConfig()"
    )

    expectExtractFailure(
        name: "comment-only-marked-fence",
        text: """
        ```swift compile
        // TODO
        ```
        """,
        containing: "comment-only"
    )

    expectExtractFailure(
        name: "blank-only-marked-fence",
        text: """
        ```swift compile

        ```
        """,
        containing: "comment-only"
    )

    do {
        let snippets = try extractSnippets(
            from: """
            ```swift compile run
            import Wax
            func rankingDemo() async throws {}
            ```
            """,
            sourcePath: "run-flag"
        )
        guard snippets.count == 1, snippets[0].shouldRun, !snippets[0].isPackageOnly else {
            fail("self-test run-flag: expected shouldRun=true packageOnly=false")
        }
        print("SELF-TEST PASS: run-flag")
    } catch {
        fail("self-test run-flag: unexpected failure \(error)")
    }

    do {
        let snippets = try extractSnippets(
            from: """
            ```swift compile-package
            import Wax
            func packageDemo() {}
            ```
            """,
            sourcePath: "package-flag"
        )
        guard snippets.count == 1, snippets[0].isPackageOnly, !snippets[0].shouldRun else {
            fail("self-test package-flag: expected isPackageOnly=true shouldRun=false")
        }
        print("SELF-TEST PASS: package-flag")
    } catch {
        fail("self-test package-flag: unexpected failure \(error)")
    }

    print("GREEN: snippet verifier parser self-tests passed")
}

func writeFixtureMarkdown(at directory: URL, contents: String) throws {
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    try contents.write(
        to: directory.appendingPathComponent("fixture.md"),
        atomically: true,
        encoding: .utf8
    )
}

func expectVerifierFailure(name: String, markdown: String, containing: String) {
    let root = fileManager.temporaryDirectory
        .appendingPathComponent("wax-snippet-neg-\(name)-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }
    do {
        try writeFixtureMarkdown(at: root, contents: markdown)
    } catch {
        fail("self-test-fixtures \(name): failed to write fixture: \(error)")
    }
    let captured = captureProcess(
        arguments: [
            "swift", scriptURL.path,
            "--markdown-root", root.path,
        ]
    )
    guard captured.status != 0 else {
        fail("self-test-fixtures \(name): expected verifier to fail")
    }
    if captured.output.localizedCaseInsensitiveContains(containing) {
        print("SELF-TEST-FIXTURES PASS: \(name)")
    } else {
        fail(
            "self-test-fixtures \(name): expected output containing '\(containing)', got '\(captured.output)'"
        )
    }
}

func runNegativeBuildFixtures() {
    expectVerifierFailure(
        name: "comment-only-fence",
        markdown: """
        # Fixture
        ```swift compile
        // TODO replace with a real example
        ```
        """,
        containing: "comment-only"
    )

    expectVerifierFailure(
        name: "uncompiled-package-only-sample",
        markdown: """
        # Fixture
        ```swift compile-package
        import Wax
        func packageDrift() {
            RemovedPackageAPI()
        }
        ```
        """,
        containing: "RemovedPackageAPI"
    )

    expectVerifierFailure(
        name: "warning-producing-snippet",
        markdown: """
        # Fixture
        ```swift compile
        func warningDemo() async {
            await 1
        }
        ```
        """,
        containing: "async"
    )

    expectVerifierFailure(
        name: "failing-run-snippet",
        markdown: """
        # Fixture
        ```swift compile run
        precondition(false, "expected-run-failure")
        ```
        """,
        containing: "compile run snippet"
    )

    print("GREEN: snippet verifier negative build fixtures failed closed")
}

let options = parseOptions()
if options.selfTest {
    runParserSelfTests()
    exit(0)
}
if options.selfTestFixtures {
    runNegativeBuildFixtures()
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
    if snippet.isPackageOnly {
        tags.append("package")
    }
    if snippet.shouldRun {
        tags.append("run")
    }
    if let trait = snippet.requiredTrait {
        tags.append("trait:\(trait)")
    }
    if isFoundationModelsGated(snippet) {
        tags.append("FM-gated")
    }
    let suffix = tags.isEmpty ? "" : " [\(tags.joined(separator: ", "))]"
    print("  - \(snippet.sourcePath)#\(snippet.index) (\(snippet.infoString))\(suffix)")
}

let publicSnippets = snippets.filter { !$0.isPackageOnly }
let packageSnippets = snippets.filter(\.isPackageOnly)

let fixtureRoot = fileManager.temporaryDirectory
    .appendingPathComponent("wax-snippet-verify-\(UUID().uuidString)", isDirectory: true)
try fileManager.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: fixtureRoot) }

if !publicSnippets.isEmpty {
    let defaultRoot = fixtureRoot.appendingPathComponent("default", isDirectory: true)
    do {
        try materializeConsumer(at: defaultRoot, snippets: publicSnippets, traitsClause: "")
    } catch {
        fail("failed to materialize default-trait consumer: \(error)")
    }
    print("Building default-trait consumer (\(publicSnippets.count) snippets)...")
    swiftBuild(packagePath: defaultRoot)

    let runSnippets = publicSnippets.enumerated().filter { $0.element.shouldRun }
    if !runSnippets.isEmpty {
        let binPath = swiftBinPath(packagePath: defaultRoot)
        for (offset, snippet) in runSnippets {
            let name = snippetTargetName(snippet, offset: offset)
            print("Running \(snippet.sourcePath)#\(snippet.index) (\(name))...")
            runExecutable(
                at: URL(fileURLWithPath: binPath).appendingPathComponent(name),
                label: "\(snippet.sourcePath)#\(snippet.index)"
            )
        }
        print("RUN: \(runSnippets.count) compile-run snippet(s) exited 0")
    }

    let traitsOffSnippets = publicSnippets.filter { $0.requiredTrait == nil }
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
    print("TRAITS-OFF: \(traitsOffSnippets.count) trait-agnostic snippets compiled with traits: []")
} else if packageSnippets.isEmpty {
    fail("no public compile snippets found")
}

if !packageSnippets.isEmpty {
    let overlayRoot = fixtureRoot.appendingPathComponent("package-overlay", isDirectory: true)
    do {
        try materializePackageOverlay(at: overlayRoot, snippets: packageSnippets)
    } catch {
        fail("failed to materialize package-overlay: \(error)")
    }
    print("Building package-overlay (\(packageSnippets.count) snippets)...")
    swiftBuild(packagePath: overlayRoot)
    print("PACKAGE: \(packageSnippets.count) compile-package snippets typechecked against package targets")
}

let fmGated = publicSnippets.filter(isFoundationModelsGated)
if !hostHasFoundationModels && !fmGated.isEmpty {
    print("SKIP: \(fmGated.count) Foundation Models snippets typecheck-skipped (canImport(FoundationModels) is false on this host)")
    for snippet in fmGated {
        print("  SKIP \(snippet.sourcePath)#\(snippet.index)")
    }
    let typechecked = publicSnippets.count - fmGated.count
    print("GREEN: \(typechecked) public Swift snippets compiled with strict concurrency (\(fmGated.count) FM skipped)")
} else {
    print("GREEN: \(publicSnippets.count) public Swift snippets compiled with strict concurrency")
}
