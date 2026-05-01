import Foundation
import Wax

private enum DemoError: Error, CustomStringConvertible {
    case usage(String)

    var description: String {
        switch self {
        case .usage(let message): return message
        }
    }
}

private struct DemoOptions {
    var keepFile: Bool = false
}

private func parseArgs(_ args: [String]) throws -> DemoOptions {
    var options = DemoOptions()
    for arg in args {
        switch arg {
        case "--keep":
            options.keepFile = true
        case "--help", "-h":
            throw DemoError.usage(usage())
        default:
            throw DemoError.usage("Unknown arg: \(arg)\n\n\(usage())")
        }
    }
    return options
}

private func usage() -> String {
    """
    WaxDemo (public API validation)

    Usage:
      swift run WaxDemo [--keep]

    Flags:
      --keep    Keep the generated .wax file and print its path
    """
}

@main
struct WaxDemoMain {
    static func main() async throws {
        let options = try parseArgs(Array(CommandLine.arguments.dropFirst()))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-demo-\(UUID().uuidString)")
            .appendingPathExtension("wax")

        defer {
            if !options.keepFile {
                try? FileManager.default.removeItem(at: url)
            }
        }

        var config = Memory.Config()
        config.enableVectorSearch = false
        let memory = try await Memory(at: url, config: config)

        try await memory.save(
            "WaxDemo stores and retrieves public Memory facade content.",
            metadata: ["source": "WaxDemo"]
        )

        var searchOptions = Memory.SearchOptions()
        searchOptions.mode = .textOnly
        searchOptions.topK = 3
        let context = try await memory.search("What does WaxDemo validate?", options: searchOptions)

        print("File:", url.path)
        print("Results:", context.items.count)
        if let best = context.items.first {
            print("Top result:", best.text)
            print("Source:", best.metadata["source"] ?? "unknown")
        }
        print("OK")

        try await memory.close()
    }
}
