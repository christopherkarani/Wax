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
                #if canImport(Darwin)
                Darwin.exit(EXIT_SUCCESS)
                #elseif canImport(Glibc)
                Glibc.exit(EXIT_SUCCESS)
                #endif
            } catch {
                writeStderr("Error: \(error.localizedDescription)")
                #if canImport(Darwin)
                Darwin.exit(EXIT_FAILURE)
                #elseif canImport(Glibc)
                Glibc.exit(EXIT_FAILURE)
                #endif
            }
        }
        dispatchMain()
    }
}
