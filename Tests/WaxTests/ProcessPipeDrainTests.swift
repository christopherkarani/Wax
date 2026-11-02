#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import Wax

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
    process.waitUntilExit()

    #expect(process.terminationStatus == 0)
    #expect(captured.stdout.count == 200_000)
    #expect(captured.stderr.count == 200_000)
    #expect(captured.stdout.allSatisfy { $0 == UInt8(ascii: "o") })
    #expect(captured.stderr.allSatisfy { $0 == UInt8(ascii: "e") })
}
#endif
