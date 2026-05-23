import Foundation

/// Locates SwiftPM resource bundles when the host binary is launched through a
/// symlink (Mint, Homebrew taps, `ln -s` installs, etc.). SwiftPM's
/// auto-generated `Bundle.module` accessor uses `Bundle.main.bundleURL` which
/// does **not** resolve symlinks, so it cannot find the `*.bundle` directories
/// that sit next to the real executable.
///
/// `resolveModule(named:moduleFallback:)` tries, in order:
/// 1. The provided `moduleFallback` (SwiftPM's `Bundle.module`) — this is
///    correct for app/test/framework hosts and for direct executable launches.
/// 2. The directory of the binary as launched (symlink target's parent).
/// 3. The directory of the resolved binary (real install location).
///
/// Pass the bundle name SwiftPM would emit (`<Package>_<Target>.bundle`).
public enum WaxBundleResolver {
    public static func resolveModule(named bundleName: String, moduleFallback: Bundle) -> Bundle {
        if moduleFallback.bundleURL.lastPathComponent == bundleName,
           FileManager.default.fileExists(atPath: moduleFallback.bundlePath) {
            return moduleFallback
        }
        for directory in candidateDirectories() {
            let candidate = directory.appendingPathComponent(bundleName)
            if let bundle = Bundle(url: candidate) { return bundle }
        }
        return moduleFallback
    }

    private static func candidateDirectories() -> [URL] {
        var directories: [URL] = []
        let mainBundleURL = Bundle.main.bundleURL
        directories.append(mainBundleURL)

        if let executablePath = Bundle.main.executablePath {
            let launched = URL(fileURLWithPath: executablePath)
            let resolved = launched.resolvingSymlinksInPath()
            directories.append(launched.deletingLastPathComponent())
            if resolved.path != launched.path {
                directories.append(resolved.deletingLastPathComponent())
            }
        }
        return directories
    }
}
