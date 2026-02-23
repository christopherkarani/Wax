import ArgumentParser

struct StoreOptions: ParsableArguments {
    @Option(name: .customLong("store-path"), help: "Path to Wax memory store (.mv2s)")
    var storePath: String = StoreSession.defaultStorePath

    @Flag(name: .customLong("no-embedder"), help: "Disable MiniLM embedder (text-only search)")
    var noEmbedder: Bool = false

    @Option(name: .customLong("format"), help: "Output format: json (default) or text")
    var format: OutputFormat = .json
}
