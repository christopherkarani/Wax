import Foundation
import Testing
@testable import Wax

private let shaA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
private let shaB = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

private func plantGitRepo(
    named: String,
    head: String,
    branch: String? = "main"
) throws -> URL {
    let repoURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(named)-\(UUID().uuidString.prefix(8))", isDirectory: true)
    let gitURL = repoURL.appendingPathComponent(".git", isDirectory: true)
    try FileManager.default.createDirectory(at: gitURL, withIntermediateDirectories: true)
    if let branch {
        let refDir = gitURL.appendingPathComponent("refs/heads", isDirectory: true)
        try FileManager.default.createDirectory(at: refDir, withIntermediateDirectories: true)
        try (head + "\n").write(
            to: refDir.appendingPathComponent(branch),
            atomically: true,
            encoding: .utf8
        )
        try "ref: refs/heads/\(branch)\n".write(
            to: gitURL.appendingPathComponent("HEAD"),
            atomically: true,
            encoding: .utf8
        )
    } else {
        try (head + "\n").write(
            to: gitURL.appendingPathComponent("HEAD"),
            atomically: true,
            encoding: .utf8
        )
    }
    return repoURL
}

struct CheckoutHonestyTests {
    @Test
    func snapshotReadsBranchRefSHA() throws {
        let repo = try plantGitRepo(named: "wax-git-branch", head: shaA, branch: "main")
        defer { try? FileManager.default.removeItem(at: repo) }

        let snap = MemorySemantics.snapshotGitCheckout(startingAt: repo.path)
        #expect(snap.sha == shaA)
        #expect(snap.branch == "main")
        #expect(snap.worktree == nil)
    }

    @Test
    func snapshotReadsDetachedHEAD() throws {
        let repo = try plantGitRepo(named: "wax-git-detach", head: shaB, branch: nil)
        defer { try? FileManager.default.removeItem(at: repo) }

        let snap = MemorySemantics.snapshotGitCheckout(startingAt: repo.path)
        #expect(snap.sha == shaB)
        #expect(snap.branch == nil)
    }

    @Test
    func snapshotNamesLinkedWorktree() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-wt-root-\(UUID().uuidString.prefix(6))", isDirectory: true)
        let worktreeFolder = "rapid-river"
        let repoURL = root.appendingPathComponent("repo", isDirectory: true)
        let worktreeURL = root.appendingPathComponent(worktreeFolder, isDirectory: true)
        let worktreeGitDir = repoURL.appendingPathComponent(".git/worktrees/\(worktreeFolder)", isDirectory: true)
        try FileManager.default.createDirectory(at: worktreeGitDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktreeURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "gitdir: \(worktreeGitDir.path)\n"
            .write(to: worktreeURL.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        try "ref: refs/heads/feature\n"
            .write(to: worktreeGitDir.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        let commonRefs = repoURL.appendingPathComponent(".git/refs/heads", isDirectory: true)
        try FileManager.default.createDirectory(at: commonRefs, withIntermediateDirectories: true)
        try (shaA + "\n").write(
            to: commonRefs.appendingPathComponent("feature"),
            atomically: true,
            encoding: .utf8
        )

        let snap = MemorySemantics.snapshotGitCheckout(startingAt: worktreeURL.path)
        #expect(snap.sha == shaA)
        #expect(snap.branch == "feature")
        #expect(snap.worktree == worktreeFolder)
    }

    @Test
    func onThisTreeYesWhenSHAMatches() {
        let live = GitCheckoutSnapshot(sha: shaA, branch: "main", worktree: nil)
        #expect(MemorySemantics.onThisTree(storedSHA: shaA, live: live) == .yes)
        #expect(MemorySemantics.onThisTree(storedSHA: String(shaA.prefix(12)), live: live) == .yes)
    }

    @Test
    func onThisTreeOtherWhenSHADiffers() {
        let live = GitCheckoutSnapshot(sha: shaB, branch: "main", worktree: nil)
        #expect(MemorySemantics.onThisTree(storedSHA: shaA, live: live) == .other)
    }

    @Test
    func onThisTreeUnknownWithoutSHA() {
        let live = GitCheckoutSnapshot(sha: nil, branch: nil, worktree: nil)
        #expect(MemorySemantics.onThisTree(storedSHA: shaA, live: live) == .unknown)
        #expect(MemorySemantics.onThisTree(storedSHA: nil, live: GitCheckoutSnapshot(sha: shaA)) == .unknown)
    }

    @Test
    func decisionDefaultsToIntentAndStampsGit() throws {
        let repo = try plantGitRepo(named: "wax-stamp", head: shaA, branch: "main")
        defer { try? FileManager.default.removeItem(at: repo) }
        let scope = MemorySemantics.inferScopeContext(currentDirectoryPath: repo.path)
        let metadata = MemorySemantics.normalizeWriteMetadata(
            metadata: [:],
            semantics: MemoryWriteSemantics(type: .decision),
            sessionID: nil,
            inferredScope: scope,
            nowMs: 1
        )
        #expect(metadata[MemoryMetadataKeys.checkoutStatus] == MemoryCheckoutStatus.intent.rawValue)
        #expect(metadata[MemoryMetadataKeys.gitSHA] == shaA)
        #expect(metadata[MemoryMetadataKeys.gitBranch] == "main")
    }

    @Test
    func factOmitsCheckoutStatusUnlessPassed() throws {
        let metadata = MemorySemantics.normalizeWriteMetadata(
            metadata: [:],
            semantics: MemoryWriteSemantics(type: .fact),
            sessionID: nil,
            inferredScope: MemoryScopeContext(),
            nowMs: 1
        )
        #expect(metadata[MemoryMetadataKeys.checkoutStatus] == nil)
    }

    @Test
    func explicitLandedRoundTrips() throws {
        let metadata = MemorySemantics.normalizeWriteMetadata(
            metadata: [:],
            semantics: MemoryWriteSemantics(type: .decision, checkoutStatus: .landed),
            sessionID: nil,
            inferredScope: MemoryScopeContext(),
            nowMs: 1
        )
        #expect(metadata[MemoryMetadataKeys.checkoutStatus] == MemoryCheckoutStatus.landed.rawValue)
    }

    @Test
    func writeDropsClientGitSHAWhenSnapshotMisses() {
        let metadata = MemorySemantics.normalizeWriteMetadata(
            metadata: [
                MemoryMetadataKeys.gitSHA: shaA,
                MemoryMetadataKeys.gitBranch: "spoofed",
                MemoryMetadataKeys.gitWorktree: "spoofed-wt",
                MemoryMetadataKeys.onThisTree: OnThisTree.yes.rawValue,
            ],
            semantics: MemoryWriteSemantics(type: .fact),
            sessionID: nil,
            inferredScope: MemoryScopeContext(),
            nowMs: 1
        )
        #expect(metadata[MemoryMetadataKeys.gitSHA] == nil)
        #expect(metadata[MemoryMetadataKeys.gitBranch] == nil)
        #expect(metadata[MemoryMetadataKeys.gitWorktree] == nil)
        #expect(metadata[MemoryMetadataKeys.onThisTree] == nil)
    }

    @Test
    func writeIgnoresClientLandedFlagUnlessTyped() {
        let fact = MemorySemantics.normalizeWriteMetadata(
            metadata: [MemoryMetadataKeys.checkoutStatus: MemoryCheckoutStatus.landed.rawValue],
            semantics: MemoryWriteSemantics(type: .fact),
            sessionID: nil,
            inferredScope: MemoryScopeContext(),
            nowMs: 1
        )
        #expect(fact[MemoryMetadataKeys.checkoutStatus] == nil)

        let decision = MemorySemantics.normalizeWriteMetadata(
            metadata: [MemoryMetadataKeys.checkoutStatus: MemoryCheckoutStatus.landed.rawValue],
            semantics: MemoryWriteSemantics(type: .decision),
            sessionID: nil,
            inferredScope: MemoryScopeContext(),
            nowMs: 1
        )
        #expect(decision[MemoryMetadataKeys.checkoutStatus] == MemoryCheckoutStatus.intent.rawValue)
    }

    @Test
    func rankingAdjustedScoreTrustsStampedOnThisTree() {
        let stampedYes = LayeredRecall.Hit(
            id: .durable(frameID: 1),
            score: 0.90,
            text: "C01 GitLiveProbe Strong execute",
            preview: "C01 GitLiveProbe Strong execute",
            metadata: [
                MemoryMetadataKeys.checkoutStatus: MemoryCheckoutStatus.landed.rawValue,
                MemoryMetadataKeys.gitSHA: shaA,
                MemoryMetadataKeys.onThisTree: OnThisTree.yes.rawValue,
            ],
            explanations: [],
            timestampMs: 0
        )
        let live = GitCheckoutSnapshot(sha: shaB, branch: "main", worktree: nil)
        #expect(
            abs(
                LayeredRecall.rankingAdjustedScore(
                    stampedYes,
                    nowMs: 1,
                    query: "GitLiveProbe",
                    liveCheckout: live
                ) - 0.90
            ) < 0.0001
        )

        let unstamped = LayeredRecall.Hit(
            id: .durable(frameID: 2),
            score: 0.90,
            text: "C01 GitLiveProbe Strong execute",
            preview: "C01 GitLiveProbe Strong execute",
            metadata: [
                MemoryMetadataKeys.checkoutStatus: MemoryCheckoutStatus.landed.rawValue,
                MemoryMetadataKeys.gitSHA: shaA,
            ],
            explanations: [],
            timestampMs: 0
        )
        #expect(
            abs(
                LayeredRecall.rankingAdjustedScore(
                    unstamped,
                    nowMs: 1,
                    query: "GitLiveProbe",
                    liveCheckout: live
                ) - 0.65
            ) < 0.0001
        )
    }

    @Test
    func compactHitSurfacesGitAndOnThisTree() throws {
        let object = RecallPresent.compactHitObject(
            id: "durable:1",
            text: "C01 GitLiveProbe Strong execute",
            preview: nil,
            metadata: [
                MemoryMetadataKeys.gitSHA: shaA,
                MemoryMetadataKeys.gitBranch: "main",
                MemoryMetadataKeys.gitWorktree: "rapid-river",
                MemoryMetadataKeys.checkoutStatus: MemoryCheckoutStatus.intent.rawValue,
                MemoryMetadataKeys.onThisTree: OnThisTree.other.rawValue,
            ],
            score: 0.9,
            createdAtMs: 0,
            nowMs: 1
        )
        #expect(object["git_sha"]?.stringValue == shaA)
        #expect(object["git_branch"]?.stringValue == "main")
        #expect(object["git_worktree"]?.stringValue == "rapid-river")
        #expect(object["checkout_status"]?.stringValue == "intent")
        #expect(object["on_this_tree"]?.stringValue == "other")
    }

    @Test
    func rememberTypedLandedSurvivesBrokerWrite() async throws {
        let repo = try plantGitRepo(named: "wax-landed-stamp", head: shaA, branch: "main")
        defer { try? FileManager.default.removeItem(at: repo) }
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-landed-broker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.enableTextSearch = true
        let service = try await AgentBrokerService(
            storePath: rootURL.appendingPathComponent("memory.wax").path,
            sessionRootPath: rootURL.appendingPathComponent("sessions").path,
            noEmbedder: true,
            embedderChoice: "auto",
            requireVector: false,
            orchestratorConfig: config
        )
        do {
            let project = "checkout-landed-\(UUID().uuidString.prefix(6))"
            let write = await service.handle(.init(
                command: "remember",
                arguments: [
                    "content": .string("C01 GitLiveProbe types exist on this HEAD."),
                    "memory_type": .string("decision"),
                    "checkout_status": .string("landed"),
                    "project": .string(project),
                    "repo": .string(project),
                    "cwd": .string(repo.path),
                ]
            ))
            #expect(write.ok == true, "remember failed: \(write.error ?? "nil")")
            let writePayload = try #require(write.payload?.objectValue)
            #expect(writePayload["checkout_status"]?.stringValue == "landed")
            #expect(writePayload["git_sha"]?.stringValue == shaA)
            try await service.close()
        } catch {
            try? await service.close()
            throw error
        }
    }

    @Test
    func rememberThenRecallLabelsOtherHEAD() async throws {
        let repoA = try plantGitRepo(named: "wax-head-a", head: shaA, branch: "main")
        let repoB = try plantGitRepo(named: "wax-head-b", head: shaB, branch: "main")
        defer {
            try? FileManager.default.removeItem(at: repoA)
            try? FileManager.default.removeItem(at: repoB)
        }
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-checkout-broker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.enableTextSearch = true
        let service = try await AgentBrokerService(
            storePath: rootURL.appendingPathComponent("memory.wax").path,
            sessionRootPath: rootURL.appendingPathComponent("sessions").path,
            noEmbedder: true,
            embedderChoice: "auto",
            requireVector: false,
            orchestratorConfig: config
        )
        do {
            let project = "checkout-honesty-\(UUID().uuidString.prefix(6))"
            let write = await service.handle(.init(
                command: "remember",
                arguments: [
                    "content": .string("C01 GitLiveProbe Strong execute"),
                    "memory_type": .string("decision"),
                    "project": .string(project),
                    "repo": .string(project),
                    "cwd": .string(repoA.path),
                ]
            ))
            #expect(write.ok == true, "remember failed: \(write.error ?? "nil")")
            let writePayload = try #require(write.payload?.objectValue)
            #expect(writePayload["git_sha"]?.stringValue == shaA)
            #expect(writePayload["checkout_status"]?.stringValue == "intent")

            let recall = await service.handle(.init(
                command: "recall",
                arguments: [
                    "query": .string("GitLiveProbe"),
                    "project": .string(project),
                    "repo": .string(project),
                    "cwd": .string(repoB.path),
                    "mode": .string("text"),
                    "limit": .int(5),
                ]
            ))
            #expect(recall.ok == true, "recall failed: \(recall.error ?? "nil")")
            let hits = try #require(recall.payload?.objectValue?["results"]?.arrayValue)
            let hit = try #require(hits.first { row in
                (row.objectValue?["text"]?.stringValue ?? "").contains("GitLiveProbe")
            }?.objectValue)
            #expect(hit["git_sha"]?.stringValue == shaA)
            #expect(hit["checkout_status"]?.stringValue == "intent")
            #expect(hit["on_this_tree"]?.stringValue == "other")
            try await service.close()
        } catch {
            try? await service.close()
            throw error
        }
    }
}
