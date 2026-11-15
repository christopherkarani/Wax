import Foundation

enum TempFiles {
    /// Each file gets its own directory, removed with everything a test left beside it.
    static func withTempFile<T>(
        fileExtension ext: String = "wax",
        _ body: (URL) async throws -> T
    ) async throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
        return try await body(url)
    }
}
