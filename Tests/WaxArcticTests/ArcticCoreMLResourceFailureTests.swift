#if canImport(CoreML)
import Foundation
import Testing
@testable import WaxVectorSearchArctic

@available(macOS 15.0, iOS 18.0, *)
@Test
func productionArcticCoreMLLoadThrowsWhenBundleModelAbsent() throws {
    let emptyBundle = try makeEmptyCoreMLResourceBundle()
    var overrides = ArcticEmbeddings.Overrides.default
    overrides.resourceBundleURL = emptyBundle
    do {
        _ = try ArcticEmbeddings(overrides: overrides)
        Issue.record("Expected missing CoreML model resource to throw")
    } catch let error as ArcticEmbeddings.InitError {
        guard case .missingModelResource = error else {
            Issue.record("Expected missingModelResource, got \(error)")
            return
        }
    } catch {
        Issue.record("Expected ArcticEmbeddings.InitError, got \(error)")
    }
}

private func makeEmptyCoreMLResourceBundle() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-empty-arctic-coreml-\(UUID().uuidString).bundle", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let info = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>CFBundleIdentifier</key>
        <string>dev.wax.empty-arctic-coreml</string>
        <key>CFBundleName</key>
        <string>empty-arctic-coreml</string>
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
