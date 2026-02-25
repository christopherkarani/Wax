import Foundation
import Testing

/// Test utilities for creating and managing temporary files
enum TempFiles {
    static func uniqueURL(fileExtension ext: String = "wax") -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
    }

    static func withTempFile<T>(
        fileExtension ext: String = "wax",
        _ body: (URL) throws -> T
    ) rethrows -> T {
        let url = uniqueURL(fileExtension: ext)
        defer { try? FileManager.default.removeItem(at: url) }
        return try body(url)
    }
}

@Test func tempURLIsUnique() {
    let url1 = TempFiles.uniqueURL()
    let url2 = TempFiles.uniqueURL()
    #expect(url1 != url2)
}

@Test func withTempFileCleansUp() throws {
    var capturedURL: URL?
    TempFiles.withTempFile { url in
        capturedURL = url
        FileManager.default.createFile(atPath: url.path, contents: Data())
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
    #expect(FileManager.default.fileExists(atPath: capturedURL!.path) == false)
}
