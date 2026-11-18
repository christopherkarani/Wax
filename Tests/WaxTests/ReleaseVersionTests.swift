import Foundation
import Testing
@testable import Wax

private func packageRoot(filePath: String = #filePath) -> URL {
    URL(fileURLWithPath: filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

@Test func npmPackageVersionMatchesSwiftReleaseVersion() throws {
    let data = try Data(contentsOf: packageRoot().appendingPathComponent("Resources/npm/waxmcp/package.json"))
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["version"] as? String == WaxReleaseInfo.version)
}

@Test func executablesCarryNoVersionLiteralOfTheirOwn() throws {
    let root = packageRoot()
    let server = try String(contentsOf: root.appendingPathComponent("Sources/WaxMCPServer/main.swift"), encoding: .utf8)
    let cli = try String(contentsOf: root.appendingPathComponent("Sources/WaxCLI/WaxCLICommand.swift"), encoding: .utf8)
    #expect(server.contains("static let version = WaxReleaseInfo.version"))
    #expect(cli.contains("version: WaxReleaseInfo.version"))
}
