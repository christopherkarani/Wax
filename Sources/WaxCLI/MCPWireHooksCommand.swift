import ArgumentParser
import Foundation

extension WaxCLI.MCP {
    struct WireHooks: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "wire-hooks",
            abstract: "Opt-in typed merge of Wax host hooks into host config files"
        )

        @Option(name: .customLong("host"), help: "Host: claude, codex, grok, or cursor. Repeatable, paired with --config.")
        var hosts: [String] = []

        @Option(name: .customLong("config"), help: "Host hook config path. Repeatable, paired with --host.")
        var configs: [String] = []

        @Flag(name: .customLong("dry-run"), help: "Detect and merge in memory; write nothing.")
        var dryRun = false

        @Option(name: .customLong("wrapper"), help: "Absolute Wax wrapper that reads JSON stdin and passes typed argv.")
        var wrapper: String?

        func run() throws {
            guard hosts.count == configs.count, !hosts.isEmpty else {
                throw HostHookError.hostConfigCountMismatch
            }

            let wrapperPath: String
            if let wrapper {
                wrapperPath = Pathing.normalizePath(wrapper)
            } else {
                wrapperPath = try Pathing.resolveSelfExecutablePath()
            }
            try HostHookCommand.requireAbsolute(wrapperPath)

            var targets: [HostHookTarget] = []
            for (hostRaw, configRaw) in zip(hosts, configs) {
                guard let host = HostHookHost(rawValue: hostRaw) else {
                    throw HostHookError.unsupportedHost(hostRaw)
                }
                let configURL = URL(fileURLWithPath: Pathing.expandPath(configRaw))
                targets.append(
                    HostHookTarget(host: host, configURL: configURL, wrapperPath: wrapperPath)
                )
            }

            let result = try HostHookInstaller.install(targets: targets, dryRun: dryRun)
            if result.dryRun {
                for preview in result.previews {
                    print("Dry-run: would wire \(preview.host.rawValue) at \(preview.configURL.path). No files written.")
                }
                print("Hooks are not marked trusted automatically. Review them in the host, then restart the host.")
                return
            }
            if result.mutated {
                print(
                    "Wired Wax hooks for \(result.previews.count) host file(s). Hooks are not marked trusted automatically. Review and trust them in the host, then restart the host."
                )
            } else {
                print("Hook wiring already up to date. Hooks are not marked trusted automatically.")
            }
        }
    }

    struct RunHook: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "run-hook",
            abstract: "Host-hook entrypoint. Reads JSON stdin; no-ops with exit 0 if prime/checkpoint is unavailable."
        )

        @Option(name: .customLong("host"), help: "Host adapter name.")
        var host: String

        @Option(name: .customLong("role"), help: "prime or checkpoint.")
        var role: String

        @Option(name: .customLong("wax-hook"), help: "Wax ownership marker version.")
        var waxHook: String = "1"

        func run() throws {
            // Drain stdin so hosts do not see SIGPIPE. Never log stdin: it may contain
            // transcripts or secrets. Host path always exits 0 and writes no stderr.
            let stdin = FileHandle.standardInput.readDataToEndOfFile()
            _ = waxHook
            let outcome = MCPRunHookRunner.run(host: host, role: role, stdin: stdin)
            if !outcome.stdout.isEmpty {
                var data = Data(outcome.stdout.utf8)
                if !outcome.stdout.hasSuffix("\n") {
                    data.append(0x0A)
                }
                FileHandle.standardOutput.write(data)
            }
        }
    }
}
