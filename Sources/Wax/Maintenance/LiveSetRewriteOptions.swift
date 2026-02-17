import Foundation

public struct LiveSetRewriteOptions: Sendable, Equatable {
    /// Allow replacing an existing destination file.
    public var overwriteDestination: Bool

    /// Replace payload bytes for non-live frames (deleted/superseded) with empty payloads.
    public var dropNonLivePayloads: Bool

    /// Run `Wax.verify(deep:)` on the rewritten file before returning.
    public var verifyDeep: Bool

    public init(
        overwriteDestination: Bool = false,
        dropNonLivePayloads: Bool = true,
        verifyDeep: Bool = false
    ) {
        self.overwriteDestination = overwriteDestination
        self.dropNonLivePayloads = dropNonLivePayloads
        self.verifyDeep = verifyDeep
    }
}
