import Foundation
import WaxCore

/// Policy for task-state records that no longer have valid session provenance.
package enum TaskStateOrphanPolicy: String, CaseIterable, Codable, Sendable, Equatable {
    /// Preserve the text as working, non-task-state memory with an audit marker.
    case quarantine
    /// Omit the orphan record from the repaired destination.
    case drop
}

/// Auditable result of a copy-first task-state repair.
package struct TaskStateMigrationReport: Codable, Sendable, Equatable {
    package var schemaVersion: Int
    package var sourcePath: String
    package var destinationPath: String
    package var orphanPolicy: TaskStateOrphanPolicy
    package var sourceHash: String
    package var destinationHash: String?
    package var sourcePreserved: Bool
    package var verified: Bool
    package var idempotent: Bool
    package var sourceDocumentCount: Int
    package var copiedDocumentCount: Int
    package var rehomedDocumentCount: Int
    package var quarantinedDocumentCount: Int
    package var droppedDocumentCount: Int

    package init(
        schemaVersion: Int = 1,
        sourcePath: String,
        destinationPath: String,
        orphanPolicy: TaskStateOrphanPolicy,
        sourceHash: String,
        destinationHash: String? = nil,
        sourcePreserved: Bool = false,
        verified: Bool = false,
        idempotent: Bool = false,
        sourceDocumentCount: Int,
        copiedDocumentCount: Int,
        rehomedDocumentCount: Int,
        quarantinedDocumentCount: Int,
        droppedDocumentCount: Int
    ) {
        self.schemaVersion = schemaVersion
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.orphanPolicy = orphanPolicy
        self.sourceHash = sourceHash
        self.destinationHash = destinationHash
        self.sourcePreserved = sourcePreserved
        self.verified = verified
        self.idempotent = idempotent
        self.sourceDocumentCount = sourceDocumentCount
        self.copiedDocumentCount = copiedDocumentCount
        self.rehomedDocumentCount = rehomedDocumentCount
        self.quarantinedDocumentCount = quarantinedDocumentCount
        self.droppedDocumentCount = droppedDocumentCount
    }
}

package extension AgentBrokerService {
    private static let taskStateMigrationSchema = "task_state_v1"
    private static let taskStateMigrationManifestSuffix = ".task-state-migration.json"

    /// Copy the live long-term document set into a distinct destination while
    /// repairing task-state records. The source is flushed and hashed before
    /// copying, and is never opened for write by this operation.
    func taskStateMigrate(_ command: BrokerCommand.TaskStateMigrate) async throws -> AgentBrokerValue {
        try await longTermMemory.flush()

        let sourceURL = longTermStoreURL.standardizedFileURL
        let destinationURL = URL(
            fileURLWithPath: AgentBrokerPathing.expandPath(command.destinationPath)
        ).standardizedFileURL
        guard sourceURL != destinationURL else {
            throw BrokerValidationError.invalid("task_state migration destination must differ from the source store")
        }

        let sourceHash = try Self.sha256File(at: sourceURL)
        let manifestURL = Self.taskStateMigrationManifestURL(for: destinationURL)
        let sourceDocuments = try await longTermMemory.corpusSourceDocuments()

        if !command.dryRun,
           let existing = try Self.loadTaskStateMigrationManifest(at: manifestURL),
           existing.sourcePath == sourceURL.path,
           existing.destinationPath == destinationURL.path,
           existing.sourceHash == sourceHash,
           existing.orphanPolicy == command.orphanPolicy,
           FileManager.default.fileExists(atPath: destinationURL.path) {
            let verified = try await Self.verifyTaskStateMigrationDestination(
                at: destinationURL,
                expectedDocumentCount: existing.copiedDocumentCount
            )
            guard verified else {
                throw BrokerValidationError.invalid(
                    "task_state migration manifest does not match a verified destination; pass overwrite_destination=true"
                )
            }
            var idempotent = existing
            idempotent.destinationHash = try Self.sha256File(at: destinationURL)
            idempotent.sourcePreserved = try Self.sha256File(at: sourceURL) == sourceHash
            idempotent.verified = true
            idempotent.idempotent = true
            return Self.taskStateMigrationPayload(idempotent)
        }

        let plan = try makeTaskStateMigrationPlan(
            documents: sourceDocuments,
            sourceHash: sourceHash,
            destinationURL: destinationURL,
            orphanPolicy: command.orphanPolicy
        )
        if command.dryRun {
            var report = plan.report
            // The source has not been opened for write during a dry run; the
            // pre-copy hash therefore already proves source preservation.
            report.sourcePreserved = true
            return Self.taskStateMigrationPayload(report)
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: destinationURL.path) {
            guard command.overwriteDestination else {
                throw BrokerValidationError.invalid(
                    "task_state migration destination already exists; pass overwrite_destination=true to replace it"
                )
            }
        }

        let buildURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".\(destinationURL.deletingPathExtension().lastPathComponent)-task-state-migration-\(UUID().uuidString)")
            .appendingPathExtension("wax")
        if fileManager.fileExists(atPath: buildURL.path) {
            try fileManager.removeItem(at: buildURL)
        }

        var config = OrchestratorConfig.default
        config.enableTextSearch = true
        config.enableVectorSearch = false
        config.enableStructuredMemory = false
        config.enableAccessStatsScoring = false

        let target = try await MemoryOrchestrator(at: buildURL, config: config)
        do {
            try await target.ingestCorpusDocumentsTextOnly(plan.documents)
            try await target.flush()
            try await target.close()
        } catch {
            try? await target.close()
            try? fileManager.removeItem(at: buildURL)
            throw error
        }

        let verifiedBuild: Bool
        do {
            verifiedBuild = try await Self.verifyTaskStateMigrationDestination(
                at: buildURL,
                expectedDocumentCount: plan.copiedDocumentCount
            )
        } catch {
            try? fileManager.removeItem(at: buildURL)
            throw error
        }
        guard verifiedBuild else {
            try? fileManager.removeItem(at: buildURL)
            throw BrokerValidationError.invalid("task_state migration destination failed deep verification")
        }
        guard try Self.sha256File(at: sourceURL) == sourceHash else {
            try? fileManager.removeItem(at: buildURL)
            throw BrokerValidationError.invalid("task_state migration source changed during copy")
        }

        do {
            try Self.installTaskStateMigrationBuild(
                buildURL,
                at: destinationURL,
                overwrite: command.overwriteDestination
            )
        } catch {
            try? fileManager.removeItem(at: buildURL)
            throw error
        }

        let destinationHash = try Self.sha256File(at: destinationURL)
        let sourcePreserved = try Self.sha256File(at: sourceURL) == sourceHash
        guard sourcePreserved else {
            throw BrokerValidationError.invalid("task_state migration source changed during copy")
        }

        var report = plan.report
        report.destinationHash = destinationHash
        report.sourcePreserved = true
        report.verified = true
        report.idempotent = false
        try Self.saveTaskStateMigrationManifest(report, at: manifestURL)
        return Self.taskStateMigrationPayload(report)
    }

    private struct TaskStateMigrationPlan {
        var report: TaskStateMigrationReport
        var documents: [MemoryOrchestrator.CorpusTargetDocument]

        var sourcePath: String { report.sourcePath }
        var destinationPath: String { report.destinationPath }
        var orphanPolicy: TaskStateOrphanPolicy { report.orphanPolicy }
        var sourceHash: String { report.sourceHash }
        var destinationHash: String? { report.destinationHash }
        var sourcePreserved: Bool { report.sourcePreserved }
        var verified: Bool { report.verified }
        var idempotent: Bool { report.idempotent }
        var sourceDocumentCount: Int { report.sourceDocumentCount }
        var copiedDocumentCount: Int { report.copiedDocumentCount }
        var rehomedDocumentCount: Int { report.rehomedDocumentCount }
        var quarantinedDocumentCount: Int { report.quarantinedDocumentCount }
        var droppedDocumentCount: Int { report.droppedDocumentCount }
    }

    private func makeTaskStateMigrationPlan(
        documents: [MemoryOrchestrator.CorpusSourceDocument],
        sourceHash: String,
        destinationURL: URL,
        orphanPolicy: TaskStateOrphanPolicy
    ) throws -> TaskStateMigrationPlan {
        var targets: [MemoryOrchestrator.CorpusTargetDocument] = []
        targets.reserveCapacity(documents.count)
        var rehomed = 0
        var quarantined = 0
        var dropped = 0

        for document in documents {
            let contentHash = Self.sha256Text(document.text)
            let info = MemorySemantics.parse(metadata: document.metadata, nowMs: Self.nowMs())
            let provenance = taskStateSessionID(in: document.metadata)
            let hasTaskState = info.type == .taskState
            let validSession = if let provenance {
                validSessionProvenance(provenance)
            } else {
                false
            }

            var metadata = document.metadata
            metadata[MemoryMetadataKeys.migrationSchema] = Self.taskStateMigrationSchema
            metadata[MemoryMetadataKeys.migrationSourceFrameID] = String(document.frameId)
            metadata[MemoryMetadataKeys.migrationSourceContentHash] = contentHash
            metadata[MemoryMetadataKeys.migrationSourceStoreHash] = sourceHash

            if hasTaskState {
                if validSession, let provenance {
                    metadata[MemoryMetadataKeys.type] = MemoryType.taskState.rawValue
                    metadata[MemoryMetadataKeys.durability] = MemoryDurability.working.rawValue
                    metadata["session_id"] = provenance.uuidString
                    metadata[MemoryMetadataKeys.migrationAction] = "rehome"
                    rehomed += 1
                } else {
                    switch orphanPolicy {
                    case .drop:
                        dropped += 1
                        continue
                    case .quarantine:
                        metadata[MemoryMetadataKeys.migrationAction] = "quarantine"
                        metadata[MemoryMetadataKeys.migrationOriginalMemoryType] = info.type.rawValue
                        if let provenance {
                            metadata[MemoryMetadataKeys.migrationOriginalSessionID] = provenance.uuidString
                        } else if let rawSessionID = document.metadata["session_id"] {
                            metadata[MemoryMetadataKeys.migrationOriginalSessionID] = rawSessionID
                        }
                        metadata.removeValue(forKey: "session_id")
                        metadata.removeValue(forKey: MemoryMetadataKeys.promotedFromSession)
                        metadata[MemoryMetadataKeys.type] = MemoryType.note.rawValue
                        metadata[MemoryMetadataKeys.durability] = MemoryDurability.working.rawValue
                        quarantined += 1
                    }
                }
            } else {
                metadata[MemoryMetadataKeys.migrationAction] = "copy"
            }

            targets.append(
                MemoryOrchestrator.CorpusTargetDocument(
                    timestampMs: document.timestampMs,
                    text: document.text,
                    metadata: metadata
                )
            )
        }

        let report = TaskStateMigrationReport(
            sourcePath: longTermStoreURL.path,
            destinationPath: destinationURL.path,
            orphanPolicy: orphanPolicy,
            sourceHash: sourceHash,
            sourceDocumentCount: documents.count,
            copiedDocumentCount: targets.count,
            rehomedDocumentCount: rehomed,
            quarantinedDocumentCount: quarantined,
            droppedDocumentCount: dropped
        )
        return TaskStateMigrationPlan(report: report, documents: targets)
    }

    private func validSessionProvenance(_ sessionID: UUID) -> Bool {
        guard let manifest = try? BrokerSessionPersistence.loadManifest(
            rootURL: sessionRootURL,
            sessionID: sessionID
        ), manifest.sessionID == sessionID,
        manifest.status == .active || manifest.status == .ended else {
            return false
        }
        let storeURL = URL(fileURLWithPath: AgentBrokerPathing.expandPath(manifest.storePath))
        return FileManager.default.fileExists(atPath: storeURL.path)
    }

    private func taskStateSessionID(in metadata: [String: String]) -> UUID? {
        for raw in [metadata["session_id"], metadata[MemoryMetadataKeys.promotedFromSession]].compactMap({ $0 }) {
            if let sessionID = UUID(uuidString: raw) {
                return sessionID
            }
        }
        return nil
    }
}

private extension AgentBrokerService {
    static func taskStateMigrationManifestURL(for destinationURL: URL) -> URL {
        URL(fileURLWithPath: destinationURL.path + taskStateMigrationManifestSuffix)
    }

    static func loadTaskStateMigrationManifest(at url: URL) throws -> TaskStateMigrationReport? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(TaskStateMigrationReport.self, from: Data(contentsOf: url))
    }

    static func saveTaskStateMigrationManifest(_ report: TaskStateMigrationReport, at url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: url, options: .atomic)
    }

    static func sha256Text(_ text: String) -> String {
        SHA256Checksum.digest(Data(text.utf8)).hexString
    }

    static func sha256File(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var checksum = SHA256Checksum()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            checksum.update(data)
        }
        return checksum.finalize().hexString
    }

    static func verifyTaskStateMigrationDestination(
        at url: URL,
        expectedDocumentCount: Int
    ) async throws -> Bool {
        var config = OrchestratorConfig.default
        config.enableTextSearch = true
        config.enableVectorSearch = false
        config.enableStructuredMemory = false
        config.enableAccessStatsScoring = false
        let memory = try await MemoryOrchestrator(at: url, config: config)
        do {
            try await memory.wax.verify(deep: true)
            let documents = try await memory.corpusSourceDocuments()
            var valid = documents.count == expectedDocumentCount
            var sourceFrameIDs = Set<String>()
            for document in documents {
                let info = MemorySemantics.parse(metadata: document.metadata, nowMs: Int64(Date().timeIntervalSince1970 * 1000))
                if info.type == .taskState,
                   !(info.durability == .working && UUID(uuidString: document.metadata["session_id"] ?? "") != nil) {
                    valid = false
                }
                let hasMigrationSchema = document.metadata[MemoryMetadataKeys.migrationSchema] == taskStateMigrationSchema
                let hasContentHash = document.metadata[MemoryMetadataKeys.migrationSourceContentHash] == sha256Text(document.text)
                let hasUniqueFrameID: Bool
                if let sourceFrameID = document.metadata[MemoryMetadataKeys.migrationSourceFrameID] {
                    hasUniqueFrameID = sourceFrameIDs.insert(sourceFrameID).inserted
                } else {
                    hasUniqueFrameID = false
                }
                if !(hasMigrationSchema && hasContentHash && hasUniqueFrameID) {
                    valid = false
                }
            }
            try await memory.close()
            return valid
        } catch {
            try? await memory.close()
            throw error
        }
    }

    static func installTaskStateMigrationBuild(
        _ buildURL: URL,
        at destinationURL: URL,
        overwrite: Bool
    ) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: destinationURL.path) else {
            try fileManager.moveItem(at: buildURL, to: destinationURL)
            return
        }
        guard overwrite else {
            throw BrokerValidationError.invalid("task_state migration destination already exists")
        }
        let backupURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".\(destinationURL.lastPathComponent)-backup-\(UUID().uuidString)")
        try fileManager.moveItem(at: destinationURL, to: backupURL)
        do {
            try fileManager.moveItem(at: buildURL, to: destinationURL)
            try? fileManager.removeItem(at: backupURL)
        } catch {
            if !fileManager.fileExists(atPath: destinationURL.path) {
                try? fileManager.moveItem(at: backupURL, to: destinationURL)
            }
            throw error
        }
    }

    static func taskStateMigrationPayload(_ report: TaskStateMigrationReport) -> AgentBrokerValue {
        .object([
            "status": .string("ok"),
            "schema_version": .from(report.schemaVersion),
            "source_path": .string(report.sourcePath),
            "destination_path": .string(report.destinationPath),
            "orphan_policy": .string(report.orphanPolicy.rawValue),
            "source_hash": .string(report.sourceHash),
            "destination_hash": .from(report.destinationHash),
            "source_preserved": .bool(report.sourcePreserved),
            "verified": .bool(report.verified),
            "idempotent": .bool(report.idempotent),
            "source_document_count": .from(report.sourceDocumentCount),
            "copied_document_count": .from(report.copiedDocumentCount),
            "rehomed_document_count": .from(report.rehomedDocumentCount),
            "quarantined_document_count": .from(report.quarantinedDocumentCount),
            "dropped_document_count": .from(report.droppedDocumentCount),
            "display_text": .string(
                "Task-state migration \(report.idempotent ? "already applied" : report.verified ? "verified" : "planned"): " +
                    "\(report.rehomedDocumentCount) rehomed, \(report.quarantinedDocumentCount) quarantined, " +
                    "\(report.droppedDocumentCount) dropped."
            ),
        ])
    }
}
