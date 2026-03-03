import Foundation

/// Store-level embedding identity binding persisted in the TOC extension area.
public struct MemoryBinding: Equatable, Sendable {
    public var embeddingProvider: String?
    public var embeddingModel: String?
    public var embeddingDimensions: UInt32?
    public var embeddingNormalized: Bool?

    public init(
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

    public var isEmpty: Bool {
        embeddingProvider == nil &&
            embeddingModel == nil &&
            embeddingDimensions == nil &&
            embeddingNormalized == nil
    }
}

extension MemoryBinding: BinaryCodable {
    public mutating func encode(to encoder: inout BinaryEncoder) throws {
        try encoder.encode(embeddingProvider)
        try encoder.encode(embeddingModel)
        encoder.encode(embeddingDimensions)
        let normalizedRaw: UInt8? = embeddingNormalized.map { $0 ? 1 : 0 }
        encoder.encode(normalizedRaw)
    }

    public static func decode(from decoder: inout BinaryDecoder) throws -> MemoryBinding {
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
