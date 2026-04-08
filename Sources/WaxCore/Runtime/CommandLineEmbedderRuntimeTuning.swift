import Foundation
#if canImport(CoreML)
@preconcurrency import CoreML
#endif

package enum CommandLineEmbedderComputeUnit: String, CaseIterable, Sendable, Codable {
    case cpuOnly
    case cpuAndGPU
    case cpuAndNeuralEngine
    case all

    #if canImport(CoreML)
    package var coreMLValue: MLComputeUnits {
        switch self {
        case .cpuOnly:
            return .cpuOnly
        case .cpuAndGPU:
            return .cpuAndGPU
        case .cpuAndNeuralEngine:
            return .cpuAndNeuralEngine
        case .all:
            return .all
        }
    }
    #endif
}

package struct CommandLineEmbedderRuntimeTuning: Sendable, Equatable, Codable {
    package static let defaultBatchSize = 1
    package static let defaultPrewarmBatchSize = 1
    package static let defaultAllowLowPrecisionGPU = true
    package static let defaultTimeoutSeconds = 30.0
    package static let defaultComputeUnitsOrder: [CommandLineEmbedderComputeUnit] = [.cpuOnly]

    package var batchSize: Int
    package var prewarmBatchSize: Int
    package var allowLowPrecisionGPU: Bool
    package var timeoutSeconds: Double
    package var computeUnitsOrder: [CommandLineEmbedderComputeUnit]

    package init(
        batchSize: Int = CommandLineEmbedderRuntimeTuning.defaultBatchSize,
        prewarmBatchSize: Int = CommandLineEmbedderRuntimeTuning.defaultPrewarmBatchSize,
        allowLowPrecisionGPU: Bool = CommandLineEmbedderRuntimeTuning.defaultAllowLowPrecisionGPU,
        timeoutSeconds: Double = CommandLineEmbedderRuntimeTuning.defaultTimeoutSeconds,
        computeUnitsOrder: [CommandLineEmbedderComputeUnit] = CommandLineEmbedderRuntimeTuning.defaultComputeUnitsOrder
    ) {
        self.batchSize = max(1, batchSize)
        self.prewarmBatchSize = max(1, prewarmBatchSize)
        self.allowLowPrecisionGPU = allowLowPrecisionGPU
        self.timeoutSeconds = timeoutSeconds > 0 ? timeoutSeconds : CommandLineEmbedderRuntimeTuning.defaultTimeoutSeconds
        self.computeUnitsOrder = computeUnitsOrder.isEmpty
            ? CommandLineEmbedderRuntimeTuning.defaultComputeUnitsOrder
            : computeUnitsOrder
    }

    package static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> CommandLineEmbedderRuntimeTuning {
        var tuning = CommandLineEmbedderRuntimeTuning()

        if let raw = environment["WAX_EMBEDDER_BATCH_SIZE"],
           let value = parsePositiveInt(raw) {
            tuning.batchSize = value
        }

        if let raw = environment["WAX_EMBEDDER_PREWARM_BATCH_SIZE"],
           let value = parsePositiveInt(raw) {
            tuning.prewarmBatchSize = value
        }

        if let raw = environment["WAX_EMBEDDER_TIMEOUT_SECS"],
           let value = parsePositiveDouble(raw) {
            tuning.timeoutSeconds = value
        }

        if let raw = environment["WAX_EMBEDDER_ALLOW_LOW_PRECISION_GPU"] {
            tuning.allowLowPrecisionGPU = parseBool(raw) ?? tuning.allowLowPrecisionGPU
        }

        if let raw = environment["WAX_EMBEDDER_COMPUTE_UNITS"] {
            let parsed = raw
                .split(separator: ",")
                .compactMap { CommandLineEmbedderComputeUnit(rawValue: String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
            if !parsed.isEmpty {
                tuning.computeUnitsOrder = parsed
            }
        }

        return tuning
    }

    package var timeoutDuration: Duration {
        .milliseconds(Int64(timeoutSeconds * 1000))
    }

    package var brokerCacheKey: String {
        [
            "batch=\(batchSize)",
            "prewarm=\(prewarmBatchSize)",
            "lowPrecisionGPU=\(allowLowPrecisionGPU ? 1 : 0)",
            "timeout=\(String(format: "%.3f", timeoutSeconds))",
            "units=\(computeUnitsOrder.map(\.rawValue).joined(separator: ","))",
        ].joined(separator: "|")
    }

    package func daemonArguments() -> [String] {
        var arguments = [
            "--embedder-batch-size", String(batchSize),
            "--embedder-prewarm-batch-size", String(prewarmBatchSize),
            "--embedder-timeout-secs", String(timeoutSeconds),
            "--embedder-low-precision-gpu", allowLowPrecisionGPU ? "true" : "false",
        ]
        for unit in computeUnitsOrder {
            arguments.append(contentsOf: ["--embedder-compute-unit", unit.rawValue])
        }
        return arguments
    }

    package func environmentOverrides() -> [String: String] {
        [
            "WAX_EMBEDDER_BATCH_SIZE": String(batchSize),
            "WAX_EMBEDDER_PREWARM_BATCH_SIZE": String(prewarmBatchSize),
            "WAX_EMBEDDER_TIMEOUT_SECS": String(timeoutSeconds),
            "WAX_EMBEDDER_ALLOW_LOW_PRECISION_GPU": allowLowPrecisionGPU ? "1" : "0",
            "WAX_EMBEDDER_COMPUTE_UNITS": computeUnitsOrder.map(\.rawValue).joined(separator: ","),
        ]
    }

    #if canImport(CoreML)
    package func modelConfiguration(for computeUnit: CommandLineEmbedderComputeUnit) -> MLModelConfiguration {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnit.coreMLValue
        configuration.allowLowPrecisionAccumulationOnGPU = allowLowPrecisionGPU
        return configuration
    }
    #endif

    private static func parsePositiveInt(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), value > 0 else { return nil }
        return value
    }

    private static func parsePositiveDouble(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(trimmed), value > 0 else { return nil }
        return value
    }

    private static func parseBool(_ raw: String) -> Bool? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }
}
