import Foundation
import Wax

/// Embeds through `scripts/embed_server.py` on localhost, so Wax and a bare reference
/// retriever can share one model. Used with `--embedder http://127.0.0.1:<port>`.
struct HTTPEmbeddings: BatchEmbeddingProvider {
    let dimensions: Int
    let normalize = true
    let identity: EmbeddingIdentity?

    private let embedURL: URL
    private let session: URLSession

    private struct Info: Decodable {
        let model: String
        let dimensions: Int
    }

    private struct EmbedRequest: Encodable {
        let texts: [String]
    }

    private struct EmbedResponse: Decodable {
        let vectors: [[Float]]
    }

    static func connect(to base: URL) async throws -> HTTPEmbeddings {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 600
        let session = URLSession(configuration: configuration)
        let (data, response) = try await session.data(from: base.appendingPathComponent("info"))
        try checkStatus(response, data: data, url: base)
        let info = try JSONDecoder().decode(Info.self, from: data)
        guard info.dimensions > 0 else {
            throw BenchError.failed("embedding server at \(base) reported \(info.dimensions) dimensions")
        }
        return HTTPEmbeddings(
            dimensions: info.dimensions,
            identity: EmbeddingIdentity(
                provider: "wax-bench-http", model: info.model, dimensions: info.dimensions, normalized: true
            ),
            embedURL: base.appendingPathComponent("embed"),
            session: session
        )
    }

    func embed(_ text: String) async throws -> [Float] {
        let vectors = try await embed(batch: [text])
        guard let vector = vectors.first else {
            throw BenchError.failed("embedding server returned no vector")
        }
        return vector
    }

    func embed(batch texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        var request = URLRequest(url: embedURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(EmbedRequest(texts: texts))
        let (data, response) = try await session.data(for: request)
        try Self.checkStatus(response, data: data, url: embedURL)
        let vectors = try JSONDecoder().decode(EmbedResponse.self, from: data).vectors
        guard vectors.count == texts.count, vectors.allSatisfy({ $0.count == dimensions }) else {
            throw BenchError.failed("embedding server returned \(vectors.count) vectors for \(texts.count) texts")
        }
        return vectors
    }

    private static func checkStatus(_ response: URLResponse, data: Data, url: URL) throws {
        guard let http = response as? HTTPURLResponse else {
            throw BenchError.failed("no HTTP response from \(url)")
        }
        guard http.statusCode == 200 else {
            let body = String(decoding: data.prefix(300), as: UTF8.self)
            throw BenchError.failed("\(url) returned \(http.statusCode): \(body)")
        }
    }
}
