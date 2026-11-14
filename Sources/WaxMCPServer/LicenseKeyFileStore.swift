#if MCPServer && os(Linux)
import Foundation
import Glibc
import WaxCore

/// The Linux home of the Wax license key, which Apple platforms keep in the
/// Keychain: `$XDG_CONFIG_HOME/wax/license-key` (default `~/.config/wax`).
///
/// The file is mode 0600 in a 0700 directory from the moment it exists: it is
/// created with `O_EXCL` and mode 0600 under a temporary name, written, synced
/// and then renamed into place, so no reader ever sees it world-readable or
/// half-written.
struct LicenseKeyFileStore {
    let url: URL

    init(url: URL) {
        self.url = url
    }

    init(environment: [String: String]) {
        self.init(url: Self.defaultURL(environment: environment))
    }

    static func defaultURL(environment: [String: String]) -> URL {
        let configHome: URL
        if let raw = environment["XDG_CONFIG_HOME"], raw.hasPrefix("/") {
            configHome = URL(fileURLWithPath: raw, isDirectory: true)
        } else {
            let home = environment["HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil }
                ?? FileManager.default.homeDirectoryForCurrentUser.path
            configHome = URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(".config", isDirectory: true)
        }
        return configHome
            .appendingPathComponent("wax", isDirectory: true)
            .appendingPathComponent("license-key")
    }

    /// The stored key, or nil when there is none or the file is not a regular
    /// file owned by this user. Symlinks are not followed.
    func read() -> String? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(),
              info.st_size <= 4096 else {
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: Int(info.st_size))
        var filled = 0
        while filled < buffer.count {
            let count = buffer.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Int in
                Glibc.read(fd, raw.baseAddress! + filled, raw.count - filled)
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            filled += count
        }
        return String(decoding: buffer.prefix(filled), as: UTF8.self)
    }

    func write(_ key: String) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        // An existing directory keeps its mode; the key must not sit in one others can list.
        guard chmod(directory.path, 0o700) == 0 else { throw Self.failure("chmod", directory.path) }

        let staging = directory.appendingPathComponent(".license-key.\(UUID().uuidString)")
        let fd = open(staging.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Self.failure("open", staging.path) }
        var published = false
        defer {
            if !published { unlink(staging.path) }
        }
        do {
            defer { close(fd) }
            // umask can only narrow 0600; set it exactly so the published file is 0600.
            guard fchmod(fd, 0o600) == 0 else { throw Self.failure("fchmod", staging.path) }
            let bytes = Array((key + "\n").utf8)
            var written = 0
            while written < bytes.count {
                let count = bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
                    Glibc.write(fd, raw.baseAddress! + written, raw.count - written)
                }
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Self.failure("write", staging.path) }
                written += count
            }
            guard fsync(fd) == 0 else { throw Self.failure("fsync", staging.path) }
        }

        var existing = stat()
        if lstat(url.path, &existing) == 0 {
            // Keep the staged file's 0600, whatever mode the old file had.
            try AtomicFileReplacement.replaceItem(
                at: url,
                withItemAt: staging,
                options: .usingNewMetadataOnly
            )
        } else {
            guard rename(staging.path, url.path) == 0 else { throw Self.failure("rename", url.path) }
        }
        published = true
    }

    private static func failure(_ operation: String, _ path: String) -> WaxError {
        let code = errno
        return WaxError.io("license key store: \(operation) failed for \(path): \(String(cString: strerror(code)))")
    }
}
#endif
