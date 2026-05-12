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
        return marker?.managed ?? true
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

    package static func markerComment(_ marker: MarkdownProjectionMarker) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(marker)) ?? Data("{}".utf8)
        let json = String(decoding: data, as: UTF8.self)
        return "\(markerPrefix)\(json) -->"
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
        let text = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
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
        guard let data = markerText.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MarkdownProjectionMarker.self, from: data)
    }
}
