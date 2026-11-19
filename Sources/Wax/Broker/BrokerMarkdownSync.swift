import Foundation

package enum MarkdownProjectionKind: String, Sendable {
    case memory
    case dailyNote = "daily_note"
    case dreams
    case handoffs
}

package struct MarkdownProjectionMarker: Codable, Sendable, Equatable {
    package var managed: Bool
    package var sourceKind: String
    package var frameID: UInt64?
    package var memoryID: String?
    package var hash: String
    package var sessionID: String?
    package var sourceFrameID: UInt64?
    package var memoryType: String?
    package var durability: String?
    package var confidence: Float?
    package var dateKey: String?
    /// `json` when the item's text is written as a JSON string literal, because
    /// the raw text would not parse back exactly (newlines, edge whitespace, a
    /// leading checkbox). Absent for raw text, as in files written before it.
    package var textEncoding: String?

    package init(
        managed: Bool = true,
        sourceKind: String,
        frameID: UInt64? = nil,
        memoryID: String? = nil,
        hash: String,
        sessionID: String? = nil,
        sourceFrameID: UInt64? = nil,
        memoryType: String? = nil,
        durability: String? = nil,
        confidence: Float? = nil,
        dateKey: String? = nil
    ) {
        self.managed = managed
        self.sourceKind = sourceKind
        self.frameID = frameID
        self.memoryID = memoryID
        self.hash = hash
        self.sessionID = sessionID
        self.sourceFrameID = sourceFrameID
        self.memoryType = memoryType
        self.durability = durability
        self.confidence = confidence
        self.dateKey = dateKey
    }
}

package struct MarkdownProjectionEntry: Sendable, Equatable {
    package var text: String
    package var lineNumber: Int
    package var section: String?
    package var checked: Bool?
    package var marker: MarkdownProjectionMarker?

    package var isManagedImportCandidate: Bool {
        guard !text.isEmpty else { return false }
        return marker?.managed == true
    }
}

package struct MarkdownSyncCounts: Sendable, Equatable {
    package var created: Int = 0
    package var updated: Int = 0
    package var deleted: Int = 0
    package var unchanged: Int = 0
    package var approvedDreams: Int = 0
    package var rejectedDreams: Int = 0
}

package struct MarkdownSyncReport: Sendable, Equatable {
    package var rootDir: String
    package var memoryPath: String?
    package var dailyNotePaths: [String]
    package var dreamsPath: String?
    package var counts: MarkdownSyncCounts
}

package enum BrokerMarkdownSync {
    private static let markerPrefix = "<!-- wax:"
    private static let base64MarkerPrefix = "b64:"

    package static func markerComment(_ marker: MarkdownProjectionMarker) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(marker)) ?? Data("{}".utf8)
        return "\(markerPrefix)\(base64MarkerPrefix)\(data.base64EncodedString()) -->"
    }

    /// One list item on one physical line that ``parse(text:)`` reads back as
    /// exactly `text`. Text that parses back as written stays raw, as people
    /// edit these files; anything else becomes a JSON string literal.
    package static func renderListItem(
        prefix: String,
        text: String,
        marker: MarkdownProjectionMarker
    ) -> String {
        var rawMarker = marker
        rawMarker.textEncoding = nil
        let raw = "\(prefix) \(text) \(markerComment(rawMarker))"
        let parsed = parse(text: raw)
        if parsed.count == 1, parsed[0].text == text, parsed[0].marker != nil {
            return raw
        }
        var encodedMarker = marker
        encodedMarker.textEncoding = jsonTextEncoding
        return "\(prefix) \(jsonStringLiteral(text)) \(markerComment(encodedMarker))"
    }

    private static let jsonTextEncoding = "json"

    private static func jsonStringLiteral(_ text: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = (try? encoder.encode(text)) ?? Data("\"\"".utf8)
        // JSON leaves these raw, but `parse` splits lines on them.
        return String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\u{85}", with: "\\u0085")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    package static func parseFile(at url: URL) throws -> [MarkdownProjectionEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let text = try String(contentsOf: url, encoding: .utf8)
        return parse(text: text)
    }

    package static func parse(text: String) -> [MarkdownProjectionEntry] {
        var entries: [MarkdownProjectionEntry] = []
        var currentSection: String?

        for (index, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                currentSection = String(line.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }
            guard let parsed = parseListItem(line, lineNumber: index + 1, section: currentSection) else {
                continue
            }
            entries.append(parsed)
        }

        return entries
    }

    private static func parseListItem(
        _ line: String,
        lineNumber: Int,
        section: String?
    ) -> MarkdownProjectionEntry? {
        guard line.hasPrefix("- ") else { return nil }
        var remainder = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)

        var checked: Bool?
        if remainder.hasPrefix("[ ] ") {
            checked = false
            remainder = String(remainder.dropFirst(4))
        } else if remainder.lowercased().hasPrefix("[x] ") {
            checked = true
            remainder = String(remainder.dropFirst(4))
        }

        let marker = extractMarker(from: &remainder)
        var text = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        // An edit that broke the literal is imported as the person wrote it.
        if marker?.textEncoding == jsonTextEncoding,
           let decoded = try? JSONDecoder().decode(String.self, from: Data(text.utf8)) {
            text = decoded
        }
        guard !text.isEmpty else { return nil }

        return MarkdownProjectionEntry(
            text: text,
            lineNumber: lineNumber,
            section: section,
            checked: checked,
            marker: marker
        )
    }

    private static func extractMarker(from line: inout String) -> MarkdownProjectionMarker? {
        guard let range = line.range(of: markerPrefix, options: [.backwards]),
              let endRange = line.range(of: "-->", options: [.backwards]),
              range.lowerBound < endRange.lowerBound else {
            return nil
        }

        let markerText = line[range.upperBound..<endRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        line = String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let data: Data?
        if markerText.hasPrefix(base64MarkerPrefix) {
            data = Data(base64Encoded: String(markerText.dropFirst(base64MarkerPrefix.count)))
        } else {
            data = markerText.data(using: .utf8)
        }
        guard let data else { return nil }
        return try? JSONDecoder().decode(MarkdownProjectionMarker.self, from: data)
    }
}
