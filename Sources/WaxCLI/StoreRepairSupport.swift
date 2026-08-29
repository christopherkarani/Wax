import ArgumentParser
import Foundation
import Wax
import WaxCore

/// Path and copy guards shared by offline store-maintenance commands.
///
/// Maintenance commands operate on a committed source and a distinct output
/// file. Lexical path comparison is not enough here: symlinks and hardlinks
/// can make two different strings refer to the same store (including the live
/// default store), and replacing one of those paths can destroy the source.
enum StoreRepairSupport {
    struct FileFingerprint: Equatable, Sendable {
        let byteCount: UInt64
        let contentHash: String
    }

    struct FileIdentity: Equatable, Sendable {
        let canonicalPath: String
        let device: UInt64?
        let inode: UInt64?
    }

    struct Promotion: Sendable {
        let destination: URL
        let backup: URL?
        /// Identity of the file this promotion installed. Rollback only
        /// removes this inode; a path replaced by another process is left
        /// untouched for manual recovery.
        let publishedIdentity: FileIdentity?
    }

    static func expandedURL(_ raw: String) -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = (trimmed as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }

    static func canonicalURL(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    static func liveFamilyURL() -> URL {
        canonicalURL(expandedURL(StoreSession.defaultStorePath))
    }

    static func destinationURL(from raw: String) throws -> URL {
        let url = expandedURL(raw)
        guard !url.path.isEmpty else {
            throw CLIError("Output path cannot be empty")
        }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return url
    }

    static func stagingURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(destination.deletingPathExtension().lastPathComponent)-repair-\(UUID().uuidString)"
            )
            .appendingPathExtension(destination.pathExtension.isEmpty ? "wax" : destination.pathExtension)
    }

    /// Validate path strings before ArgumentParser executes a command. This
    /// check is intentionally also repeated after paths are resolved because a
    /// destination may be created or replaced between parse and execution.
    static func validate(
        sourceRaw: String,
        destinationRaw: String,
        command: String
    ) throws {
        guard !sourceRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError("--store-path cannot be empty")
        }
        guard !destinationRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError("--output cannot be empty")
        }
        let source = expandedURL(sourceRaw)
        let destination = expandedURL(destinationRaw)
        try validate(source: source, destination: destination, command: command)
    }

    static func validate(
        source: URL,
        destination: URL,
        command: String
    ) throws {
        let sourceCanonical = canonicalURL(source)
        let destinationCanonical = canonicalURL(destination)
        let liveCanonical = liveFamilyURL()

        if sourceCanonical == liveCanonical {
            throw ValidationError(
                "\(command) refuses the live family store path \(StoreSession.defaultStorePath)"
            )
        }
        if destinationCanonical == liveCanonical {
            throw ValidationError(
                "\(command) refuses the live family store path \(StoreSession.defaultStorePath)"
            )
        }

        if isSymbolicLink(at: source) {
            throw ValidationError(
                "\(command) refuses a symlink source; pass the real store path"
            )
        }
        if isSymbolicLink(at: destination) {
            throw ValidationError(
                "\(command) refuses a symlink destination; pass a new regular file path"
            )
        }

        if sourceCanonical == destinationCanonical || sameFile(source, destination) {
            throw ValidationError("\(command) destination must be a distinct file from source")
        }

        if sameFile(source, liveCanonical) || sameFile(destination, liveCanonical) {
            throw ValidationError(
                "\(command) refuses a source or destination alias of the live family store"
            )
        }

        try ensureRegularFileIfPresent(at: source, label: "source", command: command)
        try ensureRegularFileIfPresent(at: destination, label: "output", command: command)
    }

    static func isSymbolicLink(at url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    static func identity(of url: URL) -> FileIdentity? {
        let canonical = canonicalURL(url)
        guard FileManager.default.fileExists(atPath: canonical.path) else { return nil }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: canonical.path) else {
            return FileIdentity(canonicalPath: canonical.path, device: nil, inode: nil)
        }
        let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        return FileIdentity(canonicalPath: canonical.path, device: device, inode: inode)
    }

    static func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        let left = identity(of: lhs)
        let right = identity(of: rhs)
        guard let left, let right else { return false }
        if left.canonicalPath == right.canonicalPath { return true }
        guard let leftInode = left.inode, let rightInode = right.inode,
              leftInode == rightInode
        else { return false }
        if let leftDevice = left.device, let rightDevice = right.device {
            return leftDevice == rightDevice
        }
        return true
    }

    /// Existing repair inputs/outputs must be regular files. In particular,
    /// never let an overwrite path recursively remove a directory.
    static func ensureRegularFileIfPresent(
        at url: URL,
        label: String,
        command: String
    ) throws {
        let path = url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        guard !isSymbolicLink(at: path) else {
            throw CLIError("\(command) \(label) must be a regular file, not a symlink")
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path.path),
              let type = attributes[.type] as? FileAttributeType,
              type == .typeRegular
        else {
            throw CLIError("\(command) \(label) must be a regular file")
        }
    }

    /// Take a non-blocking exclusive probe before replacing an existing
    /// destination. Renaming over a locked file is legal on Unix and would
    /// strand the writer on an unlinked inode, so this check belongs immediately
    /// before promotion as well as at command start. The probe is advisory and
    /// cannot stop an uncooperating process from swapping the pathname after
    /// it closes; no-follow checks and identity matching below keep rollback
    /// from deleting an unexpected path.
    static func ensureDestinationUnlockedIfPresent(
        at url: URL,
        command: String
    ) throws {
        try ensureRegularFileIfPresent(at: url, label: "output", command: command)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard try StoreLockProbe.tryExclusiveAccess(at: url.standardizedFileURL) else {
            throw CLIError("\(command) output destination is locked by another process")
        }
    }

    static func fingerprint(of url: URL) throws -> FileFingerprint {
        let canonical = canonicalURL(url)
        let handle = try FileHandle(forReadingFrom: canonical)
        defer { try? handle.close() }

        var hasher = SHA256Checksum()
        var byteCount: UInt64 = 0
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            hasher.update(data)
            byteCount += UInt64(data.count)
        }
        return FileFingerprint(byteCount: byteCount, contentHash: hasher.finalize().hexString)
    }

    /// Copy under a shared advisory lock, so a cooperating Wax writer cannot
    /// mutate the source while the byte-for-byte snapshot is being made.
    static func copySource(
        from source: URL,
        to destination: URL,
        overwrite: Bool
    ) throws -> FileFingerprint {
        // Validate the caller's path spelling before resolving symlinks. If
        // the destination is a symlink, validating only its resolved target
        // would permit overwrite to remove the target behind the link.
        let sourcePath = source.standardizedFileURL
        let destinationPath = destination.standardizedFileURL
        try validate(source: sourcePath, destination: destinationPath, command: "store repair")
        let canonicalSource = canonicalURL(sourcePath)

        let identityBefore = identity(of: canonicalSource)
        let before = try fingerprint(of: canonicalSource)
        let lock = try FileLock.acquire(at: canonicalSource, mode: .shared, timeout: .seconds(5))
        defer { try? lock.release() }

        guard identity(of: canonicalSource) == identityBefore else {
            throw CLIError("source file identity changed while taking the copy")
        }

        try ensureRegularFileIfPresent(at: destinationPath, label: "output", command: "store repair")
        if FileManager.default.fileExists(atPath: destinationPath.path) {
            guard overwrite else {
                throw CLIError("output destination already exists; pass --overwrite to replace it")
            }
            try ensureDestinationUnlockedIfPresent(at: destinationPath, command: "store repair")
            let destinationIdentity = identity(of: destinationPath)
            guard !isSymbolicLink(at: destinationPath),
                  identity(of: destinationPath) == destinationIdentity else {
                throw CLIError("output destination changed while preparing the copy")
            }
            try FileManager.default.removeItem(at: destinationPath)
        }
        try FileManager.default.copyItem(at: canonicalSource, to: destinationPath)
        let copied = try fingerprint(of: destinationPath)
        guard copied == before else {
            try? FileManager.default.removeItem(at: destinationPath)
            throw CLIError("source changed while taking the copy; no repair output was kept")
        }
        return before
    }

    /// Atomically publish a fully verified staging file. An existing regular
    /// destination is replaced only after the new file has passed verification;
    /// a failed repair therefore leaves the previous output untouched.
    static func promoteVerifiedOutput(
        from staging: URL,
        to destination: URL,
        overwrite: Bool,
        source: URL? = nil
    ) throws -> Promotion {
        let stagingPath = staging.standardizedFileURL
        let destinationPath = destination.standardizedFileURL
        guard !isSymbolicLink(at: stagingPath), !isSymbolicLink(at: destinationPath) else {
            throw CLIError("verified repair output refuses symlink staging or destination")
        }
        try ensureRegularFileIfPresent(at: stagingPath, label: "staging", command: "store repair")
        try ensureRegularFileIfPresent(at: destinationPath, label: "output", command: "store repair")
        let canonicalDestination = canonicalURL(destinationPath)
        guard FileManager.default.fileExists(atPath: stagingPath.path) else {
            throw CLIError("verified repair output is missing")
        }
        // The staging pathname is also untrusted until the atomic operation;
        // do not move a path that was swapped to a symlink or directory.
        try ensureRegularFileIfPresent(at: stagingPath, label: "staging", command: "store repair")
        if let source {
            guard !sameFile(source, destinationPath) else {
                throw CLIError("verified repair output destination aliases source")
            }
        }

        if FileManager.default.fileExists(atPath: destinationPath.path) {
            guard overwrite else {
                throw CLIError("output destination already exists; pass --overwrite to replace it")
            }
            try ensureDestinationUnlockedIfPresent(at: destinationPath, command: "store repair")
            // Re-check immediately before replace. The advisory lock is
            // released by the probe, so an external writer can still race;
            // these no-follow checks minimize the unsafe window and the
            // identity carried by Promotion makes rollback fail closed.
            try ensureRegularFileIfPresent(at: destinationPath, label: "output", command: "store repair")
            guard !isSymbolicLink(at: destinationPath) else {
                throw CLIError("verified repair output refuses a destination symlink")
            }
            let backupName = ".\(canonicalDestination.lastPathComponent)-previous-\(UUID().uuidString)"
            _ = try FileManager.default.replaceItemAt(
                destinationPath,
                withItemAt: stagingPath,
                backupItemName: backupName,
                options: []
            )
            let backupURL = destinationPath.deletingLastPathComponent()
                .appendingPathComponent(backupName)
            return Promotion(
                destination: destinationPath,
                backup: backupURL,
                publishedIdentity: identity(of: destinationPath)
            )
        } else {
            try FileManager.default.moveItem(at: stagingPath, to: destinationPath)
            return Promotion(
                destination: destinationPath,
                backup: nil,
                publishedIdentity: identity(of: destinationPath)
            )
        }
    }

    static func finalizePromotion(_ promotion: Promotion) throws {
        guard let backup = promotion.backup else { return }
        guard FileManager.default.fileExists(atPath: backup.path) else { return }

        // Retain the rollback copy unless the destination is still the exact
        // inode that was verified and published by this promotion. A pathname
        // race after verification must fail closed rather than deleting the
        // only known-good prior output.
        guard !isSymbolicLink(at: promotion.destination),
              let expected = promotion.publishedIdentity,
              identity(of: promotion.destination) == expected else {
            throw CLIError(
                "repair promotion destination changed before backup cleanup"
            )
        }
        try ensureRegularFileIfPresent(at: backup, label: "promotion backup", command: "store repair")
        try FileManager.default.removeItem(at: backup)
    }

    static func rollbackPromotion(_ promotion: Promotion) throws {
        if FileManager.default.fileExists(atPath: promotion.destination.path) {
            guard !isSymbolicLink(at: promotion.destination),
                  let expected = promotion.publishedIdentity,
                  identity(of: promotion.destination) == expected else {
                throw CLIError(
                    "repair rollback refused to remove a destination path changed after promotion"
                )
            }
            try FileManager.default.removeItem(at: promotion.destination)
        }
        if let backup = promotion.backup,
           FileManager.default.fileExists(atPath: backup.path) {
            try ensureRegularFileIfPresent(at: backup, label: "promotion backup", command: "store repair")
            guard !FileManager.default.fileExists(atPath: promotion.destination.path) else {
                throw CLIError("repair rollback destination reappeared before backup restore")
            }
            try FileManager.default.moveItem(at: backup, to: promotion.destination)
        }
    }

    static func verifyDeep(at url: URL) async throws -> WaxWALStats {
        let store = try await Wax.open(at: canonicalURL(url))
        do {
            try await store.verify(deep: true)
            let wal = await store.walStats()
            try await store.close()
            return wal
        } catch {
            try? await store.close()
            throw error
        }
    }
}

/// Compatibility façade retained for tests and callers of the released
/// compact-store command. The implementation lives in StoreRepairSupport so
/// embed-backfill and compact-store share exactly the same path policy.
enum CompactStorePathPolicy {
    static func validate(storePath: String, output: String) throws {
        try StoreRepairSupport.validate(
            sourceRaw: storePath,
            destinationRaw: output,
            command: "compact-store"
        )
    }

    static func refuseLiveFamily(_ url: URL, command: String) throws {
        let canonical = StoreRepairSupport.canonicalURL(url)
        let live = StoreRepairSupport.liveFamilyURL()
        if canonical == live || StoreRepairSupport.sameFile(canonical, live) {
            throw ValidationError(
                "\(command) refuses the live family store path \(StoreSession.defaultStorePath)"
            )
        }
    }

    static func destinationURL(from raw: String) throws -> URL {
        try StoreRepairSupport.destinationURL(from: raw)
    }

    static func liveFamilyURL() -> URL {
        StoreRepairSupport.liveFamilyURL()
    }

    static func expandedURL(_ raw: String) -> URL {
        StoreRepairSupport.expandedURL(raw)
    }
}
