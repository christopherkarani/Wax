import Foundation
import Testing
@testable import WaxHNDemo

@Suite("Harbor corpus")
struct HarborCorpusTests {
    @Test("Resolves the North Harbor set with 10 of each kind")
    func listsTenOfEach() throws {
        let corpus = try HarborCorpus.make(root: HarborCorpus.repoRoot(from: #filePath))
        #expect(corpus.images.count == 10)
        #expect(corpus.videos.count == 10)
        #expect(corpus.files.count == 10)
        #expect(corpus.markdown.count == 6)
        #expect(corpus.pdfs.count == 4)
        #expect(corpus.images.allSatisfy { $0.pathExtension == "png" })
        #expect(corpus.videos.allSatisfy { $0.pathExtension == "mp4" })
        #expect(corpus.files.contains(where: { $0.lastPathComponent == "01-offline-policy.md" }))
        #expect(corpus.files.contains(where: { $0.lastPathComponent == "07-invoice-cedar-loft.pdf" }))
    }

    @Test("Each video has a matching transcript sidecar")
    func transcriptsMatchVideos() throws {
        let corpus = try HarborCorpus.make(root: HarborCorpus.repoRoot(from: #filePath))
        let provider = try HarborTranscriptProvider(root: corpus.root)
        #expect(provider.videoIDs.count == 10)
        for video in corpus.videos {
            let id = video.deletingPathExtension().lastPathComponent
            #expect(!provider.chunks(for: id).isEmpty)
            #expect(provider.chunks(for: id).contains(where: { !$0.text.isEmpty }))
        }
    }
}

@Suite("Demo mode")
struct DemoModeTests {
    @Test("Each section has its own store and a Harbor query")
    func sectionStoresAndQueries() {
        #expect(DemoMode.allCases.count == 4)
        #expect(DemoMode.vector.storeFilename == "wax-hn-vector.wax")
        #expect(DemoMode.files.storeFilename == "wax-hn-files.wax")
        #expect(DemoMode.photos.storeFilename == StoreFilenames.photos)
        #expect(DemoMode.videos.storeFilename == "wax-hn-videos.wax")
        #expect(DemoMode.vector.suggestedQuery == "how do we keep memory on the device")
        #expect(DemoMode.files.suggestedQuery == "what is the offline policy")
        #expect(DemoMode.photos.suggestedQuery == "WAX-HB-4419")
        #expect(DemoMode.videos.suggestedQuery == "when do we ship")
        #expect(Set(DemoMode.allCases.map(\.storeFilename)).count == 4)
    }
}
