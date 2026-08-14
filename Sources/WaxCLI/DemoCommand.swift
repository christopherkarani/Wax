import ArgumentParser
import Foundation

struct DemoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "demo",
        abstract: "Linux/cloud TUI demo and public-API stress harness",
        discussion: """
        Runs durable memory, FrameStore, concurrency, volume, error, and exclusive-lock
        scenarios against the public Wax APIs. On a TTY this draws a live dashboard.
        In CI or a cloud agent (no TTY) it prints the same board once per update.

        MiniLM / Foundation Models / Photos are not claimed here. Linux is text-only.
        """
    )

    @Flag(name: .customLong("run"), help: "Non-interactive stress run (default when stdin/stdout is not a TTY)")
    var runOnce = false

    @Flag(name: .customLong("interactive"), help: "Require a TTY and wait for Enter before starting")
    var interactive = false

    @Flag(name: .customLong("stress"), help: "Larger item/round/concurrency profile")
    var stress = false

    @Option(name: .customLong("items"), help: "Facts written per memory round")
    var items: Int?

    @Option(name: .customLong("rounds"), help: "Durable save/reopen rounds")
    var rounds: Int?

    @Option(name: .customLong("concurrency"), help: "Parallel remember workers")
    var concurrency: Int?

    @Option(name: .customLong("volume"), help: "Facts ingested for recall latency")
    var volume: Int?

    @Option(name: .customLong("store-path"), help: "Persist the demo store instead of a temp file")
    var storePath: String?

    @Flag(name: .customLong("keep"), help: "Keep a generated temp store after the run")
    var keep = false

    @Option(name: .customLong("format"), help: "Output format: text (default) or json")
    var format: OutputFormat = .text

    func runAsync() async throws {
        if interactive && runOnce {
            throw CLIError("Use either --interactive or --run, not both")
        }
        if interactive && !DemoTUI.isInteractiveTerminal() {
            throw CLIError("No TTY available. Re-run without --interactive, or use --run.")
        }

        var config = stress ? DemoConfig.stress : DemoConfig.demo
        if let items { config.items = items }
        if let rounds { config.rounds = rounds }
        if let concurrency { config.concurrency = concurrency }
        if let volume { config.volume = volume }
        config.keepStore = keep
        if let storePath {
            config.storeURL = try StoreSession.resolveURL(storePath)
            config.keepStore = true
        }
        config = try config.validated()

        let wantsInteractive = interactive || (!runOnce && DemoTUI.isInteractiveTerminal() && format == .text)
        if wantsInteractive {
            FileHandle.standardError.write(Data("Wax CLI Demo — press Enter to start, or q to quit.\n".utf8))
            guard let line = readLine() else {
                throw CLIError("stdin closed before the demo started")
            }
            if line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "q" {
                return
            }
        }

        let color = DemoTUI.isInteractiveTerminal() && format == .text
        let live = DemoTUI.isInteractiveTerminal() && format == .text
        let harness = DemoHarness(config: config, profile: stress ? "stress" : "demo")
        let report = try await harness.run { snapshot in
            if format == .json { return }
            if live {
                FileHandle.standardOutput.write(Data(DemoTUI.liveFrame(snapshot, color: color).utf8))
            } else {
                // Cloud / CI has no TTY. Reprint the same board so logs still
                // look like the dashboard instead of a bare RUN line.
                print(DemoTUI.render(snapshot, color: false))
                print()
            }
        }

        switch format {
        case .json:
            printJSON(DemoTUI.jsonDictionary(report))
        case .text:
            if !live {
                print(DemoTUI.render(report, color: false))
            }
            print(report.passed ? "WAX_DEMO_OK profile=\(report.profile)" : "WAX_DEMO_FAIL profile=\(report.profile)")
        }

        if !report.passed {
            throw ExitCode.failure
        }
    }
}
