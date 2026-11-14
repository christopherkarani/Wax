import Foundation
import Testing
@testable import WaxCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// `AtomicFileReplacement.replaceItem` publishes a staged file over an existing
/// one. On Linux, swift-corelibs-foundation's `replaceItemAt` renames the
/// original over the staged file instead, so the destination disappears and the
/// new bytes are lost; these tests pin the contract the store and config
/// writers rely on.
@Suite("Atomic file replacement")
struct AtomicFileReplacementTests {
    private static func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-atomic-replace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func write(_ text: String, to url: URL, mode: Int = 0o644) throws {
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: url.path)
    }

    private static func mode(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1) & 0o7777
    }

    private static func inode(of url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require((attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
    }

    private static func isSymlink(_ url: URL) -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.type] as? FileAttributeType == .typeSymbolicLink
    }

    @Test func replacesDestinationWithNewBytesAndConsumesReplacement() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("store.wax")
        let staging = root.appendingPathComponent(".store-staging.wax")
        try Self.write("previous", to: destination)
        try Self.write("published", to: staging)
        let stagedInode = try Self.inode(of: staging)

        let result = try AtomicFileReplacement.replaceItem(at: destination, withItemAt: staging)

        #expect(result?.standardizedFileURL.path == destination.standardizedFileURL.path)
        #expect(try Data(contentsOf: destination) == Data("published".utf8))
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #if os(Linux)
        // rename(2) publishes the staged inode itself.
        #expect(try Self.inode(of: destination) == stagedInode)
        #else
        _ = stagedInode
        #endif
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["store.wax"])
    }

    @Test func preservesTheOriginalPermissions() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("settings.json")
        let staging = root.appendingPathComponent(".settings.json.tmp")
        try Self.write("{}", to: destination, mode: 0o640)
        try Self.write("{\"a\":1}", to: staging, mode: 0o600)

        try AtomicFileReplacement.replaceItem(at: destination, withItemAt: staging)

        #expect(try Self.mode(of: destination) == 0o640)
        #expect(try Data(contentsOf: destination) == Data("{\"a\":1}".utf8))
    }

    @Test func usingNewMetadataOnlyKeepsTheReplacementPermissions() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("settings.json")
        let staging = root.appendingPathComponent(".settings.json.tmp")
        try Self.write("old", to: destination, mode: 0o644)
        try Self.write("new", to: staging, mode: 0o600)

        try AtomicFileReplacement.replaceItem(at: destination, withItemAt: staging, options: [.usingNewMetadataOnly])

        #expect(try Self.mode(of: destination) == 0o600)
        #expect(try Data(contentsOf: destination) == Data("new".utf8))
    }

    @Test func keepsTheOriginalAsTheBackupWhenAsked() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("store.wax")
        let staging = root.appendingPathComponent(".store-staging.wax")
        let backupName = ".store.wax-previous-\(UUID().uuidString)"
        let backup = root.appendingPathComponent(backupName)
        try Self.write("previous", to: destination)
        try Self.write("published", to: staging)
        let originalInode = try Self.inode(of: destination)

        try AtomicFileReplacement.replaceItem(
            at: destination,
            withItemAt: staging,
            backupItemName: backupName,
            options: [.withoutDeletingBackupItem]
        )

        #expect(try Data(contentsOf: destination) == Data("published".utf8))
        #expect(try Data(contentsOf: backup) == Data("previous".utf8))
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #if os(Linux)
        // The backup is the original file itself, not a copy.
        #expect(try Self.inode(of: backup) == originalInode)
        #else
        _ = originalInode
        #endif
    }

    @Test func removesTheBackupUnlessAskedToKeepIt() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("store.wax")
        let staging = root.appendingPathComponent(".store-staging.wax")
        try Self.write("previous", to: destination)
        try Self.write("published", to: staging)

        try AtomicFileReplacement.replaceItem(at: destination, withItemAt: staging, backupItemName: "store.wax.bak")

        #expect(try Data(contentsOf: destination) == Data("published".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["store.wax"])
    }

    @Test func failureLeavesTheDestinationUntouched() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("store.wax")
        let missing = root.appendingPathComponent(".missing-staging.wax")
        try Self.write("previous", to: destination)

        #expect(throws: (any Error).self) {
            try AtomicFileReplacement.replaceItem(
                at: destination,
                withItemAt: missing,
                backupItemName: ".store.wax-previous",
                options: [.withoutDeletingBackupItem]
            )
        }
        #expect(try Data(contentsOf: destination) == Data("previous".utf8))
        #if os(Linux)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["store.wax"])
        #endif
    }

    #if os(Linux)
    /// rename(2) replaces the pathname itself; the file a symlink destination
    /// points to is neither written nor re-moded.
    @Test func replacesASymlinkDestinationWithoutTouchingItsTarget() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target.txt")
        let destination = root.appendingPathComponent("store.wax")
        let staging = root.appendingPathComponent(".store-staging.wax")
        try Self.write("target", to: target, mode: 0o600)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: target)
        try Self.write("published", to: staging, mode: 0o644)

        try AtomicFileReplacement.replaceItem(at: destination, withItemAt: staging)

        #expect(!Self.isSymlink(destination))
        #expect(try Data(contentsOf: destination) == Data("published".utf8))
        #expect(try Self.mode(of: destination) == 0o644)
        #expect(try Data(contentsOf: target) == Data("target".utf8))
        #expect(try Self.mode(of: target) == 0o600)
    }

    /// The destination name always resolves while replacements run: an
    /// observer polling it with lstat never sees it missing.
    @Test func destinationIsNeverAbsentDuringReplacement() async throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("store.wax")
        try Self.write("generation 0", to: destination)

        let missingSightings = try await BlockingWork.run { () throws -> Int in
            let done = AtomicFlag()
            let missing = AtomicCounter()
            let observer = Thread {
                var info = stat()
                while !done.isSet {
                    if lstat(destination.path, &info) != 0 { missing.increment() }
                }
            }
            observer.start()
            defer { done.set() }
            for generation in 1...300 {
                let staging = root.appendingPathComponent(".staging-\(generation)")
                try Self.write("generation \(generation)", to: staging)
                try AtomicFileReplacement.replaceItem(
                    at: destination,
                    withItemAt: staging,
                    backupItemName: ".backup-\(generation)"
                )
            }
            done.set()
            while !observer.isFinished { usleep(1_000) }
            return missing.value
        }

        #expect(missingSightings == 0)
        #expect(try Data(contentsOf: destination) == Data("generation 300".utf8))
    }
    #endif
}

private final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

private final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
