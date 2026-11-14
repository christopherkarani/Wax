#if MCPServer && os(Linux)
import Foundation
import Glibc
import Testing
@testable import wax_mcp

/// On Linux the license key that Apple platforms keep in the Keychain lives in
/// a private file under the XDG config directory.
@Suite struct LicenseKeyFileStoreLinuxTests {
    private static func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-license-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func mode(_ path: String) -> mode_t {
        var info = stat()
        guard lstat(path, &info) == 0 else { return 0 }
        return info.st_mode & 0o7777
    }

    @Test func defaultLocationFollowsXDGConfigHome() {
        #expect(
            LicenseKeyFileStore.defaultURL(environment: ["HOME": "/home/ada"]).path
                == "/home/ada/.config/wax/license-key"
        )
        #expect(
            LicenseKeyFileStore.defaultURL(environment: ["HOME": "/home/ada", "XDG_CONFIG_HOME": "/xdg"]).path
                == "/xdg/wax/license-key"
        )
        #expect(
            LicenseKeyFileStore.defaultURL(environment: ["HOME": "/home/ada", "XDG_CONFIG_HOME": "relative"]).path
                == "/home/ada/.config/wax/license-key"
        )
    }

    @Test func aWrittenKeyReadsBackFromAPrivateFile() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LicenseKeyFileStore(environment: ["HOME": root.path])

        #expect(store.read() == nil)
        try store.write("ABCD-EFGH-IJKL-MNOP")

        #expect(store.read()?.trimmingCharacters(in: .whitespacesAndNewlines) == "ABCD-EFGH-IJKL-MNOP")
        #expect(Self.mode(store.url.path) == 0o600)
        #expect(Self.mode(store.url.deletingLastPathComponent().path) == 0o700)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: store.url.deletingLastPathComponent().path)
        #expect(leftovers == ["license-key"])
    }

    /// A key file someone left world-readable is replaced by a 0600 one, and a
    /// config directory others can list is narrowed to 0700.
    @Test func rewritingNarrowsALooseFileAndDirectory() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LicenseKeyFileStore(environment: ["HOME": root.path])
        let directory = store.url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "OLD0-OLD0-OLD0-OLD0\n".write(to: store.url, atomically: false, encoding: .utf8)
        #expect(chmod(store.url.path, 0o644) == 0)
        #expect(chmod(directory.path, 0o755) == 0)

        try store.write("NEW1-NEW1-NEW1-NEW1")

        #expect(store.read()?.hasPrefix("NEW1-NEW1-NEW1-NEW1") == true)
        #expect(Self.mode(store.url.path) == 0o600)
        #expect(Self.mode(directory.path) == 0o700)
    }

    @Test func aSymlinkedKeyFileIsNotRead() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LicenseKeyFileStore(environment: ["HOME": root.path])
        let target = root.appendingPathComponent("elsewhere")
        try "ABCD-EFGH-IJKL-MNOP\n".write(to: target, atomically: false, encoding: .utf8)
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: store.url, withDestinationURL: target)

        #expect(store.read() == nil)
    }
}
#endif
