import Foundation

enum PhotoStoreChrome {
    static let shareURL = StoreFilenames.photosURL()
    static let honestLine =
        "Index (text + vectors). Original photos stay in Photos. Recall works offline."

    static func fileSizeBytes(
        at url: URL = StoreFilenames.photosURL(),
        fileManager: FileManager = .default
    ) -> UInt64? {
        guard
            let values = try? fileManager.attributesOfItem(atPath: url.path(percentEncoded: false)),
            let size = values[.size] as? NSNumber
        else {
            return nil
        }
        return size.uint64Value
    }

    static func sizeLabel(bytes: UInt64?) -> String {
        guard let bytes else { return "—" }
        let megabytes = Double(bytes) / 1_048_576
        let formatted = megabytes.formatted(
            .number.precision(.fractionLength(1)).locale(Locale(identifier: "en_US_POSIX"))
        )
        return "\(formatted) MB"
    }

    static func statusLine(size: String, fmStatus: String) -> String {
        "No account · \(size) · FM \(fmStatus)"
    }
}
