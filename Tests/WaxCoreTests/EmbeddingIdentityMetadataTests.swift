import Foundation
import Testing
@testable import WaxCore

@Test func embeddingIdentityMetadataWritesCanonicalWaxKeysOnly() {
    var entries: [String: String] = [:]
    EmbeddingIdentityMetadata.write(
        into: &entries,
        provider: "Wax",
        model: "MiniLM",
        dimensions: 384,
        normalized: true
    )

    #expect(entries[EmbeddingIdentityMetadata.providerKey] == "Wax")
    #expect(entries[EmbeddingIdentityMetadata.modelKey] == "MiniLM")
    #expect(entries[EmbeddingIdentityMetadata.dimensionKey] == "384")
    #expect(entries[EmbeddingIdentityMetadata.normalizedKey] == "true")
    #expect(entries[EmbeddingIdentityMetadata.legacyProviderKey] == nil)
    #expect(entries[EmbeddingIdentityMetadata.legacyModelKey] == nil)
    #expect(entries[EmbeddingIdentityMetadata.legacyDimensionKey] == nil)
    #expect(entries[EmbeddingIdentityMetadata.legacyNormalizedKey] == nil)
}

@Test func rememberDedupEmbeddingIdentityMatchesCanonicalWaxKeys() {
    let identity = RememberDedupEmbeddingIdentity(
        provider: "Wax",
        model: "MiniLM",
        dimensions: 384,
        normalized: true
    )
    let entries = [
        EmbeddingIdentityMetadata.providerKey: "Wax",
        EmbeddingIdentityMetadata.modelKey: "MiniLM",
        EmbeddingIdentityMetadata.dimensionKey: "384",
        EmbeddingIdentityMetadata.normalizedKey: "true",
    ]
    #expect(identity.matches(metadataEntries: entries))
}

@Test func rememberDedupEmbeddingIdentityMatchesLegacyMemvidKeys() {
    let identity = RememberDedupEmbeddingIdentity(
        provider: "Wax",
        model: "MiniLM",
        dimensions: 384,
        normalized: true
    )
    let entries = [
        EmbeddingIdentityMetadata.legacyProviderKey: "Wax",
        EmbeddingIdentityMetadata.legacyModelKey: "MiniLM",
        EmbeddingIdentityMetadata.legacyDimensionKey: "384",
        EmbeddingIdentityMetadata.legacyNormalizedKey: "true",
    ]
    #expect(identity.matches(metadataEntries: entries))
}

@Test func rememberDedupEmbeddingIdentityPrefersCanonicalOverLegacyMismatch() {
    let identity = RememberDedupEmbeddingIdentity(provider: "Wax", model: "MiniLM")
    let entries = [
        EmbeddingIdentityMetadata.providerKey: "Wax",
        EmbeddingIdentityMetadata.modelKey: "MiniLM",
        EmbeddingIdentityMetadata.legacyProviderKey: "Other",
        EmbeddingIdentityMetadata.legacyModelKey: "OtherModel",
    ]
    #expect(identity.matches(metadataEntries: entries))
}

@Test func rememberDedupEmbeddingIdentityRejectsMismatchOnEitherNamespace() {
    let identity = RememberDedupEmbeddingIdentity(provider: "Wax", model: "MiniLM")
    #expect(!identity.matches(metadataEntries: [
        EmbeddingIdentityMetadata.providerKey: "Other",
        EmbeddingIdentityMetadata.modelKey: "MiniLM",
    ]))
    #expect(!identity.matches(metadataEntries: [
        EmbeddingIdentityMetadata.legacyProviderKey: "Other",
        EmbeddingIdentityMetadata.legacyModelKey: "MiniLM",
    ]))
}
