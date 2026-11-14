import Foundation
import Testing
import WaxMILRuntime

/// The four Core ML programs bundled in the Sources tree, located from this file so the tests
/// need no resource bundling.
enum BundledModel: String, CaseIterable, CustomStringConvertible, Sendable {
    case miniLM = "Sources/WaxVectorSearchMiniLM/Resources/all-MiniLM-L6-v2.mlmodelc"
    case e5 = "Sources/WaxVectorSearchE5/Resources/e5-small-v2.mlmodelc"
    case arctic = "Sources/WaxVectorSearchArctic/Resources/snowflake-arctic-embed-s.mlmodelc"
    case reranker = "Sources/WaxRerankerMiniLM/Resources/ms-marco-MiniLM-L-6-v2.mlmodelc"

    var description: String {
        switch self {
        case .miniLM: "MiniLM"
        case .e5: "e5"
        case .arctic: "Arctic"
        case .reranker: "reranker"
        }
    }

    var url: URL { packageRoot().appendingPathComponent(rawValue, isDirectory: true) }

    var programURL: URL { url.appendingPathComponent("model.mil") }

    var outputName: String { self == .reranker ? "scores" : "embeddings" }

    /// Whether the graph itself L2-normalises its output.
    var normalisesOutput: Bool { self == .e5 || self == .arctic }

    /// Loads once per process; `static let` initialisation is thread-safe.
    var model: MILModel {
        get throws {
            switch self {
            case .miniLM: try BundledModelCache.miniLM.get()
            case .e5: try BundledModelCache.e5.get()
            case .arctic: try BundledModelCache.arctic.get()
            case .reranker: try BundledModelCache.reranker.get()
            }
        }
    }
}

private enum BundledModelCache {
    static let miniLM = Result { try MILModel(contentsOf: BundledModel.miniLM.url) }
    static let e5 = Result { try MILModel(contentsOf: BundledModel.e5.url) }
    static let arctic = Result { try MILModel(contentsOf: BundledModel.arctic.url) }
    static let reranker = Result { try MILModel(contentsOf: BundledModel.reranker.url) }
}

func packageRoot(filePath: String = #filePath) -> URL {
    URL(fileURLWithPath: filePath)
        .deletingLastPathComponent() // WaxMILRuntimeTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent()
}

func cosine(_ a: [Float], _ b: [Float]) -> Double {
    precondition(a.count == b.count)
    var dot = 0.0
    var na = 0.0
    var nb = 0.0
    for i in 0..<a.count {
        dot += Double(a[i]) * Double(b[i])
        na += Double(a[i]) * Double(a[i])
        nb += Double(b[i]) * Double(b[i])
    }
    return dot / (na.squareRoot() * nb.squareRoot())
}

func l2Norm(_ values: ArraySlice<Float>) -> Double {
    values.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot()
}

func maxAbsDifference(_ a: [Float], _ b: [Float]) -> Float {
    precondition(a.count == b.count)
    return zip(a, b).reduce(Float(0)) { max($0, abs($1.0 - $1.1)) }
}

/// Runs a small hand-written MIL program and returns its single named output.
func runProgram(
    _ text: String,
    inputs: [String: MILTensor] = [:],
    output: String = "y"
) throws -> MILTensor {
    let model = try MILModel(programText: text)
    let outputs = try model.predict(inputs)
    return try #require(outputs[output])
}

/// Wraps statements in a `main` function with the given parameter list and output.
func program(params: String = "", outputs: String = "y", _ body: String) -> String {
    """
    program(1.3)
    {
        func main<ios18>(\(params)) {
    \(body)
        } -> (\(outputs));
    }
    """
}

/// A deterministic pseudo-random generator so tests are reproducible.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func floats(_ count: Int) -> [Float] {
        (0..<count).map { _ in Float.random(in: -1...1, using: &self) }
    }
}
