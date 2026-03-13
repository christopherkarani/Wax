import Foundation

package struct MaintenanceReport: Sendable, Equatable {
    package var scannedFrames: Int
    package var eligibleFrames: Int
    package var generatedSurrogates: Int
    package var supersededSurrogates: Int
    package var skippedUpToDate: Int
    package var didTimeout: Bool

    package init(
        scannedFrames: Int = 0,
        eligibleFrames: Int = 0,
        generatedSurrogates: Int = 0,
        supersededSurrogates: Int = 0,
        skippedUpToDate: Int = 0,
        didTimeout: Bool = false
    ) {
        self.scannedFrames = scannedFrames
        self.eligibleFrames = eligibleFrames
        self.generatedSurrogates = generatedSurrogates
        self.supersededSurrogates = supersededSurrogates
        self.skippedUpToDate = skippedUpToDate
        self.didTimeout = didTimeout
    }
}

