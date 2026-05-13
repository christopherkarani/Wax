import Foundation
import Testing

@Test func waxMCPProductEnablesMiniLMCompileDefine() throws {
    let manifest = try PackageManifest.load()
    let target = try manifest.executableTarget(named: "wax-mcp")

    #expect(target.contains(miniLMCompileDefine))
}

private let miniLMCompileDefine =
    #".define("MiniLMEmbeddings", .when(traits: ["MiniLMEmbeddings"]))"#

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
