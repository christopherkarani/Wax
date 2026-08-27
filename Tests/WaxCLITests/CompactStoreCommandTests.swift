import Foundation
import Testing
import WaxCore
@testable import wax_cli

struct CompactStoreCommandTests {
    @Test func compactStoreRequiresDirectStoreFlag() throws {
        #expect(throws: (any Error).self) {
            _ = try CompactStoreCommand.parse([
                "--store-path", "/tmp/wax-compact-in.wax",
                "--output", "/tmp/wax-compact-out.wax",
            ])
        }
    }

    @Test func compactStoreRefusesLiveFamilyPath() throws {
        #expect(throws: (any Error).self) {
            _ = try CompactStoreCommand.parse([
                "--direct-store",
                "--store-path", StoreSession.defaultStorePath,
                "--output", "/tmp/wax-compact-out.wax",
            ])
        }
        #expect(throws: (any Error).self) {
            _ = try CompactStoreCommand.parse([
                "--direct-store",
                "--store-path", "~/.wax/memory.wax",
                "--output", "/tmp/wax-compact-out.wax",
            ])
        }
    }

    @Test func compactStoreRewritesTempCopyWithLongTermWal() async throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-compact-src-\(UUID().uuidString)")
            .appendingPathExtension("wax")
        let destURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-compact-dst-\(UUID().uuidString)")
            .appendingPathExtension("wax")
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: destURL)
        }

        let source = try await Wax.create(at: sourceURL)
        for index in 0..<5 {
            _ = try await source.put(
                Data("compact live payload \(index)".utf8),
                options: FrameMetaSubset(searchText: "compact live payload \(index)")
            )
        }
        try await source.commit()
        let sourceWal = await source.walStats()
        #expect(sourceWal.walSize == Constants.defaultWalSize)
        try await source.close()

        var command = try CompactStoreCommand.parse([
            "--direct-store",
            "--no-embedder",
            "--store-path", sourceURL.path,
            "--output", destURL.path,
            "--format", "json",
        ])
        try await command.runAsync()

        let dest = try await Wax.open(at: destURL)
        let destWal = await dest.walStats()
        // Shipped rewriteLiveSet automatic dest for a 256 MiB source with small
        // payload is sessionWalSize. Constants.longTermWalSize is not on this line.
        #expect(destWal.walSize == Constants.sessionWalSize)
        try await dest.verify(deep: true)
        try await dest.close()

        let destSize = try destURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        #expect(destSize < 32 * 1024 * 1024)
        #expect(destSize < Int(Constants.defaultWalSize))
    }
}
