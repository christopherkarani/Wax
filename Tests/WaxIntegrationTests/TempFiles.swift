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
}

