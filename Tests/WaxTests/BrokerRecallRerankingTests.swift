import Foundation
import Testing
@testable import Wax
import WaxTestSupport

/// Scores documents containing `marker` above the rest and records each call's documents.
private actor MarkerReranker: RerankingProvider {
    let marker: String
    private(set) var calls: [[String]] = []

    init(marker: String) {
        self.marker = marker
    }

    func scores(query: String, documents: [String]) async throws -> [Float] {
        calls.append(documents)
        return documents.map { $0.contains(marker) ? 10 : 0 }
    }
}

private struct FailingReranker: RerankingProvider {
    struct Failure: Error {}

    func scores(query: String, documents: [String]) async throws -> [Float] {
        throw Failure()
    }
}

/// Distinct durable memories that all match "apple"; the zebra one ranks last by BM25.
private let appleMemories = [
    "apple apple apple orchard harvest in the autumn",
    "apple apple pie recipe with cinnamon",
    "apple tree planted in the back garden",
    "green apple slices packed for lunch",
    "an apple a day keeps the doctor away, says the zebra at the zoo",
]

/// The automatic stage's shape (hybrid only, order kept on failure) with a test provider.
private func automaticStage(_ provider: any RerankingProvider) -> RerankStage {
    RerankStage(provider: provider, options: .default, scope: .hybridOnly, keepsRetrievalOrderOnFailure: true)
}

private func withBrokerEnvironment<T>(
    reranking: RerankStage?,
    _ body: (BrokerRecall.Environment) async throws -> T
) async throws -> T {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-broker-rerank-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    var config = OrchestratorConfig.default
    config.enableStructuredMemory = false
    config.enableAccessStatsScoring = false
    let longTerm = try await MemoryOrchestrator(
        at: root.appendingPathComponent("durable.wax"),
        config: config,
        embedder: ConstantEmbedder(vector: [1, 0], provider: "Wax", model: "E5SmallV2-prefixed")
    )
    let sessionRoot = root.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: sessionRoot, withIntermediateDirectories: true)
    let sessions = VirtualSessionStore(
        sessionRootURL: sessionRoot,
        brokerInstanceID: UUID().uuidString,
        openExisting: { url, _ in
            var sessionConfig = OrchestratorConfig.default
            sessionConfig.enableVectorSearch = false
            sessionConfig.enableStructuredMemory = false
            return try await MemoryOrchestrator(at: url, config: sessionConfig)
        }
    )
    let ended = DiskEndedSessionStore(
        sessionRootURL: sessionRoot,
        noEmbedder: true,
        enableAccessStatsScoring: false,
        readiness: EmbeddingReadiness()
    )
    do {
        for text in appleMemories {
            _ = try await longTerm.remember(text)
        }
        try await longTerm.flush()
        let environment = BrokerRecall.Environment(
            longTermMemory: longTerm,
            sessions: sessions,
            endedSessions: ended,
            preview: { $0 ?? "" },
            canonicalFrameID: { frameID, _ in frameID },
            nowMs: { Int64(Date().timeIntervalSince1970 * 1000) },
            reranking: reranking
        )
        let result = try await body(environment)
        await sessions.closeAll()
        try await longTerm.close()
        return result
    } catch {
        await sessions.closeAll()
        try? await longTerm.close()
        throw error
    }
}

private func recallHits(
    _ arguments: [String: AgentBrokerValue],
    reranking: RerankStage?
) async throws -> [LayeredRecall.Hit] {
    try await withBrokerEnvironment(reranking: reranking) { environment in
        let decoded = try BrokerCommand.decode(command: "recall", arguments: arguments)
        guard case .recall(let command) = decoded else {
            throw BrokerValidationError.invalid("expected recall command")
        }
        return try await BrokerRecall.recall(command, in: environment).hits
    }
}

private func hit(_ text: String, frameID: UInt64, horizon: LayeredRecall.Horizon = .durable) -> LayeredRecall.Hit {
    let id: MemoryID = horizon == .durable
        ? .durable(frameID: frameID)
        : .make(horizon: horizon, sessionID: UUID(), frameID: frameID)
    return LayeredRecall.Hit(
        id: id,
        score: 1,
        text: text,
        preview: text,
        metadata: [:],
        explanations: [],
        timestampMs: 0
    )
}

@Suite struct BrokerRecallRerankingTests {
    private let threeApples: [String: AgentBrokerValue] = ["query": .string("apple"), "limit": .int(3)]

    @Test func hybridRecallReranksTheMergedHitsOnce() async throws {
        let plain = try await recallHits(threeApples, reranking: nil)
        #expect(plain.count == 3)
        #expect(!plain.contains { $0.text.contains("zebra") })

        let reranker = MarkerReranker(marker: "zebra")
        let reranked = try await recallHits(threeApples, reranking: automaticStage(reranker))
        let calls = await reranker.calls
        #expect(calls.count == 1)
        // The window is the merged candidates, not just the requested three.
        #expect(calls.first?.count == appleMemories.count)
        let zebra = try #require(reranked.first { $0.text.contains("zebra") })
        #expect(zebra.explanations.contains { $0.hasPrefix("rerank: ") })
        #expect(reranked.count == 3)
    }

    @Test func textRecallSkipsTheAutomaticReranker() async throws {
        var arguments = threeApples
        arguments["mode"] = .string("text")
        let plain = try await recallHits(arguments, reranking: nil)
        let reranker = MarkerReranker(marker: "zebra")
        let reranked = try await recallHits(arguments, reranking: automaticStage(reranker))
        #expect(await reranker.calls.isEmpty)
        #expect(reranked.map(\.reference) == plain.map(\.reference))
    }

    @Test func recallKeepsThePolicyOrderWhenTheRerankerFails() async throws {
        let plain = try await recallHits(threeApples, reranking: nil)
        let reranked = try await recallHits(threeApples, reranking: automaticStage(FailingReranker()))
        #expect(!plain.isEmpty)
        #expect(reranked.map(\.reference) == plain.map(\.reference))
    }

    @Test func unlandedDemotedHitsAreNeverPromoted() async throws {
        var demoted = hit("zebra skip list", frameID: 3)
        demoted.flags.insert(.unlandedDemoted)
        let window = [hit("first", frameID: 1), hit("second", frameID: 2), demoted]
        let reranker = MarkerReranker(marker: "zebra")
        let result = try await LayeredRecall.rerankMerged(
            window: window,
            policyTop: window,
            limit: 3,
            query: "q",
            stage: automaticStage(reranker),
            text: { $0.text }
        )
        #expect(result.last?.reference == demoted.reference)
        #expect(await reranker.calls.first == ["first", "second"])
    }

    @Test func theReservedHorizonSurvivesReranking() async throws {
        let working = hit("working note", frameID: 4, horizon: .working)
        let window = [
            hit("durable one", frameID: 1),
            hit("durable zebra two", frameID: 2),
            hit("durable zebra three", frameID: 3),
            working,
        ]
        // The broker merge at limit 2 reserved a working slot.
        let policyTop = [window[0], working]
        let result = try await LayeredRecall.rerankMerged(
            window: window,
            policyTop: policyTop,
            limit: 2,
            query: "q",
            stage: automaticStage(MarkerReranker(marker: "zebra")),
            text: { $0.text }
        )
        #expect(result.count == 2)
        #expect(result.first?.reference == window[1].reference)
        #expect(result.contains { $0.reference == working.reference })
    }

    @Test func brokerServiceRecallUsesItsReranker() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-broker-service-rerank-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let reranker = MarkerReranker(marker: "zebra")
        let broker = try await AgentBrokerService(
            storePath: root.appendingPathComponent("memory.wax").path,
            sessionRootPath: root.appendingPathComponent("sessions").path,
            noEmbedder: false,
            embedderChoice: "auto",
            requireVector: false,
            embedderOverride: ConstantEmbedder(vector: [1, 0], provider: "Wax", model: "E5SmallV2-prefixed"),
            reranking: automaticStage(reranker)
        )
        do {
            for text in appleMemories {
                let written = await broker.handle(.init(command: "remember", arguments: ["content": .string(text)]))
                #expect(written.ok)
            }
            let recalled = await broker.handle(.init(command: "recall", arguments: threeApples))
            #expect(recalled.ok)
            #expect(await reranker.calls.count == 1)
            try await broker.close()
        } catch {
            try? await broker.close()
            throw error
        }
    }

    @Test func noRerankGetsItsOwnBrokerSocket() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-broker-socket-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func socketPath(noRerank: Bool?) throws -> String {
            let store = root.appendingPathComponent("memory.wax").path
            let socketRoot = root.appendingPathComponent("sockets").path
            if let noRerank {
                return try AgentBrokerPathing.configuration(
                    brokerExecutablePath: "/usr/bin/true", storePath: store, socketRootPath: socketRoot,
                    embedderChoice: "auto", noEmbedder: false, noRerank: noRerank, environment: [:]
                ).socketPath
            }
            return try AgentBrokerPathing.configuration(
                brokerExecutablePath: "/usr/bin/true", storePath: store, socketRootPath: socketRoot,
                embedderChoice: "auto", noEmbedder: false, environment: [:]
            ).socketPath
        }
        #expect(try socketPath(noRerank: false) == socketPath(noRerank: nil))
        #expect(try socketPath(noRerank: true) != socketPath(noRerank: false))
    }
}
