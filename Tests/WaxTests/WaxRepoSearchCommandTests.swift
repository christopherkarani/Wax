import Foundation
import Testing

@Test func waxRepoSearchCommandUsesOneShotPathWhenQueryIsProvided() throws {
    let source = try WaxRepoSource.load("Commands/SearchCommand.swift")

    #expect(source.contains("try await runOneShotSearch(query: query, store: store)"))
    #expect(source.contains("private func runInteractiveSearch(store: RepoStore) async throws"))
    #expect(source.contains("Application(rootView: SearchView(viewModel: viewModel)).start()"))
}

@Test(.enabled(if: ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 14))
func waxRepoSearchQueryRunsOneShotAndExits() async throws {
    let executable = try WaxRepoProcess.builtProductURL()
    let repo = try WaxRepoFixture.makeGitRepo()

    let index = try WaxRepoProcess.run(
        executableURL: executable,
        arguments: ["index", "--repo-path", repo.path, "--text-only"],
        timeout: 15
    )
    #expect(index.status == 0, "index failed: \(index.stderr)")

    let search = try WaxRepoProcess.run(
        executableURL: executable,
        arguments: ["search", "needle", "--repo-path", repo.path, "--text-only", "--top-k", "3"],
        timeout: 5
    )
    #expect(search.status == 0, "search failed: \(search.stderr)")
    #expect(search.stdout.contains("needle"))
}

private enum WaxRepoSource {
    static func load(_ relativePath: String, filePath: String = #filePath) throws -> String {
        let testFile = URL(fileURLWithPath: filePath)
        let packageRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = packageRoot
            .appendingPathComponent("Sources/WaxRepo")
            .appendingPathComponent(relativePath)
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}

private enum WaxRepoFixture {
    static func makeGitRepo(filePath: String = #filePath) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wax-repo-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        _ = try WaxRepoProcess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["git", "init"],
            currentDirectoryURL: root
        )
        _ = try WaxRepoProcess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["git", "config", "user.email", "wax@example.com"],
            currentDirectoryURL: root
        )
        _ = try WaxRepoProcess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["git", "config", "user.name", "Wax Test"],
            currentDirectoryURL: root
        )

        try "needle search fixture\n".write(
            to: root.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        _ = try WaxRepoProcess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["git", "add", "README.md"],
            currentDirectoryURL: root
        )
        _ = try WaxRepoProcess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["git", "commit", "-m", "Add needle fixture"],
            currentDirectoryURL: root
        )

        return root
    }
}

private enum WaxRepoProcess {
    struct Output {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    static func builtProductURL(filePath: String = #filePath) throws -> URL {
        let packageRoot = URL(fileURLWithPath: filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let candidates = [
            packageRoot.appendingPathComponent(".build/debug/WaxRepo"),
            packageRoot.appendingPathComponent(".build/arm64-apple-macosx/debug/WaxRepo"),
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        throw WaxRepoTestError("Build WaxRepo before running this test")
    }

    static func run(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL? = nil,
        timeout: TimeInterval = 10
    ) throws -> Output {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }

        try process.run()
        if terminated.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            process.waitUntilExit()
            throw WaxRepoTestError("Process timed out: \(executableURL.path) \(arguments.joined(separator: " "))")
        }

        process.waitUntilExit()
        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return Output(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}

private struct WaxRepoTestError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
