import Foundation
import Observation
import Wax

@MainActor
@Observable
final class DemoSearchModel {
    var mode: DemoMode = .photos
    var query = DemoMode.photos.suggestedQuery
    var notice: String?
    var isBusy = false
    var isGenerating = false
    var answer = ""
    var fmStatus = "—"
    var storeBytes: UInt64?
    var loadedCounts: [DemoMode: Int] = [:]
    var textHits: [RAGContext.Item] = []
    var photoHits: [PhotoRAGItem] = []
    var videoHits: [VideoRAGItem] = []

    var storeURL: URL { mode.storeURL() }

    var storeSizeLabel: String {
        PhotoStoreChrome.sizeLabel(bytes: storeBytes)
    }

    var loadCaption: String {
        if let count = loadedCounts[mode] {
            "Loaded \(count) Harbor \(mode.title.lowercased())"
        } else {
            "Harbor set not loaded"
        }
    }

    @ObservationIgnored private var textStores: [DemoMode: Memory] = [:]
    @ObservationIgnored private var photos: PhotoMemory?
    @ObservationIgnored private var videos: VideoMemory?
    @ObservationIgnored private var corpus: HarborCorpus?

    func prepareCurrentSection() async {
        query = mode.suggestedQuery
        textHits = []
        photoHits = []
        videoHits = []
        answer = ""
        await loadHarborSet()
        refreshStoreSize()
    }

    func loadHarborSet() async {
        isBusy = true
        defer { isBusy = false }
        do {
            let corpus = try resolvedCorpus()
            switch mode {
            case .vector, .files:
                loadedCounts[mode] = try await ingestFiles(from: corpus)
            case .photos:
                loadedCounts[mode] = try await ingestPhotos(from: corpus)
            case .videos:
                loadedCounts[mode] = try await ingestVideos(from: corpus)
            }
            notice = loadCaption
        } catch {
            notice = error.localizedDescription
        }
    }

    func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isBusy = true
        isGenerating = false
        answer = ""
        defer { isBusy = false }
        do {
            if loadedCounts[mode] == nil {
                await loadHarborSet()
            }
            switch mode {
            case .vector:
                textHits = try await searchText(trimmed, retrieval: .vectorOnly)
                photoHits = []
                videoHits = []
            case .files:
                textHits = try await searchText(trimmed, retrieval: .hybrid(alpha: 0.7))
                photoHits = []
                videoHits = []
            case .photos:
                let context = try await openPhotos().recall(
                    PhotoQuery(text: trimmed, resultLimit: 8)
                )
                photoHits = context.items
                textHits = []
                videoHits = []
                if !context.items.isEmpty {
                    await generatePhotoAnswer(query: trimmed, items: context.items)
                }
            case .videos:
                let context = try await openVideos().recall(
                    VideoQuery(text: trimmed, resultLimit: 8, segmentLimitPerVideo: 3)
                )
                videoHits = context.items
                textHits = []
                photoHits = []
            }
            if currentHitsAreEmpty {
                notice = "No hits for “\(trimmed)” in \(mode.title)."
            } else {
                notice = loadCaption
            }
        } catch {
            notice = error.localizedDescription
        }
    }

    func refreshFoundationModelsStatus() {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            fmStatus = FoundationModelsStatus.publishedString(WaxFoundationModelsAvailability.current())
            return
        }
        #endif
        fmStatus = "unavailable"
    }

    func refreshStoreSize() {
        storeBytes = PhotoStoreChrome.fileSizeBytes(at: storeURL)
    }

    private var currentHitsAreEmpty: Bool {
        switch mode {
        case .vector, .files: textHits.isEmpty
        case .photos: photoHits.isEmpty
        case .videos: videoHits.isEmpty
        }
    }

    private func resolvedCorpus() throws -> HarborCorpus {
        if let corpus { return corpus }
        let opened = try HarborCorpus.resolve()
        corpus = opened
        return opened
    }

    private func ingestFiles(from corpus: HarborCorpus) async throws -> Int {
        let memory = try await openTextStore()
        for url in corpus.markdown {
            try await memory.save(fileAt: url)
        }
        for url in corpus.pdfs {
            try await memory.save(pdfAt: url)
        }
        try await memory.flush()
        refreshStoreSize()
        return corpus.files.count
    }

    private func ingestPhotos(from corpus: HarborCorpus) async throws -> Int {
        let files = corpus.images.map { PhotoFile(id: $0.lastPathComponent, url: $0) }
        let memory = try await openPhotos()
        try await memory.ingest(files: files)
        try await memory.flush()
        refreshStoreSize()
        return files.count
    }

    private func ingestVideos(from corpus: HarborCorpus) async throws -> Int {
        let files = corpus.videos.map {
            VideoFile(id: $0.deletingPathExtension().lastPathComponent, url: $0)
        }
        let memory = try await openVideos()
        try await memory.ingest(files: files)
        try await memory.flush()
        refreshStoreSize()
        return files.count
    }

    private func searchText(_ query: String, retrieval: Memory.RetrievalMode) async throws -> [RAGContext.Item] {
        let memory = try await openTextStore()
        var options = Memory.SearchOptions.default
        options.topK = 8
        options.mode = retrieval
        return try await memory.search(query, options: options).items
    }

    private func openTextStore() async throws -> Memory {
        if let existing = textStores[mode] { return existing }
        let enableVector = mode == .vector
        var config = Memory.Config.default
        config.enableTextSearch = true
        config.enableVectorSearch = enableVector
        config.embedding = enableVector ? .builtIn(.miniLM) : .automatic
        config.requireOnDeviceProviders = enableVector
        let opened = try await Memory(at: mode.storeURL(), config: config)
        textStores[mode] = opened
        return opened
    }

    private func openPhotos() async throws -> PhotoMemory {
        if let photos { return photos }
        let embedder = try await BuiltInMultimodalEmbeddings.make(.miniLM)
        let opened = try await PhotoMemory(
            at: DemoMode.photos.storeURL(),
            embedder: embedder,
            ocr: VisionOCRProvider()
        )
        photos = opened
        return opened
    }

    private func openVideos() async throws -> VideoMemory {
        if let videos { return videos }
        let corpus = try resolvedCorpus()
        let embedder = try await BuiltInMultimodalEmbeddings.make(.miniLM)
        let opened = try await VideoMemory(
            at: DemoMode.videos.storeURL(),
            embedder: embedder,
            transcriptProvider: try HarborTranscriptProvider(root: corpus.root)
        )
        videos = opened
        return opened
    }

    private func generatePhotoAnswer(query: String, items: [PhotoRAGItem]) async {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            switch WaxFoundationModelsAvailability.current() {
            case .available:
                fmStatus = FoundationModelsStatus.publishedString(.available)
            case .unavailable(let reason):
                fmStatus = reason
                return
            }
            isGenerating = true
            defer { isGenerating = false }
            do {
                let memory = try await Memory(at: StoreFilenames.memoryURL())
                let session = memory.foundationModelsSession(
                    instructions: FoundationModelsDemoSupport.instructions,
                    configuration: FoundationModelsDemoSupport.sessionConfiguration
                )
                try await session.streamTextSnapshots(
                    to: PhotoEvidencePrompt.make(query: query, items: items)
                ) { text in
                    await self.setAnswer(text)
                }
            } catch is CancellationError {
                return
            } catch {
                notice = error.localizedDescription
            }
            return
        }
        #endif
        fmStatus = "unavailable"
    }

    private func setAnswer(_ text: String) {
        answer = text
    }
}
