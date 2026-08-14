#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

enum DemoTUI {
    static func isInteractiveTerminal() -> Bool {
        #if canImport(Darwin)
        Darwin.isatty(STDOUT_FILENO) != 0 && Darwin.isatty(STDIN_FILENO) != 0
        #elseif canImport(Glibc)
        Glibc.isatty(STDOUT_FILENO) != 0 && Glibc.isatty(STDIN_FILENO) != 0
        #else
        false
        #endif
    }

    static func render(_ report: DemoReport, color: Bool) -> String {
        let width = 72
        let title = "Wax CLI Demo"
        let heading = "\(title)  ·  \(report.profile)  ·  \(report.platform)"
        var lines: [String] = []
        lines.append(bar(width, left: "┌", fill: "─", right: "┐"))
        lines.append(row(pad(heading, width - 2), width: width))
        lines.append(row(pad(subtitle(report), width - 2), width: width))
        lines.append(bar(width, left: "├", fill: "─", right: "┤"))

        for scenario in report.scenarios {
            let status = statusLabel(scenario.status, color: color)
            let timing = scenario.status == .pending || scenario.status == .running
                ? "   …   "
                : pad(formatMs(scenario.durationMs), 8)
            let body = " \(status)  \(pad(scenario.title, 12)) \(timing)  \(truncate(scenario.detail, 32))"
            lines.append(row(pad(body, width - 2), width: width))
        }

        lines.append(bar(width, left: "├", fill: "─", right: "┤"))
        let latency = [
            report.recallP50Ms.map { "p50 \(formatMs($0))" },
            report.recallP95Ms.map { "p95 \(formatMs($0))" },
            "frames \(report.frameCount)",
        ].compactMap { $0 }.joined(separator: "   ")
        lines.append(row(pad(" \(latency)", width - 2), width: width))
        let footer: String
        if report.passed {
            footer = " ALL SCENARIOS PASSED"
        } else if report.scenarios.contains(where: { $0.status == .failed }) {
            footer = " FAILED"
        } else {
            footer = " IN PROGRESS"
        }
        lines.append(row(pad(footer, width - 2), width: width))
        lines.append(bar(width, left: "└", fill: "─", right: "┘"))
        return lines.joined(separator: "\n")
    }

    static func jsonDictionary(_ report: DemoReport) -> [String: Any] {
        [
            "profile": report.profile,
            "platform": report.platform,
            "storePath": report.storePath,
            "textOnly": report.textOnly,
            "passed": report.passed,
            "frameCount": report.frameCount,
            "recallP50Ms": report.recallP50Ms.map { $0 as Any } ?? NSNull(),
            "recallP95Ms": report.recallP95Ms.map { $0 as Any } ?? NSNull(),
            "scenarios": report.scenarios.map { scenario in
                [
                    "id": scenario.id.rawValue,
                    "title": scenario.title,
                    "status": scenario.status.rawValue,
                    "detail": scenario.detail,
                    "durationMs": scenario.durationMs,
                ] as [String: Any]
            },
        ]
    }

    static func liveFrame(_ report: DemoReport, color: Bool) -> String {
        "\u{1B}[?25l\u{1B}[H\u{1B}[2J" + render(report, color: color) + "\n"
    }

    private static func subtitle(_ report: DemoReport) -> String {
        let mode = report.textOnly ? "text-only index" : "hybrid index"
        return "\(mode)  ·  \(report.storePath)"
    }

    private static func statusLabel(_ status: DemoScenarioStatus, color: Bool) -> String {
        let raw: String
        switch status {
        case .pending: raw = "WAIT"
        case .running: raw = "RUN "
        case .passed: raw = "PASS"
        case .failed: raw = "FAIL"
        case .skipped: raw = "SKIP"
        }
        guard color else { return raw }
        switch status {
        case .passed: return "\u{1B}[32m\(raw)\u{1B}[0m"
        case .failed: return "\u{1B}[31m\(raw)\u{1B}[0m"
        case .running: return "\u{1B}[33m\(raw)\u{1B}[0m"
        case .pending, .skipped: return "\u{1B}[90m\(raw)\u{1B}[0m"
        }
    }

    private static func bar(_ width: Int, left: String, fill: String, right: String) -> String {
        left + String(repeating: fill, count: max(width - 2, 0)) + right
    }

    private static func row(_ content: String, width: Int) -> String {
        "│" + content + "│"
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        if text.count >= width {
            return String(text.prefix(width))
        }
        return text + String(repeating: " ", count: width - text.count)
    }

    private static func truncate(_ text: String, _ width: Int) -> String {
        if text.count <= width { return text }
        return String(text.prefix(max(width - 1, 0))) + "…"
    }
}
