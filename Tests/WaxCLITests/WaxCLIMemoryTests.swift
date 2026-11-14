import Foundation
import Dispatch
import Testing
import WaxCore
@testable import Wax
@testable import WaxCore
@testable import wax_cli
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if MCPServer
private let mcpServerTraitEnabled = true
#else
private let mcpServerTraitEnabled = false
#endif

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

    @Test func singleChunkRememberAddsOneFrame() async throws {
        try await withCLIMemory { memory in
            let content = "cli canary-7f3a91 single-chunk remember"
            let before = await memory.runtimeStats()
            try await memory.remember(content, metadata: ["source": "cli-single-chunk"])
            try await memory.flush()
            let after = await memory.runtimeStats()
            let added = after.frameCount - before.frameCount
            #expect(added == 1)
            #expect(after.frameCount == before.frameCount + 1)

            try await memory.remember(content, metadata: ["source": "cli-single-chunk"])
            try await memory.flush()
            let afterDuplicate = await memory.runtimeStats()
            #expect(afterDuplicate.frameCount == after.frameCount)
        }
    }

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

            let hits = try await memory.search(query: "WAL durability", mode: .textOnly, topK: 10, frameFilter: nil)
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

    // The time limit is the hang backstop for an ignored lock wait.
    @Test(.timeLimit(.minutes(1)))
    func orchestratorOpenFailsFastWhenStoreIsLocked() async throws {
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
            // Structural: the configured 150ms wait was honored and reported.
            // No tight upper wall-clock bound — it flakes under `--parallel`;
            // the one-minute `.timeLimit` above fails a wait that never ends.
            #expect(elapsed >= .milliseconds(150))
            #expect(error.localizedDescription.contains("timed out waiting for exclusive lock"))
        }
        try await holder.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func vectorHealthFailsFastWhenStoreIsHeld() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-cli-vector-health-lock-\(UUID().uuidString)")
            .appendingPathExtension("wax")
        defer { try? FileManager.default.removeItem(at: url) }

        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.enableStructuredMemory = true
        config.rag.searchMode = .textOnly

        let holder = try await MemoryOrchestrator(at: url, config: config)
        do {
            let command = try VectorHealthCommand.parse([
                "--store-path", url.path,
                "--format", "json",
            ])
            try await command.runAsync()
            Issue.record("expected vector-health to fail while the store is held")
        } catch {
            // "Fails fast" is pinned structurally: the error comes from the
            // non-blocking lock probe, not from the timed lock wait (asserted
            // below via the absence of the timed-out message).
            let message = error.localizedDescription.lowercased()
            #expect(message.contains("exclusive lock"))
            #expect(message.contains("another process"))
            #expect(message.contains("waxmcp stats") || message.contains("attach"))
            #expect(message.contains("timed out waiting for exclusive lock") == false)
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

    @Test func directFactsQueryTextRendersSpanTemporalBounds() async throws {
        let executable = URL(fileURLWithPath: try builtProductPath(named: "wax-cli"))
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-cli-facts-text-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let storeURL = tempDir.appendingPathComponent("facts.wax")

        let assertOutput = try await runProcess(
            executableURL: executable,
            arguments: [
                "fact-assert",
                "--direct-store",
                "--no-embedder",
                "--store-path", storeURL.path,
                "--format", "text",
                "--subject", "project:f019-cli",
                "--predicate", "status",
                "--object", "active",
            ],
            timeout: 20
        )
        #expect(assertOutput.status == EXIT_SUCCESS, "fact-assert should succeed: \(assertOutput.stderr)")

        let queryOutput = try await runProcess(
            executableURL: executable,
            arguments: [
                "facts-query",
                "--direct-store",
                "--no-embedder",
                "--store-path", storeURL.path,
                "--format", "text",
                "--subject", "project:f019-cli",
                "--predicate", "status",
            ],
            timeout: 20
        )

        #expect(queryOutput.status == EXIT_SUCCESS, "facts-query should succeed: \(queryOutput.stderr)")
        #expect(queryOutput.stdout.contains("[1:1]"))
        #expect(queryOutput.stdout.contains("relation=sets"))
        #expect(queryOutput.stdout.contains("valid=["))
        #expect(queryOutput.stdout.contains("system=["))
        #expect(queryOutput.stdout.contains("..open]"))
    }

    @Test func directTaskStateMigrationUsesNativeFlags() async throws {
        let executable = URL(fileURLWithPath: try builtProductPath(named: "wax-cli"))
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-cli-task-state-migrate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let sourceURL = tempDir.appendingPathComponent("source.wax")
        let destinationURL = tempDir.appendingPathComponent("repaired.wax")

        let seed = try await runProcess(
            executableURL: executable,
            arguments: [
                "remember",
                "--direct-store",
                "--no-embedder",
                "--store-path", sourceURL.path,
                "--metadata", "wax.memory_type=task_state",
                "--metadata", "wax.durability=durable",
                "legacy task state",
            ],
            timeout: 20
        )
        #expect(seed.status == EXIT_SUCCESS, "seed remember should succeed: \(seed.stderr)")

        let dryRun = try await runProcess(
            executableURL: executable,
            arguments: [
                "task-state-migrate",
                "--direct-store",
                "--no-embedder",
                "--store-path", sourceURL.path,
                "--destination-path", destinationURL.path,
                "--dry-run",
            ],
            timeout: 30
        )
        #expect(dryRun.status == EXIT_SUCCESS, "task-state-migrate should accept native flags: \(dryRun.stderr)")
        #expect(dryRun.stdout.contains("quarantined_document_count"))
        #expect(!FileManager.default.fileExists(atPath: destinationURL.path))
    }

    @Test func directStatsAndFlushHonorRequireVectorWithNoEmbedder() async throws {
        let executable = URL(fileURLWithPath: try builtProductPath(named: "wax-cli"))
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-cli-direct-require-vector-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        for command in ["stats", "flush"] {
            let output = try await runProcess(
                executableURL: executable,
                arguments: [
                    command,
                    "--direct-store",
                    "--no-embedder",
                    "--require-vector",
                    "--store-path",
                    tempDir.appendingPathComponent("\(command).wax").path,
                ],
                timeout: 15
            )

            #expect(output.status != 0, "\(command) should fail when vector search is required but no embedder is configured")
            #expect((output.stderr + output.stdout).contains("Vector search required"))
            #expect((output.stderr + output.stdout).contains("--no-embedder"))
        }
    }

    @Test func invalidEmbedderRuntimeFlagsAreRejected() throws {
        let invalidArgumentSets = [
            ["--embedder-compute-unit", "definitelyInvalid"],
            ["--embedder-compute-unit", " "],
            ["--embedder-batch-size", "0"],
            ["--embedder-batch-size", "-1"],
            ["--embedder-prewarm-batch-size", "0"],
            ["--embedder-timeout-secs", "0"],
            ["--embedder-timeout-secs", "-0.1"],
        ]

        for arguments in invalidArgumentSets {
            #expect(throws: Error.self, "Expected invalid runtime arguments to be rejected: \(arguments)") {
                _ = try VectorStoreOptions.parse(arguments)
            }
        }
    }

    @Test func brokerShutdownCompletedTreatsHeldStoreLockAsIncomplete() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wx-shutdown-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let storeURL = root.appendingPathComponent("store.wax")
        #expect(FileManager.default.createFile(atPath: storeURL.path, contents: Data()))
        let missingSocket = root.appendingPathComponent("broker.sock").path

        let held = try FileLock.acquireExclusiveOrCreate(at: storeURL, timeout: .seconds(1))
        defer { try? held.release() }

        let stillBusy = try AgentBrokerClient.brokerShutdownCompleted(
            socketPath: missingSocket,
            storePath: storeURL.path
        )
        #expect(stillBusy == false)

        try held.release()
        let released = try AgentBrokerClient.brokerShutdownCompleted(
            socketPath: missingSocket,
            storePath: storeURL.path
        )
        #expect(released == true)
    }

    @Test func brokerStatsHonorAccessStatsFeatureFlag() async throws {
        let brokerRoot = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("wxas-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let storeURL = brokerRoot.appendingPathComponent("access-stats.wax")
        defer { try? FileManager.default.removeItem(at: brokerRoot) }

        let cli = try builtProductPath(named: "wax-cli")
        let output = try await runProcess(
            executableURL: URL(fileURLWithPath: cli),
            arguments: [
                "stats",
                "--store-path", storeURL.path,
                "--no-embedder",
                "--format", "json",
            ],
            environment: [
                "WAX_BROKER_DIR": brokerRoot.path,
                "WAX_MCP_FEATURE_ACCESS_STATS": "1",
            ],
            timeout: 20
        )

        #expect(output.status == EXIT_SUCCESS, "broker-backed stats should succeed: \(output.stderr)")
        let object = try #require(JSONSerialization.jsonObject(with: Data(output.stdout.utf8)) as? [String: Any])
        let features = try #require(object["features"] as? [String: Any])
        #expect(features["accessStatsScoringEnabled"] as? Bool == true)
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
        let daemonRoot = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("wxdc-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: daemonRoot) }

        let environment = testEnvironment(["WAX_CLI_DAEMON_DIR": daemonRoot.path])

        let first = try AgentDaemonTransport.configuration(
            storePath: "~/Library/Application Support/Wax/a.wax",
            embedderChoice: .minilm,
            environment: environment
        )
        let second = try AgentDaemonTransport.configuration(
            storePath: "~/Library/Application Support/Wax/a.wax",
            embedderChoice: .minilm,
            environment: environment
        )
        let arctic = try AgentDaemonTransport.configuration(
            storePath: "~/Library/Application Support/Wax/a.wax",
            embedderChoice: .arctic,
            environment: environment
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

        let environment = testEnvironment(["WAX_CLI_DAEMON_DIR": daemonRoot.path])

        let firstCLI = binariesRoot.appendingPathComponent("wax-cli-a")
        let secondCLI = binariesRoot.appendingPathComponent("wax-cli-b")
        try Data("v1".utf8).write(to: firstCLI)
        try Data("v2-with-different-size".utf8).write(to: secondCLI)

        let first = try AgentDaemonTransport.configuration(
            storePath: "~/Library/Application Support/Wax/a.wax",
            embedderChoice: .minilm,
            cliPathOverride: firstCLI.path,
            environment: environment
        )
        let second = try AgentDaemonTransport.configuration(
            storePath: "~/Library/Application Support/Wax/a.wax",
            embedderChoice: .minilm,
            cliPathOverride: secondCLI.path,
            environment: environment
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

    @Test func daemonSocketPathDoesNotReplaceRegularFile() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-cli-daemon-socket-\(UUID().uuidString)", isDirectory: true)
        let storeURL = tempRoot.appendingPathComponent("daemon.wax")
        let victimURL = tempRoot.appendingPathComponent("victim.sock")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        try "do not unlink\n".write(to: victimURL, atomically: true, encoding: .utf8)

        let cli = try builtProductPath(named: "wax-cli")
        let output = try await runProcess(
            executableURL: URL(fileURLWithPath: cli),
            arguments: [
                "daemon",
                "--store-path", storeURL.path,
                "--no-embedder",
                "--socket-path", victimURL.path,
                "--idle-timeout-secs", "0.1",
            ],
            timeout: 10
        )

        #expect(output.status != EXIT_SUCCESS, "daemon should reject a regular file socket path")
        #expect(FileManager.default.fileExists(atPath: victimURL.path))
        let preserved = try String(contentsOf: victimURL, encoding: .utf8)
        #expect(preserved == "do not unlink\n")
    }

    @Test func daemonSocketClientTimeoutDoesNotBlockLaterRequests() async throws {
        let tempRoot = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("wxds-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let storeURL = tempRoot.appendingPathComponent("daemon.wax")
        let socketURL = tempRoot.appendingPathComponent("daemon.sock")
        let hooksURL = tempRoot.appendingPathComponent("hooks", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try FileManager.default.createDirectory(at: hooksURL, withIntermediateDirectories: true)

        let cli = try builtProductPath(named: "wax-cli")
        let process = ChildProcess()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = [
            "daemon",
            "--store-path", storeURL.path,
            "--no-embedder",
            "--socket-path", socketURL.path,
            "--idle-timeout-secs", "10",
        ]
        process.environment = testEnvironment(["WAX_BROKER_TEST_HOOKS_DIR": hooksURL.path])
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
                process.waitForExit(timeout: 10)
            }
        }

        try await waitForListening(hooksDirectory: hooksURL, daemon: process, timeout: 5)

        let stalledClient = try connectUnixSocket(path: socketURL.path)
        defer { close(stalledClient) }
        _ = "{".withCString { pointer in write(stalledClient, pointer, 1) }

        let responseLine = try await sendBrokerSocketRequest(
            AgentBrokerRequest(command: "stats"),
            socketPath: socketURL.path,
            timeoutSeconds: 3
        )
        let response = try JSONDecoder().decode(AgentBrokerResponse.self, from: Data(responseLine.utf8))
        #expect(response.ok)
    }

    /// The idle timeout counts from when the last client left. A connection held
    /// longer than the timeout must not make the daemon exit the moment it closes.
    @Test func daemonIdleTimeoutCountsFromLastClientLeaving() async throws {
        let tempRoot = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("wxdi-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let storeURL = tempRoot.appendingPathComponent("daemon.wax")
        let socketURL = tempRoot.appendingPathComponent("daemon.sock")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let cli = try builtProductPath(named: "wax-cli")
        let process = ChildProcess()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = [
            "daemon",
            "--store-path", storeURL.path,
            "--no-embedder",
            "--socket-path", socketURL.path,
            "--idle-timeout-secs", "5",
        ]
        // A long request-read deadline keeps the stalled client connected well
        // past the idle timeout, so the margins below stay wide on a loaded host.
        let hooksDir = tempRoot.appendingPathComponent("hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)
        var environment = ProcessInfo.processInfo.environment
        environment["WAX_BROKER_TEST_HOOKS_DIR"] = hooksDir.path
        environment["WAX_BROKER_TEST_READ_DEADLINE_SECS"] = "8"
        process.environment = environment
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
                process.waitForExit(timeout: 10)
            }
        }

        try await waitForListening(hooksDirectory: hooksDir, daemon: process, timeout: 5)

        // A stalled client stays connected until the daemon's 8s request-read
        // deadline drops it, which is longer than the 5s idle timeout.
        let stalledClient = try connectUnixSocket(path: socketURL.path)
        defer { close(stalledClient) }
        _ = "{".withCString { pointer in write(stalledClient, pointer, 1) }
        try await waitForPeerClose(fd: stalledClient, timeoutSeconds: 30)

        // Well inside the idle timeout measured from that close; the old
        // last-accept baseline exited within one 200ms poll slice.
        try await Task.sleep(for: .milliseconds(600))
        #expect(process.isRunning, "daemon exited as soon as its long-lived client left")

        let responseLine = try await sendBrokerSocketRequest(
            AgentBrokerRequest(command: "stats"),
            socketPath: socketURL.path,
            timeoutSeconds: 3
        )
        let response = try JSONDecoder().decode(AgentBrokerResponse.self, from: Data(responseLine.utf8))
        #expect(response.ok)
    }

    /// Reads and discards until the peer closes `fd`. The bound only catches a hang. The wait
    /// runs on a GCD thread: it outlasts the daemon's read deadline, and on the cooperative
    /// pool it held one of a CI runner's three threads that long.
    private func waitForPeerClose(fd: Int32, timeoutSeconds: Int32) async throws {
        try await BlockingWork.run { try waitForPeerCloseBlocking(fd: fd, timeoutSeconds: timeoutSeconds) }
    }

    private func waitForPeerCloseBlocking(fd: Int32, timeoutSeconds: Int32) throws {
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, timeoutSeconds * 1000)
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else {
                throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "daemon never closed the stalled client"])
            }
            let count = read(fd, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            if count <= 0 { return }
        }
    }

    @Test func mcpInstallStagesBundledRuntimeIntoStableDirectory() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-cli-install-stage-\(UUID().uuidString)", isDirectory: true)
        let sourceDir = tempRoot.appendingPathComponent("dist/darwin-arm64", isDirectory: true)
        let installRoot = tempRoot.appendingPathComponent("install-root", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try makeExecutableStub(at: sourceDir.appendingPathComponent("wax-cli"))
        try makeExecutableStub(at: sourceDir.appendingPathComponent("wax-mcp"))
        try await writeChecksumFile(for: sourceDir.appendingPathComponent("wax-cli"))
        try await writeChecksumFile(for: sourceDir.appendingPathComponent("wax-mcp"))
        try FileManager.default.createDirectory(
            at: sourceDir.appendingPathComponent("Wax_WaxVectorSearchMiniLM.bundle", isDirectory: true),
            withIntermediateDirectories: true
        )

        let runtime = try Pathing.prepareMCPInstallRuntime(
            cliPath: sourceDir.appendingPathComponent("wax-cli").path,
            serverPath: sourceDir.appendingPathComponent("wax-mcp").path,
            dryRun: false,
            environment: testEnvironment(["WAX_MCP_INSTALL_ROOT": installRoot.path])
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

    @Test func mcpSkillStagingCopiesFromSourceOverride() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-cli-skill-stage-\(UUID().uuidString)", isDirectory: true)
        let sourceSkill = tempRoot.appendingPathComponent("source-skill", isDirectory: true)
        let installRoot = tempRoot.appendingPathComponent("install-root", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try FileManager.default.createDirectory(at: sourceSkill, withIntermediateDirectories: true)
        try "# Wax MCP skill fixture\n".write(
            to: sourceSkill.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        let cli = tempRoot.appendingPathComponent("wax-cli")
        let server = tempRoot.appendingPathComponent("wax-mcp")
        try makeExecutableStub(at: cli)
        try makeExecutableStub(at: server)

        let environment = testEnvironment([
            "WAX_MCP_INSTALL_ROOT": installRoot.path,
            "WAX_MCP_SKILL_SOURCE": sourceSkill.path,
        ])

        let skipped = try Pathing.prepareWaxMCPSkill(
            cliPath: cli.path,
            serverPath: server.path,
            dryRun: false,
            skip: true,
            environment: environment
        )
        #expect(skipped.skipped)
        #expect(skipped.stagedPath == nil)

        let staged = try Pathing.prepareWaxMCPSkill(
            cliPath: cli.path,
            serverPath: server.path,
            dryRun: false,
            skip: false,
            environment: environment
        )
        #expect(!staged.skipped)
        #expect(staged.staged)
        #expect(staged.sourcePath == sourceSkill.path)

        let expected = installRoot
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent("wax-mcp", isDirectory: true)
        #expect(staged.stagedPath == expected.path)
        #expect(Pathing.isValidSkillDirectory(expected))

        let skillBody = try String(contentsOf: expected.appendingPathComponent("SKILL.md"), encoding: .utf8)
        #expect(skillBody.contains("Wax MCP skill fixture"))
    }

    @Test func mcpSkillResolvesFromNpmPackageLayout() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-cli-skill-npm-\(UUID().uuidString)", isDirectory: true)
        let packageRoot = tempRoot.appendingPathComponent("waxmcp-package", isDirectory: true)
        let runtimeDir = packageRoot.appendingPathComponent("dist/darwin-arm64", isDirectory: true)
        let skillDir = packageRoot.appendingPathComponent("skills/wax-mcp", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try FileManager.default.createDirectory(at: runtimeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        try makeExecutableStub(at: runtimeDir.appendingPathComponent("wax-cli"))
        try makeExecutableStub(at: runtimeDir.appendingPathComponent("wax-mcp"))
        try "# from npm package\n".write(
            to: skillDir.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        let resolved = Pathing.resolveWaxMCPSkillSource(
            cliPath: runtimeDir.appendingPathComponent("wax-cli").path,
            serverPath: runtimeDir.appendingPathComponent("wax-mcp").path
        )
        #expect(resolved?.path == skillDir.path)
    }

    @Test func projectRulesPlaybookIsAPointerNotASecondLifecycle() {
        #expect(WaxMCPAgentPlaybook.projectRules.contains("remember"))
        #expect(WaxMCPAgentPlaybook.projectRules.contains("recall"))
        #expect(WaxMCPAgentPlaybook.projectRules.contains("stats"))
        #expect(WaxMCPAgentPlaybook.projectRules.contains("session_id"))
        #expect(WaxMCPAgentPlaybook.projectRules.contains("live Wax MCP server instructions"))
        #expect(WaxMCPAgentPlaybook.projectRules.contains("Do not load the `wax` or `wax-mcp` skills at session start"))
        #expect(WaxMCPAgentPlaybook.projectRules.contains("`wax` is Swift SDK only"))
        #expect(WaxMCPAgentPlaybook.projectRules.contains("install/doctor only"))
        #expect(!WaxMCPAgentPlaybook.projectRules.contains("task_state"))
        #expect(!WaxMCPAgentPlaybook.projectRules.contains("before you spawn"))
        #expect(!WaxMCPAgentPlaybook.projectRules.contains("leftover_reasons"))
        #expect(!WaxMCPAgentPlaybook.projectRules.contains("Skip one-line Q&A"))
        #expect(!WaxMCPAgentPlaybook.projectRules.contains("handoff_latest then `session_start`"))
        #expect(!WaxMCPAgentPlaybook.projectRules.contains("call `session_open`"))
        #expect(WaxMCPAgentPlaybook.soulRules.contains("## Memory (Wax)"))
        #expect(WaxMCPAgentPlaybook.soulRules.contains("remember"))
        #expect(WaxMCPAgentPlaybook.soulRules.contains("live MCP server instructions"))
        #expect(!WaxMCPAgentPlaybook.soulRules.contains("task_state"))
        #expect(!WaxMCPAgentPlaybook.soulRules.contains("handoff_latest"))
        #expect(!WaxMCPAgentPlaybook.soulRules.contains("call `session_open`"))
        #expect(WaxMCPAgentPlaybook.githubSkillURL.contains("wax-mcp"))
        #expect(WaxMCPAgentPlaybook.hermesRules.contains("wax_remember"))
        #expect(WaxMCPAgentPlaybook.hermesRules.contains("wax_recall"))
        #expect(WaxMCPAgentPlaybook.hermesRules.contains("Omit `mode` unless you need an override"))
        #expect(WaxMCPAgentPlaybook.hermesRules.contains("Do not paste the MCP `session_open` loop"))
        #expect(!WaxMCPAgentPlaybook.hermesRules.contains("call `session_open`"))
        #expect(!WaxMCPAgentPlaybook.hermesRules.contains("session_close"))
    }

    @Test func writeHostRuleIsOptInAndWritesPlaybook() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-host-rule-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("wax.md")

        try WaxMCPHostRuleWriter.writeIfRequested(path: nil)
        #expect(!FileManager.default.fileExists(atPath: target.path))
        try WaxMCPHostRuleWriter.writeIfRequested(path: "   ")
        #expect(!FileManager.default.fileExists(atPath: target.path))

        try WaxMCPHostRuleWriter.writeIfRequested(path: target.path)
        let text = try String(contentsOf: target, encoding: .utf8)
        #expect(text == WaxMCPAgentPlaybook.projectRules)
        #expect(text.contains("remember"))
        #expect(text.contains("recall"))
        #expect(text.contains("stats"))
    }

    @Test func projectRulesPlaybookStaysInLockstepWithDocs() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let publicRules = repoRoot.appendingPathComponent(
            "Resources/skills/public/wax-mcp/references/project-rules.md"
        )
        let npmRules = repoRoot.appendingPathComponent(
            "Resources/npm/waxmcp/skills/wax-mcp/references/project-rules.md"
        )
        let readme = repoRoot.appendingPathComponent("README.md")

        let publicText = try String(contentsOf: publicRules, encoding: .utf8)
        let npmText = try String(contentsOf: npmRules, encoding: .utf8)
        let readmeText = try String(contentsOf: readme, encoding: .utf8)

        #expect(publicText == npmText)
        #expect(publicText.contains(WaxMCPAgentPlaybook.projectRules))
        #expect(publicText.contains(WaxMCPAgentPlaybook.soulRules))
        #expect(publicText.contains(WaxMCPAgentPlaybook.hermesRules))
        #expect(readmeText.contains(WaxMCPAgentPlaybook.projectRules))
        #expect(readmeText.contains(WaxMCPAgentPlaybook.soulRules))
        #expect(readmeText.contains(WaxMCPAgentPlaybook.hermesRules))
        #expect(readmeText.contains("Paste into AGENTS.md / CLAUDE.md / Cursor rules"))
        #expect(readmeText.contains("Paste into OpenClaw SOUL.md"))
        #expect(!readmeText.contains("Paste into Hermes / OpenClaw SOUL.md"))
        #expect(!readmeText.contains("keep the returned session_id, then recall"))
        #expect(!readmeText.contains("write lessons, user_preference, and facts with session_id"))
        #expect(readmeText.contains("session_open with recall_query is enough"))
        #expect(readmeText.contains("committed true"))
        #expect(readmeText.contains("leftover_reasons"))
        #expect(readmeText.contains("Daily tools are `remember`, `recall`, and `stats`"))

        let hostsText = try String(
            contentsOf: repoRoot.appendingPathComponent("Resources/docs/wax-mcp-hosts.md"),
            encoding: .utf8
        )
        #expect(!hostsText.contains("Before the first answer: `recall`"))
        #expect(!hostsText.contains("Keep `session_id`."))
        #expect(hostsText.contains("recall_query is enough"))
        #expect(hostsText.contains("committed: true"))
        #expect(hostsText.contains("leftover_reasons"))
        #expect(hostsText.contains("omit it after that"))

        let publicOpenAI = try String(
            contentsOf: repoRoot.appendingPathComponent("Resources/skills/public/wax-mcp/agents/openai.yaml"),
            encoding: .utf8
        )
        let npmOpenAI = try String(
            contentsOf: repoRoot.appendingPathComponent("Resources/npm/waxmcp/skills/wax-mcp/agents/openai.yaml"),
            encoding: .utf8
        )
        #expect(publicOpenAI == npmOpenAI)
        #expect(publicOpenAI.contains("remember"))
        #expect(publicOpenAI.contains("recall"))
        #expect(publicOpenAI.contains("stats"))
        #expect(publicOpenAI.contains("session_open"))
        #expect(publicOpenAI.contains("session_close"))
        #expect(!publicOpenAI.contains("Call handoff_latest then session_start"))
    }

    @Test func embedderRuntimeOptionsOverrideEnvironment() throws {
        let environment = [
            "WAX_EMBEDDER_BATCH_SIZE": "2",
            "WAX_EMBEDDER_PREWARM_BATCH_SIZE": "3",
            "WAX_EMBEDDER_ALLOW_LOW_PRECISION_GPU": "1",
            "WAX_EMBEDDER_TIMEOUT_SECS": "7",
            "WAX_EMBEDDER_COMPUTE_UNITS": "cpuOnly",
        ]
        #expect(CommandLineEmbedderRuntimeTuning.fromEnvironment(environment).batchSize == 2)

        let store = try VectorStoreOptions.parse([
            "--embedder-batch-size", "8",
            "--embedder-prewarm-batch-size", "5",
            "--embedder-low-precision-gpu", "false",
            "--embedder-timeout-secs", "11",
            "--embedder-compute-unit", "cpuAndGPU",
            "--embedder-compute-unit", "cpuOnly",
        ])

        let tuning = store.runtime.resolvedTuning(environment: environment)
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

    @Test func brokerPathingDefaultTuningComesFromInjectedEnvironment() throws {
        let environment = testEnvironment(["WAX_EMBEDDER_BATCH_SIZE": "7"])
        let configuration = try AgentBrokerPathing.configuration(
            brokerExecutablePath: "/usr/bin/true",
            storePath: "~/Library/Application Support/Wax/a.wax",
            embedderChoice: "minilm",
            noEmbedder: false,
            environment: environment
        )
        #expect(configuration.embedderTuning == CommandLineEmbedderRuntimeTuning.fromEnvironment(environment))
        #expect(configuration.embedderTuning.batchSize == 7)
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

    @Test func brokerSocketFallbackUsesPrivateUserDirectory() throws {
        let longRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-broker-long-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(String(repeating: "nested-", count: 12), isDirectory: true)
        var fallbackDirectory: URL?
        defer {
            if let fallbackDirectory {
                try? FileManager.default.removeItem(at: fallbackDirectory)
            }
            try? FileManager.default.removeItem(at: longRoot.deletingLastPathComponent())
        }

        let configuration = try AgentBrokerPathing.configuration(
            brokerExecutablePath: try builtProductPath(named: "wax-cli"),
            storePath: longRoot.appendingPathComponent("fallback.wax").path,
            socketRootPath: longRoot.path,
            embedderChoice: "minilm",
            noEmbedder: true,
            requireVector: false
        )

        let socketURL = URL(fileURLWithPath: configuration.socketPath)
        let socketDirectory = socketURL.deletingLastPathComponent()
        fallbackDirectory = socketDirectory
        let privateRoot = socketDirectory.deletingLastPathComponent()
        #expect(privateRoot.lastPathComponent == "wax-broker-\(getuid())")
        #expect(socketDirectory.lastPathComponent.hasPrefix("wxb-"))
        #expect(!configuration.socketPath.hasPrefix("/tmp/wxb-"))

        let attributes = try FileManager.default.attributesOfItem(atPath: socketDirectory.path)
        let permissionNumber = try #require(attributes[.posixPermissions] as? NSNumber)
        let ownerNumber = try #require(attributes[.ownerAccountID] as? NSNumber)
        let permissions = permissionNumber.intValue & 0o777
        let owner = ownerNumber.uint32Value
        #expect(permissions == 0o700)
        #expect(owner == UInt32(getuid()))
        #expect(configuration.socketPath.utf8.count < 100)
    }

    @Test func brokerSocketEnvironmentRootUsesPrivateDirectory() throws {
        let brokerRoot = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("wxbr-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: brokerRoot) }

        let configuration = try AgentBrokerPathing.configuration(
            brokerExecutablePath: try builtProductPath(named: "wax-cli"),
            storePath: brokerRoot.appendingPathComponent("private-root.wax").path,
            embedderChoice: "minilm",
            noEmbedder: true,
            requireVector: false,
            environment: testEnvironment(["WAX_BROKER_DIR": brokerRoot.path])
        )

        #expect(configuration.socketPath.hasPrefix(brokerRoot.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: brokerRoot.path)
        let permissionNumber = try #require(attributes[.posixPermissions] as? NSNumber)
        let ownerNumber = try #require(attributes[.ownerAccountID] as? NSNumber)
        #expect(permissionNumber.intValue & 0o777 == 0o700)
        #expect(ownerNumber.uint32Value == UInt32(getuid()))
    }

    @Test func brokerSocketEnvironmentRootRejectsSymlink() throws {
        let tempRoot = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("wxbr-symlink-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let targetRoot = tempRoot.appendingPathComponent("target", isDirectory: true)
        let symlinkRoot = tempRoot.appendingPathComponent("link", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try FileManager.default.createDirectory(at: targetRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: symlinkRoot, withDestinationURL: targetRoot)
        do {
            _ = try AgentBrokerPathing.configuration(
                brokerExecutablePath: try builtProductPath(named: "wax-cli"),
                storePath: tempRoot.appendingPathComponent("symlink-root.wax").path,
                embedderChoice: "minilm",
                noEmbedder: true,
                requireVector: false,
                environment: testEnvironment(["WAX_BROKER_DIR": symlinkRoot.path])
            )
            Issue.record("Expected broker socket root to reject symlink directories")
        } catch {
            #expect(error.localizedDescription.contains("must not be a symlink"))
        }
    }

    @Test func brokerBackedVectorRequirementFailsFastWhenNoEmbedderIsConfigured() async throws {
        let brokerRoot = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("wxbv-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let storeURL = brokerRoot.appendingPathComponent("vector-required.wax")
        defer { try? FileManager.default.removeItem(at: brokerRoot) }

        let brokerConfiguration = try AgentBrokerPathing.configuration(
            brokerExecutablePath: try builtProductPath(named: "wax-cli"),
            storePath: storeURL.path,
            embedderChoice: "minilm",
            noEmbedder: true,
            requireVector: true,
            environment: testEnvironment(["WAX_BROKER_DIR": brokerRoot.path])
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

        let configuration = try AgentBrokerPathing.configuration(
            brokerExecutablePath: try builtProductPath(named: "wax-cli"),
            storePath: storeURL.path,
            embedderChoice: "minilm",
            noEmbedder: true,
            requireVector: false,
            environment: testEnvironment(["WAX_BROKER_DIR": brokerRoot.path])
        )

        let response = try await AgentBrokerClient.perform(
            request: AgentBrokerRequest(command: "stats"),
            configuration: configuration,
            shutdownIfStarted: true
        )
        #expect(response.ok)

        #expect(!FileManager.default.fileExists(atPath: configuration.socketPath))

        // A short lock wait proves the broker released the store: a still-held
        // lock fails this open after 200ms instead of the 5s CLI default.
        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        let reopened = try await MemoryOrchestrator(
            at: storeURL,
            config: config,
            waxOptions: WaxOptions(lockWaitTimeout: .milliseconds(200))
        )
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

    @Test func buildWaxMCPBinariesWritesRelocatableChecksums() async throws {
        let sourceRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-build-checksums-\(UUID().uuidString)", isDirectory: true)
        let scriptsDir = fixtureRoot.appendingPathComponent("Resources/scripts", isDirectory: true)
        let distDir = fixtureRoot.appendingPathComponent("Resources/npm/waxmcp/dist/darwin-arm64", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        try FileManager.default.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: distDir, withIntermediateDirectories: true)
        let scriptURL = scriptsDir.appendingPathComponent("build-waxmcp-binaries.sh")
        try FileManager.default.copyItem(
            at: sourceRoot.appendingPathComponent("Resources/scripts/build-waxmcp-binaries.sh"),
            to: scriptURL
        )
        try setExecutable(scriptURL)
        try makeExecutableStub(at: distDir.appendingPathComponent("wax-cli"))
        try makeExecutableStub(at: distDir.appendingPathComponent("wax-mcp"))

        let output = try await runProcess(
            executableURL: scriptURL,
            arguments: ["darwin-arm64"],
            currentDirectoryURL: fixtureRoot,
            timeout: 10
        )

        #expect(output.status == EXIT_SUCCESS, "build helper stderr: \(output.stderr)")
        let cliChecksum = try String(
            contentsOf: distDir.appendingPathComponent("wax-cli.sha256"),
            encoding: .utf8
        )
        let mcpChecksum = try String(
            contentsOf: distDir.appendingPathComponent("wax-mcp.sha256"),
            encoding: .utf8
        )
        #expect(cliChecksum.contains("  wax-cli\n"))
        #expect(mcpChecksum.contains("  wax-mcp\n"))
        #expect(!cliChecksum.contains(fixtureRoot.path))
        #expect(!mcpChecksum.contains(fixtureRoot.path))
    }

    @Test func mcpInstallDryRunRedactsLicenseKey() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-cli-install-redaction-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let fakeServer = tempRoot.appendingPathComponent("wax-mcp")
        try makeExecutableStub(at: fakeServer)
        // Hermetic host selection: explicit --hosts avoids auto-detection
        // (which throws on host-less machines), and a stub `claude` on PATH
        // keeps the dry-run on the command-printing path. Dry-run never
        // executes the stub.
        try makeExecutableStub(at: tempRoot.appendingPathComponent("claude"))
        let path = "\(tempRoot.path):\(ProcessInfo.processInfo.environment["PATH"] ?? "")"

        let cli = try builtProductPath(named: "wax-cli")
        let secret = "wax_secret_\(UUID().uuidString)"
        let output = try await runProcess(
            executableURL: URL(fileURLWithPath: cli),
            arguments: [
                "mcp", "install",
                "--dry-run",
                "--skip-build",
                "--server-path", fakeServer.path,
                "--license-key", secret,
                "--hosts", "claude",
            ],
            environment: ["PATH": path],
            timeout: 20
        )

        #expect(output.status == EXIT_SUCCESS, "mcp install --dry-run should succeed")
        #expect(!output.stdout.contains(secret), "dry-run stdout must not include the raw license key")
        #expect(!output.stderr.contains(secret), "dry-run stderr must not include the raw license key")
        #expect(output.stdout.contains("WAX_LICENSE_KEY=<redacted>"))
    }

    @Test func mcpServePassesLicenseKeyInEnvironmentOnly() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-cli-serve-license-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let argvFile = tempRoot.appendingPathComponent("argv.txt")
        let envFile = tempRoot.appendingPathComponent("env.txt")
        let fakeServer = tempRoot.appendingPathComponent("wax-mcp")
        try """
        #!/bin/sh
        printf '%s\n' "$*" > "\(argvFile.path)"
        printf '%s\n' "$WAX_LICENSE_KEY" > "\(envFile.path)"
        exit 0
        """.write(to: fakeServer, atomically: true, encoding: .utf8)
        try setExecutable(fakeServer)

        let cli = try builtProductPath(named: "wax-cli")
        let secret = "wax_secret_\(UUID().uuidString)"
        let output = try await runProcess(
            executableURL: URL(fileURLWithPath: cli),
            arguments: [
                "mcp", "serve",
                "--server-path", fakeServer.path,
                "--store-path", tempRoot.appendingPathComponent("memory.wax").path,
                "--license-key", secret,
            ],
            timeout: 20
        )

        #expect(output.status == EXIT_SUCCESS, "mcp serve should propagate the stub server exit status")
        let argv = try String(contentsOf: argvFile, encoding: .utf8)
        let env = try String(contentsOf: envFile, encoding: .utf8)
        #expect(!argv.contains(secret), "mcp serve must not expose the raw license key in child argv")
        #expect(env.trimmingCharacters(in: .whitespacesAndNewlines) == secret)
    }

    @Test func entityUpsertNoCommitFallsBackToDirectStore() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-cli-commit-flag-\(UUID().uuidString)", isDirectory: true)
        let storeURL = tempRoot.appendingPathComponent("commit-flag.wax")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let cli = try builtProductPath(named: "wax-cli")
        let output = try await runProcess(
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

    @Test
    func mcpDoctorDailyToolSurfaceMatchesCanonicalVerbs() {
        #expect(MCPDoctorSurface.dailyToolNames == [
            "remember",
            "recall",
            "stats",
        ])
        #expect(MCPDoctorSurface.legacyToolNames == [
            "session_open",
            "remember",
            "recall",
            "session_close",
            "stats",
            "memory_get",
            "compact_context",
            "session_resume",
        ])
        #expect(MCPDoctorSurface.expectedToolNames(environment: [:]) == MCPDoctorSurface.dailyToolNames)
        #expect(
            MCPDoctorSurface.expectedToolNames(environment: ["WAX_MCP_TOOLS": "legacy"])
                == MCPDoctorSurface.legacyToolNames
        )
    }

    @Test
    func vectorHealthIsGreenOnlyWhenQueryEmbeddingsAreAvailable() {
        let healthy = MCPVectorHealthDiagnostics.evaluate(
            vectorSearchEnabled: true,
            queryEmbeddingAvailable: true,
            model: "all-MiniLM-L6-v2",
            embeddingStatus: "ready",
            framesWithoutVectors: 0
        )
        #expect(healthy.healthy)
        #expect(healthy.status == "healthy")
        #expect(healthy.model == "all-MiniLM-L6-v2")
        #expect(healthy.reason.contains("query embeddings"))
        #expect(healthy.framesWithoutVectors == 0)

        let storageOnly = MCPVectorHealthDiagnostics.evaluate(
            vectorSearchEnabled: true,
            queryEmbeddingAvailable: false,
            model: "all-MiniLM-L6-v2",
            embeddingStatus: "degraded",
            embeddingStatusReason: "query embedder is not ready",
            framesWithoutVectors: 4
        )
        #expect(storageOnly.healthy == false)
        #expect(storageOnly.status == "degraded")
        #expect(storageOnly.model == "all-MiniLM-L6-v2")
        #expect(storageOnly.reason == "query embedder is not ready")
        #expect(storageOnly.framesWithoutVectors == 4)
        #expect(storageOnly.vectorSearchEnabled)
        #expect(storageOnly.queryEmbeddingAvailable == false)

        let disabled = MCPVectorHealthDiagnostics.evaluate(
            vectorSearchEnabled: false,
            queryEmbeddingAvailable: false
        )
        #expect(disabled.healthy == false)
        #expect(disabled.status == "degraded")
        #expect(disabled.reason.contains("vector search is disabled"))

        let storageReadyWithoutQuery = MCPVectorHealthDiagnostics.evaluate(
            vectorSearchEnabled: true,
            queryEmbeddingAvailable: false,
            model: "all-MiniLM-L6-v2",
            embeddingStatus: "ready"
        )
        #expect(storageReadyWithoutQuery.healthy == false)
        #expect(storageReadyWithoutQuery.status == "degraded")
        #expect(storageReadyWithoutQuery.status != "healthy")
        #expect(storageReadyWithoutQuery.status != "ready")
        #expect(storageReadyWithoutQuery.reason.contains("query embeddings"))
    }

    @Test
    func vectorHealthCommandIsUnhealthyWhenQueryEmbeddingsAreUnavailable() {
        #expect(
            VectorHealthCommand.isHealthy(
                vectorSearchEnabled: true,
                queryEmbeddingAvailable: true,
                embedderPresent: true,
                framesWithoutVectors: 0,
                canaryPassed: true
            )
        )
        #expect(
            !VectorHealthCommand.isHealthy(
                vectorSearchEnabled: true,
                queryEmbeddingAvailable: false,
                embedderPresent: true,
                framesWithoutVectors: 0,
                canaryPassed: true
            )
        )
        #expect(
            !VectorHealthCommand.isHealthy(
                vectorSearchEnabled: false,
                queryEmbeddingAvailable: true,
                embedderPresent: true,
                framesWithoutVectors: 0,
                canaryPassed: true
            )
        )
        #expect(
            !VectorHealthCommand.isHealthy(
                vectorSearchEnabled: true,
                queryEmbeddingAvailable: true,
                embedderPresent: true,
                framesWithoutVectors: 0,
                canaryPassed: true,
                vectorsNeedReembed: true
            )
        )
    }

    @Test
    func vectorHealthFixCommandShellQuotesStorePaths() {
        #expect(
            VectorHealthCommand.reembedFixCommand(storePath: "/tmp/memory.wax")
                == "wax-cli embed-backfill --direct-store --store-path /tmp/memory.wax --output /tmp/memory-reembedded.wax"
        )
        #expect(
            VectorHealthCommand.reembedFixCommand(storePath: "/tmp/my notes/it's.wax")
                == "wax-cli embed-backfill --direct-store --store-path '/tmp/my notes/it'\\''s.wax' --output '/tmp/my notes/it'\\''s-reembedded.wax'"
        )
        #expect(VectorHealthCommand.shellQuoted("$(rm -rf ~)") == "'$(rm -rf ~)'")
    }

    @Test
    func directStoreCommandsNeverStartSupersededReembedOnTheirOwn() {
        #expect(!StoreSession.orchestratorConfig().automaticallyReembedSupersededVectors)
        #expect(OrchestratorConfig.default.automaticallyReembedSupersededVectors)
        // Nor do they commit a text-index catch-up: only the store's owning writer does.
        #expect(!StoreSession.orchestratorConfig().catchUpTextIndexOnOpen)
    }

    @Test(.disabled(if: !mcpServerTraitEnabled,
                    "Build with --traits default,MCPServer to run wax-mcp smoke tests"))
    func mcpDoctorIsHostAgnosticAndValidatesDailyToolSurface() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-cli-doctor-\(UUID().uuidString)", isDirectory: true)
        let storeURL = tempRoot.appendingPathComponent("doctor.wax")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let cli = try builtProductPath(named: "wax-cli")
        let server = try builtProductPath(named: "wax-mcp")
        let output = try await runProcess(
            executableURL: URL(fileURLWithPath: cli),
            arguments: [
                "mcp", "doctor",
                "--server-path", server,
                "--store-path", storeURL.path,
                "--no-embedder",
            ],
            environment: doctorEnvironment,
            timeout: hangTimeoutSeconds
        )

        #expect(output.status == EXIT_SUCCESS, "wax-cli mcp doctor should pass against the daily tool surface without a host CLI")
        #expect(output.stdout.contains("Doctor passed."))
        expectHostAgnosticDoctorOutput(output.stdout)
        #expect(output.stdout.lowercased().contains("vector: healthy") == false)
        #expect(output.stdout.contains("Vector search is working") == false)
    }

    @Test(.disabled(if: !mcpServerTraitEnabled,
                    "Build with --traits default,MCPServer to run wax-mcp smoke tests"))
    func mcpDoctorSmokeChecksIsolatedStoreWhenTargetStoreIsHeld() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-cli-doctor-locked-\(UUID().uuidString)", isDirectory: true)
        let storeURL = tempRoot.appendingPathComponent("held.wax")
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        config.enableStructuredMemory = true
        config.rag.searchMode = .textOnly
        let holder = try await MemoryOrchestrator(at: storeURL, config: config)

        let cli = try builtProductPath(named: "wax-cli")
        let server = try builtProductPath(named: "wax-mcp")
        let output = try await runProcess(
            executableURL: URL(fileURLWithPath: cli),
            arguments: [
                "mcp", "doctor",
                "--server-path", server,
                "--store-path", storeURL.path,
                "--no-embedder",
            ],
            environment: doctorEnvironment,
            timeout: hangTimeoutSeconds
        )
        try await holder.close()

        #expect(output.status == EXIT_SUCCESS, "doctor failed: \(output.stderr)")
        #expect(output.stdout.contains("Doctor passed."))
        #expect(output.stdout.contains("smoke-checking an isolated store"))
    }

    @Test
    func mcpDoctorFailsWhenDailyToolSurfaceIsIncomplete() async throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        try #require(FileManager.default.isExecutableFile(atPath: python.path))

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-cli-doctor-incomplete-\(UUID().uuidString)", isDirectory: true)
        let storeURL = tempRoot.appendingPathComponent("doctor.wax")
        let fakeServer = tempRoot.appendingPathComponent("fake-mcp")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        try #"""
        #!/usr/bin/python3
        import json
        import sys

        tools = [{"name": "remember"}]
        for raw in sys.stdin:
            line = raw.strip()
            if not line:
                continue
            message = json.loads(line)
            method = message.get("method")
            request_id = message.get("id")
            if method == "initialize":
                sys.stdout.write(json.dumps({
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "result": {
                        "protocolVersion": "2024-11-05",
                        "capabilities": {"tools": {}},
                        "serverInfo": {"name": "fake-mcp", "version": "0"},
                    },
                }) + "\n")
                sys.stdout.flush()
            elif method == "tools/list":
                sys.stdout.write(json.dumps({
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "result": {"tools": tools},
                }) + "\n")
                sys.stdout.flush()
        """#.write(to: fakeServer, atomically: true, encoding: .utf8)
        try setExecutable(fakeServer)

        let cli = try builtProductPath(named: "wax-cli")
        let output = try await runProcess(
            executableURL: URL(fileURLWithPath: cli),
            arguments: [
                "mcp", "doctor",
                "--server-path", fakeServer.path,
                "--store-path", storeURL.path,
                "--no-embedder",
            ],
            environment: doctorEnvironment,
            timeout: hangTimeoutSeconds
        )

        #expect(output.status != EXIT_SUCCESS)
        #expect(output.stdout.contains("missing daily tools"))
        #expect(output.stdout.contains("recall"))
        #expect(output.stdout.contains("stats"))
        #expect(output.stdout.contains("Doctor passed.") == false)
        expectHostAgnosticDoctorOutput(output.stdout)
    }

    @Test func mcpDoctorExitGraceIsNeverBelowTheSmokeTimeout() {
        #expect(ProcessRunner.mcpSmokeCheckExitGraceSeconds(timeoutSeconds: 1) == 5)
        #expect(ProcessRunner.mcpSmokeCheckExitGraceSeconds(timeoutSeconds: 5) == 5)
        #expect(ProcessRunner.mcpSmokeCheckExitGraceSeconds(timeoutSeconds: 120) == 120)
    }

    /// A server that takes longer than the 5s floor to exit after stdin closes,
    /// but less than the smoke timeout, passes instead of being killed and
    /// reported as "exit code 9".
    @Test func mcpDoctorWaitsUpToTheSmokeTimeoutForTheServerToExit() async throws {
        let output = try await runDoctorAgainstServer(
            exitingAfterStdinClosesIn: 7,
            smokeTimeoutSeconds: 15
        )
        #expect(output.stdout.contains("Doctor passed."), "doctor output: \(output.stdout)")
        #expect(output.stdout.contains("exit code") == false)
    }

    /// A server that never exits after stdin closes is killed, and reported as
    /// such, without a made-up exit code.
    @Test func mcpDoctorReportsAServerThatDoesNotExitAfterStdinCloses() async throws {
        let output = try await runDoctorAgainstServer(
            exitingAfterStdinClosesIn: 3600,
            smokeTimeoutSeconds: 10
        )
        #expect(output.status != EXIT_SUCCESS)
        #expect(output.stdout.contains("did not exit after stdin closed"), "doctor output: \(output.stdout)")
        #expect(output.stdout.contains("exit code") == false)
        #expect(output.stdout.contains("Doctor passed.") == false)
    }

    /// When doctor cannot tell whether the store is held, it must not smoke-check
    /// it as though it were free: it reports why and skips the check.
    @Test func mcpDoctorSkipsTheSmokeCheckWhenTheStoreLockCannotBeProbed() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-cli-doctor-probe-\(UUID().uuidString)", isDirectory: true)
        // A directory where the store should be: the probe cannot open it.
        let storeURL = tempRoot.appendingPathComponent("store.wax", isDirectory: true)
        let fakeServer = tempRoot.appendingPathComponent("fake-mcp")
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        try FileManager.default.createDirectory(at: storeURL, withIntermediateDirectories: true)
        try makeExecutableStub(at: fakeServer)

        let cli = try builtProductPath(named: "wax-cli")
        let output = try await runProcess(
            executableURL: URL(fileURLWithPath: cli),
            arguments: [
                "mcp", "doctor",
                "--server-path", fakeServer.path,
                "--store-path", storeURL.path,
                "--no-embedder",
            ],
            environment: doctorEnvironment,
            timeout: hangTimeoutSeconds
        )

        #expect(output.status != EXIT_SUCCESS)
        #expect(output.stdout.contains("Could not check whether the store"), "doctor output: \(output.stdout)")
        #expect(output.stdout.contains("server smoke check skipped"))
        #expect(output.stdout.contains("Smoke check") == false, "doctor ran the smoke check: \(output.stdout)")
    }

    /// Runs `mcp doctor` against a stub server that answers the smoke check
    /// with the full daily tool surface, then lingers for `exitDelay` seconds
    /// after its stdin reaches EOF.
    private func runDoctorAgainstServer(
        exitingAfterStdinClosesIn exitDelay: Int,
        smokeTimeoutSeconds: Int
    ) async throws -> ProcessOutput {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        try #require(FileManager.default.isExecutableFile(atPath: python.path))

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-cli-doctor-exit-\(UUID().uuidString)", isDirectory: true)
        let storeURL = tempRoot.appendingPathComponent("doctor.wax")
        let fakeServer = tempRoot.appendingPathComponent("fake-mcp")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let tools = MCPDoctorSurface.dailyToolNames.map { #"{"name": "\#($0)"}"# }.joined(separator: ", ")
        try #"""
        #!/usr/bin/python3
        import json
        import sys
        import time

        tools = [\#(tools)]
        for raw in sys.stdin:
            line = raw.strip()
            if not line:
                continue
            message = json.loads(line)
            method = message.get("method")
            request_id = message.get("id")
            if method == "initialize":
                result = {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": "fake-mcp", "version": "0"},
                }
            elif method == "tools/list":
                result = {"tools": tools}
            else:
                continue
            sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": request_id, "result": result}) + "\n")
            sys.stdout.flush()
        time.sleep(\#(exitDelay))
        """#.write(to: fakeServer, atomically: true, encoding: .utf8)
        try setExecutable(fakeServer)

        let cli = try builtProductPath(named: "wax-cli")
        return try await runProcess(
            executableURL: URL(fileURLWithPath: cli),
            arguments: [
                "mcp", "doctor",
                "--server-path", fakeServer.path,
                "--store-path", storeURL.path,
                "--no-embedder",
            ],
            environment: [
                "PATH": "/usr/bin:/bin",
                ProcessRunner.mcpSmokeCheckTimeoutEnvKey: String(smokeTimeoutSeconds),
            ],
            timeout: hangTimeoutSeconds
        )
    }

    @Test(.disabled(if: !mcpServerTraitEnabled,
                    "Build with --traits default,MCPServer to run wax-mcp smoke tests"))
    func pathLaunchedWaxMCPResolvesSiblingWaxCLIFromPath() async throws {
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

        let output = try await runMCPSmokeProcess(
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
            timeout: hangTimeoutSeconds
        )

        #expect(output.status == EXIT_SUCCESS, "PATH-launched wax-mcp should resolve its colocated wax-cli")
        #expect(output.stdout.contains(#""name":"remember""#))
        #expect(!output.stdout.contains(#""name":"wax_remember""#))
    }

    private func makeExecutableStub(at url: URL) throws {
        try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
        try setExecutable(url)
    }

    private func setExecutable(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: url.path
        )
    }

    private func writeChecksumFile(for executableURL: URL) async throws {
        let output = try await runProcess(
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

    /// Subprocess budgets in these tests only catch a hang. A loaded gate host can
    /// take well over 20s to start `wax-mcp`, so a tight budget measures the host,
    /// not the code.
    private let hangTimeoutSeconds: TimeInterval = 180

    /// Doctor runs with its smoke-check budget raised for the same reason; the 5s
    /// production default is covered by `mcpSmokeCheckTimeoutHonorsOverride`.
    private var doctorEnvironment: [String: String] {
        [
            "PATH": "/usr/bin:/bin",
            ProcessRunner.mcpSmokeCheckTimeoutEnvKey: String(Int(hangTimeoutSeconds)),
        ]
    }

    @Test func mcpSmokeCheckTimeoutHonorsOverride() {
        let key = ProcessRunner.mcpSmokeCheckTimeoutEnvKey
        let fallback = ProcessRunner.defaultMCPSmokeCheckTimeoutSeconds
        #expect(fallback == 5)
        #expect(ProcessRunner.mcpSmokeCheckTimeoutSeconds(environment: [:]) == fallback)
        #expect(ProcessRunner.mcpSmokeCheckTimeoutSeconds(environment: [key: "120"]) == 120)
        #expect(ProcessRunner.mcpSmokeCheckTimeoutSeconds(environment: [key: " 2.5 "]) == 2.5)
        #expect(ProcessRunner.mcpSmokeCheckTimeoutSeconds(environment: [key: "0"]) == fallback)
        #expect(ProcessRunner.mcpSmokeCheckTimeoutSeconds(environment: [key: "-3"]) == fallback)
        #expect(ProcessRunner.mcpSmokeCheckTimeoutSeconds(environment: [key: "inf"]) == fallback)
        #expect(ProcessRunner.mcpSmokeCheckTimeoutSeconds(environment: [key: "soon"]) == fallback)
    }

    private struct ProcessOutput {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// Runs the blocking subprocess wait on a GCD thread, so a long CLI child never
    /// holds a cooperative thread that the rest of the parallel test run needs.
    private func runProcess(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectoryURL: URL? = nil,
        input: String? = nil,
        timeout: TimeInterval = 15
    ) async throws -> ProcessOutput {
        try await BlockingWork.run {
            try runProcessBlocking(
                executableURL: executableURL,
                arguments: arguments,
                environment: environment,
                currentDirectoryURL: currentDirectoryURL,
                input: input,
                timeout: timeout
            )
        }
    }

    private func runProcessBlocking(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]?,
        currentDirectoryURL: URL?,
        input: String?,
        timeout: TimeInterval
    ) throws -> ProcessOutput {
        let process = ChildProcess()
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
            process.waitForExit(timeout: 10)
            throw CLIError("Process timed out: \(executableURL.path) \(arguments.joined(separator: " "))")
        }
        process.waitForExit(timeout: 10)

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcessOutput(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    /// The socket file appears at `bind`, before `listen`, so a connect that only waits for the
    /// file can be refused. The daemon's `listening` test marker is written once it accepts.
    private func waitForListening(
        hooksDirectory: URL,
        daemon: ChildProcess,
        timeout: TimeInterval
    ) async throws {
        let marker = hooksDirectory.appendingPathComponent("listening").path
        let deadline = Date().addingTimeInterval(timeout)
        while !FileManager.default.fileExists(atPath: marker) {
            guard daemon.isRunning else {
                throw CLIError("daemon exited (\(daemon.terminationStatus)) before listening")
            }
            guard Date() < deadline else {
                throw CLIError("Timed out waiting for the daemon to listen")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func connectUnixSocket(path: String) throws -> Int32 {
        #if canImport(Darwin)
        let socketType = SOCK_STREAM
        #else
        let socketType = Int32(SOCK_STREAM.rawValue)
        #endif
        let fd = socket(AF_UNIX, socketType, 0)
        guard fd >= 0 else {
            throw CLIError("Unable to create Unix socket: \(String(cString: strerror(errno)))")
        }

        var address = sockaddr_un()
        #if canImport(Darwin)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        address.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            throw CLIError("Unix socket path is too long: \(path)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: CChar.self, repeating: 0)
            for (index, byte) in pathBytes.enumerated() {
                buffer[index] = byte
            }
        }

        let connectResult = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw CLIError("Unable to connect to Unix socket at \(path): \(message)")
        }
        return fd
    }

    /// The round trip polls for the reply for up to `timeoutSeconds`, so it runs on a GCD
    /// thread rather than holding a cooperative one.
    private func sendBrokerSocketRequest(
        _ request: AgentBrokerRequest,
        socketPath: String,
        timeoutSeconds: Double
    ) async throws -> String {
        try await BlockingWork.run {
            try sendBrokerSocketRequestBlocking(request, socketPath: socketPath, timeoutSeconds: timeoutSeconds)
        }
    }

    private func sendBrokerSocketRequestBlocking(
        _ request: AgentBrokerRequest,
        socketPath: String,
        timeoutSeconds: Double
    ) throws -> String {
        let fd = try connectUnixSocket(path: socketPath)
        defer { close(fd) }

        var payload = try JSONEncoder().encode(request)
        payload.append(0x0A)
        try payload.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            let written = write(fd, base, payload.count)
            guard written == payload.count else {
                throw CLIError("Unable to write broker socket request")
            }
        }
        #if canImport(Darwin)
        shutdown(fd, SHUT_WR)
        #else
        shutdown(fd, Int32(SHUT_WR))
        #endif

        return try readSocketLine(fd: fd, timeoutSeconds: timeoutSeconds)
    }

    private func readSocketLine(fd: Int32, timeoutSeconds: Double) throws -> String {
        var buffer = Data()
        let timeoutMS = Int32(timeoutSeconds * 1000)
        while true {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let result = poll(&descriptor, 1, timeoutMS)
            if result == 0 {
                throw CLIError("Timed out waiting for broker socket response")
            }
            if result < 0 {
                if errno == EINTR { continue }
                throw CLIError("Broker socket poll failed: \(String(cString: strerror(errno)))")
            }

            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = recv(fd, &chunk, chunk.count, 0)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw CLIError("Broker socket read failed: \(String(cString: strerror(errno)))")
            }
            buffer.append(contentsOf: chunk.prefix(count))
            if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                return String(decoding: buffer[..<newlineIndex], as: UTF8.self)
            }
        }

        guard !buffer.isEmpty else {
            throw CLIError("Broker socket closed without a response")
        }
        return String(decoding: buffer, as: UTF8.self)
    }

    private func runMCPSmokeProcess(
        command: String,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectoryURL: URL? = nil,
        expectedToolName: String,
        timeout: TimeInterval = 15
    ) async throws -> ProcessOutput {
        try await BlockingWork.run {
            try runMCPSmokeProcessBlocking(
                command: command,
                arguments: arguments,
                environment: environment,
                currentDirectoryURL: currentDirectoryURL,
                expectedToolName: expectedToolName,
                timeout: timeout
            )
        }
    }

    private func runMCPSmokeProcessBlocking(
        command: String,
        arguments: [String],
        environment: [String: String]?,
        currentDirectoryURL: URL?,
        expectedToolName: String,
        timeout: TimeInterval
    ) throws -> ProcessOutput {
        let process = ChildProcess()
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
            process.waitForExit(timeout: 10)
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw CLIError("Timed out waiting for MCP tools/list response")
        }

        try? stdinPipe.fileHandleForWriting.close()
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        guard process.waitForExit(timeout: 60) != nil else {
            throw CLIError("wax-mcp did not exit after its stdin closed")
        }

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

/// Process environment plus test overrides, injected into the code under test
/// instead of mutating the global environment with `setenv`, which races with
/// every other test (and spawned child process) under `swift test --parallel`.
private func testEnvironment(_ overrides: [String: String]) -> [String: String] {
    ProcessInfo.processInfo.environment.merging(overrides) { _, override in override }
}

/// `mcp doctor` lists every supported host in a registration matrix (since e3af70cc0).
/// Host-agnostic means the matrix names all hosts and nothing outside it is host-specific.
private func expectHostAgnosticDoctorOutput(
    _ stdout: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let hosts = ["claude", "muse", "cursor", "codex", "grok", "opencode"]
    let lines = stdout.components(separatedBy: .newlines)
    #expect(lines.contains { $0.hasPrefix("## Host registrations") }, sourceLocation: sourceLocation)
    for host in hosts {
        #expect(lines.contains { $0.hasPrefix("\(host): ") }, "matrix is missing \(host)", sourceLocation: sourceLocation)
    }
    let outsideMatrix = lines.filter { line in
        !line.hasPrefix("## Host registrations") && !hosts.contains { line.hasPrefix("\($0): ") }
    }
    #expect(
        outsideMatrix.joined(separator: "\n").lowercased().contains("claude") == false,
        "doctor output outside the host matrix is claude-specific",
        sourceLocation: sourceLocation
    )
}
