import Foundation
import Testing
@testable import wax_cli

@Suite("MCPHostSetup")
struct MCPHostSetupTests {
    // MARK: - Cursor

    @Test func cursorMergeCreatesMissingConfig() throws {
        try withHostTempRoot { root in
            let config = root.appendingPathComponent(".cursor/mcp.json")
            let result = try CursorSetup.merge(entry: hostSampleEntry(), at: config)
            #expect(result.mutated)
            let rendered = try String(contentsOf: config, encoding: .utf8)
            #expect(rendered.contains("\"mcpServers\""))
            #expect(rendered.contains("\"wax\""))
            #expect(!rendered.contains("stdio"))
            #expect(rendered.contains(hostSampleEntry().command))
        }
    }

    @Test func cursorMergePreservesAndIsIdempotent() throws {
        try withHostTempRoot { root in
            let config = root.appendingPathComponent("mcp.json")
            try Data(#"{"mcpServers": {"other": {"command": "o", "args": []}}}"#.utf8).write(to: config)
            let first = try CursorSetup.merge(entry: hostSampleEntry(), at: config)
            #expect(first.mutated)
            let rendered = try String(contentsOf: config, encoding: .utf8)
            #expect(rendered.contains("\"other\""))
            let second = try CursorSetup.merge(entry: hostSampleEntry(), at: config)
            #expect(!second.mutated)
        }
    }

    @Test func cursorMergeRejectsMalformed() throws {
        try withHostTempRoot { root in
            let config = root.appendingPathComponent("mcp.json")
            try Data("{oops".utf8).write(to: config)
            #expect(throws: CursorSetupError.malformedJSON) {
                try CursorSetup.merge(entry: hostSampleEntry(), at: config)
            }
        }
    }

    @Test func cursorUnmergeRemovesEntryAndKeepsOthers() throws {
        try withHostTempRoot { root in
            let config = root.appendingPathComponent("mcp.json")
            _ = try CursorSetup.merge(entry: hostSampleEntry(), at: config)
            let result = try CursorSetup.unmerge(name: "wax", at: config)
            #expect(result.mutated)
            let rendered = try String(contentsOf: config, encoding: .utf8)
            #expect(!rendered.contains("\"wax\""))
            #expect(rendered.contains("\"mcpServers\""))
            let again = try CursorSetup.unmerge(name: "wax", at: config)
            #expect(!again.mutated)
        }
    }

    @Test func cursorUnmergeMissingFileIsNoop() throws {
        try withHostTempRoot { root in
            let config = root.appendingPathComponent("mcp.json")
            let result = try CursorSetup.unmerge(name: "wax", at: config)
            #expect(!result.mutated)
        }
    }

    @Test func cursorHasEntryReadsRegistration() throws {
        try withHostTempRoot { root in
            let missing = root.appendingPathComponent("missing.json")
            #expect(try CursorSetup.hasEntry(name: "wax", at: missing) == false)
            let config = root.appendingPathComponent("mcp.json")
            try Data(#"{"mcpServers": {}}"#.utf8).write(to: config)
            #expect(try CursorSetup.hasEntry(name: "wax", at: config) == false)
            _ = try CursorSetup.merge(entry: hostSampleEntry(), at: config)
            #expect(try CursorSetup.hasEntry(name: "wax", at: config))
        }
    }

    // MARK: - Muse unmerge

    @Test func museUnmergeRemovesEntryAndPreservesRest() throws {
        try withHostTempRoot { root in
            let settings = root.appendingPathComponent("settings.json")
            _ = try MuseSetup.merge(entry: hostSampleEntry(), at: settings)
            let result = try MuseSetup.unmerge(name: "wax", at: settings)
            #expect(result.mutated)
            let rendered = try String(contentsOf: settings, encoding: .utf8)
            #expect(!rendered.contains("\"wax\""))
            #expect(rendered.contains("\"schema_version\""))
            let again = try MuseSetup.unmerge(name: "wax", at: settings)
            #expect(!again.mutated)
        }
    }

    @Test func museUnmergeMissingFileIsNoop() throws {
        try withHostTempRoot { root in
            let settings = root.appendingPathComponent("settings.json")
            let result = try MuseSetup.unmerge(name: "wax", at: settings)
            #expect(!result.mutated)
        }
    }

    @Test func museHasEntryReadsRegistration() throws {
        try withHostTempRoot { root in
            let missing = root.appendingPathComponent("missing.json")
            #expect(try MuseSetup.hasEntry(name: "wax", at: missing) == false)
            let settings = root.appendingPathComponent("settings.json")
            _ = try MuseSetup.merge(entry: hostSampleEntry(), at: settings)
            #expect(try MuseSetup.hasEntry(name: "wax", at: settings))
            #expect(try MuseSetup.hasEntry(name: "other", at: settings) == false)
        }
    }

    // MARK: - Codex

    @Test func codexSnippetRendersStdioBlock() {
        let snippet = CodexSetup.snippet(for: hostSampleEntry())
        #expect(snippet.contains("[mcp_servers.wax]"))
        #expect(snippet.contains("command = \"/opt/waxmcp/wax-mcp\""))
        #expect(snippet.contains("args = [\"--store-path\", \"/Users/probe/.wax/memory.wax\"]"))
        #expect(snippet.contains("[mcp_servers.wax.env]"))
        #expect(snippet.contains("WAX_MCP_FEATURE_LICENSE = \"0\""))
        #expect(snippet.hasSuffix("\n"))
    }

    @Test func codexSnippetEscapesQuotes() {
        let entry = MuseSetup.ServerEntry(
            name: "wax",
            command: "/we\"ird/wax-mcp",
            args: ["--store-path", "/x"],
            env: [("K", "a\"b\\c")],
            mode: "optional"
        )
        let snippet = CodexSetup.snippet(for: entry)
        #expect(snippet.contains(#"command = "/we\"ird/wax-mcp""#))
        #expect(snippet.contains(#"K = "a\"b\\c""#))
    }

    @Test func codexWriteCreatesMissingConfig() throws {
        try withHostTempRoot { root in
            let config = root.appendingPathComponent(".codex/config.toml")
            let result = try CodexSetup.write(entry: hostSampleEntry(), at: config)
            #expect(result.mutated)
            let rendered = try String(contentsOf: config, encoding: .utf8)
            #expect(rendered == CodexSetup.snippet(for: hostSampleEntry()))
        }
    }

    @Test func codexWriteAppendsAndIsIdempotent() throws {
        try withHostTempRoot { root in
            let config = root.appendingPathComponent("config.toml")
            try Data("[other]\nkey = 1\n".utf8).write(to: config)
            let first = try CodexSetup.write(entry: hostSampleEntry(), at: config)
            #expect(first.mutated)
            let rendered = try String(contentsOf: config, encoding: .utf8)
            #expect(rendered.contains("[other]"))
            #expect(rendered.contains("[mcp_servers.wax]"))
            let second = try CodexSetup.write(entry: hostSampleEntry(), at: config)
            #expect(!second.mutated)
        }
    }

    @Test func codexWriteFailsClosedOnDifferingBlock() throws {
        try withHostTempRoot { root in
            let config = root.appendingPathComponent("config.toml")
            try Data("[mcp_servers.wax]\ncommand = \"/elsewhere\"\n".utf8).write(to: config)
            #expect(throws: CodexSetupError.self) {
                try CodexSetup.write(entry: hostSampleEntry(), at: config)
            }
            let rendered = try String(contentsOf: config, encoding: .utf8)
            #expect(rendered.contains("/elsewhere"))
        }
    }

    @Test func codexUnmergeRemovesVerbatimBlockOnly() throws {
        try withHostTempRoot { root in
            let config = root.appendingPathComponent("config.toml")
            try Data("[other]\nkey = 1\n".utf8).write(to: config)
            _ = try CodexSetup.write(entry: hostSampleEntry(), at: config)
            let result = try CodexSetup.unmerge(name: "wax", entry: hostSampleEntry(), at: config)
            #expect(result.mutated)
            let rendered = try String(contentsOf: config, encoding: .utf8)
            #expect(rendered.contains("[other]"))
            #expect(!rendered.contains("mcp_servers.wax"))
        }
    }

    @Test func codexHasEntryReadsTablePresence() throws {
        try withHostTempRoot { root in
            let missing = root.appendingPathComponent("missing.toml")
            #expect(try CodexSetup.hasEntry(name: "wax", at: missing) == false)
            let config = root.appendingPathComponent("config.toml")
            try Data("[other]\n".utf8).write(to: config)
            #expect(try CodexSetup.hasEntry(name: "wax", at: config) == false)
            _ = try CodexSetup.write(entry: hostSampleEntry(), at: config)
            #expect(try CodexSetup.hasEntry(name: "wax", at: config))
        }
    }

    @Test func grokSnippetRendersInlineEnvAndEnabled() {
        let snippet = GrokSetup.snippet(for: hostSampleEntry())
        #expect(snippet.contains("[mcp_servers.wax]"))
        #expect(snippet.contains("command = \"/opt/waxmcp/wax-mcp\""))
        #expect(snippet.contains("args = [\"--store-path\", \"/Users/probe/.wax/memory.wax\"]"))
        #expect(snippet.contains("env = { WAX_MCP_FEATURE_LICENSE = \"0\" }"))
        #expect(snippet.contains("enabled = true"))
        #expect(snippet.hasSuffix("\n"))
    }

    @Test func grokWriteAppendsAndFailsClosedOnDifferingBlock() throws {
        try withHostTempRoot { root in
            let config = root.appendingPathComponent("config.toml")
            try Data("[other]\nkey = 1\n".utf8).write(to: config)
            let first = try GrokSetup.write(entry: hostSampleEntry(), at: config)
            #expect(first.mutated)
            let rendered = try String(contentsOf: config, encoding: .utf8)
            #expect(rendered.contains("[other]"))
            #expect(rendered.contains("[mcp_servers.wax]"))
            let second = try GrokSetup.write(entry: hostSampleEntry(), at: config)
            #expect(!second.mutated)

            let edited = root.appendingPathComponent("edited.toml")
            try Data("[mcp_servers.wax]\ncommand = \"/elsewhere\"\n".utf8).write(to: edited)
            #expect(throws: GrokSetupError.self) {
                try GrokSetup.write(entry: hostSampleEntry(), at: edited)
            }
        }
    }

    @Test func grokHasEntryReadsTablePresence() throws {
        try withHostTempRoot { root in
            let missing = root.appendingPathComponent("missing.toml")
            #expect(try GrokSetup.hasEntry(name: "wax", at: missing) == false)
            let config = root.appendingPathComponent("config.toml")
            try Data("[other]\n".utf8).write(to: config)
            #expect(try GrokSetup.hasEntry(name: "wax", at: config) == false)
            _ = try GrokSetup.write(entry: hostSampleEntry(), at: config)
            #expect(try GrokSetup.hasEntry(name: "wax", at: config))
        }
    }

    @Test func openCodeMergeWritesLocalEntryAndUnmerges() throws {
        try withHostTempRoot { root in
            let config = root.appendingPathComponent("opencode.json")
            let first = try OpenCodeSetup.merge(entry: hostSampleEntry(), at: config)
            #expect(first.mutated)
            let rendered = try String(contentsOf: config, encoding: .utf8)
            #expect(rendered.contains("\"mcp\""))
            #expect(rendered.contains("\"type\""))
            #expect(rendered.contains("\"local\""))
            #expect(rendered.contains("\"environment\""))
            #expect(rendered.contains("\"enabled\""))
            #expect(rendered.contains("60000"))
            #expect(rendered.contains(hostSampleEntry().command))
            let second = try OpenCodeSetup.merge(entry: hostSampleEntry(), at: config)
            #expect(!second.mutated)
            #expect(try OpenCodeSetup.hasEntry(name: "wax", at: config))
            let removed = try OpenCodeSetup.unmerge(name: "wax", at: config)
            #expect(removed.mutated)
            #expect(try OpenCodeSetup.hasEntry(name: "wax", at: config) == false)
        }
    }

    @Test func openCodeMergeRefusesJSONC() throws {
        try withHostTempRoot { root in
            let jsonc = root.appendingPathComponent("opencode.jsonc")
            try Data("{ // comment\n}\n".utf8).write(to: jsonc)
            let config = root.appendingPathComponent("opencode.json")
            #expect(throws: OpenCodeSetupError.self) {
                try OpenCodeSetup.merge(entry: hostSampleEntry(), at: config)
            }
            #expect(throws: OpenCodeSetupError.self) {
                try OpenCodeSetup.merge(entry: hostSampleEntry(), at: jsonc)
            }
            #expect(!FileManager.default.fileExists(atPath: config.path))
        }
    }

    @Test func codexUnmergeFailsClosedOnEditedBlock() throws {
        try withHostTempRoot { root in
            let config = root.appendingPathComponent("config.toml")
            _ = try CodexSetup.write(entry: hostSampleEntry(), at: config)
            let edited = try String(contentsOf: config, encoding: .utf8)
                .replacingOccurrences(of: "[mcp_servers.wax]\n", with: "[mcp_servers.wax]\n# operator note\n")
            try Data(edited.utf8).write(to: config)
            #expect(throws: CodexSetupError.self) {
                try CodexSetup.unmerge(name: "wax", entry: hostSampleEntry(), at: config)
            }
        }
    }
}

private func hostSampleEntry() -> MuseSetup.ServerEntry {
    MuseSetup.makeEntry(
        name: "wax",
        serverPath: "/opt/waxmcp/wax-mcp",
        storePath: "/Users/probe/.wax/memory.wax",
        env: [("WAX_MCP_FEATURE_LICENSE", "0")],
        noEmbedder: false,
        featureLicense: false
    )
}

private func withHostTempRoot(_ body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-host-setup-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root)
}
