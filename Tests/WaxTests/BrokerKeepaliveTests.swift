import Foundation
import Testing
@testable import Wax
import WaxCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Suite struct BrokerKeepaliveTests {
    @Test func intervalStaysWellUnderTheIdleTimeout() {
        #expect(BrokerKeepalive.intervalSeconds(environment: [:]) == 60)
        #expect(BrokerKeepalive.intervalSeconds(environment: ["WAX_BROKER_IDLE_TIMEOUT_SECS": "30"]) == 10)
        #expect(BrokerKeepalive.intervalSeconds(environment: ["WAX_BROKER_KEEPALIVE_SECS": "5"]) == 5)
        #expect(BrokerKeepalive.intervalSeconds(environment: ["WAX_BROKER_KEEPALIVE_SECS": "0"]) == nil)
        // An unusable override falls back to the derived interval.
        #expect(BrokerKeepalive.intervalSeconds(environment: ["WAX_BROKER_KEEPALIVE_SECS": "inf"]) == 60)
        // A tiny override must not turn into a hot ping loop.
        #expect(BrokerKeepalive.intervalSeconds(environment: ["WAX_BROKER_KEEPALIVE_SECS": "0.0001"]) == 0.2)
        // A short idle timeout still gets pings well inside it, or the broker
        // idles out between them (test harnesses run with a 1s idle timeout).
        #expect(BrokerKeepalive.intervalSeconds(environment: ["WAX_BROKER_IDLE_TIMEOUT_SECS": "1"]) == 1.0 / 3)
        #expect(BrokerKeepalive.intervalSeconds(environment: ["WAX_BROKER_IDLE_TIMEOUT_SECS": "0.3"]) == 0.2)
    }

    /// The broker idled out or crashed while servers still run: the next
    /// keepalive starts one so session-start primes find it.
    @Test func tickStartsABrokerWhenNothingListens() async throws {
        let fixture = try KeepaliveFixture()
        defer { fixture.remove() }
        let configuration = try fixture.configuration(brokerScript: """
            #!/bin/sh
            echo started > '\(fixture.startedFlag.path)'
            exit 1
            """)

        // The canary exits without serving, so the start fails after launching it.
        await #expect(throws: (any Error).self) {
            _ = try await BrokerKeepalive.tick(configuration: configuration, pingTimeoutSeconds: 0.2)
        }
        #expect(FileManager.default.fileExists(atPath: fixture.startedFlag.path))
    }

    #if canImport(Darwin)
    /// One missed ping is left alone: replacing a broker drops its work.
    @Test func tickLeavesABrokerThatMissedOnePingAlone() async throws {
        let fixture = try KeepaliveFixture()
        defer { fixture.remove() }
        let configuration = try fixture.configuration(brokerScript: """
            #!/bin/sh
            echo started > '\(fixture.startedFlag.path)'
            exit 1
            """)
        let listener = try fixture.listenWithoutReplying()
        defer { close(listener) }

        let outcome = try await BrokerKeepalive.tick(configuration: configuration, pingTimeoutSeconds: 0.2)

        #expect(outcome == .unanswered)
        #expect(FileManager.default.fileExists(atPath: fixture.startedFlag.path) == false)
    }

    /// A second miss goes to recovery, which never starts a second broker
    /// beside a live socket. This listener is not wax-cli, so recovery refuses
    /// to replace it rather than killing a foreign process.
    @Test func tickHandsARepeatedlyMuteBrokerToRecovery() async throws {
        let fixture = try KeepaliveFixture()
        defer { fixture.remove() }
        let configuration = try fixture.configuration(brokerScript: """
            #!/bin/sh
            echo started > '\(fixture.startedFlag.path)'
            exit 1
            """)
        let listener = try fixture.listenWithoutReplying()
        defer { close(listener) }

        await #expect(throws: BrokerUnresponsiveError.self) {
            _ = try await BrokerKeepalive.tick(
                configuration: configuration,
                priorUnanswered: BrokerKeepalive.unansweredLimit - 1,
                pingTimeoutSeconds: 0.2
            )
        }
        #expect(FileManager.default.fileExists(atPath: fixture.startedFlag.path) == false)
    }
    #endif
}

private struct KeepaliveFixture {
    let root: URL

    init() throws {
        // Short path: Unix socket paths are limited to about 104 bytes.
        root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("wxka-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    var socketPath: String { root.appendingPathComponent("broker.sock").path }
    var startedFlag: URL { root.appendingPathComponent("started") }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func configuration(brokerScript: String) throws -> AgentBrokerConfiguration {
        let broker = root.appendingPathComponent("canary-broker")
        try brokerScript.write(to: broker, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: broker.path)
        return AgentBrokerConfiguration(
            brokerExecutablePath: broker.path,
            storePath: root.appendingPathComponent("store.wax").path,
            sessionRootPath: root.appendingPathComponent("sessions").path,
            socketPath: socketPath,
            embedderChoice: "minilm",
            noEmbedder: true,
            requireVector: false,
            embedderTuning: CommandLineEmbedderRuntimeTuning()
        )
    }

    #if canImport(Darwin)
    /// Binds and listens but never accepts, so connects succeed and reads time out.
    func listenWithoutReplying() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw KeepaliveFixtureError("socket failed") }
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            for (index, byte) in bytes.enumerated() {
                buffer[index] = byte
            }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 8) == 0 else {
            close(fd)
            throw KeepaliveFixtureError("bind/listen failed at \(socketPath)")
        }
        return fd
    }
    #endif
}

private struct KeepaliveFixtureError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
