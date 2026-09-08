import Foundation
import Testing

/// Operator-doc contract for the Hermes single-surface install path.
///
/// These files are the public guide a fresh agent follows. They must agree
/// with the installed product: native `memory.provider: wax-memory` only,
/// no `plugins.enabled` registration, project-default vs explicit-global
/// recall, and the real doctors / LaunchAgent / launcher commands.
@Suite("Wax MCP single-surface operator docs")
struct WaxMCPSingleSurfaceDocsTests {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private let operatorDocs = [
        "README.md",
        "Resources/docs/wax-mcp-hosts.md",
        "Resources/docs/wax-mcp-setup.md",
        "Resources/npm/waxmcp/README.md",
        "Resources/skills/public/wax-mcp/SKILL.md",
        "Resources/npm/waxmcp/skills/wax-mcp/SKILL.md",
    ]

    private let installPathDocs = [
        "README.md",
        "Resources/docs/wax-mcp-hosts.md",
        "Resources/docs/wax-mcp-setup.md",
        "Resources/npm/waxmcp/README.md",
    ]

    private let skillDocs = [
        "Resources/skills/public/wax-mcp/SKILL.md",
        "Resources/npm/waxmcp/skills/wax-mcp/SKILL.md",
    ]

    @Test func publicAndNpmOperatorSkillsStayByteIdentical() throws {
        let pairs = [
            (
                "Resources/skills/public/wax-mcp/SKILL.md",
                "Resources/npm/waxmcp/skills/wax-mcp/SKILL.md"
            ),
            (
                "Resources/skills/public/wax-mcp/references/project-rules.md",
                "Resources/npm/waxmcp/skills/wax-mcp/references/project-rules.md"
            ),
            (
                "Resources/skills/public/wax-mcp/agents/openai.yaml",
                "Resources/npm/waxmcp/skills/wax-mcp/agents/openai.yaml"
            ),
        ]
        for (lhs, rhs) in pairs {
            let left = try read(lhs)
            let right = try read(rhs)
            #expect(left == right, "\(lhs) must match \(rhs)")
        }
    }

    @Test func operatorDocsRecommendExactlyOneNativeHermesSurface() throws {
        for path in operatorDocs {
            let text = try read(path)
            let namesProvider = text.contains("memory.provider") && text.contains("wax-memory")
            #expect(namesProvider, "\(path) must name memory.provider wax-memory")
            let teachesInstall = text.contains("install-hermes-plugin") || path.hasSuffix("SKILL.md")
            #expect(teachesInstall, "\(path) must teach install-hermes-plugin (skills may point at hosts)")
            assertNoTwoSurfaceSameLine(text, path: path)
        }

        for path in skillDocs {
            let text = try read(path)
            let keepsGenericOffNative = text.contains("do not also register generic MCP")
            #expect(keepsGenericOffNative, "\(path) must keep the generic skill off the native Hermes path")
        }
    }

    @Test func operatorDocsTeachProjectDefaultAndExplicitGlobalRecall() throws {
        for path in operatorDocs {
            let text = try read(path)
            let teachesGlobal = text.contains("scope=global")
                || text.contains("`scope=global`")
                || text.contains("`scope: global`")
            #expect(teachesGlobal, "\(path) must teach explicit scope=global")
            let teachesTrust = text.contains("not an authorization boundary")
                || text.contains("not an authorization")
            #expect(teachesTrust, "\(path) must state that global scope is not an authorization boundary")
        }
    }

    @Test func installDocsMatchLaunchAgentDoctorsAndNativeTools() throws {
        for path in installPathDocs {
            let text = try read(path)
            expectContains(text, "wax_remember", path: path, note: "must name native wax_remember")
            expectContains(text, "wax_recall", path: path, note: "must name native wax_recall")
            expectContains(text, "start-wax-mcp-http.sh", path: path, note: "must name the persistent HTTP launcher")
            expectContains(text, "ai.wax.mcp-http", path: path, note: "must name LaunchAgent ai.wax.mcp-http")
            expectContains(text, "vector-health", path: path, note: "must name vector-health")
            expectContains(text, "hermes wax-memory doctor", path: path, note: "must name hermes wax-memory doctor")
            expectContains(text, "hermes plugins doctor wax-memory", path: path, note: "must name hermes plugins doctor wax-memory")
            let namesCLIDoctor = text.contains("wax-cli mcp doctor") || text.contains("mcp doctor")
            #expect(namesCLIDoctor, "\(path) must name wax-cli mcp doctor")
        }

        let hosts = try read("Resources/docs/wax-mcp-hosts.md")
        let explainsIdentity = hosts.contains("Wax UUID") || hosts.contains("session_id")
        #expect(explainsIdentity, "hosts doc must explain native session identity")
        let modelOmitsUUID = hosts.localizedCaseInsensitiveContains("never supply")
            || hosts.localizedCaseInsensitiveContains("without asking the agent for a Wax UUID")
            || hosts.localizedCaseInsensitiveContains("do not invent")
        #expect(modelOmitsUUID, "hosts doc must say the model does not supply a Wax UUID")
        let hasRecovery = hosts.contains("launchctl kickstart") || hosts.contains("KeepAlive")
        #expect(hasRecovery, "hosts doc must include LaunchAgent restart or KeepAlive recovery")
        let recommendsGenericMCP = hosts.contains("mcp_servers:\n  wax:")
        #expect(!recommendsGenericMCP, "recommended Hermes YAML must not register mcp_servers.wax")
    }

    @Test func genericSkillPointsAtNativeHermesWithoutCopyingMCPLoop() throws {
        for path in skillDocs {
            let text = try read(path)
            let namesNativeTools = text.contains("wax_remember") && text.contains("wax_recall")
            #expect(namesNativeTools, "\(path) must name wax_remember and wax_recall")
            expectContains(text, "hermes wax-memory doctor", path: path, note: "must name hermes wax-memory doctor")
            let pointsAtPersistence = text.contains("ai.wax.mcp-http") || text.contains("wax-mcp-hosts.md")
            #expect(pointsAtPersistence, "\(path) must name LaunchAgent or point at hosts")
            let pointsAtHealth = text.contains("vector-health") || text.contains("wax-mcp-hosts.md")
            #expect(pointsAtHealth, "\(path) must name vector-health or point at hosts")
        }
    }

    private func read(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func expectContains(_ text: String, _ needle: String, path: String, note: String) {
        let found = text.contains(needle)
        #expect(found, "\(path) \(note): missing \(needle)")
    }

    private func assertNoTwoSurfaceSameLine(_ text: String, path: String) {
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let value = String(line)
            let forbidden = matchesTwoSurfaceNeedle(value)
            #expect(
                !forbidden,
                "\(path):\(index + 1) must not combine plugins.enabled with wax-memory or mcp_servers.wax with memory.provider"
            )
        }
    }

    private func matchesTwoSurfaceNeedle(_ line: String) -> Bool {
        // Same gate as W1-U8: `plugins.enabled` then `wax-memory`, or
        // `mcp_servers.wax` then `memory.provider`, on one line.
        if line.range(of: "plugins\\.enabled.*wax-memory", options: .regularExpression) != nil {
            return true
        }
        if line.range(of: "mcp_servers\\.wax.*memory\\.provider", options: .regularExpression) != nil {
            return true
        }
        return false
    }
}
