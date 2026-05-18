#if canImport(WaxVectorSearchMiniLM)
import Testing
@testable import Wax
@testable import WaxVectorSearchMiniLM

@available(macOS 15.0, iOS 18.0, *)
@Test
func openMiniLMThrowsWhenModelMissing() async throws {
    await TempFiles.withTempFile { url in
        do {
            _ = try await MemoryOrchestrator.openMiniLM(
                at: url,
                config: .default,
                overrides: .missingModel
            )
            Issue.record("Expected missing model resource error")
        } catch {
            expectMiniLMInitError(error, matches: .missingModelResource)
        }
    }
}

@available(macOS 15.0, iOS 18.0, *)
@Test
func openMiniLMThrowsWhenTokenizerMissing() async throws {
    await TempFiles.withTempFile { url in
        do {
            _ = try await MemoryOrchestrator.openMiniLM(
                at: url,
                config: .default,
                overrides: .missingTokenizer
            )
            Issue.record("Expected tokenizer load error")
        } catch {
            expectMiniLMInitError(error, matches: .tokenizerLoadFailed("override requested failure"))
        }
    }
}

@available(macOS 15.0, iOS 18.0, *)
private func expectMiniLMInitError(
    _ error: any Error,
    matches expected: MiniLMEmbeddings.InitError
) {
    guard let actual = error as? MiniLMEmbeddings.InitError else {
        Issue.record("Expected MiniLMEmbeddings.InitError, got \(error)")
        return
    }

    switch (actual, expected) {
    case (.missingModelResource, .missingModelResource):
        break
    case (.modelLoadFailed(let actualMessage), .modelLoadFailed(let expectedMessage)):
        #expect(actualMessage == expectedMessage)
    case (.tokenizerLoadFailed(let actualMessage), .tokenizerLoadFailed(let expectedMessage)):
        #expect(actualMessage == expectedMessage)
    default:
        Issue.record("Expected \(expected), got \(actual)")
    }
}

#endif
