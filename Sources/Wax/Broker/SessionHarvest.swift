import Foundation

package enum SessionHarvest {
    package struct Report: Sendable, Equatable {
        package var harvested: Bool
        package var promotedCount: Int
        package var leftoverDocumentCount: Int
        package var leftoverLockedCount: Int
        package var reclaimAfterMs: Int64?
        package var error: String?
        package var alreadyHarvested: Bool

        package static let skipped = Report(
            harvested: false,
            promotedCount: 0,
            leftoverDocumentCount: 0,
            leftoverLockedCount: 0,
            reclaimAfterMs: nil,
            error: nil,
            alreadyHarvested: false
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
                alreadyHarvested: true
            )
        }

        do {
            let documents = try await sessionMemory.corpusSourceDocuments()
            var longTermDocuments = try await longTermMemory.corpusSourceDocuments()
            let recallSignals = BrokerSessionPersistence.recallSignals(from: events)
            let sessionStats = await sessionMemory.accessStatsSnapshot()
            var promotedCount = 0
            var leftoverDocumentCount = 0
            var leftoverLockedCount = 0
            var harvestError: String?

            for document in documents {
                let info = MemorySemantics.parse(metadata: document.metadata, nowMs: nowMs)
                if info.durability == .locked {
                    leftoverLockedCount += 1
                    leftoverDocumentCount += 1
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
                    leftoverDocumentCount += 1
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
                    leftoverDocumentCount += 1
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
                    leftoverDocumentCount += 1
                    continue
                }
                guard case .durable = destination else {
                    leftoverDocumentCount += 1
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
                    promotedCount += 1
                } catch {
                    leftoverDocumentCount += 1
                    if harvestError == nil {
                        harvestError = error.localizedDescription
                    }
                }
            }
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
                    alreadyHarvested: false
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
                alreadyHarvested: false
            )
        } catch {
            return Report(
                harvested: false,
                promotedCount: 0,
                leftoverDocumentCount: 0,
                leftoverLockedCount: 0,
                reclaimAfterMs: nil,
                error: error.localizedDescription,
                alreadyHarvested: false
            )
        }
    }
}
