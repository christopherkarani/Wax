import Foundation
import Testing
@testable import Wax

struct OwnerCardTests {
    @Test
    func matchReadsLiveXHandleAndIgnoresTickets() {
        let hit = OwnerCard.match(
            content: "Chris Karani's live X handle is @ckarani7. @chris_karani 404s.",
            memoryType: .fact
        )
        #expect(hit?.slot == .xHandle)
        #expect(hit?.value == "@ckarani7")

        let replacement = OwnerCard.match(
            content: "@chris_karani 404s and must not be used. Use @ckarani7.",
            memoryType: .fact
        )
        #expect(replacement?.value == "@ckarani7")
        #expect(
            OwnerCard.match(
                content: "Do not use @chris_karani. Use @ckarani7.",
                memoryType: .fact
            )?.value == "@ckarani7"
        )
        #expect(
            OwnerCard.match(
                content: "Use @MainActor on the Wax actor.",
                memoryType: .fact
            ) == nil
        )
        #expect(
            OwnerCard.match(
                content: "Use @Observable.",
                memoryType: .fact
            ) == nil
        )

        #expect(
            OwnerCard.match(
                content: "T1 GitLiveProbe landed on arch/38e29f1a at 60bdde0.",
                memoryType: .fact
            ) == nil
        )
        #expect(
            OwnerCard.match(
                content: "Keep answers short. Lead with the answer.",
                memoryType: .lesson
            ) == nil
        )
    }

    @Test
    func matchReadsStandingPrefs() {
        #expect(
            OwnerCard.match(
                content: "Keep answers short. Lead with the answer.",
                memoryType: .userPreference
            )?.value == "short"
        )
        #expect(
            OwnerCard.match(
                content: "Chris wants coding implementors delegated to Grok Build, not Hermes delegate_task.",
                memoryType: .userPreference
            )?.value == "grok-build"
        )
        #expect(
            OwnerCard.match(
                content: "He already treats rv as the revenue product.",
                memoryType: .userPreference
            )?.value == "rv"
        )
        #expect(
            OwnerCard.match(
                content: "Chris wants Always allow visible as its own Mac desktop sidebar page.",
                memoryType: .userPreference
            ) == nil
        )
        #expect(
            OwnerCard.match(
                content: "Do not use Grok Build for coding implementors.",
                memoryType: .userPreference
            ) == nil
        )
    }

    @Test
    func compileReplacesHandleInsteadOfStacking() async throws {
        try await withOwnerCardMemory { memory in
            try await OwnerCard.apply(
                OwnerCard.Match(slot: .xHandle, value: "@chris_karani"),
                to: memory,
                frameId: 1,
                nowMs: 1_000
            )
            try await OwnerCard.apply(
                OwnerCard.Match(slot: .xHandle, value: "@ckarani7"),
                to: memory,
                frameId: 2,
                nowMs: 2_000
            )
            let facts = try await memory.facts(
                about: OwnerCard.ownerKey,
                predicate: OwnerCard.Slot.xHandle.predicate,
                limit: 10
            )
            let live = facts.hits.filter { $0.isOpenEnded && $0.relation != .retracts }
            #expect(live.count == 1)
            #expect(live.first?.fact.object == .string("@ckarani7"))
        }
    }

    @Test
    func personLaneReadsCardInsteadOfSearchingNotes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-owner-card-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var config = OrchestratorConfig.default
        config.enableTextSearch = true
        config.enableVectorSearch = false
        config.enableStructuredMemory = true
        config.rag.searchMode = .textOnly
        let durable = try await MemoryOrchestrator(
            at: root.appendingPathComponent("durable.wax"),
            config: config
        )
        do {
            _ = try await durable.remember(
                "T1 GitLiveProbe landed on arch/38e29f1a. Chris prefers short answers in this ticket.",
                metadata: [MemoryMetadataKeys.type: MemoryType.userPreference.rawValue]
            )
            try await durable.flush()
            try await OwnerCard.apply(
                OwnerCard.Match(slot: .xHandle, value: "@ckarani7"),
                to: durable,
                frameId: 99,
                nowMs: 5_000
            )
            let stores = LayeredRecall.Stores(
                longTermMemory: durable,
                workingLane: { _ in nil },
                inferWriteScope: { _, _ in .init(project: "Wax", repo: "Wax") },
                preview: { $0 ?? "" },
                canonicalFrameID: { frameID, _ in frameID },
                endedSessions: InMemoryEndedSessionStore()
            )
            let card = try await LayeredRecall.recall(
                request: .init(
                    query: "facts about this person standing corrections",
                    identity: .global(workingSessionID: nil),
                    limit: 3,
                    searchTopK: 8,
                    mode: .textOnly,
                    memoryTypes: [.userPreference]
                ),
                stores: stores
            )
            let leadHit = try #require(card.hits.first)
            #expect(leadHit.text == "X handle: @ckarani7")
            #expect(leadHit.flags.contains(.ownerCard))
            #expect(leadHit.explanations.contains("owner card"))
            #expect(!leadHit.text.contains("GitLiveProbe"))

            let search = try await LayeredRecall.recall(
                request: .init(
                    query: "GitLiveProbe",
                    identity: .global(workingSessionID: nil),
                    limit: 8,
                    searchTopK: 8,
                    mode: .textOnly
                ),
                stores: stores
            )
            #expect(search.hits.contains { $0.text.contains("GitLiveProbe") })
            try await durable.close()
        } catch {
            try? await durable.close()
            throw error
        }
    }

    @Test
    func personLaneKeepsNonSlotPrefsAfterCard() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-owner-card-rest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var config = OrchestratorConfig.default
        config.enableTextSearch = true
        config.enableVectorSearch = false
        config.enableStructuredMemory = true
        config.rag.searchMode = .textOnly
        let durable = try await MemoryOrchestrator(
            at: root.appendingPathComponent("durable.wax"),
            config: config
        )
        do {
            _ = try await durable.remember(
                "Chris wants Always allow visible as its own Mac desktop sidebar page.",
                metadata: [MemoryMetadataKeys.type: MemoryType.userPreference.rawValue]
            )
            try await durable.flush()
            try await OwnerCard.apply(
                OwnerCard.Match(slot: .xHandle, value: "@ckarani7"),
                to: durable,
                frameId: 99,
                nowMs: 5_000
            )
            let stores = LayeredRecall.Stores(
                longTermMemory: durable,
                workingLane: { _ in nil },
                inferWriteScope: { _, _ in .init(project: "Wax", repo: "Wax") },
                preview: { $0 ?? "" },
                canonicalFrameID: { frameID, _ in frameID },
                endedSessions: InMemoryEndedSessionStore()
            )
            let recalled = try await LayeredRecall.recall(
                request: .init(
                    query: "Always allow",
                    identity: .global(workingSessionID: nil),
                    limit: 3,
                    searchTopK: 8,
                    mode: .textOnly,
                    memoryTypes: [.userPreference]
                ),
                stores: stores
            )
            #expect(recalled.hits.first?.text == "X handle: @ckarani7")
            #expect(recalled.hits.first?.flags.contains(.ownerCard) == true)
            #expect(recalled.hits.first?.explanations.contains("owner card") == true)
            #expect(recalled.hits.contains { $0.text.contains("Always allow") })
            #expect(
                recalled.hits.contains {
                    $0.text.contains("Always allow") && !$0.flags.contains(.ownerCard)
                }
            )
            try await durable.close()
        } catch {
            try? await durable.close()
            throw error
        }
    }

    @Test
    func personLaneLeftoverFilterUsesOwnerCardFlagNotExplanationString() {
        let decoy = LayeredRecall.Hit(
            id: .durable(frameID: 2),
            score: 0.4,
            text: "Chris wants Always allow visible as its own Mac desktop sidebar page.",
            preview: "Chris wants Always allow visible as its own Mac desktop sidebar page.",
            metadata: [MemoryMetadataKeys.type: MemoryType.userPreference.rawValue],
            explanations: ["owner card"],
            timestampMs: 0
        )
        let card = LayeredRecall.Hit(
            id: .durable(frameID: 1),
            score: 4,
            text: "X handle: @ckarani7",
            preview: "X handle: @ckarani7",
            metadata: [
                MemoryMetadataKeys.type: MemoryType.userPreference.rawValue,
                MemoryMetadataKeys.durability: MemoryDurability.durable.rawValue,
            ],
            explanations: ["owner card"],
            timestampMs: 0,
            sources: [.structured],
            flags: [.ownerCard]
        )
        #expect(OwnerCard.matchesCompiledSlot(text: decoy.text, metadata: decoy.metadata) == false)
        let rest = [card, decoy].filter { hit in
            !hit.flags.contains(.ownerCard)
                && !OwnerCard.matchesCompiledSlot(text: hit.text, metadata: hit.metadata)
        }
        #expect(rest.map(\.frameID) == [2])
        #expect(card.flags.contains(.ownerCard))
        #expect(decoy.explanations.contains("owner card"))
        #expect(decoy.flags.contains(.ownerCard) == false)
    }

    @Test
    func collapsedHitSetsOwnerCardFlagAndKeepsDisplayString() {
        let slot = LayeredRecall.Hit(
            id: .durable(frameID: 1),
            score: 4,
            text: "X handle: @ckarani7",
            preview: "X handle: @ckarani7",
            metadata: [:],
            explanations: [],
            timestampMs: 1,
            sources: [.structured]
        )
        let other = LayeredRecall.Hit(
            id: .durable(frameID: 2),
            score: 4,
            text: "GitHub: ckarani",
            preview: "GitHub: ckarani",
            metadata: [:],
            explanations: [],
            timestampMs: 2,
            sources: [.structured]
        )
        let collapsed = OwnerCard.collapsedHit(from: [slot, other], preview: { $0 ?? "" })
        #expect(collapsed?.flags.contains(.ownerCard) == true)
        #expect(collapsed?.explanations.contains("owner card") == true)

        let single = OwnerCard.collapsedHit(from: [slot], preview: { $0 ?? "" })
        #expect(single?.flags.contains(.ownerCard) == true)
        #expect(single?.explanations.contains("owner card") == true)
    }

    @Test
    func rememberCompilesOwnerCardThroughBroker() async throws {
        try await withOwnerCardBroker { service in
            let write = await service.handle(
                .init(
                    command: "remember",
                    arguments: [
                        "content": .string("Chris Karani's live X handle is @ckarani7."),
                        "memory_type": .string(MemoryType.fact.rawValue),
                    ]
                )
            )
            #expect(write.ok == true, "remember failed: \(write.error ?? "nil")")

            let recall = await service.handle(
                .init(
                    command: "recall",
                    arguments: [
                        "query": .string("facts about this person standing corrections"),
                        "scope": .string("global"),
                        "mode": .string("text"),
                        "limit": .int(3),
                        "memory_types": .array([.string(MemoryType.userPreference.rawValue)]),
                    ]
                )
            )
            #expect(recall.ok == true, "recall failed: \(recall.error ?? "nil")")
            let texts = (recall.payload?.objectValue?["results"]?.arrayValue ?? []).compactMap {
                $0.objectValue?["text"]?.stringValue
            }
            #expect(texts == ["X handle: @ckarani7"])
        }
    }
}

private func withOwnerCardMemory(
    _ body: (MemoryOrchestrator) async throws -> Void
) async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-owner-card-\(UUID().uuidString)")
        .appendingPathExtension("wax")
    var config = OrchestratorConfig.default
    config.enableTextSearch = true
    config.enableVectorSearch = false
    config.enableStructuredMemory = true
    config.rag.searchMode = .textOnly
    let memory = try await MemoryOrchestrator(at: url, config: config)
    do {
        try await body(memory)
        try await memory.close()
        try? FileManager.default.removeItem(at: url)
    } catch {
        try? await memory.close()
        try? FileManager.default.removeItem(at: url)
        throw error
    }
}

private func withOwnerCardBroker(
    _ body: (AgentBrokerService) async throws -> Void
) async throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-owner-card-broker-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    var config = OrchestratorConfig.default
    config.enableVectorSearch = false
    config.enableTextSearch = true
    config.rag.searchMode = .textOnly
    config.liveSetRewriteSchedule = .disabled
    let service = try await AgentBrokerService(
        storePath: rootURL.appendingPathComponent("memory.wax").path,
        sessionRootPath: rootURL.appendingPathComponent("sessions").path,
        noEmbedder: true,
        embedderChoice: "auto",
        requireVector: false,
        orchestratorConfig: config
    )
    do {
        try await body(service)
        try await service.close()
    } catch {
        try? await service.close()
        throw error
    }
}
