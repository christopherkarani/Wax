#if MCPServer
import Logging
import MCP

import struct Foundation.Data

#if canImport(System)
import System
#else
@preconcurrency import SystemPackage
#endif

#if canImport(Darwin)
import Darwin.POSIX
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

#if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
/// StdIO transport with a short EOF grace period so already-received requests can
/// finish sending their responses before the server tears down the connection.
actor GracefulStdioTransport: Transport {
    private let input: FileDescriptor
    private let output: FileDescriptor
    nonisolated let logger: Logger
    private let eofGracePeriod: Duration

    private var isConnected = false
    private let messageStream: AsyncThrowingStream<Data, Swift.Error>
    private let messageContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation

    init(
        input: FileDescriptor = .standardInput,
        output: FileDescriptor = .standardOutput,
        eofGracePeriod: Duration = .milliseconds(250),
        logger: Logger? = nil
    ) {
        self.input = input
        self.output = output
        self.eofGracePeriod = eofGracePeriod
        self.logger =
            logger
            ?? Logger(
                label: "wax.mcp.transport.stdio",
                factory: { _ in SwiftLogNoOpLogHandler() }
            )

        var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation!
        self.messageStream = AsyncThrowingStream { continuation = $0 }
        self.messageContinuation = continuation
    }

    func connect() async throws {
        guard !isConnected else { return }
        try setNonBlocking(fileDescriptor: input)
        try setNonBlocking(fileDescriptor: output)
        isConnected = true

        Task {
            await readLoop()
        }
    }

    func disconnect() async {
        guard isConnected else { return }
        isConnected = false
        messageContinuation.finish()
    }

    func send(_ message: Data) async throws {
        guard isConnected else {
            throw MCPError.transportError(Errno(rawValue: ENOTCONN))
        }

        var messageWithNewline = message
        messageWithNewline.append(UInt8(ascii: "\n"))

        var remaining = messageWithNewline
        while !remaining.isEmpty {
            do {
                let written = try remaining.withUnsafeBytes { buffer in
                    try output.write(UnsafeRawBufferPointer(buffer))
                }
                if written > 0 {
                    remaining = remaining.dropFirst(written)
                }
            } catch let error where MCPError.isResourceTemporarilyUnavailable(error) {
                try await Task.sleep(for: .milliseconds(10))
                continue
            } catch {
                throw MCPError.transportError(error)
            }
        }
    }

    func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        messageStream
    }

    private func setNonBlocking(fileDescriptor: FileDescriptor) throws {
        let flags = fcntl(fileDescriptor.rawValue, F_GETFL)
        guard flags >= 0 else {
            throw MCPError.transportError(Errno(rawValue: CInt(errno)))
        }

        let result = fcntl(fileDescriptor.rawValue, F_SETFL, flags | O_NONBLOCK)
        guard result >= 0 else {
            throw MCPError.transportError(Errno(rawValue: CInt(errno)))
        }
    }

    private func readLoop() async {
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var pendingData = Data()

        while isConnected && !Task.isCancelled {
            do {
                let bytesRead = try buffer.withUnsafeMutableBufferPointer { pointer in
                    try input.read(into: UnsafeMutableRawBufferPointer(pointer))
                }

                if bytesRead == 0 {
                    logger.notice("EOF received; waiting briefly before closing stdio transport")
                    if !pendingData.isEmpty {
                        yieldCompleteLines(from: &pendingData)
                    }
                    try? await Task.sleep(for: eofGracePeriod)
                    break
                }

                pendingData.append(Data(buffer[..<bytesRead]))
                yieldCompleteLines(from: &pendingData)
            } catch let error where MCPError.isResourceTemporarilyUnavailable(error) {
                try? await Task.sleep(for: .milliseconds(10))
                continue
            } catch {
                if !Task.isCancelled {
                    logger.error("Read error occurred", metadata: ["error": "\(error)"])
                }
                break
            }
        }

        messageContinuation.finish()
    }

    private func yieldCompleteLines(from pendingData: inout Data) {
        while let newlineIndex = pendingData.firstIndex(of: UInt8(ascii: "\n")) {
            let messageData = pendingData[..<newlineIndex]
            pendingData = pendingData[(newlineIndex + 1)...]
            guard !messageData.isEmpty else { continue }
            messageContinuation.yield(Data(messageData))
        }
    }
}
#endif
#endif
