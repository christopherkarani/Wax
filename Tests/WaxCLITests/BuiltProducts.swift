import Foundation
@testable import wax_cli

/// Locates an executable product (`wax-cli`, `wax-mcp`, ...) built by the same
/// `swift build`/`swift test` invocation as this test bundle.
///
/// SwiftPM places test bundles next to the products they were built with, so
/// the running `.xctest` bundle's directory is checked first. That covers any
/// triple and the swift-build output layout. The `.build/debug` paths are
/// fallbacks for runners that load tests from elsewhere.
func builtProductPath(named name: String) throws -> String {
    var candidates: [String] = []
    for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
        let productsDirectory = URL(fileURLWithPath: bundle.bundlePath).deletingLastPathComponent()
        candidates.append(productsDirectory.appendingPathComponent(name).path)
    }
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    candidates.append(root.appendingPathComponent(".build/debug/\(name)").path)
    candidates.append(root.appendingPathComponent(".build/arm64-apple-macosx/debug/\(name)").path)

    if let match = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
        return match
    }
    throw CLIError("Unable to locate built product '\(name)' (checked: \(candidates.joined(separator: ", ")))")
}
