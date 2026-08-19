#if MCPServer
import Foundation
import Testing
@testable import Wax
@testable import wax_mcp

private func withIsolatedBroker<T>(
    _ body: (AgentBrokerService, URL) async throws -> T
) async throws -> T {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-0128-broker-\(UUID().uuidString)", isDirectory: true)
    let storeURL = rootURL.appendingPathComponent("memory.wax")
    let sessionRootURL = rootURL.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let service = try await AgentBrokerService(
        storePath: storeURL.path,
        sessionRootPath: sessionRootURL.path,
        noEmbedder: true,
        embedderChoice: "auto",
        requireVector: false
    )
    do {
        let result = try await body(service, sessionRootURL)
        try await service.close()
        return result
    } catch {
        try? await service.close()
        throw error
    }
}

private func makeGitRepo(named name: String) throws -> URL {
    let repo = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: repo.appendingPathComponent(".git", isDirectory: true),
        withIntermediateDirectories: true
    )
    return repo
}

private func requireObject(_ value: AgentBrokerValue?) throws -> [String: AgentBrokerValue] {
    try #require(value?.objectValue)
}

private func requireString(_ object: [String: AgentBrokerValue], _ key: String) throws -> String {
    try #require(object[key]?.stringValue)
}

private struct StatsReasonEmbedder: EmbeddingProvider, Sendable {
    let dimensions: Int = 2
    let normalize: Bool = true
    let identity: EmbeddingIdentity? = EmbeddingIdentity(
        provider: "Test",
        model: "StatsReason",
        dimensions: 2,
        normalized: true
    )

    func embed(_ text: String) async throws -> [Float] {
        _ = text
        return [1, 0]
    }
}

@Test
func customStorePathDoesNotDefaultToProductSessionRoot() throws {
    let store = FileManager.default.temporaryDirectory
        .appendingPathComponent("iso-\(UUID().uuidString)")
        .appendingPathExtension("wax")
    let resolved = AgentBrokerPathing.resolveSessionRootPath(
        storePath: store.path,
        sessionRootPath: AgentBrokerPathing.defaultSessionRootPath,
        environment: [:]
    )
    let productRoot = AgentBrokerPathing.expandPath(AgentBrokerPathing.defaultSessionRootPath)
    #expect(resolved != productRoot)
    #expect(resolved.contains(".local/share/waxmcp/sessions") == false)
}

@Test
func explicitSessionRootWinsForCustomStore() throws {
    let store = FileManager.default.temporaryDirectory
        .appendingPathComponent("iso-\(UUID().uuidString)")
        .appendingPathExtension("wax")
    let sessionRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("sess-\(UUID().uuidString)", isDirectory: true)
    let resolved = AgentBrokerPathing.resolveSessionRootPath(
        storePath: store.path,
        sessionRootPath: sessionRoot.path,
        environment: [:]
    )
    #expect(resolved == AgentBrokerPathing.expandPath(sessionRoot.path))
}

@Test
func defaultStoreKeepsProductSessionRootUnlessOverridden() throws {
    let productRoot = AgentBrokerPathing.expandPath(AgentBrokerPathing.defaultSessionRootPath)
    let resolved = AgentBrokerPathing.resolveSessionRootPath(
        storePath: AgentBrokerPathing.defaultStorePath,
        sessionRootPath: AgentBrokerPathing.defaultSessionRootPath,
        environment: [:]
    )
    #expect(resolved == productRoot)
}

@Test
func envSessionRootStillOverridesCustomStore() throws {
    let store = FileManager.default.temporaryDirectory
        .appendingPathComponent("iso-\(UUID().uuidString)")
        .appendingPathExtension("wax")
    let envRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("env-sess-\(UUID().uuidString)", isDirectory: true)
    let resolved = AgentBrokerPathing.resolveSessionRootPath(
        storePath: store.path,
        sessionRootPath: AgentBrokerPathing.defaultSessionRootPath,
        environment: ["WAX_SESSION_ROOT_DIR": envRoot.path]
    )
    #expect(resolved == AgentBrokerPathing.expandPath(envRoot.path))
}

@Test
func unscopedRememberUsesClientCwdNotDaemonScope() async throws {
    let repoA = try makeGitRepo(named: "RepoA")
    let repoB = try makeGitRepo(named: "RepoB")
    defer {
        try? FileManager.default.removeItem(at: repoA)
        try? FileManager.default.removeItem(at: repoB)
    }

    let fileManager = FileManager.default
    let original = fileManager.currentDirectoryPath
    guard fileManager.changeCurrentDirectoryPath(repoA.path) else {
        Issue.record("failed to chdir into RepoA")
        return
    }
    defer { _ = fileManager.changeCurrentDirectoryPath(original) }

    try await withIsolatedBroker { service, _ in
        let write = await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("Unscoped durable canary from client cwd RepoB"),
                "cwd": .string(repoB.path),
            ]
        ))
        #expect(write.ok == true)

        let search = await service.handle(.init(
            command: "search",
            arguments: [
                "query": .string("Unscoped durable canary from client cwd"),
                "mode": .string("text"),
                "topK": .int(5),
            ]
        ))
        #expect(search.ok == true)
        let hit = try #require(try requireObject(search.payload)["results"]?.arrayValue?.first?.objectValue)
        let metadata = try #require(hit["metadata"]?.objectValue)
        #expect(metadata["wax.repo"]?.stringValue == repoB.lastPathComponent)
        #expect(metadata["wax.project"]?.stringValue == repoB.lastPathComponent)
        #expect(metadata["wax.repo"]?.stringValue != repoA.lastPathComponent)
    }
}

@Test
func explicitRepoAndProjectArgsWinOverClientCwd() async throws {
    let repoB = try makeGitRepo(named: "RepoB")
    defer { try? FileManager.default.removeItem(at: repoB) }

    try await withIsolatedBroker { service, _ in
        let write = await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("Explicit scope should beat inferred cwd"),
                "cwd": .string(repoB.path),
                "repo": .string("explicit-repo"),
                "project": .string("explicit-project"),
            ]
        ))
        #expect(write.ok == true)

        let search = await service.handle(.init(
            command: "search",
            arguments: [
                "query": .string("Explicit scope should beat inferred cwd"),
                "mode": .string("text"),
                "topK": .int(5),
            ]
        ))
        #expect(search.ok == true)
        let hit = try #require(try requireObject(search.payload)["results"]?.arrayValue?.first?.objectValue)
        let metadata = try #require(hit["metadata"]?.objectValue)
        #expect(metadata["wax.repo"]?.stringValue == "explicit-repo")
        #expect(metadata["wax.project"]?.stringValue == "explicit-project")
    }
}

@Test
func sessionScopedRememberKeepsManifestProjectAndRepo() async throws {
    let repoB = try makeGitRepo(named: "RepoB")
    defer { try? FileManager.default.removeItem(at: repoB) }

    try await withIsolatedBroker { service, _ in
        let started = await service.handle(.init(
            command: "session_start",
            arguments: [
                "cwd": .string(repoB.path),
                "agent_id": .string("p05-agent"),
                "run_id": .string("p05-run"),
            ]
        ))
        #expect(started.ok == true)
        let sessionID = try requireString(try requireObject(started.payload), "session_id")

        let other = try makeGitRepo(named: "OtherRepo")
        defer { try? FileManager.default.removeItem(at: other) }

        let write = await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("Session scoped write must keep manifest repo"),
                "session_id": .string(sessionID),
                "cwd": .string(other.path),
            ]
        ))
        #expect(write.ok == true)

        let search = await service.handle(.init(
            command: "memory_search",
            arguments: [
                "query": .string("Session scoped write must keep manifest repo"),
                "session_id": .string(sessionID),
                "include_working": .bool(true),
                "include_durable": .bool(false),
                "include_episodic": .bool(false),
            ]
        ))
        #expect(search.ok == true)
        let hit = try #require(try requireObject(search.payload)["results"]?.arrayValue?.first?.objectValue)
        let metadata = try #require(hit["metadata"]?.objectValue)
        #expect(metadata["wax.repo"]?.stringValue == repoB.lastPathComponent)
        #expect(metadata["wax.project"]?.stringValue == repoB.lastPathComponent)
    }
}

@Test
func statsDoesNotAdvertiseSiblingSessionAsPrimary() async throws {
    try await withIsolatedBroker { service, _ in
        let first = await service.handle(.init(
            command: "session_start",
            arguments: [
                "agent_id": .string("client-a"),
                "run_id": .string("run-a"),
            ]
        ))
        let second = await service.handle(.init(
            command: "session_start",
            arguments: [
                "agent_id": .string("client-b"),
                "run_id": .string("run-b"),
            ]
        ))
        #expect(first.ok == true)
        #expect(second.ok == true)
        let sessionA = try requireString(try requireObject(first.payload), "session_id")
        let sessionB = try requireString(try requireObject(second.payload), "session_id")

        let statsA = await service.handle(.init(
            command: "stats",
            arguments: ["session_id": .string(sessionA)]
        ))
        let statsB = await service.handle(.init(
            command: "stats",
            arguments: ["session_id": .string(sessionB)]
        ))
        #expect(statsA.ok == true)
        #expect(statsB.ok == true)

        let sessionObjectA = try #require(try requireObject(statsA.payload)["session"]?.objectValue)
        let sessionObjectB = try #require(try requireObject(statsB.payload)["session"]?.objectValue)
        #expect(sessionObjectA["session_id"]?.stringValue == sessionA)
        #expect(sessionObjectB["session_id"]?.stringValue == sessionB)
        #expect(sessionObjectA["session_id"]?.stringValue != sessionB)
        #expect(sessionObjectB["session_id"]?.stringValue != sessionA)

        _ = await service.handle(.init(
            command: "session_end",
            arguments: ["session_id": .string(sessionA)]
        ))
        let leftover = await service.handle(.init(command: "stats", arguments: [:]))
        #expect(leftover.ok == true)
        let leftoverSession = try #require(try requireObject(leftover.payload)["session"]?.objectValue)
        #expect(leftoverSession["session_id"] == nil || leftoverSession["session_id"] == .null)
        #expect(leftoverSession["session_id"]?.stringValue != sessionB)
    }
}

@Test
func statsIncludesReasonWhenEmbeddingStatusIsDegradedOrUnavailable() async throws {
    #expect(EmbeddingStatus.degraded(nil, reason: "some saved frames have no vectors").wireReason == "some saved frames have no vectors")
    #expect(EmbeddingStatus.unavailable(reason: "embedder failed to load").wireReason == "embedder failed to load")

    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-0128-degraded-\(UUID().uuidString)", isDirectory: true)
    let storeURL = rootURL.appendingPathComponent("memory.wax")
    let sessionRootURL = rootURL.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let seed = try await AgentBrokerService(
        storePath: storeURL.path,
        sessionRootPath: sessionRootURL.path,
        noEmbedder: true,
        embedderChoice: "auto",
        requireVector: false
    )
    let remembered = await seed.handle(.init(
        command: "remember",
        arguments: ["content": .string("Seed frame without vectors for degraded stats.")]
    ))
    #expect(remembered.ok == true)
    try await seed.close()

    let service = try await AgentBrokerService(
        storePath: storeURL.path,
        sessionRootPath: sessionRootURL.path,
        noEmbedder: false,
        embedderChoice: "auto",
        requireVector: false,
        embedderOverride: StatsReasonEmbedder()
    )
    defer { Task { try? await service.close() } }

    let stats = await service.handle(.init(command: "stats", arguments: [:]))
    #expect(stats.ok == true)
    let payload = try requireObject(stats.payload)
    let status = try requireString(payload, "embeddingStatus")
    #expect(status == "degraded" || status == "unavailable")
    let reason = try requireString(payload, "embeddingStatusReason")
    #expect(reason.isEmpty == false)
}

@Test
func textSearchPreviewIsDehighlightedForHyphenatedToken() async throws {
    try await withIsolatedBroker { service, _ in
        let token = "STRESSCANARY-F91C3BFD"
        let write = await service.handle(.init(
            command: "remember",
            arguments: ["content": .string("Preview must contain \(token) exactly.")]
        ))
        #expect(write.ok == true)

        let search = await service.handle(.init(
            command: "search",
            arguments: [
                "query": .string(token),
                "mode": .string("text"),
                "topK": .int(5),
            ]
        ))
        #expect(search.ok == true)
        let results = try #require(try requireObject(search.payload)["results"]?.arrayValue)
        let preview = results.compactMap { $0.objectValue?["preview"]?.stringValue }.joined(separator: "\n")
        #expect(preview.contains(token))
        #expect(preview.contains("[STRESSCANARY]-[F91C3BFD]") == false)

        let corpus = await service.handle(.init(
            command: "corpus_search",
            arguments: [
                "query": .string(token),
                "mode": .string("text"),
                "topK": .int(5),
                "rebuild": .bool(true),
            ]
        ))
        #expect(corpus.ok == true)
        let corpusPreview = (try requireObject(corpus.payload)["results"]?.arrayValue ?? [])
            .compactMap { $0.objectValue?["preview"]?.stringValue }
            .joined(separator: "\n")
        #expect(corpusPreview.contains(token))
        #expect(corpusPreview.contains("[STRESSCANARY]-[F91C3BFD]") == false)
    }
}

@Test
func knowledgeCaptureReturnsEntityIdOrSkipReasonWhenKindMissing() async throws {
    try await withIsolatedBroker { service, _ in
        let upsert = await service.handle(.init(
            command: "entity_upsert",
            arguments: [
                "key": .string("subject:existing"),
                "kind": .string("concept"),
            ]
        ))
        #expect(upsert.ok == true)
        let existingID = try #require(try requireObject(upsert.payload)["entity_id"]?.intValue)

        let captureExisting = await service.handle(.init(
            command: "knowledge_capture",
            arguments: [
                "content": .string("Existing subject should resolve without kind."),
                "subject": .string("subject:existing"),
            ]
        ))
        #expect(captureExisting.ok == true)
        let existingPayload = try requireObject(captureExisting.payload)
        #expect(existingPayload["entity_id"]?.intValue == existingID)

        let captureMissing = await service.handle(.init(
            command: "knowledge_capture",
            arguments: [
                "content": .string("Missing subject should explain why entity was skipped."),
                "subject": .string("subject:missing"),
            ]
        ))
        #expect(captureMissing.ok == true)
        let missingPayload = try requireObject(captureMissing.payload)
        if missingPayload["entity_id"] == nil || missingPayload["entity_id"] == .null {
            let reason = try requireString(missingPayload, "entity_skipped_reason")
            #expect(reason.isEmpty == false)
        }
    }
}

@Test
func markdownExportWithProjectOmitsOtherProjectsNotes() async throws {
    try await withIsolatedBroker { service, _ in
        let keep = await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("KEEP-PROJECT note for markdown export"),
                "project": .string("KeepProj"),
                "durability": .string("durable"),
            ]
        ))
        let drop = await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("DROP-PROJECT note for markdown export"),
                "project": .string("DropProj"),
                "durability": .string("durable"),
            ]
        ))
        #expect(keep.ok == true)
        #expect(drop.ok == true)

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-md-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let export = await service.handle(.init(
            command: "markdown_export",
            arguments: [
                "output_dir": .string(outputURL.path),
                "project": .string("KeepProj"),
            ]
        ))
        #expect(export.ok == true)
        let memoryPath = try requireString(try requireObject(export.payload), "memory_md_path")
        let text = try String(contentsOfFile: memoryPath, encoding: .utf8)
        #expect(text.contains("KEEP-PROJECT"))
        #expect(text.contains("DROP-PROJECT") == false)
    }
}

@Test
func rememberOversizeIsRejectedWithTypedContentLimit() async throws {
    try await withIsolatedBroker { service, _ in
        let oversized = String(repeating: "a", count: 131_073)
        let result = await service.handle(.init(
            command: "remember",
            arguments: ["content": .string(oversized)]
        ))
        #expect(result.ok == false)
        let message = result.error ?? ""
        #expect(message.contains("131072") || message.localizedCaseInsensitiveContains("maxContent"))
    }
}

@Test
func waxMCPServerCommandAdvertisesVersionAndHTTPBodyCap() throws {
    #expect(WaxMCPServerCommand.configuration.version == WaxMCPServerMetadata.version)
    let command = try WaxMCPServerCommand.parse([])
    #expect(command.httpMaxBodyBytes == 1_048_576)
}
#endif
