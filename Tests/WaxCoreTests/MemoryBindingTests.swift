import Foundation
import Testing
@testable import WaxCore

@Test func memoryBindingRoundTrips() throws {
    let binding = MemoryBinding(
        embeddingProvider: "local",
        embeddingModel: "all-MiniLM-L6-v2",
        embeddingDimensions: 384,
        embeddingNormalized: true
    )

    var encoder = BinaryEncoder()
    var mutable = binding
    try mutable.encode(to: &encoder)

    var decoder = try BinaryDecoder(data: encoder.data)
    let decoded = try MemoryBinding.decode(from: &decoder)
    try decoder.finalize()

    #expect(decoded == binding)
}

@Test func waxTocRoundTripsMemoryBinding() throws {
    var toc = WaxTOC.emptyV1()
    toc.memoryBinding = MemoryBinding(
        embeddingProvider: "providerA",
        embeddingModel: "modelA",
        embeddingDimensions: 768,
        embeddingNormalized: false
    )

    let bytes = try toc.encode()
    let decoded = try WaxTOC.decode(from: bytes)

    #expect(decoded.memoryBinding == toc.memoryBinding)
}

@Test func waxTocMissingMemoryBindingTagDecodesAsNil() throws {
    let toc = WaxTOC.emptyV1()
    let bytes = try toc.encode()
    let decoded = try WaxTOC.decode(from: bytes)
    #expect(decoded.memoryBinding == nil)
}

@Test func waxTocEmptyMemoryBindingEncodesAsAbsent() throws {
    var toc = WaxTOC.emptyV1()
    toc.memoryBinding = MemoryBinding()
    let bytes = try toc.encode()
    let decoded = try WaxTOC.decode(from: bytes)
    #expect(decoded.memoryBinding == nil)
}
