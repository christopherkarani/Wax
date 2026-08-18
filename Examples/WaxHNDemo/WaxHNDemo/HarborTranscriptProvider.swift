import Foundation
import Wax

struct HarborTranscriptProvider: VideoTranscriptProvider {
    var executionMode: ProviderExecutionMode { .onDeviceOnly }

    let chunksByID: [String: [VideoTranscriptChunk]]

    var videoIDs: [String] {
        chunksByID.keys.sorted()
    }

    init(root: URL) throws {
        let directory = root.appending(path: "transcripts")
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        var mapped: [String: [VideoTranscriptChunk]] = [:]
        for url in urls where url.pathExtension.lowercased() == "json" {
            let decoded = try JSONDecoder().decode(Sidecar.self, from: Data(contentsOf: url))
            mapped[decoded.id] = decoded.chunks.map {
                VideoTranscriptChunk(startMs: $0.startMs, endMs: $0.endMs, text: $0.text)
            }
        }
        chunksByID = mapped
    }

    func chunks(for id: String) -> [VideoTranscriptChunk] {
        chunksByID[id] ?? []
    }

    func transcript(for request: VideoTranscriptRequest) async throws -> [VideoTranscriptChunk] {
        let fromFile = request.localFileURL.deletingPathExtension().lastPathComponent
        return chunksByID[fromFile] ?? chunksByID[request.videoID.id] ?? []
    }
}

private struct Sidecar: Decodable {
    var id: String
    var chunks: [Chunk]

    struct Chunk: Decodable {
        var startMs: Int64
        var endMs: Int64
        var text: String

        enum CodingKeys: String, CodingKey {
            case startMs = "start_ms"
            case endMs = "end_ms"
            case text
        }
    }
}
