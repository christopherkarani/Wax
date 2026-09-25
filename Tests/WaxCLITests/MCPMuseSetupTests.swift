import Foundation
import Testing
@testable import wax_cli

@Suite("MCPMuseSetup")
struct MCPMuseSetupTests {
    @Test func settingsURLHonorsXDGConfigHome() {
        let url = MuseSetup.settingsURL(
            environment: ["XDG_CONFIG_HOME": "/tmp/xdg-probe"],
            homeDirectory: URL(fileURLWithPath: "/Users/probe")
        )
        #expect(url.path == "/tmp/xdg-probe/muse/settings.json")
    }

    @Test func settingsURLFallsBackToHomeConfig() {
        let url = MuseSetup.settingsURL(
            environment: [:],
            homeDirectory: URL(fileURLWithPath: "/Users/probe")
        )
        #expect(url.path == "/Users/probe/.config/muse/settings.json")
    }

    @Test func skillsDirectoryHonorsXDGConfigHome() {
        let overlay = MuseSetup.skillsDirectory(
            environment: ["XDG_CONFIG_HOME": "/tmp/xdg-probe"],
            homeDirectory: URL(fileURLWithPath: "/Users/probe")
        )
        #expect(overlay.path == "/tmp/xdg-probe/muse/skills")
        let fallback = MuseSetup.skillsDirectory(
            environment: [:],
            homeDirectory: URL(fileURLWithPath: "/Users/probe")
        )
        #expect(fallback.path == "/Users/probe/.config/muse/skills")
    }

    @Test func settingsURLIgnoresBlankXDGConfigHome() {
        let url = MuseSetup.settingsURL(
            environment: ["XDG_CONFIG_HOME": "   "],
            homeDirectory: URL(fileURLWithPath: "/Users/probe")
        )
        #expect(url.path == "/Users/probe/.config/muse/settings.json")
    }

    @Test func makeEntryBuildsStdioCommand() {
        let entry = MuseSetup.makeEntry(
            name: "wax",
            serverPath: "/opt/waxmcp/wax-mcp",
            storePath: "/Users/probe/.wax/memory.wax",
            env: [("WAX_MCP_FEATURE_LICENSE", "0")],
            noEmbedder: true,
            featureLicense: false
        )
        #expect(entry.command == "/opt/waxmcp/wax-mcp")
        #expect(entry.args == ["--store-path", "/Users/probe/.wax/memory.wax", "--no-embedder"])
        #expect(entry.mode == "optional")
    }

    @Test func mergeCreatesMissingSettingsFile() throws {
        try withMuseTempRoot { root in
            let settings = root.appendingPathComponent("muse/settings.json")
            let result = try MuseSetup.merge(entry: sampleEntry(), at: settings)
            #expect(result.mutated)

            let rendered = try String(contentsOf: settings, encoding: .utf8)
            #expect(rendered.contains("\"schema_version\""))
            #expect(rendered.contains("\"mcp_servers\""))
            #expect(rendered.contains("\"wax\""))
            #expect(rendered.contains("\"transport\""))
            #expect(rendered.contains("stdio"))
            #expect(rendered.contains("\"mode\""))
            #expect(rendered.contains("optional"))
            #expect(try posixPermissions(of: settings) == 0o600)
        }
    }

    @Test func mergePreservesExistingKeysAndServers() throws {
        try withMuseTempRoot { root in
            let settings = root.appendingPathComponent("settings.json")
            try Data(
                """
                {"schema_version": 1, "model": "muse-spark", "mcp_servers": {"other": {"transport": "stdio", "command": "other-bin", "args": []}}}
                """.utf8
            ).write(to: settings)

            let result = try MuseSetup.merge(entry: sampleEntry(), at: settings)
            #expect(result.mutated)

            let rendered = try String(contentsOf: settings, encoding: .utf8)
            #expect(rendered.contains("muse-spark"))
            #expect(rendered.contains("\"other\""))
            #expect(rendered.contains("other-bin"))
            #expect(rendered.contains("\"wax\""))
        }
    }

    @Test func mergeIsIdempotent() throws {
        try withMuseTempRoot { root in
            let settings = root.appendingPathComponent("settings.json")
            let first = try MuseSetup.merge(entry: sampleEntry(), at: settings)
            #expect(first.mutated)
            let second = try MuseSetup.merge(entry: sampleEntry(), at: settings)
            #expect(!second.mutated)
        }
    }

    @Test func mergeOverwritesStaleEntry() throws {
        try withMuseTempRoot { root in
            let settings = root.appendingPathComponent("settings.json")
            let stale = MuseSetup.makeEntry(
                name: "wax",
                serverPath: "/old/path/wax-mcp",
                storePath: "/old/store.wax",
                env: [],
                noEmbedder: false,
                featureLicense: false
            )
            _ = try MuseSetup.merge(entry: stale, at: settings)
            let result = try MuseSetup.merge(entry: sampleEntry(), at: settings)
            #expect(result.mutated)
            let rendered = try String(contentsOf: settings, encoding: .utf8)
            #expect(!rendered.contains("/old/path/wax-mcp"))
            #expect(rendered.contains(sampleEntry().command))
        }
    }

    @Test func mergeRejectsMalformedJSON() throws {
        try withMuseTempRoot { root in
            let settings = root.appendingPathComponent("settings.json")
            try Data("{not json".utf8).write(to: settings)
            #expect(throws: MuseSetupError.malformedJSON) {
                try MuseSetup.merge(entry: sampleEntry(), at: settings)
            }
        }
    }

    @Test func mergeRejectsMissingSchemaVersion() throws {
        try withMuseTempRoot { root in
            let settings = root.appendingPathComponent("settings.json")
            try Data(#"{"model": "x"}"#.utf8).write(to: settings)
            #expect(throws: MuseSetupError.missingSchemaVersion) {
                try MuseSetup.merge(entry: sampleEntry(), at: settings)
            }
        }
    }

    @Test func mergeRejectsUnsupportedSchemaVersion() throws {
        try withMuseTempRoot { root in
            let settings = root.appendingPathComponent("settings.json")
            try Data(#"{"schema_version": 2}"#.utf8).write(to: settings)
            #expect(throws: MuseSetupError.unsupportedSchemaVersion("2")) {
                try MuseSetup.merge(entry: sampleEntry(), at: settings)
            }
        }
    }

    @Test func mergeRejectsNonObjectServersBlock() throws {
        try withMuseTempRoot { root in
            let settings = root.appendingPathComponent("settings.json")
            try Data(#"{"schema_version": 1, "mcp_servers": []}"#.utf8).write(to: settings)
            #expect(throws: MuseSetupError.malformedJSON) {
                try MuseSetup.merge(entry: sampleEntry(), at: settings)
            }
        }
    }

    @Test func mergeRefusesSymlinkedSettings() throws {
        try withMuseTempRoot { root in
            let target = root.appendingPathComponent("real-settings.json")
            try Data(#"{"schema_version": 1}"#.utf8).write(to: target)
            let link = root.appendingPathComponent("settings.json")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            #expect(throws: HostHookError.symlinkConfig) {
                try MuseSetup.merge(entry: sampleEntry(), at: link)
            }
        }
    }
}

private func sampleEntry() -> MuseSetup.ServerEntry {
    MuseSetup.makeEntry(
        name: "wax",
        serverPath: "/opt/waxmcp/wax-mcp",
        storePath: "/Users/probe/.wax/memory.wax",
        env: [("WAX_MCP_FEATURE_LICENSE", "0")],
        noEmbedder: false,
        featureLicense: false
    )
}

private func withMuseTempRoot(_ body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-muse-setup-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root)
}

private func posixPermissions(of url: URL) throws -> UInt16 {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return ((attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0) & 0o777
}
