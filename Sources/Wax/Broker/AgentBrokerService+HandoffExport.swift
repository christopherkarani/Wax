import Foundation
import WaxCore

extension AgentBrokerService {
    func handoff(_ command: BrokerCommand.Handoff) async throws -> AgentBrokerValue {
        let content = command.content
        let pendingTasks = command.pendingTasks
        let sessionID = command.sessionID
        try await validateActiveSession(sessionID)
        let project = BrokerCommand.normalizedOrNil(command.project)
            ?? writeScope(for: sessionID).projectName
        let frameId = try await longTermMemory.rememberHandoff(
            content: content,
            project: project,
            pendingTasks: pendingTasks,
            sessionId: sessionID,
            commit: false
        )
        if let sessionID {
            try await recordHandoff(sessionID: sessionID, content: content)
        }
        try await longTermMemory.flush()
        return .object([
            "status": .string("ok"),
            "frame_id": .from(frameId),
            "committed": .bool(true),
            "display_text": .string("Handoff stored (frame \(frameId))."),
        ])
    }

    func handoffLatest(_ command: BrokerCommand.HandoffLatest) async throws -> AgentBrokerValue {
        let project = command.project
        guard let latest = try await longTermMemory.latestHandoff(project: project) else {
            return .object(["found": .bool(false)])
        }
        return .object([
            "found": .bool(true),
            "frame_id": .from(latest.frameId),
            "timestamp_ms": .from(latest.timestampMs),
            "project": .from(latest.project),
            "pending_tasks": .array(latest.pendingTasks.map { .string($0) }),
            "content": .string(latest.content),
            "display_text": .string(latest.content),
        ])
    }

    func compactContext(_ command: BrokerCommand.CompactContext) async throws -> AgentBrokerValue {
        let query = command.query
        let tokenBudget = command.tokenBudget
        let maxItems = command.maxItems
        let mode = command.mode
        let sessionID: UUID?
        switch try resolveSessionScope(command.sessionID, policy: .requireUnambiguousWorking) {
        case .session(let resolved):
            sessionID = resolved
        case .none, .durableOnly:
            sessionID = nil
        }
        if let sessionID {
            let sessionMemory = try await memory(for: sessionID)
            try await sessionMemory.flush()
            try await refreshSessionManifest(sessionID)
        }
        try await longTermMemory.flush()
        let counter = try await TokenCounter.shared()
        let tokenizer = CompactAssembly.Tokenizer(
            count: { text in await counter.count(text) },
            truncate: { text, maxTokens in await counter.truncate(text, maxTokens: maxTokens) }
        )
        let assembled = try await CompactAssembly.assemble(
            request: CompactAssembly.Request(
                query: query,
                sessionID: sessionID,
                mode: mode,
                tokenBudget: tokenBudget,
                maxItems: maxItems
            ),
            stores: layeredRecallStores(),
            tokenizer: tokenizer
        )
        if let sessionID {
            try await recordCheckpoint(
                sessionID: sessionID,
                summary: assembled.summary,
                compactedText: assembled.compactedText
            )
        }
        for hit in assembled.short + assembled.medium + assembled.long {
            if hit.horizon == .durable {
                await longTermMemory.recordAccess(frameId: hit.frameID)
            } else if let sessionID = hit.sessionID, let session = activeSessions[sessionID] {
                await session.memory.recordAccess(frameId: hit.frameID)
            }
        }
        let nowMs = BrokerClock.nowMs()
        return .object([
            "query": .string(query),
            "token_budget": .from(tokenBudget),
            "used_tokens": .from(assembled.usedTokens),
            "summary": .string(assembled.summary),
            "short_context": .array(assembled.short.map {
                RecallPresent.renderCompactLayeredMemoryHit($0, nowMs: nowMs)
            }),
            "medium_context": .array(assembled.medium.map {
                RecallPresent.renderCompactLayeredMemoryHit($0, nowMs: nowMs)
            }),
            "long_context": .array(assembled.long.map {
                RecallPresent.renderCompactLayeredMemoryHit($0, nowMs: nowMs)
            }),
            "compacted_text": .string(assembled.compactedText),
            "display_text": .string(assembled.compactedText),
        ])
    }

    func markdownExport(_ command: BrokerCommand.MarkdownExport) async throws -> AgentBrokerValue {
        let sessionID = command.sessionID
        let allProjects = command.allProjects
        let explicitProject = command.project
        let clientCWD = command.cwd
        try validateMarkdownExportSession(sessionID)
        let exportURL = URL(
            fileURLWithPath: AgentBrokerPathing.expandPath(command.outputDir),
            isDirectory: true
        ).standardizedFileURL
        let inferredProject: String?
        if allProjects {
            inferredProject = nil
        } else if let explicitProject {
            inferredProject = explicitProject
        } else if let sessionID, let session = activeSessions[sessionID] {
            inferredProject = session.manifest.project
        } else {
            inferredProject = writeScope(for: nil, clientCWD: clientCWD).projectName
        }
        let report = try await exportMarkdownProjection(
            outputURL: exportURL,
            sessionID: sessionID,
            project: inferredProject
        )
        return .object([
            "status": .string("ok"),
            "output_dir": .string(exportURL.path),
            "memory_md_path": .string(report.memoryMarkdownPath),
            "daily_note_paths": .array(report.dailyNotePaths.map(AgentBrokerValue.string)),
            "dreams_path": .from(report.dreamsPath),
            "handoff_summary_path": .from(report.handoffSummaryPath),
            "display_text": .string("Exported Markdown projection to \(exportURL.path)"),
        ])
    }

    private func validateMarkdownExportSession(_ sessionID: UUID?) throws {
        guard let sessionID else { return }
        let manifestURL = BrokerSessionPersistence.manifestURL(rootURL: sessionRootURL, sessionID: sessionID)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw BrokerValidationError.invalid("No session manifest found for session_id \(sessionID.uuidString)")
        }
        let manifest = try BrokerSessionPersistence.loadManifest(at: manifestURL)
        if manifest.status == .active && activeSessions[sessionID] == nil {
            throw BrokerValidationError.invalid("session_id is active in another broker process; call session_resume before exporting it")
        }
    }

    func markdownSync(_ command: BrokerCommand.MarkdownSync) async throws -> AgentBrokerValue {
        let dryRun = command.dryRun
        let rootURL = URL(fileURLWithPath: AgentBrokerPathing.expandPath(command.rootDir), isDirectory: true).standardizedFileURL
        let report = try await syncMarkdownProjection(rootURL: rootURL, dryRun: dryRun)
        return .object([
            "status": .string("ok"),
            "dry_run": .bool(dryRun),
            "root_dir": .string(report.rootDir),
            "memory_md_path": .from(report.memoryPath),
            "daily_note_paths": .array(report.dailyNotePaths.map(AgentBrokerValue.string)),
            "dreams_path": .from(report.dreamsPath),
            "counts": .object([
                "created": .from(report.counts.created),
                "updated": .from(report.counts.updated),
                "deleted": .from(report.counts.deleted),
                "unchanged": .from(report.counts.unchanged),
                "approved_dreams": .from(report.counts.approvedDreams),
                "rejected_dreams": .from(report.counts.rejectedDreams),
            ]),
            "display_text": .string(
                "\(dryRun ? "Dry-run sync for" : "Synced") Markdown projection from \(report.rootDir): " +
                    "\(report.counts.created) created, \(report.counts.updated) updated, " +
                    "\(report.counts.deleted) deleted, \(report.counts.approvedDreams) dreams approved."
            ),
        ])
    }
}
