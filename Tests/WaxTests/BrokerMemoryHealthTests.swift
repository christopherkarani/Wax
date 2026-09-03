import Testing
import WaxCore
@testable import Wax

struct BrokerMemoryHealthTests {
    private let nowMs: Int64 = 2_000_000_000_000
    private let dayMs: Int64 = 24 * 60 * 60 * 1000
    private let decisionText = "Prefer project-scoped recall; never auto-widen an empty project lane."

    @Test
    func unsupersededDuplicateDecisionsIdentifiesSameProjectDurablePair() throws {
        let left = document(frameId: 11, text: decisionText, type: .decision, durability: .durable, project: "wax-health")
        let right = document(frameId: 22, text: decisionText, type: .decision, durability: .durable, project: "wax-health")
        let report = BrokerMemoryInsights.healthReport(
            documents: [left, right],
            accessStats: [:],
            facts: nil,
            nowMs: nowMs
        )

        #expect(report.unsupersededDuplicateDecisions.isEmpty == false)
        let pair = try #require(report.unsupersededDuplicateDecisions.first)
        #expect(pair.leftFrameId == 11)
        #expect(pair.rightFrameId == 22)
        #expect(pair.similarity == 1)
        #expect(report.duplicatePairs.isEmpty == false)
    }

    @Test
    func sameTextsInDifferentProjectsAreNotUnsupersededDuplicateDecisions() {
        let left = document(frameId: 11, text: decisionText, type: .decision, durability: .durable, project: "wax-alpha")
        let right = document(frameId: 22, text: decisionText, type: .decision, durability: .durable, project: "wax-beta")
        let report = BrokerMemoryInsights.healthReport(
            documents: [left, right],
            accessStats: [:],
            facts: nil,
            nowMs: nowMs
        )

        #expect(report.unsupersededDuplicateDecisions.isEmpty)
        #expect(report.duplicatePairs.isEmpty == false)
    }

    @Test
    func lessonVersusDecisionIsNotAnUnsupersededDuplicateDecision() {
        let decision = document(frameId: 11, text: decisionText, type: .decision, durability: .durable, project: "wax-health")
        let lesson = document(frameId: 22, text: decisionText, type: .lesson, durability: .durable, project: "wax-health")
        let report = BrokerMemoryInsights.healthReport(
            documents: [decision, lesson],
            accessStats: [:],
            facts: nil,
            nowMs: nowMs
        )

        #expect(report.unsupersededDuplicateDecisions.isEmpty)
        #expect(report.duplicatePairs.isEmpty == false)
    }

    @Test
    func omittingSupersededFrameRemovesTheDuplicateDecisionPair() {
        let live = document(frameId: 22, text: decisionText, type: .decision, durability: .durable, project: "wax-health")
        let report = BrokerMemoryInsights.healthReport(
            documents: [live],
            accessStats: [:],
            facts: nil,
            nowMs: nowMs
        )

        #expect(report.unsupersededDuplicateDecisions.isEmpty)
        #expect(report.duplicatePairs.isEmpty)
    }

    @Test
    func structuredFactContradictionsStillPopulateSummaries() {
        let facts = StructuredFactsResult(
            hits: [
                openEndedFact(id: 1, subject: "service:broker", predicate: "store", object: "sqlite"),
                openEndedFact(id: 2, subject: "service:broker", predicate: "store", object: "grdb"),
            ],
            wasTruncated: false
        )
        let report = BrokerMemoryInsights.healthReport(
            documents: [],
            accessStats: [:],
            facts: facts,
            nowMs: nowMs
        )

        #expect(report.contradictionSummaries == [
            "service:broker has multiple current 'store' values: grdb, sqlite",
        ])
    }

    @Test
    func fortyDayDurableDecisionIsNotStaleByAge() {
        let durable = document(
            frameId: 40,
            text: decisionText,
            type: .decision,
            durability: .durable,
            project: "wax-health",
            createdAtMs: nowMs - (40 * dayMs)
        )
        let working = document(
            frameId: 41,
            text: "Scratch working note about health stale windows.",
            type: .note,
            durability: .working,
            project: "wax-health",
            createdAtMs: nowMs - (40 * dayMs)
        )
        let report = BrokerMemoryInsights.healthReport(
            documents: [durable, working],
            accessStats: [:],
            facts: nil,
            nowMs: nowMs
        )

        #expect(report.staleFrameIds.contains(40) == false)
        #expect(report.staleFrameIds.contains(41))
    }

    private func document(
        frameId: UInt64,
        text: String,
        type: MemoryType,
        durability: MemoryDurability,
        project: String,
        createdAtMs: Int64? = nil
    ) -> MemoryOrchestrator.CorpusSourceDocument {
        let created = createdAtMs ?? nowMs
        return MemoryOrchestrator.CorpusSourceDocument(
            frameId: frameId,
            timestampMs: created,
            kind: nil,
            role: .document,
            text: text,
            metadata: [
                MemoryMetadataKeys.type: type.rawValue,
                MemoryMetadataKeys.durability: durability.rawValue,
                MemoryMetadataKeys.project: project,
                MemoryMetadataKeys.createdAtMs: String(created),
            ]
        )
    }

    private func openEndedFact(
        id: Int64,
        subject: String,
        predicate: String,
        object: String
    ) -> StructuredFactHit {
        StructuredFactHit(
            factId: FactRowID(rawValue: id),
            spanId: id,
            fact: StructuredFact(
                subject: EntityKey(subject),
                predicate: PredicateKey(predicate),
                object: .string(object)
            ),
            relation: .sets,
            valid: StructuredTimeRange(fromMs: 0),
            system: StructuredTimeRange(fromMs: 0),
            evidence: [],
            isOpenEnded: true
        )
    }
}
