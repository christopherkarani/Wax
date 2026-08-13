import Foundation
import Testing
@testable import WaxCore

@Test
func asyncTimeoutPropagatesCallerCancellationImmediately() async throws {
    let started = ContinuousClock.now
    let task = Task {
        try await AsyncTimeout.run(timeout: .seconds(30), operation: "cancel probe") {
            try await Task.sleep(for: .seconds(30))
            return 1
        }
    }
    try await Task.sleep(for: .milliseconds(25))
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(ContinuousClock.now - started < .seconds(5))
}

@Test
func asyncTimeoutReturnsPromptlyWhenCallerCancelsUncancellableOperation() async throws {
    let started = ContinuousClock.now
    let finished = OffPathCompletion()
    let task = Task {
        try await AsyncTimeout.run(timeout: .seconds(30), operation: "uncancellable probe") {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                Task.detached {
                    try? await Task.sleep(for: .milliseconds(250))
                    continuation.resume()
                    await finished.mark()
                }
            }
            return 1
        }
    }
    try await Task.sleep(for: .milliseconds(25))
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(ContinuousClock.now - started < .seconds(5))

    for _ in 0..<40 {
        if await finished.isComplete { break }
        try await Task.sleep(for: .milliseconds(25))
    }
    #expect(await finished.isComplete)
}

private actor OffPathCompletion {
    private(set) var isComplete = false
    func mark() { isComplete = true }
}
