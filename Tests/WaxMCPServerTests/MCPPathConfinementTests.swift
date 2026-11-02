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
        MCPPathConfinement(fixedRoots: [store.path])
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
#endif
