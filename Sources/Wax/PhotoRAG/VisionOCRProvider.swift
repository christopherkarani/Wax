#if canImport(Vision)
@preconcurrency import Vision

import CoreGraphics
import Foundation

public struct VisionOCRProvider: OCRProvider, Sendable {
    public enum Accuracy: Sendable {
        case fast
        case accurate
    }

    public var accuracy: Accuracy
    public var usesLanguageCorrection: Bool

    public init(accuracy: Accuracy = .accurate, usesLanguageCorrection: Bool = true) {
        self.accuracy = accuracy
        self.usesLanguageCorrection = usesLanguageCorrection
    }

    public func recognizeText(in image: CGImage) async throws -> [RecognizedTextBlock] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = (accuracy == .accurate) ? .accurate : .fast
        request.usesLanguageCorrection = usesLanguageCorrection

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        guard let observations = request.results else { return [] }

        var out: [RecognizedTextBlock] = []
        out.reserveCapacity(observations.count)

        for obs in observations {
            guard let top = obs.topCandidates(1).first else { continue }
            let text = top.string
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            // Vision bounding boxes are normalized with origin at bottom-left.
            let b = obs.boundingBox
            let topLeftY = 1.0 - Double(b.origin.y) - Double(b.size.height)
            let rect = PhotoNormalizedRect(
                x: Double(b.origin.x),
                y: topLeftY,
                width: Double(b.size.width),
                height: Double(b.size.height)
            )

            out.append(
                RecognizedTextBlock(
                    text: text,
                    bbox: rect,
                    confidence: Float(top.confidence),
                    language: nil
                )
            )
        }

        return out
    }
}

#endif
