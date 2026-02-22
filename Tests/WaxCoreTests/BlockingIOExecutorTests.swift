import Dispatch
import Foundation
import Testing
@testable import WaxCore

private struct BlockingIOTestError: Error, Equatable {}

private func waitResult(
    _ semaphore: DispatchSemaphore,
    timeoutSeconds: Double
) -> DispatchTimeoutResult {
    semaphore.wait(timeout: .now() + timeoutSeconds)
}

@Test
func blockingIOExecutorReadAndAliasPathsReturnValues() async throws {
    let executor = BlockingIOExecutor(label: "wax.tests.blocking-io.read")

    let throwingRead = try await executor.runRead { () throws -> Int in 41 }
    let nonThrowingRead = await executor.runRead { 42 }
    let throwingAlias = try await executor.run { () throws -> Int in 43 }
    let nonThrowingAlias = await executor.run { 44 }

    #expect(throwingRead == 41)
    #expect(nonThrowingRead == 42)
    #expect(throwingAlias == 43)
    #expect(nonThrowingAlias == 44)
}

@Test
func blockingIOExecutorPropagatesThrowingReadAndWriteErrors() async {
    let executor = BlockingIOExecutor(label: "wax.tests.blocking-io.errors")

    await #expect(throws: BlockingIOTestError.self) {
        try await executor.runRead {
            throw BlockingIOTestError()
        }
    }

    await #expect(throws: BlockingIOTestError.self) {
        try await executor.runWrite {
            throw BlockingIOTestError()
        }
    }
}

@Test
func blockingIOExecutorWriteBarrierBlocksQueuedReadUntilWriteCompletes() async throws {
    let executor = BlockingIOExecutor(label: "wax.tests.blocking-io.barrier")
    let firstReadStarted = DispatchSemaphore(value: 0)
    let allowFirstReadToFinish = DispatchSemaphore(value: 0)
    let writeStarted = DispatchSemaphore(value: 0)
    let allowWriteToFinish = DispatchSemaphore(value: 0)
    let secondReadStarted = DispatchSemaphore(value: 0)

    let firstReadTask = Task {
        await executor.runRead {
            firstReadStarted.signal()
            _ = allowFirstReadToFinish.wait(timeout: .now() + 10)
            return 1
        }
    }
    #expect(waitResult(firstReadStarted, timeoutSeconds: 10) == .success)

    let writeTask = Task {
        await executor.runWrite {
            writeStarted.signal()
            _ = allowWriteToFinish.wait(timeout: .now() + 10)
            return 2
        }
    }

    let secondReadTask = Task {
        await executor.runRead {
            secondReadStarted.signal()
            return 3
        }
    }

    // The barrier write cannot start while the first read is still running.
    #expect(waitResult(writeStarted, timeoutSeconds: 1) == .timedOut)
    allowFirstReadToFinish.signal()
    #expect(waitResult(writeStarted, timeoutSeconds: 10) == .success)

    // The second read is queued behind the barrier and must not run yet.
    #expect(waitResult(secondReadStarted, timeoutSeconds: 1) == .timedOut)

    allowWriteToFinish.signal()
    let firstReadValue = await firstReadTask.value
    let writeValue = await writeTask.value
    let secondReadValue = await secondReadTask.value

    #expect(firstReadValue == 1)
    #expect(writeValue == 2)
    #expect(secondReadValue == 3)
}

@Test
func blockingIOExecutorNonThrowingWriteReturnsValue() async {
    let executor = BlockingIOExecutor(label: "wax.tests.blocking-io.write")
    let value = await executor.runWrite { 99 }
    #expect(value == 99)
}
