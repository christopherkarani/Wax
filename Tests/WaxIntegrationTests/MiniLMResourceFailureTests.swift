#if canImport(WaxVectorSearchMiniLM)
import Testing
@testable import Wax
@testable import WaxVectorSearchMiniLM

@available(macOS 15.0, iOS 18.0, *)
@Test
func openMiniLMThrowsWhenModelMissing() async throws {
    try await TempFiles.withTempFile { url in
        do {
            _ = try await MemoryOrchestrator.openMiniLM(
                at: url,
                config: .default,
                overrides: .missingModel
            )
            #expect(Bool(false))
        } catch {
            #expect(Bool(true))
        }
    }
}

@available(macOS 15.0, iOS 18.0, *)
@Test
func openMiniLMThrowsWhenTokenizerMissing() async throws {
    try await TempFiles.withTempFile { url in
        do {
            _ = try await MemoryOrchestrator.openMiniLM(
                at: url,
                config: .default,
                overrides: .missingTokenizer
            )
            #expect(Bool(false))
        } catch {
            #expect(Bool(true))
        }
    }
}
#endif
