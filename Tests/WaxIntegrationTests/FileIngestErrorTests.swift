import Foundation
import Testing
import Wax

@Test
func fileIngestErrorDescriptionsIncludePath() {
    let url = URL(fileURLWithPath: "/tmp/input.txt")

    #expect(FileIngestError.fileNotFound(url: url).localizedDescription == "File not found: /tmp/input.txt")
    #expect(FileIngestError.loadFailed(url: url).localizedDescription == "File could not be read: /tmp/input.txt")
    #expect(FileIngestError.unsupportedTextEncoding(url: url).localizedDescription == "File is not UTF-8 text: /tmp/input.txt")
    #expect(FileIngestError.emptyContent(url: url).localizedDescription == "File has no text content: /tmp/input.txt")
}
