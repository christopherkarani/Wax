import Foundation
import Wax

@main
struct WaxDemoCorruptTOC {
    static func main() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-demo-corrupt-toc-\(UUID().uuidString)")
            .appendingPathExtension("wax")
        defer { try? FileManager.default.removeItem(at: url) }

        var config = Memory.Config()
        config.enableVectorSearch = false
        let memory = try await Memory(at: url, config: config)

        try await memory.save(
            "Wax internal corruption handling is validated in package tests; this demo proves the checked-in external package builds against public API.",
            metadata: ["demo": "corrupt-toc-public-smoke"]
        )

        var options = Memory.SearchOptions()
        options.mode = .textOnly
        options.topK = 1
        let context = try await memory.search("corruption handling package tests", options: options)

        guard !context.items.isEmpty else {
            throw WaxError.io("expected public Memory search to return the saved corruption note")
        }

        print("File:", url.path)
        print("Results:", context.items.count)
        print("OK")

        try await memory.close()
    }
}
