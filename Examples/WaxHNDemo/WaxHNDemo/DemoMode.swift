import Foundation

enum DemoMode: String, CaseIterable, Identifiable, Sendable {
    case vector
    case files
    case photos
    case videos

    var id: String { rawValue }

    var title: String {
        switch self {
        case .vector: "Vector"
        case .files: "Files"
        case .photos: "Photos"
        case .videos: "Videos"
        }
    }

    var placeholder: String {
        switch self {
        case .vector: "Paraphrase a Harbor fact"
        case .files: "Search notes and PDFs"
        case .photos: "Search text in photos"
        case .videos: "Search spoken clips"
        }
    }

    var suggestedQuery: String {
        switch self {
        case .vector: "how do we keep memory on the device"
        case .files: "what is the offline policy"
        case .photos: "WAX-HB-4419"
        case .videos: "when do we ship"
        }
    }

    var storeFilename: String {
        switch self {
        case .vector: "wax-hn-vector.wax"
        case .files: "wax-hn-files.wax"
        case .photos: StoreFilenames.photos
        case .videos: "wax-hn-videos.wax"
        }
    }

    func storeURL(in documents: URL = .documentsDirectory) -> URL {
        documents.appending(path: storeFilename)
    }
}
