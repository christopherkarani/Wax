#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import Wax
import WaxCore

/// Writes 200 KB to stdout and then 200 KB to stderr. Either stream left
/// unread past ~64 KB blocks the child.
private let bothStreamsScript = """
head -c 200000 /dev/zero | tr '\\000' o
head -c 200000 /dev/zero | tr '\\000' e 1>&2
"""

@Test(.timeLimit(.minutes(1)))
func processPipeDrainCollectsLargeOutputOnBothStreams() throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", bothStreamsScript]
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    try process.run()
    let captured = ProcessPipeDrain(stdout: stdout, stderr: stderr).wait()
    process.waitForExit(timeout: 60)

    #expect(process.terminationStatus == 0)
    #expect(captured.stdout.count == 200_000)
    #expect(captured.stderr.count == 200_000)
    #expect(captured.stdout.allSatisfy { $0 == UInt8(ascii: "o") })
    #expect(captured.stderr.allSatisfy { $0 == UInt8(ascii: "e") })
}

@Test(.timeLimit(.minutes(1)))
func processPipeDrainStopsAtDeadlineWhileAWriterHoldsThePipe() throws {
    let stdout = Pipe()
    let stderr = Pipe()
    let drain = ProcessPipeDrain(stdout: stdout, stderr: stderr)
    stdout.fileHandleForWriting.write(Data("partial".utf8))

    let started = Date()
    // Neither write end is closed, so EOF never arrives.
    let captured = drain.wait(until: .now() + 0.3)
    #expect(Date().timeIntervalSince(started) < 5)
    #expect(captured.stdout == Data("partial".utf8))
    withExtendedLifetime((stdout, stderr)) {}
}

@Test(.timeLimit(.minutes(1)))
func processPipeDrainKeepsReadingPastItsCap() throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", bothStreamsScript]
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    try process.run()
    let captured = ProcessPipeDrain(stdout: stdout, stderr: stderr, maxBytesPerStream: 1_000).wait()
    process.waitForExit(timeout: 60)

    #expect(process.terminationStatus == 0)
    #expect(captured.stdout.count == 1_000)
    #expect(captured.stderr.count == 1_000)
    #expect(captured.stdoutTruncated)
    #expect(captured.stderrTruncated)
}
#endif
