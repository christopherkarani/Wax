import ArgumentParser
import Foundation

enum OutputFormat: String, CaseIterable, ExpressibleByArgument {
    case json
    case text
}

func writeStderr(_ message: String) {
    guard let data = (message + "\n").data(using: .utf8) else { return }
    FileHandle.standardError.write(data)
}

func printJSON(_ dict: [String: Any]) {
    guard let data = try? JSONSerialization.data(
        withJSONObject: dict, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    ), let str = String(data: data, encoding: .utf8) else { return }
    print(str)
}
