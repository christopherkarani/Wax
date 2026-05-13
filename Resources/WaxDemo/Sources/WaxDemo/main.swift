import Foundation
import Wax

private enum DemoError: Error, CustomStringConvertible {
    case usage(String)

    var description: String {
        switch self {
        case .usage(let message):
            return message
        }
    }
}

private struct DemoOptions {
    var keepFile = false
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
    WaxDemo

    Usage:
      swift run WaxDemo [--keep]

    Flags:
      --keep    Keep the generated .wax file and print its path.
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

        let config = Memory.Config(
            enableVectorSearch: false,
            requireOnDeviceProviders: false
        )
        let memory = try await Memory(at: url, config: config)

        try await memory.save(
            "Wax keeps local agent memory in one portable file.",
            metadata: ["demo": "waxdemo"]
        )

        let searchOptions = Memory.SearchOptions(topK: 3, mode: .textOnly)
        let results = try await memory.search("portable local memory", options: searchOptions)

        guard let first = results.items.first else {
            throw WaxError.io("expected demo search result")
        }

        print("File:", url.path)
        print("Found:", first.text)
        print("OK")

        try await memory.close()
    }
}
