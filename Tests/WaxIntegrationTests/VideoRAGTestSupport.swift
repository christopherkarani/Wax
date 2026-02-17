import AVFoundation
import CoreVideo
import Foundation
import Wax

enum VideoRAGTestSupport {
    static func openWritableTextOnlySession(wax: Wax) async throws -> WaxSession {
        let config = WaxSession.Config(
            enableTextSearch: true,
            enableVectorSearch: false,
            enableStructuredMemory: false,
            vectorEnginePreference: .cpuOnly,
            vectorMetric: .cosine,
            vectorDimensions: nil
        )
        return try await wax.openSession(.readWrite(.wait), config: config)
    }

    @discardableResult
    static func putRoot(
        session: WaxSession,
        videoID: VideoID,
        captureTimestampMs: Int64,
        durationMs: Int64 = 1_000,
        fileURL: URL? = nil
    ) async throws -> UInt64 {
        var meta = Metadata()
        meta.entries[VideoMetadataKey.source.rawValue] = (videoID.source == .photos) ? "photos" : "file"
        meta.entries[VideoMetadataKey.sourceID.rawValue] = videoID.id
        meta.entries[VideoMetadataKey.captureMs.rawValue] = String(captureTimestampMs)
        meta.entries[VideoMetadataKey.durationMs.rawValue] = String(durationMs)
        meta.entries[VideoMetadataKey.isLocal.rawValue] = "true"
        meta.entries[VideoMetadataKey.pipelineVersion.rawValue] = "test"
        if let fileURL {
            meta.entries[VideoMetadataKey.fileURL.rawValue] = fileURL.absoluteString
        }

        let options = FrameMetaSubset(kind: VideoFrameKind.root.rawValue, metadata: meta)
        return try await session.put(Data(), options: options, compression: .plain, timestampMs: captureTimestampMs)
    }

    @discardableResult
    static func putSegment(
        session: WaxSession,
        rootId: UInt64,
        videoID: VideoID,
        captureTimestampMs: Int64,
        segmentIndex: Int,
        segmentCount: Int,
        startMs: Int64,
        endMs: Int64,
        transcript: String
    ) async throws -> UInt64 {
        var meta = Metadata()
        meta.entries[VideoMetadataKey.source.rawValue] = (videoID.source == .photos) ? "photos" : "file"
        meta.entries[VideoMetadataKey.sourceID.rawValue] = videoID.id
        meta.entries[VideoMetadataKey.captureMs.rawValue] = String(captureTimestampMs)
        meta.entries[VideoMetadataKey.isLocal.rawValue] = "true"
        meta.entries[VideoMetadataKey.pipelineVersion.rawValue] = "test"
        meta.entries[VideoMetadataKey.segmentIndex.rawValue] = String(segmentIndex)
        meta.entries[VideoMetadataKey.segmentCount.rawValue] = String(segmentCount)
        meta.entries[VideoMetadataKey.segmentStartMs.rawValue] = String(startMs)
        meta.entries[VideoMetadataKey.segmentEndMs.rawValue] = String(endMs)
        meta.entries[VideoMetadataKey.segmentMidMs.rawValue] = String((startMs + endMs) / 2)

        let options = FrameMetaSubset(kind: VideoFrameKind.segment.rawValue, role: .blob, parentId: rootId, metadata: meta)
        let frameId = try await session.put(
            Data(transcript.utf8),
            options: options,
            compression: .plain,
            timestampMs: captureTimestampMs
        )
        try await session.indexText(frameId: frameId, text: transcript)
        return frameId
    }
}

enum VideoRAGTestVideoGenerator {
    static func writeTinyMP4(
        to url: URL,
        width: Int = 32,
        height: Int = 32,
        frameCount: Int = 2,
        fps: Int32 = 2
    ) async throws {
        try? FileManager.default.removeItem(at: url)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = false

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attributes)

        guard writer.canAdd(input) else {
            throw WaxError.io("VideoRAGTestVideoGenerator: AVAssetWriter cannot add video input")
        }
        writer.add(input)

        guard writer.startWriting() else {
            throw writer.error ?? WaxError.io("VideoRAGTestVideoGenerator: startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)

        let frameDuration = CMTime(value: 1, timescale: fps)

        for index in 0..<max(0, frameCount) {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(1))
            }

            let buffer = try makeSolidPixelBuffer(
                width: width,
                height: height,
                bgra: index.isMultiple(of: 2) ? (0x00, 0x00, 0xFF, 0xFF) : (0x00, 0xFF, 0x00, 0xFF)
            )
            let time = CMTimeMultiply(frameDuration, multiplier: Int32(index))
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw writer.error ?? WaxError.io("VideoRAGTestVideoGenerator: failed to append frame \(index)")
            }
        }

        input.markAsFinished()

        final class WriterBox: @unchecked Sendable {
            let writer: AVAssetWriter
            init(_ writer: AVAssetWriter) { self.writer = writer }
        }

        let writerBox = WriterBox(writer)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            writerBox.writer.finishWriting {
                if let error = writerBox.writer.error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }

        if writerBox.writer.status != .completed {
            throw writerBox.writer.error ?? WaxError.io("VideoRAGTestVideoGenerator: writer not completed")
        }
    }

    private static func makeSolidPixelBuffer(
        width: Int,
        height: Int,
        bgra: (UInt8, UInt8, UInt8, UInt8)
    ) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw WaxError.io("VideoRAGTestVideoGenerator: CVPixelBufferCreate failed: \(status)")
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw WaxError.io("VideoRAGTestVideoGenerator: CVPixelBufferGetBaseAddress returned nil")
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for y in 0..<height {
            let row = baseAddress.advanced(by: y * bytesPerRow)
            for x in 0..<width {
                let pixel = row.advanced(by: x * 4)
                pixel.storeBytes(of: bgra.0, as: UInt8.self)
                pixel.advanced(by: 1).storeBytes(of: bgra.1, as: UInt8.self)
                pixel.advanced(by: 2).storeBytes(of: bgra.2, as: UInt8.self)
                pixel.advanced(by: 3).storeBytes(of: bgra.3, as: UInt8.self)
            }
        }

        return pixelBuffer
    }
}
