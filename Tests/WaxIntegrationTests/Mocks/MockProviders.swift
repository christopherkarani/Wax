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
