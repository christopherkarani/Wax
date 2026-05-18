import Foundation

package actor EnrichmentPipeline {
    package struct Stats: Sendable, Equatable {
        package var processedCount: UInt64
        package var pendingCount: UInt64
        package var isRunning: Bool

        package init(processedCount: UInt64, pendingCount: UInt64, isRunning: Bool) {
            self.processedCount = processedCount
            self.pendingCount = pendingCount
            self.isRunning = isRunning
        }
    }

    private enum State {
        case idle
        case running
        case stopping
        case stopped
    }

    private var state: State = .idle
    private var continuation: AsyncStream<EnrichmentTask>.Continuation?
    private var processingTask: Task<Void, Never>?
    private var processedCount: UInt64 = 0
    private var pendingCount: UInt64 = 0

    package init() {}

    package func start(
        handler: @escaping @Sendable (EnrichmentTask) async -> EnrichmentResult,
        resultHandler: (@Sendable (EnrichmentResult) async throws -> Void)? = nil
    ) {
        guard state == .idle || state == .stopped else { return }

        let (stream, continuation) = AsyncStream<EnrichmentTask>.makeStream()
        self.continuation = continuation
        state = .running

        processingTask = Task {
            for await task in stream {
                let result = await handler(task)
                if let resultHandler {
                    do {
                        try await resultHandler(result)
                    } catch {
                        WaxDiagnostics.logSwallowed(
                            error,
                            context: "enrichment result persistence",
                            fallback: "continuing enrichment processing without persisted result"
                        )
                    }
                }
                await self.didProcessTask()
            }
            await self.didFinishProcessingLoop()
        }
    }

    package func enqueue(_ task: EnrichmentTask) throws {
        guard state == .running, continuation != nil else {
            throw WaxError.io("enrichment pipeline not running")
        }
        pendingCount &+= 1
        continuation?.yield(task)
    }

    package func waitUntilProcessed(atLeast target: UInt64, timeout: Duration) async throws {
        let deadline = ContinuousClock.now + timeout
        while processedCount < target {
            if ContinuousClock.now >= deadline {
                throw WaxError.io("enrichment timeout waiting for \(target) processed tasks")
            }
            if state == .stopped && pendingCount > 0 {
                throw WaxError.io("enrichment pipeline stopped with pending tasks")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    package func waitUntilIdle() async throws {
        while pendingCount > 0 {
            if state == .stopped {
                throw WaxError.io("enrichment pipeline stopped before queue drain")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    package func waitUntilIdle(bestEffortTimeout timeout: Duration) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while pendingCount > 0 {
            if state == .stopped {
                throw WaxError.io("enrichment pipeline stopped before queue drain")
            }
            if ContinuousClock.now >= deadline {
                return false
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    package func waitUntilIdle(timeout: Duration) async throws {
        let deadline = ContinuousClock.now + timeout
        while pendingCount > 0 {
            if ContinuousClock.now >= deadline {
                throw WaxError.io("enrichment timeout waiting for queue drain")
            }
            if state == .stopped {
                throw WaxError.io("enrichment pipeline stopped before queue drain")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    package func stop(timeout: Duration = .seconds(2)) async throws {
        guard state == .running || state == .stopping else { return }
        state = .stopping
        continuation?.finish()
        continuation = nil

        if let processingTask {
            let completed = await waitForCompletion(of: processingTask, timeout: timeout)
            if !completed {
                processingTask.cancel()
            }
        }
        processingTask = nil
        state = .stopped

        if pendingCount > 0 {
            throw WaxError.io("enrichment pipeline stopped with \(pendingCount) pending task(s)")
        }
    }

    package var stats: Stats {
        Stats(
            processedCount: processedCount,
            pendingCount: pendingCount,
            isRunning: state == .running || state == .stopping
        )
    }

    private func didProcessTask() async {
        processedCount &+= 1
        if pendingCount > 0 {
            pendingCount -= 1
        }
    }

    private func didFinishProcessingLoop() async {
        if state == .running || state == .stopping {
            state = .stopped
        }
    }

    private func waitForCompletion(of task: Task<Void, Never>, timeout: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                _ = await task.result
                return true
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}
