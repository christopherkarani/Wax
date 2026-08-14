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
        report.frameCount = 12
        report.recallP50Ms = 1.5
        report.recallP95Ms = 4.2
        let board = DemoTUI.render(report, color: false)
        #expect(board.contains("Wax CLI Demo"))
        #expect(board.contains("text-only index"))
        #expect(board.contains("memory"))
        #expect(board.contains("framestore"))
        #expect(board.contains("concurrency"))
        #expect(board.contains("volume"))
        #expect(board.contains("errors"))
        #expect(board.contains("lock"))
        #expect(board.contains("ALL SCENARIOS PASSED"))
        #expect(!board.contains("MiniLM proven"))
        #expect(!board.contains("airplane"))
        let live = DemoTUI.liveFrame(report, color: false)
        #expect(live.contains("\u{1B}[H"))
        #expect(live.contains("Wax CLI Demo"))
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
        #expect(report.recallP50Ms != nil)
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
    }
}
