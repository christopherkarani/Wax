import Testing
import Wax

@Test func factualQueryClassification() {
    #expect(RuleBasedQueryClassifier.classify("What is the user's email address?") == .factual)
}

@Test func semanticQueryClassification() {
    #expect(RuleBasedQueryClassifier.classify("How does authentication relate to user privacy?") == .semantic)
}

@Test func temporalQueryClassification() {
    #expect(RuleBasedQueryClassifier.classify("What was discussed in yesterday's meeting?") == .temporal)
}

@Test func exploratoryQueryClassification() {
    #expect(RuleBasedQueryClassifier.classify("Tell me about the project") == .exploratory)
}

@Test func hexCanaryQueryClassifiesAsFactual() {
    #expect(RuleBasedQueryClassifier.classify("7f3a91") == .factual)
    #expect(RuleBasedQueryClassifier.classify("DEADBEEF") == .factual)
}

@Test func singleTokenIdentifierQueryClassifiesAsFactual() {
    #expect(RuleBasedQueryClassifier.classify("canary-token") == .factual)
    #expect(RuleBasedQueryClassifier.classify("user_id") == .factual)
}

@Test func ordinarySingleWordStaysExploratory() {
    #expect(RuleBasedQueryClassifier.classify("Swift") == .exploratory)
}

@Test func letterOnlyHexWordsStayExploratory() {
    #expect(RuleBasedQueryClassifier.classify("facade") == .exploratory)
    #expect(RuleBasedQueryClassifier.classify("decade") == .exploratory)
}

@Test func operatorORFallbackQueryClassifiesAsExploratory() {
    #expect(RuleBasedQueryClassifier.classify("adversarial-fp.md stash-drop deny") == .exploratory)
}

