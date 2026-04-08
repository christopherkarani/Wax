import Foundation
import Dispatch
import Testing
import Wax
@testable import wax_cli

@Suite("WaxCLI Memory Commands", .serialized)
struct WaxCLIMemoryTests {

    // MARK: - Test helper

    private func withCLIMemory(
        _ body: @Sendable (MemoryOrchestrator) async throws -> Void
    ) async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-cli-tests-\(UUID().uuidString)")
            .appendingPathExtension("wax")
        defer { try? FileManager.default.removeItem(at: url) }

        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.enableStructuredMemory = true
        config.chunking = .tokenCount(targetTokens: 16, overlapTokens: 2)
        config.rag = FastRAGConfig(
            maxContextTokens: 120,
            expansionMaxTokens: 60,
            snippetMaxTokens: 30,
            maxSnippets: 8,
            searchTopK: 20,
            searchMode: .textOnly
        )

        let memory = try await MemoryOrchestrator(at: url, config: config)
        var deferredError: Error?
        do {
            try await body(memory)
        } catch {
            deferredError = error
        }
        do {
            try await memory.close()
        } catch {
            if deferredError == nil { deferredError = error }
        }
        if let deferredError { throw deferredError }
    }

    // MARK: - Tests

    @Test func rememberFlushRecallRoundTrip() async throws {
        try await withCLIMemory { memory in
            try await memory.remember(
                "Swift actors isolate mutable state for concurrency safety.",
                metadata: ["source": "cli-test"]
            )
            try await memory.flush()

            let context = try await memory.recall(query: "actors", frameFilter: nil)
            #expect(context.items.count > 0, "recall should return at least one item after remember + flush")
            #expect(context.items.contains { $0.text.contains("actors") },
                    "recall items should contain the remembered content")
        }
    }

    @Test func searchReturnsHits() async throws {
        try await withCLIMemory { memory in
            try await memory.remember(
                "The Wax storage engine uses WAL for durability.",
                metadata: ["source": "cli-test"]
            )
            try await memory.flush()

            let hits = try await memory.search(query: "WAL durability", mode: .text, topK: 10, frameFilter: nil)
            #expect(hits.count > 0, "search should return at least one hit")
            #expect(hits[0].score > 0, "search hit score should be greater than zero")
        }
    }

    @Test func statsReportsFrameCount() async throws {
        try await withCLIMemory { memory in
            try await memory.remember(
                "Frame count test content for CLI integration.",
                metadata: ["source": "cli-test"]
            )
            try await memory.flush()

            let stats = await memory.runtimeStats()
            #expect(stats.frameCount > 0, "frameCount should be greater than zero after remember + flush")
        }
    }

    @Test func handoffRoundTrip() async throws {
        try await withCLIMemory { memory in
            let _ = try await memory.rememberHandoff(
                content: "Carry over refactor checkpoints from session A.",
                project: "wax-cli",
                pendingTasks: ["add graph tests", "measure ranking drift"],
                sessionId: nil
            )
            try await memory.flush()

            let latest = try await memory.latestHandoff(project: "wax-cli")
            #expect(latest != nil, "latestHandoff should return a record after rememberHandoff + flush")
            #expect(latest?.content.contains("Carry over refactor checkpoints") == true)
            #expect(latest?.pendingTasks.count == 2)
            #expect(latest?.pendingTasks.contains("add graph tests") == true)
            #expect(latest?.pendingTasks.contains("measure ranking drift") == true)
            #expect(latest?.project == "wax-cli")
        }
    }

    @Test func latestHandoffPrefersLatestProjectScopedRecord() async throws {
        try await withCLIMemory { memory in
            let _ = try await memory.rememberHandoff(
                content: "Initial wax-cli handoff.",
                project: "wax-cli",
                pendingTasks: ["stage baseline"]
            )
            let _ = try await memory.rememberHandoff(
                content: "Different project handoff.",
                project: "other-project",
                pendingTasks: ["ignore for scoped lookup"]
            )
            let _ = try await memory.rememberHandoff(
                content: "Latest wax-cli handoff.",
                project: "wax-cli",
                pendingTasks: ["ship benchmark"]
            )
            try await memory.flush()

            let scoped = try await memory.latestHandoff(project: "wax-cli")
            let unfiltered = try await memory.latestHandoff()
            let emptyProject = try await memory.latestHandoff(project: "")

            #expect(scoped?.content.contains("Latest wax-cli handoff.") == true)
            #expect(scoped?.pendingTasks == ["ship benchmark"])
            #expect(scoped?.project == "wax-cli")
            #expect(unfiltered?.frameId == scoped?.frameId)
            #expect(emptyProject?.frameId == unfiltered?.frameId)
        }
    }

    @Test func entityUpsertAndResolveRoundTrip() async throws {
        try await withCLIMemory { memory in
            let entityID = try await memory.upsertEntity(
                key: EntityKey("agent:codex"),
                kind: "agent",
                aliases: ["codex", "assistant"],
                commit: true
            )
            #expect(entityID.rawValue > 0, "upsertEntity should return a positive entity ID")

            let matches = try await memory.resolveEntities(matchingAlias: "codex", limit: 10)
            #expect(matches.count > 0, "resolveEntities should find at least one match for the alias")
            #expect(matches[0].key.rawValue == "agent:codex")
            #expect(matches[0].kind == "agent")
        }
    }

    @Test func factAssertQueryRetractRoundTrip() async throws {
        try await withCLIMemory { memory in
            // Ensure entity exists for the fact subject
            let _ = try await memory.upsertEntity(
                key: EntityKey("agent:codex"),
                kind: "agent",
                aliases: ["codex"],
                commit: true
            )

            // Assert a fact
            let factID = try await memory.assertFact(
                subject: EntityKey("agent:codex"),
                predicate: PredicateKey("learned"),
                object: .string("patches"),
                validFromMs: nil,
                validToMs: nil,
                commit: true
            )
            #expect(factID.rawValue > 0, "assertFact should return a positive fact ID")

            // Query facts -- should find the asserted fact
            let result = try await memory.facts(
                about: EntityKey("agent:codex"),
                predicate: nil,
                asOfMs: Int64.max,
                limit: 20
            )
            #expect(result.hits.count > 0, "facts query should return at least one hit")
            #expect(result.hits[0].factId == factID)
            #expect(result.hits[0].fact.subject == EntityKey("agent:codex"))
            #expect(result.hits[0].fact.predicate == PredicateKey("learned"))
            #expect(result.hits[0].fact.object == .string("patches"))

            // Retract the fact
            try await memory.retractFact(factId: factID, atMs: nil, commit: true)

            // Query again -- should be empty now
            let afterRetract = try await memory.facts(
                about: EntityKey("agent:codex"),
                predicate: nil,
                asOfMs: Int64.max,
                limit: 20
            )
            #expect(afterRetract.hits.isEmpty, "facts query should be empty after retraction")
        }
    }

    @Test func orchestratorOpenFailsFastWhenStoreIsLocked() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-cli-lock-timeout-\(UUID().uuidString)")
            .appendingPathExtension("wax")
        defer { try? FileManager.default.removeItem(at: url) }

        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.enableStructuredMemory = true
        config.rag.searchMode = .textOnly

        let holder = try await MemoryOrchestrator(at: url, config: config)
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let contender = try await MemoryOrchestrator(
                at: url,
                config: config,
                waxOptions: WaxOptions(lockWaitTimeout: .milliseconds(150))
            )
            try await contender.close()
            Issue.record("expected second orchestrator open to time out")
        } catch {
            let elapsed = start.duration(to: clock.now)
            #expect(elapsed < .seconds(2))
            #expect(error.localizedDescription.contains("timed out waiting for exclusive lock"))
        }
        try await holder.close()
    }

    @Test func vectorRequiredOpenRejectsNoEmbedderFlag() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-cli-require-vector-\(UUID().uuidString)")
            .appendingPathExtension("wax")
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            let memory = try await StoreSession.open(
                at: url,
                noEmbedder: true,
                requireVector: true
            )
            try await memory.close()
            Issue.record("expected vector-required open to fail when --no-embedder is set")
        } catch {
            #expect(error.localizedDescription.contains("Vector search required"))
            #expect(error.localizedDescription.contains("--no-embedder"))
        }
    }

    @Test func agentDaemonPolicyPrefersDaemonForVectorCommands() throws {
        let vectorStore = try VectorStoreOptions.parse([])
        let textStore = try VectorStoreOptions.parse(["--no-embedder"])

        #expect(AgentDaemonPolicy.shouldUseDaemonForRemember(store: vectorStore))
        #expect(AgentDaemonPolicy.shouldUseDaemonForRecall(store: vectorStore))
        #expect(AgentDaemonPolicy.shouldUseDaemonForSearch(store: vectorStore, mode: "hybrid"))
        #expect(!AgentDaemonPolicy.shouldUseDaemonForSearch(store: vectorStore, mode: "text"))
        #expect(!AgentDaemonPolicy.shouldUseDaemonForRemember(store: textStore))
    }

    @Test func agentDaemonConfigurationUsesStableSocketPaths() throws {
        let daemonRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-cli-daemon-config-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: daemonRoot) }

        setenv("WAX_CLI_DAEMON_DIR", daemonRoot.path, 1)
        defer { unsetenv("WAX_CLI_DAEMON_DIR") }

        let first = try AgentDaemonTransport.configuration(
            storePath: "~/Library/Application Support/Wax/a.wax",
            embedderChoice: .minilm
        )
        let second = try AgentDaemonTransport.configuration(
            storePath: "~/Library/Application Support/Wax/a.wax",
            embedderChoice: .minilm
        )
        let arctic = try AgentDaemonTransport.configuration(
            storePath: "~/Library/Application Support/Wax/a.wax",
            embedderChoice: .arctic
        )

        #expect(first.socketPath == second.socketPath)
        #expect(first.socketPath != arctic.socketPath)
        #expect(first.socketPath.hasPrefix(daemonRoot.path))
    }

    @Test func agentDaemonConfigurationChangesWhenBinaryIdentityChanges() throws {
        let daemonRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-cli-daemon-identity-\(UUID().uuidString)", isDirectory: true)
        let binariesRoot = daemonRoot.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binariesRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: daemonRoot) }

        setenv("WAX_CLI_DAEMON_DIR", daemonRoot.path, 1)
        defer { unsetenv("WAX_CLI_DAEMON_DIR") }

        let firstCLI = binariesRoot.appendingPathComponent("wax-cli-a")
        let secondCLI = binariesRoot.appendingPathComponent("wax-cli-b")
        try Data("v1".utf8).write(to: firstCLI)
        try Data("v2-with-different-size".utf8).write(to: secondCLI)

        let first = try AgentDaemonTransport.configuration(
            storePath: "~/Library/Application Support/Wax/a.wax",
            embedderChoice: .minilm,
            cliPathOverride: firstCLI.path
        )
        let second = try AgentDaemonTransport.configuration(
            storePath: "~/Library/Application Support/Wax/a.wax",
            embedderChoice: .minilm,
            cliPathOverride: secondCLI.path
        )

        #expect(first.socketPath != second.socketPath)
    }

    @Test func agentDaemonConfigurationResolvesWaxSymlinkIntoBundledCLI() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-cli-symlink-layout-\(UUID().uuidString)", isDirectory: true)
        let runtime = root.appendingPathComponent("runtime/darwin-arm64", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let cli = runtime.appendingPathComponent("wax-cli")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)

        let waxSymlink = bin.appendingPathComponent("wax")
        try FileManager.default.createSymbolicLink(at: waxSymlink, withDestinationURL: cli)

        let resolved = AgentBrokerPathing.resolveBrokerCLIPath(currentExecutablePath: waxSymlink.path)
        #expect(resolved == cli.path)
    }

    @Test func daemonSessionHandlesPersistentRoundTripCommands() async throws {
        try await withCLIMemory { memory in
            let daemon = CLIDaemonSession(memory: memory)

            let remember = await daemon.handle(
                CLIDaemonRequest(
                    id: "1",
                    command: "remember",
                    content: "Wax daemon keeps one orchestrator open for repeated CLI requests.",
                    query: nil,
                    metadata: ["source": "daemon-test"],
                    mode: nil,
                    topK: nil,
                    limit: nil
                )
            )
            #expect(remember.ok)
            if case .remember(let frameCount, let pendingFrames, let framesAdded)? = remember.payload {
                #expect(frameCount > 0)
                #expect(pendingFrames == 0)
                #expect(framesAdded > 0)
            } else {
                Issue.record("expected remember payload")
            }

            let search = await daemon.handle(
                CLIDaemonRequest(
                    id: "2",
                    command: "search",
                    content: nil,
                    query: "orchestrator open",
                    metadata: nil,
                    mode: "text",
                    topK: 5,
                    limit: nil
                )
            )
            #expect(search.ok)
            if case .search(let count, let items)? = search.payload {
                #expect(count > 0)
                #expect(items.contains { ($0.preview ?? "").localizedCaseInsensitiveContains("orchestrator") })
            } else {
                Issue.record("expected search payload")
            }

            let recall = await daemon.handle(
                CLIDaemonRequest(
                    id: "3",
                    command: "recall",
                    content: nil,
                    query: "daemon",
                    metadata: nil,
                    mode: nil,
                    topK: nil,
                    limit: 3
                )
            )
            #expect(recall.ok)
            if case .recall(let query, _, let items)? = recall.payload {
                #expect(query == "daemon")
                #expect(items.count > 0)
                #expect(items.contains { ($0.text ?? "").localizedCaseInsensitiveContains("daemon") })
            } else {
                Issue.record("expected recall payload")
            }

            let shutdown = await daemon.handle(
                CLIDaemonRequest(
                    id: "4",
                    command: "shutdown",
                    content: nil,
                    query: nil,
                    metadata: nil,
                    mode: nil,
                    topK: nil,
                    limit: nil
                )
            )
            #expect(shutdown.ok)
            #expect(shutdown.shouldExit)
            if case .shutdown? = shutdown.payload {
                // expected
            } else {
                Issue.record("expected shutdown payload")
            }
        }
    }

    @Test func mcpInstallStagesBundledRuntimeIntoStableDirectory() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-cli-install-stage-\(UUID().uuidString)", isDirectory: true)
        let sourceDir = tempRoot.appendingPathComponent("dist/darwin-arm64", isDirectory: true)
        let installRoot = tempRoot.appendingPathComponent("install-root", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try makeExecutableStub(at: sourceDir.appendingPathComponent("wax-cli"))
        try makeExecutableStub(at: sourceDir.appendingPathComponent("wax-mcp"))
        try writeChecksumFile(for: sourceDir.appendingPathComponent("wax-cli"))
        try writeChecksumFile(for: sourceDir.appendingPathComponent("wax-mcp"))
        try FileManager.default.createDirectory(
            at: sourceDir.appendingPathComponent("Wax_WaxVectorSearchMiniLM.bundle", isDirectory: true),
            withIntermediateDirectories: true
        )

        setenv("WAX_MCP_INSTALL_ROOT", installRoot.path, 1)
        defer { unsetenv("WAX_MCP_INSTALL_ROOT") }

        let runtime = try Pathing.prepareMCPInstallRuntime(
            cliPath: sourceDir.appendingPathComponent("wax-cli").path,
            serverPath: sourceDir.appendingPathComponent("wax-mcp").path,
            dryRun: false
        )

        let expectedDir = installRoot.appendingPathComponent("darwin-arm64", isDirectory: true)
        #expect(runtime.staged)
        #expect(runtime.cliPath == expectedDir.appendingPathComponent("wax-cli").path)
        #expect(runtime.serverPath == expectedDir.appendingPathComponent("wax-mcp").path)
        #expect(FileManager.default.isExecutableFile(atPath: runtime.cliPath))
        #expect(FileManager.default.isExecutableFile(atPath: runtime.serverPath))
        #expect(
            FileManager.default.fileExists(
                atPath: expectedDir
                    .appendingPathComponent("Wax_WaxVectorSearchMiniLM.bundle", isDirectory: true)
                    .path
            )
        )

        let validation = try Pathing.validateMCPRuntime(
            serverPath: runtime.serverPath,
            expectVectorRuntime: true
        )
        #expect(validation.failures.isEmpty)
    }

    @Test func mcpInstallLeavesNonBundledPathsUntouched() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-cli-install-local-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let cli = tempRoot.appendingPathComponent("wax-cli")
        let server = tempRoot.appendingPathComponent("wax-mcp")
        try makeExecutableStub(at: cli)
        try makeExecutableStub(at: server)

        let runtime = try Pathing.prepareMCPInstallRuntime(
            cliPath: cli.path,
            serverPath: server.path,
            dryRun: false
        )

        #expect(!runtime.staged)
        #expect(runtime.cliPath == cli.path)
        #expect(runtime.serverPath == server.path)
    }

    @Test func embedderRuntimeOptionsOverrideEnvironment() throws {
        setenv("WAX_EMBEDDER_BATCH_SIZE", "2", 1)
        setenv("WAX_EMBEDDER_PREWARM_BATCH_SIZE", "3", 1)
        setenv("WAX_EMBEDDER_ALLOW_LOW_PRECISION_GPU", "1", 1)
        setenv("WAX_EMBEDDER_TIMEOUT_SECS", "7", 1)
        setenv("WAX_EMBEDDER_COMPUTE_UNITS", "cpuOnly", 1)
        defer {
            unsetenv("WAX_EMBEDDER_BATCH_SIZE")
            unsetenv("WAX_EMBEDDER_PREWARM_BATCH_SIZE")
            unsetenv("WAX_EMBEDDER_ALLOW_LOW_PRECISION_GPU")
            unsetenv("WAX_EMBEDDER_TIMEOUT_SECS")
            unsetenv("WAX_EMBEDDER_COMPUTE_UNITS")
        }

        let store = try VectorStoreOptions.parse([
            "--embedder-batch-size", "8",
            "--embedder-prewarm-batch-size", "5",
            "--embedder-low-precision-gpu", "false",
            "--embedder-timeout-secs", "11",
            "--embedder-compute-unit", "cpuAndGPU",
            "--embedder-compute-unit", "cpuOnly",
        ])

        let tuning = store.embedderTuning
        #expect(tuning.batchSize == 8)
        #expect(tuning.prewarmBatchSize == 5)
        #expect(tuning.allowLowPrecisionGPU == false)
        #expect(tuning.timeoutSeconds == 11)
        #expect(tuning.computeUnitsOrder.map(\.rawValue) == ["cpuAndGPU", "cpuOnly"])
    }

    @Test func brokerConfigurationChangesWhenEmbedderTuningChanges() throws {
        let first = try AgentBrokerCLI.configuration(
            storePath: "~/Library/Application Support/Wax/a.wax",
            embedderChoice: "minilm",
            noEmbedder: false,
            requireVector: false,
            embedderTuning: .init(batchSize: 1)
        )
        let second = try AgentBrokerCLI.configuration(
            storePath: "~/Library/Application Support/Wax/a.wax",
            embedderChoice: "minilm",
            noEmbedder: false,
            requireVector: false,
            embedderTuning: .init(batchSize: 8)
        )

        #expect(first.socketPath != second.socketPath)
    }

    @Test func brokerConfigurationChangesWhenRequireVectorChanges() throws {
        let first = try AgentBrokerCLI.configuration(
            storePath: "~/Library/Application Support/Wax/a.wax",
            embedderChoice: "minilm",
            noEmbedder: false,
            requireVector: false,
            embedderTuning: .init(batchSize: 1)
        )
        let second = try AgentBrokerCLI.configuration(
            storePath: "~/Library/Application Support/Wax/a.wax",
            embedderChoice: "minilm",
            noEmbedder: false,
            requireVector: true,
            embedderTuning: .init(batchSize: 1)
        )

        #expect(first.socketPath != second.socketPath)
    }

    @Test func brokerBackedVectorRequirementFailsFastWhenNoEmbedderIsConfigured() async throws {
        let brokerRoot = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("wxbv-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let storeURL = brokerRoot.appendingPathComponent("vector-required.wax")
        defer { try? FileManager.default.removeItem(at: brokerRoot) }

        setenv("WAX_BROKER_DIR", brokerRoot.path, 1)
        defer { unsetenv("WAX_BROKER_DIR") }

        let brokerConfiguration = try AgentBrokerPathing.configuration(
            brokerExecutablePath: try builtProductPath(named: "wax-cli"),
            storePath: storeURL.path,
            embedderChoice: "minilm",
            noEmbedder: true,
            requireVector: true
        )

        do {
            _ = try await AgentBrokerClient.perform(
                request: AgentBrokerRequest(command: "stats"),
                configuration: brokerConfiguration,
                shutdownIfStarted: true
            )
            Issue.record("Expected broker-backed stats to fail when vector search is required and --no-embedder is set")
        } catch {
            #expect(error.localizedDescription.contains("Vector search required"))
            #expect(error.localizedDescription.contains("--no-embedder"))
        }
    }

    @Test func brokerBackedOneShotCommandReleasesStoreLockImmediately() async throws {
        let brokerRoot = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("wxbs-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let storeURL = brokerRoot.appendingPathComponent("one-shot-stats.wax")
        defer { try? FileManager.default.removeItem(at: brokerRoot) }

        setenv("WAX_BROKER_DIR", brokerRoot.path, 1)
        setenv("WAX_LOCK_TIMEOUT_SECS", "0.2", 1)
        defer {
            unsetenv("WAX_BROKER_DIR")
            unsetenv("WAX_LOCK_TIMEOUT_SECS")
        }

        let configuration = try AgentBrokerPathing.configuration(
            brokerExecutablePath: try builtProductPath(named: "wax-cli"),
            storePath: storeURL.path,
            embedderChoice: "minilm",
            noEmbedder: true,
            requireVector: false
        )

        let response = try await AgentBrokerClient.perform(
            request: AgentBrokerRequest(command: "stats"),
            configuration: configuration,
            shutdownIfStarted: true
        )
        #expect(response.ok)

        #expect(!FileManager.default.fileExists(atPath: configuration.socketPath))

        let reopened = try await StoreSession.open(at: storeURL, noEmbedder: true)
        try await reopened.close()
    }

    @Test func mcpInstallRejectsBundledRuntimeWithChecksumMismatch() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-cli-install-bad-checksum-\(UUID().uuidString)", isDirectory: true)
        let sourceDir = tempRoot.appendingPathComponent("dist/darwin-arm64", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try makeExecutableStub(at: sourceDir.appendingPathComponent("wax-cli"))
        try makeExecutableStub(at: sourceDir.appendingPathComponent("wax-mcp"))
        try "deadbeef  wax-cli\n".write(
            to: sourceDir.appendingPathComponent("wax-cli.sha256"),
            atomically: true,
            encoding: .utf8
        )

        do {
            _ = try Pathing.prepareMCPInstallRuntime(
                cliPath: sourceDir.appendingPathComponent("wax-cli").path,
                serverPath: sourceDir.appendingPathComponent("wax-mcp").path,
                dryRun: false
            )
            Issue.record("Expected prepareMCPInstallRuntime to reject checksum mismatch")
        } catch {
            #expect(error.localizedDescription.contains("checksum mismatch"))
        }
    }

    @Test func runtimeValidationDetectsChecksumMismatch() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-cli-runtime-validate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let cli = tempRoot.appendingPathComponent("wax-cli")
        let server = tempRoot.appendingPathComponent("wax-mcp")
        try makeExecutableStub(at: cli)
        try makeExecutableStub(at: server)
        try "deadbeef  wax-mcp\n".write(
            to: tempRoot.appendingPathComponent("wax-mcp.sha256"),
            atomically: true,
            encoding: .utf8
        )

        let validation = try Pathing.validateMCPRuntime(
            serverPath: server.path,
            expectVectorRuntime: false
        )
        #expect(validation.failures.contains { $0.contains("checksum mismatch for wax-mcp") })
    }

    @Test func entityUpsertNoCommitFallsBackToDirectStore() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-cli-commit-flag-\(UUID().uuidString)", isDirectory: true)
        let storeURL = tempRoot.appendingPathComponent("commit-flag.wax")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let cli = try builtProductPath(named: "wax-cli")
        let output = try runProcess(
            executableURL: URL(fileURLWithPath: cli),
            arguments: [
                "entity-upsert",
                "--store-path", storeURL.path,
                "--key", "agent:commit-flag",
                "--kind", "agent",
                "--no-commit",
            ],
            timeout: 20
        )

        #expect(output.status == EXIT_SUCCESS, "wax-cli entity-upsert should succeed")
        #expect(output.stdout.contains(#""committed" : false"#))
    }

    @Test func mcpDoctorRecognizesRenamedToolSurface() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-cli-doctor-\(UUID().uuidString)", isDirectory: true)
        let storeURL = tempRoot.appendingPathComponent("doctor.wax")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let cli = try builtProductPath(named: "wax-cli")
        let server = try builtProductPath(named: "wax-mcp")
        let output = try runProcess(
            executableURL: URL(fileURLWithPath: cli),
            arguments: [
                "mcp", "doctor",
                "--server-path", server,
                "--store-path", storeURL.path,
                "--no-embedder",
            ],
            timeout: 60
        )

        #expect(output.status == EXIT_SUCCESS, "wax-cli mcp doctor should pass against the renamed tool surface")
        #expect(output.stdout.contains("Doctor passed."))
    }

    @Test func pathLaunchedWaxMCPResolvesSiblingWaxCLIFromPath() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-mcp-path-launch-\(UUID().uuidString)", isDirectory: true)
        let runtimeDir = tempRoot.appendingPathComponent("runtime/bin", isDirectory: true)
        let shadowDir = tempRoot.appendingPathComponent("shadow/bin", isDirectory: true)
        let workDir = tempRoot.appendingPathComponent("work", isDirectory: true)
        let storeURL = tempRoot.appendingPathComponent("path-launch.wax")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try FileManager.default.createDirectory(at: runtimeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: shadowDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let cli = try builtProductPath(named: "wax-cli")
        let server = try builtProductPath(named: "wax-mcp")
        let runtimeCLI = runtimeDir.appendingPathComponent("wax-cli")
        let runtimeServer = runtimeDir.appendingPathComponent("wax-mcp")
        try FileManager.default.createSymbolicLink(at: runtimeCLI, withDestinationURL: URL(fileURLWithPath: cli))
        try FileManager.default.createSymbolicLink(at: runtimeServer, withDestinationURL: URL(fileURLWithPath: server))

        let fakeCLI = shadowDir.appendingPathComponent("wax-cli")
        try "#!/bin/sh\nexit 17\n".write(to: fakeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: fakeCLI.path
        )

        let output = try runMCPSmokeProcess(
            command: "wax-mcp",
            arguments: [
                "--store-path", storeURL.path,
                "--no-embedder",
            ],
            environment: [
                "PATH": "\(shadowDir.path):\(runtimeDir.path)",
            ],
            currentDirectoryURL: workDir,
            expectedToolName: "remember",
            timeout: 20
        )

        #expect(output.status == EXIT_SUCCESS, "PATH-launched wax-mcp should resolve its colocated wax-cli")
        #expect(output.stdout.contains(#""name":"remember""#))
        #expect(!output.stdout.contains(#""name":"wax_remember""#))
    }

    private func makeExecutableStub(at url: URL) throws {
        try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: url.path
        )
    }

    private func writeChecksumFile(for executableURL: URL) throws {
        let output = try runProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/shasum"),
            arguments: ["-a", "256", executableURL.path]
        )
        guard output.status == EXIT_SUCCESS,
              let token = output.stdout.split(whereSeparator: \.isWhitespace).first else {
            throw CLIError("Unable to compute checksum for \(executableURL.path)")
        }
        let contents = "\(token)  \(executableURL.lastPathComponent)\n"
        try contents.write(
            to: executableURL.deletingPathExtension().appendingPathExtension("sha256"),
            atomically: true,
            encoding: String.Encoding.utf8
        )
    }

    private struct ProcessOutput {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private func builtProductPath(named name: String) throws -> String {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let candidates = [
            root.appendingPathComponent(".build/debug/\(name)").path,
            root.appendingPathComponent(".build/arm64-apple-macosx/debug/\(name)").path,
        ]
        if let match = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return match
        }
        throw CLIError("Unable to locate built product '\(name)'")
    }

    private func runProcess(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectoryURL: URL? = nil,
        input: String? = nil,
        timeout: TimeInterval = 15
    ) throws -> ProcessOutput {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        var mergedEnvironment = ProcessInfo.processInfo.environment
        if let environment {
            for (key, value) in environment {
                mergedEnvironment[key] = value
            }
        }
        process.environment = mergedEnvironment
        process.currentDirectoryURL = currentDirectoryURL

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdinPipe: Pipe?
        if input != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            stdinPipe = pipe
        } else {
            stdinPipe = nil
        }

        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }

        try process.run()

        if let input, let stdinPipe {
            if let data = input.data(using: .utf8) {
                stdinPipe.fileHandleForWriting.write(data)
            }
            try? stdinPipe.fileHandleForWriting.close()
        }

        if terminated.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            process.waitUntilExit()
            throw CLIError("Process timed out: \(executableURL.path) \(arguments.joined(separator: " "))")
        }

        process.waitUntilExit()

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcessOutput(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    private func runMCPSmokeProcess(
        command: String,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectoryURL: URL? = nil,
        expectedToolName: String,
        timeout: TimeInterval = 15
    ) throws -> ProcessOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + arguments
        var mergedEnvironment = ProcessInfo.processInfo.environment
        if let environment {
            for (key, value) in environment {
                mergedEnvironment[key] = value
            }
        }
        process.environment = mergedEnvironment
        process.currentDirectoryURL = currentDirectoryURL

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        final class SmokeState: @unchecked Sendable {
            private let lock = NSLock()
            private var stdoutAll = Data()
            private var stderrAll = Data()
            private var stdoutPending = Data()
            private var sawToolsList = false
            private var foundExpectedTool = false
            private var signaled = false
            let semaphore = DispatchSemaphore(value: 0)

            func appendStdout(_ data: Data, expectedToolName: String) {
                lock.lock()
                defer { lock.unlock() }
                stdoutAll.append(data)
                stdoutPending.append(data)
                while let newlineIndex = stdoutPending.firstIndex(of: UInt8(ascii: "\n")) {
                    let lineData = stdoutPending[..<newlineIndex]
                    stdoutPending = stdoutPending[(newlineIndex + 1)...]
                    guard let line = String(data: lineData, encoding: .utf8), !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        continue
                    }
                    if !sawToolsList, (line.contains(#""id":2"#) || line.contains(#""id": 2"#)) {
                        sawToolsList = true
                        foundExpectedTool = line.contains(#""name":"\#(expectedToolName)""#)
                        signalOnce()
                        return
                    }
                }
            }

            func appendStderr(_ data: Data) {
                lock.lock()
                defer { lock.unlock() }
                stderrAll.append(data)
            }

            func snapshot() -> (stdout: Data, stderr: Data, foundExpectedTool: Bool) {
                lock.lock()
                defer { lock.unlock() }
                return (stdoutAll, stderrAll, foundExpectedTool)
            }

            private func signalOnce() {
                guard !signaled else { return }
                signaled = true
                semaphore.signal()
            }
        }

        let state = SmokeState()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                return
            }
            state.appendStdout(data, expectedToolName: expectedToolName)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                return
            }
            state.appendStderr(data)
        }

        try process.run()

        let request = """
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"wax-mcp-path-test","version":"1.0"}}}
        {"jsonrpc":"2.0","method":"notifications/initialized","params":{}}
        {"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
        """
        if let data = (request + "\n").data(using: .utf8) {
            stdinPipe.fileHandleForWriting.write(data)
        }

        if state.semaphore.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            process.waitUntilExit()
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw CLIError("Timed out waiting for MCP tools/list response")
        }

        try? stdinPipe.fileHandleForWriting.close()
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        process.waitUntilExit()

        if let data = try? stdoutPipe.fileHandleForReading.readToEnd() {
            state.appendStdout(data, expectedToolName: expectedToolName)
        }
        if let data = try? stderrPipe.fileHandleForReading.readToEnd() {
            state.appendStderr(data)
        }

        let snapshot = state.snapshot()
        let stdout = String(data: snapshot.stdout, encoding: .utf8) ?? ""
        let stderr = String(data: snapshot.stderr, encoding: .utf8) ?? ""
        return ProcessOutput(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}
