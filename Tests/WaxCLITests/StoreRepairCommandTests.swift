import Foundation
import Testing
import Wax
import WaxCore
@testable import wax_cli

@Suite("Store repair commands", .serialized)
struct StoreRepairCommandTests {
    @Test
    func maintenanceCommandsRequireDirectStoreAndOutput() throws {
        #expect(throws: (any Error).self) {
            _ = try CompactStoreCommand.parse([
                "--store-path", "/tmp/wax-repair-source.wax",
                "--output", "/tmp/wax-repair-destination.wax",
            ])
        }
        #expect(throws: (any Error).self) {
            _ = try EmbedBackfillCommand.parse([
                "--direct-store",
                "--store-path", "/tmp/wax-repair-source.wax",
            ])
        }
    }

    @Test
    func maintenanceCommandsRefuseLiveFamilyAndAliases() throws {
        #expect(throws: (any Error).self) {
            _ = try CompactStoreCommand.parse([
                "--direct-store",
                "--store-path", "~/.wax/memory.wax",
                "--output", "/tmp/wax-repair-destination.wax",
            ])
        }
        #expect(throws: (any Error).self) {
            _ = try EmbedBackfillCommand.parse([
                "--direct-store",
                "--store-path", "/tmp/wax-repair-source.wax",
                "--output", "~/.wax/memory.wax",
            ])
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-repair-alias-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source.wax")
        let symlink = root.appendingPathComponent("source-link.wax")
        let hardlink = root.appendingPathComponent("source-hardlink.wax")
        let target = root.appendingPathComponent("target.wax")
        let targetLink = root.appendingPathComponent("target-link.wax")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: source.path, contents: Data("source".utf8))
        FileManager.default.createFile(atPath: target.path, contents: Data("target".utf8))
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: source)
        try FileManager.default.createSymbolicLink(at: targetLink, withDestinationURL: target)
        try FileManager.default.linkItem(at: source, to: hardlink)

        #expect(throws: (any Error).self) {
            try StoreRepairSupport.validate(source: symlink, destination: root.appendingPathComponent("out.wax"), command: "compact-store")
        }
        #expect(throws: (any Error).self) {
            try StoreRepairSupport.validate(source: source, destination: symlink, command: "compact-store")
        }
        #expect(throws: (any Error).self) {
            try StoreRepairSupport.validate(source: source, destination: hardlink, command: "compact-store")
        }
        #expect(throws: (any Error).self) {
            _ = try StoreRepairSupport.copySource(from: source, to: targetLink, overwrite: true)
        }
        #expect(try Data(contentsOf: target) == Data("target".utf8))

        let nestedOutput = root.appendingPathComponent("nested/output.wax")
        let resolvedOutput = try StoreRepairSupport.destinationURL(from: nestedOutput.path)
        #expect(resolvedOutput == nestedOutput.standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: nestedOutput.deletingLastPathComponent().path))
    }

    @Test
    func maintenanceCommandsRejectDirectoryOutputsAndLockedDestinations() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-repair-destination-guards-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source.wax")
        let directory = root.appendingPathComponent("output-directory", isDirectory: true)
        let destination = root.appendingPathComponent("output.wax")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sourceStore = try await Wax.create(at: source)
        try await sourceStore.close()

        #expect(throws: (any Error).self) {
            _ = try CompactStoreCommand.parse([
                "--direct-store",
                "--no-embedder",
                "--store-path", source.path,
                "--output", directory.path,
            ])
        }
        #expect(throws: (any Error).self) {
            _ = try EmbedBackfillCommand.parse([
                "--direct-store",
                "--store-path", source.path,
                "--output", directory.path,
            ])
        }

        FileManager.default.createFile(atPath: destination.path, contents: Data("old output".utf8))
        let held = try FileLock.acquire(at: destination, mode: .exclusive, timeout: .seconds(1))
        defer { try? held.release() }

        let compact = try CompactStoreCommand.parse([
            "--direct-store",
            "--no-embedder",
            "--overwrite",
            "--store-path", source.path,
            "--output", destination.path,
        ])
        do {
            try await compact.runAsync()
            Issue.record("compact-store must fail before replacing a locked output")
        } catch let error as CLIError {
            #expect(error.message.contains("locked"))
        }

        try held.release()
        let embedBackfill = try EmbedBackfillCommand.parse([
            "--direct-store",
            "--overwrite",
            "--store-path", source.path,
            "--output", destination.path,
        ])
        let heldAgain = try FileLock.acquire(at: destination, mode: .exclusive, timeout: .seconds(1))
        defer { try? heldAgain.release() }
        do {
            try await embedBackfill.runAsync()
            Issue.record("embed-backfill must fail before replacing a locked output")
        } catch let error as CLIError {
            #expect(error.message.contains("locked"))
        }
    }

    @Test
    func compactStorePreservesSourceAndDeepVerifiesReopenedDestination() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-repair-compact-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source.wax")
        let destination = root.appendingPathComponent("destination.wax")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let original = try await Wax.create(at: source)
        for index in 0..<4 {
            _ = try await original.put(
                Data("repair payload \(index)".utf8),
                options: FrameMetaSubset(searchText: "repair payload \(index)")
            )
        }
        try await original.commit()
        try await original.close()

        let sourceBefore = try StoreRepairSupport.fingerprint(of: source)
        let command = try CompactStoreCommand.parse([
            "--direct-store",
            "--no-embedder",
            "--store-path", source.path,
            "--output", destination.path,
            "--format", "json",
        ])
        try await command.runAsync()

        #expect(try StoreRepairSupport.fingerprint(of: source) == sourceBefore)
        let destinationWal = try await StoreRepairSupport.verifyDeep(at: destination)
        #expect(destinationWal.walSize >= Constants.sessionWalSize)
        let reopened = try await Wax.open(at: destination)
        let frames = await reopened.frameMetas()
        #expect(frames.filter { $0.status == .active && $0.supersededBy == nil }.count == 4)
        try await reopened.close()

        let overwriteCommand = try CompactStoreCommand.parse([
            "--direct-store",
            "--no-embedder",
            "--overwrite",
            "--store-path", source.path,
            "--output", destination.path,
            "--format", "json",
        ])
        try await overwriteCommand.runAsync()
        let reopenedAfterOverwrite = try await Wax.open(at: destination)
        try await reopenedAfterOverwrite.verify(deep: true)
        try await reopenedAfterOverwrite.close()
    }

#if canImport(CoreML)
    @Test
    func vectorHealthUsesARealPrimaryStoreCanary() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-repair-health-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("target.wax")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let memory = try await StoreSession.open(at: source, requireVector: true)
        try await memory.remember("target store canary for actual vector health")
        try await memory.flush()
        try await memory.close()

        let command = try VectorHealthCommand.parse([
            "--direct-store",
            "--store-path", source.path,
            "--format", "json",
        ])
        try await command.runAsync()
    }
#endif
}
