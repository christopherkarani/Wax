#if MCPServer
import Logging
import MCP

import struct Foundation.Data
import class Foundation.JSONDecoder

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
/// StdIO transport that, at stdin EOF, keeps the connection up until every request it
/// delivered has been answered (bounded by `eofDrainTimeout`), then waits a short grace period
/// before the server tears the connection down. The server handles each request in its own
/// task and stops once the receive stream ends, so ending it earlier dropped a request still
/// being handled, such as a remember that started the broker.
actor GracefulStdioTransport: Transport {
    private let input: FileDescriptor
    private let output: FileDescriptor
    nonisolated let logger: Logger
    private let eofGracePeriod: Duration
    private let eofDrainTimeout: Duration
    /// Requests delivered to the server whose response has not been sent yet.
    private var unansweredRequests: Set<RequestKey> = []

    private var isConnected = false
    private let messageStream: AsyncThrowingStream<Data, Swift.Error>
    private let messageContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation

    init(
        input: FileDescriptor = .standardInput,
        output: FileDescriptor = .standardOutput,
        eofGracePeriod: Duration = .milliseconds(250),
        eofDrainTimeout: Duration = .seconds(30),
        logger: Logger? = nil
    ) {
        self.input = input
        self.output = output
        self.eofGracePeriod = eofGracePeriod
        self.eofDrainTimeout = eofDrainTimeout
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
        var zeroWriteCount = 0
        while !remaining.isEmpty {
            do {
                let written = try remaining.withUnsafeBytes { buffer in
                    try output.write(UnsafeRawBufferPointer(buffer))
                }
                if written > 0 {
                    remaining = remaining.dropFirst(written)
                    zeroWriteCount = 0
                } else {
                    zeroWriteCount += 1
                    if zeroWriteCount > 100 {
                        throw MCPError.transportError(Errno(rawValue: EIO))
                    }
                    try await Task.sleep(for: .milliseconds(10))
                }
            } catch let error where MCPError.isResourceTemporarilyUnavailable(error) {
                try await Task.sleep(for: .milliseconds(10))
                continue
            } catch {
                throw MCPError.transportError(error)
            }
        }
        for envelope in Self.envelopes(of: message) where envelope.method == nil {
            if let id = envelope.id { unansweredRequests.remove(id) }
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
                    // A final message without a trailing newline is still a message.
                    if pendingData.contains(where: { !Self.isWhitespace($0) }) {
                        deliver(Data(pendingData))
                    }
                    await waitForUnansweredRequests()
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
            deliver(Data(messageData))
        }
    }

    private func deliver(_ message: Data) {
        for envelope in Self.envelopes(of: message) where envelope.method != nil {
            if let id = envelope.id { unansweredRequests.insert(id) }
        }
        messageContinuation.yield(message)
    }

    /// Suspends the read loop (other calls, such as `send`, still run) until every delivered
    /// request is answered or `eofDrainTimeout` passes.
    private func waitForUnansweredRequests() async {
        let deadline = ContinuousClock.now + eofDrainTimeout
        while !unansweredRequests.isEmpty, isConnected, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        if !unansweredRequests.isEmpty {
            logger.warning("Closing stdio transport with unanswered requests", metadata: [
                "count": "\(unansweredRequests.count)",
            ])
        }
    }

    /// A JSON-RPC message's id and method, or each element's for a batch. Requests carry
    /// both, responses only an id, notifications only a method.
    private struct MessageEnvelope: Decodable {
        let id: RequestKey?
        let method: String?
    }

    private enum RequestKey: Decodable, Hashable {
        case number(Int64)
        case string(String)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Int64.self) {
                self = .number(number)
            } else {
                self = .string(try container.decode(String.self))
            }
        }
    }

    private static func envelopes(of message: Data) -> [MessageEnvelope] {
        let decoder = JSONDecoder()
        if let single = try? decoder.decode(MessageEnvelope.self, from: message) {
            return [single]
        }
        return (try? decoder.decode([MessageEnvelope].self, from: message)) ?? []
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t")
            || byte == UInt8(ascii: "\r") || byte == UInt8(ascii: "\n")
    }
}
#endif
#endif
