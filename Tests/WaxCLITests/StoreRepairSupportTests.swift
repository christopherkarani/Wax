import Foundation
import Testing
import WaxCore
@testable import wax_cli

@Suite("Store repair path safety", .serialized)
struct StoreRepairSupportTests {
    @Test
    func rejectsSymlinkHardlinkDirectoryAndLockedDestinations() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-repair-paths-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source.wax")
        let hardlink = root.appendingPathComponent("source-hardlink.wax")
        let sourceLink = root.appendingPathComponent("source-link.wax")
        let destination = root.appendingPathComponent("destination.wax")
        let destinationLink = root.appendingPathComponent("destination-link.wax")
        let destinationDirectory = root.appendingPathComponent("destination-directory", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: source.path, contents: Data("source".utf8))
        try FileManager.default.linkItem(at: source, to: hardlink)
        try FileManager.default.createSymbolicLink(at: sourceLink, withDestinationURL: source)
        FileManager.default.createFile(atPath: destination.path, contents: Data("destination".utf8))
        try FileManager.default.createSymbolicLink(at: destinationLink, withDestinationURL: destination)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        #expect(throws: (any Error).self) {
            try StoreRepairSupport.validate(source: source, destination: hardlink, command: "compact-store")
        }
        #expect(throws: (any Error).self) {
            try StoreRepairSupport.validate(source: sourceLink, destination: root.appendingPathComponent("new.wax"), command: "compact-store")
        }
        #expect(throws: (any Error).self) {
            try StoreRepairSupport.validate(source: source, destination: destinationLink, command: "compact-store")
        }
        #expect(throws: (any Error).self) {
            try StoreRepairSupport.validate(source: source, destination: destinationDirectory, command: "compact-store")
        }

        let lock = try FileLock.acquire(at: destination, mode: .exclusive)
        defer { try? lock.release() }
        #expect(throws: (any Error).self) {
            try StoreRepairSupport.ensureDestinationUnlockedIfPresent(at: destination, command: "compact-store")
        }
    }

    @Test
    func copySourcePreservesFingerprintAndCreatesNestedDestination() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-repair-copy-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source.wax")
        let copy = root.appendingPathComponent("nested/copy.wax")
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: source.path, contents: Data("source bytes".utf8))
        let before = try StoreRepairSupport.fingerprint(of: source)
        let destination = try StoreRepairSupport.destinationURL(from: copy.path)
        let copied = try StoreRepairSupport.copySource(from: source, to: destination, overwrite: false)

        #expect(copied == before)
        #expect(try StoreRepairSupport.fingerprint(of: source) == before)
        #expect(try StoreRepairSupport.fingerprint(of: destination) == before)
    }
}
