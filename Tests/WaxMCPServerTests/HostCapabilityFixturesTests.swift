#if MCPServer
import Foundation
import Testing

// T0.4 residual risk (W0 contract gate). These are fail-closed policy pins, not
// runtime toggles. Later waves must not invert them when enabling prime or hooks.
private enum T04ResidualRisk {
    /// Recalled prime text is historical data, never executable instruction.
    static let primeTextIsUntrustedHistoricalData = true
    /// Global person-lane injection requires explicit `--include-person`.
    static let personLaneOffByDefault = true
    /// `Mcp-Session-Id` / stdio keys are client-controlled correlation, not auth.
    static let transportIDsAreNotAuthentication = true
    /// Installer parse, validation, or crash during merge must write nothing.
    static let mergeCrashFailsClosed = true
}

enum HostOwnershipLevel: String, Equatable, Sendable {
    case a = "A"
    case b = "B"
    /// Generic MCP transport owner, with optional read-only prime injection.
    case cPlusOptionalBPrime = "C+optional-B-prime"
}

private enum HostEventClassification {
    static let terminalCapableNames: Set<String> = [
        "SessionEnd",
        "sessionEnd",
        "session.deleted",
    ]

    static let neverCloseNames: Set<String> = [
        "Stop",
        "stop",
        "session.idle",
        "session.compacted",
        "experimental.session.compacting",
    ]

    static func isTerminalCapable(_ eventName: String) -> Bool {
        terminalCapableNames.contains(eventName)
    }

    static func isNonTerminalNeverClose(_ eventName: String) -> Bool {
        neverCloseNames.contains(eventName)
    }
}

struct FixtureSpec: Codable, Equatable, Sendable {
    var relativePath: String
    var host: String
    var eventName: String?
}

@Suite("Host capability fixtures")
struct HostCapabilityFixturesTests {
    static let inventory: [FixtureSpec] = [
        .init(relativePath: "claude/sessionStart.json", host: "claude", eventName: "SessionStart"),
        .init(relativePath: "claude/sessionEnd.json", host: "claude", eventName: "SessionEnd"),
        .init(relativePath: "claude/stop.json", host: "claude", eventName: "Stop"),
        .init(relativePath: "codex/sessionStart.json", host: "codex", eventName: "SessionStart"),
        .init(relativePath: "codex/sessionEnd.json", host: "codex", eventName: "SessionEnd"),
        .init(relativePath: "grok/sessionStart.json", host: "grok", eventName: "SessionStart"),
        .init(relativePath: "grok/sessionEnd.json", host: "grok", eventName: "SessionEnd"),
        .init(relativePath: "cursor/sessionStart.json", host: "cursor", eventName: "sessionStart"),
        .init(relativePath: "cursor/sessionEnd.json", host: "cursor", eventName: "sessionEnd"),
        .init(relativePath: "opencode/sessionDeleted.json", host: "opencode", eventName: "session.deleted"),
        .init(relativePath: "opencode/sessionIdle.json", host: "opencode", eventName: "session.idle"),
        .init(relativePath: "opencode/sessionCompacted.json", host: "opencode", eventName: "session.compacted"),
        .init(
            relativePath: "opencode/systemTransform.json",
            host: "opencode",
            eventName: "experimental.chat.system.transform"
        ),
        .init(relativePath: "openclaw/sdk-names.json", host: "openclaw", eventName: nil),
    ]

    @Test(arguments: Self.inventory)
    func fixtureLoadsAndPinsExactEventName(spec: FixtureSpec) throws {
        let fixture = try loadFixture(spec.relativePath)
        #expect(try fixture.string("host") == spec.host)
        if let expected = spec.eventName {
            #expect(try fixture.string("event_name") == expected)
            #expect(try documentedEventName(in: fixture) == expected)
        } else {
            #expect(fixture.raw["event_name"] == nil)
        }
    }

    @Test(arguments: [
        "claude/stop.json",
        "opencode/sessionIdle.json",
        "opencode/sessionCompacted.json",
    ])
    func stopIdleAndCompactAreNonTerminal(relativePath: String) throws {
        let fixture = try loadFixture(relativePath)
        let eventName = try fixture.string("event_name")
        #expect(HostEventClassification.isNonTerminalNeverClose(eventName))
        #expect(HostEventClassification.isTerminalCapable(eventName) == false)
        #expect(try fixture.bool("terminal_capable") == false)
        #expect(try fixture.bool("never_close") == true)
    }

    @Test(arguments: [
        "claude/sessionEnd.json",
        "codex/sessionEnd.json",
        "grok/sessionEnd.json",
        "cursor/sessionEnd.json",
        "opencode/sessionDeleted.json",
    ])
    func sessionEndAndDeletedAreTerminalCapable(relativePath: String) throws {
        let fixture = try loadFixture(relativePath)
        let eventName = try fixture.string("event_name")
        #expect(HostEventClassification.isTerminalCapable(eventName))
        #expect(try fixture.bool("terminal_capable") == true)
        #expect(try fixture.string("event_name") == documentedEventName(in: fixture))
    }

    @Test(arguments: [
        ("claude", HostOwnershipLevel.cPlusOptionalBPrime),
        ("codex", .cPlusOptionalBPrime),
        ("grok", .cPlusOptionalBPrime),
        ("cursor", .cPlusOptionalBPrime),
        ("opencode", .b),
        ("openclaw", .b),
    ])
    func hostOwnershipMatchesCorrelationEvidence(
        host: String,
        expected: HostOwnershipLevel
    ) throws {
        #expect(try classify(host) == expected)
        let fixtures = try loadHostFixtures(host)
        #expect(!fixtures.isEmpty)
        for fixture in fixtures {
            let correlation = try fixture.object("correlation")
            #expect(try correlation.bool("propagates_into_every_wax_read_write") == false)
            #expect(try correlation.bool("owns_all_wax_reads_writes") == false)
        }
    }

    @Test
    func hermesIsLevelAWithoutInventingHermesFixtures() throws {
        let hermes = try loadHostFixtures("hermes")
        #expect(hermes.isEmpty, "T0.1 must not invent Hermes fixtures")
        // Hermes remains Level A through the existing native provider. This inventory
        // does not pin Hermes hook JSON; T6.1 verifies the provider separately.
        #expect(classifyNativeHermesProvider() == .a)
    }

    @Test
    func grokParsesSessionIDFromStdinNotEnvironmentAlone() throws {
        for name in ["sessionStart.json", "sessionEnd.json"] {
            let fixture = try loadFixture("grok/\(name)")
            let stdin = try fixture.object("stdin")
            let sessionID = try stdin.string("session_id")
            #expect(try stdin.string("sessionId") == sessionID)
            #expect(try fixture.object("environment").string("GROK_SESSION_ID") == sessionID)
            #expect(
                try fixture.object("environment_roles").string("GROK_SESSION_ID")
                    == "consistency_check_only"
            )
        }
    }

    @Test
    func cursorRequiresTopLevelVersionAndAdditionalContext() throws {
        let start = try loadFixture("cursor/sessionStart.json")
        let config = try start.object("hooks_config")
        #expect(try config.int("version") == 1)
        #expect(try start.object("stdout").string("additional_context").isEmpty == false)
        #expect(try start.string("event_name") == "sessionStart")

        let end = try loadFixture("cursor/sessionEnd.json")
        #expect(try end.object("hooks_config").int("version") == 1)
        #expect(try end.string("event_name") == "sessionEnd")
    }

    @Test
    func codexPinsAdditionalContextAndLimit() throws {
        let start = try loadFixture("codex/sessionStart.json")
        let stdout = try start.object("stdout").object("hookSpecificOutput")
        #expect(try stdout.string("hookEventName") == "SessionStart")
        #expect(try stdout.string("additionalContext").isEmpty == false)
        let handlers = try start.object("hooks_config")
            .object("hooks")
            .array("SessionStart")
        let firstGroup = try #require(handlers.first)
        let hook = try #require(try JSONMap(firstGroup).array("hooks").first)
        #expect(try JSONMap(hook).int("additionalContextLimit") == 800)
    }

    @Test
    func openClawSDKNamesMatchDocsProbe() throws {
        let fixture = try loadFixture("openclaw/sdk-names.json")
        let probe = try fixture.object("probe")
        #expect(try probe.bool("compile") == false)
        #expect(try probe.bool("local_node_modules") == false)

        var exposed: [String: Bool] = [:]
        for name in try fixture.array("names") {
            let entry = try JSONMap(name)
            exposed[try entry.string("name")] = try entry.bool("exposed")
        }
        #expect(exposed["registerMemoryPromptPreparation"] == true)
        #expect(exposed["promptBuilder"] == true)
        #expect(exposed["flushPlanResolver"] == true)

        let terminal = try fixture.object("documented_terminal_callback")
        #expect(try terminal.bool("exposed") == false)
        #expect(try classify("openclaw") == .b)
    }

    @Test
    func opencodeIsLevelBBecauseWaxCallsDoNotShareSessionID() throws {
        let fixtures = try loadHostFixtures("opencode")
        for fixture in fixtures {
            let correlation = try fixture.object("correlation")
            #expect(try correlation.bool("all_wax_calls_share_opencode_session_id") == false)
        }
        #expect(try classify("opencode") == .b)
    }

    @Test
    func t04ResidualRisksRemainFailClosed() {
        // Prime text is untrusted historical data; current system/user instructions win.
        #expect(T04ResidualRisk.primeTextIsUntrustedHistoricalData)
        // Person lane stays off unless the operator opts in.
        #expect(T04ResidualRisk.personLaneOffByDefault)
        // Transport IDs correlate; they do not authenticate.
        #expect(T04ResidualRisk.transportIDsAreNotAuthentication)
        // Crash or concurrent edit during hook-config merge must fail closed.
        #expect(T04ResidualRisk.mergeCrashFailsClosed)
    }
}

private func classifyNativeHermesProvider() -> HostOwnershipLevel {
    .a
}

private func classify(_ host: String) throws -> HostOwnershipLevel {
    if host == "hermes" {
        return .a
    }

    let fixtures = try loadHostFixtures(host)
    let evidence = try fixtures.map { try $0.object("correlation") }
    let propagates = evidenceTrue(evidence, "propagates_into_every_wax_read_write")
    let owns = evidenceTrue(evidence, "owns_all_wax_reads_writes")
    let canPrime = evidenceTrue(evidence, "can_inject_prime")

    if host == "openclaw" {
        let sdk = try loadFixture("openclaw/sdk-names.json")
        var preparationExposed = false
        for entry in try sdk.array("names") {
            let map = try JSONMap(entry)
            if try map.string("name") == "registerMemoryPromptPreparation" {
                preparationExposed = try map.bool("exposed")
            }
        }
        let terminal = try sdk.object("documented_terminal_callback").bool("exposed")
        if preparationExposed && terminal && owns && propagates {
            return .a
        }
        return .b
    }

    if host == "opencode" {
        let sharesID = evidenceTrue(evidence, "all_wax_calls_share_opencode_session_id")
        if sharesID && owns && propagates {
            return .a
        }
        return .b
    }

    if owns && propagates {
        return .a
    }
    if canPrime {
        return .cPlusOptionalBPrime
    }
    return .b
}

private func evidenceTrue(_ evidence: [JSONMap], _ key: String) -> Bool {
    evidence.contains { (try? $0.bool(key)) == true }
}

private func documentedEventName(in fixture: JSONMap) throws -> String {
    if let stdin = try? fixture.object("stdin") {
        if let name = try? stdin.string("hook_event_name") {
            return name
        }
        if let name = try? stdin.string("hookEventName") {
            return name
        }
    }
    if let event = try? fixture.object("event"), let type = try? event.string("type") {
        return type
    }
    if let hook = try? fixture.string("plugin_hook"),
       hook == "experimental.chat.system.transform"
    {
        return hook
    }
    return try fixture.string("event_name")
}

private func loadHostFixtures(_ host: String) throws -> [JSONMap] {
    try HostCapabilityFixturesTests.inventory
        .filter { $0.host == host }
        .map { try loadFixture($0.relativePath) }
}

private func loadFixture(_ relativePath: String) throws -> JSONMap {
    let url = hostsRoot().appendingPathComponent(relativePath)
    let data = try Data(contentsOf: url)
    let object = try JSONSerialization.jsonObject(with: data)
    return try JSONMap(object)
}

private func hostsRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/hosts", isDirectory: true)
}

private struct JSONMap {
    let raw: [String: Any]

    init(_ value: Any) throws {
        guard let object = value as? [String: Any] else {
            throw FixtureError.expectedObject
        }
        raw = object
    }

    func string(_ key: String) throws -> String {
        guard let value = raw[key] as? String else {
            throw FixtureError.missing(key)
        }
        return value
    }

    func bool(_ key: String) throws -> Bool {
        if let value = raw[key] as? Bool {
            return value
        }
        if let number = raw[key] as? NSNumber {
            return number.boolValue
        }
        throw FixtureError.missing(key)
    }

    func int(_ key: String) throws -> Int {
        if let value = raw[key] as? Int {
            return value
        }
        if let number = raw[key] as? NSNumber {
            return number.intValue
        }
        throw FixtureError.missing(key)
    }

    func object(_ key: String) throws -> JSONMap {
        try JSONMap(try require(key))
    }

    func array(_ key: String) throws -> [Any] {
        guard let value = raw[key] as? [Any] else {
            throw FixtureError.missing(key)
        }
        return value
    }

    private func require(_ key: String) throws -> Any {
        guard let value = raw[key] else {
            throw FixtureError.missing(key)
        }
        return value
    }
}

private enum FixtureError: Error {
    case expectedObject
    case missing(String)
}
#endif
