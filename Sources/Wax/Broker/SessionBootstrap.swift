import Foundation

/// Typed `session_open` handoff. Compacting reads these fields, not JSON keys.
package struct SessionHandoff: Sendable, Equatable {
    package var found: Bool
    package var content: String
    package var pendingTasks: [String]

    package init(found: Bool, content: String = "", pendingTasks: [String] = []) {
        self.found = found
        self.content = content
        self.pendingTasks = pendingTasks
    }

    /// Convert `handoff_latest` JSON once. Extra wire keys are dropped.
    package init(fromLatest value: AgentBrokerValue) {
        guard let object = value.objectValue, object["found"]?.boolValue == true else {
            self.init(found: false)
            return
        }
        self.init(
            found: true,
            content: object["content"]?.stringValue ?? "",
            pendingTasks: object["pending_tasks"]?.arrayValue?.compactMap(\.stringValue) ?? []
        )
    }
}

package struct SessionBootstrapResult: Sendable {
    package var sessionID: UUID
    package var rebound: Bool
    package var handoff: SessionHandoff
    package var recall: AgentBrokerValue?
    package var person: AgentBrokerValue?
}

/// Start/resume + typed handoff/recall for `session_open`. JSON packing stays on
/// ``SessionOpenAssembly``. Policy stays on ``SessionOpenDecision``.
package enum SessionBootstrap {
    package struct Environment: Sendable {
        package var sessions: VirtualSessionStore
        package var longTermMemory: MemoryOrchestrator
        package var nowMs: @Sendable () -> Int64
        package var recall: @Sendable (BrokerCommand.Recall) async throws -> AgentBrokerValue
        package var awaitQueryEmbedder: @Sendable (UUID) async throws -> Void
        package var makeTokenizer: @Sendable () async throws -> SessionOpenAssembly.Tokenizer

        package init(
            sessions: VirtualSessionStore,
            longTermMemory: MemoryOrchestrator,
            nowMs: @escaping @Sendable () -> Int64,
            recall: @escaping @Sendable (BrokerCommand.Recall) async throws -> AgentBrokerValue,
            awaitQueryEmbedder: @escaping @Sendable (UUID) async throws -> Void,
            makeTokenizer: @escaping @Sendable () async throws -> SessionOpenAssembly.Tokenizer
        ) {
            self.sessions = sessions
            self.longTermMemory = longTermMemory
            self.nowMs = nowMs
            self.recall = recall
            self.awaitQueryEmbedder = awaitQueryEmbedder
            self.makeTokenizer = makeTokenizer
        }
    }

    package static func open(
        command: BrokerCommand.SessionOpen,
        facts: SessionOpenDecision.Facts,
        inferredScope: MemoryScopeContext,
        in environment: Environment
    ) async throws -> AgentBrokerValue {
        let sessionID = try await startOrResume(
            command: command,
            facts: facts,
            inferredScope: inferredScope,
            in: environment
        )
        try stampIdentity(sessionID: sessionID, command: command, in: environment)
        let (resolvedProject, resolvedRepo) = resolvedScope(
            sessionID: sessionID,
            command: command,
            in: environment
        )
        let handoff = try await loadHandoff(project: resolvedProject, in: environment)
        let recallQuery = command.recallQuery
        var recallPayload: AgentBrokerValue?
        if let recallQuery, !recallQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try await environment.awaitQueryEmbedder(sessionID)
            recallPayload = try await environment.recall(
                projectRecall(
                    query: recallQuery,
                    sessionID: sessionID,
                    project: resolvedProject,
                    repo: resolvedRepo,
                    cwd: command.cwd
                )
            )
        }
        let personPayload = await personPayload(
            sessionID: sessionID,
            project: resolvedProject,
            repo: resolvedRepo,
            cwd: command.cwd,
            recall: environment.recall
        )
        let result = SessionBootstrapResult(
            sessionID: sessionID,
            rebound: SessionOpenDecision.rebound(returnedSessionID: sessionID, facts: facts),
            handoff: handoff,
            recall: recallPayload,
            person: personPayload
        )
        let tokenizer: SessionOpenAssembly.Tokenizer
        if SessionOpenAssembly.needsTokenizer(result.handoff) {
            tokenizer = try await environment.makeTokenizer()
        } else {
            tokenizer = .character
        }
        let compacted = await SessionOpenAssembly.compactHandoff(
            result.handoff,
            recallQuery: recallQuery,
            tokenizer: tokenizer
        )
        return SessionOpenAssembly.bootstrapPayload(
            sessionID: result.sessionID,
            rebound: result.rebound,
            handoff: compacted,
            recall: result.recall,
            person: result.person
        )
    }

    package static func projectRecall(
        query: String,
        sessionID: UUID,
        project: String?,
        repo: String?,
        cwd: String?
    ) -> BrokerCommand.Recall {
        BrokerCommand.Recall(
            query: query,
            limit: 5,
            searchTopK: 5,
            identity: .project(workingSessionID: sessionID),
            mode: nil,
            filters: recallFilters(sessionID: sessionID),
            explicitProject: project,
            explicitRepo: repo,
            clientCWD: cwd,
            // Continuity recall is for the session being opened: include its
            // own working lane. The fetch scopes working to request.sessionID,
            // so no other session's lane can leak in.
            includeWorking: true
        )
    }

    package static func personRecall(
        sessionID: UUID,
        project: String?,
        repo: String?,
        cwd: String?
    ) -> BrokerCommand.Recall {
        BrokerCommand.Recall(
            query: "facts about this person standing corrections",
            limit: 3,
            searchTopK: 3,
            identity: .global(workingSessionID: sessionID),
            mode: .textOnly,
            filters: recallFilters(sessionID: sessionID),
            explicitProject: project,
            explicitRepo: repo,
            clientCWD: cwd,
            memoryTypes: [.userPreference]
        )
    }

    package static func personPayload(
        sessionID: UUID,
        project: String?,
        repo: String?,
        cwd: String?,
        recall: (BrokerCommand.Recall) async throws -> AgentBrokerValue
    ) async -> AgentBrokerValue? {
        do {
            return try await recall(
                personRecall(sessionID: sessionID, project: project, repo: repo, cwd: cwd)
            )
        } catch {
            return nil
        }
    }

    package static func recallFilters(sessionID: UUID) -> BrokerCommand.ParsedSearchFilters {
        BrokerCommand.ParsedSearchFilters(
            sessionId: sessionID,
            frameFilter: nil,
            timeRange: nil,
            summary: .object([
                "session_id": .from(sessionID.uuidString),
                "metadata": .object([:]),
                "labels": .array([]),
                "time_after_ms": .null,
                "time_before_ms": .null,
                "include_deleted": .bool(false),
                "include_superseded": .bool(false),
                "include_surrogates": .bool(false),
                "frame_ids": .array([]),
                "has_frame_filter": .bool(false),
                "has_time_range": .bool(false),
            ])
        )
    }

    private static func startOrResume(
        command: BrokerCommand.SessionOpen,
        facts: SessionOpenDecision.Facts,
        inferredScope: MemoryScopeContext,
        in environment: Environment
    ) async throws -> UUID {
        let conversationID = facts.conversationID
        switch SessionOpenDecision.evaluate(facts) {
        case .resume(let resumeSessionID):
            // Conversation match may also stamp a new run_id; hinted resume restores
            // a connection session after broker restart without rewriting identity.
            _ = try await environment.sessions.resume(
                explicitSessionID: resumeSessionID,
                agentID: nil,
                runID: nil,
                reopenEnded: facts.conversationMatch?.sessionID == resumeSessionID
            )
            if let conversationMatch = facts.conversationMatch,
               conversationMatch.sessionID == resumeSessionID,
               let requestedRunID = facts.requestedRunID,
               conversationMatch.runID != requestedRunID
            {
                try environment.sessions.updateLive(resumeSessionID) { state in
                    state.manifest.runID = requestedRunID
                    state.manifest.updatedAtMs = environment.nowMs()
                }
            }
            return resumeSessionID
        case .startNew:
            // Conversation isolation mints a fresh UUID; otherwise start handles
            // exact pair / unique agent+project rebind.
            let explicitSessionID = conversationID == nil ? nil : UUID()
            let lifecycle = try await environment.sessions.start(
                explicitSessionID: explicitSessionID,
                agentID: command.agentID,
                runID: command.runID,
                inferredScope: inferredScope
            )
            if let conversationID {
                try environment.sessions.updateLive(lifecycle.state.id) { state in
                    state.manifest.conversationID = conversationID
                }
            }
            return lifecycle.state.id
        }
    }

    private static func stampIdentity(
        sessionID: UUID,
        command: BrokerCommand.SessionOpen,
        in environment: Environment
    ) throws {
        let conversationID = BrokerCommand.normalizedOrNil(command.conversationID)
        let trimmedProject = command.project?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedRepo = command.repo?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Explicit project must win over cwd inference for both project and repo.
        // Leaving a cwd-inferred repo would advertise a split identity and stamp
        // foreign wax.repo on later remembers.
        guard !trimmedProject.isEmpty || conversationID != nil else { return }
        try environment.sessions.updateLive(sessionID) { state in
            if !trimmedProject.isEmpty {
                state.manifest.project = trimmedProject
                state.manifest.repo = trimmedRepo.isEmpty ? trimmedProject : trimmedRepo
            }
            if let conversationID {
                state.manifest.conversationID = conversationID
            }
        }
    }

    private static func resolvedScope(
        sessionID: UUID,
        command: BrokerCommand.SessionOpen,
        in environment: Environment
    ) -> (String?, String?) {
        let inferred = command.cwd.map {
            MemorySemantics.inferScopeContext(currentDirectoryPath: $0)
        } ?? MemoryScopeContext()
        let project = BrokerCommand.normalizedOrNil(command.project)
        let repo = BrokerCommand.normalizedOrNil(command.repo)
        if let live = environment.sessions.live[sessionID] {
            return (
                live.manifest.project ?? project ?? inferred.projectName,
                live.manifest.repo ?? repo ?? inferred.repoName
            )
        }
        return (project ?? inferred.projectName, repo ?? inferred.repoName)
    }

    private static func loadHandoff(
        project: String?,
        in environment: Environment
    ) async throws -> SessionHandoff {
        guard let project else {
            // A missing project is an unresolved scope, not permission to read
            // the newest handoff across every project.
            return SessionHandoff(found: false)
        }
        guard let latest = try await environment.longTermMemory.latestHandoff(project: project) else {
            return SessionHandoff(found: false)
        }
        return SessionHandoff(found: true, content: latest.content, pendingTasks: latest.pendingTasks)
    }
}
