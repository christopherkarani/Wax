import Foundation
import Wax

enum PhotoDrop {
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "gif", "webp",
    ]

    static func photoFiles(from urls: [URL]) -> [PhotoFile] {
        urls.compactMap { url in
            let ext = url.pathExtension.lowercased()
            guard imageExtensions.contains(ext) else { return nil }
            return PhotoFile(id: url.lastPathComponent, url: url)
        }
    }
}
