import CoreGraphics
import Foundation
import Wax

struct StubOCRProvider: OCRProvider, Sendable {
    let blocks: [RecognizedTextBlock]
    let executionMode: ProviderExecutionMode

    init(
        blocks: [RecognizedTextBlock] = [],
        executionMode: ProviderExecutionMode = .onDeviceOnly
    ) {
        self.blocks = blocks
        self.executionMode = executionMode
    }

    func recognizeText(in image: CGImage) async throws -> [RecognizedTextBlock] {
        _ = image
        return blocks
    }
}

struct StubCaptionProvider: CaptionProvider, Sendable {
    let captionText: String
    let shouldThrow: Bool
    let executionMode: ProviderExecutionMode

    init(
        captionText: String = "",
        shouldThrow: Bool = false,
        executionMode: ProviderExecutionMode = .onDeviceOnly
    ) {
        self.captionText = captionText
        self.shouldThrow = shouldThrow
        self.executionMode = executionMode
    }

    func caption(for image: CGImage) async throws -> String {
        _ = image
        if shouldThrow {
            throw MockEmbedderError.forcedFailure
        }
        return captionText
    }
}

/// Counts calls across copies of a provider; `next()` returns the 1-based call number.
actor ProviderCallCounter {
    private var count = 0

    func next() -> Int {
        count += 1
        return count
    }
}

/// Returns `blocks`, except that the `failOnCall`-th call (1-based) throws.
struct FailingOnCallOCRProvider: OCRProvider, Sendable {
    let blocks: [RecognizedTextBlock]
    let failOnCall: Int
    let executionMode: ProviderExecutionMode = .onDeviceOnly
    private let counter = ProviderCallCounter()

    init(blocks: [RecognizedTextBlock], failOnCall: Int) {
        self.blocks = blocks
        self.failOnCall = failOnCall
    }

    func recognizeText(in image: CGImage) async throws -> [RecognizedTextBlock] {
        _ = image
        if await counter.next() == failOnCall {
            throw MockEmbedderError.forcedFailure
        }
        return blocks
    }
}

/// A 4-D multimodal embedder whose `failOnImageCall`-th image embed (1-based) throws.
struct FailingOnCallImageEmbedder: MultimodalEmbeddingProvider, Sendable {
    let dimensions = 4
    let normalize = true
    let identity: EmbeddingIdentity? = EmbeddingIdentity(provider: "Mock", model: "FailingOnCall", dimensions: 4, normalized: true)
    let executionMode: ProviderExecutionMode = .onDeviceOnly
    let failOnImageCall: Int
    private let counter = ProviderCallCounter()

    init(failOnImageCall: Int) {
        self.failOnImageCall = failOnImageCall
    }

    func embed(text: String) async throws -> [Float] {
        _ = text
        return [1, 0, 0, 0]
    }

    func embed(image: CGImage) async throws -> [Float] {
        _ = image
        if await counter.next() == failOnImageCall {
            throw MockEmbedderError.forcedFailure
        }
        return [0, 1, 0, 0]
    }
}

struct StubTranscriptProvider: VideoTranscriptProvider, Sendable {
    let chunks: [VideoTranscriptChunk]
    let executionMode: ProviderExecutionMode

    init(
        chunks: [VideoTranscriptChunk] = [],
        executionMode: ProviderExecutionMode = .onDeviceOnly
    ) {
        self.chunks = chunks
        self.executionMode = executionMode
    }

    func transcript(for request: VideoTranscriptRequest) async throws -> [VideoTranscriptChunk] {
        _ = request
        return chunks
    }
}
