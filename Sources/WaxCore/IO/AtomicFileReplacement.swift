import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Publishes a staged file over an existing one in a single atomic step.
///
/// Use this instead of `FileManager.replaceItemAt(_:withItemAt:backupItemName:options:)`.
/// On Apple platforms it calls that method unchanged. On Linux,
/// swift-corelibs-foundation's implementation renames the *original* over the
/// replacement (`rename(original, replacement)`), so the destination pathname
/// disappears, the new bytes are destroyed, and the original survives only at
/// the staging path, which callers then delete. It throws ENOENT afterwards.
///
/// The Linux path here keeps the same contract with POSIX calls:
/// - the replacement is renamed over the destination with rename(2), which is
///   atomic on one filesystem, so the destination name never goes missing and
///   readers see either the old file or the new one;
/// - unless `.usingNewMetadataOnly` is passed, the replacement first takes the
///   destination's permission bits (Foundation's default, too);
/// - a backup is a second hard link to the original file, made before the
///   rename, so it is the original inode (as on Apple platforms), not a copy;
///   it is removed afterwards unless `.withoutDeletingBackupItem` is passed;
/// - a destination that is a symlink is replaced as a pathname: the file it
///   points to is neither written nor re-moded;
/// - on failure the destination is untouched and no backup is left behind.
///   Both items must be on the same filesystem (EXDEV is reported, not
///   emulated with a copy).
///
/// Callers that need the new name to survive a crash still fsync the parent
/// directory themselves.
package enum AtomicFileReplacement {
    @discardableResult
    package static func replaceItem(
        at destination: URL,
        withItemAt replacement: URL,
        backupItemName: String? = nil,
        options: FileManager.ItemReplacementOptions = []
    ) throws -> URL? {
        #if os(Linux)
        return try renameReplacing(
            destination,
            with: replacement,
            backupItemName: backupItemName,
            options: options
        )
        #else
        return try FileManager.default.replaceItemAt(
            destination,
            withItemAt: replacement,
            backupItemName: backupItemName,
            options: options
        )
        #endif
    }

    #if os(Linux)
    private static func renameReplacing(
        _ destination: URL,
        with replacement: URL,
        backupItemName: String?,
        options: FileManager.ItemReplacementOptions
    ) throws -> URL {
        let destinationPath = destination.path
        let replacementPath = replacement.path

        var destinationInfo = stat()
        guard lstat(destinationPath, &destinationInfo) == 0 else {
            throw failure("lstat", destinationPath)
        }
        var replacementInfo = stat()
        guard lstat(replacementPath, &replacementInfo) == 0 else {
            throw failure("lstat", replacementPath)
        }

        if !options.contains(.usingNewMetadataOnly),
           !isSymbolicLink(destinationInfo),
           !isSymbolicLink(replacementInfo) {
            let mode = destinationInfo.st_mode & 0o7777
            if replacementInfo.st_mode & 0o7777 != mode {
                guard chmod(replacementPath, mode) == 0 else {
                    throw failure("chmod", replacementPath)
                }
            }
        }

        var backupPath: String?
        if let backupItemName {
            let path = destination.deletingLastPathComponent()
                .appendingPathComponent(backupItemName).path
            // Flag 0: link the destination entry itself, never a symlink's target.
            guard linkat(AT_FDCWD, destinationPath, AT_FDCWD, path, 0) == 0 else {
                throw failure("link", path)
            }
            backupPath = path
        }

        guard rename(replacementPath, destinationPath) == 0 else {
            let error = failure("rename", destinationPath)
            if let backupPath { _ = unlink(backupPath) }
            throw error
        }

        if let backupPath, !options.contains(.withoutDeletingBackupItem) {
            _ = unlink(backupPath)
        }
        return destination
    }

    private static func isSymbolicLink(_ info: stat) -> Bool {
        info.st_mode & S_IFMT == S_IFLNK
    }

    private static func failure(_ operation: String, _ path: String) -> WaxError {
        let code = errno
        return WaxError.io("atomic replace: \(operation) failed for \(path): \(String(cString: strerror(code)))")
    }
    #endif
}
