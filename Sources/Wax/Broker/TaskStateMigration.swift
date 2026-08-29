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
    private static let taskStateMigrationSchema = "task_state_v2"
    private static let taskStateMigrationSchemaVersion = 2
    private static let taskStateMigrationManifestSuffix = ".task-state-migration.json"

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
                if let backupURL, fileManager.fileExists(atPath: backupURL.path) {
                    try? fileManager.moveItem(at: backupURL, to: destinationURL)
                }
                throw error
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
            MemorySemantics.parse(metadata: $0.metadata, nowMs: Self.nowMs()).type == .taskState
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
            let info = MemorySemantics.parse(metadata: document.metadata, nowMs: Self.nowMs())
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

    private func openTaskStateMigrationMemory(at url: URL) async throws -> MemoryOrchestrator {
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
        for frameID in frameIDs.sorted(by: >) {
            try await memory.delete(frameId: frameID)
        }
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

    static func validatedSourceStoreURL(_ sourceURL: URL) throws -> URL {
        let standardized = sourceURL.standardizedFileURL
        guard fileType(at: standardized) == .typeRegular else {
            throw BrokerValidationError.invalid("task_state migration source store must be a regular file")
        }
        return canonicalURL(standardized)
    }

    static func validatedMigrationDestinationURL(_ rawURL: URL, sourceURL: URL) throws -> URL {
        let standardized = rawURL.standardizedFileURL
        let parent = standardized.deletingLastPathComponent()
        guard !hasSymlinkComponent(in: parent) else {
            throw BrokerValidationError.invalid(
                "task_state migration destination must not use a symlinked parent path"
            )
        }
        let canonical = canonicalURL(standardized)
        guard canonical != sourceURL else {
            throw BrokerValidationError.invalid("task_state migration destination must differ from the source store")
        }
        if let destinationType = fileType(at: standardized) {
            guard destinationType == .typeRegular else {
                throw BrokerValidationError.invalid(
                    "task_state migration destination must be a regular file, not a directory, symlink, or special file"
                )
            }
            guard !sameFileIdentity(standardized, sourceURL) else {
                throw BrokerValidationError.invalid("task_state migration destination must not alias the source store")
            }
        }
        return canonical
    }

    static func validateDestinationSlot(
        at destinationURL: URL,
        sourceURL: URL,
        overwrite: Bool
    ) throws {
        guard !sameFileIdentityIfPresent(destinationURL, sourceURL) else {
            throw BrokerValidationError.invalid("task_state migration destination must not alias the source store")
        }
        guard let destinationType = fileType(at: destinationURL) else { return }
        guard destinationType == .typeRegular else {
            throw BrokerValidationError.invalid(
                "task_state migration destination must be a regular file, not a directory, symlink, or special file"
            )
        }
        guard overwrite else {
            throw BrokerValidationError.invalid(
                "task_state migration destination already exists; pass overwrite_destination=true to replace it"
            )
        }
    }

    static func fileType(at url: URL) -> FileAttributeType? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
    }

    static func sameFileIdentityIfPresent(_ lhs: URL, _ rhs: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: lhs.path),
              fileType(at: lhs) == .typeRegular,
              fileType(at: rhs) == .typeRegular else {
            return false
        }
        return sameFileIdentity(lhs, rhs)
    }

    static func sameFileIdentity(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let left = fileIdentity(at: lhs), let right = fileIdentity(at: rhs) else {
            return false
        }
        return left.device == right.device && left.inode == right.inode
    }

    static func fileIdentity(at url: URL) -> (device: UInt64, inode: UInt64)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        guard let device, let inode else { return nil }
        return (device: device, inode: inode)
    }

    static func hasSymlinkComponent(in url: URL) -> Bool {
        var current = url.standardizedFileURL
        while true {
            // macOS exposes /tmp and /var as stable system aliases. They do
            // not let a caller redirect a destination into an arbitrary tree;
            // nested symlink components remain rejected below.
            let isStableSystemAlias = current.path == "/tmp" || current.path == "/var"
            if !isStableSystemAlias, fileType(at: current) == .typeSymbolicLink {
                return true
            }
            if current.path == "/" {
                return false
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                return false
            }
            current = parent
        }
    }

    static func canonicalURL(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    static func sha256Text(_ text: String) -> String {
        SHA256Checksum.digest(Data(text.utf8)).hexString
    }

    static func sha256File(at url: URL) throws -> String {
        guard fileType(at: url) == .typeRegular else {
            throw BrokerValidationError.invalid("cannot hash a non-regular migration store")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var checksum = SHA256Checksum()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            checksum.update(data)
        }
        return checksum.finalize().hexString
    }

    static func taskStateAffectedFrameIDs(
        documents: [MemoryOrchestrator.CorpusSourceDocument],
        frameMetas: [FrameMeta]
    ) -> Set<UInt64> {
        taskStateAffectedFrameIDs(
            roots: Set(documents.filter {
                MemorySemantics.parse(metadata: $0.metadata, nowMs: Self.nowMs()).type == .taskState
            }.map(\.frameId)),
            frameMetas: frameMetas
        )
    }

    static func taskStateAffectedFrameIDs(
        roots: Set<UInt64>,
        frameMetas: [FrameMeta]
    ) -> Set<UInt64> {
        var affected = roots
        var changed = true
        while changed {
            changed = false
            for frame in frameMetas where !affected.contains(frame.id) {
                if let parentID = frame.parentId, affected.contains(parentID) {
                    affected.insert(frame.id)
                    changed = true
                }
            }
        }
        return affected
    }

    static func taskStateTreeFrameIDs(
        rootFrameID: UInt64,
        frameMetas: [FrameMeta]
    ) -> [UInt64] {
        Array(taskStateAffectedFrameIDs(roots: [rootFrameID], frameMetas: frameMetas)).sorted(by: >)
    }

    static func frameStateDigest(
        wax: Wax,
        frameMetas: [FrameMeta],
        excluding excludedIDs: Set<UInt64>
    ) async throws -> String {
        var checksum = SHA256Checksum()
        for frame in frameMetas.sorted(by: { $0.id < $1.id }) where !excludedIDs.contains(frame.id) {
            checksum.update(Data(frameFingerprint(frame).utf8))
            checksum.update(try await wax.frameContent(frameId: frame.id))
        }
        return checksum.finalize().hexString
    }

    static func frameFingerprint(_ frame: FrameMeta) -> String {
        let metadata = (frame.metadata?.entries ?? [:])
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")
        let tags = frame.tags.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        let checksum = frame.checksum.map { String(format: "%02x", $0) }.joined()
        let storedChecksum = frame.storedChecksum?.map { String(format: "%02x", $0) }.joined() ?? ""
        let fields: [String] = [
            String(frame.id), String(frame.timestamp), String(describing: frame.anchorTs), frame.kind ?? "",
            frame.track ?? "", frame.uri ?? "", frame.title ?? "", String(frame.canonicalEncoding.rawValue),
            String(describing: frame.canonicalLength), checksum, storedChecksum, frame.searchText ?? "",
            tags, frame.labels.joined(separator: "&"), frame.contentDates.joined(separator: "&"),
            String(frame.role.rawValue), String(describing: frame.parentId), String(describing: frame.chunkIndex),
            String(describing: frame.chunkCount), frame.chunkManifest?.base64EncodedString() ?? "",
            String(frame.status.rawValue), String(describing: frame.supersedes), String(describing: frame.supersededBy),
            metadata, "\n",
        ]
        return fields.joined(separator: "|")
    }

    static func frameCount(at url: URL) async throws -> Int {
        let memory = try await MemoryOrchestrator(at: url, config: migrationVerificationConfig())
        do {
            let count = await memory.wax.frameMetas().count
            try await memory.close()
            return count
        } catch {
            try? await memory.close()
            throw error
        }
    }

    static func vectorIndexPresent(at url: URL) async throws -> Bool {
        let memory = try await MemoryOrchestrator(at: url, config: migrationVerificationConfig())
        do {
            let present = await memory.wax.committedVecIndexManifest() != nil
            try await memory.close()
            return present
        } catch {
            try? await memory.close()
            throw error
        }
    }

    static func migrationVerificationConfig() -> OrchestratorConfig {
        var config = OrchestratorConfig.default
        config.enableTextSearch = true
        config.enableVectorSearch = false
        config.enableStructuredMemory = true
        config.enableAccessStatsScoring = false
        config.liveSetRewriteSchedule = .disabled
        return config
    }

    func verifyTaskStateMigrationDestination(
        at url: URL,
        report: TaskStateMigrationReport,
        sourceFrameMetas: [FrameMeta],
        sourceAffectedFrameIDs: Set<UInt64>
    ) async throws -> Bool {
        let memory = try await openTaskStateMigrationMemory(at: url)
        do {
            try await memory.wax.verify(deep: true)
            let documents = try await memory.corpusSourceDocuments()
            guard documents.count == report.copiedDocumentCount else {
                try await memory.close()
                return false
            }
            let documentBySourceID: [String: MemoryOrchestrator.CorpusSourceDocument] = Dictionary(
                uniqueKeysWithValues: documents.compactMap { document in
                    guard let sourceID = document.metadata[MemoryMetadataKeys.migrationSourceFrameID] else {
                        return nil
                    }
                    return (sourceID, document)
                }
            )
            var seenSourceIDs = Set<UInt64>()
            for entry in report.entries {
                guard seenSourceIDs.insert(entry.sourceFrameID).inserted else {
                    try await memory.close()
                    return false
                }
                if let document = documentBySourceID[String(entry.sourceFrameID)] {
                    let metadata = document.metadata
                    guard metadata[MemoryMetadataKeys.migrationSchema] == Self.taskStateMigrationSchema,
                          metadata[MemoryMetadataKeys.migrationSourceStoreHash] == report.sourceHash,
                          metadata[MemoryMetadataKeys.migrationSourceContentHash] == entry.sourceContentHash,
                          metadata[MemoryMetadataKeys.migrationAction] == entry.action.rawValue,
                          Self.sha256Text(document.text) == entry.sourceContentHash,
                          entry.destinationFrameID == document.frameId else {
                        try await memory.close()
                        return false
                    }
                    let info = MemorySemantics.parse(metadata: metadata, nowMs: Self.nowMs())
                    switch entry.action {
                    case .rehome:
                        guard info.type == MemoryType.taskState,
                              info.durability == MemoryDurability.working,
                              UUID(uuidString: metadata["session_id"] ?? "") != nil else {
                            try await memory.close()
                            return false
                        }
                    case .quarantine:
                        guard info.type == MemoryType.note,
                              info.durability == MemoryDurability.working,
                              metadata["session_id"] == nil,
                              metadata[MemoryMetadataKeys.promotedFromSession] == nil else {
                            try await memory.close()
                            return false
                        }
                    case .drop:
                        try await memory.close()
                        return false
                    }
                } else if entry.action != .drop {
                    try await memory.close()
                    return false
                }
            }
            guard documents.allSatisfy({ document in
                let info = MemorySemantics.parse(metadata: document.metadata, nowMs: Self.nowMs())
                return info.type != .taskState || (
                    info.durability == .working && UUID(uuidString: document.metadata["session_id"] ?? "") != nil
                )
            }) else {
                try await memory.close()
                return false
            }

            let destinationFrameMetas = await memory.wax.frameMetas()
            let sourceIDs = Set(sourceFrameMetas.map(\.id))
            let replacementRootIDs = Set(report.entries.compactMap(\.destinationFrameID))
            for frame in destinationFrameMetas where !sourceIDs.contains(frame.id) {
                guard var parentID = frame.parentId else {
                    guard replacementRootIDs.contains(frame.id) else {
                        try await memory.close()
                        return false
                    }
                    continue
                }
                var visited = Set<UInt64>()
                while !sourceIDs.contains(parentID) {
                    guard visited.insert(parentID).inserted,
                          let parent = destinationFrameMetas.first(where: { $0.id == parentID }),
                          let next = parent.parentId else {
                        break
                    }
                    parentID = next
                }
                guard replacementRootIDs.contains(parentID) else {
                    try await memory.close()
                    return false
                }
            }

            for sourceFrame in sourceFrameMetas where !sourceAffectedFrameIDs.contains(sourceFrame.id) {
                guard let destinationFrame = destinationFrameMetas.first(where: { $0.id == sourceFrame.id }),
                      Self.frameFingerprint(destinationFrame) == Self.frameFingerprint(sourceFrame) else {
                    try await memory.close()
                    return false
                }
                let sourceContent = try await longTermMemory.wax.frameContent(frameId: sourceFrame.id)
                let destinationContent = try await memory.wax.frameContent(frameId: destinationFrame.id)
                guard sourceContent == destinationContent else {
                    try await memory.close()
                    return false
                }
            }
            let preservedHash = try await Self.frameStateDigest(
                wax: longTermMemory.wax,
                frameMetas: sourceFrameMetas,
                excluding: sourceAffectedFrameIDs
            )
            guard preservedHash == report.preservedFrameHash else {
                try await memory.close()
                return false
            }
            let destinationVectorIndexPresent = await memory.wax.committedVecIndexManifest() != nil
            guard report.destinationVectorIndexPresent == nil || report.destinationVectorIndexPresent == destinationVectorIndexPresent else {
                try await memory.close()
                return false
            }
            try await memory.close()
            return true
        } catch {
            try? await memory.close()
            throw error
        }
    }

    static func installTaskStateMigrationBuild(
        _ buildURL: URL,
        at destinationURL: URL,
        sourceURL: URL,
        overwrite: Bool
    ) throws -> URL? {
        let fileManager = FileManager.default
        guard fileType(at: buildURL) == .typeRegular,
              !sameFileIdentityIfPresent(buildURL, sourceURL),
              !hasSymlinkComponent(in: buildURL.deletingLastPathComponent()) else {
            throw BrokerValidationError.invalid("task_state migration build must be a distinct regular file in a non-symlinked directory")
        }
        // Re-probe immediately before the rename/backup sequence to close the
        // preflight TOCTOU window. A path that changed into a symlink, directory,
        // special file, or source alias is never overwritten.
        guard !hasSymlinkComponent(in: destinationURL.deletingLastPathComponent()) else {
            throw BrokerValidationError.invalid("task_state migration destination must not use a symlinked parent path")
        }
        // Capture one final lstat-style probe and use that result for the
        // backup decision. A second path lookup after this point could race a
        // replacement and accidentally treat a source hard-link as disposable.
        let destinationType = fileType(at: destinationURL)
        if let destinationType {
            guard destinationType == .typeRegular else {
                throw BrokerValidationError.invalid(
                    "task_state migration destination must be a regular file, not a directory, symlink, or special file"
                )
            }
            guard !sameFileIdentityIfPresent(destinationURL, sourceURL) else {
                throw BrokerValidationError.invalid("task_state migration destination must not alias the source store")
            }
            guard try StoreLockProbe.tryExclusiveAccess(at: destinationURL) else {
                throw BrokerValidationError.invalid("task_state migration destination is locked by another process")
            }
            guard overwrite else {
                throw BrokerValidationError.invalid("task_state migration destination must be an existing regular file when overwriting")
            }
            let backupURL = destinationURL.deletingLastPathComponent()
                .appendingPathComponent(".\(destinationURL.lastPathComponent)-backup-\(UUID().uuidString)")
            guard fileType(at: backupURL) == nil else {
                throw BrokerValidationError.invalid("task_state migration backup path unexpectedly exists")
            }
            try fileManager.moveItem(at: destinationURL, to: backupURL)
            do {
                try fileManager.moveItem(at: buildURL, to: destinationURL)
                return backupURL
            } catch {
                if fileManager.fileExists(atPath: backupURL.path), !fileManager.fileExists(atPath: destinationURL.path) {
                    try? fileManager.moveItem(at: backupURL, to: destinationURL)
                }
                throw error
            }
        }
        try fileManager.moveItem(at: buildURL, to: destinationURL)
        return nil
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
            "source_frame_count": .from(report.sourceFrameCount),
            "destination_frame_count": .from(report.destinationFrameCount),
            "preserved_frame_hash": .string(report.preservedFrameHash),
            "source_vector_index_present": .bool(report.sourceVectorIndexPresent),
            "destination_vector_index_present": .from(report.destinationVectorIndexPresent),
            "display_text": .string(
                "Task-state migration \(report.idempotent ? "already applied" : report.verified ? "verified" : "planned"): " +
                    "\(report.rehomedDocumentCount) rehomed, \(report.quarantinedDocumentCount) quarantined, " +
                    "\(report.droppedDocumentCount) dropped."
            ),
        ])
    }
}
