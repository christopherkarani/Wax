import Foundation

extension AgentBrokerService {
    func syncMarkdownProjection(rootURL: URL, dryRun: Bool = false) async throws -> MarkdownSyncReport {
        if !dryRun {
            try await longTermMemory.flush()
        }

        let memoryURL = rootURL.appendingPathComponent("MEMORY.md")
        let memoryDir = rootURL.appendingPathComponent("memory", isDirectory: true)
        let dreamsURL = memoryDir.appendingPathComponent("DREAMS.md")

        var counts = MarkdownSyncCounts()
        var dailyPaths: [String] = []

        if FileManager.default.fileExists(atPath: memoryURL.path) {
            merge(&counts, with: try await syncMemoryMarkdown(at: memoryURL, dryRun: dryRun))
        }

        if FileManager.default.fileExists(atPath: memoryDir.path) {
            let dailyURLs = try FileManager.default.contentsOfDirectory(
                at: memoryDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            .filter { $0.pathExtension == "md" }
            .filter { !$0.lastPathComponent.hasPrefix("HANDOFFS") && !$0.lastPathComponent.hasPrefix("DREAMS") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

            for url in dailyURLs {
                dailyPaths.append(url.path)
                merge(&counts, with: try await syncDailyNoteMarkdown(at: url, dryRun: dryRun))
            }
        }

        if FileManager.default.fileExists(atPath: dreamsURL.path) {
            merge(&counts, with: try await syncDreamsMarkdown(at: dreamsURL, dryRun: dryRun))
        }

        if !dryRun {
            try await longTermMemory.flush()
        }

        return MarkdownSyncReport(
            rootDir: rootURL.path,
            memoryPath: FileManager.default.fileExists(atPath: memoryURL.path) ? memoryURL.path : nil,
            dailyNotePaths: dailyPaths,
            dreamsPath: FileManager.default.fileExists(atPath: dreamsURL.path) ? dreamsURL.path : nil,
            counts: counts
        )
    }

    func renderManagedMarkdownLine(
        text: String,
        marker: MarkdownProjectionMarker,
        checked: Bool? = nil
    ) -> String {
        let prefix: String
        switch checked {
        case .some(true):
            prefix = "- [x]"
        case .some(false):
            prefix = "- [ ]"
        case .none:
            prefix = "-"
        }
        return "\(prefix) \(text) \(BrokerMarkdownSync.markerComment(marker))"
    }

    func marker(
        for document: MemoryOrchestrator.CorpusSourceDocument,
        kind: MarkdownProjectionKind,
        dateKey: String? = nil
    ) -> MarkdownProjectionMarker {
        let info = MemorySemantics.parse(metadata: document.metadata)
        return MarkdownProjectionMarker(
            managed: document.metadata[MemoryMetadataKeys.sourceManaged] != "false",
            sourceKind: kind.rawValue,
            frameID: document.frameId,
            memoryID: Self.makeMemoryReference(.durable, sessionID: nil, frameID: document.frameId),
            hash: Self.stableHash(document.text),
            sessionID: document.metadata[MemoryMetadataKeys.promotedFromSession] ?? document.metadata["session_id"],
            sourceFrameID: document.metadata[MemoryMetadataKeys.promotedFromFrame].flatMap(UInt64.init),
            memoryType: info.type.rawValue,
            durability: info.durability.rawValue,
            confidence: info.confidence,
            dateKey: dateKey
        )
    }

    private func syncMemoryMarkdown(at url: URL, dryRun: Bool) async throws -> MarkdownSyncCounts {
        let entries = try BrokerMarkdownSync.parseFile(at: url).filter(\.isManagedImportCandidate)
        let allDocuments = try await longTermMemory.corpusSourceDocuments()
        let existing = allDocuments.filter { document in
            entries.contains {
                marker($0.marker, trusts: document, sourcePath: url.path, sourceKind: .memory, dateKey: nil)
            } ||
                (
                    document.metadata[MemoryMetadataKeys.sourceKind] == MarkdownProjectionKind.memory.rawValue &&
                        document.metadata[MemoryMetadataKeys.sourcePath] == url.path
                )
        }
        let counts = try await syncManagedEntries(
            entries: entries,
            existingDocuments: existing,
            sourcePath: url.path,
            sourceKind: .memory,
            dateKey: nil,
            semanticsForEntry: { entry, existing in
                let type = memoryType(forSection: entry.section) ?? MemorySemantics.classifyCandidate(
                    text: entry.text,
                    metadata: existing?.metadata ?? [:]
                )
                return MemoryWriteSemantics(
                    type: type,
                    durability: .durable,
                    project: existing?.metadata[MemoryMetadataKeys.project],
                    repo: existing?.metadata[MemoryMetadataKeys.repo],
                    confidence: existing?.metadata[MemoryMetadataKeys.confidence].flatMap(Float.init),
                    reviewed: true,
                    lock: (existing?.metadata[MemoryMetadataKeys.durability] == MemoryDurability.locked.rawValue)
                )
            },
            dryRun: dryRun
        )
        if !dryRun {
            try await longTermMemory.flush()
        }
        return counts
    }

    private func syncDailyNoteMarkdown(at url: URL, dryRun: Bool) async throws -> MarkdownSyncCounts {
        let entries = try BrokerMarkdownSync.parseFile(at: url).filter {
            $0.isManagedImportCandidate && $0.marker?.sourceKind != "daily_note_event"
        }
        let dateKey = url.deletingPathExtension().lastPathComponent
        let existing = try await longTermMemory.corpusSourceDocuments().filter {
            $0.metadata[MemoryMetadataKeys.sourceKind] == MarkdownProjectionKind.dailyNote.rawValue &&
                $0.metadata[MemoryMetadataKeys.sourcePath] == url.path
        }
        let counts = try await syncManagedEntries(
            entries: entries,
            existingDocuments: existing,
            sourcePath: url.path,
            sourceKind: .dailyNote,
            dateKey: dateKey,
            semanticsForEntry: { entry, existing in
                let classified = MemorySemantics.classifyCandidate(text: entry.text, metadata: existing?.metadata ?? [:])
                let type: MemoryType = classified == .handoff ? .handoff : .note
                return MemoryWriteSemantics(
                    type: type,
                    durability: .working,
                    project: existing?.metadata[MemoryMetadataKeys.project],
                    repo: existing?.metadata[MemoryMetadataKeys.repo],
                    confidence: existing?.metadata[MemoryMetadataKeys.confidence].flatMap(Float.init),
                    reviewed: false,
                    lock: false
                )
            },
            dryRun: dryRun
        )
        if !dryRun {
            try await longTermMemory.flush()
        }
        return counts
    }

    private func syncDreamsMarkdown(at url: URL, dryRun: Bool) async throws -> MarkdownSyncCounts {
        let entries = try BrokerMarkdownSync.parseFile(at: url)
        var counts = MarkdownSyncCounts()
        let longTermDocuments = try await longTermMemory.corpusSourceDocuments()

        for entry in entries where entry.checked == true && entry.marker?.sourceKind == MarkdownProjectionKind.dreams.rawValue {
            guard let marker = entry.marker else { continue }
            let sessionID = marker.sessionID.flatMap(UUID.init(uuidString:))
            let sourceFrameID = marker.sourceFrameID

            var metadata = [String: String]()
            if let type = marker.memoryType {
                metadata[MemoryMetadataKeys.type] = type
            }
            if let durability = marker.durability {
                metadata[MemoryMetadataKeys.durability] = durability
            }
            if let sessionID {
                metadata[MemoryMetadataKeys.promotedFromSession] = sessionID.uuidString
            }
            if let sourceFrameID {
                metadata[MemoryMetadataKeys.promotedFromFrame] = String(sourceFrameID)
            }

            let recallSignal: BrokerSessionRecallSignals?
            if let sessionID, let sourceFrameID {
                recallSignal = try await sessionSignals(for: sessionID)[sourceFrameID]
            } else {
                recallSignal = nil
            }

            let proposal = BrokerMemoryInsights.proposePromotion(
                content: entry.text,
                metadata: metadata,
                sessionID: sessionID,
                sourceFrameID: sourceFrameID,
                scope: scopeContext,
                longTermDocuments: longTermDocuments,
                recallSignals: recallSignal,
                settings: promotionSettings
            )

            if proposal.shouldWrite {
                counts.approvedDreams += 1
                if !dryRun {
                    let semantics = MemoryWriteSemantics(
                        type: proposal.suggestedType,
                        durability: proposal.suggestedDurability,
                        confidence: proposal.confidence,
                        reviewed: true,
                        lock: proposal.suggestedDurability == MemoryDurability.locked
                    )
                    var normalized = MemorySemantics.normalizeWriteMetadata(
                        metadata: metadata,
                        semantics: semantics,
                        sessionID: nil,
                        inferredScope: scopeContext
                    )
                    normalized = MemorySemantics.approvedPromotionMetadata(
                        metadata: normalized,
                        semantics: semantics,
                        suggestedType: proposal.suggestedType,
                        suggestedDurability: proposal.suggestedDurability,
                        suggestedConfidence: proposal.confidence
                    )
                    try validateDurableWriteContent(content: entry.text, metadata: normalized)
                    try await longTermMemory.remember(entry.text, metadata: normalized)

                    if let sessionID {
                        try await refreshSessionManifest(sessionID)
                        try await appendSessionEvent(
                            sessionID: sessionID,
                            kind: BrokerSessionEvent.Kind.promotionWritten,
                            payload: [
                                "frame_id": sourceFrameID.map(String.init) ?? "",
                                "memory_type": proposal.suggestedType.rawValue,
                                "confidence": String(proposal.confidence),
                                "approved": "true",
                                "written": "true",
                                "source": "dreams_markdown_sync",
                            ]
                        )
                    }
                }
            } else {
                counts.rejectedDreams += 1
            }
        }

        return counts
    }

    private func syncManagedEntries(
        entries: [MarkdownProjectionEntry],
        existingDocuments: [MemoryOrchestrator.CorpusSourceDocument],
        sourcePath: String,
        sourceKind: MarkdownProjectionKind,
        dateKey: String?,
        semanticsForEntry: (MarkdownProjectionEntry, MemoryOrchestrator.CorpusSourceDocument?) -> MemoryWriteSemantics,
        dryRun: Bool
    ) async throws -> MarkdownSyncCounts {
        var counts = MarkdownSyncCounts()
        var matchedFrameIDs = Set<UInt64>()

        for entry in entries {
            let existingByMarker = trustedExistingDocument(
                for: entry.marker,
                in: existingDocuments,
                sourcePath: sourcePath,
                sourceKind: sourceKind,
                dateKey: dateKey
            )
            let existingByHash = existingDocuments.first {
                !matchedFrameIDs.contains($0.frameId) &&
                    $0.metadata[MemoryMetadataKeys.sourceHash] == Self.stableHash(entry.text) &&
                    $0.metadata[MemoryMetadataKeys.sourcePath] == sourcePath
            }
            let existing = existingByMarker ?? existingByHash
            let semantics = semanticsForEntry(entry, existing)

            if let existing {
                let existingInfo = MemorySemantics.parse(metadata: existing.metadata)
                if existing.text == entry.text,
                   existing.metadata[MemoryMetadataKeys.sourceLine] == String(entry.lineNumber),
                   existingInfo.type == (semantics.type ?? existingInfo.type),
                   existingInfo.durability == (semantics.lock ? .locked : (semantics.durability ?? existingInfo.durability)) {
                    matchedFrameIDs.insert(existing.frameId)
                    counts.unchanged += 1
                    continue
                }
            }

            if dryRun {
                if let existing {
                    matchedFrameIDs.insert(existing.frameId)
                    counts.updated += 1
                } else {
                    counts.created += 1
                }
                continue
            }

            let newFrameID = try await upsertManagedDocument(
                content: entry.text,
                entry: entry,
                sourcePath: sourcePath,
                sourceKind: sourceKind,
                dateKey: dateKey,
                semantics: semantics,
                existing: existing
            )

            if let existing {
                matchedFrameIDs.insert(existing.frameId)
                if newFrameID == existing.frameId {
                    counts.unchanged += 1
                } else {
                    try await deleteDocumentTree(frameID: existing.frameId, memory: longTermMemory)
                    counts.updated += 1
                }
            } else {
                counts.created += 1
            }
        }

        for existing in existingDocuments where !matchedFrameIDs.contains(existing.frameId) {
            if !dryRun {
                try await deleteDocumentTree(frameID: existing.frameId, memory: longTermMemory)
            }
            counts.deleted += 1
        }

        return counts
    }

    private func trustedExistingDocument(
        for marker: MarkdownProjectionMarker?,
        in documents: [MemoryOrchestrator.CorpusSourceDocument],
        sourcePath: String,
        sourceKind: MarkdownProjectionKind,
        dateKey: String?
    ) -> MemoryOrchestrator.CorpusSourceDocument? {
        documents.first {
            self.marker(marker, trusts: $0, sourcePath: sourcePath, sourceKind: sourceKind, dateKey: dateKey)
        }
    }

    private func marker(
        _ marker: MarkdownProjectionMarker?,
        trusts document: MemoryOrchestrator.CorpusSourceDocument,
        sourcePath: String,
        sourceKind: MarkdownProjectionKind,
        dateKey: String?
    ) -> Bool {
        guard let marker, marker.managed, marker.sourceKind == sourceKind.rawValue else { return false }
        guard let frameID = marker.frameID, frameID == document.frameId else { return false }

        let previousHash = document.metadata[MemoryMetadataKeys.sourceHash] ?? Self.stableHash(document.text)
        guard marker.hash == previousHash else { return false }

        if let markerMemoryID = marker.memoryID {
            let canonicalMemoryID = Self.makeMemoryReference(.durable, sessionID: nil, frameID: document.frameId)
            let storedMemoryID = document.metadata[MemoryMetadataKeys.sourceMemoryID]
            guard markerMemoryID == canonicalMemoryID || markerMemoryID == storedMemoryID else { return false }
        }

        if let storedSourceKind = document.metadata[MemoryMetadataKeys.sourceKind],
           storedSourceKind != sourceKind.rawValue {
            return false
        }
        if let storedSourcePath = document.metadata[MemoryMetadataKeys.sourcePath],
           storedSourcePath != sourcePath {
            return false
        }
        if let markerDateKey = marker.dateKey, markerDateKey != dateKey {
            return false
        }
        if let storedDateKey = document.metadata[MemoryMetadataKeys.sourceDate],
           storedDateKey != dateKey {
            return false
        }

        return true
    }

    private func upsertManagedDocument(
        content: String,
        entry: MarkdownProjectionEntry,
        sourcePath: String,
        sourceKind: MarkdownProjectionKind,
        dateKey: String?,
        semantics: MemoryWriteSemantics,
        existing: MemoryOrchestrator.CorpusSourceDocument?
    ) async throws -> UInt64 {
        let beforeDocuments = try await longTermMemory.corpusSourceDocuments()
        let beforeIDs = Set(beforeDocuments.map { $0.frameId })

        var baseMetadata = existing?.metadata ?? [:]
        baseMetadata[MemoryMetadataKeys.sourcePath] = sourcePath
        baseMetadata[MemoryMetadataKeys.sourceLine] = String(entry.lineNumber)
        baseMetadata[MemoryMetadataKeys.sourceHash] = Self.stableHash(content)
        baseMetadata[MemoryMetadataKeys.sourceKind] = sourceKind.rawValue
        baseMetadata[MemoryMetadataKeys.sourceManaged] = "true"
        if let dateKey {
            baseMetadata[MemoryMetadataKeys.sourceDate] = dateKey
        }
        if let markerMemoryID = entry.marker?.memoryID {
            baseMetadata[MemoryMetadataKeys.sourceMemoryID] = markerMemoryID
        }

        let normalized = MemorySemantics.normalizeWriteMetadata(
            metadata: baseMetadata,
            semantics: semantics,
            sessionID: nil,
            inferredScope: scopeContext
        )

        try validateDurableWriteContent(content: content, metadata: normalized)
        try await longTermMemory.remember(content, metadata: normalized)
        try await longTermMemory.flush()

        let documents = try await longTermMemory.corpusSourceDocuments()
        let importedHash = Self.stableHash(content)
        let createdCandidates = documents.filter { document in
            !beforeIDs.contains(document.frameId) &&
                document.text == content &&
                document.metadata[MemoryMetadataKeys.sourcePath] == sourcePath &&
                document.metadata[MemoryMetadataKeys.sourceHash] == importedHash &&
                document.metadata[MemoryMetadataKeys.sourceKind] == sourceKind.rawValue
        }
        if let created = createdCandidates.sorted(by: { lhs, rhs in
            if lhs.timestampMs != rhs.timestampMs { return lhs.timestampMs > rhs.timestampMs }
            return lhs.frameId > rhs.frameId
        }).first {
            return created.frameId
        }

        if let matched = documents.first(where: {
            $0.text == content &&
                $0.metadata[MemoryMetadataKeys.sourcePath] == sourcePath &&
                $0.metadata[MemoryMetadataKeys.sourceHash] == importedHash &&
                $0.metadata[MemoryMetadataKeys.sourceKind] == sourceKind.rawValue
        }) {
            return matched.frameId
        }

        throw BrokerValidationError.invalid("Unable to reconcile imported Markdown entry at \(sourcePath):\(entry.lineNumber)")
    }

    private func deleteDocumentTree(frameID: UInt64, memory: MemoryOrchestrator) async throws {
        let metas = await memory.wax.frameMetas()
        let childIDs = metas
            .filter { $0.status == .active && $0.parentId == frameID }
            .map(\.id)
        for childID in childIDs {
            try await memory.wax.delete(frameId: childID)
        }
        try await memory.wax.delete(frameId: frameID)
    }

    func dreamProjectionLines(sessionID filterSessionID: UUID?) async throws -> [String] {
        let manifests = try BrokerSessionPersistence.listManifests(rootURL: sessionRootURL)
            .filter { $0.status == .active }
            .filter { filterSessionID == nil || $0.sessionID == filterSessionID }
        let longTermDocuments = try await longTermMemory.corpusSourceDocuments()
        var rendered: [(score: Float, line: String)] = []
        var seenHashes = Set<String>()

        for manifest in manifests {
            let sessionMemory: MemoryOrchestrator
            let shouldClose: Bool
            if let active = activeSessions[manifest.sessionID] {
                sessionMemory = active.memory
                shouldClose = false
            } else {
                sessionMemory = try await openSessionMemory(at: URL(fileURLWithPath: manifest.storePath))
                shouldClose = true
            }
            defer {
                if shouldClose {
                    Task { try? await sessionMemory.close() }
                }
            }

            let sessionDocuments = try await sessionMemory.corpusSourceDocuments()
            let recallSignals = try BrokerSessionPersistence.recallSignals(
                from: BrokerSessionPersistence.loadEvents(from: URL(fileURLWithPath: manifest.eventLogPath))
            )

            for document in sessionDocuments {
                let proposal = BrokerMemoryInsights.proposePromotion(
                    content: document.text,
                    metadata: document.metadata,
                    sessionID: manifest.sessionID,
                    sourceFrameID: document.frameId,
                    scope: scopeContext,
                    longTermDocuments: longTermDocuments,
                    recallSignals: recallSignals[document.frameId],
                    settings: promotionSettings
                )
                guard proposal.shouldWrite else { continue }
                let hash = Self.stableHash(document.text)
                guard seenHashes.insert(hash).inserted else { continue }
                let marker = MarkdownProjectionMarker(
                    managed: true,
                    sourceKind: MarkdownProjectionKind.dreams.rawValue,
                    hash: hash,
                    sessionID: manifest.sessionID.uuidString,
                    sourceFrameID: document.frameId,
                    memoryType: proposal.suggestedType.rawValue,
                    durability: proposal.suggestedDurability.rawValue,
                    confidence: proposal.confidence
                )
                rendered.append((
                    score: proposal.confidence + Float(proposal.recallCount) * 0.01,
                    line: renderManagedMarkdownLine(text: document.text, marker: marker, checked: false)
                ))
            }
        }

        return rendered
            .sorted { lhs, rhs in lhs.score > rhs.score }
            .map(\.line)
    }

    private func merge(_ counts: inout MarkdownSyncCounts, with other: MarkdownSyncCounts) {
        counts.created += other.created
        counts.updated += other.updated
        counts.deleted += other.deleted
        counts.unchanged += other.unchanged
        counts.approvedDreams += other.approvedDreams
        counts.rejectedDreams += other.rejectedDreams
    }

    private func memoryType(forSection section: String?) -> MemoryType? {
        guard let raw = section?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return nil
        }
        return MemoryType(rawValue: raw)
    }
}
