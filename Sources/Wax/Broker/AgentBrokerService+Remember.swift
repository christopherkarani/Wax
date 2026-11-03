import Foundation
import WaxCore

extension AgentBrokerService {
    func remember(_ command: BrokerCommand.Remember) async throws -> AgentBrokerValue {
        let sessionID = command.sessionID
        let stampSessionID = command.clientSessionID ?? sessionID
        // Rebind before writeScope so session manifest project/repo stamp correctly after a broker hop.
        // Durable types may still carry a wire session_id for identity even though destination is durable.
        if let stampSessionID {
            _ = try await memory(for: stampSessionID)
        }
        let inferredScope = writeScope(for: stampSessionID, clientCWD: command.cwd)
        let metadata = try MemorySemantics.validatedWriteMetadata(
            metadata: command.metadata,
            destination: command.destination,
            activeSession: stampSessionID != nil,
            inferredScope: inferredScope,
            nowMs: BrokerClock.nowMs()
        )
        try validateDurableWriteContent(content: command.content, metadata: metadata)
        let memory = try await memory(for: sessionID)
        if let stampSessionID {
            try await refreshSessionManifest(stampSessionID)
        }

        let before = await memory.runtimeStats()
        if !noEmbedder, before.vectorSearchEnabled, await memory.shouldDeferRememberUntilEmbedderReady() {
            do {
                try await Self.awaitRememberReady(
                    memory: memory,
                    timeout: .seconds(BrokerLimits.embedderReadyWaitSeconds)
                )
            } catch {
                throw BrokerValidationError.invalid(
                    "Remember failed: embedding provider not ready (\(error.localizedDescription))"
                )
            }
        }

        return try await completeRemember(
            memory: memory,
            content: command.content,
            metadata: metadata,
            sessionID: sessionID,
            echoedSessionID: stampSessionID,
            inferredScope: inferredScope
        )
    }

    /// Suspends until `memory` can accept remember writes, or fails after `timeout`.
    package static func awaitRememberReady(
        memory: MemoryOrchestrator,
        timeout: Duration
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await memory.waitUntilReadyForRemember()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw BrokerValidationError.invalid(
                    "embedding provider did not become ready within \(timeout.components.seconds)s"
                )
            }
            defer { group.cancelAll() }
            guard try await group.next() != nil else {
                throw BrokerValidationError.invalid("embedding provider readiness wait produced no result")
            }
        }
    }

    func completeRemember(
        memory: MemoryOrchestrator,
        content: String,
        metadata: [String: String],
        sessionID: UUID?,
        echoedSessionID: UUID? = nil,
        inferredScope: MemoryScopeContext = MemoryScopeContext()
    ) async throws -> AgentBrokerValue {
        let rememberResult = try await memory.remember(content, metadata: metadata)
        if let sessionID {
            try await refreshSessionManifest(sessionID)
            try await appendSessionEvent(
                sessionID: sessionID,
                kind: .remembered,
                payload: [
                    "content_hash": Self.stableHash(content),
                    "memory_type": metadata[MemoryMetadataKeys.type] ?? MemoryType.note.rawValue,
                    "durability": metadata[MemoryMetadataKeys.durability] ?? MemoryDurability.working.rawValue,
                ]
            )
        }
        try await memory.flush()
        await autoSupersedeSimilarDurableFrames(
            memory: memory,
            newFrameId: rememberResult.frameId,
            content: content,
            metadata: metadata,
            sessionID: sessionID
        )
        await OwnerCard.compileIfNeeded(
            memory: memory,
            content: content,
            metadata: metadata,
            frameId: rememberResult.frameId,
            nowMs: BrokerClock.nowMs()
        )
        let after = await memory.runtimeStats()
        return RememberAssembly.payload(
            frameId: rememberResult.frameId,
            framesAdded: rememberResult.framesAdded,
            frameCount: after.frameCount,
            pendingFrames: after.pendingFrames,
            sessionID: sessionID,
            echoedSessionID: echoedSessionID ?? sessionID,
            metadata: metadata,
            inferredScope: inferredScope,
            deduplicated: rememberResult.deduplicated,
            searchable: rememberResult.searchable,
            content: content
        )
    }

    /// Same-project Jaccard ≥ threshold retires prior unsuperseded durable twins. Locked stays live.
    /// Pending `supersededBy` is passed into selection so a swallowed supersede
    /// flush cannot restamp the same predecessor. Selection lives in
    /// ``RememberAssembly``; this method still owns corpus I/O + supersede + flush.
    private func autoSupersedeSimilarDurableFrames(
        memory: MemoryOrchestrator,
        newFrameId: UInt64,
        content: String,
        metadata: [String: String],
        sessionID: UUID?
    ) async {
        let nowMs = BrokerClock.nowMs()
        guard RememberAssembly.isAutoSupersedeEligible(
            sessionID: sessionID,
            metadata: metadata,
            nowMs: nowMs
        ) else {
            return
        }

        let info = MemorySemantics.parse(metadata: metadata, nowMs: nowMs)
        guard let project = info.project else { return }
        let documents: [MemoryOrchestrator.CorpusSourceDocument]
        do {
            // Narrow on metadata before reading payloads: only same-type,
            // same-project durable rows can ever be superseded.
            documents = try await memory.corpusSourceDocuments(matchingMetadata: { candidate in
                RememberAssembly.isSupersedeCandidate(
                    metadata: candidate,
                    supersededBy: nil,
                    type: info.type,
                    project: project,
                    nowMs: nowMs
                )
            })
        } catch {
            WaxDiagnostics.logSwallowed(
                error,
                context: "durable remember supersede scan",
                fallback: "remember succeeded without auto-supersede"
            )
            return
        }

        let pendingByID = await memory.wax.frameMetasIncludingPending(
            frameIds: documents.map(\.frameId)
        )
        let frameIDs = RememberAssembly.selectSupersedeFrameIDs(
            sessionID: sessionID,
            newFrameId: newFrameId,
            content: content,
            metadata: metadata,
            documents: documents.map {
                RememberAssembly.Candidate(
                    frameId: $0.frameId,
                    text: $0.text,
                    metadata: $0.metadata,
                    supersededBy: pendingByID[$0.frameId]?.supersededBy
                )
            },
            nowMs: nowMs
        )
        guard !frameIDs.isEmpty else { return }

        var supersededAny = false
        for frameID in frameIDs {
            do {
                try await memory.wax.supersede(
                    supersededId: frameID,
                    supersedingId: newFrameId
                )
                supersededAny = true
            } catch {
                WaxDiagnostics.logSwallowed(
                    error,
                    context: "durable remember supersede",
                    fallback: "previous similar frame may remain active"
                )
            }
        }

        guard supersededAny else { return }
        do {
            try await memory.flush()
        } catch {
            WaxDiagnostics.logSwallowed(
                error,
                context: "durable remember supersede flush",
                fallback: "supersede may remain pending until next flush"
            )
        }
    }

    func flush() async throws -> AgentBrokerValue {
        try await longTermMemory.flush()
        for session in activeSessions.values {
            try await session.memory.flush()
        }
        let stats = await longTermMemory.runtimeStats()
        let message = "Flushed. \(stats.frameCount) frames now searchable."
        return .object([
            "status": .string("ok"),
            "message": .string(message),
            "frameCount": .from(stats.frameCount),
            "pendingFrames": .from(stats.pendingFrames),
            "display_text": .string(message),
        ])
    }
}
