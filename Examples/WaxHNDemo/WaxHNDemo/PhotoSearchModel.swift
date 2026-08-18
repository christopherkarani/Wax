import Foundation
import Observation
import Photos
import Wax

@MainActor
@Observable
final class PhotoSearchModel {
    nonisolated static let resultLimit = 5

    var query = ""
    var hits: [PhotoRAGItem] = []
    var lastContext: PhotoRAGContext?
    var notice: String?
    var isPermissionBlocked = false
    var isBusy = false
    var isGenerating = false
    var answer = ""
    var fmStatus = "—"
    var photoStoreBytes: UInt64?
    var ingestReport: PhotoIngestReport?
    var libraryAuthStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)

    var photoStoreSizeLabel: String {
        PhotoStoreChrome.sizeLabel(bytes: photoStoreBytes)
    }

    var canSharePhotoStore: Bool {
        photoStoreBytes != nil
    }

    @ObservationIgnored
    private var photos: PhotoMemory?

    @ObservationIgnored
    private var textMemory: Memory?

    func requestLibraryAccessIfNeeded() async {
        libraryAuthStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard libraryAuthStatus == .notDetermined else { return }
        libraryAuthStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    func ingest(assetIDs: [String]) async {
        guard !assetIDs.isEmpty else {
            isPermissionBlocked = true
            notice = "PhotosPicker returned no asset identifiers. Photo library permission is required to index the photos you pick."
            return
        }

        isBusy = true
        defer { isBusy = false }

        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        libraryAuthStatus = status
        guard status == .authorized || status == .limited else {
            isPermissionBlocked = true
            notice = "Photos access is \(Self.describe(status)). Enable access in Settings to index the photos you pick."
            return
        }

        do {
            let memory = try await openPhotoMemory()
            try await memory.ingest(assetIDs: assetIDs)
            try await memory.flush()
            refreshPhotoStoreSize()
            isPermissionBlocked = false
            let report = try await Self.reportAfterPhotosIngest(memory: memory, assetIDs: assetIDs)
            ingestReport = report
            notice = PhotoIngestCopy.photosSuccess(report: report)
        } catch {
            notice = error.localizedDescription
        }
    }

    func ingest(files: [PhotoFile]) async {
        guard !files.isEmpty else { return }

        isBusy = true
        defer { isBusy = false }

        do {
            let memory = try await openPhotoMemory()
            try await memory.ingest(files: files)
            try await memory.flush()
            refreshPhotoStoreSize()
            isPermissionBlocked = false
            ingestReport = nil
            notice = PhotoIngestCopy.fileSuccess(count: files.count)
        } catch {
            notice = error.localizedDescription
        }
    }

    func refreshPhotoStoreSize() {
        photoStoreBytes = PhotoStoreChrome.fileSizeBytes()
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

    func recallHits() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isBusy = true
        isGenerating = false
        answer = ""

        do {
            let memory = try await openPhotoMemory()
            let context = try await memory.recall(
                PhotoQuery(text: trimmed, resultLimit: Self.resultLimit)
            )
            lastContext = context
            hits = context.items
            isPermissionBlocked = false
            if context.items.isEmpty {
                notice = PhotoIngestCopy.emptySearchNotice(report: ingestReport)
            } else {
                notice = nil
            }
            isBusy = false
            await Task.yield()
            await generateGroundedAnswerIfPossible(query: trimmed, items: context.items)
        } catch {
            notice = error.localizedDescription
            isBusy = false
        }
    }

    private func generateGroundedAnswerIfPossible(query: String, items: [PhotoRAGItem]) async {
        guard !items.isEmpty else { return }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            await generateGroundedAnswer(query: query, items: items)
            return
        }
        #endif
        fmStatus = "unavailable"
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    private func generateGroundedAnswer(query: String, items: [PhotoRAGItem]) async {
        switch WaxFoundationModelsAvailability.current() {
        case .available:
            fmStatus = FoundationModelsStatus.publishedString(.available)
        case .unavailable(let reason):
            fmStatus = reason
            answer = ""
            notice = reason
            return
        }

        isGenerating = true
        defer { isGenerating = false }

        do {
            let memory = try await openTextMemory()
            let session = memory.foundationModelsSession(
                instructions: FoundationModelsDemoSupport.instructions,
                configuration: FoundationModelsDemoSupport.sessionConfiguration
            )
            let prompt = PhotoEvidencePrompt.make(query: query, items: items)
            try await session.streamTextSnapshots(to: prompt) { text in
                await self.setAnswer(text)
            }
        } catch is CancellationError {
            return
        } catch {
            notice = error.localizedDescription
        }
    }
    #endif

    private func setAnswer(_ text: String) {
        answer = text
    }

    private static func reportAfterPhotosIngest(
        memory: PhotoMemory,
        assetIDs: [String]
    ) async throws -> PhotoIngestReport {
        let probe = try await memory.recall(
            PhotoQuery(
                filters: PhotoFilters(assetIDs: Set(assetIDs)),
                resultLimit: max(assetIDs.count, 1)
            )
        )
        return PhotoIngestReport.fromProbe(
            requested: assetIDs.count,
            returned: probe.items.count,
            degraded: probe.diagnostics.degradedResultCount
        )
    }

    private func openPhotoMemory() async throws -> PhotoMemory {
        if let photos {
            return photos
        }
        let embedder = try await BuiltInMultimodalEmbeddings.make(.miniLM)
        let opened = try await PhotoMemory(
            at: StoreFilenames.photosURL(),
            config: .default,
            embedder: embedder,
            ocr: VisionOCRProvider()
        )
        photos = opened
        refreshPhotoStoreSize()
        return opened
    }

    private func openTextMemory() async throws -> Memory {
        if let textMemory {
            return textMemory
        }
        let opened = try await Memory(at: StoreFilenames.memoryURL())
        textMemory = opened
        return opened
    }

    private static func describe(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: "not requested yet"
        case .restricted: "restricted"
        case .denied: "denied — enable in Settings"
        case .authorized: "full access"
        case .limited: "limited access"
        @unknown default: "unknown"
        }
    }
}
