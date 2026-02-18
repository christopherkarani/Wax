// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Wax",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
    ],
    products: [
        .library(
            name: "Wax",
            targets: ["Wax"]
        ),
        .library(name: "WaxCore", targets: ["WaxCore"]),
        .library(name: "WaxTextSearch", targets: ["WaxTextSearch"]),
        .library(name: "WaxVectorSearch", targets: ["WaxVectorSearch"]),
        .library(name: "WaxVectorSearchMiniLM", targets: ["WaxVectorSearchMiniLM"]),
    ],
    traits: [
        .default(enabledTraits: ["MiniLMEmbeddings"]),
        .init(
            name: "MiniLMEmbeddings",
            description: "Includes the built-in MiniLM embedding provider",
            enabledTraits: []
        ),
        .init(
            name: "MCPServer",
            description: "Builds the WaxMCPServer stdio MCP server executable (macOS only)",
            enabledTraits: ["MiniLMEmbeddings"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/unum-cloud/USearch.git", from: "2.23.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.24.0"),
        .package(url: "https://github.com/DePasqualeOrg/swift-tiktoken.git", from: "0.0.1"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.10.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "WaxCore",
            dependencies: [],
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
                .product(name: "USearch", package: "USearch"),
            ],
            resources: [.process("Shaders")],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .target(
            name: "WaxVectorSearchMiniLM",
            dependencies: [
                "WaxVectorSearch",
            ],
            resources: [
                .copy("Resources/all-MiniLM-L6-v2.mlmodelc"),
                .process("Resources/bert_tokenizer_vocab.txt"),
            ],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .target(
            name: "Wax",
            dependencies: [
                "WaxCore",
                "WaxTextSearch",
                "WaxVectorSearch",
                .product(name: "SwiftTiktoken", package: "swift-tiktoken"),
                .target(
                    name: "WaxVectorSearchMiniLM",
                    condition: .when(traits: ["MiniLMEmbeddings"])
                ),
            ],
            resources: [.process("RAG/Resources")],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .executableTarget(
            name: "WaxMCPServer",
            dependencies: [
                "Wax",
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
                .target(
                    name: "WaxVectorSearchMiniLM",
                    condition: .when(traits: ["MiniLMEmbeddings"])
                ),
            ],
            path: "Sources/WaxMCPServer",
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .executableTarget(
            name: "WaxCLI",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/WaxCLI",
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "WaxCoreTests",
            dependencies: ["WaxCore"],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "WaxIntegrationTests",
            dependencies: [
                "Wax",
                "WaxVectorSearchMiniLM",
                .product(name: "USearch", package: "USearch"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "SwiftTiktoken", package: "swift-tiktoken"),
            ],
            resources: [.process("Fixtures")],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "WaxMCPServerTests",
            dependencies: [
                "Wax",
                .target(
                    name: "WaxMCPServer",
                    condition: .when(traits: ["MCPServer"])
                ),
                .product(
                    name: "MCP",
                    package: "swift-sdk",
                    condition: .when(traits: ["MCPServer"])
                ),
            ],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
    ]
)
