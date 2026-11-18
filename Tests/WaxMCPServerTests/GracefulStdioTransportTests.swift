#if MCPServer
import Foundation
import Testing
@testable import wax_mcp

#if canImport(System)
import System
#else
@preconcurrency import SystemPackage
#endif

/// Records when the transport's receive stream ends: the server then tears the session down.
private actor StreamEnd {
    private(set) var ended = false
    func markEnded() { ended = true }
}

private func pipeFileDescriptors() throws -> (read: FileDescriptor, write: FileDescriptor) {
    var fds: [Int32] = [0, 0]
    guard pipe(&fds) == 0 else { throw Errno(rawValue: errno) }
    return (FileDescriptor(rawValue: fds[0]), FileDescriptor(rawValue: fds[1]))
}

/// A script writes its requests and closes stdin without waiting. The receive stream (and so
/// the server) must stay up until every request it delivered has been answered, however long
/// the answer takes, and end promptly once it has.
@Test(.timeLimit(.minutes(1)))
func stdioTransportStaysOpenAtEOFUntilEveryRequestIsAnswered() async throws {
    let input = try pipeFileDescriptors()
    let output = try pipeFileDescriptors()
    defer {
        try? input.read.close()
        try? output.read.close()
        try? output.write.close()
    }
    let transport = GracefulStdioTransport(input: input.read, output: output.write)
    try await transport.connect()

    let end = StreamEnd()
    let stream = await transport.receive()
    let consumer = Task {
        var received: [Data] = []
        for try await message in stream { received.append(message) }
        await end.markEnded()
        return received
    }

    let request = #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{}}"#
    let notification = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
    try input.write.writeAll(Array((notification + "\n" + request + "\n").utf8))
    try input.write.close()

    // Well past the old fixed grace period: the request is still unanswered.
    try await Task.sleep(for: .seconds(1))
    #expect(await end.ended == false, "the stream ended with request 7 unanswered")

    try await transport.send(Data(#"{"jsonrpc":"2.0","id":7,"result":{}}"#.utf8))
    let deadline = ContinuousClock.now + .seconds(5)
    while !(await end.ended), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await end.ended, "the stream must end once every request is answered")
    let received = try await consumer.value
    #expect(received.count == 2)
    await transport.disconnect()
}
#endif
