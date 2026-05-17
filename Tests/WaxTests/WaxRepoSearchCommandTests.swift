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
    let repo = try WaxRepoFixture.makeGitRepo(prefix: "wax-repo-search")
    try WaxRepoFixture.addCommit(
        to: repo,
        fileName: "README.md",
        contents: "needle search fixture\n",
        message: "Add needle fixture"
    )

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

@Test(.enabled(if: ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 14))
func waxRepoSearchUsesStoredMetadataWhenPreviewOmitsHeader() async throws {
    let executable = try WaxRepoProcess.builtProductURL()
    let repo = try WaxRepoFixture.makeGitRepo(prefix: "wax-repo-metadata")
    try WaxRepoFixture.addCommit(
        to: repo,
        fileName: "feature.txt",
        contents: "alpha beta gamma metadata-needle\n",
        message: "Preserve metadata subject"
    )

    let index = try WaxRepoProcess.run(
        executableURL: executable,
        arguments: ["index", "--repo-path", repo.path, "--text-only"],
        timeout: 15
    )
    #expect(index.status == 0, "index failed: \(index.stderr)")

    let search = try WaxRepoProcess.run(
        executableURL: executable,
        arguments: ["search", "metadata-needle", "--repo-path", repo.path, "--text-only", "--top-k", "3"],
        timeout: 5
    )
    #expect(search.status == 0, "search failed: \(search.stderr)")
    #expect(search.stdout.contains("Preserve metadata subject"))
}
