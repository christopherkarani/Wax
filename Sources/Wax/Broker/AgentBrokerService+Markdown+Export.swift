import Foundation

extension AgentBrokerService {
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
                // Export only reads: it must not commit a catch-up into an ended store.
                sessionMemory = try await virtualSessions.openExistingSessionMemory(
                    at: URL(fileURLWithPath: manifest.storePath),
                    catchUp: false
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
            let info = MemorySemantics.parse(metadata: document.metadata, nowMs: BrokerClock.nowMs())
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
