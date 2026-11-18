import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Where a file-backed FTS5 index lives while its store is open:
/// `<temporary directory>/wax-fts5/<pid>-<uuid>/`.
///
/// The engine removes its directory in `deinit`, but a process that exits or is killed first
/// leaves a full copy of the text index behind (57 MB for 100k passages). Each directory names
/// its owner's pid, and the first open in a process removes those whose owner has exited.
/// Only this parent is listed, never the shared temporary directory, which can hold tens of
/// thousands of other entries.
enum FTS5BackingDirectory {
    static let parentName = "wax-fts5"

    private static let sweptParents = SweptParents()

    /// Creates a new directory for this process, first removing orphans under `parent` once
    /// per process.
    static func make(
        under parent: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent(parentName, isDirectory: true)
    ) throws -> URL {
        if sweptParents.claim(parent.standardizedFileURL.path) {
            removeOrphans(in: parent)
        }
        let directory = parent.appendingPathComponent("\(getpid())-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Removes directories under `parent` whose owning process has exited, and returns their
    /// names. Entries that do not start with a pid are left alone.
    @discardableResult
    static func removeOrphans(in parent: URL) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: parent.path) else {
            return []
        }
        let me = getpid()
        var removed: [String] = []
        for name in names.sorted() {
            guard let owner = ownerPID(of: name), owner != me, !isRunning(owner) else { continue }
            let url = parent.appendingPathComponent(name, isDirectory: true)
            if (try? FileManager.default.removeItem(at: url)) != nil {
                removed.append(name)
            }
        }
        return removed
    }

    /// The pid a directory name starts with, as `make` writes it.
    static func ownerPID(of name: String) -> pid_t? {
        guard let dash = name.firstIndex(of: "-"), let pid = pid_t(name[..<dash]), pid > 0 else {
            return nil
        }
        return pid
    }

    /// True unless the pid certainly has no process. A pid reused by an unrelated process
    /// only delays the removal; it never removes a live owner's directory.
    private static func isRunning(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno != ESRCH
    }
}

/// Parent paths already swept in this process.
private final class SweptParents: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: Set<String> = []

    /// True the first time `path` is claimed.
    func claim(_ path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return paths.insert(path).inserted
    }
}
