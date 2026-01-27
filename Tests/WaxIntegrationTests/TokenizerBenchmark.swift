#if canImport(WaxVectorSearchMiniLM)
import Foundation
import XCTest
import WaxVectorSearchMiniLM
@testable import Wax

final class TokenizerBenchmark: XCTestCase {
    
    private var isEnabled: Bool {
        ProcessInfo.processInfo.environment["WAX_BENCHMARK_MINILM"] == "1"
    }
    
    func testTokenizerThroughput() {
        guard isEnabled else { return }
        
        let tokenizer = BertTokenizer()
        let text = "Swift concurrency vector search performance optimization is critical for on-device RAG systems."
        let iterations = 1_000
        
        print("\n🧪 Tokenizer Benchmark")
        print("   Iterations: \(iterations)")
        print("   Text length: \(text.count)")
        
        measure {
            for _ in 0..<iterations {
                _ = tokenizer.buildModelTokens(sentence: text)
            }
        }
    }
}
#endif
