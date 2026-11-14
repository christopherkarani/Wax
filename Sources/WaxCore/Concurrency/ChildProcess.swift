#if os(macOS)
import Foundation

/// A child process. On macOS this is Foundation's `Process`; on Linux it is a
/// `posix_spawn` launcher with the same surface. See the Linux declaration.
package typealias ChildProcess = Process

#elseif os(Linux)
import Foundation
import Glibc

/// A child process launched with `posix_spawn`, with the parts of Foundation's
/// `Process` that Wax uses. Spawn children with this type on Linux, never with
/// `Process.run()`.
///
/// swift-corelibs-foundation's `Process.run()` (Swift 6.2 and 6.3) has two
/// defects this type avoids:
///
/// - It emulates `POSIX_SPAWN_CLOEXEC_DEFAULT` by listing `/proc/self/fd`, and
///   copies each entry's 256-byte `d_name` out of glibc's 32 KiB readdir
///   buffer. A record is only `d_reclen` bytes long, so once the process holds
///   about 1,350 descriptors the copy reads past the buffer, and it crashes
///   with SIGSEGV when that buffer ends at the top of a malloc heap. Fixed
///   upstream after 6.3. Here the child closes every descriptor above stderr
///   itself (`posix_spawn_file_actions_addclosefrom_np`).
/// - It learns that a child exited only at EOF on a socket the child inherits
///   without `CLOEXEC`, and reaps it then. A grandchild, or a sibling spawned
///   on another thread at the same moment, can inherit that socket too, and
///   then the child stays unreaped and `isRunning` stays true until that other
///   process exits. Here a thread per child waits for the pid itself.
///
/// Behaviour otherwise follows corelibs: the child gets its own process group,
/// inherits the calling thread's signal mask, inherits stdio unless a stream is
/// set, and gets `/dev/null` for a stream set to nil or `FileHandle.nullDevice`.
/// After launch the parent closes its copy of the child's end of each `Pipe`.
package final class ChildProcess: @unchecked Sendable {
    package typealias TerminationReason = Process.TerminationReason

    /// How long a killed child gets to be reaped before `waitForExit` gives up.
    package static let exitWaitKillReapSeconds: TimeInterval = Process.exitWaitKillReapSeconds

    // Configuration: set before `run()`, as with `Process`.
    package var executableURL: URL?
    package var arguments: [String]?
    package var environment: [String: String]?
    package var currentDirectoryURL: URL?
    package var standardInput: Any? = FileHandle.standardInput
    package var standardOutput: Any? = FileHandle.standardOutput
    package var standardError: Any? = FileHandle.standardError

    // Guarded by `condition`.
    private let condition = NSCondition()
    private var pid: pid_t = 0
    private var reaped = false
    private var status: Int32 = 0
    private var reason: TerminationReason = .exit
    private var handler: (@Sendable (ChildProcess) -> Void)?

    package init() {}

    /// Called once, on a background thread, after the child has been reaped.
    /// Set it before `run()`.
    package var terminationHandler: (@Sendable (ChildProcess) -> Void)? {
        get { condition.withLock { handler } }
        set { condition.withLock { handler = newValue } }
    }

    package var processIdentifier: Int32 { condition.withLock { pid } }

    /// True from a successful `run()` until the child has been reaped.
    package var isRunning: Bool { condition.withLock { pid > 0 && !reaped } }

    /// The exit code, or the signal number for a child killed by a signal.
    /// Traps while the child runs, like `Process`.
    package var terminationStatus: Int32 {
        condition.withLock {
            precondition(pid > 0, "task not launched")
            precondition(reaped, "task still running")
            return status
        }
    }

    package var terminationReason: TerminationReason {
        condition.withLock {
            precondition(pid > 0, "task not launched")
            precondition(reaped, "task still running")
            return reason
        }
    }

    package func run() throws {
        guard let executableURL else {
            throw CocoaError(.fileNoSuchFile)
        }
        let path = executableURL.path
        try Self.checkExecutable(path)
        precondition(condition.withLock { pid == 0 }, "task already launched")

        let fileActions = UnsafeMutablePointer<posix_spawn_file_actions_t>.allocate(capacity: 1)
        try Self.check(posix_spawn_file_actions_init(fileActions), path: path)
        defer {
            posix_spawn_file_actions_destroy(fileActions)
            fileActions.deallocate()
        }
        var closeInParent: [FileHandle] = []
        for (stream, target) in [(standardInput, STDIN_FILENO), (standardOutput, STDOUT_FILENO), (standardError, STDERR_FILENO)] {
            if let handle = try Self.addStdio(stream, target: target, to: fileActions, path: path) {
                if !closeInParent.contains(where: { $0 === handle }) { closeInParent.append(handle) }
            }
        }
        try Self.addCloseAllAboveStderr(to: fileActions, path: path)
        if let directory = currentDirectoryURL?.path {
            guard let addChdir = Self.addChdir else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSYS), userInfo: [
                    NSLocalizedDescriptionKey: "posix_spawn_file_actions_addchdir_np is unavailable (glibc 2.29+ needed)",
                ])
            }
            try Self.check(addChdir(fileActions, directory), path: directory)
        }

        let attributes = UnsafeMutablePointer<posix_spawnattr_t>.allocate(capacity: 1)
        try Self.check(posix_spawnattr_init(attributes), path: path)
        defer {
            posix_spawnattr_destroy(attributes)
            attributes.deallocate()
        }
        try Self.check(posix_spawnattr_setflags(attributes, Int16(POSIX_SPAWN_SETPGROUP)), path: path)
        try Self.check(posix_spawnattr_setpgroup(attributes, 0), path: path)

        let argv = Self.cStrings([path] + (arguments ?? []))
        let environmentPairs = (environment ?? ProcessInfo.processInfo.environment).map { "\($0.key)=\($0.value)" }
        let envp = Self.cStrings(environmentPairs)
        defer {
            Self.free(argv)
            Self.free(envp)
        }

        var child: pid_t = 0
        try Self.check(posix_spawn(&child, path, fileActions, attributes, argv, envp), path: path)
        for handle in closeInParent {
            try? handle.close()
        }
        let launched = child
        condition.withLock { pid = launched }

        let reaper = Thread { [self] in self.reap(launched) }
        reaper.name = "wax.child-process-reaper"
        reaper.start()
    }

    package func terminate() {
        signal(SIGTERM)
    }

    package func interrupt() {
        signal(SIGINT)
    }

    /// Blocks until the child has been reaped. No run loop is involved.
    package func waitUntilExit() {
        condition.withLock {
            while !reaped { condition.wait() }
        }
    }

    /// Blocks until the child exits or `timeout` passes; at the deadline it
    /// kills the child with SIGKILL and waits up to `exitWaitKillReapSeconds`
    /// for the reap. Pass `.infinity` to wait as long as the child runs.
    ///
    /// - Returns: The termination status, or nil when the child was still
    ///   running at the deadline and was killed.
    @discardableResult
    package func waitForExit(timeout: TimeInterval) -> Int32? {
        // corelibs' NSCondition.wait(until: .distantFuture) traps converting
        // the date, so an unbounded wait uses wait().
        let deadline = timeout.isFinite ? Date().addingTimeInterval(timeout) : nil
        return condition.withLock {
            precondition(pid > 0, "task not launched")
            while !reaped {
                guard let deadline else {
                    condition.wait()
                    continue
                }
                if !condition.wait(until: deadline) { break }
            }
            if reaped { return status }
            // Still unreaped, so the pid is still this child's.
            kill(pid, SIGKILL)
            let reapDeadline = Date().addingTimeInterval(Self.exitWaitKillReapSeconds)
            while !reaped {
                if !condition.wait(until: reapDeadline) { break }
            }
            return nil
        }
    }

    /// The child's exit status once it has exited, nil while it runs. Matches
    /// `Process.unreapedExitStatus()`, except that it keeps answering after
    /// the reap.
    package func unreapedExitStatus() -> Int32? {
        condition.withLock {
            guard pid > 0 else { return nil }
            if reaped { return status }
            // The reaper takes this lock to reap, so `pid` is still the child.
            var info = siginfo_t()
            while waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) != 0 {
                guard errno == EINTR else { return nil }
            }
            guard info._sifields._sigchld.si_pid == pid else { return nil }
            return info._sifields._sigchld.si_status
        }
    }

    // MARK: - Private

    /// Sends `signal` while the child is unreaped; its pid cannot be reused
    /// until the reaper, which needs this lock, has reaped it.
    private func signal(_ signal: Int32) {
        condition.withLock {
            precondition(pid > 0, "task not launched")
            if !reaped { kill(pid, signal) }
        }
    }

    /// Waits for the child to exit without reaping it, then reaps it under the
    /// lock and runs the termination handler.
    private func reap(_ child: pid_t) {
        var info = siginfo_t()
        var observed = false
        while true {
            if waitid(P_PID, id_t(child), &info, WEXITED | WNOWAIT) == 0 {
                observed = info._sifields._sigchld.si_pid == child
                break
            }
            if errno != EINTR { break }
        }
        let handler: (@Sendable (ChildProcess) -> Void)? = condition.withLock {
            var raw: Int32 = 0
            var reapedHere = false
            while true {
                let result = waitpid(child, &raw, 0)
                if result == child { reapedHere = true; break }
                if result == -1, errno == EINTR { continue }
                break
            }
            if reapedHere {
                // Linux wait status: low 7 bits hold the signal, 0 for a normal exit.
                let signal = raw & 0x7F
                if signal == 0 {
                    status = (raw >> 8) & 0xFF
                    reason = .exit
                } else {
                    status = signal
                    reason = .uncaughtSignal
                }
            } else if observed {
                // Someone else reaped it; fall back to what waitid saw.
                status = info._sifields._sigchld.si_status
                reason = info.si_code == Int32(CLD_EXITED) ? .exit : .uncaughtSignal
            }
            reaped = true
            condition.broadcast()
            return self.handler
        }
        handler?(self)
    }

    private static func checkExecutable(_ path: String) throws {
        var info = stat()
        guard stat(path, &info) == 0 else {
            throw posixError(errno, path: path)
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: path])
        }
        guard access(path, X_OK) == 0 else {
            throw posixError(errno, path: path)
        }
    }

    /// Adds the action for one standard stream and returns the parent's copy
    /// of the child's end of a pipe, which the parent closes after launch.
    private static func addStdio(
        _ stream: Any?,
        target: Int32,
        to fileActions: UnsafeMutablePointer<posix_spawn_file_actions_t>,
        path: String
    ) throws -> FileHandle? {
        switch stream {
        case let pipe as Pipe:
            let childEnd = target == STDIN_FILENO ? pipe.fileHandleForReading : pipe.fileHandleForWriting
            try check(posix_spawn_file_actions_adddup2(fileActions, childEnd.fileDescriptor, target), path: path)
            return childEnd
        case let handle as FileHandle where handle === FileHandle.nullDevice:
            try addDevNull(target: target, to: fileActions, path: path)
        case let handle as FileHandle:
            // dup2 onto itself would leave the descriptor as it is: inherited.
            if handle.fileDescriptor != target {
                try check(posix_spawn_file_actions_adddup2(fileActions, handle.fileDescriptor, target), path: path)
            }
        case .none:
            try addDevNull(target: target, to: fileActions, path: path)
        default:
            break
        }
        return nil
    }

    private static func addDevNull(
        target: Int32,
        to fileActions: UnsafeMutablePointer<posix_spawn_file_actions_t>,
        path: String
    ) throws {
        let flags = target == STDIN_FILENO ? O_RDONLY : O_WRONLY
        try check(posix_spawn_file_actions_addopen(fileActions, target, "/dev/null", flags, 0), path: path)
    }

    /// The child closes every descriptor above stderr, after the stdio dup2s.
    private static func addCloseAllAboveStderr(
        to fileActions: UnsafeMutablePointer<posix_spawn_file_actions_t>,
        path: String
    ) throws {
        if let addCloseFrom {
            try check(addCloseFrom(fileActions, STDERR_FILENO + 1), path: path)
            return
        }
        // glibc before 2.34: list the open descriptors. A descriptor another
        // thread opens without CLOEXEC before the spawn can still leak.
        for descriptor in openDescriptorsAboveStderr() {
            try check(posix_spawn_file_actions_addclose(fileActions, descriptor), path: path)
        }
    }

    /// Reads names in place: copying `dirent.d_name` whole reads past the
    /// record, which is the corelibs crash this type exists to avoid.
    private static func openDescriptorsAboveStderr() -> [Int32] {
        guard let directory = opendir("/proc/self/fd") else { return [] }
        let listingDescriptor = dirfd(directory)
        let nameOffset = MemoryLayout<dirent>.offset(of: \dirent.d_name)!
        var descriptors: [Int32] = []
        while let entry = readdir(directory) {
            let name = String(cString: (UnsafeRawPointer(entry) + nameOffset).assumingMemoryBound(to: CChar.self))
            if let descriptor = Int32(name), descriptor > STDERR_FILENO, descriptor != listingDescriptor {
                descriptors.append(descriptor)
            }
        }
        closedir(directory)
        return descriptors
    }

    private typealias AddCloseFrom = @convention(c) (UnsafeMutablePointer<posix_spawn_file_actions_t>?, Int32) -> Int32
    private typealias AddChdir = @convention(c) (UnsafeMutablePointer<posix_spawn_file_actions_t>?, UnsafePointer<CChar>?) -> Int32

    /// Looked up at run time so the binary still loads on an older glibc.
    private static let addCloseFrom: AddCloseFrom? = dlsym(nil, "posix_spawn_file_actions_addclosefrom_np")
        .map { unsafeBitCast($0, to: AddCloseFrom.self) }
    private static let addChdir: AddChdir? = dlsym(nil, "posix_spawn_file_actions_addchdir_np")
        .map { unsafeBitCast($0, to: AddChdir.self) }

    private static func cStrings(_ strings: [String]) -> UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> {
        let buffer = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: strings.count + 1)
        for (index, string) in strings.enumerated() {
            buffer[index] = strdup(string)
        }
        buffer[strings.count] = nil
        return buffer
    }

    private static func free(_ buffer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) {
        var cursor = buffer
        while let string = cursor.pointee {
            Glibc.free(string)
            cursor += 1
        }
        buffer.deallocate()
    }

    private static func check(_ result: Int32, path: String) throws {
        if result != 0 { throw posixError(result, path: path) }
    }

    private static func posixError(_ code: Int32, path: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
            NSFilePathErrorKey: path,
            NSLocalizedDescriptionKey: "\(path): \(String(cString: strerror(code)))",
        ])
    }
}
#endif
