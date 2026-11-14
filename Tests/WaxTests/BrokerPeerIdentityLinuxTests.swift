#if os(Linux)
import Foundation
import Glibc
import Testing
@testable import Wax
import WaxCore
import WaxTestSupport

/// The Linux side of mute-broker recovery: the broker client must identify the
/// process listening on the broker socket before it signals anything.
@Suite struct BrokerPeerIdentityLinuxTests {
    @Test func peerCredentialsOfAListenerNameThisProcessAndUser() throws {
        let fixture = try ListenerFixture()
        defer { fixture.remove() }

        let peer = AgentBrokerClient.peerCredentials(socketPath: fixture.socketPath)

        #expect(peer?.pid == getpid())
        #expect(peer?.uid == geteuid())
    }

    @Test func peerCredentialsAreNilWithoutAListener() throws {
        let fixture = try ListenerFixture(listen: false)
        defer { fixture.remove() }

        #expect(AgentBrokerClient.peerCredentials(socketPath: fixture.socketPath) == nil)
    }

    @Test func executablePathOfThisProcessIsTheTestBinary() {
        let path = AgentBrokerClient.executablePath(pid: getpid())
        let expected = URL(fileURLWithPath: "/proc/self/exe").resolvingSymlinksInPath().path
        #expect(path == expected)
    }

    @Test func executablePathOfAMissingProcessIsNil() {
        // pid_max is at most 2^22 on Linux, so this pid cannot exist.
        #expect(AgentBrokerClient.executablePath(pid: 0x7FFF_FFF0) == nil)
    }

    /// The kernel marks the link of a process whose binary was replaced, as an
    /// upgrade does while the old broker still runs, with " (deleted)".
    @Test(arguments: [
        ("/home/u/.local/share/waxmcp/runtime/linux-x64/wax-cli", "wax-cli"),
        ("/home/u/.local/share/waxmcp/runtime/linux-x64/wax-cli (deleted)", "wax-cli"),
        ("/usr/bin/python3", "python3"),
        ("/tmp/wax-cli-impostor", "wax-cli-impostor"),
    ])
    func executableNameStripsTheDeletedMarker(link: String, name: String) {
        #expect(AgentBrokerClient.executableName(fromProcExeLink: link) == name)
    }

    /// The listener is this test process, not wax-cli, so it is left alone.
    @Test func aForeignListenerIsNotAnOwnedBroker() async throws {
        let fixture = try ListenerFixture()
        defer { fixture.remove() }

        let pid = await AgentBrokerClient.ownedBrokerPeerPIDOffPool(socketPath: fixture.socketPath)

        #expect(pid == nil)
    }
}

private struct ListenerFixture {
    let root: URL
    let fd: Int32

    init(listen: Bool = true) throws {
        // Short path: Unix socket paths are limited to 108 bytes.
        root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("wxpi-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        fd = listen ? try Self.listen(at: root.appendingPathComponent("broker.sock").path) : -1
    }

    var socketPath: String { root.appendingPathComponent("broker.sock").path }

    func remove() {
        if fd >= 0 { close(fd) }
        try? FileManager.default.removeItem(at: root)
    }

    private static func listen(at path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, TestPOSIX.sockStream, 0)
        guard fd >= 0 else { throw ListenerFixtureError() }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in bytes.enumerated() {
                buffer[index] = byte
            }
        }
        let bound = withUnsafePointer(to: &address) { (pointer: UnsafePointer<sockaddr_un>) -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { (sockaddrPointer: UnsafePointer<sockaddr>) -> Int32 in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Glibc.listen(fd, 8) == 0 else {
            close(fd)
            throw ListenerFixtureError()
        }
        return fd
    }
}

private struct ListenerFixtureError: Error {}
#endif
