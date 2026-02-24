import ArgumentParser
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
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
                exit(EXIT_SUCCESS)
            } catch {
                writeStderr("Error: \(error.localizedDescription)")
                exit(EXIT_FAILURE)
            }
        }
        dispatchMain()
    }
}
