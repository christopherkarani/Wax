import Foundation
import Testing
@testable import Wax

/// Session manifest and event-log writes fsync. A request that writes one must not
/// hold a cooperative thread, or the session state lock every lookup takes, while it does.
@Suite struct VirtualSessionStoreFileWriteTests {
    @Test func everySessionFileWriteRunsOffTheCooperativePoolWithoutTheStateLock() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-session-writes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VirtualSessionStore(
            sessionRootURL: root,
            brokerInstanceID: UUID().uuidString,
            openExisting: { url, _ in
                var config = OrchestratorConfig.default
                config.enableVectorSearch = false
                config.enableStructuredMemory = false
                return try await MemoryOrchestrator(at: url, config: config)
            }
        )
        let writes = WriteRecorder()
        store.setFileWriteHookForTesting { [weak store] in
            writes.record(
                queue: currentQueueLabel(),
                stateLockHeld: store?.stateLockIsHeldForTesting() ?? false
            )
        }

        let started = try await store.start(
            explicitSessionID: nil,
            agentID: "write-probe-agent",
            runID: "write-probe-run",
            inferredScope: MemoryScopeContext(repoName: "WaxTest", projectName: "WaxTest")
        )
        let sessionID = started.state.id
        try await store.refreshManifest(sessionID)
        try await store.appendEvent(sessionID: sessionID, kind: .handoff, payload: ["summary": "probe"])
        try await store.updateLive(sessionID) { state in
            state.manifest.latestHandoff = "probe"
        }
        _ = try await store.end(sessionID: sessionID)
        await store.closeAll()

        let recorded = writes.all()
        // start: event + manifest; refresh; event; update; end: event + manifest.
        #expect(recorded.count == 7)
        #expect(recorded.allSatisfy { !$0.queue.contains("cooperative") }, "\(recorded.map(\.queue))")
        #expect(recorded.allSatisfy { !$0.stateLockHeld }, "\(recorded.map(\.stateLockHeld))")
        let manifest = try BrokerSessionPersistence.loadManifest(rootURL: root, sessionID: sessionID)
        #expect(manifest.status == .ended)
        #expect(manifest.latestHandoff == "probe")
    }
}

private func currentQueueLabel() -> String {
    #if canImport(Darwin)
    String(cString: __dispatch_queue_get_label(nil))
    #else
    // Linux Dispatch has no current-queue label lookup; the state-lock check still runs.
    ""
    #endif
}

private final class WriteRecorder: @unchecked Sendable {
    struct Write: Sendable {
        var queue: String
        var stateLockHeld: Bool
    }

    private let lock = NSLock()
    private var writes: [Write] = []

    func record(queue: String, stateLockHeld: Bool) {
        lock.withLock { writes.append(Write(queue: queue, stateLockHeld: stateLockHeld)) }
    }

    func all() -> [Write] { lock.withLock { writes } }
}
