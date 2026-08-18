import Foundation
import Testing
import Wax
@testable import WaxHNDemo

@Suite("Photo drop")
struct PhotoDropTests {
    @Test("Maps image file URLs to PhotoFile and skips non-images")
    func mapsImageURLs() {
        let receipt = URL(fileURLWithPath: "/tmp/receipt.PNG")
        let notes = URL(fileURLWithPath: "/tmp/notes.txt")
        let files = PhotoDrop.photoFiles(from: [receipt, notes])
        #expect(files.count == 1)
        #expect(files[0].id == "receipt.PNG")
        #expect(files[0].url == receipt)
    }
}
