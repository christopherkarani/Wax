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
