import Foundation

/// Store-level embedding identity binding persisted in the TOC extension area.
package struct MemoryBinding: Equatable, Sendable {
    package var embeddingProvider: String?
    package var embeddingModel: String?
    package var embeddingDimensions: UInt32?
    package var embeddingNormalized: Bool?

    package init(
        embeddingProvider: String? = nil,
        embeddingModel: String? = nil,
        embeddingDimensions: UInt32? = nil,
        embeddingNormalized: Bool? = nil
    ) {
        self.embeddingProvider = embeddingProvider
        self.embeddingModel = embeddingModel
        self.embeddingDimensions = embeddingDimensions
        self.embeddingNormalized = embeddingNormalized
    }

    package var isEmpty: Bool {
        embeddingProvider == nil &&
            embeddingModel == nil &&
            embeddingDimensions == nil &&
            embeddingNormalized == nil
    }
}

extension MemoryBinding: BinaryCodable {
    package mutating func encode(to encoder: inout BinaryEncoder) throws {
        try encoder.encode(embeddingProvider)
        try encoder.encode(embeddingModel)
        encoder.encode(embeddingDimensions)
        let normalizedRaw: UInt8? = embeddingNormalized.map { $0 ? 1 : 0 }
        encoder.encode(normalizedRaw)
    }

    package static func decode(from decoder: inout BinaryDecoder) throws -> MemoryBinding {
        let provider = try decoder.decodeOptional(String.self)
        let model = try decoder.decodeOptional(String.self)
        let dimensions = try decoder.decodeOptional(UInt32.self)
        let normalizedRaw = try decoder.decodeOptional(UInt8.self)
        return MemoryBinding(
            embeddingProvider: provider,
            embeddingModel: model,
            embeddingDimensions: dimensions,
            embeddingNormalized: normalizedRaw.map { $0 != 0 }
        )
    }
}
