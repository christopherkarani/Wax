import Foundation
import Testing
import Wax

@Test
func memoryOrchestratorRememberFileThrowsLoadFailedForDirectoryInput() async throws {
    let directoryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-ingest-dir-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }

    try await TempFiles.withTempFile { storeURL in
        let orchestrator = try await MemoryOrchestrator(
            at: storeURL,
            config: TestHelpers.defaultMemoryConfig(vector: false)
        )

        do {
            try await orchestrator.remember(fileAt: directoryURL)
            #expect(Bool(false))
        } catch let error as FileIngestError {
            guard case let .loadFailed(url) = error else {
                #expect(Bool(false))
                return
            }
            #expect(url == directoryURL)
        }
        try await orchestrator.close()
    }
}

@Test
func memoryOrchestratorRememberFileThrowsUnsupportedEncodingForBinaryPayload() async throws {
    try await TempFiles.withTempFile(fileExtension: "bin") { binaryURL in
        let invalidUTF8 = Data([0xFF, 0xFE, 0xFD, 0xFC])
        try invalidUTF8.write(to: binaryURL, options: .atomic)

        try await TempFiles.withTempFile { storeURL in
            let orchestrator = try await MemoryOrchestrator(
                at: storeURL,
                config: TestHelpers.defaultMemoryConfig(vector: false)
            )

            do {
                try await orchestrator.remember(fileAt: binaryURL)
                #expect(Bool(false))
            } catch let error as FileIngestError {
                guard case let .unsupportedTextEncoding(url) = error else {
                    #expect(Bool(false))
                    return
                }
                #expect(url == binaryURL)
            }
            try await orchestrator.close()
        }
    }
}

@Test
func memoryOrchestratorRememberFileThrowsEmptyContentForWhitespaceOnlyFile() async throws {
    try await TempFiles.withTempFile(fileExtension: "txt") { fileURL in
        try " \n\t  ".write(to: fileURL, atomically: true, encoding: .utf8)

        try await TempFiles.withTempFile { storeURL in
            let orchestrator = try await MemoryOrchestrator(
                at: storeURL,
                config: TestHelpers.defaultMemoryConfig(vector: false)
            )

            do {
                try await orchestrator.remember(fileAt: fileURL)
                #expect(Bool(false))
            } catch let error as FileIngestError {
                guard case let .emptyContent(url) = error else {
                    #expect(Bool(false))
                    return
                }
                #expect(url == fileURL)
            }
            try await orchestrator.close()
        }
    }
}
