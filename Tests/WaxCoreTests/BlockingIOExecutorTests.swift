import Foundation
import Testing
@testable import WaxCore

@Test func blockingIOExecutorRunWriteReturnsValue() async throws {
    let executor = BlockingIOExecutor(label: "test.write")
    let result = try await executor.runWrite { 42 }
    #expect(result == 42)
}

@Test func blockingIOExecutorRunWriteNonThrowingReturnsValue() async {
    let executor = BlockingIOExecutor(label: "test.write-nothrow")
    let result = await executor.runWrite { "hello" }
    #expect(result == "hello")
}

@Test func blockingIOExecutorRunWriteThrowingPropagatesError() async {
    let executor = BlockingIOExecutor(label: "test.write-throw")
    do {
        _ = try await executor.runWrite { () -> Int in
            throw WaxError.io("test write error")
        }
        Issue.record("Expected error")
    } catch let error as WaxError {
        guard case .io(let msg) = error else {
            Issue.record("Expected WaxError.io")
            return
        }
        #expect(msg == "test write error")
    } catch {
        Issue.record("Unexpected error type: \(error)")
    }
}

@Test func blockingIOExecutorWriteThenReadSequential() async throws {
    let executor = BlockingIOExecutor(label: "test.barrier")

    // Write produces a value
    let writeResult: Int = try await executor.runWrite { 42 }
    #expect(writeResult == 42)

    // Subsequent read works
    let readResult = try await executor.run { 99 }
    #expect(readResult == 99)
}
