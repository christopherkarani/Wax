import Foundation
import XCTest

final class CrashSafetyHarnessTests: XCTestCase {
    private enum HarnessResolutionError: Error, CustomStringConvertible {
        case notFound([URL])

        var description: String {
            switch self {
            case .notFound(let candidates):
                let attempted = candidates.map(\.path).joined(separator: "\n")
                return "Could not find WaxCrashHarness binary. Tried:\n\(attempted)"
            }
        }
    }

    func testCrashSafetyHarnessScenarios() throws {
        guard ProcessInfo.processInfo.environment["WAX_RUN_CRASH_HARNESS"] == "1" else {
            throw XCTSkip("Set WAX_RUN_CRASH_HARNESS=1 to run crash-safety harness scenarios.")
        }

        for scenario in ["toc", "footer", "header"] {
            let result = try runHarnessScenario(scenario)
            XCTAssertEqual(
                result.status,
                0,
                "Harness failed for scenario \(scenario)\nstdout:\n\(result.stdout)\nstderr:\n\(result.stderr)"
            )
        }
    }

    private func runHarnessScenario(_ scenario: String) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = try harnessBinaryURL()
        process.arguments = ["--scenario", scenario]
        process.environment = ProcessInfo.processInfo.environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    private func harnessBinaryURL() throws -> URL {
        let env = ProcessInfo.processInfo.environment
        if let override = env["WAX_CRASH_HARNESS_BIN"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }

        let packageRoot = packageRootURL()
        let bundleDebugDir = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let candidates = [
            bundleDebugDir.appendingPathComponent("WaxCrashHarness"),
            packageRoot
                .appendingPathComponent(".build")
                .appendingPathComponent("arm64-apple-macosx")
                .appendingPathComponent("debug")
                .appendingPathComponent("WaxCrashHarness"),
            packageRoot
                .appendingPathComponent(".build")
                .appendingPathComponent("debug")
                .appendingPathComponent("WaxCrashHarness"),
        ]

        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        throw HarnessResolutionError.notFound(candidates)
    }

    private func packageRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // WaxCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // package root
    }
}
