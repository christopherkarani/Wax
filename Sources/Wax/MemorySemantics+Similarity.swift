import Foundation

extension MemorySemantics {
    package static func normalizedTextFingerprint(_ text: String) -> String {
        let normalized = text.lowercased()
            .components(separatedBy: .alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return normalized
    }

    package static func similarity(lhs: String, rhs: String) -> Float {
        termJaccard(terms(lhs), terms(rhs))
    }

    private static func terms(_ text: String) -> Set<String> {
        Set(normalizedTextFingerprint(text).split(separator: " ").map(String.init))
    }

    private static func termJaccard(_ lhs: Set<String>, _ rhs: Set<String>) -> Float {
        guard !lhs.isEmpty || !rhs.isEmpty else { return 0 }
        let overlap = lhs.intersection(rhs).count
        let union = lhs.union(rhs).count
        guard union > 0 else { return 0 }
        return Float(overlap) / Float(union)
    }

    /// Term and identifier sets for one text, computed once so a corpus scan
    /// does not re-normalize and re-run the identifier regexes per pair.
    package struct TextSignature: Sendable, Equatable {
        package let terms: Set<String>
        package let identifiers: Set<String>
        /// Terms minus identifier tokens and stopwords: what the text says
        /// about its identifiers rather than which identifiers it names.
        package let contentTerms: Set<String>
        /// Whether the text negates ("not", "never", "don't", ...). See `isNegated`.
        package let negated: Bool

        package init(_ text: String) {
            let tokens = MemorySemantics.normalizedTextFingerprint(MemorySemantics.expandingNegatedContractions(text))
                .split(separator: " ")
                .map(String.init)
            let terms = Set(tokens)
            let identifiers = MemorySemantics.extractIdentifiers(text)
            let identifierTerms = Set(identifiers.flatMap { MemorySemantics.terms($0) })
            self.terms = terms
            self.identifiers = identifiers
            self.contentTerms = terms
                .subtracting(identifierTerms)
                .subtracting(MemorySemantics.nearTwinStopwords)
                .subtracting(MemorySemantics.negationTerms)
            self.negated = MemorySemantics.isNegated(tokens)
        }
    }

    /// Term Jaccard of two precomputed signatures.
    package static func similarity(_ lhs: TextSignature, _ rhs: TextSignature) -> Float {
        termJaccard(lhs.terms, rhs.terms)
    }

    /// Jaccard over content terms (identifiers, stopwords and negations removed).
    package static func contentSimilarity(_ lhs: TextSignature, _ rhs: TextSignature) -> Float {
        termJaccard(lhs.contentTerms, rhs.contentTerms)
    }

    package static func contentSimilarity(lhs: String, rhs: String) -> Float {
        contentSimilarity(TextSignature(lhs), TextSignature(rhs))
    }

    /// Function words dropped before the near-twin content comparison,
    /// so shared glue ("must be ... before the") cannot carry two different
    /// statements about the same identifiers over the floor.
    private static let nearTwinStopwords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "of", "to", "in", "on", "at", "for", "by",
        "with", "from", "as", "into", "is", "are", "was", "were", "be", "been", "being",
        "it", "its", "this", "that", "these", "those", "them", "they", "we", "you", "i",
        "do", "does", "did", "must", "should", "will", "would", "can", "could", "may",
        "might", "shall", "than", "then", "so", "if", "when", "s", "t",
    ]

    /// Negation markers. "n't" contractions are expanded to "not" first
    /// (`expandingNegatedContractions`). "without" is left out: it qualifies
    /// ("without blocking") far more often than it negates.
    private static let negationTerms: Set<String> = ["not", "no", "never", "cannot"]

    /// Contractions whose stem is not the positive verb ("can't" is not "ca not").
    private static let irregularNegatedContractions: [(regex: NSRegularExpression, expansion: String)] = [
        (makeRegex(#"(?i)\bcan['\u2019]t\b"#), "can not"),
        (makeRegex(#"(?i)\bwon['\u2019]t\b"#), "will not"),
        (makeRegex(#"(?i)\bshan['\u2019]t\b"#), "shall not"),
        (makeRegex(#"(?i)\bain['\u2019]t\b"#), "is not"),
    ]

    private static let negatedContractionRegex = makeRegex(#"(?i)n['\u2019]t\b"#)

    /// Rewrites "n't" contractions (straight or curly apostrophe) as "not", so
    /// "can't" / "don't" / "hasn't" read as negations instead of normalizing to
    /// "can" + "t", which are both stopwords.
    package static func expandingNegatedContractions(_ text: String) -> String {
        var result = text
        for contraction in irregularNegatedContractions {
            result = replacing(contraction.regex, in: result, with: contraction.expansion)
        }
        return replacing(negatedContractionRegex, in: result, with: " not")
    }

    private static func replacing(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: template
        )
    }

    /// True when a negation marker negates. Idioms that only look negative do
    /// not count: "no-op" (normalized "no op") and "not only".
    private static func isNegated(_ tokens: [String]) -> Bool {
        tokens.indices.contains { index in
            let token = tokens[index]
            guard negationTerms.contains(token) else { return false }
            let next = index + 1 < tokens.count ? tokens[index + 1] : nil
            if token == "no", next == "op" { return false }
            if token == "not", next == "only" { return false }
            return true
        }
    }

    package static let identifierJaccardThreshold: Float = 0.5

    package static let identifierSharedCountThreshold = 3

    /// Content-term Jaccard floor for a near-twin, so a long newer text that
    /// happens to contain every word of a short memory does not swallow it.
    package static let nearTwinContentSimilarityFloor: Float = 0.5

    private static let pascalCaseRegex = makeRegex(#"[A-Z][a-z0-9]+(?:[A-Z][a-zA-Z0-9]+)+"#)

    private static let issueNumberRegex = makeRegex(#"#\d+"#)

    /// 7-40 hex chars with at least one letter and one digit: dates, plain
    /// numbers and hex-only words ("defaced") are not SHAs.
    private static let hexSHARegex = makeRegex(#"\b(?=[0-9a-fA-F]*[a-fA-F])(?=[0-9a-fA-F]*[0-9])[0-9a-fA-F]{7,40}\b"#)

    /// `PROJ-42` / `PR-145` / `CVE-2024-1234` style keys, or the repo's own `C01` (two or more
    /// digits) and `T1` IDs. Other letter+digit tokens (A1, L2, GPT4, ARM64,
    /// SHA256, MD5, X86, V2, S3, H264) name technologies, not tickets.
    private static let ticketIDRegex = makeRegex(#"\b(?:[A-Z]{2,10}(?:-\d{1,6})+|C\d{2,4}|T\d{1,4})\b"#)

    /// Prefixes of standards written like ticket keys (UTF-8, SHA-256, ISO-8601).
    private static let standardKeyPrefixes: Set<String> = [
        "utf", "ucs", "sha", "aes", "des", "iso", "iec", "ieee", "rsa", "hmac",
        "crc", "tls", "ssl", "http", "ipv", "md", "arm", "gpt", "x",
    ]

    /// PascalCase tokens, `#123`, 7+ hex SHAs, and `PROJ-42` / `C01` / `T1`-style IDs.
    package static func extractIdentifiers(_ text: String) -> Set<String> {
        identifiers(in: text, matching: [pascalCaseRegex, issueNumberRegex, hexSHARegex, ticketIDRegex])
    }

    private static func identifiers(in text: String, matching regexes: [NSRegularExpression]) -> Set<String> {
        var ids = Set<String>()
        for regex in regexes {
            var matches = regexMatches(regex, in: text)
            if regex === pascalCaseRegex {
                // A PascalCase identifier has lowercase letters; without this, the hex tail of a
                // token like "AC1F4B6A" also matched as "C1F4B6A" and one shared token counted twice.
                matches = matches.filter { $0.contains(where: \.isLowercase) }
            } else if regex === ticketIDRegex {
                matches = matches.filter { match in
                    guard let dash = match.firstIndex(of: "-") else { return true }
                    return !standardKeyPrefixes.contains(match[..<dash].lowercased())
                }
            }
            ids.formUnion(matches.map { $0.lowercased() })
        }
        return ids
    }

    package static func identifierOverlap(lhs: String, rhs: String) -> (jaccard: Float, shared: Int) {
        identifierOverlap(extractIdentifiers(lhs), extractIdentifiers(rhs))
    }

    package static func identifierOverlap(
        _ lhs: TextSignature,
        _ rhs: TextSignature
    ) -> (jaccard: Float, shared: Int) {
        identifierOverlap(lhs.identifiers, rhs.identifiers)
    }

    private static func identifierOverlap(
        _ left: Set<String>,
        _ right: Set<String>
    ) -> (jaccard: Float, shared: Int) {
        guard !left.isEmpty, !right.isEmpty else { return (0, 0) }
        let shared = left.intersection(right).count
        let union = left.union(right).count
        guard union > 0 else { return (0, 0) }
        return (Float(shared) / Float(union), shared)
    }

    package static func identifiersMatch(_ lhs: String, _ rhs: String) -> Bool {
        identifiersMatch(overlap: identifierOverlap(lhs: lhs, rhs: rhs))
    }

    package static func identifiersMatch(_ lhs: TextSignature, _ rhs: TextSignature) -> Bool {
        identifiersMatch(overlap: identifierOverlap(lhs, rhs))
    }

    private static func identifiersMatch(overlap: (jaccard: Float, shared: Int)) -> Bool {
        if overlap.shared >= identifierSharedCountThreshold {
            return true
        }
        // A single shared SHA / PascalCase token is not a remaining-holes paraphrase.
        return overlap.shared >= 2 && overlap.jaccard >= identifierJaccardThreshold
    }

    /// Whether `newer` subsumes `older`, so `older` can be retired. Drives
    /// write-time auto-supersede, which is destructive; read-time hints use
    /// `isStaleTwin`. Callers pass the older and newer memory in order.
    /// True iff all of:
    /// 1. both agree on negation ("use X" vs "never use X", "can't" vs "can";
    ///    "no-op", "not only" and "without" do not count as negation);
    /// 2. every identifier `older` names (types, `#123`, SHAs, tickets) is also in `newer`;
    /// 3. every content term of `older` (lowercased terms minus identifier tokens,
    ///    stopwords and negations; numbers and units included) is also in `newer`:
    ///    `newer` may add words, never substitute or drop one;
    /// 4. content-term Jaccard >= `nearTwinContentSimilarityFloor` (0.5).
    /// A false negative only leaves a duplicate live; a false positive loses a
    /// fact, so anything short of subsumption stays live side by side. This is
    /// bag-of-words: it cannot tell role swaps apart ("A calls B" vs "B calls A").
    package static func isNearTwin(older: TextSignature, newer: TextSignature) -> Bool {
        older.negated == newer.negated
            && older.identifiers.isSubset(of: newer.identifiers)
            && older.contentTerms.isSubset(of: newer.contentTerms)
            && contentSimilarity(older, newer) >= nearTwinContentSimilarityFloor
    }

    package static func isNearTwin(older: String, newer: String) -> Bool {
        isNearTwin(older: TextSignature(older), newer: TextSignature(newer))
    }

    /// Term Jaccard at or above this lets the advisory `isStaleTwin` match a
    /// near-identical rewrite (a typo fix) that `isNearTwin` rejects.
    package static let staleTwinSimilarityThreshold: Float = 0.88

    /// Advisory, non-destructive test for `stale_hint` labels and read-time
    /// stale-twin demotion: `isNearTwin(older:newer:)`, or a near-identical
    /// rewrite (term Jaccard >= 0.88) whose negation agrees and which keeps
    /// every identifier `older` names. Directional, like `isNearTwin`.
    package static func isStaleTwin(older: TextSignature, newer: TextSignature) -> Bool {
        if isNearTwin(older: older, newer: newer) { return true }
        return older.negated == newer.negated
            && older.identifiers.isSubset(of: newer.identifiers)
            && similarity(older, newer) >= staleTwinSimilarityThreshold
    }

    private static func makeRegex(_ pattern: String) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern)
        } catch {
            preconditionFailure("invalid built-in identifier regex \(pattern): \(error)")
        }
    }

    private static func regexMatches(_ regex: NSRegularExpression, in text: String) -> [String] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }
}
