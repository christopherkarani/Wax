import Foundation
import Testing
@testable import Wax
import WaxCore

/// Operator case: multi-token text query whose AND pass misses, then OR-fallback
/// matches a common token like "drop" and used to publish a perfect 1.0 score.
@Test func textSearchMultiTokenORFallbackDoesNotScoreUnrelatedDropHitAsPerfect() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()

        // Fillers keep "drop" rare so FTS BM25 IDF is nonzero. A one-doc index
        // makes every term corpus-wide and collapses the published score to 0.
        for index in 0..<16 {
            let filler = "unrelated widget corpus filler \(index) about release notes"
            let frameId = try await wax.put(Data(filler.utf8))
            try await text.index(frameId: frameId, text: filler)
        }

        let dropOnly = try await wax.put(Data("please drop unused temporary files".utf8))
        try await text.index(frameId: dropOnly, text: "please drop unused temporary files")
        try await text.commit()

        let response = try await wax.search(
            SearchRequest(
                query: "adversarial-fp.md stash-drop deny",
                mode: .textOnly,
                topK: 10
            )
        )

        let dropHit = try #require(response.results.first { $0.frameId == dropOnly })
        // Saturated BM25 publishes Float(1) as ~0.99999994. A 1-of-N overlap
        // must not look like a perfect hit.
        #expect(dropHit.score < 0.9)

        try await wax.close()
    }
}

@Test func textSearchANDMatchRanksAboveORFallbackOnlyDropHit() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()

        for index in 0..<16 {
            let filler = "unrelated widget corpus filler \(index) about release notes"
            let frameId = try await wax.put(Data(filler.utf8))
            try await text.index(frameId: frameId, text: filler)
        }

        let andMatchText = "policy for adversarial-fp.md stash-drop deny on redteam fixtures"
        let andMatch = try await wax.put(Data(andMatchText.utf8))
        try await text.index(frameId: andMatch, text: andMatchText)

        let dropOnly = try await wax.put(Data("please drop unused temporary files".utf8))
        try await text.index(frameId: dropOnly, text: "please drop unused temporary files")
        try await text.commit()

        let response = try await wax.search(
            SearchRequest(
                query: "adversarial-fp.md stash-drop deny",
                mode: .textOnly,
                topK: 10
            )
        )

        let andHit = try #require(response.results.first { $0.frameId == andMatch })
        #expect(response.results.first?.frameId == andMatch)
        if let dropHit = response.results.first(where: { $0.frameId == dropOnly }) {
            #expect(andHit.score > dropHit.score)
            #expect(dropHit.score < 0.9)
        }

        try await wax.close()
    }
}
