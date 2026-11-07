// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let waxIntegrationLinuxExcludes: [String]
#if os(Linux)
waxIntegrationLinuxExcludes = [
    "AccessStatsBootstrapBenchmarks.swift",
    "CoverageGapTests.swift",
    "BatchEmbeddingBenchmark.swift",
    "BertTokenizerReuseTests.swift",
    "BufferSerializationBenchmark.swift",
    "FoundationModelsToolAvailabilityTests.swift",
    "HandoffLookupBenchmarks.swift",
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
    "PayloadLivenessBenchmarks.swift",
    "PhotoRAGConstraintQueriesTests.swift",
    "PhotoRAGIngestDedupeTests.swift",
    "PhotoRAGOrchestratorTests.swift",
    "ProductionReadinessStabilityTests.swift",
    "RAGBenchmarkSupport.swift",
    "RAGBenchmarks.swift",
    "RAGBenchmarksMiniLM.swift",
    "RAGConfigClampingTests.swift",
    "RememberDedupBenchmarks.swift",
    "SessionRuntimeStatsBenchmarks.swift",
    "StructuredMemoryCRUDTests.swift",
    "StructuredMemorySchemaTests.swift",
    "SurrogateSourceBenchmarks.swift",
    "TextSearchEngineTests.swift",
    "UnifiedSearchTests.swift",
    "VersionRelationTests.swift",
    "BertTokenizerFastPathTests.swift",
    "HybridVectorEngineBenchmark.swift",
    "VectorSearchEngineTests.swift",
    "VideoRAGDeleteVectorDurabilityTests.swift",
    "VideoRAGFileIngestIntegrationTests.swift",
    "VideoRAGRecallOnlyTests.swift",
    "VideoRAGSegmentationMathTests.swift",
    "VideoRAGTestSupport.swift",
    "TokenizerBenchmark.swift",
]
#else
waxIntegrationLinuxExcludes = []
#endif

let waxRepoPackageDependencies: [Package.Dependency]
let waxRepoTargets: [Target]
#if os(macOS)
waxRepoPackageDependencies = [
    // rensbreur/SwiftTUI has no tagged releases; pin the exact revision for reproducible
    // builds instead of tracking the moving `main` branch. (WaxRepo TUI only.)
    .package(url: "https://github.com/rensbreur/SwiftTUI.git", revision: "537133031bc2b2731048d00748c69700e1b48185"),
    .package(url: "https://github.com/tuist/Noora.git", .upToNextMinor(from: "0.57.0")),
]
waxRepoTargets = [
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
]
#else
waxRepoPackageDependencies = []
waxRepoTargets = []
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
        .library(name: "WaxVectorSearch", targets: ["WaxVectorSearch"]),
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
        .package(url: "https://github.com/christopherkarani/MetalANNS.git", exact: "0.4.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", .upToNextMinor(from: "0.12.1")),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.7.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.3"),
    ] + waxRepoPackageDependencies,
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
            ]
        ),
        .target(
            name: "WaxBertTokenizer",
            dependencies: [],
            resources: [.process("Resources/bert_tokenizer_vocab.txt")]
        ),
        .target(
            name: "WaxTextSearch",
            dependencies: [
                "WaxCore",
                .product(name: "GRDB", package: "GRDB.swift"),
                // Linux has no Darwin SQLite3 overlay. GRDB's system library
                // exposes sqlite3_serialize so FTS5 can persist into the .wax file.
                .product(name: "GRDBSQLite", package: "GRDB.swift"),
            ]
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
            resources: [.process("Shaders")]
        ),
        .target(
            name: "WaxVectorSearchMiniLM",
            dependencies: [
                "WaxVectorSearch",
                "WaxBertTokenizer",
            ],
            resources: [
                .copy("Resources/all-MiniLM-L6-v2.mlmodelc"),
            ]
        ),
        .target(
            name: "WaxVectorSearchArctic",
            dependencies: [
                "WaxVectorSearch",
                "WaxBertTokenizer",
            ],
            resources: [
                .copy("Resources/snowflake-arctic-embed-s.mlmodelc"),
            ]
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
                .define("MiniLMEmbeddings", .when(traits: ["MiniLMEmbeddings"])),
                .define("ArcticEmbeddings", .when(traits: ["ArcticEmbeddings"])),
            ]
        ),
        .executableTarget(
            name: "wax-mcp",
            dependencies: [
                "Wax",
                "WaxCore",
                "WaxVectorSearch",
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
                .define("MiniLMEmbeddings", .when(traits: ["MiniLMEmbeddings"])),
                .define("ArcticEmbeddings", .when(traits: ["ArcticEmbeddings"])),
            ]
        ),
        .executableTarget(
            name: "WaxCrashHarness",
            dependencies: [
                "Wax",
            ],
            path: "Sources/WaxCrashHarness"
        ),
    ] + waxRepoTargets + [
        // Deterministic stub embedders shared by the test targets below. Not a product.
        .target(
            name: "WaxTestSupport",
            dependencies: [
                "Wax",
            ],
            path: "Tests/WaxTestSupport"
        ),
        .testTarget(
            name: "WaxCoreTests",
            dependencies: [
                "WaxCore",
            ],
            resources: [.process("Fixtures")]
        ),
        .testTarget(
            name: "WaxIntegrationTests",
            dependencies: [
                "Wax",
                "WaxTestSupport",
                "WaxVectorSearchMiniLM",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Logging", package: "swift-log"),
            ],
            exclude: waxIntegrationLinuxExcludes,
            resources: [.process("Fixtures")],
            swiftSettings: [
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
            ],
            path: "Tests/WaxArcticTests"
        ),
        .testTarget(
            name: "wax-mcpTests",
            dependencies: [
                "Wax",
                "WaxTestSupport",
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
                .product(
                    name: "NIOPosix",
                    package: "swift-nio",
                    condition: .when(traits: ["MCPServer"])
                ),
            ],
            path: "Tests/WaxMCPServerTests",
            resources: [.copy("Fixtures")],
            swiftSettings: [
                .define("MCPServer", .when(traits: ["MCPServer"])),
            ]
        ),
        .testTarget(
            name: "waxTests",
            dependencies: [
                "Wax",
                "WaxTestSupport",
            ],
            path: "Tests/WaxTests",
            swiftSettings: [
                .define("WaxRepo", .when(traits: ["WaxRepo"])),
            ]
        ),
        .testTarget(
            name: "WaxCLITests",
            dependencies: [
                "Wax",
                "WaxCore",
                "wax-cli",
            ],
            path: "Tests/WaxCLITests",
            resources: [.copy("Fixtures")],
            swiftSettings: [
                .define("MCPServer", .when(traits: ["MCPServer"])),
            ]
        ),
    ]
)
