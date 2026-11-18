import Foundation
import Testing
@testable import WaxCore

/// About 55 MB of search text used to make a TOC the reader refused. Five frames of 14 MiB make
/// a TOC of about 70 MiB, past the old 64 MiB limit, that must commit and reopen intact.
@Test func storeWithATocOverSixtyFourMiBCommitsAndReopens() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let textBytes = 14 * 1024 * 1024
    let texts: [String] = (0..<5).map { index in
        String(repeating: Character(UnicodeScalar(UInt8(0x61 + index))), count: textBytes)
    }

    do {
        let wax = try await Wax.create(at: url, walSize: 80 * 1024 * 1024)
        for (index, text) in texts.enumerated() {
            _ = try await wax.put(Data("big-\(index)".utf8), options: FrameMetaSubset(searchText: text))
        }
        try await wax.commit()
        try await wax.close()
    }

    let footer = try #require(try FooterScanner.findLastValidFooter(in: url)).footer
    #expect(footer.tocLen > 64 * 1024 * 1024)

    let reopened = try await Wax.open(at: url)
    let frames = await reopened.frameMetas()
    #expect(frames.map(\.id) == [0, 1, 2, 3, 4])
    #expect(frames.map(\.searchText) == texts)
    #expect(try await reopened.frameContent(frameId: 4) == Data("big-4".utf8))
    try await reopened.close()
}
