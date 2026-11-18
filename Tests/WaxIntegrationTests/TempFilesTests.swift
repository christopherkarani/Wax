import Foundation
import Testing

/// The no-sidecar checks list the directory that holds the store. In the shared temp
/// directory that listing grew with every other test's files and held a cooperative
/// thread for seconds while the suite started, so each temp file gets its own directory.
@Test func aTempFileLivesAloneInItsOwnDirectory() async throws {
    let directory = try await TempFiles.withTempFile { url in
        FileManager.default.createFile(atPath: url.path, contents: Data())
        let directory = url.deletingLastPathComponent()
        #expect(directory.standardizedFileURL != FileManager.default.temporaryDirectory.standardizedFileURL)
        let listing = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(listing == [url.lastPathComponent])
        return directory
    }
    #expect(!FileManager.default.fileExists(atPath: directory.path))
}
