import Foundation
import Wax
import WaxCore

struct DemoConfig: Sendable, Equatable {
    var items: Int
    var rounds: Int
    var concurrency: Int
    var volume: Int
    var storeURL: URL?
    var keepStore: Bool
    var paceMs: Int

    static let demo = DemoConfig(
        items: 16,
        rounds: 1,
        concurrency: 4,
        volume: 48,
        storeURL: nil,
        keepStore: false,
        paceMs: 0
    )

    static let stress = DemoConfig(
        items: 64,
        rounds: 3,
        concurrency: 8,
        volume: 200,
        storeURL: nil,
        keepStore: false,
        paceMs: 0
    )

    func validated() throws -> DemoConfig {
        func require(_ range: ClosedRange<Int>, _ value: Int, name: String) throws {
            guard range.contains(value) else {
                throw CLIError("\(name) must be between \(range.lowerBound) and \(range.upperBound)")
            }
        }
        try require(1...500, items, name: "items")
        try require(1...20, rounds, name: "rounds")
        try require(1...32, concurrency, name: "concurrency")
        try require(1...2_000, volume, name: "volume")
        try require(0...60_000, paceMs, name: "pace-ms")
        return self
    }
}

enum DemoScenarioID: String, Sendable, CaseIterable {
    case memory
    case framestore
    case concurrency
    case volume
    case errors
    case lock
}

enum DemoScenarioStatus: String, Sendable, Equatable {
    case pending
    case running
    case passed
    case failed
    case skipped
}

struct DemoScenarioResult: Sendable, Equatable {
    var id: DemoScenarioID
    var title: String
    var status: DemoScenarioStatus
    var detail: String
    var durationMs: Double
}

struct DemoReport: Sendable, Equatable {
    var profile: String
    var storePath: String
    var textOnly: Bool
    var platform: String
    var scenarios: [DemoScenarioResult]
    var frameCount: UInt64
    var recallP50Ms: Double?
    var recallP95Ms: Double?
    var passed: Bool

    static func blank(profile: String, storePath: String) -> DemoReport {
        DemoReport(
            profile: profile,
            storePath: storePath,
            textOnly: true,
            platform: DemoHarness.platformLabel,
            scenarios: DemoScenarioID.allCases.map { id in
                DemoScenarioResult(
                    id: id,
                    title: id.title,
                    status: .pending,
                    detail: "waiting",
                    durationMs: 0
                )
            },
            frameCount: 0,
            recallP50Ms: nil,
            recallP95Ms: nil,
            passed: false
        )
    }
}

enum DemoStats {
    static func percentile(_ values: [Double], _ quantile: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let clamped = min(max(quantile, 0), 1)
        let index = Int((Double(sorted.count - 1) * clamped).rounded(.toNearestOrAwayFromZero))
        return sorted[min(max(index, 0), sorted.count - 1)]
    }
}

struct DemoHarness: Sendable {
    var config: DemoConfig
    var profile: String

    static var platformLabel: String {
        #if os(Linux)
        "linux"
        #elseif os(macOS)
        "macOS"
        #else
        "unknown"
        #endif
    }

    func run(onEvent: (@Sendable (DemoReport) async -> Void)? = nil) async throws -> DemoReport {
        let config = try self.config.validated()
        let fileManager = FileManager.default
        let workDir = fileManager.temporaryDirectory
            .appendingPathComponent("wax-cli-demo-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: workDir, withIntermediateDirectories: true)

        let storeURL = config.storeURL
            ?? workDir.appendingPathComponent("demo.wax")
        var report = DemoReport.blank(profile: profile, storePath: storeURL.path)
        report.textOnly = true

        defer {
            if !config.keepStore, config.storeURL == nil {
                try? fileManager.removeItem(at: workDir)
            }
        }

        await emit(report, onEvent: onEvent, config: config)

        for id in DemoScenarioID.allCases {
            report = mutating(report, id: id, status: .running, detail: "running")
            await emit(report, onEvent: onEvent, config: config)
            let started = ContinuousClock.now
            do {
                let detail: String
                switch id {
                case .memory:
                    detail = try await runMemory(storeURL: storeURL, config: config)
                case .framestore:
                    detail = try await runFrameStore(workDir: workDir)
                case .concurrency:
                    detail = try await runConcurrency(storeURL: storeURL, config: config)
                case .volume:
                    let volume = try await runVolume(storeURL: storeURL, config: config)
                    report.recallP50Ms = volume.p50
                    report.recallP95Ms = volume.p95
                    report.frameCount = volume.frames
                    detail = volume.detail
                case .errors:
                    detail = try await runErrors(workDir: workDir)
                case .lock:
                    detail = try await runLock(workDir: workDir)
                }
                let ms = elapsedMs(since: started)
                report = mutating(report, id: id, status: .passed, detail: detail, durationMs: ms)
            } catch {
                let ms = elapsedMs(since: started)
                report = mutating(
                    report,
                    id: id,
                    status: .failed,
                    detail: error.localizedDescription,
                    durationMs: ms
                )
            }
            await emit(report, onEvent: onEvent, config: config)
        }

        report.passed = report.scenarios.allSatisfy { $0.status == .passed || $0.status == .skipped }
        await emit(report, onEvent: onEvent, config: config)
        return report
    }

    private func emit(
        _ report: DemoReport,
        onEvent: (@Sendable (DemoReport) async -> Void)?,
        config: DemoConfig
    ) async {
        await onEvent?(report)
        guard config.paceMs > 0 else { return }
        try? await Task.sleep(for: .milliseconds(config.paceMs))
    }

    private func runMemory(storeURL: URL, config: DemoConfig) async throws -> String {
        let token = "WAX_DEMO_\(UUID().uuidString.prefix(8))"
        var lastHitCount = 0

        for round in 1...config.rounds {
            let memory = try await openTextMemory(at: storeURL)
            for index in 0..<config.items {
                try await memory.save(
                    "Round \(round) item \(index) prefers Helix for \(token).",
                    metadata: ["surface": "demo", "round": "\(round)"]
                )
            }
            try await memory.save("Deploy target is Linux cloud for project \(token).")
            let hits = try await memory.search(token) { options in
                options.topK = 8
                options.mode = .textOnly
            }
            try require(!hits.items.isEmpty, "memory search empty after save in round \(round)")
            let joined = hits.items.map(\.text).joined(separator: "\n")
            try require(joined.localizedCaseInsensitiveContains("Helix"), "search missed Helix")
            try require(joined.contains(token), "search missed unique token")
            lastHitCount = hits.items.count
            try await memory.flush()
            try await memory.close()

            let reopened = try await openTextMemory(at: storeURL)
            let durable = try await reopened.search(token) { options in
                options.topK = 10
                options.mode = .textOnly
            }
            try require(!durable.items.isEmpty, "reopen search empty — durability failed")
            try require(
                durable.items.contains(where: { $0.text.contains(token) }),
                "reopen missed token"
            )
            let linuxHits = try await reopened.search("Deploy target Linux \(token)") { options in
                options.topK = 5
                options.mode = .textOnly
            }
            try require(
                linuxHits.items.contains(where: {
                    $0.text.localizedCaseInsensitiveContains("Linux") && $0.text.contains(token)
                }),
                "reopen missed Linux fact"
            )
            try await reopened.close()
        }

        return "\(config.rounds) round(s) · \(config.items) facts · reopen hits \(lastHitCount)"
    }

    private func runFrameStore(workDir: URL) async throws -> String {
        let url = workDir.appendingPathComponent("frames.wax")
        let payloadText = "FrameStore demo payload \(UUID().uuidString)"
        let store = try await FrameStore.create(at: url, walSize: 4 * 1024 * 1024)
        let frameID = try await store.put(
            Data(payloadText.utf8),
            kind: "note",
            metadata: ["surface": "demo"]
        )
        let frames = try await store.frames()
        try require(frames.contains(where: { $0.id == frameID && $0.status == .active }), "put frame missing")
        let decoded = String(data: try await store.content(frameID: frameID), encoding: .utf8) ?? ""
        try require(decoded == payloadText, "content round-trip mismatch")
        try await store.delete(frameID: frameID)
        try await store.close()

        let reopened = try await FrameStore.open(at: url)
        let after = try await reopened.frames()
        if let deleted = after.first(where: { $0.id == frameID }) {
            try require(deleted.status == .deleted, "expected deleted status")
        }
        try await reopened.close()
        return "put/read/delete/reopen frame \(frameID)"
    }

    private func runConcurrency(storeURL: URL, config: DemoConfig) async throws -> String {
        let token = "WAX_CONCUR_\(UUID().uuidString.prefix(8))"
        let memory = try await openTextMemory(at: storeURL, ingestConcurrency: config.concurrency)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for worker in 0..<config.concurrency {
                group.addTask {
                    try await memory.save(
                        "Worker \(worker) indexed cloud stress token \(token).",
                        metadata: ["worker": "\(worker)"]
                    )
                }
            }
            try await group.waitForAll()
        }
        try await memory.flush()
        let hits = try await memory.search(token) { options in
            options.topK = 8
            options.mode = .textOnly
        }
        try require(
            hits.items.contains(where: { $0.text.contains(token) }),
            "concurrent remember missed token"
        )
        try await memory.close()
        return "\(config.concurrency) workers · hit \(hits.items.count)"
    }

    private func runVolume(storeURL: URL, config: DemoConfig) async throws -> (
        detail: String,
        p50: Double,
        p95: Double,
        frames: UInt64
    ) {
        let token = "WAX_VOL_\(UUID().uuidString.prefix(8))"
        let memory = try await openTextMemory(at: storeURL)
        for index in 0..<config.volume {
            try await memory.save("Volume fact \(index) serial \(token) lives on-device.")
        }
        try await memory.flush()

        var latencies: [Double] = []
        latencies.reserveCapacity(12)
        for probe in 0..<12 {
            let started = ContinuousClock.now
            let hits = try await memory.search("\(token) \(probe % 3)") { options in
                options.topK = 5
                options.mode = .textOnly
            }
            latencies.append(elapsedMs(since: started))
            try require(!hits.items.isEmpty, "volume recall empty")
        }
        let stats = await memory.stats()
        try await memory.close()
        let p50 = DemoStats.percentile(latencies, 0.50) ?? 0
        let p95 = DemoStats.percentile(latencies, 0.95) ?? 0
        return (
            "\(config.volume) facts · p50 \(formatMs(p50)) · p95 \(formatMs(p95))",
            p50,
            p95,
            stats.frameCount
        )
    }

    private func runErrors(workDir: URL) async throws -> String {
        let missing = workDir.appendingPathComponent("missing-\(UUID().uuidString).wax")
        do {
            _ = try await FrameStore.open(at: missing)
            throw CLIError("expected FrameStore.open on a missing path to fail")
        } catch is CLIError {
            throw CLIError("expected FrameStore.open on a missing path to fail")
        } catch {
            // Expected: store is absent.
        }

        let vectorStore = workDir.appendingPathComponent("error-vector-\(UUID().uuidString).wax")
        let memory = try await openTextMemory(at: vectorStore)
        try await memory.save("plain text only")
        do {
            _ = try await memory.search("plain", options: .init(topK: 3, mode: .vectorOnly))
            try await memory.close()
            throw CLIError("vectorOnly without embedder should throw")
        } catch is CLIError {
            try await memory.close()
            throw CLIError("vectorOnly without embedder should throw")
        } catch {
            try await memory.close()
        }

        return "missing open + vectorOnly rejected"
    }

    private func runLock(workDir: URL) async throws -> String {
        let url = workDir.appendingPathComponent("lock-\(UUID().uuidString).wax")
        var options = WaxOptions()
        options.lockWaitTimeout = .milliseconds(250)
        let first = try await MemoryOrchestrator(
            at: url,
            config: textOnlyConfig(),
            embedder: nil,
            waxOptions: options
        )
        do {
            _ = try await MemoryOrchestrator(
                at: url,
                config: textOnlyConfig(),
                embedder: nil,
                waxOptions: options
            )
            try await first.close()
            throw CLIError("second exclusive open should fail")
        } catch is CLIError {
            try await first.close()
            throw CLIError("second exclusive open should fail")
        } catch {
            try await first.close()
            return "exclusive lock held · second open failed"
        }
    }

    private func openTextMemory(
        at url: URL,
        ingestConcurrency: Int = 1
    ) async throws -> Memory {
        try await Memory(at: url) { config in
            config.enableTextSearch = true
            config.enableVectorSearch = false
            config.requireOnDeviceProviders = false
            config.ingestConcurrency = ingestConcurrency
        }
    }

    private func textOnlyConfig() -> OrchestratorConfig {
        var config = OrchestratorConfig.default
        config.enableTextSearch = true
        config.enableVectorSearch = false
        config.requireOnDeviceProviders = false
        return config
    }

    private func mutating(
        _ report: DemoReport,
        id: DemoScenarioID,
        status: DemoScenarioStatus,
        detail: String,
        durationMs: Double? = nil
    ) -> DemoReport {
        var next = report
        next.scenarios = report.scenarios.map { scenario in
            guard scenario.id == id else { return scenario }
            var updated = scenario
            updated.status = status
            updated.detail = detail
            if let durationMs {
                updated.durationMs = durationMs
            }
            return updated
        }
        return next
    }

    private func require(_ condition: Bool, _ message: String) throws {
        if !condition {
            throw CLIError(message)
        }
    }

    private func elapsedMs(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now)
        return Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }
}

extension DemoScenarioID {
    var title: String {
        switch self {
        case .memory: "memory"
        case .framestore: "framestore"
        case .concurrency: "concurrency"
        case .volume: "volume"
        case .errors: "errors"
        case .lock: "lock"
        }
    }
}

func formatMs(_ value: Double) -> String {
    String(format: "%.1fms", value)
}
