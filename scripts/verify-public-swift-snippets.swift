#!/usr/bin/env swift
import Foundation

/// Extracts fenced `swift` blocks that carry a `compile` marker from README.md,
/// Wax DocC articles, and public skill templates. Materializes each snippet into
/// a nested SwiftPM consumer package and compiles it with Swift 6.2 strict concurrency.
///
/// Documented fixture tokens (replaced before compile, nowhere else):
///   __WAX_STORE_URL__  -> URL(fileURLWithPath: "/tmp/wax-docs-fixture.wax")
///   __WAX_PHOTO_URL__  -> URL(fileURLWithPath: "/tmp/wax-docs-fixture.png")
///   __WAX_VIDEO_URL__  -> URL(fileURLWithPath: "/tmp/wax-docs-fixture.mp4")
///
/// Declaration-only snippets get a sibling Harness.swift `@main` so they can live
/// in an executable target. Snippets that already contain `@main` or top-level
/// statements are written verbatim as main.swift.

struct Snippet: Sendable {
    var sourcePath: String
    var index: Int
    var infoString: String
    var code: String
}

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

func collectMarkdownFiles() -> [URL] {
    var files: [URL] = [
        repoRoot.appendingPathComponent("README.md"),
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

func extractSnippets(from url: URL) throws -> [Snippet] {
    let text = try String(contentsOf: url, encoding: .utf8)
    var snippets: [Snippet] = []
    var searchStart = text.startIndex
    var index = 0
    while searchStart < text.endIndex {
        guard let fenceStart = text[searchStart...].range(of: "```") else { break }
        let afterTicks = fenceStart.upperBound
        guard let newline = text[afterTicks...].firstIndex(of: "\n") else { break }
        let infoString = String(text[afterTicks..<newline])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let bodyStart = text.index(after: newline)
        guard let fenceEnd = text[bodyStart...].range(of: "```") else { break }
        let body = String(text[bodyStart..<fenceEnd.lowerBound])
        searchStart = fenceEnd.upperBound

        let tokens = infoString.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard tokens.first == "swift", tokens.contains("compile") else { continue }
        index += 1
        snippets.append(
            Snippet(
                sourcePath: relativePath(url),
                index: index,
                infoString: infoString,
                code: applyFixtures(body)
            )
        )
    }
    return snippets
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
            // Top-level lets in an executable are fine as main.swift statements
            // when they are not nested in a type. Treat them as executable.
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

let markdownFiles = collectMarkdownFiles()
var snippets: [Snippet] = []
for file in markdownFiles {
    do {
        snippets.append(contentsOf: try extractSnippets(from: file))
    } catch {
        fail("failed to read \(relativePath(file)): \(error)")
    }
}

if snippets.isEmpty {
    fail("no ```swift compile snippets found in README.md, Wax DocC, or public skill templates")
}

print("Wax public snippet verifier")
print("  repo:     \(repoRoot.path)")
print("  snippets: \(snippets.count)")
for snippet in snippets {
    print("  - \(snippet.sourcePath)#\(snippet.index) (\(snippet.infoString))")
}

let fixtureRoot = fileManager.temporaryDirectory
    .appendingPathComponent("wax-snippet-verify-\(UUID().uuidString)", isDirectory: true)
try fileManager.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: fixtureRoot) }

var targetDecls: [String] = []
for (offset, snippet) in snippets.enumerated() {
    let name = "Snippet\(String(format: "%03d", offset + 1))_\(swiftIdentifier(snippet.sourcePath))_\(snippet.index)"
    let dir = fixtureRoot.appendingPathComponent("Sources/\(name)", isDirectory: true)
    do {
        try writeSnippet(snippet, to: dir)
    } catch {
        fail("failed to materialize \(snippet.sourcePath)#\(snippet.index): \(error)")
    }
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
    dependencies: [.package(name: "Wax", path: "\(waxPath)")],
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

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
process.arguments = [
    "swift", "build",
    "--package-path", fixtureRoot.path,
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

print("GREEN: \(snippets.count) public Swift snippets compiled with strict concurrency")
