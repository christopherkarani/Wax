import Foundation
import Testing
import Wax
@testable import WaxHNDemo

@Suite("PhotoRAGItem evidence")
struct PhotoRAGItemEvidenceTests {
    @Test("Joins non-empty text snippets and skips blank ones")
    func joinsTextSnippets() {
        let item = PhotoRAGItem(
            assetID: "asset-1",
            score: 1,
            evidence: [
                .text(snippet: "WAX 1234"),
                .vector,
                .text(snippet: nil),
                .text(snippet: "  "),
                .text(snippet: "serial plate"),
            ],
            summaryText: "OCR: ignored when snippets exist"
        )
        #expect(item.evidenceText == "WAX 1234\nserial plate")
    }

    @Test("Falls back to summaryText when evidence has no text snippets")
    func fallsBackToSummaryText() {
        let item = PhotoRAGItem(
            assetID: "asset-2",
            score: 0.4,
            evidence: [.vector, .timeline],
            summaryText: "Caption: coffee receipt"
        )
        #expect(item.evidenceText == "Caption: coffee receipt")
    }
}

@Suite("Photo store contract")
struct PhotoStoreContractTests {
    @Test("Store path is Documents/wax-hn-photos.wax")
    func photosStoreURL() {
        #expect(StoreFilenames.photos == "wax-hn-photos.wax")
        #expect(StoreFilenames.photosURL() == URL.documentsDirectory.appending(path: "wax-hn-photos.wax"))
    }

    @Test("Recall resultLimit is 5")
    func resultLimit() {
        #expect(PhotoSearchModel.resultLimit == 5)
    }

    @Test("Memory store is Documents/wax-hn-memory.wax and never the photo file")
    func memoryStoreURL() {
        #expect(StoreFilenames.memory == "wax-hn-memory.wax")
        #expect(StoreFilenames.memoryURL() == URL.documentsDirectory.appending(path: "wax-hn-memory.wax"))
        #expect(StoreFilenames.memoryURL() != StoreFilenames.photosURL())
    }
}
