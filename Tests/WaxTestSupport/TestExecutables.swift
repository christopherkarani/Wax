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

    /// The directories that hold the running test binary, and so the products
    /// the same `swift build`/`swift test` built beside it.
    ///
    /// On Apple platforms these are the directories of the loaded `.xctest`
    /// bundles. On Linux the test bundle is the running executable, named by
    /// `/proc/self/exe`. `Bundle.allBundles` and `Bundle(for:)` are not used
    /// there: swift-corelibs-foundation can crash enumerating bundles
    /// (`CFBundleGetAllBundles`), as it does when a single test runs alone.
    package static func builtProductDirectories() -> [URL] {
        #if canImport(Darwin)
        return Bundle.allBundles
            .filter { (bundle: Bundle) -> Bool in bundle.bundlePath.hasSuffix(".xctest") }
            .map { (bundle: Bundle) -> URL in URL(fileURLWithPath: bundle.bundlePath).deletingLastPathComponent() }
        #else
        let executable = URL(fileURLWithPath: "/proc/self/exe").resolvingSymlinksInPath()
        return [executable.deletingLastPathComponent()]
        #endif
    }
}
