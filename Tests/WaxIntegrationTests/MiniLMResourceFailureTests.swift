#if canImport(WaxVectorSearchMiniLM)
import Foundation
import Testing
@testable import Wax
@testable import WaxVectorSearchMiniLM

@available(macOS 15.0, iOS 18.0, *)
@Test
func productionMiniLMCoreMLLoadThrowsWhenBundleModelAbsent() throws {
    let emptyBundle = try makeEmptyCoreMLResourceBundle()
    var overrides = MiniLMEmbeddings.Overrides.default
    overrides.resourceBundleURL = emptyBundle
    do {
        _ = try MiniLMEmbeddings(overrides: overrides)
        Issue.record("Expected missing CoreML model resource to throw")
    } catch {
        expectMiniLMInitError(error, matches: .missingModelResource)
    }
}

@available(macOS 15.0, iOS 18.0, *)
@Test
func openMiniLMThrowsWhenModelMissing() async throws {
    await TempFiles.withTempFile { url in
        do {
            _ = try await MemoryOrchestrator.openMiniLM(
                at: url,
                config: .default,
                overrides: .missingModel
            )
            Issue.record("Expected missing model resource error")
        } catch {
            expectMiniLMInitError(error, matches: .missingModelResource)
        }
    }
}

@available(macOS 15.0, iOS 18.0, *)
@Test
func openMiniLMThrowsWhenTokenizerMissing() async throws {
    await TempFiles.withTempFile { url in
        do {
            _ = try await MemoryOrchestrator.openMiniLM(
                at: url,
                config: .default,
                overrides: .missingTokenizer
            )
            Issue.record("Expected tokenizer load error")
        } catch {
            expectMiniLMInitError(error, matches: .tokenizerLoadFailed("override requested failure"))
        }
    }
}

@available(macOS 15.0, iOS 18.0, *)
private func expectMiniLMInitError(
    _ error: any Error,
    matches expected: MiniLMEmbeddings.InitError
) {
    guard let actual = error as? MiniLMEmbeddings.InitError else {
        Issue.record("Expected MiniLMEmbeddings.InitError, got \(error)")
        return
    }

    switch (actual, expected) {
    case (.missingModelResource, .missingModelResource):
        break
    case (.modelLoadFailed(let actualMessage), .modelLoadFailed(let expectedMessage)):
        #expect(actualMessage == expectedMessage)
    case (.tokenizerLoadFailed(let actualMessage), .tokenizerLoadFailed(let expectedMessage)):
        #expect(actualMessage == expectedMessage)
    default:
        Issue.record("Expected \(expected), got \(actual)")
    }
}

private func makeEmptyCoreMLResourceBundle() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-empty-coreml-\(UUID().uuidString).bundle", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let info = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>CFBundleIdentifier</key>
        <string>dev.wax.empty-coreml</string>
        <key>CFBundleName</key>
        <string>empty-coreml</string>
        <key>CFBundlePackageType</key>
        <string>BNDL</string>
        <key>CFBundleVersion</key>
        <string>1</string>
    </dict>
    </plist>
    """
    try info.write(to: root.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
    return root
}

#endif
