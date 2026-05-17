// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let waxIntegrationLinuxExcludes: [String]
#if os(Linux)
waxIntegrationLinuxExcludes = [
    "CoverageGapTests.swift",
    "BatchEmbeddingBenchmark.swift",
    "BertTokenizerReuseTests.swift",
    "BufferSerializationBenchmark.swift",
    "FoundationModelsToolAvailabilityTests.swift",
    "LongMemoryBenchmarkHarness.swift",
    "MLMultiArrayBatchBuilderTests.swift",
    "MemoryOrchestratorTests.swift",
    "MetalVectorEngineBenchmark.swift",
    "MetalVectorEnginePoolTests.swift",
    "MiniLMBatchBuilderTests.swift",
    "MiniLMEmbedderBatchPlanningTests.swift",
    "MiniLMEmbedderTests.swift",
    "MiniLMEmbeddingQualityTests.swift",
    "MiniLMFloat16DecodingTests.swift",
    "MiniLMResourceFailureTests.swift",
    "Mocks/MockProviders.swift",
    "OptimizationComparisonBenchmark.swift",
    "PDFIngestTests.swift",
    "PhotoRAGConstraintQueriesTests.swift",
    "PhotoRAGIngestDedupeTests.swift",
    "PhotoRAGOrchestratorTests.swift",
    "ProductionReadinessStabilityTests.swift",
    "RAGBenchmarkSupport.swift",
    "RAGBenchmarks.swift",
    "RAGBenchmarksMiniLM.swift",
    "RAGConfigClampingTests.swift",
    "UnifiedSearchTests.swift",
    "VectorSearchEngineTests.swift",
    "VideoRAGFileIngestIntegrationTests.swift",
    "VideoRAGRecallOnlyTests.swift",
    "VideoRAGSegmentationMathTests.swift",
    "VideoRAGTestSupport.swift",
    "TokenizerBenchmark.swift",
]
#else
waxIntegrationLinuxExcludes = []
#endif

let package = Package(
    name: "Wax",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "Wax",
            targets: ["Wax"]
        ),
        .library(name: "WaxCore", targets: ["WaxCore"]),
        .library(name: "WaxBertTokenizer", targets: ["WaxBertTokenizer"]),
        .library(name: "WaxTextSearch", targets: ["WaxTextSearch"]),
        .library(name: "WaxVectorSearch", targets: ["WaxVectorSearch"]),
        .library(name: "WaxVectorSearchMiniLM", targets: ["WaxVectorSearchMiniLM"]),
        .library(name: "WaxVectorSearchArctic", targets: ["WaxVectorSearchArctic"]),
    ],
    traits: [
        .default(enabledTraits: ["MiniLMEmbeddings"]),
        .init(
            name: "MiniLMEmbeddings",
            description: "Includes the built-in MiniLM embedding provider",
            enabledTraits: []
        ),
        .init(
            name: "ArcticEmbeddings",
            description: "Includes the Snowflake Arctic Embed Small provider",
            enabledTraits: []
        ),
        .init(
            name: "MCPServer",
            description: "Builds the WaxMCPServer executable with stdio and HTTP transports",
            enabledTraits: ["MiniLMEmbeddings"]
        ),
        .init(
            name: "WaxRepo",
            description: "Builds the wax-repo semantic git search TUI (macOS only)",
            enabledTraits: ["MiniLMEmbeddings"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/christopherkarani/MetalANNS.git", exact: "0.1.3"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/swiftlang/swift-testing", exact: "0.12.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.10.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.7.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.3"),
        .package(url: "https://github.com/rensbreur/SwiftTUI.git", branch: "main"),
        .package(url: "https://github.com/tuist/Noora.git", from: "0.54.0"),
    ],
    targets: [
        .target(
            name: "WaxCoreCompressionC",
            dependencies: [],
            path: "Sources/WaxCoreCompressionC",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedLibrary("lz4", .when(platforms: [.linux])),
                .linkedLibrary("z", .when(platforms: [.linux])),
            ]
        ),
        .target(
            name: "WaxCore",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
                .target(
                    name: "WaxCoreCompressionC",
                    condition: .when(platforms: [.linux])
                ),
            ],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .target(
            name: "WaxBertTokenizer",
            dependencies: [],
            resources: [.process("Resources/bert_tokenizer_vocab.txt")],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .target(
            name: "WaxTextSearch",
            dependencies: [
                "WaxCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .target(
            name: "WaxVectorSearch",
            dependencies: [
                "WaxCore",
                .product(
                    name: "MetalANNS",
                    package: "MetalANNS",
                    condition: .when(platforms: [.macOS, .iOS])
                ),
            ],
            resources: [.process("Shaders")],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .target(
            name: "WaxVectorSearchMiniLM",
            dependencies: [
                "WaxVectorSearch",
                "WaxBertTokenizer",
            ],
            resources: [
                .copy("Resources/all-MiniLM-L6-v2.mlmodelc"),
            ],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .target(
            name: "WaxVectorSearchArctic",
            dependencies: [
                "WaxVectorSearch",
                "WaxBertTokenizer",
            ],
            resources: [
                .copy("Resources/snowflake-arctic-embed-s.mlmodelc"),
            ],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .target(
            name: "Wax",
            dependencies: [
                "WaxCore",
                "WaxTextSearch",
                "WaxVectorSearch",
                .target(
                    name: "WaxVectorSearchMiniLM",
                    condition: .when(traits: ["MiniLMEmbeddings"])
                ),
                .target(
                    name: "WaxVectorSearchArctic",
                    condition: .when(traits: ["ArcticEmbeddings"])
                ),
            ],
            resources: [.process("RAG/Resources")],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .define("MiniLMEmbeddings", .when(traits: ["MiniLMEmbeddings"])),
                .define("ArcticEmbeddings", .when(traits: ["ArcticEmbeddings"])),
            ]
        ),
        .executableTarget(
            name: "wax-mcp",
            dependencies: [
                "Wax",
                "WaxCore",
                .product(
                    name: "MCP",
                    package: "swift-sdk",
                    condition: .when(traits: ["MCPServer"])
                ),
                .product(
                    name: "ArgumentParser",
                    package: "swift-argument-parser",
                    condition: .when(traits: ["MCPServer"])
                ),
                .product(
                    name: "NIOCore",
                    package: "swift-nio",
                    condition: .when(traits: ["MCPServer"])
                ),
                .product(
                    name: "NIOPosix",
                    package: "swift-nio",
                    condition: .when(traits: ["MCPServer"])
                ),
                .product(
                    name: "NIOHTTP1",
                    package: "swift-nio",
                    condition: .when(traits: ["MCPServer"])
                ),
                .target(
                    name: "WaxVectorSearchMiniLM",
                    condition: .when(traits: ["MiniLMEmbeddings"])
                ),
                .target(
                    name: "WaxVectorSearchArctic",
                    condition: .when(traits: ["ArcticEmbeddings"])
                ),
            ],
            path: "Sources/WaxMCPServer",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .define("MCPServer", .when(traits: ["MCPServer"])),
                .define("MiniLMEmbeddings", .when(traits: ["MiniLMEmbeddings"])),
                .define("ArcticEmbeddings", .when(traits: ["ArcticEmbeddings"])),
            ]
        ),
        .executableTarget(
            name: "wax-cli",
            dependencies: [
                "Wax",
                "WaxCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .target(name: "WaxVectorSearchMiniLM",
                        condition: .when(traits: ["MiniLMEmbeddings"])),
                .target(name: "WaxVectorSearchArctic",
                        condition: .when(traits: ["ArcticEmbeddings"])),
            ],
            path: "Sources/WaxCLI",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .define("MiniLMEmbeddings", .when(traits: ["MiniLMEmbeddings"])),
                .define("ArcticEmbeddings", .when(traits: ["ArcticEmbeddings"])),
            ]
        ),
        .executableTarget(
            name: "WaxCrashHarness",
            dependencies: [
                "Wax",
            ],
            path: "Sources/WaxCrashHarness",
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .executableTarget(
            name: "WaxRepo",
            dependencies: [
                "Wax",
                .product(name: "SwiftTUI", package: "SwiftTUI"),
                .product(name: "Noora", package: "Noora"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .target(name: "WaxVectorSearchMiniLM",
                        condition: .when(traits: ["MiniLMEmbeddings"])),
                .target(name: "WaxVectorSearchArctic",
                        condition: .when(traits: ["ArcticEmbeddings"])),
            ],
            path: "Sources/WaxRepo",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .define("WaxRepo", .when(traits: ["WaxRepo"])),
                .define("MiniLMEmbeddings", .when(traits: ["MiniLMEmbeddings"])),
                .define("ArcticEmbeddings", .when(traits: ["ArcticEmbeddings"])),
            ]
        ),
        .testTarget(
            name: "WaxCoreTests",
            dependencies: [
                "WaxCore",
                .product(name: "Testing", package: "swift-testing"),
            ],
            resources: [.process("Fixtures")],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "WaxIntegrationTests",
            dependencies: [
                "Wax",
                "WaxVectorSearchMiniLM",
                .product(name: "Testing", package: "swift-testing"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Logging", package: "swift-log"),
            ],
            exclude: waxIntegrationLinuxExcludes,
            resources: [.process("Fixtures")],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .define("MiniLMEmbeddings", .when(traits: ["MiniLMEmbeddings"])),
            ]
        ),
        .testTarget(
            name: "WaxArcticTests",
            dependencies: [
                "Wax",
                "WaxVectorSearchArctic",
                "WaxVectorSearchMiniLM",
                "WaxBertTokenizer",
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "Tests/WaxArcticTests",
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "wax-mcpTests",
            dependencies: [
                "Wax",
                .product(name: "Testing", package: "swift-testing"),
                .target(
                    name: "wax-mcp",
                    condition: .when(traits: ["MCPServer"])
                ),
                .product(
                    name: "MCP",
                    package: "swift-sdk",
                    condition: .when(traits: ["MCPServer"])
                ),
                .product(
                    name: "NIOEmbedded",
                    package: "swift-nio",
                    condition: .when(traits: ["MCPServer"])
                ),
                .product(
                    name: "NIOHTTP1",
                    package: "swift-nio",
                    condition: .when(traits: ["MCPServer"])
                ),
            ],
            path: "Tests/WaxMCPServerTests",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
                .define("MCPServer", .when(traits: ["MCPServer"])),
            ]
        ),
        .testTarget(
            name: "waxTests",
            dependencies: [
                "Wax",
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "Tests/WaxTests",
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "WaxCLITests",
            dependencies: [
                "Wax",
                "wax-cli",
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "Tests/WaxCLITests",
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
    ]
)
