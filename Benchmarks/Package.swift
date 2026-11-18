// swift-tools-version: 6.1
// Benchmark runner for Wax. Kept out of the main package so `swift test` there never pulls it.
import PackageDescription

let package = Package(
    name: "WaxBenchmarks",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "..", traits: ["MiniLMEmbeddings", "ArcticEmbeddings", "E5Embeddings", "MiniLMReranker"]),
    ],
    targets: [
        .executableTarget(
            name: "wax-bench",
            dependencies: [.product(name: "Wax", package: "Wax")],
            path: "Sources/WaxBench"
        ),
    ]
)
