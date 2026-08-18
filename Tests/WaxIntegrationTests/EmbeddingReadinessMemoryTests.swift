import Foundation
import Testing
@testable import Wax

@Test
func memoryCustomEmbeddingIsActiveImmediately() async throws {
    try await TempFiles.withTempFile { url in
        let provider = DeterministicTextEmbedder()
        let memory = try await Memory(
            at: url,
            config: .init(embedding: .custom(provider))
        )
        let stats = await memory.stats()
        #expect(stats.embeddingStatus == .active(provider.identity))
        #expect(stats.queryEmbedderConfigured)
        #expect(stats.embedderIdentity?.model == "DeterministicText")
        try await memory.close()
    }
}

@Test
func memoryDisabledVectorSearchReportsDisabledStatus() async throws {
    try await TempFiles.withTempFile { url in
        let memory = try await Memory(
            at: url,
            config: .init(enableVectorSearch: false, requireOnDeviceProviders: false)
        )
        let stats = await memory.stats()
        #expect(stats.embeddingStatus == .disabled)
        #expect(!stats.queryEmbedderConfigured)
        #expect(!stats.vectorSearchEnabled)
        try await memory.close()
    }
}

@Test
func memoryAutomaticOpensWhileLoadingThenLiveAttaches() async throws {
    try await TempFiles.withTempFile { url in
        let gate = Gate()
        let readiness = EmbeddingReadiness()
        let memory = try await Memory(
            at: url,
            config: .init(requireOnDeviceProviders: false, embedding: .automatic),
            readiness: readiness
        ) {
            await gate.wait()
            return DeterministicTextEmbedder()
        }

        let loading = await memory.stats()
        #expect(loading.embeddingStatus == .loading)
        #expect(!loading.queryEmbedderConfigured)
        #expect(loading.vectorSearchEnabled)

        await gate.open()
        try await waitForEmbeddingReady(memory)

        try await memory.save("live attach should embed this needle")
        try await memory.flush()
        let results = try await memory.search(
            "needle",
            options: .init(topK: 1, mode: .vectorOnly)
        )
        #expect(results.items.first?.text.contains("needle") == true)
        #expect(results.diagnostics?.queryEmbeddingState == .available)

        try await memory.close()
    }
}

@Test
func memoryBuiltInTimeoutThrowsPublicTimedOutError() async {
    await #expect(throws: BuiltInEmbeddingProviderError.timedOut(.miniLM)) {
        try await TempFiles.withTempFile { url in
            let gate = Gate()
            let readiness = EmbeddingReadiness()
            defer { Task { await gate.open() } }
            _ = try await Memory(
                at: url,
                config: .init(
                    requireOnDeviceProviders: false,
                    embedding: .builtIn(
                        .miniLM,
                        BuiltInEmbeddingProviderOptions(timeoutSeconds: 0.04)
                    )
                ),
                readiness: readiness
            ) {
                await gate.wait()
                return DeterministicTextEmbedder()
            }
        }
    }
}

@Test
func memoryBuiltInThrowsWhenLoadFails() async {
    await #expect(throws: TestReadinessError.boom) {
        try await TempFiles.withTempFile { url in
            let readiness = EmbeddingReadiness()
            _ = try await Memory(
                at: url,
                config: .init(requireOnDeviceProviders: false, embedding: .builtIn(.miniLM)),
                readiness: readiness
            ) {
                throw TestReadinessError.boom
            }
        }
    }
}

@Test
func memoryUnavailableKeepsIndexAndThrowsVectorOnly() async throws {
    try await TempFiles.withTempFile { url in
        let provider = DeterministicTextEmbedder()
        do {
            let seeded = try await Memory(
                at: url,
                config: .init(requireOnDeviceProviders: false, embedding: .custom(provider))
            )
            try await seeded.save("index remains when the next process has no provider")
            try await seeded.flush()
            try await seeded.close()
        }

        let readiness = EmbeddingReadiness()
        let memory = try await Memory(
            at: url,
            config: .init(requireOnDeviceProviders: false, embedding: .automatic),
            readiness: readiness
        ) {
            throw TestReadinessError.boom
        }
        try await waitForEmbeddingUnavailable(memory)

        let stats = await memory.stats()
        #expect(stats.vectorSearchEnabled)
        #expect(!stats.queryEmbedderConfigured)
        guard case .unavailable = stats.embeddingStatus else {
            Issue.record("expected unavailable, got \(stats.embeddingStatus)")
            return
        }

        let hybrid = try await memory.search("index remains", options: .init(mode: .hybrid()))
        #expect(hybrid.diagnostics?.effectiveMode == "text")
        #expect(hybrid.diagnostics?.queryEmbeddingState == .noEmbedder)

        await #expect(throws: WaxError.self) {
            _ = try await memory.search("index remains", options: .init(mode: .vectorOnly))
        }

        try await memory.close()
    }
}

@Test
func memorySaveDuringLoadingBecomesDegradedAfterAttach() async throws {
    try await TempFiles.withTempFile { url in
        let gate = Gate()
        let readiness = EmbeddingReadiness()
        let memory = try await Memory(
            at: url,
            config: .init(requireOnDeviceProviders: false, embedding: .automatic),
            readiness: readiness
        ) {
            await gate.wait()
            return DeterministicTextEmbedder()
        }

        try await memory.save("saved before the provider attached")
        await gate.open()
        try await waitForEmbeddingReady(memory, allowDegraded: true)

        let stats = await memory.stats()
        guard case .degraded = stats.embeddingStatus else {
            Issue.record("expected degraded, got \(stats.embeddingStatus)")
            return
        }
        #expect(stats.queryEmbedderConfigured)

        try await memory.close()
    }
}

@Test
func memoryReopenWithIndexAndTextOnlyFramesIsDegraded() async throws {
    try await TempFiles.withTempFile { url in
        let provider = DeterministicTextEmbedder()
        do {
            let seeded = try await Memory(
                at: url,
                config: .init(requireOnDeviceProviders: false, embedding: .custom(provider))
            )
            try await seeded.save("embedded first")
            try await seeded.flush()
            try await seeded.close()
        }

        let gate = Gate()
        let readiness = EmbeddingReadiness()
        do {
            let loading = try await Memory(
                at: url,
                config: .init(requireOnDeviceProviders: false, embedding: .automatic),
                readiness: readiness
            ) {
                await gate.wait()
                return DeterministicTextEmbedder()
            }
            try await loading.save("text only after the index already existed")
            try await loading.flush()
            try await loading.close()
            await gate.open()
        }

        let reopened = try await Memory(
            at: url,
            config: .init(requireOnDeviceProviders: false, embedding: .custom(provider))
        )
        let stats = await reopened.stats()
        guard case .degraded = stats.embeddingStatus else {
            Issue.record("expected degraded on reopen, got \(stats.embeddingStatus)")
            try await reopened.close()
            return
        }
        #expect(stats.queryEmbedderConfigured)
        try await reopened.close()
    }
}

@Test
func memoryAutomaticWaitTimeoutThenLiveAttaches() async throws {
    try await TempFiles.withTempFile { url in
        let gate = Gate()
        let readiness = EmbeddingReadiness()
        var config = OrchestratorConfig.default
        config.requireOnDeviceProviders = false
        let options = BuiltInEmbeddingProviderOptions(timeoutSeconds: 0.04)
        let orchestrator = try await EmbeddingReadinessBinding.openOrchestrator(
            at: url,
            config: config,
            request: .automatic(.miniLM, options),
            readiness: readiness
        ) {
            await gate.wait()
            return DeterministicTextEmbedder()
        }

        let deadline = ContinuousClock.now + .seconds(1)
        var sawUnavailable = false
        while ContinuousClock.now < deadline {
            if case .unavailable = await orchestrator.runtimeStats().embeddingStatus {
                sawUnavailable = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(sawUnavailable)

        await gate.open()
        let attachDeadline = ContinuousClock.now + .seconds(1)
        while ContinuousClock.now < attachDeadline {
            switch await orchestrator.runtimeStats().embeddingStatus {
            case .active, .degraded:
                try await orchestrator.close()
                return
            default:
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        Issue.record("expected live-attach after automatic wait timeout")
        try await orchestrator.close()
    }
}

@Test
func memoryAutomaticAllowsMultiChunkSaveWhileLoading() async throws {
    try await TempFiles.withTempFile { url in
        let gate = Gate()
        let readiness = EmbeddingReadiness()
        var config = OrchestratorConfig.default
        config.chunking = .tokenCount(targetTokens: 8, overlapTokens: 0)
        config.requireOnDeviceProviders = false
        let orchestrator = try await EmbeddingReadinessBinding.openOrchestrator(
            at: url,
            config: config,
            request: .automatic(.miniLM, .default),
            readiness: readiness
        ) {
            await gate.wait()
            return DeterministicTextEmbedder()
        }

        let longText = Array(
            repeating: "Swift concurrency uses actors and structured tasks.",
            count: 20
        ).joined(separator: " ")
        try await orchestrator.remember(longText)
        try await orchestrator.flush()

        let mid = await orchestrator.runtimeStats()
        #expect(mid.embeddingStatus == .loading)
        #expect(mid.frameCount > 2)

        await gate.open()
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if case .degraded = await orchestrator.runtimeStats().embeddingStatus {
                try await orchestrator.close()
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("expected degraded after multi-chunk save during loading")
        try await orchestrator.close()
    }
}

@Test
func memorySearchKeepsLoadingSnapshotForTheWholeCall() async throws {
    try await TempFiles.withTempFile { url in
        let gate = Gate()
        let readiness = EmbeddingReadiness()
        let memory = try await Memory(
            at: url,
            config: .init(requireOnDeviceProviders: false, embedding: .automatic),
            readiness: readiness
        ) {
            await gate.wait()
            return DeterministicTextEmbedder()
        }
        try await memory.save("snapshot query should stay text for this call")
        await memory.setSearchSnapshotHoldForTesting(.milliseconds(150))

        async let search = memory.search("snapshot", options: .init(mode: .hybrid()))
        await gate.open()
        let results = try await search
        #expect(results.diagnostics?.effectiveMode == "text")
        #expect(results.diagnostics?.queryEmbeddingState == .noEmbedder)

        try await waitForEmbeddingReady(memory, allowDegraded: true)
        await memory.setSearchSnapshotHoldForTesting(nil)
        let later = try await memory.search("snapshot", options: .init(mode: .hybrid()))
        #expect(later.diagnostics?.queryEmbeddingState == .available)

        try await memory.close()
    }
}

private enum TestReadinessError: Error {
    case boom
}

private func waitForEmbeddingReady(
    _ memory: Memory,
    allowDegraded: Bool = false,
    timeout: Duration = .seconds(2)
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        let stats = await memory.stats()
        switch stats.embeddingStatus {
        case .active:
            return
        case .degraded where allowDegraded:
            return
        case .unavailable(let reason):
            throw TestWaitError.unavailable(reason)
        default:
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    throw TestWaitError.timedOut
}

private func waitForEmbeddingUnavailable(
    _ memory: Memory,
    timeout: Duration = .seconds(2)
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if case .unavailable = await memory.stats().embeddingStatus {
            return
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw TestWaitError.timedOut
}

private enum TestWaitError: Error {
    case timedOut
    case unavailable(String)
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
