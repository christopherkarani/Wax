import Foundation

/// Finds a tool on `PATH` in-process, as `which` would, without spawning
/// `which`: minimal Linux images (Arch base, distroless, slim containers)
/// often do not ship it.
package enum ExecutableLookup {
    /// The first regular, executable file named `name` in `environment["PATH"]`,
    /// or nil. A `name` containing a slash is checked as given. Empty and
    /// relative `PATH` entries are skipped: they resolve against the working
    /// directory, where a checkout could shadow a real tool.
    package static func find(_ name: String, environment: [String: String]) -> String? {
        guard !name.isEmpty else { return nil }
        if name.contains("/") {
            return isExecutableRegularFile(name) ? name : nil
        }
        guard let path = environment["PATH"] else { return nil }
        for entry in path.split(separator: ":", omittingEmptySubsequences: true) where entry.hasPrefix("/") {
            let candidate = URL(fileURLWithPath: String(entry), isDirectory: true)
                .appendingPathComponent(name)
                .path
            if isExecutableRegularFile(candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func isExecutableRegularFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return false
        }
        return FileManager.default.isExecutableFile(atPath: path)
    }
}
