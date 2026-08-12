import Foundation
import Wax

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Downstream consumer of the public Foundation Models adapter surface.
/// Compiles against availability, context policy, typed errors, and owning tools
/// without using package-only types.
@main
struct FoundationModelsConsumer {
    static func main() async throws {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) {
            try await runFoundationModelsSurface()
            return
        }
        #endif
        print("WAX_FM_CONSUMER_SKIP=unavailable")
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
    private static func runFoundationModelsSurface() async throws {
        let availability = WaxFoundationModelsAvailability.current()
        let policy = WaxFoundationModelsContextPolicy(
            maxPreparedCharacters: 1_024,
            maxConversationTurns: 8,
            overflowPolicy: .resetTranscriptAndRetryOnce
        )
        precondition(policy.maxPreparedCharacters == 1_024)
        precondition(policy.overflowPolicy == .resetTranscriptAndRetryOnce)

        let overflow = WaxFoundationModelsError.contextWindowExceeded(
            estimatedPreparedCharacters: 2_000,
            maxPreparedCharacters: policy.maxPreparedCharacters,
            estimatedContextTokens: 40,
            measuredPreparedPromptTokenCount: 120,
            recalledItemCount: 2
        )
        let cancelled = WaxFoundationModelsError.cancelled(
            didPersistUser: true,
            didPersistAssistant: false
        )
        precondition(overflow.errorDescription?.contains("measuredPreparedPromptTokenCount=120") == true)
        precondition(cancelled.errorDescription?.contains("didPersistUser=true") == true)

        switch availability {
        case .available:
            print("WAX_FM_AVAILABLE=1")
        case .unavailable(let reason):
            print("WAX_FM_UNAVAILABLE=\(String(describing: reason))")
        }

        print("WAX_FM_CONSUMER_OK=1")
    }
    #endif
}
