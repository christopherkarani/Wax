import Foundation
import Testing
@testable import Wax

@Test
func embeddingReadinessCustomIsActiveImmediately() async throws {
    let readiness = EmbeddingReadiness()
    let provider = RecordingEmbedder(model: "FromHost")
    let session = try await readiness.open(.custom(provider))

    #expect(await session.status == .active(provider.identity))
    #expect(await session.currentProvider()?.identity?.model == "FromHost")
    #expect(EmbeddingStatus.active(provider.identity).isQueryEmbedderConfigured)
}

@Test
func embeddingReadinessDisabledHasNoProvider() async throws {
    let session = try await EmbeddingReadiness().open(.disabled)

    #expect(await session.status == .disabled)
    #expect(await session.currentProvider() == nil)
    #expect(!EmbeddingStatus.disabled.isQueryEmbedderConfigured)
}

@Test
func embeddingReadinessAutomaticOpensWhileLoadingThenBecomesActive() async throws {
    let gate = Gate()
    let calls = Counter()
    let key = EmbeddingLoadKey(provider: "test", configuration: "slow-auto")
    let session = try await EmbeddingReadiness().open(
        .automatic(key: key, waitTimeout: .seconds(5), factory: {
            await calls.increment()
            await gate.wait()
            return RecordingEmbedder(model: "FromFactory")
        })
    )

    #expect(await session.status == .loading)
    #expect(await session.currentProvider() == nil)
    #expect(!EmbeddingStatus.loading.isQueryEmbedderConfigured)

    await gate.open()
    let settled = await session.waitUntilSettled()
    #expect(settled == .active(RecordingEmbedder(model: "FromFactory").identity))
    #expect(await session.currentProvider()?.identity?.model == "FromFactory")
    #expect(await calls.value() == 1)
}

@Test
func embeddingReadinessBuiltInWaitsAndThrowsOnFailure() async {
    let key = EmbeddingLoadKey(provider: "test", configuration: "boom")
    await #expect(throws: TestEmbedderError.boom) {
        _ = try await EmbeddingReadiness().open(
            .builtIn(key: key, waitTimeout: nil, factory: {
                throw TestEmbedderError.boom
            })
        )
    }
}

@Test
func embeddingReadinessKeyedCompileRunsFactoryOnce() async throws {
    let gate = Gate()
    let calls = Counter()
    let readiness = EmbeddingReadiness()
    let key = EmbeddingLoadKey(provider: "test", configuration: "shared")
    let factory: @Sendable () async throws -> any EmbeddingProvider = {
        await calls.increment()
        await gate.wait()
        return RecordingEmbedder(model: "Shared")
    }

    let first = try await readiness.open(
        .automatic(key: key, waitTimeout: .seconds(5), factory: factory)
    )
    let second = try await readiness.open(
        .automatic(key: key, waitTimeout: .seconds(5), factory: factory)
    )
    #expect(await first.status == .loading)
    #expect(await second.status == .loading)

    await gate.open()
    _ = await first.waitUntilSettled()
    _ = await second.waitUntilSettled()
    #expect(await calls.value() == 1)
}

@Test
func embeddingReadinessTimedOutWaiterDoesNotCancelCompile() async throws {
    let gate = Gate()
    let calls = Counter()
    let readiness = EmbeddingReadiness()
    let key = EmbeddingLoadKey(provider: "test", configuration: "keep-work")
    let factory: @Sendable () async throws -> any EmbeddingProvider = {
        await calls.increment()
        await gate.wait()
        return RecordingEmbedder(model: "Kept")
    }

    await #expect(throws: EmbeddingReadiness.WaitError.timedOut) {
        _ = try await readiness.open(
            .builtIn(key: key, waitTimeout: .milliseconds(30), factory: factory)
        )
    }

    await gate.open()
    let session = try await readiness.open(
        .builtIn(key: key, waitTimeout: .seconds(2), factory: factory)
    )
    #expect(await session.status == .active(RecordingEmbedder(model: "Kept").identity))
    #expect(await calls.value() == 1)
}

@Test
func embeddingReadinessAutomaticWaitTimeoutMarksUnavailableThenBecomesActive() async throws {
    let gate = Gate()
    let key = EmbeddingLoadKey(provider: "test", configuration: "auto-timeout")
    let session = try await EmbeddingReadiness().open(
        .automatic(key: key, waitTimeout: .milliseconds(40), factory: {
            await gate.wait()
            return RecordingEmbedder(model: "Late")
        })
    )

    #expect(await session.status == .loading)
    let settled = await session.waitUntilSettled()
    guard case .unavailable = settled else {
        Issue.record("expected unavailable after wait timeout, got \(settled)")
        return
    }

    await gate.open()
    let compileResult = await session.waitUntilCompileFinished()
    switch compileResult {
    case .success(let provider):
        #expect(provider.identity?.model == "Late")
        #expect(await session.currentProvider()?.identity?.model == "Late")
        #expect(await session.status == .active(provider.identity))
    case .failure(let error):
        Issue.record("expected live-attach after timed-out compile finished, got \(error)")
    }
}

@Test
func embeddingReadinessIdentityComesFromProviderNotWrapper() async throws {
    let provider = RecordingEmbedder(model: "MiniLMAll")
    let session = try await EmbeddingReadiness().open(.custom(provider))
    #expect(await session.currentProvider()?.identity?.model == "MiniLMAll")
}

@Test
func hostEmbeddingReadinessMapsExistingFlags() throws {
    #expect(
        try HostEmbeddingReadiness.request(
            noEmbedder: true,
            requireVector: false,
            embedderChoice: "auto"
        ) == .disabled
    )
    #expect(
        try HostEmbeddingReadiness.request(
            noEmbedder: false,
            requireVector: false,
            embedderChoice: "auto"
        ) == .automatic(.miniLM, .default)
    )
    #expect(
        try HostEmbeddingReadiness.request(
            noEmbedder: false,
            requireVector: false,
            embedderChoice: "minilm"
        ) == .automatic(.miniLM, .default)
    )
    #expect(
        try HostEmbeddingReadiness.request(
            noEmbedder: false,
            requireVector: false,
            embedderChoice: "arctic"
        ) == .automatic(.arctic, .default)
    )
    #expect(
        try HostEmbeddingReadiness.request(
            noEmbedder: false,
            requireVector: true,
            embedderChoice: "arctic"
        ) == .builtIn(.arctic, .default)
    )
}

@Test
func memoryRetrievalModeAliasesModuleScopeRetrievalMode() {
    let nested: Memory.RetrievalMode = .hybrid(alpha: 0.4)
    let root: RetrievalMode = nested
    #expect(root == .hybrid(alpha: 0.4))
    #expect(Memory.RetrievalMode.textOnly == RetrievalMode.textOnly)
    #expect(Memory.RetrievalMode.vectorOnly == RetrievalMode.vectorOnly)
}

private struct RecordingEmbedder: EmbeddingProvider {
    let dimensions = 2
    let normalize = true
    let identity: EmbeddingIdentity?

    init(model: String) {
        identity = EmbeddingIdentity(
            provider: "Test",
            model: model,
            dimensions: 2,
            normalized: true
        )
    }

    func embed(_ text: String) async throws -> [Float] {
        _ = text
        return [1, 0]
    }
}

private enum TestEmbedderError: Error {
    case boom
}

private actor Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        for waiter in waiters {
            waiter.resume()
        }
        waiters.removeAll()
    }
}

private actor Counter {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}
