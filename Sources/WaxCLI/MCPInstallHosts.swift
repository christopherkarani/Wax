import Foundation

/// Hosts `mcp install` / `mcp uninstall` can set up. Hermes and OpenClaw are
/// intentionally absent: Hermes is a native provider install and OpenClaw
/// needs a workspace SOUL.md edit, so both stay guided-manual (see docs).
enum InstallHost: String, Sendable, CaseIterable {
    case claude
    case muse
    case cursor
    case codex
    case grok
    case opencode
}

enum HostSelection: Equatable, Sendable {
    case auto
    case all
    case only(Set<InstallHost>)
}

struct HostProbe: Sendable {
    var commandExists: @Sendable (String) -> Bool
    var fileExists: @Sendable (String) -> Bool

    static let live = HostProbe(
        commandExists: { (try? resolveToolPath($0)) != nil },
        fileExists: { FileManager.default.fileExists(atPath: $0) }
    )
}

struct HostDetection: Equatable, Sendable {
    var host: InstallHost
    var detected: Bool
    var reason: String
}

struct ResolvedHosts: Equatable, Sendable {
    var selected: [InstallHost]
    var skipped: [HostDetection]
}

enum MCPInstallHosts {
    static let specHelp = "Hosts: auto (default), all, or comma list: claude,muse,cursor,codex,grok,opencode"

    static func parseSpec(_ raw: String) throws -> HostSelection {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed == "auto" {
            return .auto
        }
        if trimmed == "all" {
            return .all
        }
        var hosts = Set<InstallHost>()
        for part in trimmed.split(separator: ",") {
            let name = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let host = InstallHost(rawValue: String(name)) else {
                throw InstallHostError.unknownHost(String(name))
            }
            hosts.insert(host)
        }
        if hosts.isEmpty {
            throw InstallHostError.emptySpec
        }
        return .only(hosts)
    }

    static func cursorConfigURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory
            .appendingPathComponent(".cursor", isDirectory: true)
            .appendingPathComponent("mcp.json")
    }

    static func codexHome(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let raw = environment["CODEX_HOME"] {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return URL(fileURLWithPath: trimmed).standardizedFileURL
            }
        }
        return homeDirectory.appendingPathComponent(".codex", isDirectory: true)
    }

    static func codexConfigURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        codexHome(environment: environment, homeDirectory: homeDirectory)
            .appendingPathComponent("config.toml")
    }

    static func codexSkillsDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        codexHome(environment: environment, homeDirectory: homeDirectory)
            .appendingPathComponent("skills", isDirectory: true)
    }

    static func grokHome(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let raw = environment["GROK_HOME"] {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return URL(fileURLWithPath: trimmed).standardizedFileURL
            }
        }
        return homeDirectory.appendingPathComponent(".grok", isDirectory: true)
    }

    static func grokConfigURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        grokHome(environment: environment, homeDirectory: homeDirectory)
            .appendingPathComponent("config.toml")
    }

    /// Global OpenCode config. `OPENCODE_CONFIG` names the file outright;
    /// otherwise `OPENCODE_CONFIG_DIR/opencode.json`, else the XDG default.
    static func openCodeConfigURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let raw = environment["OPENCODE_CONFIG"] {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return URL(fileURLWithPath: trimmed).standardizedFileURL
            }
        }
        if let raw = environment["OPENCODE_CONFIG_DIR"] {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return URL(fileURLWithPath: trimmed).standardizedFileURL
                    .appendingPathComponent("opencode.json")
            }
        }
        if let raw = environment["XDG_CONFIG_HOME"] {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return URL(fileURLWithPath: trimmed)
                    .appendingPathComponent("opencode", isDirectory: true)
                    .appendingPathComponent("opencode.json")
            }
        }
        return homeDirectory
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("opencode", isDirectory: true)
            .appendingPathComponent("opencode.json")
    }

    static func detect(
        _ host: InstallHost,
        probe: HostProbe = .live,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> HostDetection {
        switch host {
        case .claude:
            if probe.commandExists("claude") {
                return HostDetection(host: host, detected: true, reason: "claude binary found")
            }
            return HostDetection(host: host, detected: false, reason: "no `claude` binary on PATH or common locations")
        case .muse:
            let settings = MuseSetup.settingsURL(environment: environment, homeDirectory: homeDirectory).path
            if probe.commandExists("muse") {
                return HostDetection(host: host, detected: true, reason: "muse binary found")
            }
            if probe.fileExists(settings) {
                return HostDetection(host: host, detected: true, reason: "Muse settings found")
            }
            return HostDetection(host: host, detected: false, reason: "no `muse` binary and no Muse settings.json")
        case .cursor:
            let config = cursorConfigURL(homeDirectory: homeDirectory).path
            if probe.fileExists(config) {
                return HostDetection(host: host, detected: true, reason: "Cursor mcp.json found")
            }
            if probe.commandExists("cursor") {
                return HostDetection(host: host, detected: true, reason: "cursor binary found")
            }
            return HostDetection(host: host, detected: false, reason: "no Cursor mcp.json and no `cursor` binary")
        case .codex:
            let config = codexConfigURL(environment: environment, homeDirectory: homeDirectory).path
            if probe.commandExists("codex") {
                return HostDetection(host: host, detected: true, reason: "codex binary found")
            }
            if probe.fileExists(config) {
                return HostDetection(host: host, detected: true, reason: "Codex config.toml found")
            }
            return HostDetection(host: host, detected: false, reason: "no `codex` binary and no config.toml")
        case .grok:
            let config = grokConfigURL(environment: environment, homeDirectory: homeDirectory).path
            if probe.commandExists("grok") {
                return HostDetection(host: host, detected: true, reason: "grok binary found")
            }
            if probe.fileExists(config) {
                return HostDetection(host: host, detected: true, reason: "Grok config.toml found")
            }
            return HostDetection(host: host, detected: false, reason: "no `grok` binary and no config.toml")
        case .opencode:
            let config = openCodeConfigURL(environment: environment, homeDirectory: homeDirectory).path
            if probe.commandExists("opencode") {
                return HostDetection(host: host, detected: true, reason: "opencode binary found")
            }
            if probe.fileExists(config) {
                return HostDetection(host: host, detected: true, reason: "OpenCode opencode.json found")
            }
            return HostDetection(host: host, detected: false, reason: "no `opencode` binary and no opencode.json")
        }
    }

    /// Reject server names that could inject structure into host configs.
    /// Names render into TOML table headers (`[mcp_servers.<name>]`), where
    /// bare segments allow ASCII letters, numbers, `-`, and `_` only.
    static func validateName(_ name: String) throws {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        guard !name.isEmpty, name.unicodeScalars.allSatisfy(allowed.contains) else {
            throw InstallHostError.invalidName(name)
        }
    }

    /// True when the server binary answers `--version` with exit 0. Catches
    /// traitless builds (wax-mcp without the MCPServer trait exits 1) before
    /// install registers a dead server into host configs.
    static func validateServerBinary(
        serverPath: String,
        run: (String, [String]) throws -> CapturedProcessOutput = {
            try ProcessRunner.runCaptured(command: $0, arguments: $1, timeoutSeconds: 10)
        }
    ) -> Bool {
        guard let output = try? run(serverPath, ["--version"]) else {
            return false
        }
        return output.status == EXIT_SUCCESS
    }

    /// Resolve a `--hosts` spec to an ordered install list. `skipMuse`
    /// excludes muse after resolution; an empty result is an error.
    static func resolve(
        spec: HostSelection,
        skipMuse: Bool,
        probe: HostProbe = .live,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> ResolvedHosts {
        let ordered = InstallHost.allCases
        let detections = ordered.map {
            detect($0, probe: probe, environment: environment, homeDirectory: homeDirectory)
        }
        let selected: [InstallHost]
        let skipped: [HostDetection]
        switch spec {
        case .auto:
            selected = detections.filter(\.detected).map(\.host)
            skipped = detections.filter { !$0.detected }
        case .all:
            selected = ordered
            skipped = []
        case .only(let hosts):
            selected = ordered.filter { hosts.contains($0) }
            skipped = []
        }

        let final = selected.filter { !(skipMuse && $0 == .muse) }
        if final.isEmpty {
            if skipMuse, case .only(let hosts) = spec, hosts == [.muse] {
                throw InstallHostError.conflictingMuseFlags
            }
            if case .auto = spec {
                throw InstallHostError.noHostsDetected(
                    skipped.map { "\($0.host.rawValue): \($0.reason)" }.joined(separator: "; ")
                )
            }
            throw InstallHostError.noHostsSelected
        }
        return ResolvedHosts(selected: final, skipped: skipped)
    }
}

enum InstallHostError: Error, Equatable, LocalizedError {
    case unknownHost(String)
    case emptySpec
    case invalidName(String)
    case noHostsDetected(String)
    case noHostsSelected
    case conflictingMuseFlags

    var errorDescription: String? {
        switch self {
        case .unknownHost(let name):
            return "Unknown host '\(name)'. \(MCPInstallHosts.specHelp)."
        case .emptySpec:
            return "Empty --hosts spec. \(MCPInstallHosts.specHelp)."
        case .invalidName(let name):
            return "Invalid server name '\(name)'. Use ASCII letters, numbers, '-' or '_' only."
        case .noHostsDetected(let details):
            return "No supported hosts detected (\(details)). Pass --hosts explicitly to set one up anyway."
        case .noHostsSelected:
            return "No hosts selected."
        case .conflictingMuseFlags:
            return "--hosts muse conflicts with --skip-muse. Drop one of them."
        }
    }
}
