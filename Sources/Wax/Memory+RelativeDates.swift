import Foundation

extension Memory {
    /// Relative date resolution at save time (``Config/resolvesRelativeDates``).
    ///
    /// It applies only to texts whose metadata gives the day they were observed, under
    /// ``observedAtKey``. For those, `save`, `save(contentsOf:)` and `importDocuments` add the
    /// absolute date after English relative date phrases: "I went yesterday" saved with
    /// `wax.observed_at` `2023-08-22` is stored as "I went yesterday (21 Aug 2023)". Weeks
    /// become ranges ("last week (14–20 Aug 2023)"), months and years their names. Search,
    /// the text index and embeddings all see the annotated text; the original wording is
    /// never removed.
    ///
    /// A text saved without an observation day is stored exactly as given: Wax cannot tell
    /// text said just now from an old transcript or document, so it never guesses. For text
    /// observed as it is saved, pass ``observedAt(_:timeZone:)`` of the current date. A text
    /// without a resolvable phrase is stored exactly as given, whatever its metadata. Phrases
    /// whose date depends on context are left alone:
    /// possessives ("last week's report"), quoted speech, phrases next to an absolute date,
    /// "the last week", "last" meaning final ("my last week at Acme"), "next Friday" and
    /// "this Friday", "in two days", vague or partial amounts ("over a year ago",
    /// "twenty-two years ago"), "a week from today", and times in backshifted reported speech
    /// ("he said he would come tomorrow").
    public enum RelativeDates {
        /// Metadata key for the day a text was observed: exactly `yyyy-MM-dd`, or a complete
        /// ISO 8601 date-time such as `2023-08-22T17:00:00-07:00`. A save with any other value
        /// throws, and a batch or import with one rejects the whole call before writing.
        ///
        /// For a date-time, the calendar date as written is the day used, whatever its offset:
        /// `2023-08-22T00:00:00Z` is the 22nd even for a writer in California, where it was
        /// still the evening of the 21st. To record the day an instant fell on for the person
        /// who said it, pass ``observedAt(_:timeZone:)`` with their time zone instead.
        public static let observedAtKey = "wax.observed_at"

        /// The ``observedAtKey`` value for a text observed at `date`: its calendar day in
        /// `timeZone`, as `yyyy-MM-dd`.
        public static func observedAt(_ date: Date, timeZone: TimeZone = .current) -> String {
            ObservedDay.today(timeZone: timeZone, now: date).iso8601
        }

        /// The text as it was before annotation, given a stored document's full text and
        /// metadata. Text that was not annotated comes back unchanged.
        ///
        /// It applies only to a whole document as saved. Chunk frames of a long document carry
        /// the whole document's insertions, so their text returns `nil`, as does text edited
        /// after saving or malformed metadata.
        public static func originalText(_ text: String, metadata: [String: String]) -> String? {
            RelativeDateMetadata.originalText(text, metadata: metadata)
        }
    }

    /// The text and metadata a save stores: annotated when relative dates resolve.
    func prepareForSave(
        _ text: String,
        metadata: [String: String]
    ) throws -> (text: String, metadata: [String: String]) {
        guard resolvesRelativeDates else { return (text, metadata) }
        return try RelativeDateMetadata.prepare(text, metadata: metadata)
    }

    /// Every document prepared for saving.
    func prepareForSave(
        _ documents: some Sequence<(text: String, metadata: [String: String])>
    ) throws -> [(text: String, metadata: [String: String])] {
        try documents.map { try prepareForSave($0.text, metadata: $0.metadata) }
    }
}
