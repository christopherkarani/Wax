#if WaxRepo
import ArgumentParser
import Darwin
import Dispatch
import Foundation

struct WaxRepoCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wax-repo",
        abstract: "Semantic git history search powered by Wax",
        subcommands: [IndexCommand.self, SearchCommand.self, StatsCommand.self],
        defaultSubcommand: SearchCommand.self
    )
}

WaxRepoCommand.main()
#else
import Darwin
import Foundation

let message = "WaxRepo requires the WaxRepo trait. Build with --traits WaxRepo.\n"
if let data = message.data(using: .utf8) {
    FileHandle.standardError.write(data)
}
Darwin.exit(EXIT_FAILURE)
#endif
