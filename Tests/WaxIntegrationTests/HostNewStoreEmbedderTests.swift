import Foundation
import Testing
@testable import Wax
import WaxCore
import WaxTestSupport
import WaxVectorSearch

/// The CLI, MCP server and broker merge hits from several stores by score, so `auto` gives new
/// stores e5 only while none of the stores they serve is bound to MiniLM.
private enum HostIdentities {
    static func wax(_ model: String) -> EmbeddingIdentity {
        EmbeddingIdentity(provider: "Wax", model: model, dimensions: 384, normalized: true)
    }

    static let miniLM = wax("MiniLMAll-mean")
    static let e5 = wax("E5SmallV2-prefixed")
    static let defaultBuild: [BuiltInEmbeddingProvider: EmbeddingIdentity] = [.miniLM: miniLM, .e5: e5]
    static let vector = Array(repeating: Float(1 / 384.0.squareRoot()), count: 384)

    static func state(_ identity: EmbeddingIdentity?, vectors: UInt64) -> CommittedEmbeddingState {
        CommittedEmbeddingState(
            binding: identity.map(MemoryBindingCompatibility.binding(from:)),
            vectorCount: vectors
        )
    }

    static func embedder(_ identity: EmbeddingIdentity) -> ConstantEmbedder {
        ConstantEmbedder(vector: vector, identity: identity)
    }

    /// Writes one embedded memory, so the store is bound to `identity` and holds a vector.
    static func writeStore(at url: URL, boundTo identity: EmbeddingIdentity) async throws {
        var config = OrchestratorConfig.default
        config.requireOnDeviceProviders = false
        let writer = try await MemoryOrchestrator(at: url, config: config, embedder: embedder(identity))
        try await writer.remember("a memory written by \(identity.model ?? "an embedder")")
        try await writer.flush()
        try await writer.close()
    }

    static func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-host-new-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

// MARK: - Policy

@Test func hostNewStoresGetE5WhenNoServedStoreIsBound() {
    let choice = HostNewStoreEmbedder.provider(
        states: [nil, HostIdentities.state(nil, vectors: 0)],
        available: HostIdentities.defaultBuild
    )
    #expect(choice == .e5)
}

@Test func hostNewStoresStayOnE5BesideE5Stores() {
    let choice = HostNewStoreEmbedder.provider(
        states: [HostIdentities.state(HostIdentities.e5, vectors: 4)],
        available: HostIdentities.defaultBuild
    )
    #expect(choice == .e5)
}

@Test func hostNewStoresFollowAnyMiniLMBoundStore() {
    let choice = HostNewStoreEmbedder.provider(
        states: [
            HostIdentities.state(HostIdentities.e5, vectors: 4),
            HostIdentities.state(HostIdentities.miniLM, vectors: 2),
        ],
        available: HostIdentities.defaultBuild
    )
    #expect(choice == .miniLM)
}

@Test func hostNewStoresFollowTheSupersededMiniLM() {
    // Stores from before mean pooling (#257) are bound to "MiniLMAll" and re-embed with MiniLM.
    let choice = HostNewStoreEmbedder.provider(
        states: [HostIdentities.state(HostIdentities.wax("MiniLMAll"), vectors: 2)],
        available: HostIdentities.defaultBuild
    )
    #expect(choice == .miniLM)
}

@Test func hostNewStoresFollowUnboundLegacyVectors() {
    // Vectors without a binding predate bindings, and only MiniLM wrote stores then.
    let choice = HostNewStoreEmbedder.provider(
        states: [HostIdentities.state(nil, vectors: 3)],
        available: HostIdentities.defaultBuild
    )
    #expect(choice == .miniLM)
}

@Test func hostNewStoresGetMiniLMWhenTheBuildHasNoE5() {
    let choice = HostNewStoreEmbedder.provider(
        states: [],
        available: [.miniLM: HostIdentities.miniLM]
    )
    #expect(choice == .miniLM)
}

@Test func hostAutomaticChoiceIsOnlyAutoOrEmpty() {
    #expect(HostNewStoreEmbedder.isAutomatic("auto"))
    #expect(HostNewStoreEmbedder.isAutomatic(" AUTO "))
    #expect(HostNewStoreEmbedder.isAutomatic(""))
    #expect(!HostNewStoreEmbedder.isAutomatic("minilm"))
    #expect(!HostNewStoreEmbedder.isAutomatic("e5"))
}

// MARK: - Reading a store's binding

@Test func committedEmbeddingStateIsNilForAMissingStore() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-missing-\(UUID().uuidString).wax")
    #expect(try Wax.committedEmbeddingState(at: url) == nil)
}

@Test func committedEmbeddingStateReadsTheBindingWhileAnotherOpenHoldsTheStore() async throws {
    try await TempFiles.withTempFile { url in
        try await HostIdentities.writeStore(at: url, boundTo: HostIdentities.miniLM)

        var config = OrchestratorConfig.default
        config.requireOnDeviceProviders = false
        let holder = try await MemoryOrchestrator(
            at: url,
            config: config,
            embedder: HostIdentities.embedder(HostIdentities.miniLM)
        )
        let state = try Wax.committedEmbeddingState(at: url)
        try await holder.close()

        #expect(state?.binding?.embeddingModel == HostIdentities.miniLM.model)
        #expect((state?.vectorCount ?? 0) > 0)
    }
}

@Test func hostNewStoreProviderReadsServedStoresOnDisk() async throws {
    try await TempFiles.withTempFile { url in
        #expect(HostNewStoreEmbedder.provider(servedStores: [url], available: HostIdentities.defaultBuild) == .e5)
        try await HostIdentities.writeStore(at: url, boundTo: HostIdentities.miniLM)
        #expect(HostNewStoreEmbedder.provider(servedStores: [url], available: HostIdentities.defaultBuild) == .miniLM)
    }
}

// MARK: - Hosts

#if MiniLMEmbeddings && E5Embeddings
@Test func hostRequestResolvesAutoFromTheServedStores() async throws {
    guard #available(macOS 15.0, iOS 18.0, *) else { return }
    try await TempFiles.withTempFile { url in
        #expect(
            try HostEmbeddingReadiness.request(
                noEmbedder: false,
                requireVector: false,
                embedderChoice: "auto",
                servedStores: [url]
            ) == .automatic(.e5, .default)
        )
        try await HostIdentities.writeStore(at: url, boundTo: HostIdentities.miniLM)
        #expect(
            try HostEmbeddingReadiness.request(
                noEmbedder: false,
                requireVector: false,
                embedderChoice: "auto",
                servedStores: [url]
            ) == .automatic(.miniLM, .default)
        )
        #expect(
            try HostEmbeddingReadiness.request(
                noEmbedder: false,
                requireVector: true,
                embedderChoice: "auto",
                servedStores: [url]
            ) == .builtIn(.miniLM, .default)
        )
        // An explicit choice wins over the stores on disk.
        #expect(
            try HostEmbeddingReadiness.request(
                noEmbedder: false,
                requireVector: false,
                embedderChoice: "e5",
                servedStores: [url]
            ) == .automatic(.e5, .default)
        )
    }
}

private func makeBroker(
    root: URL,
    embedderChoice: String,
    factoryIdentity: EmbeddingIdentity
) async throws -> AgentBrokerService {
    try await AgentBrokerService(
        storePath: root.appendingPathComponent("memory.wax").path,
        sessionRootPath: root.appendingPathComponent("sessions").path,
        noEmbedder: false,
        embedderChoice: embedderChoice,
        requireVector: false,
        readiness: EmbeddingReadiness(),
        factoryOverride: { HostIdentities.embedder(factoryIdentity) },
        automaticEmbeddingBackfill: false
    )
}

/// Opens a session and returns the built-in its new store loads.
private func newSessionProvider(_ broker: AgentBrokerService) async throws -> BuiltInEmbeddingProvider? {
    let opened = await broker.handle(.init(command: "session_open", arguments: [
        "project": .string("host-new-store"),
        "agent_id": .string("host-new-store-agent"),
        "run_id": .string(UUID().uuidString),
    ]))
    let rawID = try #require(opened.payload?.objectValue?["session_id"]?.stringValue, "\(opened)")
    let sessionID = try #require(UUID(uuidString: rawID))
    let memory = try #require(await broker.activeSessions[sessionID]?.memory)
    return await memory.automaticProvider
}

@Test func brokerGivesAFreshInstallE5Stores() async throws {
    guard #available(macOS 15.0, iOS 18.0, *) else { return }
    let root = try HostIdentities.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let broker = try await makeBroker(root: root, embedderChoice: "auto", factoryIdentity: HostIdentities.e5)
    do {
        #expect(await broker.embedderChoice == "e5")
        #expect(await broker.longTermMemory.automaticProvider == .e5)
        #expect(try await newSessionProvider(broker) == .e5)
        try await broker.close()
    } catch {
        try? await broker.close()
        throw error
    }
}

@Test func brokerNewStoresFollowAMiniLMDurableStore() async throws {
    guard #available(macOS 15.0, iOS 18.0, *) else { return }
    let root = try HostIdentities.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let durable = root.appendingPathComponent("memory.wax")
    try await HostIdentities.writeStore(at: durable, boundTo: HostIdentities.miniLM)

    let broker = try await makeBroker(root: root, embedderChoice: "auto", factoryIdentity: HostIdentities.miniLM)
    do {
        #expect(await broker.embedderChoice == "minilm")
        #expect(await broker.longTermMemory.automaticProvider == .miniLM)
        #expect(try await newSessionProvider(broker) == .miniLM)
        try await broker.close()
    } catch {
        try? await broker.close()
        throw error
    }
    // The durable store keeps its binding.
    #expect(try Wax.committedEmbeddingState(at: durable)?.binding?.embeddingModel == HostIdentities.miniLM.model)
}

@Test func brokerNewStoresFollowAMiniLMSessionStore() async throws {
    guard #available(macOS 15.0, iOS 18.0, *) else { return }
    let root = try HostIdentities.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessions = root.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let oldSession = sessions.appendingPathComponent("\(UUID().uuidString).wax")
    try await HostIdentities.writeStore(at: oldSession, boundTo: HostIdentities.miniLM)

    let broker = try await makeBroker(root: root, embedderChoice: "auto", factoryIdentity: HostIdentities.miniLM)
    do {
        // The durable store is new, yet recall would merge it with the MiniLM session store.
        #expect(await broker.longTermMemory.automaticProvider == .miniLM)
        #expect(try await newSessionProvider(broker) == .miniLM)
        try await broker.close()
    } catch {
        try? await broker.close()
        throw error
    }
    #expect(try Wax.committedEmbeddingState(at: oldSession)?.binding?.embeddingModel == HostIdentities.miniLM.model)
}

@Test func brokerExplicitEmbedderWinsOverAMiniLMDurableStore() async throws {
    guard #available(macOS 15.0, iOS 18.0, *) else { return }
    let root = try HostIdentities.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let durable = root.appendingPathComponent("memory.wax")
    try await HostIdentities.writeStore(at: durable, boundTo: HostIdentities.miniLM)

    let broker = try await makeBroker(root: root, embedderChoice: "e5", factoryIdentity: HostIdentities.e5)
    do {
        #expect(await broker.embedderChoice == "e5")
        // The existing store still opens with the built-in that wrote it.
        #expect(await broker.longTermMemory.automaticProvider == .miniLM)
        #expect(try await newSessionProvider(broker) == .e5)
        try await broker.close()
    } catch {
        try? await broker.close()
        throw error
    }
    #expect(try Wax.committedEmbeddingState(at: durable)?.binding?.embeddingModel == HostIdentities.miniLM.model)
}
#endif
