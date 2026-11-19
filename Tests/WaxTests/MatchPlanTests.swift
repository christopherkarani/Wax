import Testing
@testable import Wax

@Test
func matchPlanANDQuotesNormalizedTokens() {
    let plan = MatchPlan.plan(query: "Swift actors")
    #expect(plan?.primaryMatch == "\"swift\" \"actors\"")
    #expect(plan?.fallbackMatch == "\"swift\" OR \"actors\"")
    #expect(plan?.tokenCount == 2)
}

@Test
func matchPlanSingleTokenHasNoORFallback() {
    let plan = MatchPlan.plan(query: "Swift")
    #expect(plan?.primaryMatch == "\"swift\"")
    #expect(plan?.fallbackMatch == nil)
    #expect(plan?.tokenCount == 1)
}

@Test
func matchPlanStopwordsAndOperatorsAloneAreEmpty() {
    #expect(MatchPlan.plan(query: "what is the date") == nil)
    #expect(MatchPlan.plan(query: "AND OR NOT NEAR") == nil)
    #expect(MatchPlan.plan(query: "   ") == nil)
}

@Test
func matchPlanKeepsHyphenatedIdentifierAsToken() {
    let tokens = MatchPlan.tokens(from: "qx7m-ishi-qa")
    #expect(tokens.contains("qx7m-ishi-qa"))
    #expect(tokens.contains("ishi"))
    let plan = MatchPlan.plan(query: "qx7m-ishi-qa")
    #expect(plan?.primaryMatch.contains("qx7m-ishi-qa") == true)
    #expect(plan?.fallbackMatch?.contains(" OR ") == true)
}

@Test
func matchPlanKeepsHyphenatedQuotedPhraseTogether() {
    let plan = MatchPlan.plan(query: #"What is "foo-bar"?"#)
    #expect(plan?.primaryMatch.contains(#""foo-bar""#) == true)
    #expect(plan?.primaryMatch.contains(#""foo-bar foo bar""#) == false)
    #expect(MatchPlan.normalizedQuotedPhrases(from: #""foo-bar""#) == ["foo-bar"])
}

@Test
func matchPlanTreatsFTSPunctuationAsLiteralTokens() {
    let plan = MatchPlan.plan(query: #"task:(F076) NEAR(unclosed "quote""#)
    let primary = plan?.primaryMatch ?? ""
    #expect(primary.contains("\"task\""))
    #expect(primary.contains("\"f076\""))
    #expect(primary.contains("\"unclosed\""))
    #expect(primary.contains("\"quote\""))
    #expect(primary.contains("NEAR") == false)
}

@Test
func matchPlanTreatsControlCharactersAsSeparators() throws {
    for query in ["abc\u{0}def", "\"abc\u{0}def\"", "abc\u{7}def\u{1B}"] {
        let plan = try #require(MatchPlan.plan(query: query))
        let expressions: [String] = [plan.primaryMatch] + (plan.fallbackMatch.map { [$0] } ?? [])
        for expression in expressions {
            #expect(!expression.unicodeScalars.contains { $0.properties.generalCategory == .control })
        }
        #expect(plan.primaryMatch.contains("\"abc\""))
        #expect(plan.primaryMatch.contains("\"def\""))
    }
    #expect(MatchPlan.plan(query: "\u{0}") == nil)
}
