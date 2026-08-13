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

@Test func brokerCorpusStoreBuildDoesNotDeleteExistingCorpusBeforeReplacement() throws {
    let source = try PackageSource.load("Sources/Wax/Broker/BrokerCorpusStore.swift")

    #expect(source.contains("try replaceExistingCorpusStore("))
    #expect(!source.contains("try fileManager.removeItem(at: standardizedTarget)\n        try fileManager.moveItem(at: buildURL, to: standardizedTarget)"))
}

@Test func waxIntegrationLinuxExcludesDarwinOnlyBenchmarks() throws {
    let manifest = try PackageManifest.load()
    let requiredExcludes = [
        "AccessStatsBootstrapBenchmarks.swift",
        "HandoffLookupBenchmarks.swift",
        "PayloadLivenessBenchmarks.swift",
        "RememberDedupBenchmarks.swift",
        "SessionRuntimeStatsBenchmarks.swift",
        "SurrogateSourceBenchmarks.swift",
    ]

    for file in requiredExcludes {
        #expect(manifest.source.contains(#""\#(file)""#))
    }
}

@Test func miniLMAndArcticTargetsDeclareWaxCoreDirectly() throws {
    let manifest = try PackageManifest.load()

    #expect(manifest.source.contains(#"""
        .target(
            name: "WaxVectorSearchMiniLM",
            dependencies: [
                "WaxCore",
                "WaxVectorSearch",
                "WaxBertTokenizer",
            ],
"""#))
    #expect(manifest.source.contains(#"""
        .target(
            name: "WaxVectorSearchArctic",
            dependencies: [
                "WaxCore",
                "WaxVectorSearch",
                "WaxBertTokenizer",
            ],
"""#))
}

@Test func consumerSizeGateInventoriesNonModelResourcesAndRejectsArcticMiniLM() throws {
    let source = try PackageSource.load("scripts/measure-consumer-size.sh")

    #expect(source.contains(#"arctic["miniLMResourceBytes"] != 0"#))
    #expect(source.contains(#"inv(arctic)["hasMiniLMModel"]"#))
    #expect(source.contains("hasTiktoken"))
    #expect(source.contains("hasBertVocab"))
    #expect(source.contains("hasWaxShaders"))
    #expect(source.contains("hasPrivacyInfo"))
    #expect(source.contains("Wax_Wax.bundle"))
    #expect(source.contains("waxBundlesMissingPrivacyInfo"))
    #expect(source.contains("Wax-owned bundles"))
    #expect(source.contains("-warnings-as-errors"))
    #expect(source.contains("--arch x86_64"))
    #expect(source.contains("traits-off consumer unexpectedly contains bert_tokenizer_vocab.txt"))
}

@Test func productionCoreMLLoadersBypassGeneratedBundleForceUnwrap() throws {
    let miniLM = try PackageSource.load("Sources/WaxVectorSearchMiniLM/CoreML/MiniLMEmbeddings.swift")
    let arctic = try PackageSource.load("Sources/WaxVectorSearchArctic/CoreML/ArcticEmbeddings.swift")
    let generatedMiniLM = try PackageSource.load("Sources/WaxVectorSearchMiniLM/CoreML/all-MiniLM-L6-v2.swift")
    let generatedArctic = try PackageSource.load("Sources/WaxVectorSearchArctic/CoreML/snowflake_arctic_embed_s.swift")

    #expect(miniLM.contains("loadModelFromBundle"))
    #expect(miniLM.contains("WaxBundleResolver.resolveModule"))
    #expect(!miniLM.contains("urlOfModelInThisBundle"))
    #expect(arctic.contains("loadModelFromBundle"))
    #expect(arctic.contains("WaxBundleResolver.resolveModule"))
    #expect(!arctic.contains("urlOfModelInThisBundle"))
    #expect(generatedMiniLM.contains("private class var urlOfModelInThisBundle"))
    #expect(generatedMiniLM.contains("private convenience init(configuration:"))
    #expect(!generatedMiniLM.contains("package convenience init(configuration:"))
    #expect(generatedArctic.contains("private class var urlOfModelInThisBundle"))
    #expect(generatedArctic.contains("private convenience init(configuration:"))
    #expect(!generatedArctic.contains("package convenience init(configuration:"))
    #expect(generatedMiniLM.contains(#"return bundle.url(forResource: "all-MiniLM-L6-v2", withExtension: "mlmodelc")!"#))
    #expect(generatedArctic.contains(#"return bundle.url(forResource: "snowflake-arctic-embed-s", withExtension: "mlmodelc")!"#))
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
    .package(url: "https://github.com/tuist/Noora.git", from: "0.54.0"),
]
"""#))
    #expect(manifest.source.contains(#"""
#if os(macOS)
waxRepoPackageDependencies = [
    // rensbreur/SwiftTUI has no tagged releases; pin the exact revision for reproducible
    // builds instead of tracking the moving `main` branch. (WaxRepo TUI only.)
    .package(url: "https://github.com/rensbreur/SwiftTUI.git", revision: "537133031bc2b2731048d00748c69700e1b48185"),
    .package(url: "https://github.com/tuist/Noora.git", from: "0.54.0"),
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
