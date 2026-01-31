#if canImport(WaxVectorSearchMiniLM)
import Foundation
import XCTest
import WaxVectorSearchMiniLM
@testable import Wax

final class TokenizerBenchmark: XCTestCase {
    
    private var isEnabled: Bool {
        ProcessInfo.processInfo.environment["WAX_BENCHMARK_MINILM"] == "1"
    }
    
    func testTokenizerThroughput() throws {
        guard isEnabled else { return }
        
        let tokenizer = try BertTokenizer()
        let text = "Swift concurrency vector search performance optimization is critical for on-device RAG systems."
        let iterations = 1_000
        
        print("\n🧪 Tokenizer Benchmark")
        print("   Iterations: \(iterations)")
        print("   Text length: \(text.count)")
        
        measure {
            for _ in 0..<iterations {
                do {
                    _ = try tokenizer.buildModelTokens(sentence: text)
                } catch {
                    XCTFail("Tokenizer failed to build tokens: \(error)")
                    break
                }
            }
        }
    }
}
#endif
