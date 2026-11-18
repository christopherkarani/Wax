import Foundation
import WaxCore

/// Policy for task-state records that no longer have valid session provenance.
package enum TaskStateOrphanPolicy: String, CaseIterable, Codable, Sendable, Equatable {
    /// Preserve the text as working, non-task-state memory with an audit marker.
    case quarantine
    /// Omit the orphan record from the repaired destination.
    case drop
}

package enum TaskStateMigrationAction: String, Codable, Sendable, Equatable {
    case rehome
    case quarantine
    case drop
}

package struct TaskStateMigrationEntry: Codable, Sendable, Equatable {
    package var sourceFrameID: UInt64
    package var sourceContentHash: String
    package var action: TaskStateMigrationAction
    package var destinationFrameID: UInt64?

    package init(
        sourceFrameID: UInt64,
        sourceContentHash: String,
        action: TaskStateMigrationAction,
        destinationFrameID: UInt64? = nil
    ) {
        self.sourceFrameID = sourceFrameID
        self.sourceContentHash = sourceContentHash
        self.action = action
        self.destinationFrameID = destinationFrameID
    }
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
    package var sourceFrameCount: Int
    package var destinationFrameCount: Int?
    package var preservedFrameHash: String
    package var sourceVectorIndexPresent: Bool
    package var destinationVectorIndexPresent: Bool?
    package var entries: [TaskStateMigrationEntry]

    package init(
        schemaVersion: Int = 2,
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
        droppedDocumentCount: Int,
        sourceFrameCount: Int = 0,
        destinationFrameCount: Int? = nil,
        preservedFrameHash: String = "",
        sourceVectorIndexPresent: Bool = false,
        destinationVectorIndexPresent: Bool? = nil,
        entries: [TaskStateMigrationEntry] = []
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
        self.sourceFrameCount = sourceFrameCount
        self.destinationFrameCount = destinationFrameCount
        self.preservedFrameHash = preservedFrameHash
        self.sourceVectorIndexPresent = sourceVectorIndexPresent
        self.destinationVectorIndexPresent = destinationVectorIndexPresent
        self.entries = entries
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case sourcePath
        case destinationPath
        case orphanPolicy
        case sourceHash
        case destinationHash
        case sourcePreserved
        case verified
        case idempotent
        case sourceDocumentCount
        case copiedDocumentCount
        case rehomedDocumentCount
        case quarantinedDocumentCount
        case droppedDocumentCount
        case sourceFrameCount
        case destinationFrameCount
        case preservedFrameHash
        case sourceVectorIndexPresent
        case destinationVectorIndexPresent
        case entries
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        sourcePath = try container.decode(String.self, forKey: .sourcePath)
        destinationPath = try container.decode(String.self, forKey: .destinationPath)
        orphanPolicy = try container.decode(TaskStateOrphanPolicy.self, forKey: .orphanPolicy)
        sourceHash = try container.decode(String.self, forKey: .sourceHash)
        destinationHash = try container.decodeIfPresent(String.self, forKey: .destinationHash)
        sourcePreserved = try container.decodeIfPresent(Bool.self, forKey: .sourcePreserved) ?? false
        verified = try container.decodeIfPresent(Bool.self, forKey: .verified) ?? false
        idempotent = try container.decodeIfPresent(Bool.self, forKey: .idempotent) ?? false
        sourceDocumentCount = try container.decodeIfPresent(Int.self, forKey: .sourceDocumentCount) ?? 0
        copiedDocumentCount = try container.decodeIfPresent(Int.self, forKey: .copiedDocumentCount) ?? 0
        rehomedDocumentCount = try container.decodeIfPresent(Int.self, forKey: .rehomedDocumentCount) ?? 0
        quarantinedDocumentCount = try container.decodeIfPresent(Int.self, forKey: .quarantinedDocumentCount) ?? 0
        droppedDocumentCount = try container.decodeIfPresent(Int.self, forKey: .droppedDocumentCount) ?? 0
        sourceFrameCount = try container.decodeIfPresent(Int.self, forKey: .sourceFrameCount) ?? 0
        destinationFrameCount = try container.decodeIfPresent(Int.self, forKey: .destinationFrameCount)
        preservedFrameHash = try container.decodeIfPresent(String.self, forKey: .preservedFrameHash) ?? ""
        sourceVectorIndexPresent = try container.decodeIfPresent(Bool.self, forKey: .sourceVectorIndexPresent) ?? false
        destinationVectorIndexPresent = try container.decodeIfPresent(Bool.self, forKey: .destinationVectorIndexPresent)
        entries = try container.decodeIfPresent([TaskStateMigrationEntry].self, forKey: .entries) ?? []
    }
}

package extension AgentBrokerService {
    internal static let taskStateMigrationSchema = "task_state_v2"
    private static let taskStateMigrationSchemaVersion = 2
    internal static let taskStateMigrationManifestSuffix = ".task-state-migration.json"

    /// Copy the complete long-term store into a distinct destination while repairing
    /// task-state records in the copy. The source is flushed and hashed before the
    /// copy, and is never opened for write by this operation.
    func taskStateMigrate(_ command: BrokerCommand.TaskStateMigrate) async throws -> AgentBrokerValue {
        try await longTermMemory.flush()

        let sourceURL = try Self.validatedSourceStoreURL(longTermStoreURL)
        let destinationURL = try Self.validatedMigrationDestinationURL(
            URL(fileURLWithPath: AgentBrokerPathing.expandPath(command.destinationPath)),
            sourceURL: sourceURL
        )
        let fileManager = FileManager.default
        let sourceHash = try Self.sha256File(at: sourceURL)
        let manifestURL = Self.taskStateMigrationManifestURL(for: destinationURL)
        let sourceFrameMetas = await longTermMemory.wax.frameMetas()
        let sourceDocuments = try await longTermMemory.corpusSourceDocuments()
        let sourceVectorIndexPresent = await longTermMemory.wax.committedVecIndexManifest() != nil
        let affectedSourceFrameIDs = Self.taskStateAffectedFrameIDs(
            documents: sourceDocuments,
            frameMetas: sourceFrameMetas
        )
        let preservedFrameHash = try await Self.frameStateDigest(
            wax: longTermMemory.wax,
            frameMetas: sourceFrameMetas,
            excluding: affectedSourceFrameIDs
        )
        let plan = try makeTaskStateMigrationPlan(
            documents: sourceDocuments,
            frameMetas: sourceFrameMetas,
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            sourceHash: sourceHash,
            preservedFrameHash: preservedFrameHash,
            sourceVectorIndexPresent: sourceVectorIndexPresent,
            orphanPolicy: command.orphanPolicy
        )

        if !command.dryRun,
           let existing = try? Self.loadTaskStateMigrationManifest(at: manifestURL),
           existing.schemaVersion == Self.taskStateMigrationSchemaVersion,
           existing.sourcePath == sourceURL.path,
           existing.destinationPath == destinationURL.path,
           existing.sourceHash == sourceHash,
           existing.orphanPolicy == command.orphanPolicy,
           existing.preservedFrameHash == preservedFrameHash,
           fileManager.fileExists(atPath: destinationURL.path) {
            let verified = try await verifyTaskStateMigrationDestination(
                at: destinationURL,
                report: existing,
                sourceFrameMetas: sourceFrameMetas,
                sourceAffectedFrameIDs: affectedSourceFrameIDs
            )
            guard verified else {
                throw BrokerValidationError.invalid(
                    "task_state migration manifest does not match a verified destination; pass overwrite_destination=true"
                )
            }
            var idempotent = existing
            // Re-opening a Wax file may legitimately refresh its recovery
            // header, so destinationHash is informational. Deep frame/index
            // verification below detects actual data changes without treating
            // a header-only rewrite as tampering.
            idempotent.destinationHash = try Self.sha256File(at: destinationURL)
            idempotent.sourcePreserved = try Self.sha256File(at: sourceURL) == sourceHash
            idempotent.verified = idempotent.sourcePreserved
            idempotent.idempotent = idempotent.sourcePreserved
            guard idempotent.sourcePreserved else {
                throw BrokerValidationError.invalid("task_state migration source changed after its manifest")
            }
            try Self.saveTaskStateMigrationManifest(idempotent, at: manifestURL)
            return Self.taskStateMigrationPayload(idempotent)
        }

        if command.dryRun {
            var report = plan.report
            report.sourcePreserved = true
            return Self.taskStateMigrationPayload(report)
        }

        if plan.hasStoreMutations, sourceVectorIndexPresent {
            let sourceRuntime = await longTermMemory.runtimeStats()
            guard sourceRuntime.vectorSearchEnabled, sourceRuntime.queryEmbedderReady else {
                throw BrokerValidationError.invalid(
                    "task_state migration would alter a vector-indexed store, but its matching embedder is unavailable"
                )
            }
        }

        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Self.validateDestinationSlot(
            at: destinationURL,
            sourceURL: sourceURL,
            overwrite: command.overwriteDestination
        )

        let buildURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(destinationURL.deletingPathExtension().lastPathComponent)-task-state-migration-\(UUID().uuidString)"
            )
            .appendingPathExtension("wax")
        if fileManager.fileExists(atPath: buildURL.path) {
            try fileManager.removeItem(at: buildURL)
        }

        do {
            // The raw file copy retains every frame, structured record, and committed
            // text/vector index. Only the task-state trees listed in the plan change.
            try fileManager.copyItem(at: sourceURL, to: buildURL)
            var report = plan.report
            let target = try await openTaskStateMigrationMemory(at: buildURL)
            do {
                let targetRuntime = await target.runtimeStats()
                if plan.hasStoreMutations, sourceVectorIndexPresent {
                    guard targetRuntime.vectorSearchEnabled, targetRuntime.queryEmbedderReady else {
                        throw BrokerValidationError.invalid(
                            "task_state migration could not open the matching embedder for vector preservation"
                        )
                    }
                }

                for (index, operation) in plan.operations.enumerated() {
                    switch operation.action {
                    case .drop:
                        try await deleteTaskStateTree(
                            operation.sourceTreeFrameIDs,
                            from: target
                        )
                    case .rehome, .quarantine:
                        guard let metadata = operation.replacementMetadata else {
                            throw BrokerValidationError.invalid("task_state migration produced an incomplete replacement plan")
                        }
                        let replacement = try await target.remember(
                            operation.source.text,
                            metadata: metadata
                        )
                        report.entries[index].destinationFrameID = replacement.frameId
                        try await deleteTaskStateTree(
                            operation.sourceTreeFrameIDs,
                            from: target
                        )
                    }
                }
                try await target.flush()
                try await target.close()
            } catch {
                try? await target.close()
                throw error
            }

            let verifiedBuild = try await verifyTaskStateMigrationDestination(
                at: buildURL,
                report: report,
                sourceFrameMetas: sourceFrameMetas,
                sourceAffectedFrameIDs: affectedSourceFrameIDs
            )
            guard verifiedBuild else {
                throw BrokerValidationError.invalid("task_state migration destination failed deep verification")
            }
            report.destinationFrameCount = try await Self.frameCount(at: buildURL)
            report.destinationVectorIndexPresent = try await Self.vectorIndexPresent(at: buildURL)
            guard try Self.sha256File(at: sourceURL) == sourceHash else {
                throw BrokerValidationError.invalid("task_state migration source changed during copy")
            }

            let backupURL = try Self.installTaskStateMigrationBuild(
                buildURL,
                at: destinationURL,
                sourceURL: sourceURL,
                overwrite: command.overwriteDestination
            )
            do {
                let verifiedInstalled = try await verifyTaskStateMigrationDestination(
                    at: destinationURL,
                    report: report,
                    sourceFrameMetas: sourceFrameMetas,
                    sourceAffectedFrameIDs: affectedSourceFrameIDs
                )
                guard verifiedInstalled else {
                    throw BrokerValidationError.invalid(
                        "task_state migration destination failed post-install verification"
                    )
                }
                guard try Self.sha256File(at: sourceURL) == sourceHash else {
                    throw BrokerValidationError.invalid("task_state migration source changed during install")
                }
                if let backupURL {
                    // Keep the rollback copy until the installed destination has
                    // passed deep verification and the source hash is rechecked.
                    try? fileManager.removeItem(at: backupURL)
                }
            } catch {
                try? fileManager.removeItem(at: destinationURL)
                guard let backupURL else { throw error }
                throw Self.restoreTaskStateMigrationBackup(backupURL, to: destinationURL, after: error)
            }

            report.destinationHash = try Self.sha256File(at: destinationURL)
            report.sourcePreserved = try Self.sha256File(at: sourceURL) == sourceHash
            guard report.sourcePreserved else {
                throw BrokerValidationError.invalid("task_state migration source changed during copy")
            }
            report.verified = true
            report.idempotent = false
            try Self.saveTaskStateMigrationManifest(report, at: manifestURL)
            return Self.taskStateMigrationPayload(report)
        } catch {
            try? fileManager.removeItem(at: buildURL)
            throw error
        }
    }

    private struct TaskStateMigrationOperation {
        var source: MemoryOrchestrator.CorpusSourceDocument
        var action: TaskStateMigrationAction
        var replacementMetadata: [String: String]?
        var sourceContentHash: String
        var sourceTreeFrameIDs: [UInt64]
    }

    private struct TaskStateMigrationPlan {
        var report: TaskStateMigrationReport
        var operations: [TaskStateMigrationOperation]

        var hasStoreMutations: Bool { !operations.isEmpty }
    }

    private func makeTaskStateMigrationPlan(
        documents: [MemoryOrchestrator.CorpusSourceDocument],
        frameMetas: [FrameMeta],
        sourceURL: URL,
        destinationURL: URL,
        sourceHash: String,
        preservedFrameHash: String,
        sourceVectorIndexPresent: Bool,
        orphanPolicy: TaskStateOrphanPolicy
    ) throws -> TaskStateMigrationPlan {
        let taskStateDocuments = documents.filter {
            MemorySemantics.parse(metadata: $0.metadata, nowMs: BrokerClock.nowMs()).type == .taskState
        }
        var operations: [TaskStateMigrationOperation] = []
        operations.reserveCapacity(taskStateDocuments.count)
        var entries: [TaskStateMigrationEntry] = []
        entries.reserveCapacity(taskStateDocuments.count)
        var rehomed = 0
        var quarantined = 0
        var dropped = 0

        for document in taskStateDocuments {
            let contentHash = Self.sha256Text(document.text)
            let info = MemorySemantics.parse(metadata: document.metadata, nowMs: BrokerClock.nowMs())
            let provenance = taskStateSessionID(in: document.metadata)
            let validSession = if let provenance {
                validSessionProvenance(provenance)
            } else {
                false
            }
            let action: TaskStateMigrationAction
            var replacementMetadata: [String: String]?

            if validSession, let provenance {
                action = .rehome
                var metadata = document.metadata
                metadata[MemoryMetadataKeys.migrationSchema] = Self.taskStateMigrationSchema
                metadata[MemoryMetadataKeys.migrationSourceFrameID] = String(document.frameId)
                metadata[MemoryMetadataKeys.migrationSourceContentHash] = contentHash
                metadata[MemoryMetadataKeys.migrationSourceStoreHash] = sourceHash
                metadata[MemoryMetadataKeys.migrationAction] = action.rawValue
                metadata[MemoryMetadataKeys.type] = MemoryType.taskState.rawValue
                metadata[MemoryMetadataKeys.durability] = MemoryDurability.working.rawValue
                metadata["session_id"] = provenance.uuidString
                replacementMetadata = metadata
                rehomed += 1
            } else {
                action = orphanPolicy == .drop ? .drop : .quarantine
                switch action {
                case .drop:
                    dropped += 1
                case .quarantine:
                    var metadata = document.metadata
                    metadata[MemoryMetadataKeys.migrationSchema] = Self.taskStateMigrationSchema
                    metadata[MemoryMetadataKeys.migrationSourceFrameID] = String(document.frameId)
                    metadata[MemoryMetadataKeys.migrationSourceContentHash] = contentHash
                    metadata[MemoryMetadataKeys.migrationSourceStoreHash] = sourceHash
                    metadata[MemoryMetadataKeys.migrationAction] = action.rawValue
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
                    replacementMetadata = metadata
                    quarantined += 1
                case .rehome:
                    throw BrokerValidationError.invalid("task_state migration produced an invalid orphan action")
                }
            }

            entries.append(
                TaskStateMigrationEntry(
                    sourceFrameID: document.frameId,
                    sourceContentHash: contentHash,
                    action: action
                )
            )
            operations.append(
                TaskStateMigrationOperation(
                    source: document,
                    action: action,
                    replacementMetadata: replacementMetadata,
                    sourceContentHash: contentHash,
                    sourceTreeFrameIDs: Self.taskStateTreeFrameIDs(
                        rootFrameID: document.frameId,
                        frameMetas: frameMetas
                    )
                )
            )
        }

        let report = TaskStateMigrationReport(
            sourcePath: sourceURL.path,
            destinationPath: destinationURL.path,
            orphanPolicy: orphanPolicy,
            sourceHash: sourceHash,
            sourceDocumentCount: documents.count,
            copiedDocumentCount: documents.count - dropped,
            rehomedDocumentCount: rehomed,
            quarantinedDocumentCount: quarantined,
            droppedDocumentCount: dropped,
            sourceFrameCount: frameMetas.count,
            preservedFrameHash: preservedFrameHash,
            sourceVectorIndexPresent: sourceVectorIndexPresent,
            entries: entries
        )
        return TaskStateMigrationPlan(report: report, operations: operations)
    }

    internal func openTaskStateMigrationMemory(at url: URL) async throws -> MemoryOrchestrator {
        var config = longTermMemory.config
        config.enableAsyncEnrichment = false
        config.liveSetRewriteSchedule = .disabled
        return try await EmbeddingReadinessBinding.openOrchestrator(
            at: url,
            config: config,
            request: embeddingRequest,
            waxOptions: CommandLineEmbedderFactory.waxOptions(),
            readiness: readiness,
            factoryOverride: factoryOverride
        )
    }

    private func deleteTaskStateTree(
        _ frameIDs: [UInt64],
        from memory: MemoryOrchestrator
    ) async throws {
        try await memory.delete(frameIds: frameIDs.sorted(by: >))
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

extension AgentBrokerService {
    /// Moves the pre-migration destination back after a failed install and
    /// returns the error to throw. When the restore fails too (or something
    /// already occupies the destination), the error names `backupURL` so the
    /// previous store can be recovered by hand instead of being silently orphaned.
    package static func restoreTaskStateMigrationBackup(
        _ backupURL: URL,
        to destinationURL: URL,
        after installError: any Error
    ) -> any Error {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: backupURL.path) else { return installError }
        do {
            try fileManager.moveItem(at: backupURL, to: destinationURL)
            return installError
        } catch {
            return BrokerValidationError.invalid(
                "task_state migration failed (\(installError.localizedDescription)) and restoring the previous destination failed (\(error.localizedDescription)); the previous destination is preserved at \(backupURL.path)"
            )
        }
    }
}
