import Foundation
import Testing
@testable import Wax

/// Two `wax-mcp` servers started with the same `--store-path` must find the
/// same broker socket, whether or not the store file existed when each started.
@Suite struct BrokerSocketPathingTests {
    /// Foundation drops a leading `/private` from a path only when the shorter
    /// path exists, so a store under `/private/tmp` used to standardize to
    /// `/private/tmp/...` before it was created and `/tmp/...` after.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: "/private/tmp")))
    func socketIsStableAcrossStoreCreationUnderPrivateTmp() throws {
        let root = "/private/tmp/wax-socket-key-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let storePath = root + "/m.wax"

        func configuration() throws -> AgentBrokerConfiguration {
            try AgentBrokerPathing.configuration(
                brokerExecutablePath: "/usr/bin/true", storePath: storePath,
                socketRootPath: root + "/sockets",
                embedderChoice: "auto", noEmbedder: true, environment: [:]
            )
        }

        let beforeCreation = try configuration()
        #expect(FileManager.default.createFile(atPath: storePath, contents: Data()))
        let afterCreation = try configuration()

        #expect(beforeCreation.storePath == afterCreation.storePath)
        #expect(beforeCreation.sessionRootPath == afterCreation.sessionRootPath)
        #expect(beforeCreation.socketPath == afterCreation.socketPath)
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: "/private/tmp")))
    func missingDirectoriesExpandLikeCreatedOnes() throws {
        let root = "/private/tmp/wax-socket-key-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let nested = root + "/a/b/m.wax"

        let beforeCreation = AgentBrokerPathing.expandPath(nested)
        try FileManager.default.createDirectory(atPath: root + "/a/b", withIntermediateDirectories: true)
        #expect(FileManager.default.createFile(atPath: nested, contents: Data()))

        #expect(beforeCreation == AgentBrokerPathing.expandPath(nested))
    }

    /// Paths with no symlinked prefix, like the default `~/.wax/memory.wax`,
    /// keep the form they always had, so an upgrade does not move the session
    /// root or socket key of an existing install.
    @Test func pathsWithoutSymlinkedPrefixAreUnchanged() {
        for raw in [AgentBrokerPathing.defaultStorePath, "~/.wax/never-created-\(UUID().uuidString)/m.wax"] {
            let expanded = (raw as NSString).expandingTildeInPath
            let legacy = URL(fileURLWithPath: expanded).standardizedFileURL.path
            #expect(AgentBrokerPathing.expandPath(raw) == legacy)
        }
    }
}
