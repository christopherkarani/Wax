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
    ],
    dependencies: [
        .package(url: "https://github.com/unum-cloud/USearch.git", from: "2.23.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.24.0"),
        .package(url: "https://github.com/narner/TiktokenSwift.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
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
                .product(name: "TiktokenSwift", package: "TiktokenSwift"),
                .target(
                    name: "WaxVectorSearchMiniLM",
                    condition: .when(traits: ["MiniLMEmbeddings"])
                ),
            ],
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
                .product(name: "TiktokenSwift", package: "TiktokenSwift"),
            ],
            resources: [.process("Fixtures")],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
    ]
)
