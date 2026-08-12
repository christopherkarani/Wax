#if canImport(ImageIO)
import CoreGraphics
import Foundation
import WaxCore
import WaxVectorSearch

/// Byte-oriented OCR provider for ``PhotoMemory``.
public protocol PhotoOCRProvider: Sendable {
    var executionMode: ProviderExecutionMode { get }
    func recognizeText(in imageData: Data, format: WaxImageFormat) async throws -> [PhotoMemory.RecognizedText]
}

/// Byte-oriented caption provider for ``PhotoMemory``.
public protocol PhotoCaptionProvider: Sendable {
    var executionMode: ProviderExecutionMode { get }
    func caption(for imageData: Data, format: WaxImageFormat) async throws -> String
}

package struct PhotoOCRProviderAdapter: CGImageOCRProvider {
    private let wrapped: any PhotoOCRProvider

    package init(_ wrapped: any PhotoOCRProvider) {
        self.wrapped = wrapped
    }

    package var executionMode: ProviderExecutionMode { wrapped.executionMode }

    package func recognizeText(in image: CGImage) async throws -> [RecognizedTextBlock] {
        let data = try WaxImageCodec.encodePNG(image)
        let blocks = try await wrapped.recognizeText(in: data, format: .png)
        return blocks.map { block in
            RecognizedTextBlock(
                text: block.text,
                bbox: PhotoNormalizedRect(
                    x: block.bbox.x,
                    y: block.bbox.y,
                    width: block.bbox.width,
                    height: block.bbox.height
                ),
                confidence: block.confidence,
                language: block.language
            )
        }
    }
}

package struct PhotoCaptionProviderAdapter: CGImageCaptionProvider {
    private let wrapped: any PhotoCaptionProvider

    package init(_ wrapped: any PhotoCaptionProvider) {
        self.wrapped = wrapped
    }

    package var executionMode: ProviderExecutionMode { wrapped.executionMode }

    package func caption(for image: CGImage) async throws -> String {
        let data = try WaxImageCodec.encodePNG(image)
        return try await wrapped.caption(for: data, format: .png)
    }
}

extension PhotoQueryImage.Format {
    init(_ format: WaxImageFormat) {
        switch format {
        case .jpeg:
            self = .jpeg
        case .png:
            self = .png
        case .heic:
            self = .heic
        case .other(let uti):
            self = .other(uti: uti)
        }
    }
}

extension PhotoFile {
    init(_ file: PhotoMemory.File) {
        self.init(id: file.id, url: file.url, captureDate: file.captureDate)
    }
}

extension PhotoQuery {
    init(_ query: PhotoMemory.Query) {
        let image: PhotoQueryImage?
        if let data = query.imageData {
            image = PhotoQueryImage(data: data, format: PhotoQueryImage.Format(query.imageFormat ?? .other(uti: "public.image")))
        } else {
            image = nil
        }
        self.init(
            text: query.text,
            image: image,
            timeRange: query.timeRange,
            resultLimit: query.resultLimit
        )
    }
}

extension PhotoMemory.Item {
    init(_ item: PhotoRAGItem) {
        self.init(
            assetID: item.assetID,
            score: item.score,
            summaryText: item.summaryText,
            thumbnail: item.thumbnail?.data,
            regions: item.regions.map { region in
                PhotoMemory.Region(
                    bbox: PhotoMemory.BoundingBox(
                        x: region.bbox.x,
                        y: region.bbox.y,
                        width: region.bbox.width,
                        height: region.bbox.height
                    ),
                    crop: region.crop?.data
                )
            }
        )
    }
}

extension PhotoMemory.Results {
    init(_ context: PhotoRAGContext) {
        self.init(
            items: context.items.map(PhotoMemory.Item.init),
            usedTextTokens: context.diagnostics.usedTextTokens,
            degradedResultCount: context.diagnostics.degradedResultCount
        )
    }
}

extension PhotoRAGConfig {
    init(_ config: PhotoMemory.Config) {
        self.init(
            ingestConcurrency: config.ingestConcurrency,
            embedMaxPixelSize: config.embedMaxPixelSize,
            ocrMaxPixelSize: config.ocrMaxPixelSize,
            enableOCR: config.enableOCR,
            enableRegionEmbeddings: config.enableRegionEmbeddings,
            maxRegionsPerPhoto: config.maxRegionsPerPhoto,
            searchTopK: config.searchTopK,
            hybridAlpha: config.hybridAlpha,
            vectorEnginePreference: .auto,
            requireOnDeviceProviders: false,
            includeThumbnailsInContext: config.includeThumbnailsInContext,
            includeRegionCropsInContext: config.includeRegionCropsInContext
        )
    }
}

#endif
