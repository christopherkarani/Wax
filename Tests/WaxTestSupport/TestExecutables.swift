import Foundation

/// Locates command-line tools for tests without assuming one distribution's layout
/// (`python3` lives in /usr/local/bin on some images; usr-merged and split /bin
/// layouts put `true` in different places).
package enum TestExecutables {
    /// The first executable named `name` on `PATH`, then in the usual system directories.
    package static func path(
        _ name: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let pathDirectories = (environment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
        let fallbacks = ["/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        for directory in pathDirectories + fallbacks {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
