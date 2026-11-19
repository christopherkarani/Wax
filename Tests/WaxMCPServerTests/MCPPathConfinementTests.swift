#if MCPServer
import Foundation
import MCP
import Testing
@testable import Wax
@testable import wax_mcp

private struct ConfinementFixture {
    let root: URL
    let store: URL
    let project: URL
    let outside: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-confine-\(UUID().uuidString)", isDirectory: true)
        root = base
        store = base.appendingPathComponent("store", isDirectory: true)
        project = base.appendingPathComponent("project", isDirectory: true)
        outside = base.appendingPathComponent("outside", isDirectory: true)
        for directory in [store, project, outside] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    var confinement: MCPPathConfinement {
        MCPPathConfinement(fixedRoots: [store.path], storeDirectory: store.path)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func errorCode(_ result: CallTool.Result) -> String? {
    guard case .text(let text, _, _)? = result.content.first,
          let data = text.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return object["code"] as? String
}

@Test
func pathConfinementAcceptsPathsInsideStoreAndProjectRoots() throws {
    let fixture = try ConfinementFixture()
    defer { fixture.cleanup() }

    let inStore = try fixture.confinement.confine(
        argument: "output_dir",
        path: fixture.store.appendingPathComponent("export/nested").path,
        projectRoots: []
    )
    #expect(inStore.hasSuffix("/store/export/nested"))

    let inProject = try fixture.confinement.confine(
        argument: "output_dir",
        path: fixture.project.appendingPathComponent("notes").path,
        projectRoots: [fixture.project.path]
    )
    #expect(inProject.hasSuffix("/project/notes"))
}

@Test
func pathConfinementRejectsDotDotTraversal() throws {
    let fixture = try ConfinementFixture()
    defer { fixture.cleanup() }

    let traversal = fixture.store.path + "/../outside/escape"
    #expect(throws: MCPPathConfinementError.self) {
        try fixture.confinement.confine(argument: "output_dir", path: traversal, projectRoots: [])
    }
}

@Test
func pathConfinementRejectsAbsolutePathOutsideRoots() throws {
    let fixture = try ConfinementFixture()
    defer { fixture.cleanup() }

    #expect(throws: MCPPathConfinementError.self) {
        try fixture.confinement.confine(argument: "output_dir", path: fixture.outside.path, projectRoots: [])
    }
    #expect(throws: MCPPathConfinementError.self) {
        try fixture.confinement.confine(argument: "output_dir", path: "/etc", projectRoots: [])
    }
}

@Test
func pathConfinementRejectsRelativePaths() throws {
    let fixture = try ConfinementFixture()
    defer { fixture.cleanup() }

    #expect(throws: MCPPathConfinementError.self) {
        try fixture.confinement.confine(argument: "output_dir", path: "export", projectRoots: [])
    }
}

@Test
func pathConfinementRejectsSymlinkEscape() throws {
    let fixture = try ConfinementFixture()
    defer { fixture.cleanup() }

    let link = fixture.store.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.outside)
    #expect(throws: MCPPathConfinementError.self) {
        try fixture.confinement.confine(argument: "output_dir", path: link.path, projectRoots: [])
    }
    #expect(throws: MCPPathConfinementError.self) {
        try fixture.confinement.confine(
            argument: "output_dir",
            path: link.appendingPathComponent("child").path,
            projectRoots: []
        )
    }

    let dangling = fixture.store.appendingPathComponent("dangling")
    try FileManager.default.createSymbolicLink(
        at: dangling,
        withDestinationURL: fixture.outside.appendingPathComponent("missing")
    )
    #expect(throws: MCPPathConfinementError.self) {
        try fixture.confinement.confine(argument: "destination_path", path: dangling.path, projectRoots: [])
    }
}

@Test
func stdioConfinementIncludesProcessDirectoryAndHTTPDoesNot() throws {
    let fixture = try ConfinementFixture()
    defer { fixture.cleanup() }
    func confinement(for transport: MCPServedTransport) -> MCPPathConfinement {
        MCPPathConfinement(
            storeURL: fixture.store.appendingPathComponent("memory.wax"),
            sessionRootURL: fixture.store.appendingPathComponent("sessions"),
            includeProcessDirectory: transport.includesProcessDirectory
        )
    }
    let inWorkingDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("wax-confine-probe-\(UUID().uuidString)")
        .path

    let confined = try confinement(for: .stdio).confine(
        argument: "output_dir",
        path: inWorkingDirectory,
        projectRoots: []
    )
    #expect(confined.hasSuffix((inWorkingDirectory as NSString).lastPathComponent))
    #expect(throws: MCPPathConfinementError.self) {
        try confinement(for: .http).confine(argument: "output_dir", path: inWorkingDirectory, projectRoots: [])
    }
}

@Test
func pathConfinementIgnoresFilesystemRootAsAllowedRoot() throws {
    let confinement = MCPPathConfinement(fixedRoots: ["/"])
    #expect(throws: MCPPathConfinementError.self) {
        try confinement.confine(argument: "output_dir", path: "/etc", projectRoots: ["/"])
    }
}

@Test
func mcpPathToolsRejectOutsidePathsBeforeReachingBroker() async throws {
    let fixture = try ConfinementFixture()
    defer { fixture.cleanup() }
    let broker = try await AgentBrokerService(
        storePath: fixture.store.appendingPathComponent("memory.wax").path,
        sessionRootPath: fixture.store.appendingPathComponent("sessions").path,
        noEmbedder: true,
        embedderChoice: "auto",
        requireVector: false
    )
    defer { Task { try? await broker.close() } }

    let escapedExport = fixture.outside.appendingPathComponent("export", isDirectory: true)
    let cases: [(String, [String: Value])] = [
        ("markdown_export", ["output_dir": .string(escapedExport.path)]),
        ("markdown_export", ["output_dir": .string(fixture.store.path + "/../outside/export2")]),
        ("markdown_sync", ["root_dir": .string(fixture.outside.path)]),
        ("task_state_migrate", ["destination_path": .string(fixture.outside.appendingPathComponent("x.wax").path)]),
    ]
    for (name, arguments) in cases {
        let result = await WaxMCPTools.handleCall(
            params: .init(name: name, arguments: arguments),
            broker: broker,
            pathConfinement: fixture.confinement
        )
        #expect(result.isError ?? false, "\(name) must be rejected")
        #expect(errorCode(result) == "path_not_allowed", "\(name) must fail with path_not_allowed")
    }
    #expect(!FileManager.default.fileExists(atPath: escapedExport.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.outside.appendingPathComponent("export2").path))

    let allowedExport = fixture.store.appendingPathComponent("export", isDirectory: true)
    let allowed = await WaxMCPTools.handleCall(
        params: .init(name: "markdown_export", arguments: ["output_dir": .string(allowedExport.path)]),
        broker: broker,
        pathConfinement: fixture.confinement
    )
    #expect(!(allowed.isError ?? false))
    #expect(FileManager.default.fileExists(atPath: allowedExport.appendingPathComponent("MEMORY.md").path))
}

private extension ConfinementFixture {
    /// Workspace roots cover the store and project; migration may only
    /// target the store directory.
    var migrationConfinement: MCPPathConfinement {
        MCPPathConfinement(fixedRoots: [store.path, project.path], storeDirectory: store.path)
    }

    func makeBroker() async throws -> AgentBrokerService {
        try await AgentBrokerService(
            storePath: store.appendingPathComponent("memory.wax").path,
            sessionRootPath: store.appendingPathComponent("sessions").path,
            noEmbedder: true,
            embedderChoice: "auto",
            requireVector: false
        )
    }
}

@Test
func migrationDestinationIsConfinedToStoreDirectory() throws {
    let fixture = try ConfinementFixture()
    defer { fixture.cleanup() }
    let confinement = fixture.migrationConfinement

    let inStore = try confinement.confineMigrationDestination(
        path: fixture.store.appendingPathComponent("repaired.wax").path
    )
    #expect(inStore.hasSuffix("/store/repaired.wax"))
    // Workspace and host roots are fine for Markdown, never for a store copy.
    #expect(throws: MCPPathConfinementError.self) {
        try confinement.confineMigrationDestination(path: fixture.project.appendingPathComponent("repaired.wax").path)
    }
    #expect(throws: MCPPathConfinementError.self) {
        try MCPPathConfinement.denyAll.confineMigrationDestination(
            path: fixture.store.appendingPathComponent("repaired.wax").path
        )
    }
}

@Test
func migrationDestinationRequiresWaxExtension() throws {
    let fixture = try ConfinementFixture()
    defer { fixture.cleanup() }

    #expect(throws: MCPPathConfinementError.self) {
        try fixture.migrationConfinement.confineMigrationDestination(
            path: fixture.store.appendingPathComponent("precious.swift").path
        )
    }
    #expect(throws: MCPPathConfinementError.self) {
        try fixture.migrationConfinement.confineMigrationDestination(path: fixture.store.path)
    }
}

@Test
func migrationDestinationOnlyOverwritesExistingWaxStores() throws {
    let fixture = try ConfinementFixture()
    defer { fixture.cleanup() }

    let notAStore = fixture.store.appendingPathComponent("notes.wax")
    try Data("precious".utf8).write(to: notAStore)
    #expect(throws: MCPPathConfinementError.self) {
        try fixture.migrationConfinement.confineMigrationDestination(path: notAStore.path)
    }

    let previousCopy = fixture.store.appendingPathComponent("previous.wax")
    try (Data("WAX1".utf8) + Data(repeating: 0, count: 64)).write(to: previousCopy)
    #expect(throws: Never.self) {
        try fixture.migrationConfinement.confineMigrationDestination(path: previousCopy.path)
    }
}

@Test
func migrationDestinationRefusesSessionRootAndSourceStore() throws {
    let fixture = try ConfinementFixture()
    defer { fixture.cleanup() }
    let storeURL = fixture.store.appendingPathComponent("memory.wax")
    let sessionRoot = fixture.store.appendingPathComponent("sessions-0123abcd", isDirectory: true)
    try FileManager.default.createDirectory(at: sessionRoot, withIntermediateDirectories: true)
    let confinement = MCPPathConfinement(
        storeURL: storeURL,
        sessionRootURL: sessionRoot,
        includeProcessDirectory: false
    )
    let waxHeader = Data("WAX1".utf8) + Data(repeating: 0, count: 64)
    let sessionStore = sessionRoot.appendingPathComponent("\(UUID().uuidString).wax")
    try waxHeader.write(to: sessionStore)
    try waxHeader.write(to: storeURL)

    for refused in [sessionStore, sessionRoot.appendingPathComponent("fresh.wax"), storeURL] {
        #expect(throws: MCPPathConfinementError.self, "\(refused.lastPathComponent) must be refused") {
            try confinement.confineMigrationDestination(path: refused.path)
        }
    }

    // Other Wax stores in the store directory may still be replaced, and new ones created.
    let previousCopy = fixture.store.appendingPathComponent("previous.wax")
    try waxHeader.write(to: previousCopy)
    #expect(throws: Never.self) {
        try confinement.confineMigrationDestination(path: previousCopy.path)
        try confinement.confineMigrationDestination(path: fixture.store.appendingPathComponent("repaired.wax").path)
    }
}

@Test
func taskStateMigrateCannotOverwriteSessionStores() async throws {
    let fixture = try ConfinementFixture()
    defer { fixture.cleanup() }
    // An active session whose broker exited (idle shutdown, restart): its
    // store is unlocked on disk and resumable.
    let previousBroker = try await fixture.makeBroker()
    let parkedStore = try await startSession(on: previousBroker, agent: "confine-parked")
    try await previousBroker.close()
    try #require(FileManager.default.fileExists(atPath: parkedStore.path))

    let broker = try await fixture.makeBroker()
    defer { Task { try? await broker.close() } }
    let liveStore = try await startSession(on: broker, agent: "confine-live")

    for sessionStore in [liveStore, parkedStore] {
        let before = try Data(contentsOf: sessionStore)
        for overwrite in [true, false] {
            let result = await WaxMCPTools.handleCall(
                params: .init(name: "task_state_migrate", arguments: [
                    "destination_path": .string(sessionStore.path),
                    "overwrite_destination": .bool(overwrite),
                ]),
                broker: broker
            )
            let label = "\(sessionStore == liveStore ? "live" : "parked") overwrite_destination=\(overwrite)"
            #expect(result.isError ?? false, "\(label) must be refused")
            #expect(errorCode(result) == "path_not_allowed", "\(label): \(result.content)")
        }
        #expect(try Data(contentsOf: sessionStore) == before)
    }
}

private enum ConfinementTestError: Error {
    case sessionStartFailed(String)
}

/// Starts a broker session and returns the path of its session store.
private func startSession(on broker: AgentBrokerService, agent: String) async throws -> URL {
    let started = await broker.handle(AgentBrokerRequest(
        command: "session_start",
        arguments: ["agent_id": .string(agent), "run_id": .string("\(agent)-run")]
    ))
    guard case .success(let payload) = started.outcome,
          let rawID = payload.objectValue?["session_id"]?.stringValue
    else {
        throw ConfinementTestError.sessionStartFailed("\(started)")
    }
    return await broker.sessionRootURL.appendingPathComponent("\(rawID).wax")
}

@Test
func taskStateMigrateCannotOverwriteArbitraryFilesInAllowedRoots() async throws {
    let fixture = try ConfinementFixture()
    defer { fixture.cleanup() }
    let broker = try await fixture.makeBroker()
    defer { Task { try? await broker.close() } }

    let precious = fixture.store.appendingPathComponent("precious.swift")
    let notAStore = fixture.store.appendingPathComponent("notes.wax")
    let projectCopy = fixture.project.appendingPathComponent("copy.wax")
    try Data("let keep = true\n".utf8).write(to: precious)
    try Data("precious".utf8).write(to: notAStore)

    for destination in [precious, notAStore, projectCopy] {
        let result = await WaxMCPTools.handleCall(
            params: .init(name: "task_state_migrate", arguments: [
                "destination_path": .string(destination.path),
                "overwrite_destination": .bool(true),
            ]),
            broker: broker,
            pathConfinement: fixture.migrationConfinement
        )
        #expect(result.isError ?? false, "\(destination.lastPathComponent) must be refused")
        #expect(errorCode(result) == "path_not_allowed")
    }
    #expect(try String(contentsOf: precious, encoding: .utf8) == "let keep = true\n")
    #expect(try String(contentsOf: notAStore, encoding: .utf8) == "precious")
    #expect(!FileManager.default.fileExists(atPath: projectCopy.path))
}

@Test
func brokerAdapterConfinesPathsByDefault() async throws {
    let fixture = try ConfinementFixture()
    defer { fixture.cleanup() }
    let broker = try await fixture.makeBroker()
    defer { Task { try? await broker.close() } }

    let escaped = fixture.outside.appendingPathComponent("export", isDirectory: true)
    let refused = await WaxMCPTools.handleCall(
        params: .init(name: "markdown_export", arguments: ["output_dir": .string(escaped.path)]),
        broker: broker
    )
    #expect(errorCode(refused) == "path_not_allowed")
    #expect(!FileManager.default.fileExists(atPath: escaped.path))

    let inStore = fixture.store.appendingPathComponent("export", isDirectory: true)
    let allowed = await WaxMCPTools.handleCall(
        params: .init(name: "markdown_export", arguments: ["output_dir": .string(inStore.path)]),
        broker: broker
    )
    #expect(!(allowed.isError ?? false))
}

@Test
func pathConfinementFetchesHostRootsBeforeTheFirstCall() async throws {
    let fixture = try ConfinementFixture()
    defer { fixture.cleanup() }
    let broker = try await fixture.makeBroker()
    defer { Task { try? await broker.close() } }

    // roots/list has not been captured yet; the provider is registered.
    let key = "confine-roots-\(UUID().uuidString)"
    let projectPath = fixture.project.path
    MCPRootsProviderRegistry.shared.remember(key: key) { [projectPath] }
    defer { MCPRootsProviderRegistry.shared.remove(key: key) }
    let hint = MCPClientSessionHint(connectionKey: key, context: nil)

    let export = fixture.project.appendingPathComponent("export", isDirectory: true)
    let result = await WaxMCPTools.handleCall(
        params: .init(name: "markdown_export", arguments: [
            "output_dir": .string(export.path),
            "all_projects": .bool(true),
        ]),
        broker: broker,
        sessionHint: hint,
        pathConfinement: fixture.confinement
    )
    #expect(errorCode(result) != "path_not_allowed")
    #expect(FileManager.default.fileExists(atPath: export.appendingPathComponent("MEMORY.md").path))
}
#endif
