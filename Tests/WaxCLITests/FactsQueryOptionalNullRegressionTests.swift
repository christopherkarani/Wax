import Foundation
import Testing

/// Regression: `facts-query` with omitted optional filters used to fail with
/// "subject must be a string" because the broker treated JSON null as invalid.
@Test
func factsQueryWithoutFiltersSucceedsViaCLI() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // WaxCLITests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // repo
    let binary = repoRoot.appendingPathComponent(".build/debug/wax-cli")
    try #require(FileManager.default.isExecutableFile(atPath: binary.path))

    let store = FileManager.default.temporaryDirectory
        .appendingPathComponent("facts-null-\(UUID().uuidString).wax")
    defer { try? FileManager.default.removeItem(at: store) }

    func run(_ args: [String]) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = binary
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    let storePath = store.path
    let assert = try run([
        "fact-assert", "--store-path", storePath, "--no-embedder",
        "--subject", "user", "--predicate", "prefers", "--object", "Helix",
    ])
    #expect(assert.0 == 0, Comment(rawValue: "fact-assert failed: \(assert.1)"))

    let queryAll = try run([
        "facts-query", "--store-path", storePath, "--no-embedder",
    ])
    #expect(queryAll.0 == 0, Comment(rawValue: "facts-query failed: \(queryAll.1)"))
    #expect(
        queryAll.1.localizedCaseInsensitiveContains("Helix")
            || queryAll.1.localizedCaseInsensitiveContains("prefers")
            || queryAll.1.localizedCaseInsensitiveContains("user")
            || queryAll.1.localizedCaseInsensitiveContains("fact"),
        Comment(rawValue: queryAll.1)
    )
}
