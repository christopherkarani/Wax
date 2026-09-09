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
        let info = MemorySemantics.parse(metadata: document.metadata, nowMs: Self.nowMs())
        return MarkdownProjectionMarker(
            managed: document.metadata[MemoryMetadataKeys.sourceManaged] != "false",
            sourceKind: kind.rawValue,
            frameID: document.frameId,
            memoryID: Self.makeMemoryReference(frameID: document.frameId),
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
        var approvedFingerprints = Set(longTermDocuments.map {
            MemorySemantics.normalizedTextFingerprint($0.text)
        })

        for entry in entries where entry.checked == true && entry.marker?.sourceKind == MarkdownProjectionKind.dreams.rawValue {
            guard let marker = entry.marker else { continue }
            let fingerprint = MemorySemantics.normalizedTextFingerprint(entry.text)
            guard !approvedFingerprints.contains(fingerprint) else {
                counts.rejectedDreams += 1
                continue
            }
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
                let normalized = try approvedDreamMetadata(metadata: metadata, proposal: proposal)
                try validateDurableWriteContent(content: entry.text, metadata: normalized)
                counts.approvedDreams += 1
                approvedFingerprints.insert(fingerprint)
                if !dryRun {
                    try await longTermMemory.remember(entry.text, metadata: normalized)

                    if let sessionID, activeSessions[sessionID] != nil {
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

    private func approvedDreamMetadata(
        metadata: [String: String],
        proposal: BrokerPromotionProposal
    ) throws -> [String: String] {
        let semantics = MemoryWriteSemantics(
            type: proposal.suggestedType,
            durability: proposal.suggestedDurability,
            confidence: proposal.confidence,
            reviewed: true,
            lock: proposal.suggestedDurability == MemoryDurability.locked
        )
        let normalized = MemorySemantics.normalizeWriteMetadata(
            metadata: metadata,
            semantics: semantics,
            sessionID: nil,
            inferredScope: scopeContext,
            nowMs: Self.nowMs()
        )
        let approved = MemorySemantics.approvedPromotionMetadata(
            metadata: normalized,
            semantics: semantics,
            suggestedType: proposal.suggestedType,
            suggestedDurability: proposal.suggestedDurability,
            suggestedConfidence: proposal.confidence
        )
        return try MemorySemantics.validatedWriteMetadata(
            metadata: approved,
            semantics: semantics,
            sessionID: nil,
            scope: "durable",
            activeSession: false,
            inferredScope: scopeContext,
            nowMs: Self.nowMs()
        )
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

            // Validate before the unchanged fast path too: a legacy task_state
            // diary must not remain silently accepted by Markdown sync.
            _ = try MemorySemantics.validatedWriteMetadata(
                metadata: existing?.metadata ?? [:],
                semantics: semantics,
                sessionID: nil,
                scope: sourceKind == .memory ? "durable" : nil,
                activeSession: false,
                inferredScope: scopeContext,
                nowMs: Self.nowMs()
            )

            if let existing {
                let existingInfo = MemorySemantics.parse(metadata: existing.metadata, nowMs: Self.nowMs())
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
                try validateManagedDocumentWrite(
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
            if isLockedMemory(existing) {
                counts.unchanged += 1
                continue
            }
            if !dryRun {
                try await deleteDocumentTree(frameID: existing.frameId, memory: longTermMemory)
            }
            counts.deleted += 1
        }

        return counts
    }

    private func isLockedMemory(_ document: MemoryOrchestrator.CorpusSourceDocument) -> Bool {
        MemorySemantics.parse(metadata: document.metadata, nowMs: Self.nowMs()).durability == .locked
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
            let canonicalMemoryID = Self.makeMemoryReference(frameID: document.frameId)
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

        let normalized = try managedDocumentMetadata(
            content: content,
            entry: entry,
            sourcePath: sourcePath,
            sourceKind: sourceKind,
            dateKey: dateKey,
            semantics: semantics,
            existing: existing
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

    private func validateManagedDocumentWrite(
        content: String,
        entry: MarkdownProjectionEntry,
        sourcePath: String,
        sourceKind: MarkdownProjectionKind,
        dateKey: String?,
        semantics: MemoryWriteSemantics,
        existing: MemoryOrchestrator.CorpusSourceDocument?
    ) throws {
        let normalized = try managedDocumentMetadata(
            content: content,
            entry: entry,
            sourcePath: sourcePath,
            sourceKind: sourceKind,
            dateKey: dateKey,
            semantics: semantics,
            existing: existing
        )
        try validateDurableWriteContent(content: content, metadata: normalized)
    }

    private func managedDocumentMetadata(
        content: String,
        entry: MarkdownProjectionEntry,
        sourcePath: String,
        sourceKind: MarkdownProjectionKind,
        dateKey: String?,
        semantics: MemoryWriteSemantics,
        existing: MemoryOrchestrator.CorpusSourceDocument?
    ) throws -> [String: String] {
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

        return try MemorySemantics.validatedWriteMetadata(
            metadata: baseMetadata,
            semantics: semantics,
            sessionID: nil,
            scope: sourceKind == .memory ? "durable" : nil,
            activeSession: false,
            inferredScope: scopeContext,
            nowMs: Self.nowMs()
        )
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

    func dreamProjectionLines(sessionID filterSessionID: UUID?, project: String? = nil) async throws -> [String] {
        let manifests = try BrokerSessionPersistence.listManifests(rootURL: sessionRootURL)
            .filter { $0.status == .active || $0.status == .ended }
            .filter { filterSessionID == nil || $0.sessionID == filterSessionID }
            .filter { matchesExportProject($0.project, project: project) }
            .filter { $0.status == .ended || activeSessions[$0.sessionID] != nil }
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
                sessionMemory = try await virtualSessions.openExistingSessionMemory(
                    at: URL(fileURLWithPath: manifest.storePath)
                )
                shouldClose = true
            }

            let sessionDocuments: [MemoryOrchestrator.CorpusSourceDocument]
            let recallSignals: [UInt64: BrokerSessionRecallSignals]
            do {
                sessionDocuments = try await sessionMemory.corpusSourceDocuments()
                recallSignals = try BrokerSessionPersistence.recallSignals(
                    from: BrokerSessionPersistence.loadEvents(from: URL(fileURLWithPath: manifest.eventLogPath))
                )
                if shouldClose {
                    try await sessionMemory.close()
                }
            } catch {
                if shouldClose {
                    try? await sessionMemory.close()
                }
                throw error
            }

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

    func exportMarkdownProjection(
        outputURL: URL,
        sessionID: UUID?,
        project: String? = nil
    ) async throws -> MarkdownProjectionReport {
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        let memoryDir = outputURL.appendingPathComponent("memory", isDirectory: true)
        try FileManager.default.createDirectory(at: memoryDir, withIntermediateDirectories: true)
        try await longTermMemory.flush()

        let durableDocuments = try await longTermMemory.corpusSourceDocuments()
            .filter { document in
                matchesExportProject(document.metadata[MemoryMetadataKeys.project], project: project)
            }
            .sorted { lhs, rhs in
                if lhs.timestampMs != rhs.timestampMs { return lhs.timestampMs > rhs.timestampMs }
                return lhs.frameId > rhs.frameId
            }
        let memoryMarkdown = renderMemoryMarkdown(documents: durableDocuments)
        let memoryMarkdownURL = outputURL.appendingPathComponent("MEMORY.md")
        try memoryMarkdown.write(to: memoryMarkdownURL, atomically: true, encoding: .utf8)

        var dailyNotesByDate: [String: [String]] = [:]
        var handoffLines: [String] = []
        let manifests = try BrokerSessionPersistence.listManifests(rootURL: sessionRootURL)
            .filter { sessionID == nil || $0.sessionID == sessionID }
            .filter { matchesExportProject($0.project, project: project) }
        for manifest in manifests {
            let events = try BrokerSessionPersistence.loadEvents(from: URL(fileURLWithPath: manifest.eventLogPath))
            for event in events {
                let dateKey = Self.dayString(fromMs: event.timestampMs)
                switch event.kind {
                case .remembered, .checkpoint, .promotionWritten, .promotionReviewed:
                    let summary = if let summary = event.payload["summary"], !summary.isEmpty {
                        summary
                    } else if let contentHash = event.payload["content_hash"] {
                        "session event \(event.kind.rawValue) [\(contentHash)]"
                    } else {
                        ""
                    }
                    if !summary.isEmpty {
                        let marker = MarkdownProjectionMarker(
                            managed: false,
                            sourceKind: "daily_note_event",
                            hash: Self.stableHash(summary),
                            sessionID: manifest.sessionID.uuidString,
                            sourceFrameID: event.payload["frame_id"].flatMap(UInt64.init),
                            memoryType: event.payload["memory_type"],
                            dateKey: dateKey
                        )
                        dailyNotesByDate[dateKey, default: []].append(
                            renderManagedMarkdownLine(text: summary, marker: marker)
                        )
                    }
                case .handoff:
                    let summary = "[\(dateKey)] \(manifest.agentID)/\(manifest.runID): \(event.payload["summary"] ?? "")"
                    let marker = MarkdownProjectionMarker(
                        managed: false,
                        sourceKind: "daily_note_event",
                        hash: Self.stableHash(summary),
                        sessionID: manifest.sessionID.uuidString,
                        dateKey: dateKey
                    )
                    let line = renderManagedMarkdownLine(text: summary, marker: marker)
                    handoffLines.append(line)
                    dailyNotesByDate[dateKey, default: []].append(line)
                default:
                    break
                }
            }
        }

        let managedDailyNotes = durableDocuments
            .filter { $0.metadata[MemoryMetadataKeys.sourceKind] == MarkdownProjectionKind.dailyNote.rawValue }
            .sorted { lhs, rhs in
                if lhs.timestampMs != rhs.timestampMs { return lhs.timestampMs > rhs.timestampMs }
                return lhs.frameId > rhs.frameId
        }
        for document in managedDailyNotes {
            let dateKey = Self.safeMarkdownDailyDateKey(
                document.metadata[MemoryMetadataKeys.sourceDate],
                fallbackMs: document.timestampMs
            )
            let marker = marker(for: document, kind: .dailyNote, dateKey: dateKey)
            dailyNotesByDate[dateKey, default: []].append(renderManagedMarkdownLine(text: document.text, marker: marker))
        }

        var dailyNotePaths: [String] = []
        var dailyNoteURLs = Set<URL>()
        for dateKey in dailyNotesByDate.keys.sorted() {
            let noteURL = memoryDir.appendingPathComponent("\(dateKey).md")
            var bodyLines = ["# \(dateKey)", ""]
            bodyLines.append(contentsOf: dailyNotesByDate[dateKey, default: []])
            let body = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
            try body.write(to: noteURL, atomically: true, encoding: .utf8)
            dailyNoteURLs.insert(noteURL.standardizedFileURL)
            dailyNotePaths.append(noteURL.path)
        }

        let dreamsLines = try await dreamProjectionLines(sessionID: sessionID, project: project)
        let dreamsURL = memoryDir.appendingPathComponent("DREAMS.md")
        var dreamsPath: String?
        if !dreamsLines.isEmpty {
            let body = "# DREAMS\n\n" + dreamsLines.joined(separator: "\n") + "\n"
            try body.write(to: dreamsURL, atomically: true, encoding: .utf8)
            dreamsPath = dreamsURL.path
        } else {
            try removeGeneratedMarkdownFileIfPresent(at: dreamsURL, allowedSourceKinds: [MarkdownProjectionKind.dreams.rawValue])
        }

        var handoffSummaryPath: String?
        if !handoffLines.isEmpty {
            let handoffURL = memoryDir.appendingPathComponent("HANDOFFS.md")
            let body = "# Handoffs\n\n" + handoffLines.joined(separator: "\n") + "\n"
            try body.write(to: handoffURL, atomically: true, encoding: .utf8)
            handoffSummaryPath = handoffURL.path
        } else {
            try removeGeneratedMarkdownFileIfPresent(at: memoryDir.appendingPathComponent("HANDOFFS.md"), allowedSourceKinds: ["daily_note_event"])
        }

        try removeStaleGeneratedDailyNotes(in: memoryDir, keeping: dailyNoteURLs)

        if let sessionID, activeSessions[sessionID] != nil {
            try await appendSessionEvent(
                sessionID: sessionID,
                kind: .markdownExported,
                payload: ["output_dir": outputURL.path]
            )
        }

        return MarkdownProjectionReport(
            memoryMarkdownPath: memoryMarkdownURL.path,
            dailyNotePaths: dailyNotePaths.sorted(),
            dreamsPath: dreamsPath,
            handoffSummaryPath: handoffSummaryPath
        )
    }

    private func removeStaleGeneratedDailyNotes(in memoryDir: URL, keeping currentDailyNoteURLs: Set<URL>) throws {
        guard FileManager.default.fileExists(atPath: memoryDir.path) else { return }
        let urls = try FileManager.default.contentsOfDirectory(
            at: memoryDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for url in urls where url.pathExtension == "md" {
            guard !url.lastPathComponent.hasPrefix("DREAMS"),
                  !url.lastPathComponent.hasPrefix("HANDOFFS"),
                  url.lastPathComponent.range(of: #"^\d{4}-\d{2}-\d{2}\.md$"#, options: .regularExpression) != nil,
                  !currentDailyNoteURLs.contains(url.standardizedFileURL)
            else { continue }
            try removeGeneratedMarkdownFileIfPresent(
                at: url,
                allowedSourceKinds: [MarkdownProjectionKind.dailyNote.rawValue, "daily_note_event"]
            )
        }
    }

    private func removeGeneratedMarkdownFileIfPresent(at url: URL, allowedSourceKinds: Set<String>) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let entries = try BrokerMarkdownSync.parseFile(at: url)
        guard !entries.isEmpty else { return }
        var generatedLines = Set<String>()
        let generatedOnly = entries.allSatisfy { entry in
            guard let marker = entry.marker else { return false }
            guard allowedSourceKinds.contains(marker.sourceKind) else { return false }
            guard marker.hash == Self.stableHash(entry.text) else { return false }
            if marker.sourceKind == MarkdownProjectionKind.dreams.rawValue, entry.checked == true {
                return false
            }
            generatedLines.insert(renderManagedMarkdownLine(text: entry.text, marker: marker, checked: entry.checked))
            return true
        }
        guard generatedOnly else { return }
        let raw = try String(contentsOf: url, encoding: .utf8)
        let hasUserContent = raw.components(separatedBy: .newlines).contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            guard !trimmed.hasPrefix("#") else { return false }
            return !generatedLines.contains(trimmed)
        }
        guard !hasUserContent else { return }
        try FileManager.default.removeItem(at: url)
    }

    func renderMemoryMarkdown(documents: [MemoryOrchestrator.CorpusSourceDocument]) -> String {
        var sections: [MemoryType: [String]] = [:]
        for document in documents {
            let info = MemorySemantics.parse(metadata: document.metadata, nowMs: Self.nowMs())
            guard info.durability == .durable || info.durability == .locked else { continue }
            let type = info.type
            let marker = marker(for: document, kind: .memory)
            sections[type, default: []].append(renderManagedMarkdownLine(text: document.text, marker: marker))
        }
        let orderedTypes: [MemoryType] = [.decision, .lesson, .userPreference, .constraint, .fact, .handoff, .note, .taskState]
        var lines = ["# MEMORY", ""]
        for type in orderedTypes {
            guard let entries = sections[type], !entries.isEmpty else { continue }
            lines.append("## \(type.rawValue)")
            lines.append(contentsOf: entries)
            lines.append("")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    static func dayString(fromMs timestampMs: Int64) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1000))
    }

    static func safeMarkdownDailyDateKey(_ rawValue: String?, fallbackMs: Int64) -> String {
        guard let rawValue else {
            return dayString(fromMs: fallbackMs)
        }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
            return dayString(fromMs: fallbackMs)
        }
        return trimmed
    }
}
