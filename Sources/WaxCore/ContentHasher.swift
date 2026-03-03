import Foundation

/// Stable hashing utility for frame content deduplication.
public enum ContentHasher {
    /// Computes the SHA-256 digest for canonical content bytes.
    public static func hash(_ content: Data) -> Data {
        SHA256Checksum.digest(content)
    }
}
