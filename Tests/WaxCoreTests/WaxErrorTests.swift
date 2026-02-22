import Testing
@testable import WaxCore

@Test
func waxErrorDescriptionsCoverAllCases() {
    let errors: [WaxError] = [
        .invalidHeader(reason: "h"),
        .invalidFooter(reason: "f"),
        .invalidToc(reason: "t"),
        .encodingError(reason: "e"),
        .decodingError(reason: "d"),
        .walCorruption(offset: 5, reason: "w"),
        .checksumMismatch("c"),
        .lockUnavailable("l"),
        .capacityExceeded(limit: 10, requested: 20),
        .frameNotFound(frameId: 7),
        .io("i"),
        .writerBusy,
        .writerTimeout,
    ]

    let descriptions = errors.compactMap(\.errorDescription)
    #expect(descriptions.count == errors.count)
    #expect(descriptions[0].contains("Invalid header"))
    #expect(descriptions[1].contains("Invalid footer"))
    #expect(descriptions[2].contains("Invalid TOC"))
    #expect(descriptions[3].contains("Encoding error"))
    #expect(descriptions[4].contains("Decoding error"))
    #expect(descriptions[5].contains("WAL corruption"))
    #expect(descriptions[6].contains("Checksum mismatch"))
    #expect(descriptions[7].contains("Lock unavailable"))
    #expect(descriptions[8].contains("Capacity exceeded"))
    #expect(descriptions[9].contains("Frame not found"))
    #expect(descriptions[10].contains("I/O error"))
    #expect(descriptions[11].contains("Writer session already active"))
    #expect(descriptions[12].contains("Timed out waiting"))
}
