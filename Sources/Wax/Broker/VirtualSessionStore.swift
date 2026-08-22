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

    package enum LifecycleResult: Sendable {
        case started(SessionState)
        case resumed(SessionState, recoveredLease: Bool)

        package var state: SessionState {
            switch self {
            case .started(let state), .resumed(let state, _):
                return state
            }
        }

        package var resumed: Bool {
            switch self {
            case .started:
                return false
            case .resumed:
                return true
            }
        }

        package var recoveredLease: Bool {
            switch self {
            case .started:
                return false
            case .resumed(_, let recoveredLease):
                return recoveredLease
            }
        }
    }

    package enum EndResult: Sendable {
        case idle
        case ended(sessionID: UUID, remainingActive: Int)

        package var sessionID: UUID? {
            switch self {
            case .idle:
                return nil
            case .ended(let sessionID, _):
                return sessionID
            }
        }

        package var ended: Bool {
            switch self {
            case .idle:
                return false
            case .ended:
                return true
            }
        }

        package var remainingActive: Bool {
            activeCount > 0
        }

        package var activeCount: Int {
            switch self {
            case .idle:
                return 0
            case .ended(_, let remainingActive):
                return remainingActive
            }
        }
    }

    package enum Lookup: Sendable {
        /// No virtual session. Caller uses long-term Memory.
        case none
        case live(MemoryOrchestrator)
    }

    private enum EndTarget {
        case idle
        case session(id: UUID, state: SessionState)
        case missing(UUID)
        case requireSessionID
    }

    private struct SessionPairKey: Hashable, Sendable {
        var agentID: String
        var runID: String
    }

    package static let defaultSessionLeaseSeconds = 300

    package static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    package let sessionRootURL: URL
    package let brokerInstanceID: String
    private let leaseSeconds: Int
    private let nowMs: @Sendable () -> Int64
    private let waxOptions: WaxOptions
    private let openExisting: @Sendable (URL) async throws -> MemoryOrchestrator
    private let endMutex = AsyncMutex()
    private let lock = NSLock()
    private var _live: [UUID: SessionState] = [:]
    private var endingSessions: Set<UUID> = []
    private var endHoldForTesting: Duration?
    private var endCloseFailuresForTesting = 0
    private var endEventFailuresForTesting = 0
    private var creatingPairs: Set<SessionPairKey> = []
    private var pairWaiters: [SessionPairKey: [CheckedContinuation<LifecycleResult?, Error>]] = [:]

    package var live: [UUID: SessionState] {
        locked { _live.filter { !endingSessions.contains($0.key) } }
    }

    package func setEndHoldForTesting(_ duration: Duration?) {
        locked { endHoldForTesting = duration }
    }

    package func setEndCloseFailuresForTesting(_ count: Int) {
        locked { endCloseFailuresForTesting = max(0, count) }
    }

    package func setEndEventFailuresForTesting(_ count: Int) {
        locked { endEventFailuresForTesting = max(0, count) }
    }

    package init(
        sessionRootURL: URL,
        brokerInstanceID: String,
        leaseSeconds: Int = VirtualSessionStore.defaultSessionLeaseSeconds,
        nowMs: @escaping @Sendable () -> Int64 = { VirtualSessionStore.nowMs() },
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

    /// Create a session file at `Constants.sessionWalSize` when missing, then open it.
    /// Only `start` mints. Existing files keep their WAL.
    package func createSessionMemory(at url: URL) async throws -> MemoryOrchestrator {
        if !FileManager.default.fileExists(atPath: url.path) {
            let created = try await Wax.create(
                at: url,
                walSize: Constants.sessionWalSize,
                options: waxOptions
            )
            try await created.close()
        }
        return try await openExisting(url)
    }

    /// Open an existing session file. Missing files fail closed and do not mint.
    package func openExistingSessionMemory(at url: URL) async throws -> MemoryOrchestrator {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw BrokerValidationError.invalid(
                "session store is missing at \(url.lastPathComponent); call session_start again"
            )
        }
        return try await openExisting(url)
    }

    package func start(
        explicitSessionID: UUID?,
        agentID: String?,
        runID: String?,
        inferredScope: MemoryScopeContext
    ) async throws -> LifecycleResult {
        if let agentID, let runID, locked({ endingSessionMatchesLocked(agentID: agentID, runID: runID) }) {
            throw BrokerValidationError.invalid("agent_id and run_id session is ending; start a new run after it closes")
        }
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

        var claimedPair: SessionPairKey?
        if let agentID, let runID {
            if let waited = try await claimPairOrWait(agentID: agentID, runID: runID) {
                if let explicitSessionID, explicitSessionID != waited.state.id {
                    throw BrokerValidationError.invalid(
                        "agent_id and run_id already have an active session; use session_resume"
                    )
                }
                return waited
            }
            claimedPair = SessionPairKey(agentID: agentID, runID: runID)
        }

        do {
            let result = try await mintNewSession(
                explicitSessionID: explicitSessionID,
                agentID: agentID,
                runID: runID,
                inferredScope: inferredScope
            )
            if let claimedPair {
                completePairClaim(claimedPair, .success(result))
            }
            return result
        } catch {
            if let claimedPair {
                completePairClaim(claimedPair, .failure(error))
            }
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

        if let existing = locked({
            endingSessions.contains(manifest.sessionID) ? nil : _live[manifest.sessionID]
        }) {
            return .resumed(existing, recoveredLease: false)
        }
        if locked({ endingSessions.contains(manifest.sessionID) }) {
            throw Self.notActiveError(for: manifest.sessionID)
        }

        let timestamp = nowMs()
        let recoveredLease = manifest.brokerLeaseOwnerID != nil && manifest.brokerLeaseOwnerID != brokerInstanceID
        let memory = try await openExistingSessionMemory(at: URL(fileURLWithPath: manifest.storePath))
        do {
            if let existing = locked({
                endingSessions.contains(manifest.sessionID) ? nil : _live[manifest.sessionID]
            }) {
                try? await memory.close()
                return .resumed(existing, recoveredLease: false)
            }
            if locked({ endingSessions.contains(manifest.sessionID) }) {
                try? await memory.close()
                throw Self.notActiveError(for: manifest.sessionID)
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
            return .resumed(state, recoveredLease: recoveredLease)
        } catch {
            try? await memory.close()
            throw error
        }
    }

    /// Resolve which live session `end` would tear down, without mutating `_live`.
    package func peekEndTarget(sessionID: UUID?) throws -> UUID? {
        try locked {
            switch endTarget(sessionID) {
            case .idle:
                return nil
            case .session(let id, _):
                return id
            case .missing(let missingID):
                throw Self.notActiveError(for: missingID)
            case .requireSessionID:
                throw Self.requireSessionIDError
            }
        }
    }

    package func end(sessionID: UUID?) async throws -> EndResult {
        try await endMutex.withLock { [self] in
            try await endSerialized(sessionID: sessionID)
        }
    }

    private func endSerialized(sessionID: UUID?) async throws -> EndResult {
        let target: (id: UUID, state: SessionState)? = try locked {
            switch endTarget(sessionID) {
            case .idle:
                return nil
            case .missing(let missingID):
                throw Self.notActiveError(for: missingID)
            case .requireSessionID:
                throw Self.requireSessionIDError
            case .session(let id, let state):
                endingSessions.insert(id)
                return (id, state)
            }
        }

        guard let target else {
            return .idle
        }

        if let hold = locked({ endHoldForTesting }) {
            do {
                try await Task.sleep(for: hold)
            } catch {
                if target.state.manifest.status != .ended {
                    _ = locked { endingSessions.remove(target.id) }
                }
                throw error
            }
        }

        // `_live` retains the state for retry, while `endingSessions` removes it
        // from every routable view before the first suspension point.
        if target.state.manifest.status != .ended {
            do {
                try await target.state.memory.flush()
                _ = try locked {
                    guard var state = _live[target.id] else {
                        throw Self.notActiveError(for: target.id)
                    }
                    let timestamp = nowMs()
                    state.manifest.status = .ended
                    state.manifest.updatedAtMs = timestamp
                    state.manifest.brokerLeaseOwnerID = nil
                    state.manifest.leaseExpiresAtMs = nil
                    if endEventFailuresForTesting > 0 {
                        endEventFailuresForTesting -= 1
                        throw BrokerValidationError.invalid("injected session end event failure")
                    }
                    try BrokerSessionPersistence.appendEvent(
                        BrokerSessionEvent(
                            sessionID: state.id,
                            agentID: state.manifest.agentID,
                            runID: state.manifest.runID,
                            timestampMs: timestamp,
                            kind: .ended
                        ),
                        to: state.eventLogURL
                    )
                    try BrokerSessionPersistence.saveManifest(state.manifest, to: state.manifestURL)
                    _live[target.id] = state
                    return state
                }
            } catch {
                _ = locked { endingSessions.remove(target.id) }
                throw error
            }
        }

        // A close failure deliberately leaves the session reserved (not routable)
        // so a later explicit end can retry without admitting new writes.
        let injectCloseFailure = locked { () -> Bool in
            guard endCloseFailuresForTesting > 0 else { return false }
            endCloseFailuresForTesting -= 1
            return true
        }
        if injectCloseFailure {
            throw BrokerValidationError.invalid("injected session close failure")
        }
        try await target.state.memory.close()
        let remaining = locked {
            _live.removeValue(forKey: target.id)
            endingSessions.remove(target.id)
            return _live.count - endingSessions.count
        }
        return .ended(sessionID: target.id, remainingActive: remaining)
    }

    /// Lookup never infers or mints. Omitted `session_id` is no virtual session.
    /// Unknown or not live here fails closed (no auto-rebind).
    package func lookup(_ sessionID: UUID?) throws -> Lookup {
        guard let sessionID else { return .none }
        guard let state = locked({
            endingSessions.contains(sessionID) ? nil : _live[sessionID]
        }) else {
            throw Self.notActiveError(for: sessionID)
        }
        return .live(state.memory)
    }

    /// Returns the live orchestrator for `sessionID`, rebinding from disk when needed.
    ///
    /// On a `_live` miss, rebinds **only** the supplied UUID when its on-disk manifest is
    /// still `.active`. Never attaches a different session via `agent_id`+`run_id`.
    ///
    /// - Parameter sessionID: Session to resolve, or `nil` for no virtual session.
    /// - Returns: `.none` when `sessionID` is omitted; otherwise `.live` for that UUID.
    /// - Throws: ``BrokerSessionInactiveError`` when the UUID is unknown, ended, or unreadable.
    package func ensureLive(_ sessionID: UUID?) async throws -> Lookup {
        guard let sessionID else { return .none }
        if let state = locked({
            endingSessions.contains(sessionID) ? nil : _live[sessionID]
        }) {
            return .live(state.memory)
        }
        if locked({ endingSessions.contains(sessionID) }) {
            throw Self.notActiveError(for: sessionID)
        }

        let manifest: BrokerSessionManifest
        do {
            manifest = try BrokerSessionPersistence.loadManifest(
                rootURL: sessionRootURL,
                sessionID: sessionID
            )
        } catch BrokerSessionPersistenceError.manifestNotFound {
            throw BrokerSessionInactiveError.unknown(sessionID: sessionID)
        } catch {
            throw BrokerSessionInactiveError.unreadable(
                sessionID: sessionID,
                detail: error.localizedDescription
            )
        }

        guard manifest.status == .active else {
            throw BrokerSessionInactiveError.ended(sessionID: sessionID)
        }

        let result = try await resume(
            explicitSessionID: sessionID,
            agentID: nil,
            runID: nil
        )
        return .live(result.state.memory)
    }

    /// Verifies `sessionID` is already in this process's live map (no disk rebind).
    package func validateActive(_ sessionID: UUID?) throws {
        guard sessionID != nil else { return }
        _ = try lookup(sessionID)
    }

    package func validateActiveOrRebind(_ sessionID: UUID?) async throws {
        guard sessionID != nil else { return }
        _ = try await ensureLive(sessionID)
    }

    /// Returns the on-disk manifest status for `sessionID`, or `nil` if no manifest exists.
    package func persistedStatus(for sessionID: UUID) throws -> BrokerSessionManifest.Status? {
        do {
            return try BrokerSessionPersistence.loadManifest(
                rootURL: sessionRootURL,
                sessionID: sessionID
            ).status
        } catch BrokerSessionPersistenceError.manifestNotFound {
            return nil
        }
    }

    package func findActive(agentID: String, runID: String) throws -> BrokerSessionManifest? {
        if let liveMatch = locked({ liveMatchLocked(agentID: agentID, runID: runID) }) {
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
            guard !endingSessions.contains(sessionID), var state = _live[sessionID] else {
                throw Self.notActiveError(for: sessionID)
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
        let snapshot = try locked { () -> (agentID: String, runID: String, eventLogURL: URL) in
            guard !endingSessions.contains(sessionID), let state = _live[sessionID] else {
                throw Self.notActiveError(for: sessionID)
            }
            return (state.manifest.agentID, state.manifest.runID, state.eventLogURL)
        }
        try BrokerSessionPersistence.appendEvent(
            BrokerSessionEvent(
                sessionID: sessionID,
                agentID: snapshot.agentID,
                runID: snapshot.runID,
                timestampMs: nowMs(),
                kind: kind,
                payload: payload
            ),
            to: snapshot.eventLogURL
        )
    }

    package func updateLive(_ sessionID: UUID, _ body: (inout SessionState) throws -> Void) throws {
        try locked {
            guard !endingSessions.contains(sessionID), var state = _live[sessionID] else {
                throw Self.notActiveError(for: sessionID)
            }
            try body(&state)
            try BrokerSessionPersistence.saveManifest(state.manifest, to: state.manifestURL)
            _live[sessionID] = state
        }
    }

    package func closeAll() async {
        let sessions = locked { () -> [SessionState] in
            let values = Array(_live.values)
            _live.removeAll()
            endingSessions.removeAll()
            return values
        }
        for session in sessions {
            try? await session.memory.flush()
            try? await session.memory.close()
        }
    }

    private func mintNewSession(
        explicitSessionID: UUID?,
        agentID: String?,
        runID: String?,
        inferredScope: MemoryScopeContext
    ) async throws -> LifecycleResult {
        let sessionID = explicitSessionID ?? UUID()
        if let active = locked({
            endingSessions.contains(sessionID) ? nil : _live[sessionID]
        }) {
            return .resumed(active, recoveredLease: false)
        }
        if locked({ endingSessions.contains(sessionID) }) {
            throw Self.notActiveError(for: sessionID)
        }

        let manifestURL = BrokerSessionPersistence.manifestURL(rootURL: sessionRootURL, sessionID: sessionID)
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            throw BrokerValidationError.invalid("session_id already exists; use session_resume to reopen it")
        }

        let sessionURL = sessionRootURL.appendingPathComponent("\(sessionID.uuidString).wax")
        let eventLogURL = BrokerSessionPersistence.eventLogURL(rootURL: sessionRootURL, sessionID: sessionID)
        let memory = try await createSessionMemory(at: sessionURL)
        do {
            if let agentID, let runID, let existing = try findActive(agentID: agentID, runID: runID) {
                await abandonUnusedSessionFile(at: sessionURL, sessionID: sessionID, memory: memory)
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
            if let active = locked({
                endingSessions.contains(sessionID) ? nil : _live[sessionID]
            }) {
                try? await memory.close()
                return .resumed(active, recoveredLease: false)
            }
            if locked({ endingSessions.contains(sessionID) }) {
                try? await memory.close()
                throw Self.notActiveError(for: sessionID)
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
            try locked {
                if let active = _live[sessionID] {
                    throw PairInsertRace.alreadyLive(active)
                }
                if let agentID, let runID, let liveMatch = liveMatchLocked(agentID: agentID, runID: runID) {
                    throw PairInsertRace.pairTaken(liveMatch)
                }
                _live[sessionID] = state
            }
            return .started(state)
        } catch PairInsertRace.alreadyLive(let active) {
            try? await memory.close()
            return .resumed(active, recoveredLease: false)
        } catch PairInsertRace.pairTaken(let existing) {
            await abandonUnusedSessionFile(at: sessionURL, sessionID: sessionID, memory: memory)
            return try await resume(
                explicitSessionID: existing.id,
                agentID: nil,
                runID: nil
            )
        } catch {
            await abandonUnusedSessionFile(at: sessionURL, sessionID: sessionID, memory: memory)
            throw error
        }
    }

    private func claimPairOrWait(agentID: String, runID: String) async throws -> LifecycleResult? {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let live = liveMatchLocked(agentID: agentID, runID: runID) {
                lock.unlock()
                continuation.resume(returning: .resumed(live, recoveredLease: false))
                return
            }
            let key = SessionPairKey(agentID: agentID, runID: runID)
            if creatingPairs.contains(key) {
                pairWaiters[key, default: []].append(continuation)
                lock.unlock()
                return
            }
            creatingPairs.insert(key)
            lock.unlock()
            continuation.resume(returning: nil)
        }
    }

    private func completePairClaim(_ key: SessionPairKey, _ result: Result<LifecycleResult, Error>) {
        lock.lock()
        creatingPairs.remove(key)
        let waiters = pairWaiters.removeValue(forKey: key) ?? []
        lock.unlock()
        switch result {
        case .success(let lifecycle):
            let shared: LifecycleResult = .resumed(lifecycle.state, recoveredLease: false)
            for waiter in waiters {
                waiter.resume(returning: shared)
            }
        case .failure(let error):
            for waiter in waiters {
                waiter.resume(throwing: error)
            }
        }
    }

    private func endTarget(_ sessionID: UUID?) -> EndTarget {
        if let sessionID {
            if let state = _live[sessionID] {
                return .session(id: sessionID, state: state)
            }
            return .missing(sessionID)
        }
        if _live.isEmpty {
            return .idle
        }
        if let only = _live.first, _live.count == 1 {
            return .session(id: only.key, state: only.value)
        }
        return .requireSessionID
    }

    private func liveMatchLocked(agentID: String, runID: String) -> SessionState? {
        _live.first(where: {
            !endingSessions.contains($0.key)
                && $0.value.manifest.agentID == agentID
                && $0.value.manifest.runID == runID
        })?.value
    }

    private func endingSessionMatchesLocked(agentID: String, runID: String) -> Bool {
        _live.contains { entry in
            endingSessions.contains(entry.key)
                && entry.value.manifest.agentID == agentID
                && entry.value.manifest.runID == runID
        }
    }

    private func abandonUnusedSessionFile(
        at url: URL,
        sessionID: UUID,
        memory: MemoryOrchestrator
    ) async {
        try? await memory.close()
        let stillLive = locked { _live[sessionID] != nil }
        guard !stillLive else { return }
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(
            at: BrokerSessionPersistence.manifestURL(rootURL: sessionRootURL, sessionID: sessionID)
        )
        try? FileManager.default.removeItem(
            at: BrokerSessionPersistence.eventLogURL(rootURL: sessionRootURL, sessionID: sessionID)
        )
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// Prefer ``ensureLive`` on write/recall paths so active manifests rebind (C4).
    /// This error is for `_live`-only checks that intentionally do not rebind.
    private static func notActiveError(for sessionID: UUID) -> BrokerSessionInactiveError {
        .notLive(sessionID: sessionID)
    }

    private static var requireSessionIDError: BrokerValidationError {
        .invalid("session_id is required when more than one session is active")
    }

    private enum PairInsertRace: Error {
        case alreadyLive(SessionState)
        case pairTaken(SessionState)
    }
}
