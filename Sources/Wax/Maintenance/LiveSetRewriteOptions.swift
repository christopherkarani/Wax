import Foundation

package struct LiveSetRewriteOptions: Sendable, Equatable {
    /// Allow replacing an existing destination file.
    package var overwriteDestination: Bool

    /// Replace payload bytes for non-live frames (deleted/superseded) with empty payloads.
    package var dropNonLivePayloads: Bool

    /// Run `Wax.verify(deep:)` on the rewritten file before returning.
    package var verifyDeep: Bool

    package init(
        overwriteDestination: Bool = false,
        dropNonLivePayloads: Bool = true,
        verifyDeep: Bool = false
    ) {
        self.overwriteDestination = overwriteDestination
        self.dropNonLivePayloads = dropNonLivePayloads
        self.verifyDeep = verifyDeep
    }
}
