import ArgumentParser

struct StoreOptions: ParsableArguments {
    @Option(name: .customLong("store-path"), help: "Path to Wax memory store (.wax)")
    var storePath: String = StoreSession.defaultStorePath

    @Flag(name: .customLong("no-embedder"), help: "Disable MiniLM embedder (text-only search)")
    var noEmbedder: Bool = false

    @Option(name: .customLong("format"), help: "Output format: json (default) or text")
    var format: OutputFormat = .json
}

enum EmbedderChoice: String, CaseIterable, ExpressibleByArgument, Sendable {
    case minilm
    case arctic
}

struct VectorStoreOptions: ParsableArguments {
    @OptionGroup var base: StoreOptions

    @Option(name: .customLong("embedder"), help: "Embedder to use: minilm (default) or arctic")
    var embedder: EmbedderChoice = .minilm

    @Flag(
        name: .customLong("require-vector"),
        help: "Fail if vector search is unavailable instead of falling back to text-only mode"
    )
    var requireVector = false

    var storePath: String { base.storePath }
    var noEmbedder: Bool { base.noEmbedder }
    var format: OutputFormat { base.format }
}
