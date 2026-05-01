import Foundation
import Wax

@main
struct WaxDemoMultiFooter {
    static func main() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-demo-multi-footer-\(UUID().uuidString)")
            .appendingPathExtension("wax")
        defer { try? FileManager.default.removeItem(at: url) }

        var config = Memory.Config()
        config.enableVectorSearch = false
        let memory = try await Memory(at: url, config: config)

        try await memory.save(
            "Wax footer selection is covered by internal tests; this demo validates the public package wiring.",
            metadata: ["demo": "multi-footer-public-smoke"]
        )

        var options = Memory.SearchOptions()
        options.mode = .textOnly
        options.topK = 1
        let context = try await memory.search("public package wiring", options: options)

        guard let best = context.items.first else {
            throw WaxError.io("expected public Memory search to return the saved wiring note")
        }

        print("File:", url.path)
        print("Top result:", best.text)
        print("OK")

        try await memory.close()
    }
}
