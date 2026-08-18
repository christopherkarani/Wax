#if canImport(FoundationModels)
import FoundationModels
import Wax

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
extension WaxFoundationModelSession {
    /// Consumes ``streamResponse(to:options:)`` on the session actor so the
    /// non-Sendable `ResponseStream` never crosses to the main actor.
    func streamTextSnapshots(
        to prompt: String,
        onSnapshot: @Sendable (String) async -> Void
    ) async throws {
        let stream = try await streamResponse(to: prompt)
        for try await snapshot in stream {
            try Task.checkCancellation()
            await onSnapshot(snapshot.content)
        }
    }
}
#endif
