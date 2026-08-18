import Foundation
import Testing
import Wax
@testable import WaxHNDemo

@Suite("Photo evidence prompt")
struct PhotoEvidencePromptTests {
    @Test("Builds <photo_evidence> from each item’s assetID and summaryText")
    func buildsExactPrompt() {
        let items = [
            PhotoRAGItem(
                assetID: "A1",
                score: 1,
                evidence: [.text(snippet: "must-not-appear")],
                summaryText: "OCR: WAX-99"
            ),
            PhotoRAGItem(
                assetID: "B2",
                score: 0.5,
                evidence: [.vector],
                summaryText: "Caption: mug"
            ),
        ]

        let prompt = PhotoEvidencePrompt.make(query: "what serial?", items: items)
        #expect(prompt == """
        Answer using only this on-device photo evidence. If the evidence does not contain the answer, say you cannot find it.

        <photo_evidence>
        [A1]
        OCR: WAX-99

        [B2]
        Caption: mug
        </photo_evidence>

        Question: what serial?
        """)
        #expect(!prompt.contains("must-not-appear"))
    }
}

@Suite("Foundation Models session config")
struct FoundationModelsDemoSupportTests {
    @Test("Demo session is prompt-augmentation, no memory tools, persistence none")
    func sessionConfiguration() {
        let configuration = FoundationModelsDemoSupport.sessionConfiguration
        #expect(configuration.persistencePolicy == .none)
        #expect(configuration.contextStrategy == .promptAugmentation)
        #expect(configuration.includeMemoryTools == false)
        #expect(configuration.persistencePolicy.shouldPersistUser == false)
        #expect(configuration.persistencePolicy.shouldPersistAssistant == false)
    }

    #if canImport(FoundationModels)
    @Test("Published status uses the exact unavailable reason")
    func publishedUnavailableReason() {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { return }
        #expect(
            FoundationModelsStatus.publishedString(.unavailable(reason: "appleIntelligenceNotEnabled"))
                == "appleIntelligenceNotEnabled"
        )
        #expect(FoundationModelsStatus.publishedString(.available) == "available")
    }
    #endif
}
