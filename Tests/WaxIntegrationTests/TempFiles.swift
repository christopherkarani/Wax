import Foundation

enum TempFiles {
    static func withTempFile<T>(
        fileExtension ext: String = "wax",
        _ body: (URL) async throws -> T
    ) async rethrows -> T {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
        defer { try? FileManager.default.removeItem(at: url) }
        return try await body(url)
    }

    /// The entries beside `url` whose names start with its base name: the store
    /// plus any sidecar it left behind.
    ///
    /// The temporary directory is shared with every test running in parallel.
    /// `contentsOfDirectory(at:includingPropertiesForKeys:)` stats each
    /// subdirectory it reads on Linux (swift-corelibs-foundation walks with fts),
    /// so it throws a pathless `NSFileReadNoSuchFileError` whenever another test
    /// removes its temporary directory mid-walk. The path-based listing only
    /// reads directory entries, so it is not affected.
    static func storeFamily(of url: URL) throws -> [URL] {
        let baseName = url.deletingPathExtension().lastPathComponent
        let dir = url.deletingLastPathComponent()
        return try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix(baseName) }
            .map { dir.appendingPathComponent($0) }
    }
}

