import Foundation
import Testing
@testable import WaxCore

@Test func blockingIOExecutorRunReturnsValue() async throws {
    let executor = BlockingIOExecutor(label: "test.run")
    let result = try await executor.run { () throws -> Int in 42 }
    #expect(result == 42)
}

@Test func blockingIOExecutorRunNonThrowingReturnsValue() async {
    let executor = BlockingIOExecutor(label: "test.run-nothrow")
    let result = await executor.run { "hello" }
    #expect(result == "hello")
}

@Test func blockingIOExecutorRunThrowingPropagatesError() async {
    let executor = BlockingIOExecutor(label: "test.run-throw")
    do {
        _ = try await executor.run { () throws -> Int in
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
