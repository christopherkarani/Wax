import Foundation
import Testing
import WaxCore

@Test func durationFormattingZeroIsExactLabel() {
    #expect(DurationFormatting.format(.zero) == "0s")
}

@Test func durationFormattingUsesFixedFractionalSeconds() {
    #expect(DurationFormatting.format(.milliseconds(1500)) == "1.50s")
    #expect(DurationFormatting.format(.milliseconds(10)) == "0.01s")
}
