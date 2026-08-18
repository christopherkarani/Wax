import Foundation
import WaxCore
import WaxVectorSearch

package enum CommandLineEmbedderFactory {
    private static let defaultLockTimeoutSeconds = 2.0

    /// Compile or reuse a built-in provider through embedding readiness.
    package static func buildEmbedder(
        noEmbedder: Bool,
        embedderChoice: String,
        tuning: CommandLineEmbedderRuntimeTuning = .fromEnvironment()
    ) async throws -> (any EmbeddingProvider)? {
        let request = try HostEmbeddingReadiness.request(
            noEmbedder: noEmbedder,
            requireVector: false,
            embedderChoice: embedderChoice,
            options: BuiltInEmbeddingProviderOptions(tuning: tuning)
        )
        switch request {
        case .disabled:
            return nil
        case .custom(let provider):
            return provider
        case .automatic(let provider, let options), .builtIn(let provider, let options):
            return try await EmbeddingReadiness.shared.compile(
                key: BuiltInEmbeddingCompiler.loadKey(provider, options: options),
                timeout: options.tuning.timeoutDuration
            ) {
                try await BuiltInEmbeddingCompiler.compile(provider, options: options, skipPrewarm: true)
            }
        }
    }

    package static func waxOptions() -> WaxOptions {
        var options = WaxOptions()
        options.lockWaitTimeout = lockWaitTimeout()
        return options
    }

    private static func lockWaitTimeout() -> Duration? {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["WAX_LOCK_TIMEOUT_SECS"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return .milliseconds(Int64(defaultLockTimeoutSeconds * 1000))
        }
        guard let secs = Double(raw) else {
            return .milliseconds(Int64(defaultLockTimeoutSeconds * 1000))
        }
        guard secs > 0 else { return nil }
        return .milliseconds(Int64(secs * 1000))
    }
}

