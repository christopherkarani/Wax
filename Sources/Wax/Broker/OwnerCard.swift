import Foundation
import WaxCore

/// Machine-owner standing card. Qualifying `remember` sentences fill one
/// slot; person-lane recall reads current rows instead of searching notes.
package enum OwnerCard {
    package static let ownerKey = EntityKey("wax.owner")
    package static let ownerKind = "person"
    package static let extractorId = "wax.owner-card"
    package static let extractorVersion = "1"

    package enum Slot: String, CaseIterable, Sendable {
        case xHandle = "x_handle"
        case github = "github"
        case currentProduct = "current_product"
        case revenueProduct = "revenue_product"
        case answerStyle = "answer_style"
        case implementor = "implementor"

        package var predicate: PredicateKey { PredicateKey(rawValue) }

        package var label: String {
            switch self {
            case .xHandle: return "X handle"
            case .github: return "GitHub"
            case .currentProduct: return "current product"
            case .revenueProduct: return "revenue product"
            case .answerStyle: return "answer style"
            case .implementor: return "implementor"
            }
        }
    }

    package struct Match: Sendable, Equatable {
        package var slot: Slot
        package var value: String
    }

    /// First matching slot, or nil. Tickets, lessons, and unmatched prefs skip.
    package static func match(content: String, memoryType: MemoryType) -> Match? {
        switch memoryType {
        case .userPreference, .fact:
            break
        case .note, .taskState, .decision, .lesson, .handoff, .constraint:
            return nil
        }
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        for slot in Slot.allCases {
            if let value = extract(slot, from: text) {
                return Match(slot: slot, value: value)
            }
        }
        return nil
    }

    package static func compileIfNeeded(
        memory: MemoryOrchestrator,
        content: String,
        metadata: [String: String],
        frameId: UInt64,
        nowMs: Int64
    ) async {
        let memoryType = metadata[MemoryMetadataKeys.type].flatMap(MemoryType.init(rawValue:)) ?? .note
        guard let match = match(content: content, memoryType: memoryType) else { return }
        do {
            try await apply(
                match,
                to: memory,
                frameId: frameId,
                nowMs: nowMs
            )
        } catch {
            WaxDiagnostics.logSwallowed(
                error,
                context: "owner card compile",
                fallback: "remember succeeded without updating the owner card"
            )
        }
    }

    /// Collapse current rows into one person-lane snippet so session-open
    /// `limit: 3` still has room for non-card prefs.
    package static func collapsedHit(
        from hits: [LayeredRecall.Hit],
        preview: @Sendable (String?) -> String
    ) -> LayeredRecall.Hit? {
        guard let first = hits.first else { return nil }
        if hits.count == 1 {
            var only = first
            only.flags.insert(.ownerCard)
            if !only.explanations.contains("owner card") {
                only.explanations = ["owner card"] + only.explanations
            }
            return only
        }
        let text = hits.map(\.text).joined(separator: " · ")
        return LayeredRecall.Hit(
            id: first.id,
            score: first.score,
            text: text,
            preview: preview(text),
            metadata: first.metadata,
            explanations: ["owner card"],
            timestampMs: first.timestampMs,
            sources: [.structured],
            flags: [.ownerCard]
        )
    }

    /// True when a searched note would compile to a card slot (drop it so the
    /// structured row does not occupy a second person-lane seat).
    package static func matchesCompiledSlot(text: String, metadata: [String: String]) -> Bool {
        let type = metadata[MemoryMetadataKeys.type].flatMap(MemoryType.init(rawValue:)) ?? .note
        return match(content: text, memoryType: type) != nil
    }

    package static func hits(
        from memory: MemoryOrchestrator,
        nowMs: Int64,
        preview: @Sendable (String?) -> String
    ) async -> [LayeredRecall.Hit] {
        let result: StructuredFactsResult
        do {
            result = try await memory.facts(
                about: ownerKey,
                predicate: nil,
                asOfMs: Int64.max,
                limit: 32
            )
        } catch {
            return []
        }
        var seen = Set<Slot>()
        var hits: [LayeredRecall.Hit] = []
        for slot in Slot.allCases {
            guard let hit = result.hits.first(where: { candidate in
                candidate.isOpenEnded
                    && candidate.relation != .retracts
                    && candidate.fact.predicate == slot.predicate
                    && stringValue(candidate.fact.object) != nil
            }) else { continue }
            guard seen.insert(slot).inserted else { continue }
            guard let value = stringValue(hit.fact.object) else { continue }
            let text = "\(slot.label): \(value)"
            let frameID = hit.evidence.last?.sourceFrameId ?? 0
            hits.append(
                LayeredRecall.Hit(
                    id: .durable(frameID: frameID),
                    score: 4,
                    text: text,
                    preview: preview(text),
                    metadata: [
                        MemoryMetadataKeys.type: MemoryType.userPreference.rawValue,
                        MemoryMetadataKeys.durability: MemoryDurability.durable.rawValue,
                    ],
                    explanations: ["owner card"],
                    timestampMs: hit.system.fromMs == 0 ? nowMs : hit.system.fromMs,
                    sources: [.structured],
                    flags: [.ownerCard]
                )
            )
        }
        return hits
    }

    package static func apply(
        _ match: Match,
        to memory: MemoryOrchestrator,
        frameId: UInt64,
        nowMs: Int64
    ) async throws {
        _ = try await memory.upsertEntity(
            key: ownerKey,
            kind: ownerKind,
            aliases: [],
            commit: false
        )
        let current = try await memory.facts(
            about: ownerKey,
            predicate: match.slot.predicate,
            asOfMs: Int64.max,
            limit: 32
        )
        let live = current.hits.filter { $0.isOpenEnded && $0.relation != .retracts }
        let normalized = normalize(match.value, slot: match.slot)
        if live.contains(where: { stringValue($0.fact.object).map { normalize($0, slot: match.slot) } == normalized })
            && live.allSatisfy({ stringValue($0.fact.object).map { normalize($0, slot: match.slot) } == normalized })
        {
            try await memory.flush()
            return
        }
        for hit in live {
            try await memory.retractFact(factId: hit.factId, atMs: nil, commit: false)
        }
        _ = try await memory.assertFact(
            subject: ownerKey,
            predicate: match.slot.predicate,
            object: .string(match.value),
            relation: .sets,
            validFromMs: nil,
            validToMs: nil,
            evidence: [
                StructuredEvidence(
                    sourceFrameId: frameId,
                    extractorId: extractorId,
                    extractorVersion: extractorVersion,
                    confidence: 1,
                    assertedAtMs: nowMs
                ),
            ],
            commit: true
        )
    }

    private static func extract(_ slot: Slot, from text: String) -> String? {
        switch slot {
        case .xHandle:
            return extractHandle(from: text)
        case .github:
            return firstCapture(
                patterns: [
                    #"(?i)github(?:\s+handle)?\s+is\s+([A-Za-z0-9-]{2,39})"#,
                    #"(?i)github:\s*([A-Za-z0-9-]{2,39})\b"#,
                ],
                in: text
            )
        case .currentProduct:
            return firstCapture(
                patterns: [#"((?i)current product is\s+([A-Za-z][A-Za-z0-9_-]{0,31}))"#],
                in: text
            ).flatMap { cleanedProduct($0) }
        case .revenueProduct:
            return firstCapture(
                patterns: [
                    #"(?i)treats?\s+([A-Za-z][A-Za-z0-9_-]{0,31})\s+as the revenue product"#,
                    #"(?i)revenue product is\s+([A-Za-z][A-Za-z0-9_-]{0,31})"#,
                    #"(?i)\b([A-Za-z][A-Za-z0-9_-]{0,31})\s+is the revenue product"#,
                ],
                in: text
            ).flatMap { cleanedProduct($0) }
        case .answerStyle:
            let lower = text.lowercased()
            if lower.contains("keep answers short") || lower.contains("lead with the answer") {
                return "short"
            }
            return nil
        case .implementor:
            let lower = text.lowercased()
            guard lower.contains("grok build") else { return nil }
            if lower.contains("do not use grok")
                || lower.contains("don't use grok")
                || lower.contains("dont use grok")
                || lower.contains("never use grok")
            {
                return nil
            }
            return "grok-build"
        }
    }

    private static let swiftAttributeHandles: Set<String> = [
        "mainactor", "observable", "environment", "published", "state",
        "binding", "viewbuilder", "escaping", "available", "unchecked",
        "sendable", "discardable", "frozen", "inlinable", "objc",
        "testable", "nsmanaged", "iboutlet", "ibaction",
    ]

    private static func extractHandle(from text: String) -> String? {
        if let live = firstCapture(
            patterns: [#"((?i)(?:live\s+)?(?:x|twitter)\s+handle is\s+@?([A-Za-z0-9_]{2,30}))"#],
            in: text
        ) {
            return formatHandle(live)
        }
        return lastUseHandle(in: text)
    }

    private static func formatHandle(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "@").union(.whitespaces))
        return "@\(trimmed)"
    }

    private static func lastUseHandle(in text: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?i)\buse\s+@([A-Za-z0-9_]{2,30})\b"#
        ) else { return nil }
        let nsText = text as NSString
        let full = NSRange(location: 0, length: nsText.length)
        var last: String?
        for match in regex.matches(in: text, range: full) {
            guard match.numberOfRanges >= 2,
                  let handleRange = Range(match.range(at: 1), in: text)
            else { continue }
            let handle = String(text[handleRange])
            if swiftAttributeHandles.contains(handle.lowercased()) { continue }
            let prefix = nsText.substring(
                with: NSRange(location: 0, length: match.range.location)
            ).lowercased()
            let tail = String(prefix.suffix(12))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if tail.hasSuffix("do not")
                || tail.hasSuffix("don't")
                || tail.hasSuffix("dont")
                || tail.hasSuffix("never")
            {
                continue
            }
            last = formatHandle(handle)
        }
        return last
    }

    private static func cleanedProduct(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let blocked: Set<String> = ["the", "a", "an", "this", "that", "our"]
        if blocked.contains(value.lowercased()) { return nil }
        return value
    }

    private static func normalize(_ value: String, slot: Slot) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch slot {
        case .xHandle:
            return trimmed.lowercased().hasPrefix("@") ? trimmed.lowercased() : "@\(trimmed.lowercased())"
        case .github, .currentProduct, .revenueProduct, .answerStyle, .implementor:
            return trimmed.lowercased()
        }
    }

    private static func stringValue(_ value: FactValue) -> String? {
        if case .string(let text) = value { return text }
        return nil
    }

    private static func firstCapture(patterns: [String], in text: String) -> String? {
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range) else { continue }
            let group = max(0, match.numberOfRanges - 1)
            guard let swiftRange = Range(match.range(at: group), in: text) else { continue }
            let value = String(text[swiftRange])
            if !value.isEmpty { return value }
        }
        return nil
    }
}
