import Foundation

/// Documents filenames for later phases. Do not open both stores on one URL.
/// Phase 02: PhotoMemory at `photos`. Phase 03: Memory at `memory`.
enum StoreFilenames {
    static let photos = "wax-hn-photos.wax"
    static let memory = "wax-hn-memory.wax"

    static func photosURL(in documents: URL = .documentsDirectory) -> URL {
        documents.appending(path: photos)
    }

    static func memoryURL(in documents: URL = .documentsDirectory) -> URL {
        documents.appending(path: memory)
    }
}
