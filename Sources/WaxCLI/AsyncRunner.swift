import ArgumentParser
import Darwin
import Dispatch

protocol AsyncParsableCommand: ParsableCommand, Sendable {
    func runAsync() async throws
}

extension AsyncParsableCommand {
    mutating func run() throws {
        let command = self
        Task(priority: .userInitiated) {
            do {
                try await command.runAsync()
                Darwin.exit(EXIT_SUCCESS)
            } catch {
                writeStderr("Error: \(error.localizedDescription)")
                Darwin.exit(EXIT_FAILURE)
            }
        }
        dispatchMain()
    }
}
