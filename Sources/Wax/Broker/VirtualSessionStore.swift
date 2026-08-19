import Foundation
import WaxCore

/// Internal virtual-session module: lifecycle, reuse, lease, session-file create, and
/// `session_id` routing. Omitted `session_id` is not a virtual session. Not public API.
///
/// `@unchecked Sendable` plus `NSLock` because async open hops off the owning
/// `AgentBrokerService` actor. Every `live` read/write goes through the lock.
package final class VirtualSessionStore: @unchecked Sendable {
    package struct SessionState: Sendable {
        package let id: UUID
        package var manifest: BrokerSessionManifest
        package let manifestURL: URL
        package let eventLogURL: URL
        package let storeURL: URL
        package let memory: MemoryOrchestrator
    }

    package struct LifecycleResult: Sendable {
        package let state: SessionState
        package let resumed: Bool
        package let recoveredLease: Bool
    }

    package struct EndResult: Sendable {
        package let sessionID: UUID?
        package let ended: Bool
        package let remainingActive: Bool
        package let activeCount: Int
    }

    package enum Lookup: Sendable {
        /// No virtual session. Caller uses long-term Memory.
        case none
        case live(MemoryOrchestrator)
    }

    package let sessionRootURL: URL
    package let brokerInstanceID: String
    private let leaseSeconds: Int
    private let nowMs: @Sendable () -> Int64
    private let waxOptions: WaxOptions
    private let openExisting: @Sendable (URL) async throws -> MemoryOrchestrator
    private let lock = NSLock()
    private var _live: [UUID: SessionState] = [:]

    package var live: [UUID: SessionState] {
        locked { _live }
    }

    package init(
        sessionRootURL: URL,
        brokerInstanceID: String,
        leaseSeconds: Int = AgentBrokerService.defaultSessionLeaseSeconds,
        nowMs: @escaping @Sendable () -> Int64 = { AgentBrokerService.nowMs() },
        waxOptions: WaxOptions = CommandLineEmbedderFactory.waxOptions(),
        openExisting: @escaping @Sendable (URL) async throws -> MemoryOrchestrator
    ) {
        self.sessionRootURL = sessionRootURL
        self.brokerInstanceID = brokerInstanceID
        self.leaseSeconds = leaseSeconds
        self.nowMs = nowMs
        self.waxOptions = waxOptions
        self.openExisting = openExisting
    }

    /// Open a session file. New files are created at `Constants.sessionWalSize`.
    /// Existing files keep their WAL. Resume/reuse must pass `createIfMissing: false`.
    package func openSessionMemory(at url: URL, createIfMissing: Bool = true) async throws -> MemoryOrchestrator {
        let exists = FileManager.default.fileExists(atPath: url.path)
        if !exists {
            guard createIfMissing else {
                throw BrokerValidationError.invalid(
                    "session store is missing at \(url.lastPathComponent); call session_start again"
                )
            }
            let created = try await Wax.create(
                at: url,
                walSize: Constants.sessionWalSize,
                options: waxOptions
            )
            try await created.close()
        }
        return try await openExisting(url)
    }

    package func start(
        explicitSessionID: UUID?,
        agentID: String?,
        runID: String?,
        inferredScope: MemoryScopeContext
    ) async throws -> LifecycleResult {
        if let agentID, let runID, let existing = try findActive(agentID: agentID, runID: runID) {
            if let explicitSessionID, explicitSessionID != existing.sessionID {
                throw BrokerValidationError.invalid(
                    "agent_id and run_id already have an active session; use session_resume"
                )
            }
            return try await resume(
                explicitSessionID: existing.sessionID,
                agentID: nil,
                runID: nil
            )
        }

        let sessionID = explicitSessionID ?? UUID()
        if let active = locked({ _live[sessionID] }) {
            return LifecycleResult(state: active, resumed: true, recoveredLease: false)
        }

        let manifestURL = BrokerSessionPersistence.manifestURL(rootURL: sessionRootURL, sessionID: sessionID)
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            throw BrokerValidationError.invalid("session_id already exists; use session_resume to reopen it")
        }

        let sessionURL = sessionRootURL.appendingPathComponent("\(sessionID.uuidString).wax")
        let eventLogURL = BrokerSessionPersistence.eventLogURL(rootURL: sessionRootURL, sessionID: sessionID)
        let memory = try await openSessionMemory(at: sessionURL, createIfMissing: true)
        do {
            if let agentID, let runID, let existing = try findActive(agentID: agentID, runID: runID) {
                try? await memory.close()
                if let explicitSessionID, explicitSessionID != existing.sessionID {
                    throw BrokerValidationError.invalid(
                        "agent_id and run_id already have an active session; use session_resume"
                    )
                }
                return try await resume(
                    explicitSessionID: existing.sessionID,
                    agentID: nil,
                    runID: nil
                )
            }
            if let active = locked({ _live[sessionID] }) {
                try? await memory.close()
                return LifecycleResult(state: active, resumed: true, recoveredLease: false)
            }

            let timestamp = nowMs()
            let resolvedAgentID = agentID ?? inferredScope.repoName ?? "wax-agent"
            let resolvedRunID = runID ?? UUID().uuidString
            let manifest = BrokerSessionManifest(
                sessionID: sessionID,
                agentID: resolvedAgentID,
                runID: resolvedRunID,
                project: inferredScope.projectName,
                repo: inferredScope.repoName,
                storePath: sessionURL.path,
                eventLogPath: eventLogURL.path,
                status: .active,
                brokerLeaseOwnerID: brokerInstanceID,
                leaseExpiresAtMs: timestamp + Int64(leaseSeconds * 1000),
                createdAtMs: timestamp,
                updatedAtMs: timestamp
            )
            try BrokerSessionPersistence.appendEvent(
                BrokerSessionEvent(
                    sessionID: sessionID,
                    agentID: resolvedAgentID,
                    runID: resolvedRunID,
                    timestampMs: timestamp,
                    kind: .started,
                    payload: [
                        "project": manifest.project ?? "",
                        "repo": manifest.repo ?? "",
                    ]
                ),
                to: eventLogURL
            )
            try BrokerSessionPersistence.saveManifest(manifest, to: manifestURL)
            let state = SessionState(
                id: sessionID,
                manifest: manifest,
                manifestURL: manifestURL,
                eventLogURL: eventLogURL,
                storeURL: sessionURL,
                memory: memory
            )
            locked { _live[sessionID] = state }
            return LifecycleResult(state: state, resumed: false, recoveredLease: false)
        } catch {
            try? await memory.close()
            throw error
        }
    }

    package func resume(
        explicitSessionID: UUID?,
        agentID: String?,
        runID: String?
    ) async throws -> LifecycleResult {
        let manifest = try resolveManifest(
            explicitSessionID: explicitSessionID,
            agentID: agentID,
            runID: runID
        )
        guard manifest.status == .active else {
            throw BrokerValidationError.invalid("session_id has already been ended and cannot be resumed")
        }

        if let existing = locked({ _live[manifest.sessionID] }) {
            return LifecycleResult(state: existing, resumed: true, recoveredLease: false)
        }

        let timestamp = nowMs()
        let recoveredLease = manifest.brokerLeaseOwnerID != nil && manifest.brokerLeaseOwnerID != brokerInstanceID
        let memory = try await openSessionMemory(
            at: URL(fileURLWithPath: manifest.storePath),
            createIfMissing: false
        )
        do {
            if let existing = locked({ _live[manifest.sessionID] }) {
                try? await memory.close()
                return LifecycleResult(state: existing, resumed: true, recoveredLease: false)
            }

            var refreshed = manifest
            refreshed.brokerLeaseOwnerID = brokerInstanceID
            refreshed.leaseExpiresAtMs = timestamp + Int64(leaseSeconds * 1000)
            refreshed.updatedAtMs = timestamp

            let manifestURL = BrokerSessionPersistence.manifestURL(rootURL: sessionRootURL, sessionID: manifest.sessionID)
            let eventLogURL = URL(fileURLWithPath: refreshed.eventLogPath)
            try BrokerSessionPersistence.appendEvent(
                BrokerSessionEvent(
                    sessionID: refreshed.sessionID,
                    agentID: refreshed.agentID,
                    runID: refreshed.runID,
                    timestampMs: timestamp,
                    kind: .resumed,
                    payload: [
                        "recovered_lease": recoveredLease ? "true" : "false",
                    ]
                ),
                to: eventLogURL
            )
            try BrokerSessionPersistence.saveManifest(refreshed, to: manifestURL)
            let state = SessionState(
                id: refreshed.sessionID,
                manifest: refreshed,
                manifestURL: manifestURL,
                eventLogURL: eventLogURL,
                storeURL: URL(fileURLWithPath: refreshed.storePath),
                memory: memory
            )
            locked { _live[refreshed.sessionID] = state }
            return LifecycleResult(state: state, resumed: true, recoveredLease: recoveredLease)
        } catch {
            try? await memory.close()
            throw error
        }
    }

    package func end(sessionID: UUID?) async throws -> EndResult {
        let snapshot: (target: UUID, state: SessionState)?
        switch (sessionID, locked({ _live.count })) {
        case let (.some(explicit), _):
            guard let state = locked({ _live[explicit] }) else {
                throw BrokerValidationError.invalid(
                    "session_id is not active in this broker process; call session_start again"
                )
            }
            snapshot = (explicit, state)
        case (.none, 1):
            let only = locked { _live.first! }
            snapshot = (only.key, only.value)
        case (.none, 0):
            return EndResult(sessionID: nil, ended: false, remainingActive: false, activeCount: 0)
        default:
            throw BrokerValidationError.invalid("session_id is required when more than one session is active")
        }

        let target = snapshot!.target
        let state = snapshot!.state
        var manifest = state.manifest
        manifest.status = .ended
        manifest.updatedAtMs = nowMs()
        manifest.brokerLeaseOwnerID = nil
        manifest.leaseExpiresAtMs = nil
        try BrokerSessionPersistence.saveManifest(manifest, to: state.manifestURL)
        try BrokerSessionPersistence.appendEvent(
            BrokerSessionEvent(
                sessionID: state.id,
                agentID: manifest.agentID,
                runID: manifest.runID,
                timestampMs: manifest.updatedAtMs,
                kind: .ended
            ),
            to: state.eventLogURL
        )
        try await state.memory.flush()
        try await state.memory.close()
        let remaining = locked { () -> Int in
            _live.removeValue(forKey: target)
            return _live.count
        }
        return EndResult(
            sessionID: target,
            ended: true,
            remainingActive: remaining > 0,
            activeCount: remaining
        )
    }

    /// Lookup never infers or mints. Omitted `session_id` is no virtual session.
    /// Unknown or not live here fails closed.
    package func lookup(_ sessionID: UUID?) throws -> Lookup {
        guard let sessionID else { return .none }
        guard let state = locked({ _live[sessionID] }) else {
            throw BrokerValidationError.invalid(
                "session_id is not active in this broker process; call session_start again"
            )
        }
        return .live(state.memory)
    }

    package func validateActive(_ sessionID: UUID?) throws {
        guard sessionID != nil else { return }
        _ = try lookup(sessionID)
    }

    package func requireLive(_ sessionID: UUID) throws -> SessionState {
        guard let state = locked({ _live[sessionID] }) else {
            throw BrokerValidationError.invalid(
                "session_id is not active in this broker process; call session_start again"
            )
        }
        return state
    }

    package func findActive(agentID: String, runID: String) throws -> BrokerSessionManifest? {
        if let liveMatch = locked({
            _live.values.first(where: {
                $0.manifest.agentID == agentID && $0.manifest.runID == runID
            })
        }) {
            return liveMatch.manifest
        }
        let matches = try BrokerSessionPersistence.listManifests(rootURL: sessionRootURL).filter { manifest in
            manifest.status == .active && manifest.agentID == agentID && manifest.runID == runID
        }
        if matches.count > 1 {
            throw BrokerValidationError.invalid("multiple active sessions matched agent_id and run_id")
        }
        return matches.first
    }

    package func resolveManifest(
        explicitSessionID: UUID?,
        agentID: String?,
        runID: String?
    ) throws -> BrokerSessionManifest {
        if let explicitSessionID {
            return try BrokerSessionPersistence.loadManifest(rootURL: sessionRootURL, sessionID: explicitSessionID)
        }

        let manifests = try BrokerSessionPersistence.listManifests(rootURL: sessionRootURL)
        let filtered = manifests.filter { manifest in
            guard manifest.status == .active else { return false }
            if let agentID, manifest.agentID != agentID { return false }
            if let runID, manifest.runID != runID { return false }
            return true
        }
        guard filtered.count <= 1 else {
            throw BrokerValidationError.invalid("multiple active sessions matched the requested selectors")
        }
        guard let match = filtered.first else {
            throw BrokerValidationError.invalid("No resumable session manifest matched the requested selectors")
        }
        return match
    }

    package func refreshManifest(_ sessionID: UUID) throws {
        try locked {
            guard var state = _live[sessionID] else {
                throw BrokerValidationError.invalid(
                    "session_id is not active in this broker process; call session_start again"
                )
            }
            state.manifest.updatedAtMs = nowMs()
            state.manifest.brokerLeaseOwnerID = brokerInstanceID
            state.manifest.leaseExpiresAtMs = state.manifest.updatedAtMs + Int64(leaseSeconds * 1000)
            try BrokerSessionPersistence.saveManifest(state.manifest, to: state.manifestURL)
            _live[sessionID] = state
        }
    }

    package func appendEvent(
        sessionID: UUID,
        kind: BrokerSessionEvent.Kind,
        payload: [String: String] = [:]
    ) throws {
        let state = try requireLive(sessionID)
        try BrokerSessionPersistence.appendEvent(
            BrokerSessionEvent(
                sessionID: sessionID,
                agentID: state.manifest.agentID,
                runID: state.manifest.runID,
                timestampMs: nowMs(),
                kind: kind,
                payload: payload
            ),
            to: state.eventLogURL
        )
    }

    package func replaceLive(_ state: SessionState) throws {
        try locked {
            guard _live[state.id] != nil else {
                throw BrokerValidationError.invalid(
                    "session_id is not active in this broker process; call session_start again"
                )
            }
            _live[state.id] = state
        }
    }

    package func closeAll() async {
        let sessions = locked { () -> [SessionState] in
            let values = Array(_live.values)
            _live.removeAll()
            return values
        }
        for session in sessions {
            try? await session.memory.flush()
            try? await session.memory.close()
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
