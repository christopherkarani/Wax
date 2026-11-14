import Foundation
import Testing

@Test func waxMCPProductEnablesMiniLMCompileDefine() throws {
    let manifest = try PackageManifest.load()
    let target = try manifest.executableTarget(named: "wax-mcp")

    #expect(target.contains(miniLMCompileDefine))
}

@Test func waxRepoProductEnablesMiniLMCompileDefine() throws {
    let manifest = try PackageManifest.load()
    let target = try manifest.executableTarget(named: "WaxRepo")

    #expect(target.contains(miniLMCompileDefine))
}

@Test func waxMCPMultimodalAdapterGuardsCoreGraphicsImport() throws {
    let source = try PackageSource.load("Sources/WaxMCPServer/MultimodalAdapter.swift")

    #expect(source.contains("#if MCPServer && canImport(CoreGraphics) && canImport(ImageIO)"))
    #expect(!source.contains("#if MCPServer\nimport CoreGraphics"))
}

@Test func waxMCPEntrypointUsesPlatformNeutralExit() throws {
    let source = try PackageSource.load("Sources/WaxMCPServer/main.swift")

    #expect(!source.contains("Darwin.exit"))
}

@Test func waxMCPEntrypointDoesNotAdvertiseUnpublishedMultimodalTools() throws {
    let source = try PackageSource.load("Sources/WaxMCPServer/main.swift")

    #expect(!source.contains("multimodal RAG tools"))
}

@Test func brokerStartTimeoutDefaultAllowsParallelProcessTests() throws {
    let source = try PackageSource.load("Sources/Wax/Broker/AgentBrokerClient.swift")

    #expect(source.contains("envKey: \"WAX_BROKER_START_TIMEOUT_SECS\""))
    #expect(source.contains("defaultValue: 10.0"))
    #expect(!source.contains("envKey: \"WAX_BROKER_START_TIMEOUT_SECS\",\n        defaultValue: 5.0"))
}

@Test func brokerAutostartUsesIndependentNullDeviceDescriptors() throws {
    let source = try PackageSource.load("Sources/Wax/Broker/AgentBrokerClient.swift")

    #expect(source.contains("FileHandle(forReadingAtPath: \"/dev/null\")"))
    #expect(source.contains("FileHandle(forWritingAtPath: \"/dev/null\")"))
    #expect(source.contains("process.standardInput = nullInput"))
    #expect(source.contains("process.standardOutput = nullOutput"))
    #expect(!source.contains("let nullDevice = FileHandle(forWritingAtPath: \"/dev/null\")"))
}

@Test func brokerCorpusStoreBuildDoesNotDeleteExistingCorpusBeforeReplacement() throws {
    let source = try PackageSource.load("Sources/Wax/Broker/BrokerCorpusStore.swift")

    #expect(source.contains("try replaceExistingCorpusStore("))
    #expect(!source.contains("try fileManager.removeItem(at: standardizedTarget)\n        try fileManager.moveItem(at: buildURL, to: standardizedTarget)"))
}

/// Benchmarks and the Apple-only photo, video and benchmark-support files stay out of
/// the Linux build: they need XCTMetric, ImageIO, CoreGraphics or AVFoundation.
@Test func waxIntegrationLinuxExcludesDarwinOnlyBenchmarks() throws {
    let excludes = try PackageManifest.load().linuxIntegrationExcludes()
    let requiredExcludes = [
        "AccessStatsBootstrapBenchmarks.swift",
        "HandoffLookupBenchmarks.swift",
        "HybridVectorEngineBenchmark.swift",
        "PayloadLivenessBenchmarks.swift",
        "RAGBenchmarkSupport.swift",
        "RememberDedupBenchmarks.swift",
        "SessionRuntimeStatsBenchmarks.swift",
        "SurrogateSourceBenchmarks.swift",
        "VideoRAGTestSupport.swift",
    ]

    for file in requiredExcludes {
        #expect(excludes.contains(#""\#(file)""#), "\(file) needs Apple frameworks; exclude it on Linux")
    }
}

/// Every Linux exclude names a file that exists, so a rename cannot leave a stale entry.
@Test func waxIntegrationLinuxExcludesNameExistingFiles() throws {
    let excludes = try PackageManifest.load().linuxIntegrationExcludes()
    let testsRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("WaxIntegrationTests", isDirectory: true)
    let files = excludes.split(separator: "\n").compactMap { (line: Substring) -> String? in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("\""), trimmed.hasSuffix("\","), trimmed.count > 3 else { return nil }
        return String(trimmed.dropFirst().dropLast(2))
    }
    #expect(!files.isEmpty)
    for file in files {
        #expect(
            FileManager.default.fileExists(atPath: testsRoot.appendingPathComponent(file).path),
            "waxIntegrationLinuxExcludes lists missing file \(file)"
        )
    }
}

/// Suites that run on Linux (tokenizer and embedders through WaxMILRuntime, SQLite
/// through GRDBSQLite, CPU vector search) must stay compiled there. Files that mix in
/// Apple-only cases gate just those cases with `#if canImport(...)`.
@Test func waxIntegrationLinuxExcludesKeepPortableEmbedderTests() throws {
    let excludes = try PackageManifest.load().linuxIntegrationExcludes()
    let portable = [
        "BenchmarkTextFactory.swift",
        "BertTokenizerFastPathTests.swift",
        "BertTokenizerReuseTests.swift",
        "CoverageGapTests.swift",
        "FTS5SerializerTests.swift",
        "MemoryOrchestratorTests.swift",
        "MiniLMEmbedderTests.swift",
        "MiniLMEmbeddingQualityTests.swift",
        "MiniLMResourceFailureTests.swift",
        "RAGConfigClampingTests.swift",
        "StructuredMemoryCRUDTests.swift",
        "StructuredMemorySchemaTests.swift",
        "TextSearchEngineTests.swift",
        "UnifiedSearchTests.swift",
        "VectorSearchEngineTests.swift",
        "VersionRelationTests.swift",
    ]
    for file in portable {
        #expect(!excludes.contains(#""\#(file)""#), "\(file) is portable; do not exclude it on Linux")
    }
}

@Test func testTargetsUseToolchainSwiftTesting() throws {
    // The external swiftlang/swift-testing package's #expect silently passed false
    // Bool comparisons such as `#expect(flag == false)` on the Swift 6.4 toolchain.
    let manifest = try PackageManifest.load()
    #expect(!manifest.source.contains("swift-testing"))
}

@Test func waxRepoUIDependenciesAreMacOSScoped() throws {
    let manifest = try PackageManifest.load()

    #expect(manifest.source.contains(#"""
let waxRepoPackageDependencies: [Package.Dependency]
let waxRepoTargets: [Target]
#if os(macOS)
waxRepoPackageDependencies = [
    // rensbreur/SwiftTUI has no tagged releases; pin the exact revision for reproducible
    // builds instead of tracking the moving `main` branch. (WaxRepo TUI only.)
    .package(url: "https://github.com/rensbreur/SwiftTUI.git", revision: "537133031bc2b2731048d00748c69700e1b48185"),
    .package(url: "https://github.com/tuist/Noora.git", .upToNextMinor(from: "0.57.0")),
]
"""#))
    #expect(manifest.source.contains(#"""
#if os(macOS)
waxRepoPackageDependencies = [
    // rensbreur/SwiftTUI has no tagged releases; pin the exact revision for reproducible
    // builds instead of tracking the moving `main` branch. (WaxRepo TUI only.)
    .package(url: "https://github.com/rensbreur/SwiftTUI.git", revision: "537133031bc2b2731048d00748c69700e1b48185"),
    .package(url: "https://github.com/tuist/Noora.git", .upToNextMinor(from: "0.57.0")),
]
waxRepoTargets = [
    .executableTarget(
        name: "WaxRepo"
"""#))
    #expect(manifest.source.contains(#"    ] + waxRepoPackageDependencies,"#))
    #expect(manifest.source.contains(#"    ] + waxRepoTargets + ["#))
}

private let miniLMCompileDefine =
    #".define("MiniLMEmbeddings", .when(traits: ["MiniLMEmbeddings"]))"#

private struct PackageSource {
    static func load(_ path: String, filePath: String = #filePath) throws -> String {
        let testFile = URL(fileURLWithPath: filePath)
        let packageRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = packageRoot.appendingPathComponent(path)
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}

private struct PackageManifest {
    let source: String

    static func load(filePath: String = #filePath) throws -> PackageManifest {
        let testFile = URL(fileURLWithPath: filePath)
        let packageRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let manifestURL = packageRoot.appendingPathComponent("Package.swift")
        return PackageManifest(source: try String(contentsOf: manifestURL, encoding: .utf8))
    }

    /// The Linux branch of `waxIntegrationLinuxExcludes`.
    func linuxIntegrationExcludes() throws -> Substring {
        guard let start = source.range(of: "waxIntegrationLinuxExcludes = [")?.upperBound,
              let end = source[start...].range(of: "\n]")?.lowerBound
        else {
            throw ManifestError.missingTarget("waxIntegrationLinuxExcludes")
        }
        return source[start..<end]
    }

    func executableTarget(named targetName: String) throws -> Substring {
        var searchStart = source.startIndex
        while let targetStart = source[searchStart...].range(of: ".executableTarget(")?.lowerBound {
            let block = try executableTargetBlock(startingAt: targetStart, named: targetName)
            if block.contains(#"name: "\#(targetName)""#) {
                return block
            }
            searchStart = source.index(after: block.startIndex)
        }

        throw ManifestError.missingTarget(targetName)
    }

    private func executableTargetBlock(startingAt start: String.Index, named targetName: String) throws -> Substring {
        var depth = 0
        for index in source[start...].indices {
            switch source[index] {
            case "(":
                depth += 1
            case ")":
                depth -= 1
                if depth == 0 {
                    return source[start...index]
                }
            default:
                break
            }
        }

        throw ManifestError.unclosedTarget(targetName)
    }

    enum ManifestError: Error, CustomStringConvertible {
        case missingTarget(String)
        case unclosedTarget(String)

        var description: String {
            switch self {
            case .missingTarget(let targetName):
                "Package.swift does not contain executable target \(targetName)"
            case .unclosedTarget(let targetName):
                "Package.swift executable target \(targetName) is not closed"
            }
        }
    }
}
