#if canImport(FoundationModels)
import Foundation
import FoundationModels

/// High-level availability of Apple's on-device Foundation Models runtime.
///
/// Maps ``SystemLanguageModel/availability`` without collapsing distinct
/// unavailability reasons into a string. Unknown future Apple cases become
/// ``UnavailableReason/unknown(_:)``.
@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
public enum WaxFoundationModelsAvailability: Sendable, Equatable {
    public enum UnavailableReason: Sendable, Equatable {
        case deviceNotEligible
        case appleIntelligenceNotEnabled
        case modelNotReady
        case unknown(String)
    }

    case available
    case unavailable(UnavailableReason)

    /// Maps ``SystemLanguageModel/availability`` for the given model.
    public static func current(model: SystemLanguageModel = .default) -> Self {
        map(model.availability)
    }

    /// Typed mapping from Apple's availability enum. Does not infer readiness
    /// beyond the cases Apple actually reports.
    public static func map(_ availability: SystemLanguageModel.Availability) -> Self {
        switch availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return .unavailable(.deviceNotEligible)
            case .appleIntelligenceNotEnabled:
                return .unavailable(.appleIntelligenceNotEnabled)
            case .modelNotReady:
                return .unavailable(.modelNotReady)
            @unknown default:
                return .unavailable(.unknown(String(describing: reason)))
            }
        @unknown default:
            return .unavailable(.unknown("unknown"))
        }
    }

    /// Throws ``WaxFoundationModelsError/unavailable(_:)`` when the runtime is
    /// not available. Call before prewarming a ``LanguageModelSession``.
    public static func preflight(_ availability: Self) throws {
        if case .unavailable(let reason) = availability {
            throw WaxFoundationModelsError.unavailable(reason)
        }
    }
}

/// Typed Foundation Models adapter failures: availability, context, busy
/// streams, iterator misuse, and terminal generation/cancellation with
/// persistence accounting.
@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
@available(tvOS, unavailable)
@available(watchOS, unavailable)
public enum WaxFoundationModelsError: Error, Sendable, Equatable, LocalizedError {
    /// Apple Intelligence / on-device model is not usable.
    case unavailable(WaxFoundationModelsAvailability.UnavailableReason)
    /// A second ``WaxFoundationModelSession/streamResponse(to:options:)`` while
    /// an owning stream still holds the generation lease.
    case generationInProgress
    /// ``WaxGenerationStream`` allows a single iterator.
    case iteratorAlreadyCreated
    /// Prepared prompt exceeded the character policy, or Apple reported an
    /// exceeded context window. Character counts are measured.
    /// `estimatedContextTokens` is the Wax retrieval estimate (`RAGContext.totalTokens`);
    /// `measuredPreparedPromptTokenCount` is the Wax cl100k `TokenCounter` count of the
    /// final prepared prompt. Neither is Apple's hidden tokenizer.
    case contextWindowExceeded(
        estimatedPreparedCharacters: Int,
        maxPreparedCharacters: Int,
        estimatedContextTokens: Int,
        measuredPreparedPromptTokenCount: Int,
        recalledItemCount: Int
    )
    /// Caller cancellation after generation started. Persistence flags record
    /// what was already written.
    case cancelled(didPersistUser: Bool, didPersistAssistant: Bool)
    /// Generation or streaming failed. Persistence flags record what was
    /// already written; assistant text is never persisted on this path.
    case generationFailed(didPersistUser: Bool, didPersistAssistant: Bool, reason: String)
    /// ``WaxFoundationModelsContextPolicy/maxConversationTurns`` was reached.
    case conversationLimitExceeded(completedTurns: Int, maxConversationTurns: Int)
    /// Adapter configuration or stream contract was violated.
    case invalidConfiguration(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            return "Foundation Models unavailable: \(reasonLabel(reason))"
        case .generationInProgress:
            return "A Foundation Models stream is already in progress on this session."
        case .iteratorAlreadyCreated:
            return "WaxGenerationStream supports a single iterator."
        case .contextWindowExceeded(
            let estimatedPreparedCharacters,
            let maxPreparedCharacters,
            let estimatedContextTokens,
            let measuredPreparedPromptTokenCount,
            let recalledItemCount
        ):
            return "Foundation Models context window exceeded: preparedCharacters=\(estimatedPreparedCharacters) maxPreparedCharacters=\(maxPreparedCharacters) estimatedContextTokens=\(estimatedContextTokens) measuredPreparedPromptTokenCount=\(measuredPreparedPromptTokenCount) recalledItemCount=\(recalledItemCount). Character counts are measured; estimatedContextTokens is a retrieval estimate; measuredPreparedPromptTokenCount is Wax cl100k, not Apple's tokenizer."
        case .cancelled(let didPersistUser, let didPersistAssistant):
            return "Foundation Models generation cancelled (didPersistUser=\(didPersistUser), didPersistAssistant=\(didPersistAssistant))."
        case .generationFailed(let didPersistUser, let didPersistAssistant, let reason):
            return "Foundation Models generation failed (didPersistUser=\(didPersistUser), didPersistAssistant=\(didPersistAssistant)): \(reason)"
        case .conversationLimitExceeded(let completedTurns, let maxConversationTurns):
            return "Foundation Models conversation limit exceeded: completedTurns=\(completedTurns) maxConversationTurns=\(maxConversationTurns)."
        case .invalidConfiguration(let reason):
            return "Invalid Foundation Models configuration: \(reason)"
        }
    }

    private func reasonLabel(
        _ reason: WaxFoundationModelsAvailability.UnavailableReason
    ) -> String {
        switch reason {
        case .deviceNotEligible:
            return "deviceNotEligible"
        case .appleIntelligenceNotEnabled:
            return "appleIntelligenceNotEnabled"
        case .modelNotReady:
            return "modelNotReady"
        case .unknown(let detail):
            return detail
        }
    }

    /// Maps Apple / cancellation / unknown generation failures into typed
    /// adapter errors, preserving persistence accounting.
    package static func mapTerminal(
        _ error: Error,
        estimatedPreparedCharacters: Int,
        maxPreparedCharacters: Int,
        estimatedContextTokens: Int,
        measuredPreparedPromptTokenCount: Int,
        recalledItemCount: Int,
        didPersistUser: Bool,
        didPersistAssistant: Bool
    ) -> Error {
        if let typed = error as? WaxFoundationModelsError {
            return typed
        }
        if error is CancellationError {
            return WaxFoundationModelsError.cancelled(
                didPersistUser: didPersistUser,
                didPersistAssistant: didPersistAssistant
            )
        }
        if let generation = error as? LanguageModelSession.GenerationError,
           case .exceededContextWindowSize = generation {
            return WaxFoundationModelsError.contextWindowExceeded(
                estimatedPreparedCharacters: estimatedPreparedCharacters,
                maxPreparedCharacters: maxPreparedCharacters,
                estimatedContextTokens: estimatedContextTokens,
                measuredPreparedPromptTokenCount: measuredPreparedPromptTokenCount,
                recalledItemCount: recalledItemCount
            )
        }
        return WaxFoundationModelsError.generationFailed(
            didPersistUser: didPersistUser,
            didPersistAssistant: didPersistAssistant,
            reason: String(describing: error)
        )
    }

    package static func isExceededContextWindow(_ error: Error) -> Bool {
        if let generation = error as? LanguageModelSession.GenerationError,
           case .exceededContextWindowSize = generation {
            return true
        }
        if case .contextWindowExceeded = error as? WaxFoundationModelsError {
            return true
        }
        return false
    }
}
#endif
