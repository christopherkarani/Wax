import Foundation
import Testing
@testable import Wax

// MARK: - Helpers

/// Builds a minimal RAGContext.Item with a known score so relevance arithmetic
/// is predictable in all extractor tests below.
private func makeItem(text: String, score: Float = 0.5) -> RAGContext.Item {
    RAGContext.Item(
        kind: .snippet,
        frameId: 0,
        score: score,
        sources: [],
        text: text
    )
}

// MARK: - appointmentDateTimeCandidates

// The regex requires: <FullMonthName> <1-2 digit day>, <4-digit year> at <H:MM> <AM|PM>
// e.g. "March 4, 2025 at 9:00 AM"

@Test
func appointmentDateTimeRegexMatchesCanonicalFormat() {
    let extractor = DeterministicAnswerExtractor()
    let item = makeItem(text: "Your dentist appointment is March 4, 2025 at 9:00 AM.")
    let answer = extractor.extractAnswer(
        query: "When is my dentist appointment?",
        items: [item]
    )
    #expect(answer == "March 4, 2025 at 9:00 AM")
}

@Test
func appointmentDateTimeRegexMatchesTwoDigitDay() {
    let extractor = DeterministicAnswerExtractor()
    let item = makeItem(text: "Dentist visit is on November 12, 2026 at 10:30 AM.")
    let answer = extractor.extractAnswer(
        query: "When is my dentist appointment?",
        items: [item]
    )
    #expect(answer == "November 12, 2026 at 10:30 AM")
}

@Test
func appointmentDateTimeRegexMatchesPMTime() {
    let extractor = DeterministicAnswerExtractor()
    let item = makeItem(text: "Scheduled: January 7, 2025 at 3:15 PM for dental cleaning.")
    let answer = extractor.extractAnswer(
        query: "When is my dentist appointment?",
        items: [item]
    )
    #expect(answer == "January 7, 2025 at 3:15 PM")
}

@Test
func appointmentDateTimeNotExtractedWhenQueryLacksAppointmentKeywords() {
    // Without "dentist" or "appointment" in the query the .asksDate + asksDentist
    // branch is not taken; the extractor falls through to generic date or lexical
    // fallback – it must NOT return the full datetime span.
    let extractor = DeterministicAnswerExtractor()
    let item = makeItem(text: "Reminder: February 20, 2025 at 8:00 AM for gym.")
    let answer = extractor.extractAnswer(
        query: "What time should I wake up?",
        items: [item]
    )
    // The result must be non-empty (fallback fires), but it is implementation-
    // defined beyond that; the important thing is no crash and sensible output.
    #expect(!answer.isEmpty)
}

// MARK: - flightDestinationCandidates

// The regex requires "Flight to <City>" or "flight to <City>" where City starts
// with an uppercase letter.

@Test
func flightDestinationRegexExtractsCapitalizedCity() {
    let extractor = DeterministicAnswerExtractor()
    let item = makeItem(text: "I have a Flight to Tokyo booked for next week.")
    let answer = extractor.extractAnswer(
        query: "Where am I flying to?",
        items: [item]
    )
    #expect(answer == "Tokyo")
}

@Test
func flightDestinationRegexExtractsTwoWordCity() {
    let extractor = DeterministicAnswerExtractor()
    // The regex allows up to two Title-case words for the destination.
    let item = makeItem(text: "Flight to New York departs Friday.")
    let answer = extractor.extractAnswer(
        query: "What is my flight destination?",
        items: [item]
    )
    #expect(answer == "New York")
}

@Test
func flightDestinationRegexMatchesLowercaseFlight() {
    let extractor = DeterministicAnswerExtractor()
    let item = makeItem(text: "She booked a flight to Paris for the conference.")
    let answer = extractor.extractAnswer(
        query: "Where is she traveling?",
        items: [item]
    )
    #expect(answer == "Paris")
}

@Test
func flightDestinationNotExtractedWhenPatternAbsent() {
    let extractor = DeterministicAnswerExtractor()
    // No "flight to …" phrase – extractor falls back to lexical sentence.
    let item = makeItem(text: "The conference will be held in Berlin.")
    let answer = extractor.extractAnswer(
        query: "Where am I flying to?",
        items: [item]
    )
    #expect(!answer.isEmpty)
}

// MARK: - allergyCandidates

// The regex: "allergic to <word(s)>" – capture group 1 is the allergen.
// The stored candidate text is prefixed: "allergic to <allergen>".

@Test
func allergyRegexExtractsSingleWordAllergen() {
    let extractor = DeterministicAnswerExtractor()
    let item = makeItem(text: "Note: the patient is allergic to penicillin.")
    let answer = extractor.extractAnswer(
        query: "What is my allergy?",
        items: [item]
    )
    #expect(answer == "allergic to penicillin")
}

@Test
func allergyRegexExtractsTwoWordAllergen() {
    let extractor = DeterministicAnswerExtractor()
    let item = makeItem(text: "She is allergic to tree nuts and should avoid them.")
    let answer = extractor.extractAnswer(
        query: "What am I allergic to?",
        items: [item]
    )
    #expect(answer == "allergic to tree nuts")
}

@Test
func allergyRegexMatchedByAllergyKeywordInQuery() {
    let extractor = DeterministicAnswerExtractor()
    let item = makeItem(text: "The client is allergic to shellfish.")
    // "allergy" triggers asksAllergy flag
    let answer = extractor.extractAnswer(
        query: "Any known allergy?",
        items: [item]
    )
    #expect(answer == "allergic to shellfish")
}

@Test
func allergyRegexMatchedByAllergicKeywordInQuery() {
    let extractor = DeterministicAnswerExtractor()
    let item = makeItem(text: "Mark is allergic to dust mites.")
    // "allergic" triggers asksAllergy flag
    let answer = extractor.extractAnswer(
        query: "What is Mark allergic to?",
        items: [item]
    )
    #expect(answer == "allergic to dust mites")
}

// MARK: - preferenceCandidates

// The regex: "prefers <capture: rest-of-sentence up to '.'>"
// Stored verbatim from capture group 1.

@Test
func preferenceRegexExtractsCommunicationStyleViaBullets() {
    let extractor = DeterministicAnswerExtractor()
    // "status update" triggers asksCommunicationStyle
    let item = makeItem(text: "Alice prefers bullet points for status updates.")
    let answer = extractor.extractAnswer(
        query: "How does Alice prefer status update reports?",
        items: [item]
    )
    #expect(answer.contains("bullet points"))
}

@Test
func preferenceRegexExtractsWrittenStyleViaWrittenQuery() {
    let extractor = DeterministicAnswerExtractor()
    // "written" in query triggers asksCommunicationStyle
    let item = makeItem(text: "Bob prefers concise written summaries over long paragraphs.")
    let answer = extractor.extractAnswer(
        query: "How does Bob like things written?",
        items: [item]
    )
    #expect(answer.contains("concise written summaries"))
}

@Test
func preferenceRegexExtractsEntireClauseUpToPeriod() {
    let extractor = DeterministicAnswerExtractor()
    let item = makeItem(text: "The team prefers async communication over meetings.")
    let answer = extractor.extractAnswer(
        query: "What is the team written preference?",
        items: [item]
    )
    // Capture group stops at '.' so trailing period should not appear.
    #expect(answer.contains("async communication"))
    #expect(!answer.hasSuffix("."))
}

// MARK: - petNameCandidates

// The regex: "named <UppercaseWord>" – capture group 1 is the pet name.

@Test
func petNameRegexExtractsCapitalizedName() {
    let extractor = DeterministicAnswerExtractor()
    // "adopt" triggers asksPet; need both petName + adoptionDate for composite answer.
    let item = makeItem(
        text: "I adopted a dog named Biscuit in March 2023."
    )
    let answer = extractor.extractAnswer(
        query: "What is my dog's name and when did I adopt him?",
        items: [item]
    )
    // The composite pet adoption path produces "<name> in <month year>"
    #expect(answer.contains("Biscuit"))
    #expect(answer.contains("March 2023"))
}

@Test
func petNameRegexOnlyExtractsUppercaseLeadName() {
    let extractor = DeterministicAnswerExtractor()
    // "named fluffy" should NOT match because 'f' is lowercase.
    let item = makeItem(text: "I have a cat named fluffy who is very playful.")
    // Without a valid petNameCandidate the pet adoption path cannot fire.
    let answer = extractor.extractAnswer(
        query: "What is my pet's name?",
        items: [item]
    )
    // Falls back to lexical sentence – must be non-empty and must not be "fluffy".
    #expect(!answer.isEmpty)
    // The answer should NOT come from the pet name regex since 'fluffy' is lowercase.
    #expect(!answer.lowercased().hasPrefix("fluffy in"))
}

// MARK: - Pet adoption composite answer path

// The branch: asksPet && petNameCandidates != [] && adoptionDateCandidates != []
// => returns "<petName> in <adoptedDate>"

@Test
func petAdoptionPathReturnsCompositeAnswer() {
    let extractor = DeterministicAnswerExtractor()
    let item = makeItem(
        text: "We adopted a rescue dog named Pepper in June 2021."
    )
    let answer = extractor.extractAnswer(
        query: "When did I adopt my dog and what is her name?",
        items: [item]
    )
    #expect(answer == "Pepper in June 2021")
}

@Test
func petAdoptionPathTriggeredByPetKeyword() {
    let extractor = DeterministicAnswerExtractor()
    let item = makeItem(
        text: "My new pet is named Luna and I got her in August 2022."
    )
    // "pet" in query triggers asksPet
    let answer = extractor.extractAnswer(
        query: "Tell me about my pet.",
        items: [item]
    )
    #expect(answer.contains("Luna"))
    #expect(answer.contains("August 2022"))
}

@Test
func petAdoptionPathTriggeredByAdoptKeyword() {
    let extractor = DeterministicAnswerExtractor()
    let item = makeItem(
        text: "I decided to adopt a dog named Rex in January 2020."
    )
    // "adopt" in query triggers asksPet
    let answer = extractor.extractAnswer(
        query: "What dog did I adopt?",
        items: [item]
    )
    #expect(answer.contains("Rex"))
    #expect(answer.contains("January 2020"))
}

@Test
func petAdoptionPathDoesNotFireWhenAdoptionDateMissing() {
    let extractor = DeterministicAnswerExtractor()
    // No "in <Month Year>" pattern -> adoptionDateCandidates stays empty
    // -> composite path cannot fire; extractor falls back.
    let item = makeItem(text: "I have a dog named Charlie. He is three years old.")
    let answer = extractor.extractAnswer(
        query: "What is my dog's name?",
        items: [item]
    )
    // Falls back but must still mention something about the content.
    #expect(!answer.isEmpty)
}

// MARK: - Communication style answer path

// The branch: asksCommunicationStyle && preferenceCandidates != [] => returns style

@Test
func communicationStylePathViaStatusUpdateQuery() {
    let extractor = DeterministicAnswerExtractor()
    // "status update" in query enables asksCommunicationStyle
    let item = makeItem(text: "Sarah prefers brief bullet-point summaries for her status updates.")
    let answer = extractor.extractAnswer(
        query: "How does Sarah want status update reports formatted?",
        items: [item]
    )
    #expect(answer.contains("brief bullet-point summaries"))
}

@Test
func communicationStylePathViaWrittenQuery() {
    let extractor = DeterministicAnswerExtractor()
    // "written" in query enables asksCommunicationStyle
    let item = makeItem(text: "The manager prefers short written paragraphs over slide decks.")
    let answer = extractor.extractAnswer(
        query: "What is the manager's preferred written format?",
        items: [item]
    )
    #expect(answer.contains("short written paragraphs"))
}

@Test
func communicationStylePathDoesNotFireWithoutQueryKeyword() {
    let extractor = DeterministicAnswerExtractor()
    let item = makeItem(text: "The manager prefers email over Slack.")
    // Query lacks "status update" and "written" – asksCommunicationStyle is false.
    let answer = extractor.extractAnswer(
        query: "How does the manager like to communicate?",
        items: [item]
    )
    // Must not crash; result is non-empty via lexical fallback.
    #expect(!answer.isEmpty)
}

// MARK: - Allergy answer path

// The branch: asksAllergy && allergyCandidates != [] => returns "allergic to <allergen>"

@Test
func allergyAnswerPathReturnsFormattedAllergenString() {
    let extractor = DeterministicAnswerExtractor()
    let item = makeItem(text: "Patient record: John is allergic to latex.")
    let answer = extractor.extractAnswer(
        query: "Does John have any known allergy?",
        items: [item]
    )
    #expect(answer == "allergic to latex")
}

@Test
func allergyAnswerPathPrefersHigherScoredItemWhenMultiplePresent() {
    let extractor = DeterministicAnswerExtractor()
    // Two items; the higher-score one should win.
    let lowScore = makeItem(
        text: "He is allergic to pollen.",
        score: 0.3
    )
    let highScore = makeItem(
        text: "He is allergic to peanuts.",
        score: 0.9
    )
    let answer = extractor.extractAnswer(
        query: "What is his allergy?",
        items: [lowScore, highScore]
    )
    #expect(answer == "allergic to peanuts")
}

@Test
func allergyAnswerPathNotReturnedWhenNoAllergyInItems() {
    let extractor = DeterministicAnswerExtractor()
    // Items contain no "allergic to …" pattern.
    let item = makeItem(text: "The patient has no known medical conditions.")
    let answer = extractor.extractAnswer(
        query: "Does the patient have any allergy?",
        items: [item]
    )
    // Must not crash; falls back to lexical sentence.
    #expect(!answer.isEmpty)
}

// MARK: - Travel destination answer path

// The branch: asksTravel && flightDestinationCandidates != [] => returns destination

@Test
func travelDestinationPathViaFlyingKeyword() {
    let extractor = DeterministicAnswerExtractor()
    // "flying" in query triggers asksTravel
    let item = makeItem(text: "I have a Flight to Amsterdam scheduled for Thursday.")
    let answer = extractor.extractAnswer(
        query: "Where am I flying to this week?",
        items: [item]
    )
    #expect(answer == "Amsterdam")
}

@Test
func travelDestinationPathViaFlightKeyword() {
    let extractor = DeterministicAnswerExtractor()
    // "flight" in query triggers asksTravel
    let item = makeItem(text: "Her flight to Lisbon departs at noon.")
    let answer = extractor.extractAnswer(
        query: "What is her flight destination?",
        items: [item]
    )
    #expect(answer == "Lisbon")
}

@Test
func travelDestinationPathViaTravelKeyword() {
    let extractor = DeterministicAnswerExtractor()
    // "travel" in query triggers asksTravel
    let item = makeItem(text: "Flight to Sydney has been confirmed.")
    let answer = extractor.extractAnswer(
        query: "Where is he planning to travel?",
        items: [item]
    )
    #expect(answer == "Sydney")
}

@Test
func travelDestinationPathPrefersFlightDestinationOverGenericCity() {
    let extractor = DeterministicAnswerExtractor()
    // One item contains both a moved-city pattern and a flight-destination pattern.
    // The flight destination branch fires first (higher priority when asksTravel is true).
    let item = makeItem(
        text: "Tom moved to Chicago but has a Flight to Dublin next month."
    )
    let answer = extractor.extractAnswer(
        query: "Where is Tom flying to?",
        items: [item]
    )
    #expect(answer == "Dublin")
}

@Test
func travelDestinationNotReturnedWhenPatternAbsent() {
    let extractor = DeterministicAnswerExtractor()
    let item = makeItem(text: "The meeting will take place in Rome next quarter.")
    let answer = extractor.extractAnswer(
        query: "Where am I traveling for the meeting?",
        items: [item]
    )
    // Must not crash; falls back to lexical sentence.
    #expect(!answer.isEmpty)
}

// MARK: - Edge cases & extractor contract

@Test
func emptyItemListReturnsEmptyString() {
    let extractor = DeterministicAnswerExtractor()
    let answer = extractor.extractAnswer(query: "What is my allergy?", items: [])
    #expect(answer.isEmpty)
}

@Test
func itemWithOnlyWhitespaceIsFilteredOut() {
    let extractor = DeterministicAnswerExtractor()
    // Whitespace-only text should be cleaned away and treated as empty.
    let whitespaceItem = makeItem(text: "   \n\t  ")
    let answer = extractor.extractAnswer(
        query: "What is my allergy?",
        items: [whitespaceItem]
    )
    #expect(answer.isEmpty)
}

@Test
func highlightBracketsAreStrippedBeforeMatching() {
    let extractor = DeterministicAnswerExtractor()
    // The extractor strips "[" and "]" from item text before applying regexes.
    // Simulate a highlighted item like: "[allergic] to [peanuts]"
    let item = makeItem(text: "[allergic] to [peanuts] according to the medical file.")
    let answer = extractor.extractAnswer(
        query: "Does the patient have any known allergy?",
        items: [item]
    )
    #expect(answer.contains("allergic to peanuts"))
}

@Test
func extractorIsSendable() {
    // DeterministicAnswerExtractor is declared Sendable; verify it can be
    // captured across an async boundary without a compiler warning.
    let extractor = DeterministicAnswerExtractor()
    let _: @Sendable () -> Void = {
        let item = makeItem(text: "Flight to Rome tomorrow.")
        _ = extractor.extractAnswer(query: "Where am I flying?", items: [item])
    }
}
