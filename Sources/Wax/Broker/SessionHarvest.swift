import Foundation

package enum SessionHarvest {
    package struct Report: Sendable, Equatable {
        package struct Promoted: Sendable, Equatable {
            package var memoryID: String
            package var type: String
            package var preview: String
        }

        package var harvested: Bool
        package var promotedCount: Int
        package var leftoverDocumentCount: Int
        package var leftoverLockedCount: Int
        package var reclaimAfterMs: Int64?
        package var error: String?
        package var alreadyHarvested: Bool
        package var promoted: [Promoted] = []
        package var leftoverReasons: [String] = []

        package var leftoverCount: Int { leftoverDocumentCount }

        package static let skipped = Report(
            harvested: false,
            promotedCount: 0,
            leftoverDocumentCount: 0,
            leftoverLockedCount: 0,
            reclaimAfterMs: nil,
            error: nil,
            alreadyHarvested: false,
            promoted: [],
            leftoverReasons: []
        )

        package var immediateReclaimEligible: Bool {
            harvested
                && error == nil
                && leftoverDocumentCount == 0
                && leftoverLockedCount == 0
        }
    }

    /// Close harvest trusts explicit types. Implicit notes/task_state still need recall
    /// even when text cues would make operator `promote` always-write.
    private static func harvestShouldWrite(
        proposal: BrokerPromotionProposal,
        storedType: MemoryType,
        settings: BrokerPromotionSettings
    ) -> Bool {
        guard proposal.shouldWrite else { return false }
        if storedType == .note || storedType == .taskState {
            return proposal.recallCount >= settings.minimumRecallCount
        }
        return true
    }

    package static func run(
        sessionMemory: MemoryOrchestrator,
        longTermMemory: MemoryOrchestrator,
        sessionID: UUID,
        manifest: BrokerSessionManifest,
        events: [BrokerSessionEvent],
        scope: MemoryScopeContext?,
        settings: BrokerPromotionSettings = .default,
        retention: MemoryRetentionSettings = .fromEnvironment(),
        nowMs: Int64
    ) async -> Report {
        if let harvestedAtMs = manifest.harvestedAtMs, manifest.harvestError == nil {
            let immediate = manifest.reclaimAfterMs == harvestedAtMs
            return Report(
                harvested: true,
                promotedCount: manifest.promotedCount,
                leftoverDocumentCount: immediate ? 0 : 1,
                leftoverLockedCount: 0,
                reclaimAfterMs: manifest.reclaimAfterMs,
                error: nil,
                alreadyHarvested: true,
                promoted: [],
                leftoverReasons: []
            )
        }

        do {
            let documents = try await sessionMemory.corpusSourceDocuments()
            var longTermDocuments = try await longTermMemory.corpusSourceDocuments()
            let recallSignals = BrokerSessionPersistence.recallSignals(from: events)
            let sessionStats = await sessionMemory.accessStatsSnapshot()
            var promoted: [Report.Promoted] = []
            var leftoverDocumentCount = 0
            var leftoverLockedCount = 0
            var leftoverReasons: [String] = []
            var harvestError: String?

            func recordLeftover(_ reason: String? = nil) {
                leftoverDocumentCount += 1
                if let reason {
                    leftoverReasons.append(reason)
                }
            }

            for document in documents {
                let info = MemorySemantics.parse(metadata: document.metadata, nowMs: nowMs)
                if info.durability == .locked {
                    leftoverLockedCount += 1
                    recordLeftover("locked")
                    continue
                }
                let storedType = info.type
                let proposal = BrokerMemoryInsights.proposePromotion(
                    content: document.text,
                    metadata: document.metadata,
                    sessionID: sessionID,
                    sourceFrameID: document.frameId,
                    scope: scope,
                    longTermDocuments: longTermDocuments,
                    recallSignals: recallSignals[document.frameId],
                    settings: settings
                )
                guard harvestShouldWrite(proposal: proposal, storedType: storedType, settings: settings) else {
                    let exactDuplicate = !proposal.shouldWrite
                        && (proposal.duplicateMatches.first?.similarity ?? 0) >= 0.92
                    if exactDuplicate {
                        recordLeftover("dup")
                    } else if (storedType == .note || storedType == .taskState)
                        && proposal.recallCount < settings.minimumRecallCount
                    {
                        recordLeftover("note_low_recall")
                    } else {
                        recordLeftover()
                    }
                    continue
                }
                var metadata = MemorySemantics.approvedPromotionMetadata(
                    metadata: document.metadata,
                    semantics: MemoryWriteSemantics(),
                    suggestedType: proposal.suggestedType,
                    suggestedDurability: proposal.suggestedDurability,
                    suggestedConfidence: proposal.confidence
                )
                metadata[MemoryMetadataKeys.promotedFromSession] = sessionID.uuidString
                metadata[MemoryMetadataKeys.promotedFromFrame] = String(document.frameId)
                metadata[MemoryMetadataKeys.tier] = MemoryTier.hot.rawValue
                metadata.removeValue(forKey: "session_id")
                if SecretHeuristics.detectSecretLikeContent(document.text, metadata: metadata) != nil {
                    recordLeftover("secret")
                    continue
                }
                let destination: RememberDestination
                do {
                    destination = try RememberDestination.decode(
                        sessionID: nil,
                        writeScope: .durable,
                        semantics: MemoryWriteSemantics(),
                        metadata: metadata
                    )
                } catch {
                    recordLeftover()
                    continue
                }
                guard case .durable = destination else {
                    recordLeftover()
                    continue
                }
                do {
                    let written = try await longTermMemory.remember(document.text, metadata: metadata)
                    if let sourceStats = sessionStats[document.frameId] {
                        await longTermMemory.seedAccessStats(frameId: written.frameId, from: sourceStats)
                    }
                    longTermDocuments.append(
                        MemoryOrchestrator.CorpusSourceDocument(
                            frameId: written.frameId,
                            timestampMs: nowMs,
                            kind: document.kind,
                            role: document.role,
                            text: document.text,
                            metadata: metadata
                        )
                    )
                    promoted.append(
                        Report.Promoted(
                            memoryID: MemoryID.durable(frameID: written.frameId).wire,
                            type: metadata[MemoryMetadataKeys.type] ?? storedType.rawValue,
                            preview: MemorySemantics.summarizeCandidate(document.text)
                        )
                    )
                } catch {
                    recordLeftover()
                    if harvestError == nil {
                        harvestError = error.localizedDescription
                    }
                }
            }
            let promotedCount = promoted.count
            do {
                try await longTermMemory.flush()
            } catch {
                harvestError = error.localizedDescription
                return Report(
                    harvested: false,
                    promotedCount: promotedCount,
                    leftoverDocumentCount: leftoverDocumentCount,
                    leftoverLockedCount: leftoverLockedCount,
                    reclaimAfterMs: nil,
                    error: harvestError,
                    alreadyHarvested: false,
                    promoted: promoted,
                    leftoverReasons: leftoverReasons
                )
            }

            let immediate = leftoverDocumentCount == 0 && leftoverLockedCount == 0 && harvestError == nil
            let reclaimAfterMs = immediate ? nowMs : nowMs + retention.recentlyClosedMs
            return Report(
                harvested: true,
                promotedCount: promotedCount,
                leftoverDocumentCount: leftoverDocumentCount,
                leftoverLockedCount: leftoverLockedCount,
                reclaimAfterMs: reclaimAfterMs,
                error: harvestError,
                alreadyHarvested: false,
                promoted: promoted,
                leftoverReasons: leftoverReasons
            )
        } catch {
            return Report(
                harvested: false,
                promotedCount: 0,
                leftoverDocumentCount: 0,
                leftoverLockedCount: 0,
                reclaimAfterMs: nil,
                error: error.localizedDescription,
                alreadyHarvested: false,
                promoted: [],
                leftoverReasons: []
            )
        }
    }
}
