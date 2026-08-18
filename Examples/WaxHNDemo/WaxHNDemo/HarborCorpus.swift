import Foundation

enum HarborCorpusError: Error, LocalizedError {
    case missing(URL)

    var errorDescription: String? {
        switch self {
        case .missing(let url):
            "Harbor corpus not found at \(url.path)"
        }
    }
}

struct HarborCorpus: Sendable {
    let root: URL
    let images: [URL]
    let videos: [URL]
    let files: [URL]

    var markdown: [URL] {
        files.filter { $0.pathExtension.lowercased() == "md" }
    }

    var pdfs: [URL] {
        files.filter { $0.pathExtension.lowercased() == "pdf" }
    }

    static func repoRoot(from filePath: String) -> URL {
        URL(fileURLWithPath: filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "WaxDemoCorpus")
    }

    static func make(root: URL) throws -> HarborCorpus {
        let images = listed(in: root.appending(path: "images"), extensions: ["png", "jpg", "jpeg", "heic"])
        let videos = listed(in: root.appending(path: "videos"), extensions: ["mp4", "mov"])
        let files = listed(in: root.appending(path: "files"), extensions: ["md", "txt", "pdf"])
        guard !images.isEmpty, !videos.isEmpty, !files.isEmpty else {
            throw HarborCorpusError.missing(root)
        }
        return HarborCorpus(root: root, images: images, videos: videos, files: files)
    }

    static func resolve() throws -> HarborCorpus {
        let candidates: [URL] = [
            Bundle.main.url(forResource: "WaxDemoCorpus", withExtension: nil),
            Bundle.main.resourceURL?.appending(path: "WaxDemoCorpus"),
            Bundle.main.resourceURL,
            repoRoot(from: #filePath),
        ].compactMap { $0 }

        for root in candidates {
            if let corpus = try? make(root: root) {
                return corpus
            }
        }
        throw HarborCorpusError.missing(candidates.last ?? URL(fileURLWithPath: "/WaxDemoCorpus"))
    }

    private static func listed(in directory: URL, extensions: Set<String>) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls
            .filter { extensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
