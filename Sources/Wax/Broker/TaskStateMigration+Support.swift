import Foundation
import WaxCore

extension AgentBrokerService {
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
                MemorySemantics.parse(metadata: $0.metadata, nowMs: BrokerClock.nowMs()).type == .taskState
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
        config.automaticallyReembedSupersededVectors = false
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
                    let info = MemorySemantics.parse(metadata: metadata, nowMs: BrokerClock.nowMs())
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
                let info = MemorySemantics.parse(metadata: document.metadata, nowMs: BrokerClock.nowMs())
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
                throw Self.restoreTaskStateMigrationBackup(backupURL, to: destinationURL, after: error)
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
