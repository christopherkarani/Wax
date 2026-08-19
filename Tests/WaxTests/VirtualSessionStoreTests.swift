import Foundation
import Testing
@testable import Wax

private func withVirtualSessionStore<T>(
    brokerInstanceID: String = UUID().uuidString,
    sessionRootURL: URL? = nil,
    removeRootOnExit: Bool = true,
    _ body: (VirtualSessionStore, URL) async throws -> T
) async throws -> T {
    let rootURL: URL
    let owned: Bool
    if let sessionRootURL {
        rootURL = sessionRootURL
        owned = false
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    } else {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-virtual-session-\(UUID().uuidString)", isDirectory: true)
        owned = true
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    let store = VirtualSessionStore(
        sessionRootURL: rootURL,
        brokerInstanceID: brokerInstanceID,
        openExisting: { url in
            var config = OrchestratorConfig.default
            config.enableVectorSearch = false
            config.enableStructuredMemory = false
            return try await MemoryOrchestrator(at: url, config: config)
        }
    )
    do {
        let result = try await body(store, rootURL)
        await store.closeAll()
        if owned, removeRootOnExit {
            try? FileManager.default.removeItem(at: rootURL)
        }
        return result
    } catch {
        await store.closeAll()
        if owned, removeRootOnExit {
            try? FileManager.default.removeItem(at: rootURL)
        }
        throw error
    }
}

private func startSession(
    _ store: VirtualSessionStore,
    agentID: String,
    runID: String,
    cwd: String? = nil
) async throws -> VirtualSessionStore.LifecycleResult {
    let scope: MemoryScopeContext
    if let cwd {
        scope = MemorySemantics.inferScopeContext(currentDirectoryPath: cwd)
    } else {
        scope = MemorySemantics.inferScopeContext()
    }
    return try await store.start(
        explicitSessionID: nil,
        agentID: agentID,
        runID: runID,
        inferredScope: scope
    )
}

private func waxFileSize(at url: URL) throws -> UInt64 {
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    let size = try #require(attrs[.size] as? NSNumber)
    return size.uint64Value
}

struct VirtualSessionStoreTests {
    @Test
    func omittedSessionIDIsNoVirtualSessionEvenWhenOneIsLive() async throws {
        try await withVirtualSessionStore { store, _ in
            _ = try await startSession(store, agentID: "lookup-agent", runID: "lookup-run")
            switch try store.lookup(nil) {
            case .none:
                break
            case .live:
                Issue.record("omitted session_id inferred a virtual session")
            }
        }
    }

    @Test
    func unknownSessionIDFailsClosedWithoutCreatingAStore() async throws {
        try await withVirtualSessionStore { store, root in
            let unknown = UUID()
            do {
                _ = try store.lookup(unknown)
                Issue.record("unknown session_id should fail closed")
            } catch {
                #expect(error.localizedDescription.contains("session_id is not active"))
            }
            let waxFiles = try FileManager.default.contentsOfDirectory(atPath: root.path)
                .filter { $0.hasSuffix(".wax") }
            #expect(waxFiles.isEmpty)
        }
    }

    @Test
    func startCreatesADistinctStoreNearFourMebibytes() async throws {
        try await withVirtualSessionStore { store, root in
            let started = try await startSession(store, agentID: "wal-agent", runID: "wal-run")
            #expect(started.resumed == false)
            let size = try waxFileSize(at: started.state.storeURL)
            #expect(size >= 4 * 1024 * 1024)
            #expect(size < 16 * 1024 * 1024)

            switch try store.lookup(started.state.id) {
            case .none:
                Issue.record("live session_id should route to the virtual session store")
            case .live:
                break
            }

            let waxFiles = try FileManager.default.contentsOfDirectory(atPath: root.path)
                .filter { $0.hasSuffix(".wax") }
            #expect(waxFiles.count == 1)
        }
    }

    @Test
    func sameAgentAndRunPairReusesTheActiveStore() async throws {
        try await withVirtualSessionStore { store, root in
            let first = try await startSession(store, agentID: "same-agent", runID: "same-run")
            let second = try await startSession(store, agentID: "same-agent", runID: "same-run")
            #expect(second.state.id == first.state.id)
            #expect(second.resumed == true)
            #expect(second.recoveredLease == false)
            let waxFiles = try FileManager.default.contentsOfDirectory(atPath: root.path)
                .filter { $0.hasSuffix(".wax") }
            #expect(waxFiles.count == 1)
        }
    }

    @Test
    func agentIDAloneDoesNotReuse() async throws {
        try await withVirtualSessionStore { store, _ in
            let first = try await startSession(store, agentID: "solo-agent", runID: "run-a")
            let second = try await startSession(store, agentID: "solo-agent", runID: "run-b")
            #expect(second.state.id != first.state.id)
            #expect(second.resumed == false)
        }
    }

    @Test
    func endedStoreIsNotReusedByTheSameAgentAndRunPair() async throws {
        try await withVirtualSessionStore { store, _ in
            let first = try await startSession(store, agentID: "ended-agent", runID: "ended-run")
            let ended = try await store.end(sessionID: first.state.id)
            #expect(ended.ended == true)

            do {
                _ = try store.lookup(first.state.id)
                Issue.record("ended session_id should fail closed")
            } catch {
                #expect(error.localizedDescription.contains("session_id is not active"))
            }

            let second = try await startSession(store, agentID: "ended-agent", runID: "ended-run")
            #expect(second.state.id != first.state.id)
            #expect(second.resumed == false)
        }
    }

    @Test
    func resumeStealsAForeignLeaseAndReportsRecoveredLease() async throws {
        try await withVirtualSessionStore(brokerInstanceID: "owner-a") { firstStore, root in
            let started = try await startSession(firstStore, agentID: "lease-agent", runID: "lease-run")
            await firstStore.closeAll()

            try await withVirtualSessionStore(
                brokerInstanceID: "owner-b",
                sessionRootURL: root,
                removeRootOnExit: false
            ) { secondStore, _ in
                let resumed = try await secondStore.resume(
                    explicitSessionID: started.state.id,
                    agentID: nil,
                    runID: nil
                )
                #expect(resumed.state.id == started.state.id)
                #expect(resumed.resumed == true)
                #expect(resumed.recoveredLease == true)
                #expect(resumed.state.manifest.brokerLeaseOwnerID == "owner-b")
            }
        }
    }

    @Test
    func startWithSameAgentAndRunOnANewProcessResumesAndStealsTheLease() async throws {
        try await withVirtualSessionStore(brokerInstanceID: "owner-a") { firstStore, root in
            _ = try await startSession(firstStore, agentID: "pair-agent", runID: "pair-run")
            await firstStore.closeAll()

            try await withVirtualSessionStore(
                brokerInstanceID: "owner-b",
                sessionRootURL: root,
                removeRootOnExit: false
            ) { secondStore, _ in
                let reused = try await startSession(secondStore, agentID: "pair-agent", runID: "pair-run")
                #expect(reused.resumed == true)
                #expect(reused.recoveredLease == true)
            }
        }
    }

    @Test
    func sessionEndWithoutIDEndsTheSoleLiveSession() async throws {
        try await withVirtualSessionStore { store, _ in
            let started = try await startSession(store, agentID: "sole-agent", runID: "sole-run")
            let ended = try await store.end(sessionID: nil)
            #expect(ended.ended == true)
            #expect(ended.sessionID == started.state.id)
            #expect(ended.remainingActive == false)
            #expect(ended.activeCount == 0)
        }
    }

    @Test
    func sessionEndWithoutIDIsIdleWhenNothingIsLive() async throws {
        try await withVirtualSessionStore { store, _ in
            let ended = try await store.end(sessionID: nil)
            #expect(ended.ended == false)
            #expect(ended.sessionID == nil)
            #expect(ended.activeCount == 0)
        }
    }

    @Test
    func lookupOfADiskActiveSessionNotLiveHereFailsClosed() async throws {
        try await withVirtualSessionStore(brokerInstanceID: "owner-a") { firstStore, root in
            let started = try await startSession(firstStore, agentID: "away-agent", runID: "away-run")
            let sessionID = started.state.id
            await firstStore.closeAll()

            try await withVirtualSessionStore(
                brokerInstanceID: "owner-b",
                sessionRootURL: root,
                removeRootOnExit: false
            ) { secondStore, _ in
                do {
                    _ = try secondStore.lookup(sessionID)
                    Issue.record("not-live-here session_id should fail closed")
                } catch {
                    #expect(error.localizedDescription.contains("session_id is not active"))
                }
                #expect(secondStore.live.isEmpty)
            }
        }
    }

    @Test
    func startWithAnExistingSessionIDRequiresResume() async throws {
        try await withVirtualSessionStore { store, _ in
            let started = try await startSession(store, agentID: "exists-agent", runID: "exists-run")
            await store.closeAll()
            do {
                _ = try await store.start(
                    explicitSessionID: started.state.id,
                    agentID: "other-agent",
                    runID: "other-run",
                    inferredScope: MemorySemantics.inferScopeContext()
                )
                Issue.record("existing session_id should require session_resume")
            } catch {
                #expect(error.localizedDescription.contains("use session_resume"))
            }
        }
    }

    @Test
    func resumeOfAnEndedSessionFailsClosed() async throws {
        try await withVirtualSessionStore { store, _ in
            let started = try await startSession(store, agentID: "ended-resume-agent", runID: "ended-resume-run")
            _ = try await store.end(sessionID: started.state.id)
            do {
                _ = try await store.resume(
                    explicitSessionID: started.state.id,
                    agentID: nil,
                    runID: nil
                )
                Issue.record("ended session_id should not resume")
            } catch {
                #expect(error.localizedDescription.contains("already been ended"))
            }
        }
    }

    @Test
    func endOfASessionThatIsNotLiveHereFailsClosed() async throws {
        try await withVirtualSessionStore { store, _ in
            do {
                _ = try await store.end(sessionID: UUID())
                Issue.record("unknown session_id should not end")
            } catch {
                #expect(error.localizedDescription.contains("session_id is not active"))
            }
        }
    }

    @Test
    func sessionEndWithoutIDRequiresAnIDWhenMoreThanOneIsLive() async throws {
        try await withVirtualSessionStore { store, _ in
            let first = try await startSession(store, agentID: "multi-a", runID: "run-a")
            _ = try await startSession(store, agentID: "multi-b", runID: "run-b")
            do {
                _ = try await store.end(sessionID: nil)
                Issue.record("session_end without session_id should fail when two sessions are live")
            } catch {
                #expect(error.localizedDescription.contains("session_id is required when more than one"))
            }
            let ended = try await store.end(sessionID: first.state.id)
            #expect(ended.ended == true)
            #expect(ended.remainingActive == true)
            #expect(ended.activeCount == 1)
        }
    }
}
