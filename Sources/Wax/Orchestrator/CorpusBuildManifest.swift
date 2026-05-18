import Foundation

package struct CorpusBuildManifest: Codable, Equatable, Sendable {
    package struct BuildConfiguration: Codable, Equatable, Sendable {
        package var noEmbedder: Bool
        package var embedderChoice: String
        package var recursive: Bool

        package init(
            noEmbedder: Bool,
            embedderChoice: String,
            recursive: Bool
        ) {
            self.noEmbedder = noEmbedder
            self.embedderChoice = embedderChoice
            self.recursive = recursive
        }
    }

    package struct SourceFingerprint: Codable, Equatable, Sendable {
        package var path: String
        package var fileSizeBytes: Int64
        package var modificationTimeMs: Int64

        package init(path: String, fileSizeBytes: Int64, modificationTimeMs: Int64) {
            self.path = path
            self.fileSizeBytes = fileSizeBytes
            self.modificationTimeMs = modificationTimeMs
        }
    }

    package static let currentVersion = 1

    package var version: Int
    package var configuration: BuildConfiguration
    package var sources: [SourceFingerprint]
    package var generatedAtMs: Int64

    package init(
        version: Int = Self.currentVersion,
        configuration: BuildConfiguration,
        sources: [SourceFingerprint],
        generatedAtMs: Int64
    ) {
        self.version = version
        self.configuration = configuration
        self.sources = sources
        self.generatedAtMs = generatedAtMs
    }
}

package enum CorpusBuildManifestStore {
    private static let decoder = JSONDecoder()
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    package static func load(for targetStoreURL: URL) throws -> CorpusBuildManifest? {
        let manifestURL = manifestURL(for: targetStoreURL)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: manifestURL)
        do {
            return try decoder.decode(CorpusBuildManifest.self, from: data)
        } catch is DecodingError {
            return nil
        }
    }

    package static func save(_ manifest: CorpusBuildManifest, for targetStoreURL: URL) throws {
        let manifestURL = manifestURL(for: targetStoreURL)
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL, options: .atomic)
    }

    package static func delete(for targetStoreURL: URL) throws {
        let manifestURL = manifestURL(for: targetStoreURL)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: manifestURL)
    }

    package static func manifestURL(for targetStoreURL: URL) -> URL {
        URL(fileURLWithPath: targetStoreURL.path + ".manifest.json")
    }

    package static func fingerprints(for storeURLs: [URL]) throws -> [CorpusBuildManifest.SourceFingerprint] {
        try storeURLs.map(fingerprint(for:))
    }

    private static func fingerprint(for storeURL: URL) throws -> CorpusBuildManifest.SourceFingerprint {
        let standardized = storeURL.standardizedFileURL
        let resourceValues = try standardized.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey,
        ])
        let fileSizeBytes = Int64(resourceValues.fileSize ?? 0)
        let modificationTimeMs = Int64((resourceValues.contentModificationDate ?? .distantPast).timeIntervalSince1970 * 1000)
        return CorpusBuildManifest.SourceFingerprint(
            path: standardized.path,
            fileSizeBytes: fileSizeBytes,
            modificationTimeMs: modificationTimeMs
        )
    }
}
