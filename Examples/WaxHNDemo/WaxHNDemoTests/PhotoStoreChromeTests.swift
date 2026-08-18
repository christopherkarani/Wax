import Foundation
import Testing
@testable import WaxHNDemo

@Suite("Photo store chrome")
struct PhotoStoreChromeTests {
    @Test("Share and reveal target is wax-hn-photos.wax, not the memory store")
    func shareTargetIsPhotoStore() {
        #expect(PhotoStoreChrome.shareURL == StoreFilenames.photosURL())
        #expect(PhotoStoreChrome.shareURL.lastPathComponent == "wax-hn-photos.wax")
        #expect(PhotoStoreChrome.shareURL != StoreFilenames.memoryURL())
        #expect(PhotoStoreChrome.shareURL.lastPathComponent != StoreFilenames.memory)
    }

    @Test("Size label is one decimal megabyte")
    func sizeLabelOneDecimalMB() {
        #expect(PhotoStoreChrome.sizeLabel(bytes: nil) == "—")
        #expect(PhotoStoreChrome.sizeLabel(bytes: 1_048_576) == "1.0 MB")
        #expect(PhotoStoreChrome.sizeLabel(bytes: 1_572_864) == "1.5 MB")
        #expect(PhotoStoreChrome.sizeLabel(bytes: 524_288) == "0.5 MB")
    }

    @Test("Reads byte count with attributesOfItem")
    func readsFileSizeFromDisk() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "wax-hn-chrome-size-\(UUID().uuidString).wax")
        let payload = Data(repeating: 7, count: 2_097_152)
        try payload.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(PhotoStoreChrome.fileSizeBytes(at: url) == 2_097_152)
        #expect(PhotoStoreChrome.sizeLabel(bytes: PhotoStoreChrome.fileSizeBytes(at: url)) == "2.0 MB")
        #expect(PhotoStoreChrome.fileSizeBytes(at: url.appending(path: "missing")) == nil)
    }

    @Test("Footer shows No account, size, and FM availability string")
    func footerStatusLine() {
        #expect(
            PhotoStoreChrome.statusLine(size: "1.2 MB", fmStatus: "available")
                == "No account · 1.2 MB · FM available"
        )
        #expect(
            PhotoStoreChrome.statusLine(size: "0.5 MB", fmStatus: "appleIntelligenceNotEnabled")
                == "No account · 0.5 MB · FM appleIntelligenceNotEnabled"
        )
        #expect(
            PhotoStoreChrome.statusLine(size: "—", fmStatus: "modelNotReady")
                == "No account · — · FM modelNotReady"
        )
    }

    @Test("Honest copy says the index is text and vectors and originals stay in Photos")
    func honestCopy() {
        #expect(PhotoStoreChrome.honestLine == "Index (text + vectors). Original photos stay in Photos. Recall works offline.")
        #expect(!PhotoStoreChrome.honestLine.contains("wax-hn-memory"))
        #expect(!PhotoStoreChrome.honestLine.contains("0 requests"))
        #expect(!PhotoStoreChrome.honestLine.contains("packet"))
    }
}
