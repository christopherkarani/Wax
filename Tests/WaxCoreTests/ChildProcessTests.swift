#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import WaxCore

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// `ChildProcess` launches, wires stdio, reports status and reaps like
/// Foundation's `Process` (which it is on macOS). On Linux it is a
/// `posix_spawn` launcher; the last tests cover what it does differently.
@Suite struct ChildProcessTests {
    private struct TimedOut: Error, CustomStringConvertible {
        var description: String { "the child was not reaped in time" }
    }

    // Blocking waits run on a GCD thread, not a cooperative one.

    @Test func reportsTheExitCodeAndTheKillingSignal() async throws {
        let (exited, exitReason, killed, killReason) = try await BlockingWork.run {
            () throws -> (Int32, ChildProcess.TerminationReason, Int32, ChildProcess.TerminationReason) in
            let exited = try launch("/bin/sh", ["-c", "exit 3"])
            let killed = try launch("/bin/sh", ["-c", "kill -KILL $$"])
            exited.waitUntilExit()
            killed.waitUntilExit()
            return (exited.terminationStatus, exited.terminationReason, killed.terminationStatus, killed.terminationReason)
        }
        #expect(exited == 3)
        #expect(exitReason == .exit)
        #expect(killed == SIGKILL)
        #expect(killReason == .uncaughtSignal)
    }

    /// Reading to EOF returns only if the parent closed its copy of the
    /// child's end of each pipe.
    @Test func wiresPipesAndClosesTheChildsEndsInTheParent() async throws {
        let (stdout, stderr, status) = try await BlockingWork.run { () throws -> (String, String, Int32) in
            let input = Pipe()
            let output = Pipe()
            let errors = Pipe()
            let process = ChildProcess()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "cat; echo oops >&2"]
            process.standardInput = input
            process.standardOutput = output
            process.standardError = errors
            try process.run()
            input.fileHandleForWriting.write(Data("piped".utf8))
            try input.fileHandleForWriting.close()
            let stdout = output.fileHandleForReading.readDataToEndOfFile()
            let stderr = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (String(decoding: stdout, as: UTF8.self), String(decoding: stderr, as: UTF8.self), process.terminationStatus)
        }
        #expect(stdout == "piped")
        #expect(stderr == "oops\n")
        #expect(status == 0)
    }

    @Test func passesTheEnvironmentAndWorkingDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-child-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = try await BlockingWork.run { () throws -> String in
            let pipe = Pipe()
            let process = ChildProcess()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "echo \"$WAX_CHILD_TEST\"; pwd -P"]
            process.environment = ["WAX_CHILD_TEST": "from-parent", "PATH": "/usr/bin:/bin"]
            process.currentDirectoryURL = directory
            process.standardOutput = pipe
            try process.run()
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: output, as: UTF8.self)
        }
        let lines = output.split(separator: "\n").map(String.init)
        #expect(lines.first == "from-parent")
        #expect(lines.last == directory.resolvingSymlinksInPath().path)
    }

    @Test func runsTheTerminationHandlerOnceTheChildIsReaped() async throws {
        let (calls, wasRunning, status) = try await BlockingWork.run { () throws -> (Int, Bool, Int32) in
            let done = DispatchSemaphore(value: 0)
            let observed = ObservedTermination()
            let process = ChildProcess()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "exit 7"]
            process.terminationHandler = { @Sendable (child: ChildProcess) in
                observed.record(isRunning: child.isRunning, status: child.terminationStatus)
                done.signal()
            }
            try process.run()
            guard done.wait(timeout: .now() + 30) == .success else { throw TimedOut() }
            process.waitUntilExit()
            return observed.snapshot()
        }
        #expect(calls == 1)
        #expect(!wasRunning)
        #expect(status == 7)
    }

    @Test func throwsForAMissingExecutable() {
        let process = ChildProcess()
        process.executableURL = URL(fileURLWithPath: "/nonexistent/wax-child-\(UUID().uuidString)")
        #expect(throws: (any Error).self) { try process.run() }
        #expect(!process.isRunning)
    }

    #if os(Linux)
    /// corelibs maps a nil stream to /dev/null; Darwin's semantics are not asserted here.
    @Test func aNilStreamIsTheNullDevice() async throws {
        let (output, status) = try await BlockingWork.run { () throws -> (String, Int32) in
            let pipe = Pipe()
            let process = ChildProcess()
            process.executableURL = URL(fileURLWithPath: "/bin/cat")
            process.standardInput = nil
            process.standardOutput = pipe
            try process.run()
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (String(decoding: output, as: UTF8.self), process.terminationStatus)
        }
        #expect(output.isEmpty)
        #expect(status == 0)
    }

    /// Foundation's children inherit any descriptor the parent opened without
    /// CLOEXEC after it listed `/proc/self/fd`. These children get stdio only.
    @Test func theChildInheritsOnlyStdio() async throws {
        var leaked: [Int32] = [0, 0]
        #expect(pipe(&leaked) == 0)
        let held = leaked
        defer { held.forEach { close($0) } }
        let listed = try await BlockingWork.run { () throws -> Set<Int32> in
            let output = Pipe()
            let process = ChildProcess()
            process.executableURL = URL(fileURLWithPath: "/bin/ls")
            process.arguments = ["/proc/self/fd"]
            process.standardOutput = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return Set(String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { Int32($0) })
        }
        #expect(listed.isDisjoint(with: held))
        // stdio plus the descriptor ls opened for the listing.
        #expect(listed.count <= 4)
    }

    /// corelibs reaps a child only at EOF on a socket the child inherits, so a
    /// process that inherits it too (a grandchild here, or a sibling spawned on
    /// another thread) kept the child unreaped. This child is reaped by pid.
    @Test func reapsTheChildWhileItsBackgroundChildIsStillRunning() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-child-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let holderFile = directory.appendingPathComponent("holder")
        defer {
            if let text = try? String(contentsOf: holderFile, encoding: .utf8),
               let holder = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                kill(holder, SIGKILL)
            }
            try? FileManager.default.removeItem(at: directory)
        }
        let (status, isRunning) = try await BlockingWork.run { () throws -> (Int32?, Bool) in
            let process = try launch("/bin/sh", ["-c", "sleep 30 & echo $! > '\(holderFile.path)'; exit 4"])
            let status = process.waitForExit(timeout: 20)
            return (status, process.isRunning)
        }
        #expect(status == 4)
        #expect(!isRunning)
    }

    /// corelibs' `Process.run()` crashed a parallel test run (SIGSEGV in
    /// memcpy under `findMaximumOpenFromProcSelfFD`) once the process held
    /// about 1,350 descriptors: it copies each `/proc/self/fd` entry's whole
    /// 256-byte `d_name` and reads past glibc's readdir buffer, which faults
    /// when that buffer ends at the top of a malloc heap. Whether it faults
    /// depends on the heap, so this test cannot make `Process` crash on demand;
    /// it checks that `ChildProcess` spawns, shaped like the CLI test helper
    /// that crashed (merged environment, two pipes, a termination handler,
    /// several at once), keep working while the process holds that many.
    @Test func spawnsConcurrentlyWhileTheProcessHoldsManyDescriptors() async throws {
        let held = holdDescriptors(1_500)
        defer { held.forEach { close($0) } }
        let environment = ProcessInfo.processInfo.environment.merging(["WAX_CHILD_STRESS": "1"]) { $1 }
        let workers = 8
        let spawnsPerWorker = 25
        let statuses = try await withThrowingTaskGroup(of: [Int32].self) { (group: inout ThrowingTaskGroup<[Int32], any Error>) in
            for _ in 0..<workers {
                group.addTask {
                    try await BlockingWork.run { () throws -> [Int32] in
                        var statuses: [Int32] = []
                        for _ in 0..<spawnsPerWorker {
                            statuses.append(try runLikeTheCLIHelper(environment: environment))
                        }
                        return statuses
                    }
                }
            }
            var all: [Int32] = []
            for try await statuses in group { all += statuses }
            return all
        }
        #expect(held.count == 1_500)
        #expect(statuses.count == workers * spawnsPerWorker)
        #expect(statuses.allSatisfy { $0 == 0 })
    }

    private func holdDescriptors(_ count: Int) -> [Int32] {
        var held: [Int32] = []
        for _ in 0..<count {
            let descriptor = open("/dev/null", O_RDONLY | O_CLOEXEC)
            guard descriptor >= 0 else { break }
            held.append(descriptor)
        }
        return held
    }

    private func runLikeTheCLIHelper(environment: [String: String]) throws -> Int32 {
        let process = ChildProcess()
        process.executableURL = URL(fileURLWithPath: "/bin/true")
        process.environment = environment
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { @Sendable (_: ChildProcess) in terminated.signal() }
        try process.run()
        _ = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        _ = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        guard terminated.wait(timeout: .now() + 60) == .success else { throw TimedOut() }
        process.waitUntilExit()
        return process.terminationStatus
    }
    #endif

    /// Every spawn in the package goes through `ChildProcess`, so none reaches
    /// corelibs' `Process.run()` on Linux.
    @Test func noSourceOrTestSpawnsWithFoundationProcess() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let construction = try Regex(#"\bProcess\(\)"#)
        var offenders: [String] = []
        for directory in ["Sources", "Tests"] {
            let root = packageRoot.appendingPathComponent(directory)
            guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
                continue
            }
            for case let file as URL in files where file.pathExtension == "swift" {
                let source = try String(contentsOf: file, encoding: .utf8)
                for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
                    where line.contains(construction) {
                    offenders.append("\(directory)/\(file.lastPathComponent):\(index + 1)")
                }
            }
        }
        #expect(offenders.isEmpty, "spawn with ChildProcess, not Process: \(offenders)")
    }

    private func launch(_ path: String, _ arguments: [String]) throws -> ChildProcess {
        let process = ChildProcess()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }
}

private final class ObservedTermination: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var wasRunning = true
    private var status: Int32 = -1

    func record(isRunning: Bool, status: Int32) {
        lock.withLock {
            calls += 1
            wasRunning = isRunning
            self.status = status
        }
    }

    func snapshot() -> (Int, Bool, Int32) {
        lock.withLock { (calls, wasRunning, status) }
    }
}
#endif
