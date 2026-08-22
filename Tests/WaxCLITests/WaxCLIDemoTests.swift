import Foundation
import Testing
@testable import wax_cli

@Suite("WaxCLI demo harness")
struct WaxCLIDemoTests {
    @Test("Percentile helper is stable on tiny samples")
    func percentileHelper() {
        #expect(DemoStats.percentile([], 0.5) == nil)
        #expect(DemoStats.percentile([4], 0.5) == 4)
        #expect(DemoStats.percentile([1, 2, 3, 4, 5], 0.50) == 3)
        #expect(DemoStats.percentile([1, 2, 3, 4, 5], 0.95) == 5)
    }

    @Test("TUI board names every scenario and the text-only footer")
    func tuiBoardCopy() {
        var report = DemoReport.blank(profile: "demo", storePath: "/tmp/demo.wax")
        report.textOnly = true
        report.platform = "linux"
        report.passed = true
        report.scenarios = report.scenarios.map { scenario in
            var scenario = scenario
            scenario.status = .passed
            scenario.detail = "passed"
            return scenario
        }
        report.frameCount = 12
        report.retrievalLastMs = 1.8
        report.recallP50Ms = 1.5
        report.recallP95Ms = 4.2
        report.retrievalCount = 9
        let board = DemoTUI.render(report, color: false)
        #expect(board.contains("Wax CLI Demo"))
        #expect(board.contains("text-only index"))
        #expect(board.contains("memory"))
        #expect(board.contains("framestore"))
        #expect(board.contains("concurrency"))
        #expect(board.contains("volume"))
        #expect(board.contains("errors"))
        #expect(board.contains("lock"))
        #expect(board.contains("retrieval  last 1.8ms  p50 1.5ms  p95 4.2ms  n=9"))
        #expect(board.contains("ALL SCENARIOS PASSED"))
        #expect(!board.contains("IN PROGRESS"))
        #expect(!board.contains("MiniLM proven"))
        #expect(!board.contains("airplane"))

        var pending = DemoReport.blank(profile: "demo", storePath: "/tmp/demo.wax")
        pending.textOnly = true
        let pendingBoard = DemoTUI.render(pending, color: false)
        #expect(pendingBoard.contains("IN PROGRESS"))
        #expect(pendingBoard.contains("retrieval  last —  p50 —  p95 —  n=0"))
        #expect(!pendingBoard.contains("FAILED"))
        let live = DemoTUI.liveFrame(report, color: false)
        #expect(live.contains("\u{1B}[H"))
        #expect(live.contains("Wax CLI Demo"))

        let colored = DemoTUI.render(report, color: true)
        #expect(colored.contains("\u{1B}[32mPASS\u{1B}[0m"))
        let plainLines = board.split(separator: "\n").count
        let colorLines = colored.split(separator: "\n").count
        #expect(plainLines == colorLines)
    }

    @Test("Default demo profile passes on a temp store")
    func defaultDemoPasses() async throws {
        let harness = DemoHarness(config: .demo, profile: "demo")
        let report = try await harness.run()
        #expect(report.passed)
        #expect(report.textOnly)
        #expect(report.scenarios.count == DemoScenarioID.allCases.count)
        #expect(report.scenarios.allSatisfy { $0.status == .passed })
        #expect(report.frameCount > 0)
        #expect(report.retrievalCount > 0)
        #expect(report.retrievalLastMs != nil)
        #expect(report.recallP50Ms != nil)
        #expect(report.recallP95Ms != nil)
    }

    @Test("Tiny stress-shaped config still proves durability")
    func tinyStressShapedRun() async throws {
        var config = DemoConfig.demo
        config.items = 4
        config.rounds = 2
        config.concurrency = 2
        config.volume = 8
        let report = try await DemoHarness(config: config, profile: "stress").run()
        #expect(report.passed)
        let memory = report.scenarios.first { $0.id == .memory }
        #expect(memory?.detail.contains("2 round") == true)
    }

    @Test("Invalid knobs fail before opening a store")
    func rejectsInvalidKnobs() async {
        var config = DemoConfig.demo
        config.items = 0
        do {
            _ = try await DemoHarness(config: config, profile: "demo").run()
            Issue.record("expected validation failure")
        } catch {
            #expect(String(describing: error).contains("items"))
        }

        var paced = DemoConfig.demo
        paced.paceMs = 90_000
        do {
            _ = try await DemoHarness(config: paced, profile: "demo").run()
            Issue.record("expected pace-ms validation failure")
        } catch {
            #expect(String(describing: error).contains("pace-ms"))
        }
    }
}
