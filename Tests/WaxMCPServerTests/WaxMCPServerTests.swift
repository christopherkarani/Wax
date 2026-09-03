import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if MCPServer
import MCP
import NIOEmbedded
import NIOHTTP1
@testable import wax_mcp
@testable import Wax
import XCTest

private let waxMCPTestSignalSetup: Void = {
    // Process and broker peers can close while another parallel test is
    // finishing its request. Keep a broken pipe as EPIPE instead of killing
    // the shared Swift test runner with SIGPIPE.
    signal(SIGPIPE, SIG_IGN)
}()

private func prepareWaxMCPTestProcessIO() {
    _ = waxMCPTestSignalSetup
}

private func withAgentBrokerService<T>(
    _ body: (AgentBrokerService, URL) async throws -> T
) async throws -> T {
    prepareWaxMCPTestProcessIO()
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-broker-test-\(UUID().uuidString)", isDirectory: true)
    let storeURL = rootURL.appendingPathComponent("memory.wax")
    let sessionRootURL = rootURL.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let service = try await AgentBrokerService(
        storePath: storeURL.path,
        sessionRootPath: sessionRootURL.path,
        noEmbedder: true,
        embedderChoice: "auto",
        requireVector: false
    )
    do {
        let result = try await body(service, sessionRootURL)
        try await service.close()
        return result
    } catch {
        try? await service.close()
        throw error
    }
}

@Test
func agentBrokerResponseWireFormatMatchesLegacyShape() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]

    let success = AgentBrokerResponse.success(
        id: "req-1",
        payload: .object(["status": .string("ok")])
    )
    #expect(
        String(data: try encoder.encode(success), encoding: .utf8)
            == #"{"id":"req-1","ok":true,"payload":{"status":"ok"},"shouldExit":false}"#
    )

    let successNoID = AgentBrokerResponse.success(payload: .object([:]), shouldExit: true)
    #expect(
        String(data: try encoder.encode(successNoID), encoding: .utf8)
            == #"{"ok":true,"payload":{},"shouldExit":true}"#
    )

    let failure = AgentBrokerResponse.failure(
        id: "req-2",
        payload: .object(["code": .string("bad_request")]),
        message: "unsupported argument"
    )
    #expect(
        String(data: try encoder.encode(failure), encoding: .utf8)
            == #"{"error":"unsupported argument","id":"req-2","ok":false,"payload":{"code":"bad_request"},"shouldExit":false}"#
    )

    let failureNoPayload = AgentBrokerResponse.failure(id: "req-3", message: "boom")
    #expect(
        String(data: try encoder.encode(failureNoPayload), encoding: .utf8)
            == #"{"error":"boom","id":"req-3","ok":false,"shouldExit":false}"#
    )

    let decoder = JSONDecoder()
    let decodedSuccess = try decoder.decode(
        AgentBrokerResponse.self,
        from: Data(#"{"id":"req-1","ok":true,"payload":{"status":"ok"},"shouldExit":false}"#.utf8)
    )
    #expect(decodedSuccess == success)

    let successNullPayload = AgentBrokerResponse.success(payload: .null)
    #expect(
        String(data: try encoder.encode(successNullPayload), encoding: .utf8)
            == #"{"ok":true,"payload":null,"shouldExit":false}"#
    )

    let decodedLegacyEmptyPayload = try decoder.decode(
        AgentBrokerResponse.self,
        from: Data(#"{"id":"req-4","ok":true,"shouldExit":false}"#.utf8)
    )
    #expect(decodedLegacyEmptyPayload.ok)
    #expect(decodedLegacyEmptyPayload.payload == nil)

    let decodedLegacyFailureWithoutError = try decoder.decode(
        AgentBrokerResponse.self,
        from: Data(#"{"id":"req-5","ok":false,"shouldExit":false}"#.utf8)
    )
    #expect(!decodedLegacyFailureWithoutError.ok)
    #expect(decodedLegacyFailureWithoutError.error == "Broker execution failed")
    #expect(decodedLegacyFailureWithoutError.payload == nil)

    let decodedFailure = try decoder.decode(
        AgentBrokerResponse.self,
        from: Data(
            #"{"id":"req-2","ok":false,"payload":{"code":"bad_request"},"error":"unsupported argument","shouldExit":false}"#.utf8
        )
    )
    #expect(decodedFailure == failure)
}

@Test
func brokerRejectsInvalidEmbedderChoice() async throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-broker-invalid-embedder-\(UUID().uuidString)", isDirectory: true)
    let storeURL = rootURL.appendingPathComponent("memory.wax")
    let sessionRootURL = rootURL.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    do {
        let service = try await AgentBrokerService(
            storePath: storeURL.path,
            sessionRootPath: sessionRootURL.path,
            noEmbedder: false,
            embedderChoice: "definitelyInvalid",
            requireVector: false
        )
        try await service.close()
        Issue.record("invalid embedder choice should fail instead of falling back to MiniLM")
    } catch {
        #expect(error.localizedDescription.contains("Invalid embedder choice"))
        #expect(error.localizedDescription.contains("minilm"))
        #expect(error.localizedDescription.contains("arctic"))
    }
}

@Test
func isSocketLiveDistinguishesMissingStaleAndListeningSockets() throws {
    let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
        .appendingPathComponent("wxsa-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let missing = root.appendingPathComponent("missing.sock").path
    #expect(!AgentBrokerClient.isSocketLive(socketPath: missing))

    let stale = root.appendingPathComponent("stale.sock").path
    try makeStaleUnixSocket(at: stale)
    #expect(FileManager.default.fileExists(atPath: stale))
    #expect(!AgentBrokerClient.isSocketLive(socketPath: stale))

    let live = root.appendingPathComponent("live.sock").path
    let listener = try bindAndListenUnixSocket(at: live)
    defer {
        close(listener)
        unlink(live)
    }
    #expect(AgentBrokerClient.isSocketLive(socketPath: live))
}

@Test
func ensureAvailableDoesNotUnlinkSocketOnConnectFailure() async throws {
    let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
        .appendingPathComponent("wxsa-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let socketPath = root.appendingPathComponent("broker.sock").path
    try makeStaleUnixSocket(at: socketPath)

    do {
        _ = try await AgentBrokerClient.ensureAvailable(
            configuration: testBrokerConfiguration(root: root, socketPath: socketPath)
        )
        Issue.record("expected ensureAvailable to fail without a broker executable")
    } catch {
        #expect(error.localizedDescription.contains("not executable"))
    }

    #expect(FileManager.default.fileExists(atPath: socketPath))
}

@Test
func ensureAvailableReusesLiveBrokerWithoutStartingReplacement() async throws {
    let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
        .appendingPathComponent("wxsa-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let socketPath = root.appendingPathComponent("broker.sock").path
    let listener = try bindAndListenUnixSocket(at: socketPath)
    defer {
        close(listener)
        unlink(socketPath)
    }

    let server = UnixStatsResponder(listener: listener)
    server.start(holdFirstRequest: false)
    defer { server.stop() }

    let started = try await AgentBrokerClient.ensureAvailable(
        configuration: testBrokerConfiguration(root: root, socketPath: socketPath)
    )
    #expect(started == false)
}

@Test(.timeLimit(.minutes(1)))
func shortAttachPingTimeoutFallsThroughToLiveRetry() async throws {
    let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
        .appendingPathComponent("wxsa-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let socketPath = root.appendingPathComponent("broker.sock").path
    let listener = try bindAndListenUnixSocket(at: socketPath)
    defer {
        close(listener)
        unlink(socketPath)
    }

    let server = UnixStatsResponder(listener: listener)
    server.start(holdFirstRequest: true)
    defer { server.stop() }

    let started = try await AgentBrokerClient.ensureAvailable(
        configuration: testBrokerConfiguration(root: root, socketPath: socketPath)
    )
    #expect(started == false)
}

#if canImport(Darwin)
private let testUnixStreamSocketType: Int32 = SOCK_STREAM
#else
private let testUnixStreamSocketType: Int32 = Int32(SOCK_STREAM.rawValue)
#endif

private func testBrokerConfiguration(root: URL, socketPath: String) -> AgentBrokerConfiguration {
    AgentBrokerConfiguration(
        brokerExecutablePath: "/nonexistent/wax-cli-must-not-start",
        storePath: root.appendingPathComponent("memory.wax").path,
        sessionRootPath: root.appendingPathComponent("sessions").path,
        socketPath: socketPath,
        embedderChoice: "auto",
        noEmbedder: true,
        requireVector: false,
        embedderTuning: .fromEnvironment()
    )
}

private func bindAndListenUnixSocket(at path: String) throws -> Int32 {
    let fd = socket(AF_UNIX, testUnixStreamSocketType, 0)
    guard fd >= 0 else {
        throw TestUnixSocketError("socket: \(String(cString: strerror(errno)))")
    }

    var address = sockaddr_un()
    #if canImport(Darwin)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    #endif
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8)
    guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
        close(fd)
        throw TestUnixSocketError("path too long: \(path)")
    }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        buffer.initializeMemory(as: CChar.self, repeating: 0)
        for (index, byte) in pathBytes.enumerated() {
            buffer[index] = byte
        }
    }

    let bindResult = withUnsafePointer(to: &address) { pointer -> Int32 in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard bindResult == 0 else {
        close(fd)
        throw TestUnixSocketError("bind: \(String(cString: strerror(errno)))")
    }
    guard listen(fd, 16) == 0 else {
        close(fd)
        unlink(path)
        throw TestUnixSocketError("listen: \(String(cString: strerror(errno)))")
    }
    return fd
}

private func makeStaleUnixSocket(at path: String) throws {
    let fd = try bindAndListenUnixSocket(at: path)
    close(fd)
}

private struct TestUnixSocketError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

private final class UnixStatsResponder: @unchecked Sendable {
    private let listener: Int32
    private let lock = NSLock()
    private let ready = DispatchSemaphore(value: 0)
    private var stopped = false
    private var heldFDs: [Int32] = []
    private var holdFirstRequest = false
    private var heldFirstRequest = false

    init(listener: Int32) {
        self.listener = listener
    }

    func start(holdFirstRequest: Bool) {
        lock.lock()
        self.holdFirstRequest = holdFirstRequest
        lock.unlock()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            self.ready.signal()
            while true {
                guard !self.isStopped else { return }
                var descriptor = pollfd(fd: self.listener, events: Int16(POLLIN), revents: 0)
                let pollResult = poll(&descriptor, 1, 50)
                if pollResult == 0 { continue }
                if pollResult < 0 {
                    if errno == EINTR { continue }
                    return
                }
                let client = accept(self.listener, nil, nil)
                if client < 0 {
                    if errno == EINTR { continue }
                    return
                }
                self.handle(client: client)
            }
        }
        ready.wait()
    }

    func stop() {
        lock.lock()
        stopped = true
        let held = heldFDs
        heldFDs.removeAll()
        lock.unlock()
        for fd in held {
            close(fd)
        }
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func handle(client: Int32) {
        var descriptor = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
        let pollResult = poll(&descriptor, 1, 2_000)
        if pollResult <= 0 {
            close(client)
            return
        }

        var chunk = [UInt8](repeating: 0, count: 4096)
        let count = recv(client, &chunk, chunk.count, 0)
        if count <= 0 {
            close(client)
            return
        }

        let shouldHold: Bool = {
            lock.lock()
            defer { lock.unlock() }
            if holdFirstRequest && !heldFirstRequest {
                heldFirstRequest = true
                heldFDs.append(client)
                return true
            }
            return false
        }()
        if shouldHold {
            return
        }

        let response = AgentBrokerResponse.success(id: "__ping__", payload: .object([:]))
        guard let payload = try? JSONEncoder().encode(response) else {
            close(client)
            return
        }
        var data = payload
        data.append(0x0A)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            _ = write(client, base, data.count)
        }
        close(client)
    }
}

@Test
func toolsListContainsExpectedTools() {
    let expected: Set<String> = [
        "session_open",
        "remember",
        "recall",
        "session_close",
        "stats",
        "memory_get",
        "compact_context",
        "session_resume",
    ]
    let names = Set(
        ToolSchemas.tools(
            structuredMemoryEnabled: true,
            profile: .fromEnvironment([:])
        ).map(\.name)
    )
    #expect(MCPToolProfile.dailyNames == [
        "session_open",
        "remember",
        "recall",
        "session_close",
        "stats",
        "memory_get",
        "compact_context",
        "session_resume",
    ])
    #expect(names == expected)
    #expect(
        ToolSchemas.tools(structuredMemoryEnabled: true, profile: .daily).map(\.name)
            == MCPToolProfile.dailyNames
    )
    #expect(names.count == 8)
    #expect(!names.contains("memory_append"))
    #expect(!names.contains("promote"))
    #expect(!names.contains("memory_promote"))
    #expect(!names.contains("search"))
    #expect(!names.contains("flush"))
    #expect(!names.contains("memory_maintain"))
    #expect(!names.contains("sessions_prune"))
}

@Test
func mcpToolProfileFromEnvironmentSelectsDailyAndFull() {
    #expect(MCPToolProfile.fromEnvironment([:]) == .daily)
    #expect(MCPToolProfile.fromEnvironment(["WAX_MCP_TOOLS": "daily"]) == .daily)
    #expect(MCPToolProfile.fromEnvironment(["WAX_MCP_TOOLS": "full"]) == .full)
    #expect(MCPToolProfile.fromEnvironment(["WAX_MCP_TOOLS": "FULL"]) == .full)
    #expect(MCPToolProfile.fromEnvironment(["WAX_MCP_TOOLS": " full "]) == .full)
    #expect(MCPToolProfile.fromEnvironment(["WAX_MCP_TOOLS": "aliases"]) == .daily)
    let fullNames = Set(
        ToolSchemas.tools(
            structuredMemoryEnabled: true,
            profile: .fromEnvironment(["WAX_MCP_TOOLS": "full"])
        ).map(\.name)
    )
    #expect(fullNames.contains("memory_append"))
    #expect(fullNames.contains("promote"))
}

@Test
func allToolsIsTheFullPublishedCatalog() {
    #expect(ToolSchemas.allTools.map(\.name) == ToolSchemas.allPublishedTools.map(\.name))
    #expect(ToolSchemas.allTools.map(\.name).contains("memory_append"))
    #expect(ToolSchemas.allTools.map(\.name).contains("remember"))
}

@Test
func toolsListFullProfileContainsAliases() {
    let names = Set(ToolSchemas.tools(structuredMemoryEnabled: true, profile: .full).map(\.name))
    #expect(names.contains("memory_append"))
    #expect(names.contains("memory_search"))
    #expect(names.contains("memory_get"))
    #expect(names.contains("remember"))
    #expect(names.contains("recall"))
    #expect(names.contains("search"))
    #expect(names.contains("session_synthesize"))
    #expect(names.contains("memory_promote"))
    #expect(names.contains("promote"))
    #expect(names.contains("memory_health"))
    #expect(names.contains("knowledge_capture"))
    #expect(names.contains("corpus_search"))
    #expect(!names.contains("flush"))
    #expect(!names.contains("memory_maintain"))
    #expect(names.contains("stats"))
    #expect(names.contains("session_start"))
    #expect(names.contains("session_resume"))
    #expect(names.contains("session_end"))
    #expect(names.contains("session_close"))
    #expect(names.contains("session_open"))
    #expect(names.contains("handoff"))
    #expect(names.contains("handoff_latest"))
    #expect(names.contains("compact_context"))
    #expect(names.contains("markdown_export"))
    #expect(names.contains("markdown_sync"))
    #expect(names.contains("task_state_migrate"))
    #expect(names.contains("entity_upsert"))
    #expect(names.contains("fact_assert"))
    #expect(names.contains("fact_retract"))
    #expect(names.contains("facts_query"))
    #expect(names.contains("entity_resolve"))
    #expect(names.count == ToolSchemas.allPublishedTools.count)
}

@Test
func dailyToolNamesAreSubsetOfPublicCatalog() {
    #expect(MCPToolProfile.dailyNameSet.isSubset(of: AgentBrokerCommandSurface.publicCommandNames))
}

@Test
func agentInstructionsDescribeSessionLifecycle() {
    let text = MCPAgentInstructions.text(version: "9.9.9")
    #expect(text.contains("server v9.9.9"))
    #expect(text.contains("session_open"))
    #expect(text.contains("handoff_latest"))
    #expect(text.contains("session_start"))
    #expect(text.contains("session_end"))
    #expect(text.contains("session_id"))
    #expect(text.contains("remaining_active"))
    #expect(text.contains("active_session_count"))
    #expect(text.contains("Do not manage SESSION_STORE"))
    #expect(!text.contains("or call handoff_latest first"))
    #expect(text.contains("Call session_open"))
    for name in MCPToolProfile.dailyNames {
        #expect(text.contains(name), "instructions must name daily tool \(name)")
    }
    #expect(text.contains("memory_type selects the horizon"))
    #expect(text.contains("do not call memory_promote"))
    #expect(!text.contains("session_synthesize then memory_promote"))
    #expect(text.contains("The same agent_id+run_id resumes"))
    #expect(text.contains("exactly one live session"))
    #expect(text.contains("agent_id+resolved project rebinds"))
    #expect(text.contains("durable types must omit session_id"))
    #expect(!text.contains("durable types stay durable even if session_id is present"))
    #expect(text.contains("remember inherits session_id only for task_state, handoff, or scope=session"))
}

@Test
func coreToolDescriptionsIncludeOperatorHints() {
    let tools = Dictionary(
        uniqueKeysWithValues: ToolSchemas.allPublishedTools.map { ($0.name, $0.description ?? "") }
    )
    #expect(tools["handoff_latest"]?.contains("Call first at session start") != true)
    #expect(tools["handoff_latest"]?.localizedCaseInsensitiveContains("latest handoff") == true)
    #expect(tools["session_start"]?.contains("Prefer `session_open`") == true
            || tools["session_start"]?.contains("Prefer session_open") == true)
    #expect(tools["session_open"]?.localizedCaseInsensitiveContains("one-shot") == true
            || tools["session_open"]?.localizedCaseInsensitiveContains("one call") == true)
    #expect(tools["session_open"]?.contains("handoff_latest then") != true)
    #expect(tools["remember"]?.contains("session_id") == true)
    #expect(tools["recall"]?.contains("Preferred read path") == true)
    #expect(tools["recall"]?.contains("session_open") == true)
    #expect(tools["handoff"]?.contains("end-of-session") == true)
}

@Test
func toolsListHonorsStructuredMemoryFlag() {
    let withStructuredMemory = Set(ToolSchemas.tools(structuredMemoryEnabled: true, profile: .full).map(\.name))
    let withoutStructuredMemory = Set(ToolSchemas.tools(structuredMemoryEnabled: false, profile: .full).map(\.name))
    #expect(withStructuredMemory.contains("facts_query"))
    #expect(!withoutStructuredMemory.contains("facts_query"))
    #expect(withStructuredMemory.contains("entity_upsert"))
    #expect(!withoutStructuredMemory.contains("entity_upsert"))
    #expect(!withoutStructuredMemory.contains("fact_assert"))
    #expect(!withoutStructuredMemory.contains("knowledge_capture"))
}

@Test
func toolSchemasStayWithinCommandCatalogSurface() {
    let tools = ToolSchemas.allPublishedTools
    let toolNames = Set(tools.map(\.name))
    #expect(toolNames == AgentBrokerCommandSurface.publicCommandNames)

    for tool in tools {
        guard let entry = AgentBrokerCommandSurface.entry(for: tool.name) else {
            Issue.record("Tool '\(tool.name)' is missing from the command catalog")
            continue
        }
        #expect(entry.exposure == .publicCommand)
        #expect(schemaPropertyNames(tool.inputSchema).isSubset(of: entry.acceptedArgumentKeys))
    }
}

@Test
func toolSchemaRegression() {
    let tools = ToolSchemas.allPublishedTools

    // No duplicate tool names
    let names = tools.map(\.name)
    let uniqueNames = Set(names)
    #expect(uniqueNames.count == names.count, "Duplicate tool names detected")

    // Every tool must have a non-empty name and description
    for tool in tools {
        #expect(!tool.name.isEmpty, "Tool has an empty name")
        #expect(!(tool.description ?? "").isEmpty, "Tool '\(tool.name)' has empty or nil description")
    }

    // Core tools must be present (regression: renaming or removing breaks clients)
    let requiredTools = ["memory_append", "memory_search", "memory_get", "remember", "recall", "search", "session_synthesize", "memory_promote", "promote", "memory_health", "knowledge_capture", "corpus_search", "stats", "session_resume", "compact_context", "markdown_export", "markdown_sync", "task_state_migrate"]
    for required in requiredTools {
        #expect(uniqueNames.contains(required), "Required tool '\(required)' is missing from schema")
    }

    // Tool inputSchemas must be well-formed objects, and tools with required inputs
    // must preserve those requirements in the published schema.
    let schemas: [(name: String, schema: Value, requiresNonEmptyFields: Bool)] = [
        ("memory_append", ToolSchemas.waxMemoryAppend, true),
        ("memory_search", ToolSchemas.waxMemorySearch, true),
        ("memory_get", ToolSchemas.waxMemoryGet, true),
        ("remember", ToolSchemas.waxRemember, true),
        ("recall", ToolSchemas.waxRecall, true),
        ("search", ToolSchemas.waxSearch, true),
        ("session_synthesize", ToolSchemas.waxSessionSynthesize, false),
        ("memory_promote", ToolSchemas.waxMemoryPromote, false),
        ("promote", ToolSchemas.waxPromote, false),
        ("memory_health", ToolSchemas.waxMemoryHealth, false),
        ("knowledge_capture", ToolSchemas.waxKnowledgeCapture, true),
        ("corpus_search", ToolSchemas.waxCorpusSearch, true),
        ("stats", ToolSchemas.waxStats, false),
        ("session_start", ToolSchemas.waxSessionStart, false),
        ("session_resume", ToolSchemas.waxSessionResume, false),
        ("session_end", ToolSchemas.waxSessionEnd, false),
        ("session_close", ToolSchemas.waxSessionClose, true),
        ("session_open", ToolSchemas.waxSessionOpen, false),
        ("handoff", ToolSchemas.waxHandoff, true),
        ("handoff_latest", ToolSchemas.waxHandoffLatest, false),
        ("compact_context", ToolSchemas.waxCompactContext, true),
        ("markdown_export", ToolSchemas.waxMarkdownExport, true),
        ("markdown_sync", ToolSchemas.waxMarkdownSync, true),
        ("task_state_migrate", ToolSchemas.waxTaskStateMigrate, true),
        ("entity_upsert", ToolSchemas.waxEntityUpsert, true),
        ("fact_assert", ToolSchemas.waxFactAssert, true),
        ("fact_retract", ToolSchemas.waxFactRetract, true),
        ("facts_query", ToolSchemas.waxFactsQuery, false),
        ("entity_resolve", ToolSchemas.waxEntityResolve, true),
    ]
    for (toolName, schema, requiresNonEmptyFields) in schemas {
        guard let obj = schema.objectValue else {
            Issue.record("Schema for '\(toolName)' is not an object")
            continue
        }
        if case .string(let typeVal) = obj["type"] {
            #expect(typeVal == "object", "Schema for '\(toolName)' has unexpected type '\(typeVal)'")
        } else {
            Issue.record("Schema for '\(toolName)' is missing 'type' field")
        }
        #expect(obj["properties"] != nil, "Schema for '\(toolName)' is missing 'properties'")
        if case .array(let required) = obj["required"] {
            if requiresNonEmptyFields {
                #expect(!required.isEmpty, "Schema for '\(toolName)' has no required fields")
            }
        } else {
            Issue.record("Schema for '\(toolName)' is missing 'required' array")
        }
    }
}

@Test
func recallSchemaExposesLegacyTopKAlias() {
    guard let obj = ToolSchemas.waxRecall.objectValue,
          case .object(let properties) = obj["properties"]
    else {
        Issue.record("recall schema is missing object properties")
        return
    }

    #expect(properties["search_top_k"] != nil)
    #expect(properties["topK"] != nil)
}

@Test
func schemasExposeVectorSearchMode() {
    let schemas = [
        ToolSchemas.waxRecall,
        ToolSchemas.waxSearch,
        ToolSchemas.waxMemorySearch,
        ToolSchemas.waxCorpusSearch,
        ToolSchemas.waxCompactContext,
    ]

    for schema in schemas {
        #expect(schemaEnum(schema, property: "mode") == ["text", "vector", "hybrid"])
    }
}

@Test
func searchAndRecallSchemasExposeLifecycleAndFrameIDFilters() {
    let requiredFilterProperties = [
        "include_deleted",
        "include_superseded",
        "frame_ids",
    ]

    for schema in [ToolSchemas.waxRecall, ToolSchemas.waxSearch] {
        guard let filterProperties = schemaNestedProperties(schema, property: "filters") else {
            Issue.record("search schema is missing filters properties")
            continue
        }
        for property in requiredFilterProperties {
            #expect(filterProperties[property] != nil, "Missing filters.\(property)")
        }
    }
}

@Test
func factAssertSchemaExposesVersionRelation() {
    #expect(schemaEnum(ToolSchemas.waxFactAssert, property: "relation") == ["sets", "updates", "extends", "retracts"])
}

@Test
func factAssertSchemaExposesEvidence() {
    guard case .object(let root) = ToolSchemas.waxFactAssert,
          case .object(let properties)? = root["properties"],
          case .object(let evidenceSchema)? = properties["evidence"],
          case .object(let itemSchema)? = evidenceSchema["items"],
          case .object(let itemProperties)? = itemSchema["properties"] else {
        Issue.record("fact_assert evidence schema is missing item properties")
        return
    }
    #expect(itemProperties["source_frame_id"] != nil)
    #expect(itemProperties["extractor_id"] != nil)
    #expect(itemProperties["extractor_version"] != nil)
    #expect(itemProperties["asserted_at_ms"] != nil)
}

@Test
func toolsRejectUnknownTopLevelArguments() async throws {
    try await withAgentBrokerService { service, _ in
        let result = await WaxMCPTools.handleCall(
            params: .init(
                name: "recall",
                arguments: [
                    "query": .string("actors"),
                    "limit": .int(3),
                    "unexpected": .string("boom"),
                ]
            ),
            broker: service
        )
        #expect(result.isError == true)
        #expect(firstText(in: result).contains("unsupported argument"))
    }
}

@Test
func brokerRejectsUnknownTopLevelArguments() async throws {
    try await withAgentBrokerService { service, _ in
        let response = await service.handle(
            AgentBrokerRequest(
                command: "recall",
                arguments: [
                    "query": .string("actors"),
                    "limit": .int(3),
                    "unexpected": .string("boom"),
                ]
            )
        )

        #expect(response.ok == false)
        #expect(response.error?.contains("unsupported argument") == true)
        #expect(response.error?.contains("unexpected") == true)
    }
}

@Test
func compatibilityPathRejectsRenamedToolAliases() async throws {
    try await withAgentBrokerService { service, _ in
        let result = await WaxMCPTools.handleCall(
            params: .init(
                name: "wax_remember",
                arguments: ["content": .string("legacy alias should not execute")]
            ),
            broker: service
        )

        #expect(result.isError == true)
        #expect(firstText(in: result).contains("has been renamed to 'remember'"))
        let payload = try parseJSONResource(in: result, uriSuffix: "tool_renamed")
        #expect(payload["code"] as? String == "tool_renamed")
    }
}

@Test
func brokerSearchAppliesLifecycleAndFrameIDFilters() async throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-broker-lifecycle-filters-\(UUID().uuidString)", isDirectory: true)
    let storeURL = rootURL.appendingPathComponent("memory.wax")
    let sessionRootURL = rootURL.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let fixture = try await seedLifecycleFilterFixture(at: storeURL)
    let service = try await AgentBrokerService(
        storePath: storeURL.path,
        sessionRootPath: sessionRootURL.path,
        noEmbedder: true,
        embedderChoice: "auto",
        requireVector: false
    )
    do {
        let baseline = await service.handle(.init(
            command: "search",
            arguments: [
                "query": .string(fixture.query),
                "mode": .string("text"),
                "topK": .int(10),
            ]
        ))
        #expect(baseline.ok == true)
        #expect(resultFrameIDs(from: baseline).contains(fixture.replacementFrameID))
        #expect(!resultFrameIDs(from: baseline).contains(fixture.deletedFrameID))
        #expect(!resultFrameIDs(from: baseline).contains(fixture.supersededFrameID))

        let filtered = await service.handle(.init(
            command: "search",
            arguments: [
                "query": .string(fixture.query),
                "mode": .string("text"),
                "topK": .int(10),
                "filters": .object([
                    "include_deleted": .bool(true),
                    "include_superseded": .bool(true),
                    "frame_ids": .array([
                        .from(fixture.deletedFrameID),
                        .from(fixture.supersededFrameID),
                    ]),
                ]),
            ]
        ))
        #expect(filtered.ok == true)
        #expect(resultFrameIDs(from: filtered) == Set([fixture.deletedFrameID, fixture.supersededFrameID]))
        let applied = try #require(filtered.payload?.objectValue?["applied_filters"]?.objectValue)
        #expect(applied["include_deleted"]?.boolValue == true)
        #expect(applied["include_superseded"]?.boolValue == true)
        #expect(applied["frame_ids"]?.arrayValue?.count == 2)
        try await service.close()
    } catch {
        try? await service.close()
        throw error
    }
}

@Test
func brokerSearchRejectsInvalidFrameIDFilters() async throws {
    try await withAgentBrokerService { service, _ in
        let response = await service.handle(.init(
            command: "search",
            arguments: [
                "query": .string("bad frame id filter"),
                "filters": .object([
                    "frame_ids": .array([.double(9_223_372_036_854_775_808)]),
                ]),
            ]
        ))

        #expect(response.ok == false)
        #expect(response.error?.contains("filters.frame_ids must contain only non-negative integers") == true)
    }
}

@Test
func brokerBackedF152RecallAndSearchSupportFilters() async throws {
    try await withAgentBrokerService { service, _ in
        let seed = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let queryToken = "brokerf152filter\(seed.prefix(8))"
        let blockedMarker = "brokerf152blocked\(seed.suffix(8))"
        let allowedMarker = "brokerf152allowed\(seed.dropFirst(8).prefix(8))"

        let blocked = await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("\(queryToken) \(blockedMarker)"),
                "metadata": .object(["group": .string("blocked")]),
                "durability": .string("durable"),
            ]
        ))
        #expect(blocked.ok == true)

        let allowed = await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("\(queryToken) \(allowedMarker)"),
                "metadata": .object(["group": .string("allowed")]),
                "durability": .string("durable"),
            ]
        ))
        #expect(allowed.ok == true)

        let baselineSearch = await service.handle(.init(
            command: "search",
            arguments: [
                "query": .string(queryToken),
                "mode": .string("text"),
                "topK": .int(10),
            ]
        ))
        #expect(baselineSearch.ok == true)
        let baselinePayload = try #require(baselineSearch.payload?.objectValue)
        let baselineResults = try #require(baselinePayload["results"]?.arrayValue)
        #expect(baselineResults.contains { result in
            guard let object = result.objectValue else { return false }
            return object["preview"]?.stringValue?.contains(blockedMarker) == true
        })

        let filters: AgentBrokerValue = .object([
            "metadata": .object([
                "exact": .object(["group": .string("allowed")]),
            ]),
        ])
        let filteredSearch = await service.handle(.init(
            command: "search",
            arguments: [
                "query": .string(queryToken),
                "mode": .string("text"),
                "topK": .int(10),
                "filters": filters,
            ]
        ))
        #expect(filteredSearch.ok == true)
        let filteredSearchPayload = try #require(filteredSearch.payload?.objectValue)
        let filteredSearchResults = try #require(filteredSearchPayload["results"]?.arrayValue)
        #expect(filteredSearchResults.contains { result in
            guard let object = result.objectValue else { return false }
            return object["preview"]?.stringValue?.contains(allowedMarker) == true
        })
        #expect(!filteredSearchResults.contains { result in
            guard let object = result.objectValue else { return false }
            return object["preview"]?.stringValue?.contains(blockedMarker) == true
        })
        let appliedFilters = try #require(filteredSearchPayload["applied_filters"]?.objectValue)
        let appliedMetadata = try #require(appliedFilters["metadata"]?.objectValue)
        #expect(appliedMetadata["group"]?.stringValue == "allowed")

        let filteredRecall = await service.handle(.init(
            command: "recall",
            arguments: [
                "query": .string(queryToken),
                "mode": .string("text"),
                "limit": .int(10),
                "scope": .string("global"),
                "filters": filters,
            ]
        ))
        #expect(filteredRecall.ok == true)
        let filteredRecallPayload = try #require(filteredRecall.payload?.objectValue)
        let filteredRecallResults = try #require(filteredRecallPayload["results"]?.arrayValue)
        #expect(filteredRecallResults.contains { result in
            guard let object = result.objectValue else { return false }
            return object["text"]?.stringValue?.contains(allowedMarker) == true
        })
        #expect(!filteredRecallResults.contains { result in
            guard let object = result.objectValue else { return false }
            return object["text"]?.stringValue?.contains(blockedMarker) == true
        })
    }
}

@Test
func promotionMaxCandidatesAreBounded() async throws {
    setenv("WAX_OPENCLAW_PROMOTION_MAX_CANDIDATES", "1000000", 1)
    defer { unsetenv("WAX_OPENCLAW_PROMOTION_MAX_CANDIDATES") }

    #expect(BrokerPromotionSettings.fromEnvironment().maxCandidates == 12)
    #expect(schemaMaximum(ToolSchemas.waxSessionSynthesize, property: "max_candidates") == 12)
    #expect(schemaMaximum(ToolSchemas.waxMemoryPromote, property: "max_candidates") == 12)

    try await withAgentBrokerService { service, _ in
        let started = await service.handle(.init(command: "session_start"))
        let startedPayload = try #require(started.payload?.objectValue)
        let sessionIDString = try #require(startedPayload["session_id"]?.stringValue)

        for index in 0..<20 {
            let append = await service.handle(.init(
                command: "memory_append",
                arguments: [
                    "content": .string("Decision: bounded promotion candidate \(index) should stay within the server maximum."),
                    "session_id": .string(sessionIDString),
                ]
            ))
            #expect(append.ok == true)
        }

        let synthesize = await service.handle(
            AgentBrokerRequest(
                command: "session_synthesize",
                arguments: [
                    "session_id": .string(sessionIDString),
                    "max_candidates": .int(1_000_000),
                ]
            )
        )
        #expect(synthesize.ok == true)
        let payload = try #require(synthesize.payload?.objectValue)
        let candidates = try #require(payload["durable_candidates"]?.arrayValue)
        #expect(candidates.count <= 12)
    }
}

@Test
func corpusSearchRejectsUnknownTopLevelArguments() async throws {
    try await withAgentBrokerService { service, _ in
        let result = await WaxMCPTools.handleCall(
            params: .init(
                name: "corpus_search",
                arguments: [
                    "query": .string("actors"),
                    "sessionsDir": .string("/tmp/typo"),
                ]
            ),
            broker: service
        )
        #expect(result.isError == true)
        #expect(firstText(in: result).contains("unsupported argument"))
    }
}

@Test
func factAssertRejectsMixedTypedObjectKeys() async throws {
    try await withAgentBrokerService { service, _ in
        let result = await WaxMCPTools.handleCall(
            params: .init(
                name: "fact_assert",
                arguments: [
                    "subject": .string("project:wax"),
                    "predicate": .string("status"),
                    "object": .object([
                        "entity": .string("project:wax"),
                        "time_ms": .int(123),
                    ]),
                ]
            ),
            broker: service
        )
        #expect(result.isError == true)
        #expect(firstText(in: result).contains("typed object"))
    }
}

@Test
func factAssertAcceptsPublishedGenericTypedObjects() async throws {
    try await withAgentBrokerService { service, _ in
        let encoded = Data("opaque bytes".utf8).base64EncodedString()
        let cases: [(predicate: String, object: Value, expected: String)] = [
            (
                "owner",
                .object(["type": .string("entity"), "value": .string("agent:codex")]),
                #""entity":"agent:codex""#
            ),
            (
                "seen_at",
                .object(["type": .string("time_ms"), "value": .int(123)]),
                #""time_ms":123"#
            ),
            (
                "payload",
                .object(["type": .string("data_base64"), "value": .string(encoded)]),
                #""data_base64":"\#(encoded)""#
            ),
        ]

        for testCase in cases {
            let result = await WaxMCPTools.handleCall(
                params: .init(
                    name: "fact_assert",
                    arguments: [
                        "subject": .string("project:wax"),
                        "predicate": .string(testCase.predicate),
                        "object": testCase.object,
                    ]
                ),
                broker: service
            )
            #expect(result.isError != true)

            let query = await WaxMCPTools.handleCall(
                params: .init(
                    name: "facts_query",
                    arguments: [
                        "subject": .string("project:wax"),
                        "predicate": .string(testCase.predicate),
                    ]
                ),
                broker: service
            )
            #expect(query.isError != true)
            #expect(firstText(in: query).contains(testCase.expected))
        }
    }
}

@Test
func factAssertAcceptsEvidence() async throws {
    try await withAgentBrokerService { service, _ in
        let asserted = await WaxMCPTools.handleCall(
            params: .init(
                name: "fact_assert",
                arguments: [
                    "subject": .string("project:wax"),
                    "predicate": .string("status"),
                    "object": .string("evidence-backed"),
                    "evidence": .array([
                        .object([
                            "source_frame_id": .int(42),
                            "chunk_index": .int(3),
                            "span_start_utf8": .int(1),
                            "span_end_utf8": .int(7),
                            "extractor_id": .string("mcp-test"),
                            "extractor_version": .string("1"),
                            "confidence": .double(0.75),
                            "asserted_at_ms": .int(123_456),
                        ]),
                    ]),
                ]
            ),
            broker: service
        )
        #expect(asserted.isError != true)

        let queried = await WaxMCPTools.handleCall(
            params: .init(
                name: "facts_query",
                arguments: [
                    "subject": .string("project:wax"),
                    "predicate": .string("status"),
                ]
            ),
            broker: service
        )
        #expect(queried.isError != true)
        let payload = try parseJSONText(in: queried)
        let hits = try #require(payload["hits"] as? [[String: Any]])
        let first = try #require(hits.first)
        #expect(first["evidence_count"] as? Int == 1)
        let evidence = try #require(first["evidence"] as? [[String: Any]])
        #expect(evidence.first?["source_frame_id"] as? Int == 42)
        #expect(evidence.first?["extractor_id"] as? String == "mcp-test")
    }
}

@Test
func factAssertRejectsUnknownEvidenceFields() async throws {
    try await withAgentBrokerService { service, _ in
        let asserted = await WaxMCPTools.handleCall(
            params: .init(
                name: "fact_assert",
                arguments: [
                    "subject": .string("project:wax"),
                    "predicate": .string("status"),
                    "object": .string("evidence-backed"),
                    "evidence": .array([
                        .object([
                            "source_frame_id": .int(42),
                            "extractor_id": .string("mcp-test"),
                            "extractor_version": .string("1"),
                            "asserted_at_ms": .int(123_456),
                            "unsupported": .string("dropped"),
                        ]),
                    ]),
                ]
            ),
            broker: service
        )
        #expect(asserted.isError == true)
    }
}

@Test
func brokerFactAssertAcceptsPublishedGenericTypedObjects() async throws {
    try await withAgentBrokerService { service, _ in
        let encoded = Data("opaque bytes".utf8).base64EncodedString()
        let cases: [(predicate: String, object: AgentBrokerValue, expectedKey: String, expectedValue: AgentBrokerValue)] = [
            (
                "owner",
                .object(["type": .string("entity"), "value": .string("agent:codex")]),
                "entity",
                .string("agent:codex")
            ),
            (
                "seen_at",
                .object(["type": .string("time_ms"), "value": .int(123)]),
                "time_ms",
                .int(123)
            ),
            (
                "payload",
                .object(["type": .string("data_base64"), "value": .string(encoded)]),
                "data_base64",
                .string(encoded)
            ),
        ]

        for testCase in cases {
            let asserted = await service.handle(.init(
                command: "fact_assert",
                arguments: [
                    "subject": .string("project:wax"),
                    "predicate": .string(testCase.predicate),
                    "object": testCase.object,
                ]
            ))
            #expect(asserted.ok == true)

            let queried = await service.handle(.init(
                command: "facts_query",
                arguments: [
                    "subject": .string("project:wax"),
                    "predicate": .string(testCase.predicate),
                ]
            ))
            #expect(queried.ok == true)
            let payload = try #require(queried.payload?.objectValue)
            let facts = try #require(payload["hits"]?.arrayValue)
            let firstFact = try #require(facts.first?.objectValue)
            #expect(firstFact["object"]?.objectValue?[testCase.expectedKey] == testCase.expectedValue)
        }
    }
}

@Test
func brokerFactAssertAcceptsEvidence() async throws {
    try await withAgentBrokerService { service, _ in
        let asserted = await service.handle(.init(
            command: "fact_assert",
            arguments: [
                "subject": .string("project:wax"),
                "predicate": .string("status"),
                "object": .string("evidence-backed"),
                "evidence": .array([
                    .object([
                        "source_frame_id": .int(42),
                        "chunk_index": .int(3),
                        "span_start_utf8": .int(1),
                        "span_end_utf8": .int(7),
                        "extractor_id": .string("broker-test"),
                        "extractor_version": .string("1"),
                        "confidence": .double(0.75),
                        "asserted_at_ms": .int(123_456),
                    ]),
                ]),
            ]
        ))
        #expect(asserted.ok == true)

        let queried = await service.handle(.init(
            command: "facts_query",
            arguments: [
                "subject": .string("project:wax"),
                "predicate": .string("status"),
            ]
        ))
        #expect(queried.ok == true)
        let payload = try #require(queried.payload?.objectValue)
        let hits = try #require(payload["hits"]?.arrayValue)
        let first = try #require(hits.first?.objectValue)
        #expect(first["evidence_count"]?.intValue == 1)
        let evidence = try #require(first["evidence"]?.arrayValue)
        let firstEvidence = try #require(evidence.first?.objectValue)
        #expect(firstEvidence["source_frame_id"]?.intValue == 42)
        #expect(firstEvidence["extractor_id"]?.stringValue == "broker-test")
    }
}

@Test
func brokerFactsQuerySupportsSeparateSystemAndValidTime() async throws {
    try await withAgentBrokerService { service, _ in
        let asserted = await service.handle(.init(
            command: "fact_assert",
            arguments: [
                "subject": .string("project:f026"),
                "predicate": .string("status"),
                "object": .string("historical"),
                "valid_from": .int(100),
                "valid_to": .int(200),
            ]
        ))
        #expect(asserted.ok == true)

        let collapsed = await service.handle(.init(
            command: "facts_query",
            arguments: [
                "subject": .string("project:f026"),
                "predicate": .string("status"),
                "as_of": .int(150),
            ]
        ))
        #expect(collapsed.ok == true)
        let collapsedPayload = try #require(collapsed.payload?.objectValue)
        #expect(collapsedPayload["count"]?.intValue == 0)

        let dualAxis = await service.handle(.init(
            command: "facts_query",
            arguments: [
                "subject": .string("project:f026"),
                "predicate": .string("status"),
                "valid_as_of": .int(150),
                "system_as_of": .int(Int64.max),
            ]
        ))
        #expect(dualAxis.ok == true)
        let dualAxisPayload = try #require(dualAxis.payload?.objectValue)
        #expect(dualAxisPayload["count"]?.intValue == 1)
        #expect(dualAxisPayload["valid_as_of"]?.intValue == 150)
        #expect(dualAxisPayload["system_as_of"]?.intValue == Int64.max)
    }
}

@Test
func brokerFactsQueryRejectsRoundedOutOfRangeTimestampDoubles() async throws {
    try await withAgentBrokerService { service, _ in
        let result = await service.handle(.init(
            command: "facts_query",
            arguments: [
                "subject": .string("project:f026"),
                "valid_as_of": .double(Double(Int64.max)),
            ]
        ))
        #expect(result.ok == false)
        #expect(result.error?.contains("valid_as_of is out of range") == true)
    }
}

@Test
func brokerFactAssertRejectsUnknownEvidenceFields() async throws {
    try await withAgentBrokerService { service, _ in
        let asserted = await service.handle(.init(
            command: "fact_assert",
            arguments: [
                "subject": .string("project:wax"),
                "predicate": .string("status"),
                "object": .string("evidence-backed"),
                "evidence": .array([
                    .object([
                        "source_frame_id": .int(42),
                        "extractor_id": .string("broker-test"),
                        "extractor_version": .string("1"),
                        "asserted_at_ms": .int(123_456),
                        "unsupported": .string("dropped"),
                    ]),
                ]),
            ]
        ))
        #expect(asserted.ok == false)
    }
}

@Test
func mcpFactsQuerySupportsSeparateSystemAndValidTime() async throws {
    try await withAgentBrokerService { service, _ in
        let asserted = await WaxMCPTools.handleCall(
            params: .init(
                name: "fact_assert",
                arguments: [
                    "subject": .string("project:f026-mcp"),
                    "predicate": .string("status"),
                    "object": .string("historical"),
                    "valid_from": .int(100),
                    "valid_to": .int(200),
                ]
            ),
            broker: service
        )
        #expect(asserted.isError != true)

        let collapsed = await WaxMCPTools.handleCall(
            params: .init(
                name: "facts_query",
                arguments: [
                    "subject": .string("project:f026-mcp"),
                    "predicate": .string("status"),
                    "as_of": .int(150),
                ]
            ),
            broker: service
        )
        #expect(collapsed.isError != true)
        let collapsedJSON = try parseJSONText(in: collapsed)
        #expect(collapsedJSON["count"] as? Int == 0)

        let dualAxis = await WaxMCPTools.handleCall(
            params: .init(
                name: "facts_query",
                arguments: [
                    "subject": .string("project:f026-mcp"),
                    "predicate": .string("status"),
                    "valid_as_of": .int(150),
                    "system_as_of": .int(Int(Int64.max)),
                ]
            ),
            broker: service
        )
        #expect(dualAxis.isError != true)
        let dualAxisJSON = try parseJSONText(in: dualAxis)
        #expect(dualAxisJSON["count"] as? Int == 1)
        #expect(dualAxisJSON["valid_as_of"] as? Int == 150)
        #expect((dualAxisJSON["system_as_of"] as? NSNumber)?.int64Value == Int64.max)
        #expect(firstText(in: dualAxis).contains("historical"))
    }
}

@Test
func mcpFactsQueryRejectsRoundedOutOfRangeTimestampDoubles() async throws {
    try await withAgentBrokerService { service, _ in
        let result = await WaxMCPTools.handleCall(
            params: .init(
                name: "facts_query",
                arguments: [
                    "subject": .string("project:f026"),
                    "valid_as_of": .double(Double(Int64.max)),
                ]
            ),
            broker: service
        )
        #expect(result.isError == true)
        #expect(firstText(in: result).contains("valid_as_of is out of range"))
    }
}

@Test
func temporalFactArgumentsAreHonoredByPublishedTools() async throws {
    try await withAgentBrokerService { service, _ in
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let asserted = await WaxMCPTools.handleCall(
            params: .init(
                name: "fact_assert",
                arguments: [
                    "subject": .string("project:wax"),
                    "predicate": .string("status"),
                    "object": .string("temporal"),
                    "valid_from": .int(Int(nowMs)),
                    "valid_to": .int(Int(nowMs + 100)),
                ]
            ),
            broker: service
        )
        #expect(asserted.isError != true)

        let insideValidWindow = await WaxMCPTools.handleCall(
            params: .init(
                name: "facts_query",
                arguments: [
                    "subject": .string("project:wax"),
                    "predicate": .string("status"),
                    "as_of": .int(Int(nowMs + 50)),
                ]
            ),
            broker: service
        )
        #expect(insideValidWindow.isError != true)
        #expect(firstText(in: insideValidWindow).contains("temporal"))

        let outsideValidWindow = await WaxMCPTools.handleCall(
            params: .init(
                name: "facts_query",
                arguments: [
                    "subject": .string("project:wax"),
                    "predicate": .string("status"),
                    "as_of": .int(Int(nowMs + 150)),
                ]
            ),
            broker: service
        )
        #expect(outsideValidWindow.isError != true)
        #expect(!firstText(in: outsideValidWindow).contains("temporal"))

        let historicalValidCurrentSystem = await WaxMCPTools.handleCall(
            params: .init(
                name: "facts_query",
                arguments: [
                    "subject": .string("project:wax"),
                    "predicate": .string("status"),
                    "valid_as_of": .int(Int(nowMs + 50)),
                    "system_as_of": .int(Int(Int64.max)),
                ]
            ),
            broker: service
        )
        #expect(historicalValidCurrentSystem.isError != true)
        #expect(firstText(in: historicalValidCurrentSystem).contains("temporal"))

        // Capture a fresh clock after earlier tool calls. A stale `nowMs` from
        // the start of this test can land `at_ms` before system_from under
        // parallel CI load.
        let retractableFromMs = Int64(Date().timeIntervalSince1970 * 1000)
        let retractable = await WaxMCPTools.handleCall(
            params: .init(
                name: "fact_assert",
                arguments: [
                    "subject": .string("project:wax"),
                    "predicate": .string("retractable"),
                    "object": .string("temporal retraction"),
                    "valid_from": .int(Int(retractableFromMs)),
                ]
            ),
            broker: service
        )
        #expect(retractable.isError != true)
        let retractableJSON = try parseJSONText(in: retractable)
        let factID = try requireInt(retractableJSON, key: "fact_id")

        let retractAtMs = retractableFromMs + 2_000
        let retract = await WaxMCPTools.handleCall(
            params: .init(
                name: "fact_retract",
                arguments: [
                    "fact_id": .int(factID),
                    "at_ms": .int(Int(retractAtMs)),
                ]
            ),
            broker: service
        )
        #expect(retract.isError != true)

        let beforeRetractionTime = await WaxMCPTools.handleCall(
            params: .init(
                name: "facts_query",
                arguments: [
                    "subject": .string("project:wax"),
                    "predicate": .string("retractable"),
                    "as_of": .int(Int(retractableFromMs + 1_000)),
                ]
            ),
            broker: service
        )
        #expect(beforeRetractionTime.isError != true)
        #expect(firstText(in: beforeRetractionTime).contains("temporal retraction"))

        let afterRetractionTime = await WaxMCPTools.handleCall(
            params: .init(
                name: "facts_query",
                arguments: [
                    "subject": .string("project:wax"),
                    "predicate": .string("retractable"),
                    "as_of": .int(Int(retractAtMs + 1_000)),
                ]
            ),
            broker: service
        )
        #expect(afterRetractionTime.isError != true)
        #expect(!firstText(in: afterRetractionTime).contains("temporal retraction"))
    }
}

@Test
func httpRequestBodyLimitRejectsContentLengthAndStreamingOverflow() {
    #expect(HTTPRequestBodyLimit.exceedsLimit(
        currentBytes: 0,
        incomingBytes: 0,
        contentLength: 1_049,
        maxBytes: 1_048
    ))
    #expect(HTTPRequestBodyLimit.exceedsLimit(
        currentBytes: 1_000,
        incomingBytes: 49,
        contentLength: nil,
        maxBytes: 1_048
    ))
    #expect(!HTTPRequestBodyLimit.exceedsLimit(
        currentBytes: 1_000,
        incomingBytes: 48,
        contentLength: nil,
        maxBytes: 1_048
    ))
}

@Test
func httpHandlerRejectsOversizedContentLengthBeforeReadingBody() async throws {
    let app = MCPHTTPApplication(
        configuration: .init(maxRequestBodyBytes: 10),
        serverFactory: { _, _ in
            Issue.record("oversized request should not reach MCP server creation")
            throw MCP.MCPError.invalidRequest("unexpected server creation")
        }
    )
    let channel = EmbeddedChannel(handler: HTTPHandler(app: app))
    var headers = HTTPHeaders()
    headers.add(name: "content-length", value: "11")
    let head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp", headers: headers)

    try channel.writeInbound(HTTPServerRequestPart.head(head))
    try expectImmediatePayloadTooLargeResponse(on: channel)
    let trailingResponsePart = try channel.readOutbound(as: HTTPServerResponsePart.self)
    #expect(trailingResponsePart == nil)
    _ = try channel.finish()
}

@Test
func httpHandlerReturns404AfterRequestEndForUnknownPath() async throws {
    let app = MCPHTTPApplication(
        configuration: .init(maxRequestBodyBytes: 1_048),
        serverFactory: { _, _ in
            Issue.record("unknown path should not reach MCP server creation")
            throw MCP.MCPError.invalidRequest("unexpected server creation")
        }
    )
    let channel = await NIOAsyncTestingChannel(handler: HTTPHandler(app: app))
    let head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/not-mcp")

    try await channel.writeInbound(HTTPServerRequestPart.head(head))
    try await channel.writeInbound(HTTPServerRequestPart.end(nil))

    let responseHeadPart = try await channel.waitForOutboundWrite(as: HTTPServerResponsePart.self)
    guard case .head(let response) = responseHeadPart else {
        Issue.record("expected response head, got \(responseHeadPart)")
        return
    }
    #expect(response.status == HTTPResponseStatus(statusCode: 404))
    _ = try await channel.finish()
}

@Test
func httpHandlerRejectsStreamingOverflowBeforeRequestEnd() async throws {
    let app = MCPHTTPApplication(
        configuration: .init(maxRequestBodyBytes: 10),
        serverFactory: { _, _ in
            Issue.record("oversized request should not reach MCP server creation")
            throw MCP.MCPError.invalidRequest("unexpected server creation")
        }
    )
    let channel = EmbeddedChannel(handler: HTTPHandler(app: app))
    let head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/mcp")
    var body = channel.allocator.buffer(capacity: 11)
    body.writeString("01234567890")

    try channel.writeInbound(HTTPServerRequestPart.head(head))
    try channel.writeInbound(HTTPServerRequestPart.body(body))
    try expectImmediatePayloadTooLargeResponse(on: channel)
    let trailingResponsePart = try channel.readOutbound(as: HTTPServerResponsePart.self)
    #expect(trailingResponsePart == nil)
    _ = try channel.finish()
}

private func expectImmediatePayloadTooLargeResponse(on channel: EmbeddedChannel) throws {
    let responseHeadPart = try channel.readOutbound(as: HTTPServerResponsePart.self)
    let responseHead = try #require(responseHeadPart)
    guard case .head(let head) = responseHead else {
        Issue.record("expected response head, got \(responseHead)")
        return
    }
    #expect(head.status == HTTPResponseStatus(statusCode: 413))

    let nextResponsePartValue = try channel.readOutbound(as: HTTPServerResponsePart.self)
    let nextResponsePart = try #require(nextResponsePartValue)
    let responseEnd: HTTPServerResponsePart
    if case .body = nextResponsePart {
        let endPartValue = try channel.readOutbound(as: HTTPServerResponsePart.self)
        responseEnd = try #require(endPartValue)
    } else {
        responseEnd = nextResponsePart
    }
    guard case .end = responseEnd else {
        Issue.record("expected response end, got \(responseEnd)")
        return
    }
}

@Test
func httpAuthPolicyRequiresTokenOffLoopbackOnly() {
    #expect(!HTTPAuthPolicy.requiresAuthentication(host: "127.0.0.1"))
    #expect(!HTTPAuthPolicy.requiresAuthentication(host: "localhost"))
    #expect(!HTTPAuthPolicy.requiresAuthentication(host: "::1"))
    #expect(HTTPAuthPolicy.requiresAuthentication(host: "0.0.0.0"))
    #expect(HTTPAuthPolicy.requiresAuthentication(host: "::"))
    #expect(HTTPAuthPolicy.requiresAuthentication(host: "192.168.1.10"))
}

@Test
func httpAuthPolicyValidatesBearerToken() {
    let token = "test-http-token"
    #expect(HTTPAuthPolicy.isAuthorized(requestToken: "Bearer \(token)", configuredToken: token))
    #expect(HTTPAuthPolicy.isAuthorized(requestToken: "  Bearer \(token)  ", configuredToken: token))
    #expect(!HTTPAuthPolicy.isAuthorized(requestToken: nil, configuredToken: token))
    #expect(!HTTPAuthPolicy.isAuthorized(requestToken: "Bearer wrong", configuredToken: token))
    #expect(!HTTPAuthPolicy.isAuthorized(requestToken: token, configuredToken: token))
}

@Test
func httpApplicationRejectsUnauthorizedOffLoopbackRequests() async throws {
    let app = MCPHTTPApplication(
        configuration: .init(host: "0.0.0.0", authToken: "secret-token"),
        serverFactory: { _, _ in
            Issue.record("unauthorized request should not create an MCP server")
            throw MCP.MCPError.invalidRequest("unexpected server creation")
        }
    )
    let body = try JSONSerialization.data(withJSONObject: [
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": [:],
    ])

    let response = await app.handleHTTPRequest(HTTPRequest(
        method: "POST",
        headers: ["Content-Type": "application/json"],
        body: body,
        path: "/mcp"
    ))

    #expect(response.statusCode == 401)
    #expect(response.headers["WWW-Authenticate"] == "Bearer")
}

@Test
func httpInitializeReusesClientSessionIDWhenUnknown() async throws {
    let preferredID = "cursor-stale-session-reuse-001"
    let app = MCPHTTPApplication(
        serverFactory: { _, _ in
            Server(
                name: "wax-mcp-test",
                version: "0.0.0",
                capabilities: .init(tools: .init(listChanged: false))
            )
        }
    )
    let body = try JSONSerialization.data(withJSONObject: [
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": [
            "protocolVersion": "2024-11-05",
            "capabilities": [:] as [String: Any],
            "clientInfo": ["name": "cursor-probe", "version": "0"],
        ],
    ])

    let response = await app.handleHTTPRequest(HTTPRequest(
        method: "POST",
        headers: [
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
            HTTPHeaderName.sessionID: preferredID,
        ],
        body: body,
        path: "/mcp"
    ))

    #expect(response.statusCode == 200)
    #expect(response.headers[HTTPHeaderName.sessionID] == preferredID)
}

@Test
func httpRecoversUnknownSessionForToolsListWithoutClientReinit() async throws {
    let staleID = "cursor-stale-session-tools-002"
    let app = MCPHTTPApplication(
        serverFactory: { _, _ in
            Server(
                name: "wax-mcp-test",
                version: "0.0.0",
                capabilities: .init(tools: .init(listChanged: false))
            )
        }
    )
    let body = try JSONSerialization.data(withJSONObject: [
        "jsonrpc": "2.0",
        "id": 2,
        "method": "tools/list",
        "params": [:] as [String: Any],
    ])

    let response = await app.handleHTTPRequest(HTTPRequest(
        method: "POST",
        headers: [
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
            HTTPHeaderName.sessionID: staleID,
        ],
        body: body,
        path: "/mcp"
    ))

    #expect(response.statusCode == 200)
    #expect(response.headers[HTTPHeaderName.sessionID] == staleID)
    // Second call should hit the live map, not recover again.
    let again = await app.handleHTTPRequest(HTTPRequest(
        method: "POST",
        headers: [
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
            HTTPHeaderName.sessionID: staleID,
        ],
        body: body,
        path: "/mcp"
    ))
    #expect(again.statusCode == 200)
    #expect(again.headers[HTTPHeaderName.sessionID] == staleID)
}

@Test
func httpMissingSessionHeaderOnNonInitializeStillFails() async throws {
    let app = MCPHTTPApplication(
        serverFactory: { _, _ in
            Issue.record("missing session header should not create a server")
            throw MCP.MCPError.invalidRequest("unexpected server creation")
        }
    )
    let body = try JSONSerialization.data(withJSONObject: [
        "jsonrpc": "2.0",
        "id": 3,
        "method": "tools/list",
        "params": [:] as [String: Any],
    ])
    let response = await app.handleHTTPRequest(HTTPRequest(
        method: "POST",
        headers: [
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        ],
        body: body,
        path: "/mcp"
    ))
    #expect(response.statusCode == 400)
}

@Test
func httpSessionCleanupTaskStopsWithApplicationStop() async throws {
    let app = MCPHTTPApplication(
        configuration: .init(port: 0, sessionCleanupInterval: .milliseconds(10)),
        serverFactory: { _, _ in
            Issue.record("cleanup lifecycle test should not create an MCP server")
            throw MCP.MCPError.invalidRequest("unexpected server creation")
        }
    )

    let startTask = Task { try await app.start() }
    while !(await app.hasActiveSessionCleanupTask()) {
        try await Task.sleep(for: .milliseconds(1))
    }
    #expect(await app.hasActiveSessionCleanupTask())
    await app.stop()
    try await startTask.value
    #expect(!(await app.hasActiveSessionCleanupTask()))
}

@Test
func openClawPackageDeclaresSDKPeerDependency() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let packageJSONURL = packageRoot
        .appendingPathComponent("Resources/openclaw/wax-memory-plugin/package.json")
    let data = try Data(contentsOf: packageJSONURL)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let peerDependencies = try #require(json["peerDependencies"] as? [String: Any])
    let devDependencies = try #require(json["devDependencies"] as? [String: Any])

    #expect(peerDependencies["openclaw"] as? String == ">=2026.3.24-beta.2")
    #expect(devDependencies["openclaw"] as? String == ">=2026.3.24-beta.2")
}


@Test
func handleCallRoutesSessionLifecycleThroughBroker() async throws {
    try await withAgentBrokerService { service, _ in
        let start = await WaxMCPTools.handleCall(
            params: .init(name: "session_start", arguments: [:]),
            broker: service
        )
        #expect(start.isError != true)
        let startJSON = try parseJSONText(in: start)
        let sessionID = try #require(startJSON["session_id"] as? String)

        let remember = await WaxMCPTools.handleCall(
            params: .init(
                name: "remember",
                arguments: [
                    "content": "session_id routes through handle",
                    "session_id": .string(sessionID),
                ]
            ),
            broker: service
        )
        #expect(remember.isError != true)
    }
}

@Test
func toolsRememberRecallSearchFlushStatsHappyPath() async throws {
    try await withAgentBrokerService { service, _ in
        let rememberResult = await WaxMCPTools.handleCall(
            params: .init(
                name: "remember",
                arguments: [
                    "content": "Swift actors isolate mutable state.",
                    "metadata": ["source": "test-suite", "rank": 1],
                ]
            ),
            broker: service
        )
        #expect(rememberResult.isError != true)

        let recallResult = await WaxMCPTools.handleCall(
            params: .init(name: "recall", arguments: ["query": "actors", "limit": 3, "scope": "global"]),
            broker: service
        )
        #expect(recallResult.isError != true)
        let recallJSON = try parseJSONText(in: recallResult)
        #expect((recallJSON["query"] as? String) == "actors")
        #expect((recallJSON["result_count"] as? Int) == 1)

        let searchResult = await WaxMCPTools.handleCall(
            params: .init(
                name: "search",
                arguments: ["query": "actors", "mode": "text", "topK": 5]
            ),
            broker: service
        )
        #expect(searchResult.isError != true)
        #expect(!firstText(in: searchResult).isEmpty)

        let statsResult = await WaxMCPTools.handleCall(
            params: .init(name: "stats", arguments: [:]),
            broker: service
        )
        #expect(statsResult.isError != true)
        #expect(firstText(in: statsResult).contains("\"frameCount\""))
    }
}


@Test
func corpusSearchBuildsAcrossSessionStoresAndReturnsProvenance() async throws {
    try await withTemporaryDirectory { root in
        let sessionsDir = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        let sourceA = sessionsDir.appendingPathComponent("session-a.wax")
        let sourceB = sessionsDir.appendingPathComponent("session-b.wax")
        let corpus = root.appendingPathComponent("corpus.wax")

        try await writeSessionStore(
            at: sourceA,
            documents: [("Apollo guidance session with thruster calibration notes.", ["session_id": "session-a"])]
        )
        try await writeSessionStore(
            at: sourceB,
            documents: [("Zephyr retrieval session covering lunar habitat logistics.", ["session_id": "session-b"])]
        )

        let build = try await CorpusStoreBuilder.build(
            sessionsDirectory: sessionsDir,
            targetStoreURL: corpus,
            noEmbedder: true,
            embedderChoice: "minilm",
            recursive: true
        )
        #expect(build.storesDiscovered == 2)
        #expect(build.storesSkipped == 0)
        #expect(build.documentsIndexed == 2)

        let execution = try await MCPMemoryFactory.withOpenMemory(
            at: corpus,
            noEmbedder: true,
            embedderChoice: "minilm",
            structuredMemoryEnabled: false
        ) { memory in
            try await memory.searchExecution(
                query: "thruster calibration",
                mode: .textOnly,
                topK: 5,
                frameFilter: nil,
                timeRange: nil
            )
        }

        #expect(!execution.hits.isEmpty)
        let preview = execution.hits.first?.previewText ?? ""
        #expect(preview.contains("thruster"))
        #expect(preview.contains("calibration"))
        let metadata = execution.hits.first?.metadata ?? [:]
        #expect(metadata[CorpusMetadataKeys.sourceStorePath] == sourceA.path)
        #expect(metadata[CorpusMetadataKeys.sourceStoreName] == "session-a.wax")
        #expect(metadata["session_id"] == "session-a")
    }
}

@Test
func brokerCorpusSearchBuildSkipsLockedSessionStore() async throws {
    try await withTemporaryDirectory { root in
        let sessionsDir = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        let sourceA = sessionsDir.appendingPathComponent("session-a.wax")
        let sourceB = sessionsDir.appendingPathComponent("session-b.wax")
        let corpus = root.appendingPathComponent("corpus.wax")

        try await writeSessionStore(
            at: sourceA,
            documents: [("Unlocked session note about mission telemetry.", ["session_id": "session-a"])]
        )
        try await writeSessionStore(
            at: sourceB,
            documents: [("Locked session note about fallback navigation.", ["session_id": "session-b"])]
        )

        let lockedMemory = try await openTextOnlyMemory(at: sourceB, structuredMemoryEnabled: false)
        defer { Task { try? await lockedMemory.close() } }

        let build = try await BrokerCorpusStoreBuilder.build(
            sessionsDirectory: sessionsDir,
            targetStoreURL: corpus,
            noEmbedder: true,
            embedderChoice: "minilm",
            recursive: true
        )
        #expect(build.storesDiscovered == 2)
        #expect(build.storesIndexed == 1)
        #expect(build.storesSkipped == 1)
        #expect(build.documentsIndexed == 1)

        let execution = try await MCPMemoryFactory.withOpenMemory(
            at: corpus,
            noEmbedder: true,
            embedderChoice: "minilm",
            structuredMemoryEnabled: false
        ) { memory in
            try await memory.searchExecution(
                query: "mission telemetry",
                mode: .textOnly,
                topK: 5,
                frameFilter: nil,
                timeRange: nil
            )
        }

        #expect(!execution.hits.isEmpty)
        #expect(execution.hits.contains { ($0.previewText ?? "").contains("telemetry") })
        #expect(!execution.hits.contains { ($0.previewText ?? "").contains("navigation") })
    }
}

@Test
func corpusSearchIncludesActiveSessionDocumentsWhileStoreIsLockedByBroker() async throws {
    // Active session stores hold an exclusive flock, so disk rebuild skips them.
    // corpus_search must still surface in-process active session notes.
    try await withAgentBrokerService { service, _ in
        let token = "ACTIVECORPUS\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))"
        let started = await service.handle(.init(command: "session_start"))
        #expect(started.ok == true)
        let sessionID = try #require(started.payload?.objectValue?["session_id"]?.stringValue)

        let remembered = await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("Session-only preference note \(token)"),
                "session_id": .string(sessionID),
            ]
        ))
        #expect(remembered.ok == true)

        let corpus = await service.handle(.init(
            command: "corpus_search",
            arguments: [
                "query": .string(String(token)),
                "mode": .string("text"),
                "topK": .int(5),
                "rebuild": .bool(true),
            ]
        ))
        #expect(corpus.ok == true, "corpus_search failed: \(corpus.error ?? "nil")")
        let payload = try #require(corpus.payload?.objectValue)
        let results = payload["results"]?.arrayValue ?? []
        #expect(!results.isEmpty, "expected active-session hit for \(token); display=\(payload["display_text"]?.stringValue ?? "")")
        let previews = results.compactMap { $0.objectValue?["preview"]?.stringValue }
        #expect(previews.contains { $0.contains(token) })

        let synthesize = await service.handle(.init(
            command: "session_synthesize",
            arguments: ["session_id": .string(sessionID)]
        ))
        #expect(synthesize.ok == true)
        let summary = try #require(synthesize.payload?.objectValue?["summary"]?.stringValue)
        #expect(summary != "No session memories recorded.")
        #expect(summary.contains(token) || summary.localizedCaseInsensitiveContains("preference") || summary.localizedCaseInsensitiveContains("session"))
    }
}

@Test
func corpusSearchBuildReusesExistingCorpusWhenSourcesUnchanged() async throws {
    try await withTemporaryDirectory { root in
        let sessionsDir = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        let source = sessionsDir.appendingPathComponent("session-a.wax")
        let corpus = root.appendingPathComponent("corpus.wax")

        try await writeSessionStore(
            at: source,
            documents: [("Manifest reuse session covering thruster telemetry.", ["session_id": "session-a"])]
        )

        let firstBuild = try await CorpusStoreBuilder.build(
            sessionsDirectory: sessionsDir,
            targetStoreURL: corpus,
            noEmbedder: true,
            embedderChoice: "minilm",
            recursive: true
        )
        #expect(firstBuild.documentsIndexed == 1)

        let targetValuesBefore = try corpus.resourceValues(forKeys: [.contentModificationDateKey])
        let manifestURL = CorpusBuildManifestStore.manifestURL(for: corpus)
        #expect(FileManager.default.fileExists(atPath: manifestURL.path))

        let secondBuild = try await CorpusStoreBuilder.build(
            sessionsDirectory: sessionsDir,
            targetStoreURL: corpus,
            noEmbedder: true,
            embedderChoice: "minilm",
            recursive: true
        )
        #expect(secondBuild.storesDiscovered == 1)
        #expect(secondBuild.storesIndexed == 0)
        #expect(secondBuild.documentsIndexed == 0)

        let targetValuesAfter = try corpus.resourceValues(forKeys: [.contentModificationDateKey])
        #expect(targetValuesAfter.contentModificationDate == targetValuesBefore.contentModificationDate)
    }
}

@Test
func brokerCorpusSearchRebuildsWhenSourceFingerprintChanges() async throws {
    try await withTemporaryDirectory { root in
        let sessionsDir = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        let source = sessionsDir.appendingPathComponent("session-a.wax")
        let corpus = root.appendingPathComponent("corpus.wax")

        try await writeSessionStore(
            at: source,
            documents: [("First corpus rebuild note about early telemetry.", ["session_id": "session-a"])]
        )

        _ = try await BrokerCorpusStoreBuilder.build(
            sessionsDirectory: sessionsDir,
            targetStoreURL: corpus,
            noEmbedder: true,
            embedderChoice: "minilm",
            recursive: true
        )

        try FileManager.default.removeItem(at: source)
        try await writeSessionStore(
            at: source,
            documents: [("Updated corpus rebuild note with navigation lock.", ["session_id": "session-a"])]
        )

        let rebuild = try await BrokerCorpusStoreBuilder.build(
            sessionsDirectory: sessionsDir,
            targetStoreURL: corpus,
            noEmbedder: true,
            embedderChoice: "minilm",
            recursive: true
        )
        #expect(rebuild.storesDiscovered == 1)
        #expect(rebuild.storesIndexed == 1)
        #expect(rebuild.documentsIndexed == 1)

        let execution = try await MCPMemoryFactory.withOpenMemory(
            at: corpus,
            noEmbedder: true,
            embedderChoice: "minilm",
            structuredMemoryEnabled: false
        ) { memory in
            try await memory.searchExecution(
                query: "navigation lock",
                mode: .textOnly,
                topK: 5,
                frameFilter: nil,
                timeRange: nil
            )
        }

        #expect(!execution.hits.isEmpty)
        #expect(execution.hits.contains { ($0.previewText ?? "").contains("navigation") })
    }
}

@Test
func brokerCorpusSearchRebuildsWhenCorpusManifestIsCorrupt() async throws {
    try await withTemporaryDirectory { root in
        let sessionsDir = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        let source = sessionsDir.appendingPathComponent("session-a.wax")
        let corpus = root.appendingPathComponent("corpus.wax")

        try await writeSessionStore(
            at: source,
            documents: [("Corrupt manifest rebuild note about orbital telemetry.", ["session_id": "session-a"])]
        )

        _ = try await BrokerCorpusStoreBuilder.build(
            sessionsDirectory: sessionsDir,
            targetStoreURL: corpus,
            noEmbedder: true,
            embedderChoice: "minilm",
            recursive: true
        )

        let manifestURL = CorpusBuildManifestStore.manifestURL(for: corpus)
        try Data("not valid corpus manifest json".utf8).write(to: manifestURL)

        let rebuild = try await BrokerCorpusStoreBuilder.build(
            sessionsDirectory: sessionsDir,
            targetStoreURL: corpus,
            noEmbedder: true,
            embedderChoice: "minilm",
            recursive: true
        )
        #expect(rebuild.storesDiscovered == 1)
        #expect(rebuild.storesIndexed == 1)
        #expect(rebuild.documentsIndexed == 1)
        #expect(try CorpusBuildManifestStore.load(for: corpus) != nil)

        let documents = try await MCPMemoryFactory.withOpenMemory(
            at: corpus,
            noEmbedder: true,
            embedderChoice: "minilm",
            structuredMemoryEnabled: false
        ) { memory in
            try await memory.corpusSourceDocuments()
        }
        #expect(documents.contains { $0.text.contains("orbital telemetry") })
    }
}

@Test
func corpusSearchBuilderRebuildsWhenCorpusManifestIsCorrupt() async throws {
    try await withTemporaryDirectory { root in
        let sessionsDir = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        let source = sessionsDir.appendingPathComponent("session-a.wax")
        let corpus = root.appendingPathComponent("corpus.wax")

        try await writeSessionStore(
            at: source,
            documents: [("MCP corpus corrupt manifest rebuild note about docking telemetry.", ["session_id": "session-a"])]
        )

        _ = try await CorpusStoreBuilder.build(
            sessionsDirectory: sessionsDir,
            targetStoreURL: corpus,
            noEmbedder: true,
            embedderChoice: "minilm",
            recursive: true
        )

        let manifestURL = CorpusBuildManifestStore.manifestURL(for: corpus)
        try Data("not valid mcp corpus manifest json".utf8).write(to: manifestURL)

        let rebuild = try await CorpusStoreBuilder.build(
            sessionsDirectory: sessionsDir,
            targetStoreURL: corpus,
            noEmbedder: true,
            embedderChoice: "minilm",
            recursive: true
        )
        #expect(rebuild.storesDiscovered == 1)
        #expect(rebuild.storesIndexed == 1)
        #expect(rebuild.documentsIndexed == 1)
        #expect(try CorpusBuildManifestStore.load(for: corpus) != nil)

        let documents = try await MCPMemoryFactory.withOpenMemory(
            at: corpus,
            noEmbedder: true,
            embedderChoice: "minilm",
            structuredMemoryEnabled: false
        ) { memory in
            try await memory.corpusSourceDocuments()
        }
        #expect(documents.contains { $0.text.contains("docking telemetry") })
    }
}

@Test
func corpusSearchRejectsInvalidTopK() async throws {
    try await withAgentBrokerService { service, _ in
        let result = await WaxMCPTools.handleCall(
            params: .init(
                name: "corpus_search",
                arguments: [
                    "query": .string("anything"),
                    "topK": .int(0),
                ]
            ),
            broker: service
        )

        #expect(result.isError == true)
        #expect(firstText(in: result).contains("topK must be between 1 and"))
    }
}

@Test
func corpusSearchDefaultRebuildIsFalse() async throws {
    try await withAgentBrokerService { service, _ in
        let token = "CORPUSDEFAULT\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))"
        let started = await service.handle(.init(command: "session_start"))
        #expect(started.ok == true)
        let sessionID = try #require(started.payload?.objectValue?["session_id"]?.stringValue)

        let remembered = await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("Broker default rebuild note \(token)"),
                "session_id": .string(sessionID),
            ]
        ))
        #expect(remembered.ok == true)

        let ended = await service.handle(.init(
            command: "session_end",
            arguments: ["session_id": .string(sessionID)]
        ))
        #expect(ended.ok == true)

        let seeded = await service.handle(.init(
            command: "corpus_search",
            arguments: [
                "query": .string(token),
                "mode": .string("text"),
                "topK": .int(5),
                "rebuild": .bool(true),
            ]
        ))
        #expect(seeded.ok == true, "corpus_search failed: \(seeded.error ?? "nil")")
        let seededBuild = try #require(seeded.payload?.objectValue?["build"]?.objectValue)
        try #require(seededBuild["performed"]?.boolValue == true)
        try #require(seeded.payload?.objectValue?["rebuild_requested"]?.boolValue == true)

        let omitted = await service.handle(.init(
            command: "corpus_search",
            arguments: [
                "query": .string(token),
                "mode": .string("text"),
                "topK": .int(5),
            ]
        ))
        #expect(omitted.ok == true, "corpus_search failed: \(omitted.error ?? "nil")")
        let omittedBuild = try #require(omitted.payload?.objectValue?["build"]?.objectValue)
        try #require(omitted.payload?.objectValue?["rebuild_requested"]?.boolValue == false)
        try #require(omittedBuild["performed"]?.boolValue == false)

        let corpusPath = try #require(
            omitted.payload?.objectValue?["build"]?.objectValue?["corpus_store_path"]?.stringValue
        )
        try FileManager.default.removeItem(atPath: corpusPath)

        let missing = await service.handle(.init(
            command: "corpus_search",
            arguments: [
                "query": .string(token),
                "mode": .string("text"),
                "topK": .int(5),
            ]
        ))
        #expect(missing.ok == true, "corpus_search failed: \(missing.error ?? "nil")")
        #expect(missing.payload?.objectValue?["rebuild_requested"]?.boolValue == false)
        #expect(missing.payload?.objectValue?["build"]?.objectValue?["performed"]?.boolValue == true)
    }

    guard let obj = ToolSchemas.waxCorpusSearch.objectValue,
          case .object(let properties) = obj["properties"],
          case .object(let rebuildSchema) = properties["rebuild"],
          case .string(let description) = rebuildSchema["description"]
    else {
        Issue.record("corpus_search rebuild schema is missing a description")
        return
    }
    #expect(!description.contains("Default: true"))
    #expect(description.contains("Default: false"))
}

@Test
func rememberDefaultAutoCommitMakesDataImmediatelyRecallable() async throws {
    try await withAgentBrokerService { service, _ in
        let seed = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let queryToken = "rememberautoquery\(seed.prefix(8))"
        let marker = "rememberautomarker\(seed.suffix(8))"
        let markerNeedle = String(marker.prefix(14))

        let rememberResult = await WaxMCPTools.handleCall(
            params: .init(
                name: "remember",
                arguments: ["content": .string("\(queryToken) \(marker)")]
            ),
            broker: service
        )
        #expect(rememberResult.isError != true)
        let rememberJSON = try parseJSONText(in: rememberResult)
        #expect((rememberJSON["status"] as? String) == "ok")

        let statsResult = await WaxMCPTools.handleCall(
            params: .init(name: "stats", arguments: [:]),
            broker: service
        )
        #expect(statsResult.isError != true)
        let statsJSON = try parseJSONText(in: statsResult)
        #expect((statsJSON["pendingFrames"] as? Int ?? -1) == 0)

        let recallResult = await WaxMCPTools.handleCall(
            params: .init(name: "recall", arguments: ["query": .string(queryToken), "limit": .int(5), "scope": .string("global")]),
            broker: service
        )
        #expect(recallResult.isError != true)
        #expect(firstText(in: recallResult).contains(markerNeedle))
    }
}

@Test
func rememberRejectsLegacyCommitArgument() async throws {
    try await withAgentBrokerService { service, _ in
        let rememberResult = await WaxMCPTools.handleCall(
            params: .init(
                name: "remember",
                arguments: [
                    "content": .string("legacy commit should fail"),
                    "commit": .bool(false),
                ]
            ),
            broker: service
        )
        #expect(rememberResult.isError == true)
        #expect(firstText(in: rememberResult).contains("unsupported argument"))
    }
}

@Test
func handoffRejectsLegacyCommitArgument() async throws {
    try await withAgentBrokerService { service, _ in
        let handoffResult = await WaxMCPTools.handleCall(
            params: .init(
                name: "handoff",
                arguments: [
                    "content": .string("legacy handoff commit should fail"),
                    "commit": false,
                ]
            ),
            broker: service
        )
        #expect(handoffResult.isError == true)
        #expect(firstText(in: handoffResult).contains("unsupported argument"))
    }
}

@Test
func recallAndSearchSupportMetadataExactFilters() async throws {
    try await withAgentBrokerService { service, _ in
        let seed = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let queryToken = "metadatafilterquery\(seed.prefix(8))"
        let blockedMarker = "metadatablocked\(seed.suffix(8))"
        let allowedMarker = "metadataallowed\(seed.dropFirst(8).prefix(8))"
        let blockedNeedle = String(blockedMarker.prefix(12))
        let allowedNeedle = String(allowedMarker.prefix(12))

        let blockedRemember = await WaxMCPTools.handleCall(
            params: .init(
                name: "remember",
                arguments: [
                    "content": .string("\(queryToken) \(blockedMarker)"),
                    "metadata": .object(["group": .string("blocked")]),
                ]
            ),
            broker: service
        )
        #expect(blockedRemember.isError != true)

        let allowedRemember = await WaxMCPTools.handleCall(
            params: .init(
                name: "remember",
                arguments: [
                    "content": .string("\(queryToken) \(allowedMarker)"),
                    "metadata": .object(["group": .string("allowed")]),
                ]
            ),
            broker: service
        )
        #expect(allowedRemember.isError != true)

        let baselineSearch = await WaxMCPTools.handleCall(
            params: .init(
                name: "search",
                arguments: ["query": .string(queryToken), "mode": .string("text"), "topK": .int(10)]
            ),
            broker: service
        )
        #expect(baselineSearch.isError != true)
        #expect(firstText(in: baselineSearch).contains(blockedNeedle))

        let filteredSearch = await WaxMCPTools.handleCall(
            params: .init(
                name: "search",
                arguments: [
                    "query": .string(queryToken),
                    "mode": .string("text"),
                    "topK": .int(10),
                    "filters": .object([
                        "metadata": .object([
                            "exact": .object(["group": .string("allowed")]),
                        ]),
                    ]),
                ]
            ),
            broker: service
        )
        #expect(filteredSearch.isError != true)
        #expect(firstText(in: filteredSearch).contains(allowedNeedle))
        #expect(!firstText(in: filteredSearch).contains(blockedNeedle))

        let baselineRecall = await WaxMCPTools.handleCall(
            params: .init(name: "recall", arguments: ["query": .string(queryToken), "limit": .int(10), "scope": .string("global")]),
            broker: service
        )
        #expect(baselineRecall.isError != true)
        #expect(firstText(in: baselineRecall).contains(blockedNeedle))

        let filteredRecall = await WaxMCPTools.handleCall(
            params: .init(
                name: "recall",
                arguments: [
                    "query": .string(queryToken),
                    "limit": .int(10),
                    "scope": .string("global"),
                    "filters": .object([
                        "metadata": .object([
                            "exact": .object(["group": .string("allowed")]),
                        ]),
                    ]),
                ]
            ),
            broker: service
        )
        #expect(filteredRecall.isError != true)
        #expect(firstText(in: filteredRecall).contains(allowedNeedle))
        #expect(!firstText(in: filteredRecall).contains(blockedNeedle))
    }
}

@Test
func searchAcceptsLifecycleAndFrameIDFilters() async throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-mcp-lifecycle-filters-\(UUID().uuidString)", isDirectory: true)
    let storeURL = rootURL.appendingPathComponent("memory.wax")
    let sessionRootURL = rootURL.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let fixture = try await seedLifecycleFilterFixture(at: storeURL)
    let service = try await AgentBrokerService(
        storePath: storeURL.path,
        sessionRootPath: sessionRootURL.path,
        noEmbedder: true,
        embedderChoice: "auto",
        requireVector: false
    )
    defer { Task { try? await service.close() } }

    do {
        let baselineSearch = await WaxMCPTools.handleCall(
            params: .init(
                name: "search",
                arguments: [
                    "query": .string(fixture.query),
                    "mode": .string("text"),
                    "topK": .int(10),
                ]
            ),
            broker: service
        )
        #expect(baselineSearch.isError != true)
        let baselineJSON = try parseJSONResource(in: baselineSearch, uriSuffix: "search-summary")
        #expect(resultFrameIDs(fromToolJSON: baselineJSON).contains(fixture.replacementFrameID))
        #expect(!resultFrameIDs(fromToolJSON: baselineJSON).contains(fixture.deletedFrameID))
        #expect(!resultFrameIDs(fromToolJSON: baselineJSON).contains(fixture.supersededFrameID))

        let filteredSearch = await WaxMCPTools.handleCall(
            params: .init(
                name: "search",
                arguments: [
                    "query": .string(fixture.query),
                    "mode": .string("text"),
                    "topK": .int(10),
                    "filters": .object([
                        "include_deleted": .bool(true),
                        "include_superseded": .bool(true),
                        "frame_ids": .array([
                            .int(Int(fixture.deletedFrameID)),
                            .int(Int(fixture.supersededFrameID)),
                        ]),
                    ]),
                ]
            ),
            broker: service
        )
        #expect(filteredSearch.isError != true)
        let filteredJSON = try parseJSONResource(in: filteredSearch, uriSuffix: "search-summary")
        #expect(resultFrameIDs(fromToolJSON: filteredJSON) == Set([fixture.deletedFrameID, fixture.supersededFrameID]))
        let appliedFilters = try #require(filteredJSON["applied_filters"] as? [String: Any])
        #expect(appliedFilters["include_deleted"] as? Bool == true)
        #expect(appliedFilters["include_superseded"] as? Bool == true)
        #expect((appliedFilters["frame_ids"] as? [Int])?.count == 2)
    }
}

@Test
func recallValidatesModeAndSearchControls() async throws {
    try await withAgentBrokerService { service, _ in
        let invalidMode = await WaxMCPTools.handleCall(
            params: .init(
                name: "recall",
                arguments: ["query": "mode-validation", "mode": "invalid-mode"]
            ),
            broker: service
        )
        #expect(invalidMode.isError == true)
        #expect(firstText(in: invalidMode).contains("mode"))

        let invalidTopK = await WaxMCPTools.handleCall(
            params: .init(
                name: "recall",
                arguments: ["query": "topk-validation", "search_top_k": 0]
            ),
            broker: service
        )
        #expect(invalidTopK.isError == true)
        #expect(firstText(in: invalidTopK).contains("search_top_k"))
    }
}

@Test
func searchRejectsUnknownFilterKeys() async throws {
    try await withAgentBrokerService { service, _ in
        let result = await WaxMCPTools.handleCall(
            params: .init(
                name: "search",
                arguments: [
                    "query": "unknown filter key",
                    "filters": .object(["unsupported": .bool(true)]),
                ]
            ),
            broker: service
        )

        #expect(result.isError == true)
        #expect(firstText(in: result).contains("filters.unsupported"))
    }
}

@Test
func searchRejectsNonArrayLabelsFilter() async throws {
    try await withAgentBrokerService { service, _ in
        let result = await WaxMCPTools.handleCall(
            params: .init(
                name: "search",
                arguments: [
                    "query": "bad labels filter",
                    "filters": .object(["labels": .string("not-an-array")]),
                ]
            ),
            broker: service
        )

        #expect(result.isError == true)
        #expect(firstText(in: result).contains("filters.labels must be an array of strings"))
    }
}

@Test
func searchRejectsNonIntegerTimeFilters() async throws {
    try await withAgentBrokerService { service, _ in
        let result = await WaxMCPTools.handleCall(
            params: .init(
                name: "search",
                arguments: [
                    "query": "bad time filter",
                    "filters": .object(["time_after_ms": .string("not-an-int")]),
                ]
            ),
            broker: service
        )

        #expect(result.isError == true)
        #expect(firstText(in: result).contains("filters.time_after_ms must be an integer"))
    }
}

@Test
func searchRejectsInvalidLifecycleAndFrameIDFilters() async throws {
    try await withAgentBrokerService { service, _ in
        let invalidDeleted = await WaxMCPTools.handleCall(
            params: .init(
                name: "search",
                arguments: [
                    "query": "bad lifecycle filter",
                    "filters": .object(["include_deleted": .string("yes")]),
                ]
            ),
            broker: service
        )
        #expect(invalidDeleted.isError == true)
        #expect(firstText(in: invalidDeleted).contains("filters.include_deleted must be a boolean"))

        let invalidFrameIDs = await WaxMCPTools.handleCall(
            params: .init(
                name: "search",
                arguments: [
                    "query": "bad frame id filter",
                    "filters": .object(["frame_ids": .array([.int(-1)])]),
                ]
            ),
            broker: service
        )
        #expect(invalidFrameIDs.isError == true)
        #expect(firstText(in: invalidFrameIDs).contains("filters.frame_ids must contain only non-negative integers"))
    }
}

@Test
func toolsReturnValidationErrorForMissingArguments() async throws {
    try await withAgentBrokerService { service, _ in
        let result = await WaxMCPTools.handleCall(
            params: .init(name: "remember", arguments: [:]),
            broker: service
        )
        #expect(result.isError == true)
        #expect(firstText(in: result).contains("Missing required argument"))
    }
}

@Test
func toolsRejectNonIntegralAndOutOfRangeNumericArguments() async throws {
    try await withAgentBrokerService { service, _ in
        let fractional = await WaxMCPTools.handleCall(
            params: .init(
                name: "search",
                arguments: ["query": "actors", "topK": 1.9]
            ),
            broker: service
        )
        #expect(fractional.isError == true)
        #expect(firstText(in: fractional).contains("topK must be an integer"))

        let outOfRange = await WaxMCPTools.handleCall(
            params: .init(
                name: "search",
                arguments: ["query": "actors", "topK": 1e100]
            ),
            broker: service
        )
        #expect(outOfRange.isError == true)
        #expect(firstText(in: outOfRange).contains("topK is out of range"))
    }
}

@Test
func toolsRejectRecallLimitOutOfRange() async throws {
    try await withAgentBrokerService { service, _ in
        let zero = await WaxMCPTools.handleCall(
            params: .init(
                name: "recall",
                arguments: ["query": "actors", "limit": 0]
            ),
            broker: service,
            structuredMemoryEnabled: true
        )
        #expect(zero.isError == true)
        #expect(firstText(in: zero).contains("limit must be between 1 and"))

        let tooHigh = await WaxMCPTools.handleCall(
            params: .init(
                name: "recall",
                arguments: ["query": "actors", "limit": 101]
            ),
            broker: service,
            structuredMemoryEnabled: true
        )
        #expect(tooHigh.isError == true)
        #expect(firstText(in: tooHigh).contains("limit must be between 1 and"))
    }
}

@Test
func factsQueryRendersSpanIdentityAndTemporalBounds() async throws {
    try await withAgentBrokerService { service, _ in
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let first = await WaxMCPTools.handleCall(
            params: .init(
                name: "fact_assert",
                arguments: [
                    "subject": .string("project:f019"),
                    "predicate": .string("status"),
                    "object": .string("active"),
                    "relation": .string("extends"),
                    "valid_from": .int(Int(nowMs)),
                ]
            ),
            broker: service
        )
        #expect(first.isError != true)

        let second = await WaxMCPTools.handleCall(
            params: .init(
                name: "fact_assert",
                arguments: [
                    "subject": .string("project:f019"),
                    "predicate": .string("status"),
                    "object": .string("active"),
                    "relation": .string("extends"),
                    "valid_from": .int(Int(nowMs)),
                ]
            ),
            broker: service
        )
        #expect(second.isError != true)

        let queried = await WaxMCPTools.handleCall(
            params: .init(
                name: "facts_query",
                arguments: [
                    "subject": .string("project:f019"),
                    "predicate": .string("status"),
                    "valid_as_of": .int(Int(nowMs)),
                    "system_as_of": .int(Int.max),
                    "limit": .int(10),
                ]
            ),
            broker: service
        )
        #expect(queried.isError != true)

        let payload = try parseJSONText(in: queried)
        let hits = try #require(payload["hits"] as? [[String: Any]])
        #expect(hits.count == 2)

        let spanIDs = hits.compactMap { $0["span_id"] as? Int }
        #expect(Set(spanIDs).count == 2)
        for hit in hits {
            #expect(hit["relation"] as? String == "extends")
            #expect(hit["valid_from_ms"] as? Int == Int(nowMs))
            #expect(hit["valid_to_ms"] is NSNull)
            #expect(hit["system_from_ms"] as? Int != nil)
            #expect(hit["system_to_ms"] is NSNull)
            #expect(hit["is_open_ended"] as? Bool == true)
        }
    }
}

@Test
func toolsBlockStructuredMemoryOnlyToolsWhenDisabled() async throws {
    try await withAgentBrokerService { service, _ in
        let result = await WaxMCPTools.handleCall(
            params: .init(
                name: "facts_query",
                arguments: ["subject": "agent:codex", "limit": 10]
            ),
            broker: service,
            structuredMemoryEnabled: false
        )
        #expect(result.isError == true)
        #expect(firstText(in: result).contains("structured memory"))

        let knowledgeCapture = await WaxMCPTools.handleCall(
            params: .init(
                name: "knowledge_capture",
                arguments: [
                    "content": "Codex prefers focused regressions.",
                    "subject": "agent:codex",
                    "kind": "agent",
                    "predicate": "prefers",
                    "object": "focused regressions",
                ]
            ),
            broker: service,
            structuredMemoryEnabled: false
        )
        #expect(knowledgeCapture.isError == true)
        #expect(firstText(in: knowledgeCapture).contains("structured memory"))
    }
}

@Test
func memoryAppendRemainsCallableWhenUnlisted() async throws {
    try await withAgentBrokerService { service, _ in
        let daily = Set(ToolSchemas.tools(structuredMemoryEnabled: true, profile: .daily).map(\.name))
        #expect(!daily.contains("memory_append"))
        let result = await WaxMCPTools.handleCall(
            params: .init(
                name: "memory_append",
                arguments: [
                    "content": "ALIAS-CANARY unlisted memory_append still writes",
                ]
            ),
            broker: service
        )
        #expect(result.isError != true)
        let payload = try parseJSONText(in: result)
        #expect(payload["status"] as? String == "ok")
    }
}

@Test
func unknownToolReturnsErrorResult() async throws {
    try await withAgentBrokerService { service, _ in
        let result = await WaxMCPTools.handleCall(
            params: .init(name: "nope", arguments: [:]),
            broker: service
        )
        #expect(result.isError == true)
        #expect(firstText(in: result).contains("Unknown tool"))
    }
}

@Test
func mcpRejectsBrokerControlCommands() async throws {
    try await withAgentBrokerService { service, _ in
        for command in ["shutdown", "exit", "quit"] {
            let result = await WaxMCPTools.handleCall(
                params: .init(name: command, arguments: [:]),
                broker: service
            )
            #expect(result.isError == true)
            #expect(firstText(in: result).contains("Unknown tool"))
        }
    }
}

@Test
func hiddenFlushToolIsRejectedConsistently() async throws {
    try await withAgentBrokerService { service, _ in
        for command in ["flush", "wax_flush"] {
            let result = await WaxMCPTools.handleCall(
                params: .init(name: command, arguments: [:]),
                broker: service
            )
            #expect(result.isError == true)
            #expect(firstText(in: result).contains("Unknown tool"))
        }
    }
}

@Test
func markdownProjectionMarkerEscapesCommentTerminators() throws {
    let marker = MarkdownProjectionMarker(
        sourceKind: "daily_note",
        frameID: 7,
        memoryID: "durable:7",
        hash: "hash-->break",
        dateKey: "2026-05-17-->escape"
    )

    let comment = BrokerMarkdownSync.markerComment(marker)
    let payloadEnd = comment.index(comment.endIndex, offsetBy: -4)
    #expect(!comment[..<payloadEnd].contains("-->"))

    let parsed = BrokerMarkdownSync.parse(text: "- safe line \(comment)")
    #expect(parsed.count == 1)
    #expect(parsed[0].text == "safe line")
    #expect(parsed[0].marker == marker)
}

@Test
func markdownExportSanitizesDailySourceDateFilenames() async throws {
    try await withAgentBrokerService { service, _ in
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-markdown-source-date-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let remember = await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("Daily note source date must not escape the projection directory."),
                "memory_type": .string("fact"),
                "durability": .string("durable"),
                "metadata": .object([
                    MemoryMetadataKeys.sourceKind: .string(MarkdownProjectionKind.dailyNote.rawValue),
                    MemoryMetadataKeys.sourceDate: .string("../escape"),
                ]),
            ]
        ))
        #expect(remember.ok == true)

        let export = await service.handle(.init(
            command: "markdown_export",
            arguments: ["output_dir": .string(rootURL.path)]
        ))
        #expect(export.ok == true)
        let payload = try #require(export.payload?.objectValue)
        let dailyPaths = try #require(payload["daily_note_paths"]?.arrayValue)
        let escapedURL = rootURL.appendingPathComponent("escape.md")
        #expect(!FileManager.default.fileExists(atPath: escapedURL.path))

        let memoryDir = rootURL.appendingPathComponent("memory", isDirectory: true).standardizedFileURL
        for pathValue in dailyPaths {
            let path = try #require(pathValue.stringValue)
            let url = URL(fileURLWithPath: path).standardizedFileURL
            #expect(url.deletingLastPathComponent() == memoryDir)
            #expect(!url.lastPathComponent.contains("/"))
            #expect(!url.lastPathComponent.contains(".."))
        }
    }
}


@Test
func brokerMemorySearchRequiresSessionIDWhenMultipleActiveSessionsIncludeWorking() async throws {
    try await withAgentBrokerService { service, _ in
        let first = await service.handle(.init(command: "session_start"))
        #expect(first.ok == true)
        let firstID = try #require(first.payload?.objectValue?["session_id"]?.stringValue)

        let second = await service.handle(.init(command: "session_start"))
        #expect(second.ok == true)
        let secondID = try #require(second.payload?.objectValue?["session_id"]?.stringValue)
        let marker = "F034_BROKER_WORKING_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"

        let firstWrite = await service.handle(.init(
            command: "memory_append",
            arguments: [
                "content": .string("\(marker) first session working memory"),
                "session_id": .string(firstID),
            ]
        ))
        #expect(firstWrite.ok == true)
        let secondWrite = await service.handle(.init(
            command: "memory_append",
            arguments: [
                "content": .string("\(marker) second session working memory"),
                "session_id": .string(secondID),
            ]
        ))
        #expect(secondWrite.ok == true)

        let ambiguous = await service.handle(.init(
            command: "memory_search",
            arguments: [
                "query": .string(marker),
                "mode": .string("text"),
                "include_working": .bool(true),
                "include_episodic": .bool(false),
                "include_durable": .bool(false),
            ]
        ))
        #expect(ambiguous.ok == false)
        #expect((ambiguous.error ?? "").contains("session_id is required when more than one"))

        let durableOnly = await service.handle(.init(
            command: "memory_search",
            arguments: [
                "query": .string(marker),
                "mode": .string("text"),
                "include_working": .bool(false),
                "include_episodic": .bool(false),
                "include_durable": .bool(true),
            ]
        ))
        #expect(durableOnly.ok == true)

        let explicit = await service.handle(.init(
            command: "memory_search",
            arguments: [
                "query": .string(marker),
                "session_id": .string(firstID),
                "mode": .string("text"),
                "include_working": .bool(true),
                "include_episodic": .bool(false),
                "include_durable": .bool(false),
            ]
        ))
        #expect(explicit.ok == true)
        let payload = try #require(explicit.payload?.objectValue)
        let results = try #require(payload["results"]?.arrayValue)
        #expect(!results.isEmpty)
        #expect(results.allSatisfy {
            $0.objectValue?["memory_id"]?.stringValue?.contains(firstID) == true
        })
    }
}

@Test
func brokerCompactContextRequiresSessionIDWhenMultipleSessionsAreActive() async throws {
    try await withAgentBrokerService { service, _ in
        let first = await service.handle(.init(command: "session_start"))
        #expect(first.ok == true)
        let firstID = try #require(first.payload?.objectValue?["session_id"]?.stringValue)

        let second = await service.handle(.init(command: "session_start"))
        #expect(second.ok == true)
        _ = try #require(second.payload?.objectValue?["session_id"]?.stringValue)
        let marker = "F034_BROKER_COMPACT_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"

        let write = await service.handle(.init(
            command: "memory_append",
            arguments: [
                "content": .string("\(marker) first session working memory"),
                "session_id": .string(firstID),
            ]
        ))
        #expect(write.ok == true)

        let ambiguous = await service.handle(.init(
            command: "compact_context",
            arguments: [
                "query": .string(marker),
                "mode": .string("text"),
                "token_budget": .int(512),
            ]
        ))
        #expect(ambiguous.ok == false)
        #expect((ambiguous.error ?? "").contains("session_id is required when more than one"))

        let explicit = await service.handle(.init(
            command: "compact_context",
            arguments: [
                "query": .string(marker),
                "session_id": .string(firstID),
                "mode": .string("text"),
                "token_budget": .int(512),
            ]
        ))
        #expect(explicit.ok == true)
        let payload = try #require(explicit.payload?.objectValue)
        let shortContext = try #require(payload["short_context"]?.arrayValue)
        #expect(shortContext.contains {
            $0.objectValue?["preview"]?.stringValue?.contains("first session working memory") == true
        })
    }
}

@Test
func brokerCLIPathResolvesSiblingWhenLaunchedViaPath() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-broker-path-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let cliPath = tempDir.appendingPathComponent("wax-cli")
    let mcpPath = tempDir.appendingPathComponent("wax-mcp")
    try "#!/bin/sh\nexit 0\n".write(to: cliPath, atomically: true, encoding: .utf8)
    try "#!/bin/sh\nexit 0\n".write(to: mcpPath, atomically: true, encoding: .utf8)
    guard chmod(cliPath.path, 0o755) == 0, chmod(mcpPath.path, 0o755) == 0 else {
        throw NSError(domain: "WaxMCPServerTests", code: 41, userInfo: [NSLocalizedDescriptionKey: "Failed to make test executables"])
    }

    let originalPath = ProcessInfo.processInfo.environment["PATH"]
    let pathPrefix = tempDir.path
    let newPath = originalPath.map { "\(pathPrefix):\($0)" } ?? pathPrefix
    setenv("PATH", newPath, 1)
    defer {
        if let originalPath {
            setenv("PATH", originalPath, 1)
        } else {
            unsetenv("PATH")
        }
    }

    let resolved = AgentBrokerPathing.resolveBrokerCLIPath(currentExecutablePath: "wax-mcp")
    #expect(resolved == cliPath.path)
}


@Test
func rememberRejectsMetadataSessionID() async throws {
    try await withAgentBrokerService { service, _ in
        let result = await WaxMCPTools.handleCall(
            params: .init(
                name: "remember",
                arguments: [
                    "content": "invalid metadata session id",
                    "metadata": .object(["session_id": .string("not-a-uuid")]),
                ]
            ),
            broker: service
        )
        #expect(result.isError == true)
        #expect(firstText(in: result).contains("metadata.session_id"))
    }
}


@Test
func statsReportQueryEmbeddingAvailableWithoutIdentityMetadata() async throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-mcp-identityless-embedder-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    var config = OrchestratorConfig.default
    config.enableVectorSearch = true
    config.queryEmbeddingTimeout = .seconds(1)

    let service = try await AgentBrokerService(
        storePath: rootURL.appendingPathComponent("memory.wax").path,
        sessionRootPath: rootURL.appendingPathComponent("sessions").path,
        noEmbedder: false,
        embedderChoice: "auto",
        requireVector: false,
        embedderOverride: IdentitylessEmbedder(),
        orchestratorConfig: config
    )
    defer { Task { try? await service.close() } }

    let stats = await WaxMCPTools.handleCall(
        params: .init(name: "stats", arguments: [:]),
        broker: service
    )
    #expect(stats.isError != true)
    let statsJSON = try parseJSONText(in: stats)
    #expect((statsJSON["queryEmbeddingAvailable"] as? Bool) == true)
}

@Test
func vectorFallbackIsSurfacedInSearchAndStats() async throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-mcp-vector-fallback-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let storeURL = rootURL.appendingPathComponent("memory.wax")
    let sessionRootURL = rootURL.appendingPathComponent("sessions", isDirectory: true)

    do {
        var seedConfig = OrchestratorConfig.default
        seedConfig.enableVectorSearch = false
        seedConfig.enableStructuredMemory = true
        let seeder = try await AgentBrokerService(
            storePath: storeURL.path,
            sessionRootPath: sessionRootURL.path,
            noEmbedder: true,
            embedderChoice: "auto",
            requireVector: false,
            orchestratorConfig: seedConfig
        )
        let remembered = await WaxMCPTools.handleCall(
            params: .init(
                name: "remember",
                arguments: ["content": "VECTOR_FALLBACK_SIGNAL Swift actors"]
            ),
            broker: seeder
        )
        #expect(remembered.isError != true)
        try await seeder.close()
    }

    var config = OrchestratorConfig.default
    config.enableVectorSearch = true
    config.queryEmbeddingTimeout = .milliseconds(25)
    config.rag.searchMode = .hybrid(alpha: 0.5)

    let service = try await AgentBrokerService(
        storePath: storeURL.path,
        sessionRootPath: sessionRootURL.path,
        noEmbedder: false,
        embedderChoice: "auto",
        requireVector: false,
        embedderOverride: HangingCountingEmbedder(),
        orchestratorConfig: config
    )
    defer { Task { try? await service.close() } }

    let search = await WaxMCPTools.handleCall(
        params: .init(
            name: "search",
            arguments: ["query": "VECTOR_FALLBACK_SIGNAL", "mode": "hybrid", "topK": 5]
        ),
        broker: service
    )
    #expect(search.isError != true)
        let payload = try parseJSONResource(in: search, uriSuffix: "/search-summary")
        #expect((payload["requested_mode"] as? String) == "hybrid(alpha=0.500)")
        #expect((payload["effective_mode"] as? String) == "text")
        #expect((payload["query_embedding_state"] as? String) == "timeout")
        let warning = try #require(payload["warning"] as? String)
        #expect(warning.contains("hybrid requested"))
        #expect(warning.contains("used text"))
        let results = try requireArray(payload, key: "results")
        #expect(!results.isEmpty)
        let firstResult = try requireObject(results[0])
        #expect(firstResult["frameId"] != nil)
        #expect(firstResult["sources"] != nil)

    let stats = await WaxMCPTools.handleCall(
        params: .init(name: "stats", arguments: [:]),
        broker: service
    )
    #expect(stats.isError != true)
    let statsJSON = try parseJSONText(in: stats)
    #expect((statsJSON["queryEmbeddingCircuitOpen"] as? Bool) == true)
}

@Test
func invalidSessionIDIsRejected() async throws {
    try await withAgentBrokerService { service, _ in
        let result = await WaxMCPTools.handleCall(
            params: .init(
                name: "search",
                arguments: ["query": "x", "mode": "text", "session_id": "not-a-uuid"]
            ),
            broker: service
        )
        #expect(result.isError == true)
        #expect(firstText(in: result).contains("session_id must be a valid UUID"))
    }
}

@Test
func recallJSONResourceIncludesStructuredResults() async throws {
    try await withAgentBrokerService { service, _ in
        _ = await WaxMCPTools.handleCall(
            params: .init(
                name: "remember",
                arguments: [
                    "content": "Structured recall payload marker",
                    "metadata": ["source": "recall-json"],
                ]
            ),
            broker: service
        )
        let recall = await WaxMCPTools.handleCall(
            params: .init(
                name: "recall",
                arguments: ["query": "payload marker", "limit": 3, "scope": "global"]
            ),
            broker: service
        )

        #expect(recall.isError != true)
        let payload = try parseJSONResource(in: recall, uriSuffix: "/recall-summary")
        let results = try requireArray(payload, key: "results")
        #expect(!results.isEmpty)
        let first = try requireObject(results[0])
        #expect((first["text"] as? String)?.contains("Structured recall payload marker") == true)
        let metadata = try requireObject(first, key: "metadata")
        #expect((metadata["source"] as? String) == "recall-json")
    }
}


@Test
func graphToolsRoundTripWorks() async throws {
    try await withAgentBrokerService { service, _ in
        let upsert = await WaxMCPTools.handleCall(
            params: .init(
                name: "entity_upsert",
                arguments: [
                    "key": "agent:codex",
                    "kind": "agent",
                    "aliases": ["codex", "assistant"],
                ]
            ),
            broker: service
        )
        #expect(upsert.isError != true)
        let upsertJSON = try parseJSONText(in: upsert)
        #expect((upsertJSON["entity_id"] as? Int ?? 0) > 0)

        let assert = await WaxMCPTools.handleCall(
            params: .init(
                name: "fact_assert",
                arguments: [
                    "subject": "agent:codex",
                    "predicate": "learned_behavior",
                    "object": "Prefer focused patches",
                ]
            ),
            broker: service
        )
        #expect(assert.isError != true)
        let asserted = try parseJSONText(in: assert)
        let factID = try requireInt(asserted, key: "fact_id")

        let factsBeforeRetract = await WaxMCPTools.handleCall(
            params: .init(
                name: "facts_query",
                arguments: ["subject": "agent:codex", "predicate": "learned_behavior", "limit": 20]
            ),
            broker: service
        )
        #expect(factsBeforeRetract.isError != true)
        #expect(firstText(in: factsBeforeRetract).contains("Prefer focused patches"))

        let retract = await WaxMCPTools.handleCall(
            params: .init(
                name: "fact_retract",
                arguments: ["fact_id": .int(factID)]
            ),
            broker: service
        )
        #expect(retract.isError != true)

        let factsAfterRetract = await WaxMCPTools.handleCall(
            params: .init(
                name: "facts_query",
                arguments: ["subject": "agent:codex", "predicate": "learned_behavior", "limit": 20]
            ),
            broker: service
        )
        #expect(factsAfterRetract.isError != true)
        #expect(!firstText(in: factsAfterRetract).contains("Prefer focused patches"))

        let resolve = await WaxMCPTools.handleCall(
            params: .init(
                name: "entity_resolve",
                arguments: ["alias": "codex", "limit": 5]
            ),
            broker: service
        )
        #expect(resolve.isError != true)
        #expect(firstText(in: resolve).contains("agent:codex"))
    }
}

@Test
func licenseValidatorRejectsInvalidFormat() {
    do {
        try LicenseValidator.validate(key: "bad-key")
        #expect(Bool(false))
    } catch let error as LicenseValidator.ValidationError {
        #expect(error == .invalidLicenseKey)
    } catch {
        #expect(Bool(false))
    }
}

@Test
func licenseValidatorTrialPassAndExpiration() throws {
    let originalDefaults = LicenseValidator.trialDefaults
    let originalKey = LicenseValidator.firstLaunchKey
    let originalKeychain = LicenseValidator.keychainEnabled

    let suiteName = "wax-mcp-tests-\(UUID().uuidString)"
    guard let suite = UserDefaults(suiteName: suiteName) else {
        throw NSError(domain: "WaxMCPServerTests", code: 1, userInfo: nil)
    }

    LicenseValidator.trialDefaults = suite
    LicenseValidator.firstLaunchKey = "wax_first_launch_test"
    LicenseValidator.keychainEnabled = false

    defer {
        LicenseValidator.trialDefaults = originalDefaults
        LicenseValidator.firstLaunchKey = originalKey
        LicenseValidator.keychainEnabled = originalKeychain
        suite.removePersistentDomain(forName: suiteName)
    }

    try LicenseValidator.validate(key: nil)

    suite.set(
        Date(timeIntervalSinceNow: -(15 * 24 * 60 * 60)),
        forKey: LicenseValidator.firstLaunchKey
    )

    do {
        try LicenseValidator.validate(key: nil)
        #expect(Bool(false))
    } catch let error as LicenseValidator.ValidationError {
        #expect(error == .trialExpired)
    }
}

private func withTemporaryDirectory(
    _ body: (URL) async throws -> Void
) async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-mcp-corpus-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    try await body(url)
}

private func writeSessionStore(
    at url: URL,
    documents: [(String, [String: String])]
) async throws {
    var config = OrchestratorConfig.default
    config.enableVectorSearch = false
    config.enableStructuredMemory = false
    config.chunking = .tokenCount(targetTokens: 8, overlapTokens: 2)
    config.rag = FastRAGConfig(
        maxContextTokens: 120,
        expansionMaxTokens: 60,
        snippetMaxTokens: 30,
        maxSnippets: 8,
        searchTopK: 20,
        searchMode: .textOnly
    )

    let memory = try await MemoryOrchestrator(at: url, config: config)
    var deferredError: Error?
    do {
        for (text, metadata) in documents {
            try await memory.remember(text, metadata: metadata)
        }
        try await memory.flush()
    } catch {
        deferredError = error
    }

    do {
        try await memory.close()
    } catch {
        if deferredError == nil {
            deferredError = error
        }
    }

    if let deferredError {
        throw deferredError
    }
}

private func openTextOnlyMemory(
    at url: URL,
    structuredMemoryEnabled: Bool
) async throws -> MemoryOrchestrator {
    var config = OrchestratorConfig.default
    config.enableVectorSearch = false
    config.enableStructuredMemory = structuredMemoryEnabled
    config.chunking = .tokenCount(targetTokens: 8, overlapTokens: 2)
    config.rag = FastRAGConfig(
        maxContextTokens: 120,
        expansionMaxTokens: 60,
        snippetMaxTokens: 30,
        maxSnippets: 8,
        searchTopK: 20,
        searchMode: .textOnly
    )
    return try await MemoryOrchestrator(at: url, config: config)
}

private func withVectorBrokerService(
    _ body: @Sendable (AgentBrokerService) async throws -> Void
) async throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-mcp-vector-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    var config = OrchestratorConfig.default
    config.enableVectorSearch = true
    config.enableTextSearch = true
    config.ingestEmbeddingTimeout = .seconds(5)
    config.queryEmbeddingTimeout = .seconds(5)
    config.chunking = .tokenCount(targetTokens: 200, overlapTokens: 20)
    config.rag = FastRAGConfig(
        maxContextTokens: 120,
        expansionMaxTokens: 60,
        snippetMaxTokens: 30,
        maxSnippets: 8,
        searchTopK: 20,
        searchMode: .hybrid(alpha: 0.5)
    )

    let service = try await AgentBrokerService(
        storePath: rootURL.appendingPathComponent("memory.wax").path,
        sessionRootPath: rootURL.appendingPathComponent("sessions").path,
        noEmbedder: false,
        embedderChoice: "auto",
        requireVector: false,
        embedderOverride: MCPTestDeterministicEmbedder(),
        orchestratorConfig: config
    )
    var deferredError: Error?
    do {
        try await body(service)
    } catch {
        deferredError = error
    }
    do {
        try await service.close()
    } catch {
        if deferredError == nil {
            deferredError = error
        }
    }
    if let deferredError {
        throw deferredError
    }
}

@Test
func vectorSearchRememberFlushRecallHappyPath() async throws {
    try await withVectorBrokerService { service in
        let remember = await WaxMCPTools.handleCall(
            params: .init(name: "remember", arguments: [
                "content": .string("Swift actors provide data isolation through actor-isolated state."),
            ]),
            broker: service
        )
        #expect(remember.isError != true)
        let rememberJSON = try parseJSONText(in: remember)
        #expect((rememberJSON["status"] as? String) == "ok")
        let framesAdded = rememberJSON["framesAdded"] as? Int ?? 0
        #expect(framesAdded > 0)

        let recall = await WaxMCPTools.handleCall(
            params: .init(name: "recall", arguments: [
                "query": .string("actors"),
                "scope": .string("global"),
            ]),
            broker: service
        )
        #expect(recall.isError != true)
        let recallJSON = try parseJSONText(in: recall)
        #expect((recallJSON["effective_mode"] as? String)?.hasPrefix("hybrid") == true)
        #expect((recallJSON["result_count"] as? Int) == 1)

        let search = await WaxMCPTools.handleCall(
            params: .init(name: "search", arguments: [
                "query": .string("actors"),
                "mode": .string("hybrid"),
            ]),
            broker: service
        )
        #expect(search.isError != true)
    }
}

@Test
func compatibilitySearchAcceptsVectorMode() async throws {
    try await withVectorBrokerService { service in
        let remember = await WaxMCPTools.handleCall(
            params: .init(
                name: "remember",
                arguments: ["content": .string("Vector mode compatibility anchor")]
            ),
            broker: service
        )
        #expect(remember.isError != true)

        let search = await WaxMCPTools.handleCall(
            params: .init(
                name: "search",
                arguments: [
                    "query": .string("Vector mode compatibility anchor"),
                    "mode": .string("vector"),
                    "topK": .int(5),
                ]
            ),
            broker: service
        )

        #expect(search.isError != true)
        #expect(firstText(in: search).contains("Vector mode compatibility anchor"))
    }
}

@Test
func vectorSearchRememberTimesOutWithHangingEmbedder() async throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-mcp-hang-remember-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    var config = OrchestratorConfig.default
    config.enableVectorSearch = true
    config.ingestEmbeddingTimeout = .milliseconds(100)

    let service = try await AgentBrokerService(
        storePath: rootURL.appendingPathComponent("memory.wax").path,
        sessionRootPath: rootURL.appendingPathComponent("sessions").path,
        noEmbedder: false,
        embedderChoice: "auto",
        requireVector: false,
        embedderOverride: HangingCountingEmbedder(),
        orchestratorConfig: config
    )
    defer { Task { try? await service.close() } }

    let result = await WaxMCPTools.handleCall(
        params: .init(name: "remember", arguments: [
            "content": .string("This should time out."),
        ]),
        broker: service
    )
    #expect(result.isError == true)
    let text = firstText(in: result)
    #expect(text.localizedCaseInsensitiveContains("timeout") || text.localizedCaseInsensitiveContains("timed out"))
}

@Test
func rememberRejectsSecretLikeDurableMemory() async throws {
    try await withAgentBrokerService { service, _ in
        let result = await WaxMCPTools.handleCall(
            params: .init(name: "remember", arguments: [
                "content": .string("OPENAI_API_KEY=sk-1234567890abcdefghijklmnop"),
                "memory_type": .string("decision"),
                "durability": .string("durable"),
            ]),
            broker: service
        )
        #expect(result.isError == true)
        #expect(firstText(in: result).contains("secret-like content"))
    }
}

@Test
func rememberSearchAndRecallExposeTypedExplainableMemory() async throws {
    try await withAgentBrokerService { service, _ in
        let remember = await WaxMCPTools.handleCall(
            params: .init(name: "remember", arguments: [
                "content": .string("Chris prefers concise summaries for release notes."),
                "memory_type": .string("user_preference"),
                "durability": .string("durable"),
                "project": .string("Wax"),
                "repo": .string("Wax"),
                "reviewed": .bool(true),
            ]),
            broker: service
        )
        #expect(remember.isError != true)

        let search = await WaxMCPTools.handleCall(
            params: .init(name: "search", arguments: [
                "query": .string("concise summaries"),
                "mode": .string("text"),
            ]),
            broker: service
        )
        #expect(search.isError != true)
        let searchJSON = try parseJSONResource(in: search, uriSuffix: "search-summary")
        let first = ((searchJSON["results"] as? [[String: Any]]) ?? []).first
        let explanations = first?["explanations"] as? [String] ?? []
        let metadata = first?["metadata"] as? [String: Any] ?? [:]
        #expect(metadata["wax.memory_type"] as? String == "user_preference")
        #expect(explanations.contains("keyword match"))
        #expect(explanations.contains("user preference"))

        let recall = await WaxMCPTools.handleCall(
            params: .init(name: "recall", arguments: [
                "query": .string("release notes preference"),
                "limit": .int(3),
                "scope": .string("global"),
                "verbosity": .string("verbose"),
            ]),
            broker: service
        )
        #expect(recall.isError != true)
        guard case .object(let recallJSON) = try #require(recall.structuredContent) else {
            Issue.record("Expected verbose recall structured content")
            return
        }
        guard case .array(let results)? = recallJSON["results"] else {
            Issue.record("Expected verbose recall results array")
            return
        }
        let recallFirst = results.compactMap { value -> [String: Value]? in
            if case .object(let object) = value { return object }
            return nil
        }.first
        let recallExplanations: [String] = {
            guard case .array(let values)? = recallFirst?["explanations"] else { return [] }
            return values.compactMap { value in
                if case .string(let text) = value { return text }
                return nil
            }
        }()
        #expect(recallExplanations.contains("user preference"))
    }
}


@Test
func brokerMarkdownSyncRejectsSecretLikeDurableMemoryImports() async throws {
    try await withAgentBrokerService { service, _ in
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-markdown-secret-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let memoryURL = rootURL.appendingPathComponent("MEMORY.md")
        let secret = "api_key=12345678901234567890"
        let marker = MarkdownProjectionMarker(
            sourceKind: MarkdownProjectionKind.memory.rawValue,
            hash: AgentBrokerService.stableHash(secret),
            memoryType: MemoryType.fact.rawValue,
            durability: MemoryDurability.durable.rawValue
        )
        try """
        # MEMORY

        ## fact
        - \(secret) \(BrokerMarkdownSync.markerComment(marker))
        """.write(to: memoryURL, atomically: true, encoding: .utf8)

        let response = await service.handle(.init(
            command: "markdown_sync",
            arguments: ["root_dir": .string(rootURL.path)]
        ))

        #expect(response.ok == false)
        #expect((response.error ?? "").contains("Refusing to store durable memory containing secret-like content"))
    }
}

@Test
func brokerMarkdownSyncDryRunRejectsSecretLikeDurableMemoryImports() async throws {
    try await withAgentBrokerService { service, _ in
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-markdown-secret-dry-run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let memoryURL = rootURL.appendingPathComponent("MEMORY.md")
        let secret = "api_key=12345678901234567890"
        let marker = MarkdownProjectionMarker(
            sourceKind: MarkdownProjectionKind.memory.rawValue,
            hash: AgentBrokerService.stableHash(secret),
            memoryType: MemoryType.fact.rawValue,
            durability: MemoryDurability.durable.rawValue
        )
        try """
        # MEMORY

        ## fact
        - \(secret) \(BrokerMarkdownSync.markerComment(marker))
        """.write(to: memoryURL, atomically: true, encoding: .utf8)

        let response = await service.handle(.init(
            command: "markdown_sync",
            arguments: [
                "root_dir": .string(rootURL.path),
                "dry_run": .bool(true),
            ]
        ))

        #expect(response.ok == false)
        #expect((response.error ?? "").contains("Refusing to store durable memory containing secret-like content"))
    }
}

@Test
func brokerMarkdownSyncIgnoresMarkerlessMemoryBullets() async throws {
    try await withAgentBrokerService { service, _ in
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-markdown-markerless-memory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let memoryURL = rootURL.appendingPathComponent("MEMORY.md")
        let markerless = "Markerless F185 memory bullet \(UUID().uuidString)"
        try """
        # MEMORY

        ## fact
        - \(markerless)
        """.write(to: memoryURL, atomically: true, encoding: .utf8)

        let sync = await service.handle(.init(
            command: "markdown_sync",
            arguments: ["root_dir": .string(rootURL.path)]
        ))
        #expect(sync.ok == true)
        let payload = try #require(sync.payload?.objectValue)
        let counts = try #require(payload["counts"]?.objectValue)
        #expect(counts["created"]?.intValue == 0)

        let search = await service.handle(.init(
            command: "search",
            arguments: [
                "query": .string(markerless),
                "mode": .string("text"),
                "topK": .int(5),
            ]
        ))
        #expect(search.ok == true)
        let searchPayload = try #require(search.payload?.objectValue)
        let results = try #require(searchPayload["results"]?.arrayValue)
        #expect(!results.contains { result in
            result.objectValue?["preview"]?.stringValue?.contains(markerless) == true
        })
    }
}

@Test
func brokerMarkdownSyncIgnoresMarkerlessDailyNoteBullets() async throws {
    try await withAgentBrokerService { service, _ in
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-markdown-markerless-daily-\(UUID().uuidString)", isDirectory: true)
        let memoryDir = rootURL.appendingPathComponent("memory", isDirectory: true)
        try FileManager.default.createDirectory(at: memoryDir, withIntermediateDirectories: true)
        let dailyURL = memoryDir.appendingPathComponent("2026-05-17.md")
        let markerless = "Markerless F185 daily bullet \(UUID().uuidString)"
        try """
        # 2026-05-17

        - \(markerless)
        """.write(to: dailyURL, atomically: true, encoding: .utf8)

        let sync = await service.handle(.init(
            command: "markdown_sync",
            arguments: ["root_dir": .string(rootURL.path)]
        ))
        #expect(sync.ok == true)
        let payload = try #require(sync.payload?.objectValue)
        let counts = try #require(payload["counts"]?.objectValue)
        #expect(counts["created"]?.intValue == 0)

        let search = await service.handle(.init(
            command: "search",
            arguments: [
                "query": .string(markerless),
                "mode": .string("text"),
                "topK": .int(5),
            ]
        ))
        #expect(search.ok == true)
        let searchPayload = try #require(search.payload?.objectValue)
        let results = try #require(searchPayload["results"]?.arrayValue)
        #expect(!results.contains { result in
            result.objectValue?["preview"]?.stringValue?.contains(markerless) == true
        })
    }
}

@Test
func brokerMarkdownSyncDryRunRejectsSecretLikeDreamApprovals() async throws {
    try await withAgentBrokerService { service, _ in
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-markdown-dream-secret-dry-run-\(UUID().uuidString)", isDirectory: true)
        let memoryDir = rootURL.appendingPathComponent("memory", isDirectory: true)
        try FileManager.default.createDirectory(at: memoryDir, withIntermediateDirectories: true)
        let dreamsURL = memoryDir.appendingPathComponent("DREAMS.md")
        let secret = "Decision: api_key=12345678901234567890"
        let marker = MarkdownProjectionMarker(
            sourceKind: MarkdownProjectionKind.dreams.rawValue,
            hash: AgentBrokerService.stableHash(secret),
            memoryType: MemoryType.fact.rawValue,
            durability: MemoryDurability.durable.rawValue
        )
        try """
        # DREAMS

        - [x] \(secret) \(BrokerMarkdownSync.markerComment(marker))
        """.write(to: dreamsURL, atomically: true, encoding: .utf8)

        let response = await service.handle(.init(
            command: "markdown_sync",
            arguments: [
                "root_dir": .string(rootURL.path),
                "dry_run": .bool(true),
            ]
        ))

        #expect(response.ok == false)
        #expect((response.error ?? "").contains("Refusing to store durable memory containing secret-like content"))
    }
}

@Test
func brokerMarkdownSyncDeduplicatesCheckedDreamApprovals() async throws {
    try await withAgentBrokerService { service, _ in
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-markdown-dream-dedupe-\(UUID().uuidString)", isDirectory: true)
        let memoryDir = rootURL.appendingPathComponent("memory", isDirectory: true)
        try FileManager.default.createDirectory(at: memoryDir, withIntermediateDirectories: true)
        let dreamsURL = memoryDir.appendingPathComponent("DREAMS.md")
        let dream = "Decision: deduplicate F186 DREAMS approval \(UUID().uuidString)"
        let marker = MarkdownProjectionMarker(
            sourceKind: MarkdownProjectionKind.dreams.rawValue,
            hash: AgentBrokerService.stableHash(dream),
            sourceFrameID: 41,
            memoryType: MemoryType.decision.rawValue,
            durability: MemoryDurability.durable.rawValue
        )
        var duplicateMarker = marker
        duplicateMarker.sourceFrameID = 42
        let firstLine = "- [x] \(dream) \(BrokerMarkdownSync.markerComment(marker))"
        let duplicateLine = "- [x] \(dream) \(BrokerMarkdownSync.markerComment(duplicateMarker))"
        try """
        # DREAMS

        \(firstLine)
        \(duplicateLine)
        """.write(to: dreamsURL, atomically: true, encoding: .utf8)

        let sync = await service.handle(.init(
            command: "markdown_sync",
            arguments: ["root_dir": .string(rootURL.path)]
        ))
        #expect(sync.ok == true)
        let payload = try #require(sync.payload?.objectValue)
        let counts = try #require(payload["counts"]?.objectValue)
        #expect(counts["approved_dreams"]?.intValue == 1)
        #expect(counts["rejected_dreams"]?.intValue == 1)

        let health = await service.handle(.init(command: "memory_health"))
        #expect(health.ok == true)
        let healthPayload = try #require(health.payload?.objectValue)
        #expect(healthPayload["total_documents"]?.intValue == 1)
    }
}

@Test
func brokerMarkdownExportIncludesEndedSessionDreams() async throws {
    try await withAgentBrokerService { service, sessionRootURL in
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-markdown-ended-dreams-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let started = await service.handle(.init(command: "session_start"))
        #expect(started.ok == true)
        let startedPayload = try #require(started.payload?.objectValue)
        let sessionID = try #require(startedPayload["session_id"]?.stringValue)
        let sessionUUID = try #require(UUID(uuidString: sessionID))
        let dream = "Decision: export ended session DREAMS \(UUID().uuidString)"

        let remembered = await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string(dream),
                "session_id": .string(sessionID),
            ]
        ))
        #expect(remembered.ok == true)

        let ended = await service.handle(.init(
            command: "session_end",
            arguments: ["session_id": .string(sessionID)]
        ))
        #expect(ended.ok == true)

        let export = await service.handle(.init(
            command: "markdown_export",
            arguments: [
                "output_dir": .string(outputURL.path),
                "session_id": .string(sessionID),
            ]
        ))
        #expect(export.ok == true)
        let exportPayload = try #require(export.payload?.objectValue)
        let dreamsPath = try #require(exportPayload["dreams_path"]?.stringValue)
        let dreamsURL = URL(fileURLWithPath: dreamsPath)
        var dreamsText = try String(contentsOf: dreamsURL, encoding: .utf8)
        #expect(dreamsText.contains(dream))
        #expect(dreamsText.contains("- [ ]"))

        let manifest = try BrokerSessionPersistence.loadManifest(rootURL: sessionRootURL, sessionID: sessionUUID)
        let reopened = try await service.openSessionMemory(at: URL(fileURLWithPath: manifest.storePath))
        try await reopened.close()

        dreamsText = dreamsText.replacingOccurrences(of: "- [ ] \(dream)", with: "- [x] \(dream)")
        try dreamsText.write(to: dreamsURL, atomically: true, encoding: .utf8)

        let sync = await service.handle(.init(
            command: "markdown_sync",
            arguments: ["root_dir": .string(outputURL.path)]
        ))
        #expect(sync.ok == true)
        let syncPayload = try #require(sync.payload?.objectValue)
        let counts = try #require(syncPayload["counts"]?.objectValue)
        #expect(counts["approved_dreams"]?.intValue == 1)
    }
}

@Test
func brokerMarkdownExportRejectsUnknownExplicitSessionID() async throws {
    try await withAgentBrokerService { service, _ in
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-markdown-unknown-session-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let export = await service.handle(.init(
            command: "markdown_export",
            arguments: [
                "output_dir": .string(outputURL.path),
                "session_id": .string(UUID().uuidString),
            ]
        ))

        #expect(export.ok == false)
        #expect((export.error ?? "").contains("No session manifest found"))
    }
}

@Test
func brokerMarkdownExportSkipsActiveSessionsOwnedByOtherBrokers() async throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-other-broker-export-\(UUID().uuidString)", isDirectory: true)
    let sessionRootURL = rootURL.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let owner = try await AgentBrokerService(
        storePath: rootURL.appendingPathComponent("owner-memory.wax").path,
        sessionRootPath: sessionRootURL.path,
        noEmbedder: true,
        embedderChoice: "auto",
        requireVector: false
    )
    defer { Task { try? await owner.close() } }

    let started = await owner.handle(.init(command: "session_start"))
    #expect(started.ok == true)
    let sessionID = try #require(started.payload?.objectValue?["session_id"]?.stringValue)
    let foreignDream = "Decision: other broker export should not open this active session \(UUID().uuidString)"
    let remembered = await owner.handle(.init(
        command: "remember",
        arguments: [
            "content": .string(foreignDream),
            "session_id": .string(sessionID),
        ]
    ))
    #expect(remembered.ok == true)

    let exporter = try await AgentBrokerService(
        storePath: rootURL.appendingPathComponent("exporter-memory.wax").path,
        sessionRootPath: sessionRootURL.path,
        noEmbedder: true,
        embedderChoice: "auto",
        requireVector: false
    )
    defer { Task { try? await exporter.close() } }

    let outputURL = rootURL.appendingPathComponent("markdown-export", isDirectory: true)
    let export = await exporter.handle(.init(
        command: "markdown_export",
        arguments: ["output_dir": .string(outputURL.path)]
    ))

    #expect(export.ok == true)
    let exportPayload = try #require(export.payload?.objectValue)
    if let dreamsPath = exportPayload["dreams_path"]?.stringValue {
        let dreamsText = try String(contentsOf: URL(fileURLWithPath: dreamsPath), encoding: .utf8)
        #expect(!dreamsText.contains(foreignDream))
    }

    let scopedExport = await exporter.handle(.init(
        command: "markdown_export",
        arguments: [
            "output_dir": .string(rootURL.appendingPathComponent("scoped-export", isDirectory: true).path),
            "session_id": .string(sessionID),
        ]
    ))
    #expect(scopedExport.ok == false)
    #expect((scopedExport.error ?? "").contains("active in another broker process"))

    let get = await owner.handle(.init(
        command: "memory_search",
        arguments: [
            "query": .string("other broker export should not open"),
            "session_id": .string(sessionID),
            "mode": .string("text"),
        ]
    ))
    #expect(get.ok == true)
}

@Test
func brokerRememberRejectsDurableTaskStateBeforeMarkdownExport() async throws {
    try await withAgentBrokerService { service, _ in
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-markdown-stored-type-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let content = "Decision: keep this exported as task state \(UUID().uuidString)"
        let remember = await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string(content),
                "memory_type": .string("task_state"),
                "durability": .string("durable"),
                "reviewed": .bool(true),
            ]
        ))
        #expect(remember.ok == false)
        #expect((remember.error ?? "").contains("task_state"))

        let export = await service.handle(.init(
            command: "markdown_export",
            arguments: [
                "output_dir": .string(outputURL.path),
            ]
        ))
        #expect(export.ok == true)
        let payload = try #require(export.payload?.objectValue)
        let memoryPath = try #require(payload["memory_md_path"]?.stringValue)
        let markdown = try String(contentsOfFile: memoryPath, encoding: .utf8)
        #expect(!markdown.contains("## task_state"))
        #expect(!markdown.contains(content))
    }
}

@Test
func brokerMarkdownExportRemovesStaleGeneratedFiles() async throws {
    try await withAgentBrokerService { service, _ in
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-markdown-stale-files-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let first = await service.handle(.init(command: "session_start"))
        #expect(first.ok == true)
        let firstSessionID = try #require(first.payload?.objectValue?["session_id"]?.stringValue)
        let remembered = await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("Decision: stale generated Markdown files must be removed \(UUID().uuidString)"),
                "session_id": .string(firstSessionID),
            ]
        ))
        #expect(remembered.ok == true)
        let handoff = await service.handle(.init(
            command: "handoff",
            arguments: [
                "content": .string("Stale generated handoff \(UUID().uuidString)"),
                "session_id": .string(firstSessionID),
            ]
        ))
        #expect(handoff.ok == true)

        let firstExport = await service.handle(.init(
            command: "markdown_export",
            arguments: [
                "output_dir": .string(outputURL.path),
                "session_id": .string(firstSessionID),
            ]
        ))
        #expect(firstExport.ok == true)
        let firstPayload = try #require(firstExport.payload?.objectValue)
        let staleDreamsPath = try #require(firstPayload["dreams_path"]?.stringValue)
        let staleHandoffPath = try #require(firstPayload["handoff_summary_path"]?.stringValue)
        let staleDailyPath = try #require(firstPayload["daily_note_paths"]?.arrayValue?.first?.stringValue)
        let userNotesURL = URL(fileURLWithPath: staleDailyPath)
            .deletingLastPathComponent()
            .appendingPathComponent("project-notes.md")
        try String(contentsOfFile: staleDailyPath, encoding: .utf8)
            .write(to: userNotesURL, atomically: true, encoding: .utf8)
        #expect(FileManager.default.fileExists(atPath: staleDreamsPath))
        #expect(FileManager.default.fileExists(atPath: staleHandoffPath))
        #expect(FileManager.default.fileExists(atPath: staleDailyPath))
        #expect(FileManager.default.fileExists(atPath: userNotesURL.path))

        let second = await service.handle(.init(command: "session_start"))
        #expect(second.ok == true)
        let secondSessionID = try #require(second.payload?.objectValue?["session_id"]?.stringValue)
        let secondExport = await service.handle(.init(
            command: "markdown_export",
            arguments: [
                "output_dir": .string(outputURL.path),
                "session_id": .string(secondSessionID),
            ]
        ))
        #expect(secondExport.ok == true)
        let secondPayload = try #require(secondExport.payload?.objectValue)
        #expect(secondPayload["dreams_path"]?.stringValue == nil)
        #expect(secondPayload["handoff_summary_path"]?.stringValue == nil)
        #expect(secondPayload["daily_note_paths"]?.arrayValue?.isEmpty == true)
        #expect(!FileManager.default.fileExists(atPath: staleDreamsPath))
        #expect(!FileManager.default.fileExists(atPath: staleHandoffPath))
        #expect(!FileManager.default.fileExists(atPath: staleDailyPath))
        #expect(FileManager.default.fileExists(atPath: userNotesURL.path))
    }
}

@Test
func brokerMarkdownExportPreservesCheckedStaleDreams() async throws {
    try await withAgentBrokerService { service, _ in
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-markdown-checked-dream-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let first = await service.handle(.init(command: "session_start"))
        #expect(first.ok == true)
        let firstSessionID = try #require(first.payload?.objectValue?["session_id"]?.stringValue)
        let dream = "Decision: preserve checked DREAMS approvals across empty export \(UUID().uuidString)"
        let remembered = await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string(dream),
                "session_id": .string(firstSessionID),
            ]
        ))
        #expect(remembered.ok == true)

        let firstExport = await service.handle(.init(
            command: "markdown_export",
            arguments: [
                "output_dir": .string(outputURL.path),
                "session_id": .string(firstSessionID),
            ]
        ))
        #expect(firstExport.ok == true)
        let firstPayload = try #require(firstExport.payload?.objectValue)
        let dreamsPath = try #require(firstPayload["dreams_path"]?.stringValue)
        let dreamsURL = URL(fileURLWithPath: dreamsPath)
        var dreamsText = try String(contentsOf: dreamsURL, encoding: .utf8)
        dreamsText = dreamsText.replacingOccurrences(of: "- [ ] \(dream)", with: "- [x] \(dream)")
        try dreamsText.write(to: dreamsURL, atomically: true, encoding: .utf8)

        let second = await service.handle(.init(command: "session_start"))
        #expect(second.ok == true)
        let secondSessionID = try #require(second.payload?.objectValue?["session_id"]?.stringValue)
        let secondExport = await service.handle(.init(
            command: "markdown_export",
            arguments: [
                "output_dir": .string(outputURL.path),
                "session_id": .string(secondSessionID),
            ]
        ))
        #expect(secondExport.ok == true)
        let secondPayload = try #require(secondExport.payload?.objectValue)
        #expect(secondPayload["dreams_path"]?.stringValue == nil)
        #expect(FileManager.default.fileExists(atPath: dreamsPath))
        #expect(try String(contentsOf: dreamsURL, encoding: .utf8).contains("- [x] \(dream)"))
    }
}

@Test
func brokerMarkdownExportPreservesStaleDreamsWithUserProse() async throws {
    try await withAgentBrokerService { service, _ in
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-markdown-prose-dream-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let first = await service.handle(.init(command: "session_start"))
        #expect(first.ok == true)
        let firstSessionID = try #require(first.payload?.objectValue?["session_id"]?.stringValue)
        let dream = "Decision: preserve prose in stale DREAMS files \(UUID().uuidString)"
        let remembered = await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string(dream),
                "session_id": .string(firstSessionID),
            ]
        ))
        #expect(remembered.ok == true)

        let firstExport = await service.handle(.init(
            command: "markdown_export",
            arguments: [
                "output_dir": .string(outputURL.path),
                "session_id": .string(firstSessionID),
            ]
        ))
        #expect(firstExport.ok == true)
        let firstPayload = try #require(firstExport.payload?.objectValue)
        let dreamsPath = try #require(firstPayload["dreams_path"]?.stringValue)
        let dreamsURL = URL(fileURLWithPath: dreamsPath)
        var dreamsText = try String(contentsOf: dreamsURL, encoding: .utf8)
        let prose = "Pending: verify this before deleting."
        dreamsText += "\n\(prose)\n"
        try dreamsText.write(to: dreamsURL, atomically: true, encoding: .utf8)

        let second = await service.handle(.init(command: "session_start"))
        #expect(second.ok == true)
        let secondSessionID = try #require(second.payload?.objectValue?["session_id"]?.stringValue)
        let secondExport = await service.handle(.init(
            command: "markdown_export",
            arguments: [
                "output_dir": .string(outputURL.path),
                "session_id": .string(secondSessionID),
            ]
        ))
        #expect(secondExport.ok == true)
        #expect(FileManager.default.fileExists(atPath: dreamsPath))
        #expect(try String(contentsOf: dreamsURL, encoding: .utf8).contains(prose))
    }
}

@Test
func brokerMarkdownSyncDoesNotTrustFrameIDWithMismatchedMarkerHash() async throws {
    try await withAgentBrokerService { service, _ in
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-markdown-marker-trust-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let protected = "Protected F182 marker trust fact \(UUID().uuidString)"
        let tampered = "Tampered F182 marker trust replacement \(UUID().uuidString)"

        let remember = await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string(protected),
                "memory_type": .string("fact"),
                "durability": .string("durable"),
            ]
        ))
        #expect(remember.ok == true)

        let export = await service.handle(.init(
            command: "markdown_export",
            arguments: ["output_dir": .string(rootURL.path)]
        ))
        #expect(export.ok == true)
        let exportPayload = try #require(export.payload?.objectValue)
        let memoryPath = try #require(exportPayload["memory_md_path"]?.stringValue)
        let memoryURL = URL(fileURLWithPath: memoryPath)
        let exportedEntry = try #require(
            BrokerMarkdownSync.parseFile(at: memoryURL).first { $0.text == protected }
        )
        var marker = try #require(exportedEntry.marker)
        let protectedMemoryID = try #require(marker.memoryID)
        marker.hash = AgentBrokerService.stableHash("not the protected memory \(UUID().uuidString)")
        let tamperedLine = "- \(tampered) \(BrokerMarkdownSync.markerComment(marker))"
        try """
        # MEMORY

        ## fact
        \(tamperedLine)
        """.write(to: memoryURL, atomically: true, encoding: .utf8)

        let sync = await service.handle(.init(
            command: "markdown_sync",
            arguments: ["root_dir": .string(rootURL.path)]
        ))
        #expect(sync.ok == true)
        let syncPayload = try #require(sync.payload?.objectValue)
        let counts = try #require(syncPayload["counts"]?.objectValue)
        #expect(counts["updated"]?.intValue == 0)
        #expect(counts["deleted"]?.intValue == 0)

        let get = await service.handle(.init(
            command: "memory_get",
            arguments: ["memory_id": .string(protectedMemoryID)]
        ))
        #expect(get.ok == true)
        let getPayload = try #require(get.payload?.objectValue)
        #expect(getPayload["text"]?.stringValue == protected)
    }
}

@Test
func brokerMarkdownSyncDoesNotDeleteLockedMemoryWhenLineRemoved() async throws {
    try await withAgentBrokerService { service, _ in
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-markdown-locked-delete-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let lockedContent = "Locked F183 markdown memory \(UUID().uuidString)"

        let remember = await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string(lockedContent),
                "memory_type": .string("fact"),
                "durability": .string("locked"),
            ]
        ))
        #expect(remember.ok == true)

        let export = await service.handle(.init(
            command: "markdown_export",
            arguments: ["output_dir": .string(rootURL.path)]
        ))
        #expect(export.ok == true)
        let exportPayload = try #require(export.payload?.objectValue)
        let memoryPath = try #require(exportPayload["memory_md_path"]?.stringValue)
        let memoryURL = URL(fileURLWithPath: memoryPath)

        let firstSync = await service.handle(.init(
            command: "markdown_sync",
            arguments: ["root_dir": .string(rootURL.path)]
        ))
        #expect(firstSync.ok == true)

        let refreshedExport = await service.handle(.init(
            command: "markdown_export",
            arguments: ["output_dir": .string(rootURL.path)]
        ))
        #expect(refreshedExport.ok == true)
        let lockedEntry = try #require(
            BrokerMarkdownSync.parseFile(at: memoryURL).first { $0.text == lockedContent }
        )
        let lockedMemoryID = try #require(lockedEntry.marker?.memoryID)

        try """
        # MEMORY

        ## fact
        """.write(to: memoryURL, atomically: true, encoding: .utf8)

        let secondSync = await service.handle(.init(
            command: "markdown_sync",
            arguments: ["root_dir": .string(rootURL.path)]
        ))
        #expect(secondSync.ok == true)
        let secondPayload = try #require(secondSync.payload?.objectValue)
        let counts = try #require(secondPayload["counts"]?.objectValue)
        #expect(counts["deleted"]?.intValue == 0)

        let get = await service.handle(.init(
            command: "memory_get",
            arguments: ["memory_id": .string(lockedMemoryID)]
        ))
        #expect(get.ok == true)
        let getPayload = try #require(get.payload?.objectValue)
        #expect(getPayload["text"]?.stringValue == lockedContent)
        #expect(getPayload["metadata"]?.objectValue?[MemoryMetadataKeys.durability]?.stringValue == MemoryDurability.locked.rawValue)
    }
}

@Test
func brokerRetrievalEventsPersistQueryHashWithoutRawQuery() async throws {
    try await withAgentBrokerService { service, sessionRootURL in
        let started = await service.handle(.init(command: "session_start"))
        let startedPayload = try #require(started.payload?.objectValue)
        let sessionIDString = try #require(startedPayload["session_id"]?.stringValue)
        let sessionID = try #require(UUID(uuidString: sessionIDString))
        let query = "QUERY_LOG_PRIVACY_ANCHOR"

        let append = await service.handle(.init(
            command: "memory_append",
            arguments: [
                "content": .string("Remember \(query) without storing raw retrieval queries."),
                "session_id": .string(sessionIDString),
            ]
        ))
        #expect(append.ok == true)

        let search = await service.handle(.init(
            command: "search",
            arguments: [
                "query": .string(query),
                "mode": .string("text"),
                "topK": .int(5),
                "session_id": .string(sessionIDString),
            ]
        ))
        #expect(search.ok == true)

        let manifest = try BrokerSessionPersistence.loadManifest(rootURL: sessionRootURL, sessionID: sessionID)
        let events = try BrokerSessionPersistence.loadEvents(from: URL(fileURLWithPath: manifest.eventLogPath))
        let retrievalEvents = events.filter { $0.kind == .retrievalHit }
        #expect(!retrievalEvents.isEmpty)
        for event in retrievalEvents {
            #expect(event.payload["query"] == nil)
            #expect(event.payload["query_hash"] != nil)
        }
    }
}

@Test
func brokerSessionStartAppendsStartedEventBeforeSavingManifest() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let source = try String(
        contentsOf: repoRoot.appendingPathComponent("Sources/Wax/Broker/VirtualSessionStore.swift"),
        encoding: .utf8
    )
    let start = try #require(source.range(of: "private func mintNewSession("))
    let end = try #require(source[start.upperBound...].range(of: "private func abandonUnusedSessionFile("))
    let body = source[start.lowerBound..<end.lowerBound]

    let appendEvent = try #require(body.range(of: "BrokerSessionPersistence.appendEvent("))
    let saveManifest = try #require(body.range(of: "BrokerSessionPersistence.saveManifest(manifest, to: manifestURL)"))
    #expect(appendEvent.lowerBound < saveManifest.lowerBound)
}

@Test
func brokerSessionResumeAppendsResumedEventBeforeSavingLease() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let source = try String(
        contentsOf: repoRoot.appendingPathComponent("Sources/Wax/Broker/VirtualSessionStore.swift"),
        encoding: .utf8
    )
    let start = try #require(source.range(of: "package func resume("))
    let end = try #require(source[start.upperBound...].range(of: "package func end("))
    let body = source[start.lowerBound..<end.lowerBound]

    let appendEvent = try #require(body.range(of: "BrokerSessionPersistence.appendEvent("))
    let saveManifest = try #require(body.range(of: "BrokerSessionPersistence.saveManifest(refreshed, to: manifestURL)"))
    #expect(appendEvent.lowerBound < saveManifest.lowerBound)
}

@Test
func brokerSessionEndKeepsActiveSessionUntilPersistenceSucceeds() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let source = try String(
        contentsOf: repoRoot.appendingPathComponent("Sources/Wax/Broker/VirtualSessionStore.swift"),
        encoding: .utf8
    )
    let start = try #require(source.range(of: "private func endSerialized("))
    let end = try #require(source[start.upperBound...].range(of: "package func lookup("))
    let body = source[start.lowerBound..<end.lowerBound]

    let flush = try #require(body.range(of: "try await target.state.memory.flush()"))
    let saveManifest = try #require(body.range(of: "BrokerSessionPersistence.saveManifest(state.manifest, to: state.manifestURL)"))
    let appendEvent = try #require(body.range(of: "BrokerSessionPersistence.appendEvent("))
    let close = try #require(body.range(of: "try await target.state.memory.close()"))
    let remove = try #require(body.range(of: "_live.removeValue(forKey: target.id)"))

    #expect(flush.lowerBound < remove.lowerBound)
    #expect(saveManifest.lowerBound < remove.lowerBound)
    #expect(appendEvent.lowerBound < remove.lowerBound)
    #expect(close.lowerBound < remove.lowerBound)
}

@Test
func brokerRememberAppendsSessionEventBeforeFlushingMemory() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let source = try String(
        contentsOf: repoRoot.appendingPathComponent("Sources/Wax/Broker/AgentBrokerService.swift"),
        encoding: .utf8
    )
    let start = try #require(source.range(of: "func completeRemember("))
    let end = try #require(source[start.upperBound...].range(of: "func recall(_ command: BrokerCommand.Recall)"))
    let body = source[start.lowerBound..<end.lowerBound]

    let appendEvent = try #require(body.range(of: "appendSessionEvent("))
    let flush = try #require(body.range(of: "try await memory.flush()"))
    #expect(appendEvent.lowerBound < flush.lowerBound)
}

@Test
func brokerHandoffRecordsEventBeforeCommittingHandoffFrame() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let source = try String(
        contentsOf: repoRoot.appendingPathComponent("Sources/Wax/Broker/AgentBrokerService.swift"),
        encoding: .utf8
    )
    let start = try #require(source.range(of: "func handoff(_ command: BrokerCommand.Handoff)"))
    let end = try #require(source[start.upperBound...].range(of: "func handoffLatest(_ command: BrokerCommand.HandoffLatest)"))
    let body = source[start.lowerBound..<end.lowerBound]

    #expect(body.contains("commit: false"))
    let recordHandoff = try #require(body.range(of: "recordHandoff(sessionID: sessionID, content: content)"))
    let flush = try #require(body.range(of: "try await longTermMemory.flush()"))
    #expect(recordHandoff.lowerBound < flush.lowerBound)
}

@Test
func brokerHandoffAppendsEventBeforeSavingHandoffManifest() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let source = try String(
        contentsOf: repoRoot.appendingPathComponent("Sources/Wax/Broker/AgentBrokerService.swift"),
        encoding: .utf8
    )
    let start = try #require(source.range(of: "func recordHandoff(sessionID: UUID, content: String)"))
    let end = try #require(source[start.upperBound...].range(of: "func recordCheckpoint(sessionID: UUID, summary: String, compactedText: String)"))
    let body = source[start.lowerBound..<end.lowerBound]

    let appendEvent = try #require(body.range(of: "appendSessionEvent("))
    let persistManifest = try #require(body.range(of: "virtualSessions.updateLive(sessionID)"))
    #expect(appendEvent.lowerBound < persistManifest.lowerBound)
}

@Test
func brokerKnowledgeCaptureStagesMemoryBeforeGraphWrites() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let source = try String(
        contentsOf: repoRoot.appendingPathComponent("Sources/Wax/Broker/AgentBrokerService.swift"),
        encoding: .utf8
    )
    let start = try #require(source.range(of: "func knowledgeCapture(_ command: BrokerCommand.KnowledgeCapture)"))
    let end = try #require(source[start.upperBound...].range(of: "func stats(_ command: BrokerCommand.Stats"))
    let body = source[start.lowerBound..<end.lowerBound]

    let remember = try #require(body.range(of: "try await longTermMemory.remember(command.content, metadata: metadata)"))
    let upsert = try #require(body.range(of: "longTermMemory.upsertEntity("))
    let assertFact = try #require(body.range(of: "longTermMemory.assertFact("))
    let flush = try #require(body.range(of: "try await longTermMemory.flush()"))

    #expect(remember.lowerBound < upsert.lowerBound)
    #expect(remember.lowerBound < assertFact.lowerBound)
    #expect(upsert.lowerBound < flush.lowerBound)
    #expect(assertFact.lowerBound < flush.lowerBound)
    #expect(body.contains("commit: false"))
    #expect(!body.contains("commit: true"))
}

@Test
func brokerDreamProjectionAwaitsOpenedSessionStoreClose() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    let source = try String(
        contentsOf: repoRoot.appendingPathComponent("Sources/Wax/Broker/AgentBrokerService+Markdown.swift"),
        encoding: .utf8
    )
    let start = try #require(source.range(of: "func dreamProjectionLines(sessionID filterSessionID: UUID?, project: String? = nil) async throws -> [String]"))
    let end = try #require(source[start.upperBound...].range(of: "private func merge("))
    let body = source[start.lowerBound..<end.lowerBound]

    #expect(!body.contains("Task { try? await sessionMemory.close() }"))
    #expect(body.contains("try await sessionMemory.close()"))
}

@Test
func brokerSessionAppendEventThrowsWhenFirstEventFileCannotBeCreated() throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-event-create-failure-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let event = BrokerSessionEvent(
        sessionID: UUID(),
        agentID: "agent",
        runID: "run",
        timestampMs: 1,
        kind: .started
    )
    let missingParentEventURL = rootURL
        .appendingPathComponent("missing", isDirectory: true)
        .appendingPathComponent("session.events.jsonl")

    #expect(throws: (any Error).self) {
        try BrokerSessionPersistence.appendEvent(event, to: missingParentEventURL)
    }
}

@Test
func brokerSessionLoadEventsSkipsMalformedJSONLLines() throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-event-malformed-line-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let eventLogURL = rootURL.appendingPathComponent("session.events.jsonl")
    let first = BrokerSessionEvent(
        sessionID: UUID(),
        agentID: "agent",
        runID: "run",
        timestampMs: 1,
        kind: .started
    )
    let second = BrokerSessionEvent(
        sessionID: first.sessionID,
        agentID: "agent",
        runID: "run",
        timestampMs: 2,
        kind: .resumed
    )

    try BrokerSessionPersistence.appendEvent(first, to: eventLogURL)
    let handle = try FileHandle(forWritingTo: eventLogURL)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("not-json\n".utf8))
    try BrokerSessionPersistence.appendEvent(second, to: eventLogURL)

    let events = try BrokerSessionPersistence.loadEvents(from: eventLogURL)
    #expect(events.map(\.kind) == [.started, .resumed])
}

@Test
func brokerSessionListManifestsSkipsMalformedStrayJSON() throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-manifest-malformed-stray-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let olderID = UUID()
    let newerID = UUID()
    let older = BrokerSessionManifest(
        sessionID: olderID,
        agentID: "agent",
        runID: "older",
        project: nil,
        repo: nil,
        storePath: rootURL.appendingPathComponent("older.wax").path,
        eventLogPath: rootURL.appendingPathComponent("older.events.jsonl").path,
        status: .active,
        brokerLeaseOwnerID: "broker",
        leaseExpiresAtMs: 2,
        createdAtMs: 1,
        updatedAtMs: 1
    )
    let newer = BrokerSessionManifest(
        sessionID: newerID,
        agentID: "agent",
        runID: "newer",
        project: nil,
        repo: nil,
        storePath: rootURL.appendingPathComponent("newer.wax").path,
        eventLogPath: rootURL.appendingPathComponent("newer.events.jsonl").path,
        status: .active,
        brokerLeaseOwnerID: "broker",
        leaseExpiresAtMs: 3,
        createdAtMs: 2,
        updatedAtMs: 2
    )
    try BrokerSessionPersistence.saveManifest(older, to: BrokerSessionPersistence.manifestURL(rootURL: rootURL, sessionID: olderID))
    try BrokerSessionPersistence.saveManifest(newer, to: BrokerSessionPersistence.manifestURL(rootURL: rootURL, sessionID: newerID))
    let corruptManifestURL = rootURL.appendingPathComponent("stray.json")
    try Data("{not valid json".utf8).write(to: corruptManifestURL)

    let manifests = try BrokerSessionPersistence.listManifests(rootURL: rootURL)
    #expect(manifests.map(\.sessionID) == [newerID, olderID])
    #expect(throws: (any Error).self) {
        try BrokerSessionPersistence.loadManifest(at: corruptManifestURL)
    }
}

@Test
func brokerSessionListManifestsPropagatesMalformedSessionManifest() throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-manifest-malformed-session-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let sessionID = UUID()
    let corruptManifestURL = BrokerSessionPersistence.manifestURL(rootURL: rootURL, sessionID: sessionID)
    try Data("{not valid json".utf8).write(to: corruptManifestURL)

    #expect(throws: (any Error).self) {
        _ = try BrokerSessionPersistence.listManifests(rootURL: rootURL)
    }
}

@Test
func brokerSessionLoadManifestMissingUUIDDoesNotLeakPath() throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-manifest-missing-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let sessionID = UUID()
    do {
        _ = try BrokerSessionPersistence.loadManifest(rootURL: rootURL, sessionID: sessionID)
        Issue.record("missing manifest should throw")
    } catch let error as BrokerSessionPersistenceError {
        #expect(error == .manifestNotFound(sessionID: sessionID))
        let description = error.localizedDescription
        #expect(description == "No session manifest found for session_id \(sessionID.uuidString)")
        #expect(!description.contains("/Users/"))
        #expect(!description.contains("/home/"))
        #expect(!description.contains("~/.wax"))
        #expect(!description.contains(".json"))
    }
}

@Test
func brokerRememberPreservesContentWhitespace() async throws {
    try await withAgentBrokerService { service, _ in
        let content = "  WHITESPACE_KEEP_TOKEN\n"
        let append = await service.handle(.init(
            command: "memory_append",
            arguments: ["content": .string(content)]
        ))
        #expect(append.ok == true)

        let search = await service.handle(.init(
            command: "memory_search",
            arguments: [
                "query": .string("WHITESPACE_KEEP_TOKEN"),
                "mode": .string("text"),
                "topK": .int(1),
            ]
        ))
        #expect(search.ok == true)
        let searchPayload = try #require(search.payload?.objectValue)
        let results = try #require(searchPayload["results"]?.arrayValue)
        let first = try #require(results.first?.objectValue)
        let memoryID = try #require(first["memory_id"]?.stringValue)

        let get = await service.handle(.init(
            command: "memory_get",
            arguments: ["memory_id": .string(memoryID)]
        ))
        #expect(get.ok == true)
        let getPayload = try #require(get.payload?.objectValue)
        #expect(getPayload["text"]?.stringValue == content)

        let handoffContent = "  HANDOFF_KEEP_TOKEN\n"
        let handoff = await service.handle(.init(
            command: "handoff",
            arguments: [
                "content": .string(handoffContent),
                "project": .string("whitespace-project"),
            ]
        ))
        #expect(handoff.ok == true)

        let latest = await service.handle(.init(
            command: "handoff_latest",
            arguments: ["project": .string("whitespace-project")]
        ))
        #expect(latest.ok == true)
        let latestPayload = try #require(latest.payload?.objectValue)
        #expect(latestPayload["content"]?.stringValue == handoffContent)
    }
}

@Test
func brokerBackedF152CompactContextScopesToRequestedSession() async throws {
    try await withAgentBrokerService { service, _ in
        let startA = await service.handle(.init(command: "session_start"))
        #expect(startA.ok == true)
        let sessionA = try #require(startA.payload?.objectValue?["session_id"]?.stringValue)

        let startB = await service.handle(.init(command: "session_start"))
        #expect(startB.ok == true)
        let sessionB = try #require(startB.payload?.objectValue?["session_id"]?.stringValue)

        let durable = await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("BROKER_F152_COMPACT_SCOPE durable memory can appear only as long context."),
                "durability": .string("durable"),
            ]
        ))
        #expect(durable.ok == true)

        let sessionAWrite = await service.handle(.init(
            command: "memory_append",
            arguments: [
                "content": .string("BROKER_F152_COMPACT_SCOPE session A working memory should compact for session A."),
                "session_id": .string(sessionA),
            ]
        ))
        #expect(sessionAWrite.ok == true)

        let sessionBWrite = await service.handle(.init(
            command: "memory_append",
            arguments: [
                "content": .string("BROKER_F152_COMPACT_SCOPE session B working memory must not leak into session A short context."),
                "session_id": .string(sessionB),
            ]
        ))
        #expect(sessionBWrite.ok == true)

        let compact = await service.handle(.init(
            command: "compact_context",
            arguments: [
                "query": .string("BROKER_F152_COMPACT_SCOPE"),
                "session_id": .string(sessionA),
                "mode": .string("text"),
                "max_items": .int(6),
                "token_budget": .int(512),
            ]
        ))
        #expect(compact.ok == true)
        let compactPayload = try #require(compact.payload?.objectValue)
        let shortContext = try #require(compactPayload["short_context"]?.arrayValue)
        #expect(shortContext.contains { entry in
            guard let object = entry.objectValue else { return false }
            return object["preview"]?.stringValue?.contains("session A working memory should compact") == true
        })
        #expect(!shortContext.contains { entry in
            guard let object = entry.objectValue else { return false }
            return object["preview"]?.stringValue?.contains("session B working memory must not leak") == true
        })
        #expect(shortContext.allSatisfy { entry in
            guard let object = entry.objectValue,
                  let memoryID = object["memory_id"]?.stringValue else { return false }
            return memoryID.hasPrefix("working:\(sessionA):")
        })
        let shortMemoryIDs = shortContext.compactMap { $0.objectValue?["memory_id"]?.stringValue }
        #expect(shortMemoryIDs.count == Set(shortMemoryIDs).count)

        let longContext = try #require(compactPayload["long_context"]?.arrayValue)
        #expect(longContext.contains { entry in
            guard let object = entry.objectValue else { return false }
            return object["preview"]?.stringValue?.contains("durable memory can appear only as long context") == true
        })
        let longMemoryIDs = longContext.compactMap { $0.objectValue?["memory_id"]?.stringValue }
        #expect(longMemoryIDs.count == Set(longMemoryIDs).count)

        let firstItem = try #require(shortContext.compactMap(\.objectValue).first)
        let memoryID = try #require(firstItem["memory_id"]?.stringValue)
        let get = await service.handle(.init(
            command: "memory_get",
            arguments: ["memory_id": .string(memoryID)]
        ))
        #expect(get.ok == true)
        let getPayload = try #require(get.payload?.objectValue)
        #expect(getPayload["text"]?.stringValue?.contains("session A working memory should compact") == true)

        let firstLongItem = try #require(longContext.compactMap(\.objectValue).first)
        let longMemoryID = try #require(firstLongItem["memory_id"]?.stringValue)
        let getLong = await service.handle(.init(
            command: "memory_get",
            arguments: ["memory_id": .string(longMemoryID)]
        ))
        #expect(getLong.ok == true)
        let getLongPayload = try #require(getLong.payload?.objectValue)
        #expect(getLongPayload["text"]?.stringValue?.contains("durable memory can appear only as long context") == true)
    }
}

@Test
func brokerCompactContextEmitsCanonicalDocumentMemoryIDsForChunkHits() async throws {
    try await withAgentBrokerService { service, _ in
        let started = await service.handle(.init(command: "session_start"))
        #expect(started.ok == true)
        let sessionIDString = try #require(started.payload?.objectValue?["session_id"]?.stringValue)
        let sessionID = try #require(UUID(uuidString: sessionIDString))
        let state = try #require(await service.activeSessions[sessionID])

        let anchor = "F194_CHUNK_CANONICAL_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let content = Array(
            repeating: "\(anchor) compact context must return document memory ids instead of chunk frame ids.",
            count: 90
        ).joined(separator: " ")
        let append = await service.handle(.init(
            command: "memory_append",
            arguments: [
                "content": .string(content),
                "session_id": .string(sessionIDString),
            ]
        ))
        #expect(append.ok == true)

        let rawSearch = await service.handle(.init(
            command: "search",
            arguments: [
                "query": .string(anchor),
                "session_id": .string(sessionIDString),
                "mode": .string("text"),
                "topK": .int(12),
            ]
        ))
        #expect(rawSearch.ok == true)
        let rawResults = try #require(rawSearch.payload?.objectValue?["results"]?.arrayValue)
        var rawChunkFrameIDs = Set<UInt64>()
        for result in rawResults {
            guard let rawID = result.objectValue?["frameId"]?.intValue.map(UInt64.init) else { continue }
            let meta = try await state.memory.wax.frameMetaIncludingPending(frameId: rawID)
            if meta.role == .chunk {
                rawChunkFrameIDs.insert(rawID)
            }
        }
        #expect(!rawChunkFrameIDs.isEmpty)

        let compact = await service.handle(.init(
            command: "compact_context",
            arguments: [
                "query": .string(anchor),
                "session_id": .string(sessionIDString),
                "mode": .string("text"),
                "max_items": .int(6),
                "token_budget": .int(512),
            ]
        ))
        #expect(compact.ok == true)
        let compactPayload = try #require(compact.payload?.objectValue)
        let shortContext = try #require(compactPayload["short_context"]?.arrayValue)
        #expect(!shortContext.isEmpty)

        for item in shortContext {
            let object = try #require(item.objectValue)
            let memoryID = try #require(object["memory_id"]?.stringValue)
            let frameID = try #require(object["frame_id"]?.intValue.map(UInt64.init))
            #expect(!rawChunkFrameIDs.contains(frameID))
            let meta = try await state.memory.wax.frameMetaIncludingPending(frameId: frameID)
            #expect(meta.role != .chunk)

            let get = await service.handle(.init(
                command: "memory_get",
                arguments: ["memory_id": .string(memoryID)]
            ))
            #expect(get.ok == true)
            #expect(get.payload?.objectValue?["text"]?.stringValue?.contains(anchor) == true)
        }
    }
}

@Test
func brokerCompactContextBudgetsRenderedOutputTokens() async throws {
    try await withAgentBrokerService { service, _ in
        let started = await service.handle(.init(command: "session_start"))
        #expect(started.ok == true)
        let sessionIDString = try #require(started.payload?.objectValue?["session_id"]?.stringValue)
        let anchor = "F195_RENDERED_BUDGET_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"

        for index in 0..<8 {
            let working = await service.handle(.init(
                command: "memory_append",
                arguments: [
                    "content": .string("\(anchor) short working \(index)"),
                    "session_id": .string(sessionIDString),
                ]
            ))
            #expect(working.ok == true)

            let durable = await service.handle(.init(
                command: "remember",
                arguments: [
                    "content": .string("\(anchor) short durable \(index)"),
                    "durability": .string("durable"),
                ]
            ))
            #expect(durable.ok == true)
        }

        let compact = await service.handle(.init(
            command: "compact_context",
            arguments: [
                "query": .string(anchor),
                "session_id": .string(sessionIDString),
                "mode": .string("text"),
                "max_items": .int(64),
                "token_budget": .int(128),
            ]
        ))
        #expect(compact.ok == true)
        let payload = try #require(compact.payload?.objectValue)
        let compactedText = try #require(payload["compacted_text"]?.stringValue)
        let reportedUsedTokens = try #require(payload["used_tokens"]?.intValue)
        let counter = try await TokenCounter.shared()
        let renderedTokens = await counter.count(compactedText)
        #expect(renderedTokens <= 128)
        #expect(reportedUsedTokens == Int64(renderedTokens))
    }
}

@Test
func brokerCompactContextBudgetsLongQueryOnlyRender() async throws {
    try await withAgentBrokerService { service, _ in
        let longQuery = Array(repeating: "F195_LONG_QUERY_BUDGET", count: 220).joined(separator: " ")
        let compact = await service.handle(.init(
            command: "compact_context",
            arguments: [
                "query": .string(longQuery),
                "mode": .string("text"),
                "max_items": .int(4),
                "token_budget": .int(128),
            ]
        ))
        #expect(compact.ok == true)
        let payload = try #require(compact.payload?.objectValue)
        let compactedText = try #require(payload["compacted_text"]?.stringValue)
        let reportedUsedTokens = try #require(payload["used_tokens"]?.intValue)
        let counter = try await TokenCounter.shared()
        let renderedTokens = await counter.count(compactedText)
        #expect(renderedTokens <= 128)
        #expect(reportedUsedTokens == Int64(renderedTokens))
    }
}

@Test
func brokerCompactContextSearchesOlderRelevantEndedSessionsBeforeRecencyCutoff() async throws {
    try await withAgentBrokerService { service, _ in
        let anchor = "F196_OLDER_RELEVANT_SESSION_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"

        let relevantStart = await service.handle(.init(command: "session_start"))
        #expect(relevantStart.ok == true)
        let relevantSessionID = try #require(relevantStart.payload?.objectValue?["session_id"]?.stringValue)
        let relevantWrite = await service.handle(.init(
            command: "memory_append",
            arguments: [
                "content": .string("\(anchor) older ended session should be searched before recency cutoff."),
                "session_id": .string(relevantSessionID),
            ]
        ))
        #expect(relevantWrite.ok == true)
        let relevantEnd = await service.handle(.init(
            command: "session_end",
            arguments: ["session_id": .string(relevantSessionID)]
        ))
        #expect(relevantEnd.ok == true)
        try await Task.sleep(for: .milliseconds(2))

        for index in 0..<4 {
            let start = await service.handle(.init(command: "session_start"))
            #expect(start.ok == true)
            let sessionID = try #require(start.payload?.objectValue?["session_id"]?.stringValue)
            let write = await service.handle(.init(
                command: "memory_append",
                arguments: [
                    "content": .string("F196 irrelevant newer ended session \(index) should not hide the older relevant session."),
                    "session_id": .string(sessionID),
                ]
            ))
            #expect(write.ok == true)
            let end = await service.handle(.init(
                command: "session_end",
                arguments: ["session_id": .string(sessionID)]
            ))
            #expect(end.ok == true)
        }

        let compact = await service.handle(.init(
            command: "compact_context",
            arguments: [
                "query": .string(anchor),
                "mode": .string("text"),
                "max_items": .int(4),
                "token_budget": .int(512),
            ]
        ))
        #expect(compact.ok == true)
        let payload = try #require(compact.payload?.objectValue)
        let mediumContext = try #require(payload["medium_context"]?.arrayValue)
        #expect(mediumContext.contains { entry in
            entry.objectValue?["preview"]?.stringValue?.contains(anchor) == true
        })
    }
}

@Test
func brokerSessionResumeSelectorSkipsEndedManifests() async throws {
    try await withAgentBrokerService { service, _ in
        let first = await service.handle(.init(
            command: "session_start",
            arguments: [
                "agent_id": .string("selector-agent"),
                "run_id": .string("selector-run"),
            ]
        ))
        #expect(first.ok == true)
        let firstPayload = try #require(first.payload?.objectValue)
        let firstSessionID = try #require(firstPayload["session_id"]?.stringValue)

        let ended = await service.handle(.init(
            command: "session_end",
            arguments: ["session_id": .string(firstSessionID)]
        ))
        #expect(ended.ok == true)

        let second = await service.handle(.init(
            command: "session_start",
            arguments: [
                "agent_id": .string("selector-agent"),
                "run_id": .string("selector-run"),
            ]
        ))
        #expect(second.ok == true)
        let secondPayload = try #require(second.payload?.objectValue)
        let secondSessionID = try #require(secondPayload["session_id"]?.stringValue)
        #expect(secondSessionID != firstSessionID)

        let resumed = await service.handle(.init(
            command: "session_resume",
            arguments: [
                "agent_id": .string("selector-agent"),
                "run_id": .string("selector-run"),
            ]
        ))

        #expect(resumed.ok == true)
        let resumedPayload = try #require(resumed.payload?.objectValue)
        #expect(resumedPayload["session_id"]?.stringValue == secondSessionID)
        #expect(resumedPayload["resumed"]?.boolValue == true)
    }
}

@Test
func brokerSessionResumeSelectorSkipsCorruptStrayManifests() async throws {
    try await withAgentBrokerService { service, sessionRootURL in
        let started = await service.handle(.init(
            command: "session_start",
            arguments: [
                "agent_id": .string("corrupt-selector-agent"),
                "run_id": .string("corrupt-selector-run"),
            ]
        ))
        #expect(started.ok == true)
        let startedPayload = try #require(started.payload?.objectValue)
        let sessionIDString = try #require(startedPayload["session_id"]?.stringValue)

        let corruptManifestURL = sessionRootURL.appendingPathComponent("not-a-session.json")
        try Data("{not valid json".utf8).write(to: corruptManifestURL)

        let resumed = await service.handle(.init(
            command: "session_resume",
            arguments: [
                "agent_id": .string("corrupt-selector-agent"),
                "run_id": .string("corrupt-selector-run"),
            ]
        ))

        #expect(resumed.ok == true)
        let resumedPayload = try #require(resumed.payload?.objectValue)
        #expect(resumedPayload["session_id"]?.stringValue == sessionIDString)
        #expect(resumedPayload["resumed"]?.boolValue == true)
    }
}

@Test
func brokerImplicitMemoryPromotePreservesResolvedSessionProvenance() async throws {
    try await withAgentBrokerService { service, sessionRootURL in
        let started = await service.handle(.init(command: "session_start"))
        let startedPayload = try #require(started.payload?.objectValue)
        let sessionIDString = try #require(startedPayload["session_id"]?.stringValue)
        let sessionID = try #require(UUID(uuidString: sessionIDString))

        let append = await service.handle(.init(
            command: "memory_append",
            arguments: [
                "content": .string("Decision: implicit promotion must preserve session provenance."),
                "session_id": .string(sessionIDString),
            ]
        ))
        #expect(append.ok == true)

        let promote = await service.handle(.init(
            command: "memory_promote",
            arguments: ["approve": .bool(true)]
        ))
        #expect(promote.ok == true)
        let promotePayload = try #require(promote.payload?.objectValue)
        #expect(promotePayload["written"]?.boolValue == true)
        let metadata = try #require(promotePayload["metadata"]?.objectValue)
        #expect(metadata[MemoryMetadataKeys.promotedFromSession]?.stringValue == sessionIDString)
        #expect(metadata["session_id"] == nil)

        let manifest = try BrokerSessionPersistence.loadManifest(rootURL: sessionRootURL, sessionID: sessionID)
        let events = try BrokerSessionPersistence.loadEvents(from: URL(fileURLWithPath: manifest.eventLogPath))
        #expect(events.contains { $0.kind == .promotionWritten })
    }
}

@Test
func brokerMemoryPromoteRejectsStaleSessionBeforeDurableWrite() async throws {
    try await withAgentBrokerService { service, _ in
        let started = await service.handle(.init(command: "session_start"))
        let startedPayload = try #require(started.payload?.objectValue)
        let sessionIDString = try #require(startedPayload["session_id"]?.stringValue)

        let ended = await service.handle(.init(
            command: "session_end",
            arguments: ["session_id": .string(sessionIDString)]
        ))
        #expect(ended.ok == true)
        let beforeStats = await service.handle(.init(command: "stats"))
        let beforeFrameCount = try #require(beforeStats.payload?.objectValue?["frameCount"]?.intValue)
        let token = "F179_PROMOTION_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let content = "Decision: Adopt \(token) as the durable release policy."
        let proposal = await service.handle(.init(
            command: "memory_promote",
            arguments: [
                "content": .string(content),
                "memory_type": .string("decision"),
            ]
        ))
        #expect(proposal.ok == true)
        let proposalPayload = try #require(proposal.payload?.objectValue)
        let proposalObject = try #require(proposalPayload["proposal"]?.objectValue)
        #expect(proposalObject["should_write"]?.boolValue == true)

        let promote = await service.handle(.init(
            command: "memory_promote",
            arguments: [
                "session_id": .string(sessionIDString),
                "content": .string(content),
                "memory_type": .string("decision"),
                "approve": .bool(true),
            ]
        ))
        #expect(promote.ok == false)
        let afterStats = await service.handle(.init(command: "stats"))
        let afterFrameCount = try #require(afterStats.payload?.objectValue?["frameCount"]?.intValue)
        #expect(afterFrameCount == beforeFrameCount)

        let search = await service.handle(.init(
            command: "memory_search",
            arguments: [
                "query": .string(token),
                "mode": .string("text"),
                "include_working": .bool(false),
                "include_episodic": .bool(false),
                "include_durable": .bool(true),
                "topK": .int(5),
            ]
        ))
        #expect(search.ok == true)
        let searchPayload = try #require(search.payload?.objectValue)
        let results = try #require(searchPayload["results"]?.arrayValue)
        #expect(results.isEmpty)
    }
}


@Test
func knowledgeCaptureAndMemoryHealthWork() async throws {
    try await withAgentBrokerService { service, _ in
        let capture = await WaxMCPTools.handleCall(
            params: .init(name: "knowledge_capture", arguments: [
                "content": .string("Wax uses a broker-owned long-term store."),
                "subject": .string("project:wax"),
                "kind": .string("project"),
                "predicate": .string("architecture"),
                "object": .string("broker-owned"),
            ]),
            broker: service
        )
        #expect(capture.isError != true)
        let captureJSON = try parseJSONText(in: capture)
        #expect(captureJSON["durability"] as? String == "durable")

        let duplicateA = await WaxMCPTools.handleCall(
            params: .init(name: "remember", arguments: [
                "content": .string("Lesson: keep broker-owned long-term store access single-owner."),
                "memory_type": .string("lesson"),
            ]),
            broker: service
        )
        #expect(duplicateA.isError != true)

        let duplicateB = await WaxMCPTools.handleCall(
            params: .init(name: "remember", arguments: [
                "content": .string("Lesson: keep broker-owned long-term store access single owner."),
                "memory_type": .string("lesson"),
            ]),
            broker: service
        )
        #expect(duplicateB.isError != true)

        let conflictingFact = await WaxMCPTools.handleCall(
            params: .init(name: "fact_assert", arguments: [
                "subject": .string("project:wax"),
                "predicate": .string("architecture"),
                "object": .string("direct-store"),
            ]),
            broker: service
        )
        #expect(conflictingFact.isError != true)

        let health = await WaxMCPTools.handleCall(
            params: .init(name: "memory_health", arguments: [:]),
            broker: service
        )
        #expect(health.isError != true)
        let healthJSON = try parseJSONResource(in: health, uriSuffix: "memory-health-summary")
        let duplicates = healthJSON["duplicate_pairs"] as? [[String: Any]] ?? []
        let contradictions = healthJSON["contradictions"] as? [String] ?? []
        #expect(!duplicates.isEmpty)
        #expect(!contradictions.isEmpty)
    }
}

@Test
func mcpSuccessResultsUseOneDefaultRepresentation() async throws {
    try await withAgentBrokerService { service, _ in
        #expect((await service.handle(.init(
            command: "remember",
            arguments: ["content": .string("DEFAULT_COMPACT_RECALL_MARKER")]
        ))).ok == true)
        for result in [
            await WaxMCPTools.handleCall(
                params: .init(name: "stats", arguments: [:]),
                broker: service
            ),
            await WaxMCPTools.handleCall(
                params: .init(name: "handoff_latest", arguments: [:]),
                broker: service
            ),
            await WaxMCPTools.handleCall(
                params: .init(
                    name: "recall",
                    arguments: [
                        "query": .string("DEFAULT_COMPACT_RECALL_MARKER"),
                        "scope": .string("global"),
                    ]
                ),
                broker: service
            ),
        ] {
            #expect(result.isError != true)
            #expect(result.content.count == 1)
            #expect(result.structuredContent == nil)
            _ = try parseJSONText(in: result)
        }
    }
}

@Test
func compactLifecycleResponsesOmitHostPaths() async throws {
    try await withAgentBrokerService { service, _ in
        for result in [
            await WaxMCPTools.handleCall(
                params: .init(name: "stats", arguments: [:]),
                broker: service
            ),
            await WaxMCPTools.handleCall(
                params: .init(name: "session_start", arguments: [:]),
                broker: service
            ),
        ] {
            let payload = try parseJSONText(in: result)
            #expect(!containsKeyRecursively("storePath", in: payload))
            #expect(!containsKeyRecursively("store_path", in: payload))
            #expect(!containsKeyRecursively("event_log_path", in: payload))
        }
    }
}

@Test
func verboseResultsUseStructuredContentWithoutResourceEcho() async throws {
    try await withAgentBrokerService { service, _ in
        #expect((await service.handle(.init(
            command: "remember",
            arguments: ["content": .string("VERBOSE_SEARCH_MARKER")]
        ))).ok == true)
        let verboseStats = await WaxMCPTools.handleCall(
            params: .init(
                name: "stats",
                arguments: ["verbosity": .string("verbose")]
            ),
            broker: service
        )
        for result in [
            verboseStats,
            await WaxMCPTools.handleCall(
                params: .init(
                    name: "search",
                    arguments: [
                        "query": .string("VERBOSE_SEARCH_MARKER"),
                        "mode": .string("text"),
                        "verbosity": .string("verbose"),
                    ]
                ),
                broker: service
            ),
        ] {
            #expect(result.isError != true)
            #expect(result.content.count == 1)
            #expect(result.structuredContent != nil)
            #expect(result.content.allSatisfy { content in
                if case .resource = content { return false }
                return true
            })
        }
        guard case .object(let statsPayload) = try #require(verboseStats.structuredContent) else {
            Issue.record("Expected verbose stats structured content")
            return
        }
        #expect(statsPayload["storePath"] != nil)
    }
}

@Test
func compactRecallPreservesUserDisplayTextMetadata() async throws {
    try await withAgentBrokerService { service, _ in
        let marker = "USER_DISPLAY_TEXT_MARKER_\(UUID().uuidString)"
        #expect((await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string(marker),
                "metadata": .object(["display_text": .string("user-authored value")]),
            ]
        ))).ok == true)

        let result = await WaxMCPTools.handleCall(
            params: .init(
                name: "recall",
                arguments: [
                    "query": .string(marker),
                    "scope": .string("global"),
                ]
            ),
            broker: service
        )
        let payload = try parseJSONText(in: result)
        let results = try #require(payload["results"] as? [[String: Any]])
        let metadata = try #require(results.first?["metadata"] as? [String: Any])
        #expect(metadata["display_text"] as? String == "user-authored value")
    }
}

@Test
func sessionOpenCompactRecursivelyRemovesDisplayText() async throws {
    try await withAgentBrokerService { service, _ in
        let project = "compact-open-\(UUID().uuidString)"
        #expect((await service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("COMPACT_OPEN_RECALL_MARKER"),
                "project": .string(project),
            ]
        ))).ok == true)
        #expect((await service.handle(.init(
            command: "handoff",
            arguments: [
                "content": .string("Compact open handoff summary."),
                "project": .string(project),
                "pending_tasks": .array([.string("finish compact regression")]),
            ]
        ))).ok == true)

        let opened = await WaxMCPTools.handleCall(
            params: .init(
                name: "session_open",
                arguments: [
                    "project": .string(project),
                    "agent_id": .string("compact-open-agent"),
                    "run_id": .string(UUID().uuidString),
                    "recall_query": .string("COMPACT_OPEN_RECALL_MARKER"),
                    "verbosity": .string("compact"),
                ]
            ),
            broker: service
        )

        #expect(opened.isError != true)
        #expect(opened.content.count == 1)
        let payload = try parseJSONText(in: opened)
        #expect(payload["handoff"] != nil)
        #expect(payload["recall"] != nil)
        #expect(!containsKeyRecursively("display_text", in: payload))
    }
}

@Test
func sessionOpenDefaultsToBoundedHandoffWithoutRecall() async throws {
    try await withAgentBrokerService { service, _ in
        let project = "session-open-bounded-\(UUID().uuidString)"
        let content = String(repeating: "handoff content 🚀 ", count: 400)
        let pendingTasks: [AgentBrokerValue] = (0..<12).map { index in
            .string("task-\(index) " + String(repeating: "待", count: 200))
        }
        #expect((await service.handle(.init(
            command: "handoff",
            arguments: [
                "content": .string(content),
                "project": .string(project),
                "pending_tasks": .array(pendingTasks),
            ]
        ))).ok == true)

        let opened = await WaxMCPTools.handleCall(
            params: .init(
                name: "session_open",
                arguments: [
                    "project": .string(project),
                    "agent_id": .string("bounded-open-agent"),
                    "run_id": .string(UUID().uuidString),
                ]
            ),
            broker: service
        )

        #expect(opened.isError != true)
        let payload = try parseJSONText(in: opened)
        #expect(Set(payload.keys).isSuperset(of: ["session_id", "handoff", "rebound", "share_prompt"]))
        #expect(payload["session_id"] as? String != nil)
        #expect(payload["recall"] == nil)
        let handoff = try requireObject(payload, key: "handoff")
        let compactContent = try requireString(handoff, key: "content")
        let tasks = try requireArray(handoff, key: "pending_tasks")
        #expect(compactContent.utf8.count <= 2_048)
        #expect((handoff["content_bytes"] as? Int ?? 2_049) <= 2_048)
        #expect((handoff["content_tokens"] as? Int ?? 257) <= 256)
        #expect(tasks.count <= 3)
        #expect(tasks.allSatisfy { (($0 as? String)?.utf8.count ?? 257) <= 256 })
        #expect((handoff["truncated"] as? Bool) == true)
        #expect((handoff["pending_tasks_omitted"] as? Int) == 9)
        #expect(handoff["frame_id"] == nil)
        #expect(handoff["timestamp_ms"] == nil)
    }
}

@Test
func sessionOpenCompactHandoffTruncationPreservesUnicodeBoundaries() async throws {
    try await withAgentBrokerService { service, _ in
        let project = "session-open-unicode-\(UUID().uuidString)"
        let content = String(repeating: "🧠", count: 2_000)
        #expect((await service.handle(.init(
            command: "handoff",
            arguments: [
                "content": .string(content),
                "project": .string(project),
            ]
        ))).ok == true)

        let opened = await WaxMCPTools.handleCall(
            params: .init(
                name: "session_open",
                arguments: [
                    "project": .string(project),
                    "agent_id": .string("unicode-open-agent"),
                    "run_id": .string(UUID().uuidString),
                ]
            ),
            broker: service
        )
        let handoff = try requireObject(try parseJSONText(in: opened), key: "handoff")
        let compactContent = try requireString(handoff, key: "content")
        #expect(compactContent.utf8.count <= 2_048)
        let counter = try await TokenCounter.shared()
        #expect(await counter.count(compactContent) <= 256)
        #expect(content.hasPrefix(compactContent))
        #expect(String(data: Data(compactContent.utf8), encoding: .utf8) == compactContent)
        #expect(!compactContent.contains("�"))
        #expect((handoff["content_truncated"] as? Bool) == true)
    }
}

@Test
func sessionOpenExplicitRecallRemainsCapped() async throws {
    try await withAgentBrokerService { service, _ in
        let project = "session-open-recall-\(UUID().uuidString)"
        let marker = "SESSION_OPEN_RECALL_CAP_\(UUID().uuidString)"
        for index in 0..<8 {
            #expect((await service.handle(.init(
                command: "remember",
                arguments: [
                    "content": .string("\(marker) result \(index)"),
                    "project": .string(project),
                ]
            ))).ok == true)
        }

        let opened = await WaxMCPTools.handleCall(
            params: .init(
                name: "session_open",
                arguments: [
                    "project": .string(project),
                    "agent_id": .string("recall-open-agent"),
                    "run_id": .string(UUID().uuidString),
                    "recall_query": .string(marker),
                ]
            ),
            broker: service
        )
        let payload = try parseJSONText(in: opened)
        let recall = try requireObject(payload, key: "recall")
        #expect((recall["limit"] as? Int) == 5)
        #expect((recall["result_count"] as? Int ?? 6) <= 5)
    }
}

@Test
func sessionOpenLeavesFullHandoffLatestExplicitReadUnchanged() async throws {
    try await withAgentBrokerService { service, _ in
        let project = "session-open-full-read-\(UUID().uuidString)"
        let content = "Full handoff content stays on handoff_latest."
        let tasks = ["task one", "task two", "task three", "task four"]
        #expect((await service.handle(.init(
            command: "handoff",
            arguments: [
                "content": .string(content),
                "project": .string(project),
                "pending_tasks": .array(tasks.map { .string($0) }),
            ]
        ))).ok == true)

        let opened = await WaxMCPTools.handleCall(
            params: .init(
                name: "session_open",
                arguments: [
                    "project": .string(project),
                    "agent_id": .string("full-read-agent"),
                    "run_id": .string(UUID().uuidString),
                ]
            ),
            broker: service
        )
        let compactHandoff = try requireObject(try parseJSONText(in: opened), key: "handoff")
        #expect(compactHandoff["frame_id"] == nil)
        #expect(compactHandoff["timestamp_ms"] == nil)

        let latest = await WaxMCPTools.handleCall(
            params: .init(
                name: "handoff_latest",
                arguments: ["project": .string(project)]
            ),
            broker: service
        )
        let latestPayload = try parseJSONText(in: latest)
        #expect(latestPayload["content"] as? String == content)
        #expect((latestPayload["pending_tasks"] as? [String]) == tasks)
        #expect(latestPayload["frame_id"] != nil)
        #expect(latestPayload["timestamp_ms"] != nil)
    }
}

@Test
func invalidArgumentErrorListsAcceptedArguments() async throws {
    try await withAgentBrokerService { service, _ in
        let result = await WaxMCPTools.handleCall(
            params: .init(
                name: "handoff_latest",
                arguments: ["filePath": .string("handoff.json")]
            ),
            broker: service
        )

        #expect(result.isError == true)
        let message = firstText(in: result)
        #expect(message.contains("unsupported argument(s): filePath"))
        #expect(message.contains("valid argument(s): project, verbosity"))

        let malformedVerbosity = await WaxMCPTools.handleCall(
            params: .init(
                name: "stats",
                arguments: ["verbosity": .int(42)]
            ),
            broker: service
        )
        #expect(malformedVerbosity.isError == true)
        #expect(firstText(in: malformedVerbosity).contains("verbosity must be a string"))
    }
}

@Test
func rememberReceiptIdentifiesStoredMemoryAndDeduplication() async throws {
    try await withAgentBrokerService { service, _ in
        let content = "RECEIPT_MARKER-\(UUID().uuidString)"
        let first = await WaxMCPTools.handleCall(
            params: .init(
                name: "remember",
                arguments: [
                    "content": .string(content),
                    "project": .string("Wax"),
                    "memory_type": .string("decision"),
                    "durability": .string("durable"),
                ]
            ),
            broker: service
        )
        let firstJSON = try parseJSONText(in: first)
        #expect((firstJSON["frame_id"] as? Int ?? -1) >= 0)
        #expect((firstJSON["memory_id"] as? String)?.hasPrefix("durable:") == true)
        #expect(firstJSON["scope"] as? String == "durable")
        #expect(firstJSON["memory_type"] as? String == "decision")
        #expect(firstJSON["durability"] as? String == "durable")
        #expect(firstJSON["deduplicated"] as? Bool == false)
        #expect(firstJSON["searchable"] as? Bool == true)

        let repeated = await WaxMCPTools.handleCall(
            params: .init(
                name: "remember",
                arguments: [
                    "content": .string(content),
                    "project": .string("Wax"),
                    "memory_type": .string("decision"),
                    "durability": .string("durable"),
                ]
            ),
            broker: service
        )
        let repeatedJSON = try parseJSONText(in: repeated)
        #expect(repeatedJSON["memory_id"] as? String == firstJSON["memory_id"] as? String)
        #expect(repeatedJSON["deduplicated"] as? Bool == true)
        #expect(repeatedJSON["framesAdded"] as? Int == 0)
    }
}

@Test
func handoffStoresPendingTasksOnceAndSupersedesPriorProjectHandoff() async throws {
    try await withAgentBrokerService { service, _ in
        let project = "handoff-supersede-\(UUID().uuidString)"
        let sessionID = UUID()
        let firstMarker = "OLD_HANDOFF_\(UUID().uuidString)"
        let secondMarker = "NEW_HANDOFF_\(UUID().uuidString)"

        #expect((await service.handle(.init(
            command: "session_start",
            arguments: [
                "session_id": .string(sessionID.uuidString),
                "project": .string(project),
            ]
        ))).ok == true)
        #expect((await service.handle(.init(
            command: "handoff",
            arguments: [
                "content": .string("\(firstMarker) old summary"),
                "session_id": .string(sessionID.uuidString),
                "project": .string(project),
                "pending_tasks": .array([.string("old task")]),
            ]
        ))).ok == true)
        #expect((await service.handle(.init(
            command: "handoff",
            arguments: [
                "content": .string("\(secondMarker) current summary"),
                "session_id": .string(sessionID.uuidString),
                "project": .string("  \(project)  "),
                "pending_tasks": .array([.string("current task")]),
            ]
        ))).ok == true)

        let latest = await service.handle(.init(
            command: "handoff_latest",
            arguments: ["project": .string(project)]
        ))
        let latestPayload = try #require(latest.payload?.objectValue)
        #expect(latestPayload["content"]?.stringValue == "\(secondMarker) current summary")
        #expect(latestPayload["pending_tasks"]?.arrayValue?.compactMap(\.stringValue) == ["current task"])
        #expect(latestPayload["content"]?.stringValue?.contains("Pending tasks:") == false)

        let oldRecall = await service.handle(.init(
            command: "recall",
            arguments: [
                "query": .string(firstMarker),
                "project": .string(project),
                "mode": .string("text"),
                "limit": .int(5),
            ]
        ))
        let oldPayload = try #require(oldRecall.payload?.objectValue)
        #expect(oldPayload["results"]?.arrayValue?.isEmpty == true)
    }
}

@Test
func handoffSupersessionKeepsOtherSessionLineagesVisible() async throws {
    try await withAgentBrokerService { service, _ in
        let project = "handoff-lineage-\(UUID().uuidString)"
        let sessionA = UUID()
        let sessionB = UUID()
        for sessionID in [sessionA, sessionB] {
            #expect((await service.handle(.init(
                command: "session_start",
                arguments: [
                    "session_id": .string(sessionID.uuidString),
                    "project": .string(project),
                ]
            ))).ok == true)
        }

        let oldA = "OLD_A_\(UUID().uuidString)"
        let currentA = "CURRENT_A_\(UUID().uuidString)"
        let currentB = "CURRENT_B_\(UUID().uuidString)"
        for (sessionID, content) in [(sessionA, oldA), (sessionB, currentB), (sessionA, currentA)] {
            #expect((await service.handle(.init(
                command: "handoff",
                arguments: [
                    "session_id": .string(sessionID.uuidString),
                    "project": .string(project),
                    "content": .string(content),
                ]
            ))).ok == true)
        }

        for marker in [currentA, currentB] {
            let recall = try #require((await service.handle(.init(
                command: "recall",
                arguments: [
                    "query": .string(marker),
                    "project": .string(project),
                    "mode": .string("text"),
                ]
            ))).payload?.objectValue)
            #expect(recall["results"]?.arrayValue?.isEmpty == false)
        }
        let oldRecall = try #require((await service.handle(.init(
            command: "recall",
            arguments: [
                "query": .string(oldA),
                "project": .string(project),
                "mode": .string("text"),
            ]
        ))).payload?.objectValue)
        #expect(oldRecall["results"]?.arrayValue?.isEmpty == true)
    }
}

@Test
func concurrentHandoffsForOneLineageCommitWithoutConflictingSupersedes() async throws {
    try await withAgentBrokerService { service, _ in
        let project = "handoff-concurrency-\(UUID().uuidString)"
        let sessionID = UUID()
        #expect((await service.handle(.init(
            command: "session_start",
            arguments: [
                "session_id": .string(sessionID.uuidString),
                "project": .string(project),
            ]
        ))).ok == true)

        let responses = await withTaskGroup(of: AgentBrokerResponse.self, returning: [AgentBrokerResponse].self) { group in
            for index in 0..<12 {
                group.addTask {
                    await service.handle(.init(
                        command: "handoff",
                        arguments: [
                            "session_id": .string(sessionID.uuidString),
                            "project": .string(project),
                            "content": .string("CONCURRENT_HANDOFF_\(index)"),
                        ]
                    ))
                }
            }
            var collected: [AgentBrokerResponse] = []
            for await response in group { collected.append(response) }
            return collected
        }
        #expect(responses.count == 12)
        #expect(responses.allSatisfy { $0.ok })

        let recall = try #require((await service.handle(.init(
            command: "recall",
            arguments: [
                "query": .string("CONCURRENT_HANDOFF"),
                "project": .string(project),
                "mode": .string("text"),
                "limit": .int(20),
            ]
        ))).payload?.objectValue)
        #expect(recall["results"]?.arrayValue?.count == 1)
    }
}

@Test(.timeLimit(.minutes(1)))
func sessionEndWaitsForInFlightRememberToFinish() async throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-mcp-end-drain-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let embedder = ControlledRememberEmbedder()
    let service = try await AgentBrokerService(
        storePath: rootURL.appendingPathComponent("memory.wax").path,
        sessionRootPath: rootURL.appendingPathComponent("sessions", isDirectory: true).path,
        noEmbedder: false,
        embedderChoice: "auto",
        requireVector: false,
        embedderOverride: embedder
    )

    do {
        let started = try #require((await service.handle(.init(
            command: "session_start",
            arguments: [:]
        ))).payload?.objectValue)
        let sessionID = try #require(started["session_id"]?.stringValue)

        async let remembering = service.handle(.init(
            command: "remember",
            arguments: [
                "content": .string("IN_FLIGHT_END_DRAIN_MARKER"),
                "session_id": .string(sessionID),
            ]
        ))
        await embedder.waitUntilEmbeddingStarts()
        async let ending = service.handle(.init(
            command: "session_end",
            arguments: ["session_id": .string(sessionID)]
        ))

        await embedder.release()
        let remembered = await remembering
        let ended = await ending
        #expect(remembered.ok == true)
        #expect(ended.ok == true)
        #expect(ended.payload?.objectValue?["ended"]?.boolValue == true)
        try await service.close()
    } catch {
        await embedder.release()
        try? await service.close()
        throw error
    }
}

@Test
func defaultRecallUsesHybridWhenVectorCoverageIsPartial() async throws {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-mcp-partial-vectors-\(UUID().uuidString)", isDirectory: true)
    let storeURL = rootURL.appendingPathComponent("memory.wax")
    let sessionRootURL = rootURL.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }

    var textOnlyConfig = OrchestratorConfig.default
    textOnlyConfig.enableVectorSearch = false
    let textOnly = try await AgentBrokerService(
        storePath: storeURL.path,
        sessionRootPath: sessionRootURL.path,
        noEmbedder: true,
        embedderChoice: "auto",
        requireVector: false,
        orchestratorConfig: textOnlyConfig
    )
    #expect((await textOnly.handle(.init(
        command: "remember",
        arguments: ["content": .string("LEGACY_TEXT_ONLY_PARTIAL_VECTOR_MARKER")]
    ))).ok == true)
    try await textOnly.close()

    var hybridConfig = OrchestratorConfig.default
    hybridConfig.enableVectorSearch = true
    hybridConfig.rag.searchMode = .hybrid(alpha: 0.5)
    let hybrid = try await AgentBrokerService(
        storePath: storeURL.path,
        sessionRootPath: sessionRootURL.path,
        noEmbedder: false,
        embedderChoice: "auto",
        requireVector: false,
        embedderOverride: MCPTestDeterministicEmbedder(),
        orchestratorConfig: hybridConfig
    )
    do {
        #expect((await hybrid.handle(.init(
            command: "remember",
            arguments: ["content": .string("hybrid default query marker for partial vector coverage")]
        ))).ok == true)

        let stats = try #require((await hybrid.handle(.init(command: "stats"))).payload?.objectValue)
        #expect(stats["embeddingStatus"]?.stringValue == "degraded")
        #expect(stats["queryEmbeddingAvailable"]?.boolValue == true)

        // Ordinary prose, not a SCREAMING_SNAKE identifier. Omitted-mode
        // recall must still request hybrid when vector coverage is partial.
        let recalled = await hybrid.handle(.init(
            command: "recall",
            arguments: [
                "query": .string("hybrid default query marker"),
                "scope": .string("global"),
                "limit": .int(5),
            ]
        ))
        let payload = try #require(recalled.payload?.objectValue)
        #expect(payload["requested_mode"]?.stringValue == "hybrid(alpha=0.500)")
        #expect(payload["effective_mode"]?.stringValue == "hybrid(alpha=0.500)")
        #expect(payload["query_embedding_state"]?.stringValue == "available")
        try await hybrid.close()
    } catch {
        try? await hybrid.close()
        throw error
    }
}

@Test
func factRetractMissingIdDoesNotReportCommitted() async throws {
    try await withAgentBrokerService { service, _ in
        let retract = await WaxMCPTools.handleCall(
            params: .init(
                name: "fact_retract",
                arguments: ["fact_id": .int(999_999)]
            ),
            broker: service
        )
        #expect(retract.isError == true)
        #expect(firstText(in: retract).contains("fact_id has no open spans"))
        #expect(!firstText(in: retract).contains("\"committed\":true"))
    }

    try await withAgentBrokerService { service, _ in
        let result = await service.handle(.init(
            command: "fact_retract",
            arguments: ["fact_id": .int(999_999)]
        ))
        #expect(result.ok == false)
        #expect(result.payload == nil)
        #expect(result.error?.contains("fact_id has no open spans") == true)
    }
}

@Test
func brokerSessionResumeMissingUUIDDoesNotLeakPath() async throws {
    try await withAgentBrokerService { service, _ in
        let missingSessionID = UUID()
        let resumed = await service.handle(.init(
            command: "session_resume",
            arguments: ["session_id": .string(missingSessionID.uuidString)]
        ))

        #expect(resumed.ok != true)
        let error = resumed.error ?? ""
        #expect(error == "No session manifest found for session_id \(missingSessionID.uuidString)")
        #expect(!error.contains("/Users/"))
        #expect(!error.contains("/home/"))
        #expect(!error.contains("~/.wax"))
        #expect(!error.contains(".json"))
    }
}

@Test
func brokerSessionResumeCorruptUUIDDoesNotReportMissing() async throws {
    try await withAgentBrokerService { service, sessionRootURL in
        let sessionID = UUID()
        let corruptManifestURL = BrokerSessionPersistence.manifestURL(
            rootURL: sessionRootURL,
            sessionID: sessionID
        )
        try Data("{not valid json".utf8).write(to: corruptManifestURL)

        let resumed = await service.handle(.init(
            command: "session_resume",
            arguments: ["session_id": .string(sessionID.uuidString)]
        ))

        #expect(resumed.ok != true)
        let error = resumed.error ?? ""
        #expect(!error.contains("No session manifest found"))
        #expect(!error.contains("/Users/"))
        #expect(!error.contains("/home/"))
        #expect(!error.contains("~/.wax"))
        #expect(!error.contains(".json"))
    }
}

private func firstText(in result: CallTool.Result) -> String {
    for content in result.content {
        if case .text(text: let text, annotations: _, _meta: _) = content {
            return text
        }
    }
    return ""
}

private func containsKeyRecursively(_ key: String, in value: Any) -> Bool {
    if let object = value as? [String: Any] {
        if object[key] != nil { return true }
        return object.values.contains { containsKeyRecursively(key, in: $0) }
    }
    if let array = value as? [Any] {
        return array.contains { containsKeyRecursively(key, in: $0) }
    }
    return false
}

private func parseJSONText(in result: CallTool.Result) throws -> [String: Any] {
    let text = firstText(in: result)
    if let dict = decodeJSONObject(text) {
        return dict
    }
    for content in result.content {
        if case .resource(let resource, _, _) = content,
           let resourceText = resource.text,
           let dict = decodeJSONObject(resourceText) {
            return dict
        }
    }
    let preview = text.isEmpty ? "<empty>" : String(text.prefix(200))
    throw NSError(
        domain: "WaxMCPServerTests",
        code: 3,
        userInfo: [NSLocalizedDescriptionKey: "Result is not a JSON object: \(preview)"]
    )
}

private func decodeJSONObject(_ text: String) -> [String: Any]? {
    guard !text.isEmpty, let data = text.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) else {
        return nil
    }
    return object as? [String: Any]
}

private func parseJSONResource(in result: CallTool.Result, uriSuffix: String) throws -> [String: Any] {
    if let textPayload = try? parseJSONText(in: result) {
        return textPayload
    }
    for content in result.content {
        if case .resource(let resource, _, _) = content,
           resource.uri.hasSuffix(uriSuffix),
           let text = resource.text,
           let data = text.data(using: .utf8) {
            let object = try JSONSerialization.jsonObject(with: data)
            guard let dict = object as? [String: Any] else {
                throw NSError(domain: "WaxMCPServerTests", code: 6, userInfo: [NSLocalizedDescriptionKey: "Resource is not a JSON object"])
            }
            return dict
        }
    }
    throw NSError(domain: "WaxMCPServerTests", code: 7, userInfo: [NSLocalizedDescriptionKey: "Missing JSON resource with suffix '\(uriSuffix)'"])
}

private func schemaMaximum(_ schema: Value, property: String) -> Double? {
    guard case .object(let root) = schema,
          case .object(let properties)? = root["properties"],
          case .object(let propertySchema)? = properties[property]
    else {
        return nil
    }
    switch propertySchema["maximum"] {
    case .double(let value):
        return value
    case .int(let value):
        return Double(value)
    default:
        return nil
    }
}

private func schemaPropertyNames(_ schema: Value) -> Set<String> {
    guard case .object(let root) = schema,
          case .object(let properties)? = root["properties"]
    else {
        return []
    }
    return Set(properties.keys)
}

private func schemaEnum(_ schema: Value, property: String) -> [String]? {
    guard case .object(let root) = schema,
          case .object(let properties)? = root["properties"],
          case .object(let propertySchema)? = properties[property],
          case .array(let values)? = propertySchema["enum"]
    else {
        return nil
    }
    return values.compactMap { value in
        guard case .string(let raw) = value else { return nil }
        return raw
    }
}

private func schemaNestedProperties(_ schema: Value, property: String) -> [String: Value]? {
    guard case .object(let root) = schema,
          case .object(let properties)? = root["properties"],
          case .object(let propertySchema)? = properties[property],
          case .object(let nestedProperties)? = propertySchema["properties"]
    else {
        return nil
    }
    return nestedProperties
}

private struct LifecycleFilterFixture {
    let query: String
    let deletedFrameID: UInt64
    let supersededFrameID: UInt64
    let replacementFrameID: UInt64
}

private func seedLifecycleFilterFixture(at storeURL: URL) async throws -> LifecycleFilterFixture {
    var config = OrchestratorConfig.default
    config.enableVectorSearch = false
    config.enableStructuredMemory = false
    config.chunking = .tokenCount(targetTokens: 8, overlapTokens: 2)
    config.rag = FastRAGConfig(
        maxContextTokens: 120,
        expansionMaxTokens: 60,
        snippetMaxTokens: 30,
        maxSnippets: 8,
        searchTopK: 20,
        searchMode: .textOnly
    )
    let memory = try await MemoryOrchestrator(at: storeURL, config: config)
    do {
        let fixture = try await seedLifecycleFilterFixture(memory: memory)
        try await memory.close()
        return fixture
    } catch {
        try? await memory.close()
        throw error
    }
}

private func seedLifecycleFilterFixture(memory: MemoryOrchestrator) async throws -> LifecycleFilterFixture {
    let seed = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    let query = "lifecyclefilterquery\(seed.prefix(8))"
    let deletedMarker = "lifecycledeleted\(seed.dropFirst(8).prefix(8))"
    let supersededMarker = "lifecyclesuperseded\(seed.dropFirst(16).prefix(8))"
    let replacementMarker = "lifecyclereplacement\(seed.dropFirst(24).prefix(8))"

    try await memory.ingestCorpusDocumentsTextOnly([
        .init(timestampMs: 1_800_000_001_000, text: "\(query) \(deletedMarker)", metadata: ["fixture": "deleted"]),
        .init(timestampMs: 1_800_000_002_000, text: "\(query) \(supersededMarker)", metadata: ["fixture": "superseded"]),
        .init(timestampMs: 1_800_000_003_000, text: "\(query) \(replacementMarker)", metadata: ["fixture": "replacement"]),
    ])
    let wax = await memory.wax
    try await wax.commit()

    let documents = try await memory.corpusSourceDocuments()
    func frameID(containing marker: String) throws -> UInt64 {
        guard let document = documents.first(where: { $0.text.contains(marker) }) else {
            throw NSError(
                domain: "WaxMCPServerTests",
                code: 9,
                userInfo: [NSLocalizedDescriptionKey: "Missing seeded document for marker \(marker)"]
            )
        }
        return document.frameId
    }

    let deletedFrameID = try frameID(containing: deletedMarker)
    let supersededFrameID = try frameID(containing: supersededMarker)
    let replacementFrameID = try frameID(containing: replacementMarker)
    try await wax.delete(frameId: deletedFrameID)
    try await wax.supersede(supersededId: supersededFrameID, supersedingId: replacementFrameID)
    try await wax.commit()

    return LifecycleFilterFixture(
        query: query,
        deletedFrameID: deletedFrameID,
        supersededFrameID: supersededFrameID,
        replacementFrameID: replacementFrameID
    )
}

private func resultFrameIDs(from response: AgentBrokerResponse) -> Set<UInt64> {
    guard let rows = response.payload?.objectValue?["results"]?.arrayValue else {
        return []
    }
    return Set(rows.compactMap { row in
        guard let raw = row.objectValue?["frameId"]?.intValue, raw >= 0 else {
            return nil
        }
        return UInt64(raw)
    })
}

private func resultFrameIDs(fromToolJSON object: [String: Any]) -> Set<UInt64> {
    guard let rows = object["results"] as? [[String: Any]] else {
        return []
    }
    return Set(rows.compactMap { row in
        if let value = row["frameId"] as? Int, value >= 0 {
            return UInt64(value)
        }
        if let value = row["frameId"] as? UInt64 {
            return value
        }
        return nil
    })
}

private func parseToolTextJSON(fromResponseLine line: String) throws -> [String: Any] {
    guard let data = line.data(using: .utf8) else {
        throw NSError(domain: "WaxMCPServerTests", code: 8, userInfo: [NSLocalizedDescriptionKey: "Invalid UTF-8 response line"])
    }
    let object = try JSONSerialization.jsonObject(with: data)
    guard let dict = object as? [String: Any],
          let result = dict["result"] as? [String: Any],
          let content = result["content"] as? [[String: Any]]
    else {
        throw NSError(domain: "WaxMCPServerTests", code: 9, userInfo: [NSLocalizedDescriptionKey: "Missing tool text payload"])
    }

    if let text = content.first(where: { ($0["type"] as? String) == "text" })?["text"] as? String,
       let textData = text.data(using: .utf8),
       let textObject = try? JSONSerialization.jsonObject(with: textData),
       let textDict = textObject as? [String: Any] {
        return textDict
    }

    if let resource = content.first(where: {
        ($0["type"] as? String) == "resource" &&
            ((($0["resource"] as? [String: Any])?["uri"] as? String)?.hasSuffix("tool/result") == true)
    })?["resource"] as? [String: Any],
       let text = resource["text"] as? String,
       let textData = text.data(using: .utf8),
       let resourceObject = try? JSONSerialization.jsonObject(with: textData),
       let resourceDict = resourceObject as? [String: Any] {
        return resourceDict
    }

    throw NSError(domain: "WaxMCPServerTests", code: 10, userInfo: [NSLocalizedDescriptionKey: "Tool payload is not a JSON object"])
}

private func parseToolResourceJSON(fromResponseLine line: String, uriSuffix: String) throws -> [String: Any] {
    if let textPayload = try? parseToolTextJSON(fromResponseLine: line) {
        return textPayload
    }
    guard let data = line.data(using: .utf8) else {
        throw NSError(domain: "WaxMCPServerTests", code: 24, userInfo: [NSLocalizedDescriptionKey: "Invalid UTF-8 response line"])
    }
    let object = try JSONSerialization.jsonObject(with: data)
    guard let dict = object as? [String: Any],
          let result = dict["result"] as? [String: Any],
          let content = result["content"] as? [[String: Any]],
          let resource = content.first(where: {
              ($0["type"] as? String) == "resource" &&
              (($0["resource"] as? [String: Any])?["uri"] as? String)?.hasSuffix(uriSuffix) == true
          }),
          let resourceObject = resource["resource"] as? [String: Any],
          let text = resourceObject["text"] as? String,
          let textData = text.data(using: .utf8)
    else {
        throw NSError(domain: "WaxMCPServerTests", code: 25, userInfo: [NSLocalizedDescriptionKey: "Missing tool resource payload"])
    }

    let textObject = try JSONSerialization.jsonObject(with: textData)
    guard let textDict = textObject as? [String: Any] else {
        throw NSError(domain: "WaxMCPServerTests", code: 26, userInfo: [NSLocalizedDescriptionKey: "Tool resource payload is not a JSON object"])
    }
    return textDict
}

private func requireString(_ object: [String: Any], key: String) throws -> String {
    guard let value = object[key] as? String, !value.isEmpty else {
        throw NSError(domain: "WaxMCPServerTests", code: 4, userInfo: [NSLocalizedDescriptionKey: "Missing string key '\(key)'"])
    }
    return value
}

private func requireObject(_ object: [String: Any], key: String) throws -> [String: Any] {
    guard let nested = object[key] as? [String: Any] else {
        throw NSError(
            domain: "WaxMCPServerTests",
            code: 20,
            userInfo: [NSLocalizedDescriptionKey: "Missing object value for key '\(key)'"]
        )
    }
    return nested
}

private func requireObject(_ value: Any) throws -> [String: Any] {
    guard let object = value as? [String: Any] else {
        throw NSError(
            domain: "WaxMCPServerTests",
            code: 21,
            userInfo: [NSLocalizedDescriptionKey: "Value is not a JSON object"]
        )
    }
    return object
}

private func requireArray(_ object: [String: Any], key: String) throws -> [Any] {
    guard let array = object[key] as? [Any] else {
        throw NSError(
            domain: "WaxMCPServerTests",
            code: 22,
            userInfo: [NSLocalizedDescriptionKey: "Missing array value for key '\(key)'"]
        )
    }
    return array
}

private func requireInt(_ object: [String: Any], key: String) throws -> Int {
    if let value = object[key] as? Int {
        return value
    }
    if let value = object[key] as? NSNumber {
        return value.intValue
    }
    throw NSError(domain: "WaxMCPServerTests", code: 5, userInfo: [NSLocalizedDescriptionKey: "Missing int key '\(key)'"])
}

private actor HangingCountingEmbedder: EmbeddingProvider {
    let dimensions: Int = 2
    let normalize: Bool = true
    let identity: EmbeddingIdentity? = .init(
        provider: "Test",
        model: "Hanging",
        dimensions: 2,
        normalized: true
    )

    func embed(_ text: String) async throws -> [Float] {
        _ = text
        try await Task.sleep(for: .seconds(60))
        return [1.0, 0.0]
    }
}

private actor ControlledRememberEmbedder: EmbeddingProvider {
    let dimensions: Int = 2
    let normalize: Bool = true
    let identity: EmbeddingIdentity? = .init(
        provider: "Test",
        model: "ControlledRemember",
        dimensions: 2,
        normalized: true
    )
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func embed(_ text: String) async throws -> [Float] {
        _ = text
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if !released {
            await withCheckedContinuation { releaseWaiters.append($0) }
        }
        return [1.0, 0.0]
    }

    func waitUntilEmbeddingStarts() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private actor IdentitylessEmbedder: EmbeddingProvider {
    let dimensions: Int = 2
    let normalize: Bool = true
    let identity: EmbeddingIdentity? = nil

    func embed(_ text: String) async throws -> [Float] {
        _ = text
        return [1.0, 0.0]
    }
}

private struct MCPTestDeterministicEmbedder: EmbeddingProvider, Sendable {
    let dimensions: Int = 2
    let normalize: Bool = true
    let identity: EmbeddingIdentity? = EmbeddingIdentity(
        provider: "MCPTest",
        model: "Deterministic",
        dimensions: 2,
        normalized: true
    )

    func embed(_ text: String) async throws -> [Float] {
        let a = Float(text.utf8.count % 97) / 97.0
        let b = Float(text.unicodeScalars.count % 89) / 89.0
        let norm = sqrt(a * a + b * b)
        guard norm > 0 else { return [1, 0] }
        return [a / norm, b / norm]
    }
}

private final class MCPServerProcessHarness: @unchecked Sendable {
    struct BootstrapResult {
        let initialize: String
        let toolsList: String?
    }

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let lock = NSLock()
    private var stdoutLines: [String] = []
    private var stdoutPending = Data()
    private var stderrPending = Data()
    private var stderrLines: [String] = []
    private let brokerConfiguration: AgentBrokerConfiguration
    private let harnessRootURL: URL
    private let harnessHomeURL: URL
    private let harnessBrokerRootURL: URL

    let storeURL: URL
    var brokerSessionRootURL: URL {
        URL(fileURLWithPath: brokerConfiguration.sessionRootPath, isDirectory: true)
    }
    var brokerSocketPath: String { brokerConfiguration.socketPath }

    var isRunning: Bool { process.isRunning }
    var processIdentifier: Int32 { process.processIdentifier }

    init(
        useRealEmbedder: Bool = false,
        storeURL: URL? = nil,
        extraArguments: [String] = [],
        isolateSessionRootEnv: Bool = true,
        currentDirectory: URL? = nil,
        extraEnvironment: [String: String] = [:]
    ) throws {
        prepareWaxMCPTestProcessIO()
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        self.storeURL = storeURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-mcp-process-\(UUID().uuidString)")
            .appendingPathExtension("wax")

        let executableURL = try Self.waxMCPBinaryURL(packageRoot: root)
        process.executableURL = executableURL
        var args = ["--store-path", self.storeURL.path]
        if !useRealEmbedder {
            args.append("--no-embedder")
        }
        args.append(contentsOf: extraArguments)
        process.arguments = args
        if let currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }
        let envRoot = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("wmh-\(Self.stableTestHash(self.storeURL.path))", isDirectory: true)
        harnessRootURL = envRoot
        harnessHomeURL = envRoot.appendingPathComponent("h", isDirectory: true)
        harnessBrokerRootURL = envRoot.appendingPathComponent("b", isDirectory: true)
        try FileManager.default.createDirectory(at: harnessHomeURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: harnessBrokerRootURL, withIntermediateDirectories: true)
        let sessionRootPath = envRoot.appendingPathComponent("s", isDirectory: true).path
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = harnessHomeURL.path
        environment["WAX_BROKER_DIR"] = harnessBrokerRootURL.path
        if isolateSessionRootEnv {
            environment["WAX_SESSION_ROOT_DIR"] = sessionRootPath
        } else {
            environment.removeValue(forKey: "WAX_SESSION_ROOT_DIR")
            environment.removeValue(forKey: "WAX_SESSION_ROOT")
        }
        environment["WAX_BROKER_IDLE_TIMEOUT_SECS"] = "1"
        environment.removeValue(forKey: "WAX_MCP_TOOLS")
        for (key, value) in extraEnvironment {
            environment[key] = value
        }
        process.environment = environment
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        brokerConfiguration = try AgentBrokerPathing.configuration(
            brokerExecutablePath: AgentBrokerPathing.resolveBrokerCLIPath(
                currentExecutablePath: executableURL.path
            ),
            storePath: self.storeURL.path,
            sessionRootPath: sessionRootPath,
            socketRootPath: harnessBrokerRootURL.path,
            embedderChoice: "minilm",
            noEmbedder: !useRealEmbedder
        )
    }

    func start() throws {
        try Self.setNonBlocking(stdoutPipe.fileHandleForReading.fileDescriptor)
        try Self.setNonBlocking(stderrPipe.fileHandleForReading.fileDescriptor)
        try process.run()
        Thread.sleep(forTimeInterval: 0.05)
    }

    func terminateIfNeeded() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        try? stdinPipe.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
                let forceDeadline = Date().addingTimeInterval(1)
                while process.isRunning, Date() < forceDeadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }
        }
        try? shutdownBrokerIfRunning()
    }

    func sendJSONLine(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        stdinPipe.fileHandleForWriting.write(data)
        stdinPipe.fileHandleForWriting.write(Data([0x0A]))
    }

    func bootstrap(
        clientName: String,
        initializeID: Int = 1,
        includeToolsList: Bool = false,
        toolsListID: Int = 2,
        initializeTimeout: TimeInterval = 15,
        toolsListTimeout: TimeInterval = 15
    ) async throws -> BootstrapResult {
        try sendJSONLine([
            "jsonrpc": "2.0",
            "id": initializeID,
            "method": "initialize",
            "params": [
                "protocolVersion": "2024-11-05",
                "capabilities": [:],
                "clientInfo": ["name": clientName, "version": "1.0"],
            ],
        ])

        let initialize = try await waitForResponseLine(id: initializeID, timeout: initializeTimeout)
        try sendJSONLine([
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
            "params": [:],
        ])

        if includeToolsList {
            try sendJSONLine([
                "jsonrpc": "2.0",
                "id": toolsListID,
                "method": "tools/list",
                "params": [:],
            ])
        }

        let toolsList = includeToolsList
            ? try await waitForResponseLine(id: toolsListID, timeout: toolsListTimeout)
            : nil
        return BootstrapResult(initialize: initialize, toolsList: toolsList)
    }

    func callTool(
        id: Int,
        name: String,
        arguments: [String: Any],
        timeout: TimeInterval = 10
    ) async throws -> String {
        try sendJSONLine([
            "jsonrpc": "2.0",
            "id": id,
            "method": "tools/call",
            "params": [
                "name": name,
                "arguments": arguments,
            ],
        ])
        return try await waitForResponseLine(id: id, timeout: timeout)
    }

    func closeInput() throws {
        try stdinPipe.fileHandleForWriting.close()
    }

    func sendSignal(_ signal: Int32) throws {
        guard process.processIdentifier > 0 else {
            throw NSError(domain: "MCPServerProcessHarness", code: 1)
        }
        Darwin.kill(process.processIdentifier, signal)
    }

    func waitForResponseLine(id: Int, timeout: TimeInterval = 5) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            drainAvailableOutput()
            if let line = withLocked({ stdoutLines.first(where: { Self.responseLineMatchesID($0, id: id) }) }) {
                return line
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let running = process.isRunning
        let (stderr, stdoutTail, terminationStatus) = withLocked {
            (
                stderrLines.joined(separator: "\n"),
                Array(stdoutLines.suffix(10)).joined(separator: "\n"),
                process.isRunning ? nil : process.terminationStatus
            )
        }
        throw NSError(
            domain: "MCPServerProcessHarness",
            code: 2,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Timed out waiting for response id \(id). " +
                    "running=\(running) terminationStatus=\(String(describing: terminationStatus)) " +
                    "stderr=\(stderr) stdoutTail=\(stdoutTail)"
            ]
        )
    }

    func waitForExit(timeout: TimeInterval = 5) async throws -> Int32 {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            drainAvailableOutput()
            if !process.isRunning {
                drainPipes()
                return process.terminationStatus
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "MCPServerProcessHarness", code: 3)
    }

    func waitForStderrContaining(_ needle: String, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            drainAvailableOutput()
            if withLocked({ stderrLines.joined(separator: "\n") }).contains(needle) {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let stderr = withLocked { stderrLines.joined(separator: "\n") }
        throw NSError(
            domain: "MCPServerProcessHarness",
            code: 5,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for stderr containing '\(needle)'. stderr=\(stderr)"]
        )
    }

    private func drainPipes() {
        drainAvailableOutput()
    }

    private func drainAvailableOutput() {
        drainAvailableData(from: stdoutPipe.fileHandleForReading, toStdout: true)
        drainAvailableData(from: stderrPipe.fileHandleForReading, toStdout: false)
    }

    private func drainAvailableData(from handle: FileHandle, toStdout: Bool) {
        let fd = handle.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let bytesRead = read(fd, &buffer, buffer.count)
            if bytesRead > 0 {
                appendOutput(Data(buffer[..<bytesRead]), toStdout: toStdout)
                continue
            }
            if bytesRead == 0 {
                return
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            }
            return
        }
    }

    private func appendOutput(_ data: Data, toStdout: Bool) {
        lock.lock()
        defer { lock.unlock() }

        if toStdout {
            stdoutPending.append(data)
            Self.extractLines(from: &stdoutPending, into: &stdoutLines)
        } else {
            stderrPending.append(data)
            Self.extractLines(from: &stderrPending, into: &stderrLines)
        }
    }

    private func withLocked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private static func extractLines(from pending: inout Data, into target: inout [String]) {
        while let newline = pending.firstIndex(of: 0x0A) {
            let lineData = pending[..<newline]
            pending = pending[(newline + 1)...]
            guard !lineData.isEmpty, let line = String(data: lineData, encoding: .utf8) else { continue }
            target.append(line)
        }
    }

    private static func responseLineMatchesID(_ line: String, id: Int) -> Bool {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responseID = object["id"]
        else {
            return false
        }

        if let responseID = responseID as? Int {
            return responseID == id
        }
        if let responseID = responseID as? NSNumber {
            return responseID.intValue == id
        }
        if let responseID = responseID as? String {
            return responseID == String(id)
        }
        return false
    }

    static func waxMCPBinaryURLForTests(packageRoot: URL) throws -> URL {
        try waxMCPBinaryURL(packageRoot: packageRoot)
    }

    private static func waxMCPBinaryURL(packageRoot: URL) throws -> URL {
        let bundleDebugDir = Bundle(for: XCTestCase.self).bundleURL.deletingLastPathComponent()
        let candidates = [
            bundleDebugDir.appendingPathComponent("wax-mcp"),
            packageRoot.appendingPathComponent(".build/debug/wax-mcp"),
            packageRoot.appendingPathComponent(".build/arm64-apple-macosx/debug/wax-mcp"),
        ]

        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }

        let attempted = candidates.map(\.path).joined(separator: "\n")
        throw NSError(
            domain: "MCPServerProcessHarness",
            code: 4,
            userInfo: [NSLocalizedDescriptionKey: "Could not find wax-mcp binary. Tried:\n\(attempted)"]
        )
    }

    private static func stableTestHash(_ text: String) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(hash, radix: 16)
    }

    private static func setNonBlocking(_ fileDescriptor: Int32) throws {
        let flags = fcntl(fileDescriptor, F_GETFL)
        guard flags >= 0 else {
            throw NSError(
                domain: "MCPServerProcessHarness",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "Unable to read file status flags for fd \(fileDescriptor)"]
            )
        }
        guard fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw NSError(
                domain: "MCPServerProcessHarness",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: "Unable to set nonblocking mode for fd \(fileDescriptor)"]
            )
        }
    }

    func stderrSnapshot() -> String {
        withLocked { stderrLines.joined(separator: "\n") }
    }

    func shutdownBrokerIfRunning(timeout: TimeInterval = 2) throws {
        guard FileManager.default.fileExists(atPath: brokerConfiguration.socketPath) else {
            return
        }

        try Self.sendBrokerShutdownSignal(socketPath: brokerConfiguration.socketPath)

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try brokerShutdownCompleted() {
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private func brokerShutdownCompleted() throws -> Bool {
        guard !FileManager.default.fileExists(atPath: brokerConfiguration.socketPath) else {
            return false
        }

        try StoreLockProbe.preflightExclusiveAccess(
            at: URL(fileURLWithPath: brokerConfiguration.storePath),
            timeout: .milliseconds(50)
        )
        return true
    }

    private static func sendBrokerRequest(
        _ request: AgentBrokerRequest,
        socketPath: String
    ) throws -> AgentBrokerResponse? {
        guard FileManager.default.fileExists(atPath: socketPath) else {
            return nil
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return nil
        }
        defer { close(fd) }

        var address = sockaddr_un()
        #if canImport(Darwin)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        address.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            return nil
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: CChar.self, repeating: 0)
            for (index, byte) in pathBytes.enumerated() {
                buffer[index] = byte
            }
        }

        let connectResult = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            return nil
        }

        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let payload = try JSONEncoder().encode(request)
        handle.write(payload)
        handle.write(Data([0x0A]))
        shutdown(fd, SHUT_WR)

        let data = try handle.readToEnd() ?? Data()
        guard let line = String(data: data, encoding: .utf8)?
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return nil
        }

        return try JSONDecoder().decode(AgentBrokerResponse.self, from: Data(line.utf8))
    }

    private static func sendBrokerShutdownSignal(socketPath: String) throws {
        guard FileManager.default.fileExists(atPath: socketPath) else {
            return
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return
        }
        defer { close(fd) }

        var address = sockaddr_un()
        #if canImport(Darwin)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        address.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            return
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: CChar.self, repeating: 0)
            for (index, byte) in pathBytes.enumerated() {
                buffer[index] = byte
            }
        }

        let connectResult = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            return
        }

        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let payload = try JSONEncoder().encode(AgentBrokerRequest(command: "shutdown"))
        handle.write(payload)
        handle.write(Data([0x0A]))
        shutdown(fd, SHUT_WR)
    }
}

private func toolNamesListedInMCPResponse(_ line: String) throws -> Set<String> {
    let data = try #require(line.data(using: .utf8))
    let envelope = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let result = try #require(envelope["result"] as? [String: Any])
    let tools = try #require(result["tools"] as? [[String: Any]])
    return Set(tools.compactMap { $0["name"] as? String })
}

@Suite("Wax MCP Process Tests", .serialized)
struct WaxMCPProcessTests {
    @Test(.timeLimit(.minutes(1)))
    func defaultProcessToolsListContainsRememberAndHidesMemoryAppend() async throws {
        let harness = try MCPServerProcessHarness()
        try harness.start()
        defer { harness.terminateIfNeeded() }

        let bootstrap = try await harness.bootstrap(
            clientName: "wax-mcp-daily-catalog-list-test",
            includeToolsList: true
        )
        let toolsList = try #require(bootstrap.toolsList)
        let names = try toolNamesListedInMCPResponse(toolsList)
        let expected: Set<String> = [
            "session_open",
            "remember",
            "recall",
            "session_close",
            "stats",
            "memory_get",
            "compact_context",
            "session_resume",
        ]
        #expect(names == expected)
        #expect(toolsList.contains(#""name":"remember""#))
        #expect(!toolsList.contains(#""name":"memory_append""#))
        #expect(!names.contains("memory_append"))
        #expect(!names.contains("promote"))
    }

    @Test(.timeLimit(.minutes(1)))
    func fullProcessToolsListIncludesMemoryAppend() async throws {
        let harness = try MCPServerProcessHarness(
            extraEnvironment: ["WAX_MCP_TOOLS": "full"]
        )
        try harness.start()
        defer { harness.terminateIfNeeded() }

        let bootstrap = try await harness.bootstrap(
            clientName: "wax-mcp-full-catalog-list-test",
            includeToolsList: true
        )
        let toolsList = try #require(bootstrap.toolsList)
        let names = try toolNamesListedInMCPResponse(toolsList)
        #expect(names.contains("remember"))
        #expect(names.contains("memory_append"))
        #expect(names.contains("promote"))
        #expect(names.contains("search"))
    }

    @Test
    func processHarnessUsesShortBrokerSocketPaths() throws {
        let harness = try MCPServerProcessHarness()
        defer { harness.terminateIfNeeded() }

        #expect(harness.brokerSocketPath.utf8.count < 104)
        #expect(harness.brokerSessionRootURL.path.hasPrefix("/tmp/wmh-"))
    }

    @Test(.timeLimit(.minutes(1)))
    func compactToolResponseUsesOneWireContentBlock() async throws {
        let harness = try MCPServerProcessHarness()
        try harness.start()
        defer { harness.terminateIfNeeded() }

        _ = try await harness.bootstrap(clientName: "wax-mcp-compact-wire-response")
        let response = try await harness.callTool(
            id: 2,
            name: "stats",
            arguments: [:],
            timeout: 20
        )
        let data = try #require(response.data(using: .utf8))
        let envelope = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try #require(envelope["result"] as? [String: Any])
        let content = try #require(result["content"] as? [[String: Any]])

        #expect(content.count == 1)
        #expect(content[0]["type"] as? String == "text")
        #expect(result["structuredContent"] == nil)
        _ = try parseToolTextJSON(fromResponseLine: response)
    }

    @Test(.timeLimit(.minutes(1)))
    func brokerBackedSessionsUseHarnessIsolatedSessionRoot() async throws {
        let harness = try MCPServerProcessHarness()
        try harness.start()
        defer { harness.terminateIfNeeded() }

        _ = try await harness.bootstrap(clientName: "wax-mcp-session-root-isolation-test", includeToolsList: true)
        let started = try await harness.callTool(
            id: 3,
            name: "session_start",
            arguments: ["verbosity": "verbose"],
            timeout: 20
        )
        #expect(started.contains("store_path"))
        #expect(started.contains(harness.brokerSessionRootURL.path))
    }

    @Test(.timeLimit(.minutes(1)))
    func brokerBackedRememberRejectsReservedMetadataSessionID() async throws {
        let harness = try MCPServerProcessHarness()
        try harness.start()
        defer { harness.terminateIfNeeded() }

        _ = try await harness.bootstrap(clientName: "wax-mcp-metadata-reserved-test")

        let remember = try await harness.callTool(
            id: 2,
            name: "remember",
            arguments: [
                "content": "invalid reserved metadata key",
                "metadata": ["session_id": "not-a-real-session"],
            ],
            timeout: 20
        )
        #expect(remember.contains("metadata.session_id"))
        #expect(remember.contains("reserved"))
    }

    @Test(.timeLimit(.minutes(1)))
    func legacyWaxFlushIsRejectedBecauseFlushIsNotPublished() async throws {
        let harness = try MCPServerProcessHarness()
        try harness.start()
        defer { harness.terminateIfNeeded() }

        _ = try await harness.bootstrap(clientName: "wax-mcp-legacy-flush-test")

        let flush = try await harness.callTool(
            id: 2,
            name: "wax_flush",
            arguments: [:],
            timeout: 20
        )
        #expect(flush.contains("Unknown tool"))
    }

    @Test(.timeLimit(.minutes(1)))
    func waxMCPProcessRespondsAfterImmediateEOF() async throws {
        let harness = try MCPServerProcessHarness()
        try harness.start()
        defer { harness.terminateIfNeeded() }

        _ = try await harness.bootstrap(
            clientName: "wax-mcp-eof-test",
            includeToolsList: true
        )
        try harness.closeInput()

        #expect(try await harness.waitForExit(timeout: 15) == EXIT_SUCCESS)
    }

    @Test(.timeLimit(.minutes(1)))
    func waxMCPProcessPersistsCommittedWritesBeforeSIGTERM() async throws {
        let harness = try MCPServerProcessHarness()
        try harness.start()
        defer { harness.terminateIfNeeded() }

        _ = try await harness.bootstrap(clientName: "wax-mcp-sigterm-test")

        let marker = "waxmcp-sigterm-\(UUID().uuidString)"
        let remember = try await harness.callTool(
            id: 2,
            name: "remember",
            arguments: ["content": marker]
        )
        let rememberJSON = try parseToolTextJSON(fromResponseLine: remember)
        #expect((rememberJSON["status"] as? String) == "ok")

        try harness.closeInput()
        #expect(try await harness.waitForExit() == EXIT_SUCCESS)
        try harness.shutdownBrokerIfRunning()

        var config = OrchestratorConfig.default
        config.enableVectorSearch = false
        let reopened = try await MemoryOrchestrator(at: harness.storeURL, config: config)
        defer { Task { try? await reopened.close() } }
        let context = try await reopened.recall(query: marker)
        #expect(context.items.contains { $0.text.contains(marker) })
    }

    @Test(.timeLimit(.minutes(1)))
    func brokerManagedSessionLifecycleScopesRecallAndRejectsEndedHandoff() async throws {
        let harness = try MCPServerProcessHarness()
        try harness.start()
        defer { harness.terminateIfNeeded() }

        _ = try await harness.bootstrap(
            clientName: "wax-mcp-session-test",
            includeToolsList: true
        )

        let sessionStart = try await harness.callTool(id: 3, name: "session_start", arguments: [:], timeout: 20)
        let sessionStartJSON = try parseToolTextJSON(fromResponseLine: sessionStart)
        let sessionID = try requireString(sessionStartJSON, key: "session_id")

        _ = try await harness.callTool(
            id: 4,
            name: "remember",
            arguments: ["content": "GLOBAL_ONLY_ABC broker regression anchor"],
            timeout: 20
        )
        _ = try await harness.callTool(
            id: 5,
            name: "remember",
            arguments: [
                "content": "SESSION_ONLY_XYZ broker regression anchor",
                "session_id": sessionID,
            ],
            timeout: 20
        )

        let recall = try await harness.callTool(
            id: 6,
            name: "recall",
            arguments: [
                "query": "SESSION_ONLY_XYZ",
                "session_id": sessionID,
                "scope": "global",
                "limit": 10,
            ],
            timeout: 20
        )
        #expect(recall.contains("SESSION_ONLY_XYZ"))
        #expect(recall.contains("GLOBAL_") && recall.contains("ABC"))

        _ = try await harness.callTool(
            id: 7,
            name: "session_end",
            arguments: ["session_id": sessionID],
            timeout: 20
        )

        let handoff = try await harness.callTool(
            id: 8,
            name: "handoff",
            arguments: [
                "content": "should fail after session end",
                "session_id": sessionID,
            ],
            timeout: 20
        )
        #expect(handoff.contains("not active") || handoff.contains("has ended") || handoff.contains("resumable=false"))
    }

    @Test(.timeLimit(.minutes(1)))
    func brokerBackedStatsReflectActiveSessionState() async throws {
        let harness = try MCPServerProcessHarness()
        try harness.start()
        defer { harness.terminateIfNeeded() }

        _ = try await harness.bootstrap(
            clientName: "wax-mcp-broker-stats-session-test",
            includeToolsList: true
        )

        let sessionStart = try await harness.callTool(id: 81, name: "session_start", arguments: [:], timeout: 20)
        let sessionID = try requireString(try parseToolTextJSON(fromResponseLine: sessionStart), key: "session_id")

        _ = try await harness.callTool(
            id: 82,
            name: "remember",
            arguments: [
                "content": "SESSION_STATS_VISIBLE broker-managed session note",
                "session_id": sessionID,
            ],
            timeout: 20
        )

        let stats = try await harness.callTool(
            id: 83,
            name: "stats",
            arguments: [:],
            timeout: 20
        )
        let statsJSON = try parseToolTextJSON(fromResponseLine: stats)
        let session = try requireObject(statsJSON, key: "session")
        #expect((session["active"] as? Bool) == true)
        #expect((session["session_id"] as? String) == sessionID)
        #expect((session["sessionFrameCount"] as? Int ?? 0) >= 1)
        #expect((session["activeSessionCount"] as? Int) == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func brokerBackedSessionSynthesizePromotesDefaultSessionWrites() async throws {
        let harness = try MCPServerProcessHarness()
        try harness.start()
        defer { harness.terminateIfNeeded() }

        _ = try await harness.bootstrap(
            clientName: "wax-mcp-broker-synthesize-test",
            includeToolsList: true
        )

        let sessionStart = try await harness.callTool(id: 9, name: "session_start", arguments: [:], timeout: 20)
        let sessionID = try requireString(try parseToolTextJSON(fromResponseLine: sessionStart), key: "session_id")

        _ = try await harness.callTool(
            id: 10,
            name: "remember",
            arguments: [
                "content": "Decision: promote default session notes when they clearly encode a decision.",
                "session_id": sessionID,
            ],
            timeout: 20
        )

        let synthesize = try await harness.callTool(
            id: 11,
            name: "session_synthesize",
            arguments: ["session_id": sessionID],
            timeout: 20
        )
        let synthesisJSON = try parseToolResourceJSON(
            fromResponseLine: synthesize,
            uriSuffix: "session-synthesize-summary"
        )
        let candidates = try requireArray(synthesisJSON, key: "durable_candidates")
        #expect(candidates.contains { candidate in
            guard let object = try? requireObject(candidate) else {
                return false
            }
            return object["suggested_type"] as? String == "decision"
        })

        let promote = try await harness.callTool(
            id: 12,
            name: "memory_promote",
            arguments: [
                "session_id": sessionID,
                "approve": true,
            ],
            timeout: 20
        )
        let promoteJSON = try parseToolTextJSON(fromResponseLine: promote)
        let metadata = try requireObject(promoteJSON, key: "metadata")
        #expect(try requireString(metadata, key: "wax.memory_type") == "decision")
    }

    @Test(.timeLimit(.minutes(1)))
    func brokerBackedMemorySearchSignalsInfluenceSynthesis() async throws {
        let harness = try MCPServerProcessHarness()
        try harness.start()
        defer { harness.terminateIfNeeded() }

        _ = try await harness.bootstrap(
            clientName: "wax-mcp-broker-memory-search-signals",
            includeToolsList: true
        )

        let sessionStart = try await harness.callTool(id: 70, name: "session_start", arguments: [:], timeout: 20)
        let sessionID = try requireString(try parseToolTextJSON(fromResponseLine: sessionStart), key: "session_id")

        _ = try await harness.callTool(
            id: 71,
            name: "remember",
            arguments: [
                "content": "Decision: broker memory_search retrieval signals should influence synthesis and promotion.",
                "session_id": sessionID,
            ],
            timeout: 20
        )

        for (id, query) in [(72, "retrieval signals"), (73, "synthesis promotion")] {
            _ = try await harness.callTool(
                id: id,
                name: "memory_search",
                arguments: [
                    "query": query,
                    "session_id": sessionID,
                    "mode": "text",
                    "topK": 5,
                    "include_working": true,
                    "include_episodic": false,
                    "include_durable": false,
                ],
                timeout: 20
            )
        }

        let synthesize = try await harness.callTool(
            id: 74,
            name: "session_synthesize",
            arguments: ["session_id": sessionID],
            timeout: 20
        )
        let synthesisJSON = try parseToolResourceJSON(
            fromResponseLine: synthesize,
            uriSuffix: "session-synthesize-summary"
        )
        let candidates = try requireArray(synthesisJSON, key: "durable_candidates")
        let matching = try #require(candidates.first(where: { candidate in
            guard let object = try? requireObject(candidate) else { return false }
            return ((object["summary"] as? String) ?? "").contains("broker memory_search retrieval signals")
        }))
        let matchingObject = try requireObject(matching)
        #expect((matchingObject["recall_count"] as? Int ?? 0) >= 2)
        #expect((matchingObject["unique_query_count"] as? Int ?? 0) >= 2)
        #expect((matchingObject["average_relevance_score"] as? Double ?? 0) > 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func brokerRecordRetrievalHitsCanonicalizesChunkFrameIDs() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-broker-retrieval-signals-\(UUID().uuidString)", isDirectory: true)
        let storeURL = rootURL.appendingPathComponent("memory.wax")
        let sessionRootURL = rootURL.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let service = try await AgentBrokerService(
            storePath: storeURL.path,
            sessionRootPath: sessionRootURL.path,
            noEmbedder: true,
            embedderChoice: "auto",
            requireVector: false
        )

        var deferredError: Error?
        do {
            let started = await service.handle(.init(command: "session_start"))
            #expect(started.ok == true)
            let startedPayload = try #require(started.payload?.objectValue)
            let sessionIDString = try #require(startedPayload["session_id"]?.stringValue)
            let sessionID = try #require(UUID(uuidString: sessionIDString))

            let content = Array(
                repeating: "CHUNK_SIGNAL_ANCHOR repeated broker session content to force chunk creation and retrieval accounting coverage.",
                count: 80
            ).joined(separator: " ")
            let append = await service.handle(.init(
                command: "memory_append",
                arguments: [
                    "content": .string(content),
                    "session_id": .string(sessionIDString),
                ]
            ))
            #expect(append.ok == true)

            let search = await service.handle(.init(
                command: "search",
                arguments: [
                    "query": .string("CHUNK_SIGNAL_ANCHOR"),
                    "mode": .string("text"),
                    "topK": .int(10),
                    "session_id": .string(sessionIDString),
                ]
            ))
            #expect(search.ok == true)
            let searchPayload = try #require(search.payload?.objectValue)
            let searchResults = try #require(searchPayload["results"]?.arrayValue)
            let searchFrameIDs = searchResults.compactMap { result -> UInt64? in
                result.objectValue?["frameId"]?.intValue.map(UInt64.init)
            }
            let rawFrameID = try #require(searchFrameIDs.first)

            let memorySearch = await service.handle(.init(
                command: "memory_search",
                arguments: [
                    "query": .string("CHUNK_SIGNAL_ANCHOR"),
                    "mode": .string("text"),
                    "topK": .int(10),
                    "session_id": .string(sessionIDString),
                    "include_working": .bool(true),
                    "include_episodic": .bool(false),
                    "include_durable": .bool(false),
                ]
            ))
            #expect(memorySearch.ok == true)
            let memorySearchPayload = try #require(memorySearch.payload?.objectValue)
            let memorySearchResults = try #require(memorySearchPayload["results"]?.arrayValue)
            let memorySearchFrameIDs = memorySearchResults.compactMap { result -> UInt64? in
                result.objectValue?["frame_id"]?.intValue.map(UInt64.init)
            }
            let canonicalFrameID = try #require(memorySearchFrameIDs.first)
            #expect(canonicalFrameID != rawFrameID)

            let manifest = try BrokerSessionPersistence.loadManifest(rootURL: sessionRootURL, sessionID: sessionID)
            let signals = BrokerSessionPersistence.recallSignals(
                from: try BrokerSessionPersistence.loadEvents(from: URL(fileURLWithPath: manifest.eventLogPath))
            )
            #expect(signals[rawFrameID] == nil)
            let signal = try #require(signals[canonicalFrameID])
            #expect(signal.recallCount == 2)
            #expect(signal.uniqueQueryCount == 1)
            #expect(signal.averageScore > 0)
        } catch {
            deferredError = error
        }

        do {
            try await service.close()
        } catch {
            if deferredError == nil {
                deferredError = error
            }
        }
        try? FileManager.default.removeItem(at: rootURL)
        if let deferredError {
            throw deferredError
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func brokerBackedMemoryPromotePreservesLockedOverride() async throws {
        let harness = try MCPServerProcessHarness()
        try harness.start()
        defer { harness.terminateIfNeeded() }

        _ = try await harness.bootstrap(
            clientName: "wax-mcp-broker-promote-override-test",
            includeToolsList: true
        )

        let sessionStart = try await harness.callTool(id: 13, name: "session_start", arguments: [:], timeout: 20)
        let sessionID = try requireString(try parseToolTextJSON(fromResponseLine: sessionStart), key: "session_id")

        _ = try await harness.callTool(
            id: 14,
            name: "remember",
            arguments: [
                "content": "Decision: preserve promote overrides for locked durable memories.",
                "session_id": sessionID,
            ],
            timeout: 20
        )

        let promote = try await harness.callTool(
            id: 15,
            name: "memory_promote",
            arguments: [
                "session_id": sessionID,
                "approve": true,
                "locked": true,
            ],
            timeout: 20
        )
        let promoteJSON = try parseToolTextJSON(fromResponseLine: promote)
        let metadata = try requireObject(promoteJSON, key: "metadata")
        #expect(try requireString(metadata, key: "wax.durability") == "locked")
        #expect(try requireString(metadata, key: "wax.reviewed") == "true")
    }

    @Test(.timeLimit(.minutes(1)))
    func brokerBackedKnowledgeCaptureDefaultsToDurable() async throws {
        let harness = try MCPServerProcessHarness()
        try harness.start()
        defer { harness.terminateIfNeeded() }

        _ = try await harness.bootstrap(
            clientName: "wax-mcp-broker-knowledge-capture-test",
            includeToolsList: true
        )

        let capture = try await harness.callTool(
            id: 16,
            name: "knowledge_capture",
            arguments: [
                "content": "Wax keeps durable broker knowledge in the long-term store by default.",
            ],
            timeout: 20
        )
        let captureJSON = try parseToolTextJSON(fromResponseLine: capture)
        #expect(try requireString(captureJSON, key: "durability") == "durable")
    }

    @Test(.timeLimit(.minutes(1)))
    func brokerBackedMemorySearchAndGetExposeStableMemoryIDs() async throws {
        let harness = try MCPServerProcessHarness()
        try harness.start()
        defer { harness.terminateIfNeeded() }

        _ = try await harness.bootstrap(
            clientName: "wax-mcp-broker-memory-search-get-test",
            includeToolsList: true
        )

        let sessionStart = try await harness.callTool(
            id: 17,
            name: "session_start",
            arguments: ["agent_id": "openclaw-agent", "run_id": "run-001"],
            timeout: 20
        )
        let sessionID = try requireString(try parseToolTextJSON(fromResponseLine: sessionStart), key: "session_id")

        _ = try await harness.callTool(
            id: 18,
            name: "remember",
            arguments: [
                "content": "Durable memory anchor: Wax is the long-term source of truth.",
                "memory_type": "decision",
                "durability": "durable",
            ],
            timeout: 20
        )
        _ = try await harness.callTool(
            id: 19,
            name: "memory_append",
            arguments: [
                "content": "Working memory anchor: current task is OpenClaw adapter implementation.",
                "session_id": sessionID,
            ],
            timeout: 20
        )

        let search = try await harness.callTool(
            id: 20,
            name: "memory_search",
            arguments: [
                "query": "anchor",
                "session_id": sessionID,
                "topK": 6,
                "mode": "text",
            ],
            timeout: 20
        )
        let searchJSON = try parseToolResourceJSON(fromResponseLine: search, uriSuffix: "memory-search-summary")
        let results = try requireArray(searchJSON, key: "results")
        #expect(results.contains { result in
            guard let object = try? requireObject(result) else { return false }
            return (object["horizon"] as? String) == "working"
        })
        #expect(results.contains { result in
            guard let object = try? requireObject(result) else { return false }
            return (object["horizon"] as? String) == "durable"
        })

        let pattern = #"working:[0-9A-F-]+:[0-9]+"#
        let regex = try NSRegularExpression(pattern: pattern)
        let searchRange = NSRange(search.startIndex..<search.endIndex, in: search)
        let match = try #require(regex.firstMatch(in: search, range: searchRange))
        let workingRange = try #require(Range(match.range, in: search))
        let workingID = String(search[workingRange])

        let get = try await harness.callTool(
            id: 21,
            name: "memory_get",
            arguments: ["memory_id": workingID],
            timeout: 20
        )
        #expect(get.contains("OpenClaw adapter implementation"))
    }

    @Test(.timeLimit(.minutes(1)))
    func brokerBackedSessionResumeReopensPersistedSessionAfterRestart() async throws {
        let sharedStoreURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-mcp-session-resume-\(UUID().uuidString)")
            .appendingPathExtension("wax")

        let first = try MCPServerProcessHarness(storeURL: sharedStoreURL)
        try first.start()
        _ = try await first.bootstrap(clientName: "wax-mcp-session-resume-first", includeToolsList: true)

        let started = try await first.callTool(
            id: 31,
            name: "session_start",
            arguments: ["agent_id": "openclaw-agent", "run_id": "resume-run"],
            timeout: 20
        )
        let startedJSON = try parseToolTextJSON(fromResponseLine: started)
        let sessionID = try requireString(startedJSON, key: "session_id")

        _ = try await first.callTool(
            id: 32,
            name: "memory_append",
            arguments: [
                "content": "Resume anchor: persisted session memory survives broker restart.",
                "session_id": sessionID,
            ],
            timeout: 20
        )
        first.terminateIfNeeded()

        let second = try MCPServerProcessHarness(storeURL: sharedStoreURL)
        try second.start()
        defer { second.terminateIfNeeded() }
        _ = try await second.bootstrap(clientName: "wax-mcp-session-resume-second", includeToolsList: true)

        let resumed = try await second.callTool(
            id: 33,
            name: "session_resume",
            arguments: ["session_id": sessionID],
            timeout: 20
        )
        let resumedJSON = try parseToolTextJSON(fromResponseLine: resumed)
        #expect((resumedJSON["resumed"] as? Bool) == true)

        let search = try await second.callTool(
            id: 34,
            name: "memory_search",
            arguments: [
                "query": "resume anchor",
                "session_id": sessionID,
                "mode": "text",
            ],
            timeout: 20
        )
        let searchJSON = try parseToolResourceJSON(fromResponseLine: search, uriSuffix: "memory-search-summary")
        let results = try requireArray(searchJSON, key: "results")
        #expect(results.contains { result in
            guard let object = try? requireObject(result) else { return false }
            return (object["preview"] as? String)?.contains("persisted session memory survives broker restart") == true
        })
    }

    @Test(.timeLimit(.minutes(1)))
    func brokerBackedCompactContextDoesNotLoseSessionMemoryAcrossRepeatedCheckpoints() async throws {
        let harness = try MCPServerProcessHarness()
        try harness.start()
        defer { harness.terminateIfNeeded() }

        _ = try await harness.bootstrap(
            clientName: "wax-mcp-compact-context-test",
            includeToolsList: true
        )

        let started = try await harness.callTool(id: 41, name: "session_start", arguments: [:], timeout: 20)
        let sessionID = try requireString(try parseToolTextJSON(fromResponseLine: started), key: "session_id")

        _ = try await harness.callTool(
            id: 42,
            name: "memory_append",
            arguments: [
                "content": "Checkpoint anchor: do not lose session memory after repeated compact_context calls.",
                "session_id": sessionID,
            ],
            timeout: 20
        )
        _ = try await harness.callTool(
            id: 43,
            name: "memory_append",
            arguments: [
                "content": "Context budget anchor: preserve session notes while compacting.",
                "session_id": sessionID,
            ],
            timeout: 20
        )

        let compactA = try await harness.callTool(
            id: 44,
            name: "compact_context",
            arguments: [
                "query": "checkpoint anchor",
                "session_id": sessionID,
                "token_budget": 512,
                "mode": "text",
            ],
            timeout: 20
        )
        let compactAJSON = try parseToolResourceJSON(fromResponseLine: compactA, uriSuffix: "compact-context-summary")
        #expect(try requireString(compactAJSON, key: "compacted_text").contains("Checkpoint anchor"))

        _ = try await harness.callTool(
            id: 45,
            name: "compact_context",
            arguments: [
                "query": "context budget anchor",
                "session_id": sessionID,
                "token_budget": 512,
                "mode": "text",
            ],
            timeout: 20
        )

        let search = try await harness.callTool(
            id: 46,
            name: "memory_search",
            arguments: [
                "query": "checkpoint anchor",
                "session_id": sessionID,
                "mode": "text",
            ],
            timeout: 20
        )
        let searchJSON = try parseToolResourceJSON(fromResponseLine: search, uriSuffix: "memory-search-summary")
        let results = try requireArray(searchJSON, key: "results")
        #expect(results.contains { result in
            guard let object = try? requireObject(result) else { return false }
            return (object["preview"] as? String)?.contains("do not lose session memory") == true
        })
    }

    @Test(.timeLimit(.minutes(1)))
    func brokerBackedMemorySearchDoesNotLeakAcrossSessions() async throws {
        let harness = try MCPServerProcessHarness()
        try harness.start()
        defer { harness.terminateIfNeeded() }

        _ = try await harness.bootstrap(
            clientName: "wax-mcp-cross-session-isolation-test",
            includeToolsList: true
        )

        let startedA = try await harness.callTool(id: 47, name: "session_start", arguments: [:], timeout: 20)
        let sessionA = try requireString(try parseToolTextJSON(fromResponseLine: startedA), key: "session_id")
        let startedB = try await harness.callTool(id: 48, name: "session_start", arguments: [:], timeout: 20)
        let sessionB = try requireString(try parseToolTextJSON(fromResponseLine: startedB), key: "session_id")

        _ = try await harness.callTool(
            id: 49,
            name: "memory_append",
            arguments: [
                "content": "SESSION_A_PRIVATE_ANCHOR do not leak this note into other session searches.",
                "session_id": sessionA,
            ],
            timeout: 20
        )
        _ = try await harness.callTool(
            id: 50,
            name: "memory_append",
            arguments: [
                "content": "SESSION_B_PRIVATE_ANCHOR this note belongs only to session B.",
                "session_id": sessionB,
            ],
            timeout: 20
        )

        let isolated = try await harness.callTool(
            id: 51,
            name: "memory_search",
            arguments: [
                "query": "SESSION_B_PRIVATE_ANCHOR",
                "session_id": sessionA,
                "mode": "text",
                "topK": 5,
            ],
            timeout: 20
        )
        let isolatedJSON = try parseToolResourceJSON(fromResponseLine: isolated, uriSuffix: "memory-search-summary")
        let isolatedResults = try requireArray(isolatedJSON, key: "results")
        #expect(!isolatedResults.contains { result in
            guard let object = try? requireObject(result) else { return false }
            return (object["preview"] as? String)?.contains("SESSION_B_PRIVATE_ANCHOR") == true
        })

        let visible = try await harness.callTool(
            id: 52,
            name: "memory_search",
            arguments: [
                "query": "SESSION_A_PRIVATE_ANCHOR",
                "session_id": sessionA,
                "mode": "text",
                "topK": 5,
            ],
            timeout: 20
        )
        let visibleJSON = try parseToolResourceJSON(fromResponseLine: visible, uriSuffix: "memory-search-summary")
        let visibleResults = try requireArray(visibleJSON, key: "results")
        #expect(!visibleResults.isEmpty)
        #expect(visibleResults.contains { result in
            guard let object = try? requireObject(result) else { return false }
            return (object["session_id"] as? String) == sessionA && (object["horizon"] as? String) == "working"
        })
    }

    @Test(.timeLimit(.minutes(2)))
    func brokerBackedHighVolumeWorkingMemoryRemainsSearchable() async throws {
        let harness = try MCPServerProcessHarness()
        try harness.start()
        defer { harness.terminateIfNeeded() }

        _ = try await harness.bootstrap(
            clientName: "wax-mcp-high-volume-session-test",
            includeToolsList: true
        )

        let started = try await harness.callTool(id: 53, name: "session_start", arguments: [:], timeout: 20)
        let sessionID = try requireString(try parseToolTextJSON(fromResponseLine: started), key: "session_id")

        for index in 0..<8 {
            _ = try await harness.callTool(
                id: 100 + index,
                name: "memory_append",
                arguments: [
                    "content": "HIGH_VOLUME_ANCHOR_\(index) broker session memory event \(index) for endurance coverage.",
                    "session_id": sessionID,
                ],
                timeout: 20
            )
        }

        _ = try await harness.callTool(
            id: 180,
            name: "compact_context",
            arguments: [
                "query": "HIGH_VOLUME_ANCHOR_5",
                "session_id": sessionID,
                "token_budget": 768,
                "mode": "text",
            ],
            timeout: 20
        )

        let search = try await harness.callTool(
            id: 181,
            name: "memory_search",
            arguments: [
                "query": "HIGH_VOLUME_ANCHOR_5",
                "session_id": sessionID,
                "mode": "text",
                "topK": 8,
            ],
            timeout: 20
        )
        let searchJSON = try parseToolResourceJSON(fromResponseLine: search, uriSuffix: "memory-search-summary")
        let results = try requireArray(searchJSON, key: "results")
        #expect(!results.isEmpty)
        #expect(search.contains("HIGH_VOLUME_ANCHOR_5"))
    }

    @Test(.timeLimit(.minutes(1)))
    func brokerBackedMarkdownExportProjectsCompatibilityFiles() async throws {
        let harness = try MCPServerProcessHarness()
        try harness.start()
        defer { harness.terminateIfNeeded() }

        _ = try await harness.bootstrap(
            clientName: "wax-mcp-markdown-export-test",
            includeToolsList: true
        )

        let started = try await harness.callTool(id: 51, name: "session_start", arguments: [:], timeout: 20)
        let sessionID = try requireString(try parseToolTextJSON(fromResponseLine: started), key: "session_id")

        _ = try await harness.callTool(
            id: 52,
            name: "remember",
            arguments: [
                "content": "Markdown export anchor: durable facts should project into MEMORY.md.",
                "memory_type": "fact",
                "durability": "durable",
            ],
            timeout: 20
        )
        _ = try await harness.callTool(
            id: 53,
            name: "remember",
            arguments: [
                "content": "Decision: use Markdown approvals to promote durable OpenClaw learnings.",
                "session_id": sessionID,
            ],
            timeout: 20
        )
        _ = try await harness.callTool(
            id: 54,
            name: "handoff",
            arguments: [
                "content": "Markdown export handoff anchor.",
                "session_id": sessionID,
            ],
            timeout: 20
        )

        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-markdown-export-\(UUID().uuidString)", isDirectory: true)

        let export = try await harness.callTool(
            id: 55,
            name: "markdown_export",
            arguments: [
                "output_dir": outputDir.path,
                "session_id": sessionID,
            ],
            timeout: 20
        )
        let exportJSON = try parseToolTextJSON(fromResponseLine: export)
        let memoryPath = try requireString(exportJSON, key: "memory_md_path")
        let memoryText = try String(contentsOfFile: memoryPath, encoding: .utf8)
        #expect(memoryText.contains("Markdown export anchor"))

        let handoffPath = try #require(exportJSON["handoff_summary_path"] as? String)
        let handoffText = try String(contentsOfFile: handoffPath, encoding: .utf8)
        #expect(handoffText.contains("Markdown export handoff anchor"))

        let dreamsPath = try #require(exportJSON["dreams_path"] as? String)
        let dreamsText = try String(contentsOfFile: dreamsPath, encoding: .utf8)
        #expect(dreamsText.contains("Markdown approvals"))
        #expect(dreamsText.contains("- [ ]"))
    }

    @Test(.timeLimit(.minutes(2)))
    func brokerBackedMarkdownSyncReconcilesManagedFilesAndApprovesDreams() async throws {
        let harness = try MCPServerProcessHarness()
        try harness.start()
        defer { harness.terminateIfNeeded() }

        _ = try await harness.bootstrap(
            clientName: "wax-mcp-markdown-sync-test",
            includeToolsList: true
        )

        let started = try await harness.callTool(id: 61, name: "session_start", arguments: [:], timeout: 20)
        let sessionID = try requireString(try parseToolTextJSON(fromResponseLine: started), key: "session_id")

        _ = try await harness.callTool(
            id: 62,
            name: "remember",
            arguments: [
                "content": "Original markdown-managed fact anchor.",
                "memory_type": "fact",
                "durability": "durable",
            ],
            timeout: 20
        )
        _ = try await harness.callTool(
            id: 63,
            name: "remember",
            arguments: [
                "content": "Decision: promote DREAMS approvals into durable memory.",
                "session_id": sessionID,
            ],
            timeout: 20
        )

        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-markdown-sync-\(UUID().uuidString)", isDirectory: true)
        let export = try await harness.callTool(
            id: 64,
            name: "markdown_export",
            arguments: [
                "output_dir": outputDir.path,
                "session_id": sessionID,
            ],
            timeout: 20
        )
        let exportJSON = try parseToolTextJSON(fromResponseLine: export)
        let memoryPath = try requireString(exportJSON, key: "memory_md_path")
        let dreamsPath = try #require(exportJSON["dreams_path"] as? String)
        let dailyPaths = try requireArray(exportJSON, key: "daily_note_paths")
        let dailyPath = try #require(dailyPaths.first as? String)

        var memoryText = try String(contentsOfFile: memoryPath, encoding: .utf8)
        memoryText = memoryText.replacingOccurrences(
            of: "Original markdown-managed fact anchor.",
            with: "Updated markdown-managed fact anchor."
        )
        try memoryText.write(toFile: memoryPath, atomically: true, encoding: .utf8)

        let importedDailyText = "Imported daily note anchor."
        let dailyDateKey = URL(fileURLWithPath: dailyPath).deletingPathExtension().lastPathComponent
        let dailyMarker = MarkdownProjectionMarker(
            sourceKind: MarkdownProjectionKind.dailyNote.rawValue,
            hash: AgentBrokerService.stableHash(importedDailyText),
            memoryType: MemoryType.note.rawValue,
            durability: MemoryDurability.working.rawValue,
            dateKey: dailyDateKey
        )
        var dailyText = try String(contentsOfFile: dailyPath, encoding: .utf8)
        dailyText.append("\n- \(importedDailyText) \(BrokerMarkdownSync.markerComment(dailyMarker))\n")
        try dailyText.write(toFile: dailyPath, atomically: true, encoding: .utf8)

        var dreamsText = try String(contentsOfFile: dreamsPath, encoding: .utf8)
        dreamsText = dreamsText.replacingOccurrences(of: "- [ ]", with: "- [x]", options: [], range: dreamsText.range(of: "- [ ]"))
        try dreamsText.write(toFile: dreamsPath, atomically: true, encoding: .utf8)

        let sync = try await harness.callTool(
            id: 65,
            name: "markdown_sync",
            arguments: [
                "root_dir": outputDir.path,
            ],
            timeout: 60
        )
        let syncJSON = try parseToolTextJSON(fromResponseLine: sync)
        let counts = try requireObject(syncJSON, key: "counts")
        #expect((counts["updated"] as? Int ?? 0) >= 1)
        #expect((counts["created"] as? Int ?? 0) >= 1)
        #expect((counts["approved_dreams"] as? Int ?? 0) >= 1)

        let updatedFact = try await harness.callTool(
            id: 66,
            name: "search",
            arguments: [
                "query": "Updated markdown-managed fact anchor",
                "topK": 5,
            ],
            timeout: 20
        )
        #expect(updatedFact.contains("Updated markdown-managed fact anchor"))

        let importedDaily = try await harness.callTool(
            id: 67,
            name: "search",
            arguments: [
                "query": "Imported daily note anchor",
                "topK": 5,
            ],
            timeout: 20
        )
        #expect(importedDaily.contains("Imported daily note anchor"))

        let approvedDream = try await harness.callTool(
            id: 68,
            name: "search",
            arguments: [
                "query": "promote DREAMS approvals into durable memory",
                "topK": 5,
            ],
            timeout: 20
        )
        #expect(approvedDream.contains("DREAMS approvals"))
    }

    @Test(.timeLimit(.minutes(1)))
    func brokerAutoStartHandlesConcurrentFirstAccess() async throws {
        let sharedStoreURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-mcp-concurrent-start-\(UUID().uuidString)")
            .appendingPathExtension("wax")

        let first = try MCPServerProcessHarness(storeURL: sharedStoreURL)
        let second = try MCPServerProcessHarness(storeURL: sharedStoreURL)
        try first.start()
        try second.start()
        defer {
            first.terminateIfNeeded()
            second.terminateIfNeeded()
        }

        async let firstBootstrap: MCPServerProcessHarness.BootstrapResult = first.bootstrap(
            clientName: "wax-mcp-concurrent-first",
            initializeID: 11,
            includeToolsList: true,
            toolsListID: 12,
            initializeTimeout: 30,
            toolsListTimeout: 20
        )
        async let secondBootstrap: MCPServerProcessHarness.BootstrapResult = second.bootstrap(
            clientName: "wax-mcp-concurrent-second",
            initializeID: 21,
            includeToolsList: true,
            toolsListID: 22,
            initializeTimeout: 30,
            toolsListTimeout: 20
        )
        let firstResult = try await firstBootstrap
        let secondResult = try await secondBootstrap

        #expect(firstResult.initialize.contains(#""protocolVersion":"2024-11-05""#))
        #expect(firstResult.toolsList?.contains(#""name":"remember""#) == true)
        #expect(secondResult.initialize.contains(#""protocolVersion":"2024-11-05""#))
        #expect(secondResult.toolsList?.contains(#""name":"remember""#) == true)
    }

    @Test(
        .timeLimit(.minutes(3)),
        .disabled(
            if: ProcessInfo.processInfo.environment["WAX_TEST_MINILM"] != "1",
            "Set WAX_TEST_MINILM=1 to run MiniLM embedder inference tests"
        )
    )
    func waxMCPProcessRememberWithRealCoreMLEmbedder() async throws {
        let harness = try MCPServerProcessHarness(useRealEmbedder: true)
        try harness.start()
        defer { harness.terminateIfNeeded() }

        let initStart = Date()
        let bootstrap = try await harness.bootstrap(
            clientName: "wax-mcp-coreml-test",
            includeToolsList: true,
            toolsListID: 99,
            initializeTimeout: 20,
            toolsListTimeout: 5
        )
        let initElapsed = Date().timeIntervalSince(initStart)
        #expect(bootstrap.initialize.contains(#""protocolVersion":"2024-11-05""#))
        #expect(initElapsed < 10)

        // 200+ word content → forces 256-token bucket (NOT prewarmed)
        let longContent = """
        The architecture of modern distributed systems requires careful consideration \
        of consistency models, partition tolerance, and availability guarantees as \
        described by the CAP theorem. When designing microservices that communicate \
        via message queues and event-driven architectures, developers must account for \
        eventual consistency, idempotent message processing, and proper dead-letter \
        queue handling. The Swift programming language provides excellent support for \
        building concurrent applications through its actor model, which isolates \
        mutable state and prevents data races at compile time. Combined with async/await \
        syntax and structured concurrency via task groups, Swift enables developers to \
        write safe, performant server-side applications. Core ML on Apple platforms \
        offers on-device machine learning inference with support for neural engine \
        acceleration, but careful attention must be paid to model compilation, \
        sequence length bucketing, and thread pool management to avoid performance \
        bottlenecks. The MiniLM model produces 384-dimensional dense embeddings \
        suitable for semantic search and retrieval-augmented generation workflows.
        """

        var rememberResp = try await harness.callTool(
            id: 2,
            name: "remember",
            arguments: ["content": longContent],
            timeout: 120
        )
        let rememberJSON: [String: Any]
        do {
            rememberJSON = try parseToolTextJSON(fromResponseLine: rememberResp)
        } catch {
            // One retry: CoreML compile/load can lose a race under `swift test --parallel`.
            rememberResp = try await harness.callTool(
                id: 22,
                name: "remember",
                arguments: ["content": longContent],
                timeout: 120
            )
            rememberJSON = try parseToolTextJSON(fromResponseLine: rememberResp)
        }
        #expect((rememberJSON["status"] as? String) == "ok")

        let recallResp = try await harness.callTool(
            id: 3,
            name: "recall",
            arguments: ["query": "Swift concurrency", "limit": 3, "scope": "global"],
            timeout: 30
        )
        #expect(recallResp.contains("result"))

        try harness.closeInput()
        #expect(try await harness.waitForExit(timeout: 10) == EXIT_SUCCESS)
        let stderr = harness.stderrSnapshot()
        #expect(stderr.contains("wax-mcp v\(WaxMCPServerMetadata.version) starting"))
    }

    @Test(.timeLimit(.minutes(1)))
    func waxMCPStartupReusesBrokerForSharedStore() async throws {
        let sharedStoreURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-mcp-startup-lock-\(UUID().uuidString)")
            .appendingPathExtension("wax")

        let first = try MCPServerProcessHarness(storeURL: sharedStoreURL)
        try first.start()
        defer { first.terminateIfNeeded() }

        _ = try await first.bootstrap(
            clientName: "wax-mcp-first-lock-test",
            includeToolsList: true
        )

        let second = try MCPServerProcessHarness(storeURL: sharedStoreURL)
        let start = Date()
        try second.start()
        defer { second.terminateIfNeeded() }

        let bootstrap = try await second.bootstrap(
            clientName: "wax-mcp-second-lock-test",
            includeToolsList: true,
            initializeTimeout: 10,
            toolsListTimeout: 10
        )
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 4)
        let stderr = second.stderrSnapshot()
        #expect(bootstrap.initialize.contains(#""protocolVersion":"2024-11-05""#))
        #expect(bootstrap.toolsList?.contains(#""name":"remember""#) == true)
        #expect(!stderr.localizedCaseInsensitiveContains("use a unique --store-path"))
    }

    @Test(.timeLimit(.minutes(1)))
    func threeMCPClientsAttachToOneBrokerWithoutExclusiveLockTimeout() async throws {
        let sharedStoreURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-mcp-three-clients-\(UUID().uuidString)")
            .appendingPathExtension("wax")

        let first = try MCPServerProcessHarness(storeURL: sharedStoreURL)
        let second = try MCPServerProcessHarness(storeURL: sharedStoreURL)
        let third = try MCPServerProcessHarness(storeURL: sharedStoreURL)
        try first.start()
        try second.start()
        try third.start()
        defer {
            first.terminateIfNeeded()
            second.terminateIfNeeded()
            third.terminateIfNeeded()
        }

        _ = try await first.bootstrap(clientName: "wax-mcp-three-a", includeToolsList: true)
        _ = try await second.bootstrap(clientName: "wax-mcp-three-b", includeToolsList: true)
        _ = try await third.bootstrap(clientName: "wax-mcp-three-c", includeToolsList: true)

        let statsA = try await first.callTool(id: 41, name: "stats", arguments: [:], timeout: 15)
        let statsB = try await second.callTool(id: 42, name: "stats", arguments: [:], timeout: 15)
        let statsC = try await third.callTool(id: 43, name: "stats", arguments: [:], timeout: 15)
        #expect(!statsA.localizedCaseInsensitiveContains("Lock unavailable"))
        #expect(!statsB.localizedCaseInsensitiveContains("Lock unavailable"))
        #expect(!statsC.localizedCaseInsensitiveContains("Lock unavailable"))
        #expect(statsA.contains("frameCount") || statsA.contains("storePath"))
        #expect(first.brokerSocketPath == second.brokerSocketPath)
        #expect(second.brokerSocketPath == third.brokerSocketPath)
    }

    @Test(.timeLimit(.minutes(1)))
    func corpusSearchSkipsLockedBrokerManagedSessionStore() async throws {
        let harness = try MCPServerProcessHarness()
        try harness.start()
        defer { harness.terminateIfNeeded() }

        _ = try await harness.bootstrap(
            clientName: "wax-mcp-corpus-locked-session-test",
            includeToolsList: true
        )

        let lockedSessionStart = try await harness.callTool(id: 30, name: "session_start", arguments: [:], timeout: 20)
        let lockedSessionID = try requireString(try parseToolTextJSON(fromResponseLine: lockedSessionStart), key: "session_id")
        _ = try await harness.callTool(
            id: 31,
            name: "remember",
            arguments: [
                "content": "LOCKED_CORPUS_ONLY broker-managed session note",
                "session_id": lockedSessionID,
            ],
            timeout: 20
        )
        _ = try await harness.callTool(
            id: 32,
            name: "session_end",
            arguments: ["session_id": lockedSessionID],
            timeout: 20
        )

        let unlockedSessionStart = try await harness.callTool(id: 33, name: "session_start", arguments: [:], timeout: 20)
        let unlockedSessionID = try requireString(try parseToolTextJSON(fromResponseLine: unlockedSessionStart), key: "session_id")
        _ = try await harness.callTool(
            id: 34,
            name: "remember",
            arguments: [
                "content": "UNLOCKED_CORPUS_MATCH broker-managed session note",
                "session_id": unlockedSessionID,
            ],
            timeout: 20
        )
        _ = try await harness.callTool(
            id: 35,
            name: "session_end",
            arguments: ["session_id": unlockedSessionID],
            timeout: 20
        )

        let lockedStoreURL = harness.brokerSessionRootURL
            .appendingPathComponent("\(lockedSessionID).wax")
        let lockHolder = try await openTextOnlyMemory(at: lockedStoreURL, structuredMemoryEnabled: false)
        defer { Task { try? await lockHolder.close() } }

        let corpusSearch = try await harness.callTool(
            id: 36,
            name: "corpus_search",
            arguments: [
                "query": "UNLOCKED_CORPUS_MATCH",
                "mode": "text",
                "topK": 5,
                "rebuild": true,
            ],
            timeout: 20
        )
        let payload = try parseToolResourceJSON(
            fromResponseLine: corpusSearch,
            uriSuffix: "/corpus-search-summary"
        )
        let build = try requireObject(payload, key: "build")
        #expect(try requireInt(build, key: "stores_discovered") >= 2)
        #expect(try requireInt(build, key: "stores_indexed") >= 1)
        #expect(try requireInt(build, key: "stores_skipped") >= 1)
        let results = try requireArray(payload, key: "results")
        #expect(!results.isEmpty)
        #expect(results.contains { result in
            guard let object = try? requireObject(result) else {
                return false
            }
            let preview = object["preview"] as? String ?? ""
            return preview.contains("UNLOCKED") && preview.contains("MATCH")
        })
    }

    @Test(.timeLimit(.minutes(2)))
    func stdioRememberOversizeKeepsProcessAlive() async throws {
        let harness = try MCPServerProcessHarness()
        try harness.start()
        defer { harness.terminateIfNeeded() }

        _ = try await harness.bootstrap(clientName: "wax-mcp-oversize-remember", includeToolsList: true)
        let pid = harness.processIdentifier
        #expect(harness.isRunning)

        for (id, count) in [(10, 131_073), (11, 1_048_576), (12, 1_100_000)] {
            let response = try await harness.callTool(
                id: id,
                name: "remember",
                arguments: ["content": String(repeating: "a", count: count)],
                timeout: 30
            )
            #expect(harness.isRunning, "wax-mcp died after remember \(count) bytes; pid=\(pid)")
            #expect(response.contains("131072") || response.localizedCaseInsensitiveContains("maxContent"))
            #expect(response.contains("isError") || response.contains("error") || response.contains("content exceeds"))
        }

        #expect(harness.isRunning)
        #expect(harness.processIdentifier == pid)
    }

    @Test(.timeLimit(.minutes(1)))
    func customStorePathDoesNotWriteProductSessionRoot() async throws {
        let productSessions = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/waxmcp/sessions", isDirectory: true)
        let before = Set(
            (try? FileManager.default.contentsOfDirectory(atPath: productSessions.path)) ?? []
        )

        let sessionRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-sess-explicit-\(UUID().uuidString)", isDirectory: true)
        let harness = try MCPServerProcessHarness(
            extraArguments: ["--session-root", sessionRoot.path],
            isolateSessionRootEnv: false
        )
        try harness.start()
        defer { harness.terminateIfNeeded() }

        _ = try await harness.bootstrap(clientName: "wax-mcp-session-root-flag", includeToolsList: true)
        let started = try await harness.callTool(
            id: 3,
            name: "session_start",
            arguments: ["verbosity": "verbose"],
            timeout: 20
        )
        #expect(started.contains("store_path"))
        #expect(started.contains(sessionRoot.path))

        let after = Set(
            (try? FileManager.default.contentsOfDirectory(atPath: productSessions.path)) ?? []
        )
        #expect(after.subtracting(before).isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func isolatedCustomStoreDoesNotCreateProductSessionFiles() async throws {
        let productSessions = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/waxmcp/sessions", isDirectory: true)
        let before = Set(
            (try? FileManager.default.contentsOfDirectory(atPath: productSessions.path)) ?? []
        )

        let harness = try MCPServerProcessHarness(isolateSessionRootEnv: false)
        try harness.start()
        defer { harness.terminateIfNeeded() }

        _ = try await harness.bootstrap(clientName: "wax-mcp-isolated-store-no-product-sessions")
        let started = try await harness.callTool(
            id: 3,
            name: "session_start",
            arguments: ["verbosity": "verbose"],
            timeout: 20
        )
        #expect(started.contains("store_path"))
        #expect(started.contains("/.local/share/waxmcp/sessions") == false)

        let after = Set(
            (try? FileManager.default.contentsOfDirectory(atPath: productSessions.path)) ?? []
        )
        #expect(after.subtracting(before).isEmpty)
        #expect(harness.storeURL.path.contains(".local/share/waxmcp/sessions") == false)

        let storeParent = harness.storeURL.deletingLastPathComponent()
        let siblingSessions = (try? FileManager.default.contentsOfDirectory(at: storeParent, includingPropertiesForKeys: nil)) ?? []
        #expect(siblingSessions.contains { $0.lastPathComponent.hasPrefix("sessions-") })
    }

    @Test(.timeLimit(.minutes(1)))
    func twoClientsStatsDoNotImpersonateEachOther() async throws {
        let sharedStoreURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-mcp-stats-impersonation-\(UUID().uuidString)")
            .appendingPathExtension("wax")
        let first = try MCPServerProcessHarness(storeURL: sharedStoreURL)
        let second = try MCPServerProcessHarness(storeURL: sharedStoreURL)
        try first.start()
        try second.start()
        defer {
            first.terminateIfNeeded()
            second.terminateIfNeeded()
        }

        _ = try await first.bootstrap(clientName: "wax-mcp-stats-client-a")
        _ = try await second.bootstrap(clientName: "wax-mcp-stats-client-b")

        let startA = try await first.callTool(id: 3, name: "session_start", arguments: [:], timeout: 20)
        let startB = try await second.callTool(id: 3, name: "session_start", arguments: [:], timeout: 20)
        let sessionA = try requireString(try parseToolTextJSON(fromResponseLine: startA), key: "session_id")
        let sessionB = try requireString(try parseToolTextJSON(fromResponseLine: startB), key: "session_id")
        #expect(sessionA != sessionB)

        let statsA = try await first.callTool(id: 4, name: "stats", arguments: [:], timeout: 20)
        let statsB = try await second.callTool(id: 4, name: "stats", arguments: [:], timeout: 20)
        let sessionObjectA = try requireObject(try parseToolTextJSON(fromResponseLine: statsA), key: "session")
        let sessionObjectB = try requireObject(try parseToolTextJSON(fromResponseLine: statsB), key: "session")
        #expect(sessionObjectA["session_id"] as? String == sessionA)
        #expect(sessionObjectB["session_id"] as? String == sessionB)
        #expect(sessionA != sessionB)
    }

    @Test
    func waxMCPAndCLIVersionFlagsExitZero() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let packageJSON = packageRoot
            .appendingPathComponent("Resources/npm/waxmcp/package.json")
        let packageData = try Data(contentsOf: packageJSON)
        let packageObject = try JSONSerialization.jsonObject(with: packageData) as? [String: Any]
        let expectedVersion = try #require(packageObject?["version"] as? String)

        let mcp = try MCPServerProcessHarness.waxMCPBinaryURLForTests(packageRoot: packageRoot)
        try expectVersion(executable: mcp, expectedSubstring: expectedVersion)

        let cliCandidates = [
            mcp.deletingLastPathComponent().appendingPathComponent("wax-cli"),
            packageRoot.appendingPathComponent(".build/debug/wax-cli"),
            packageRoot.appendingPathComponent(".build/arm64-apple-macosx/debug/wax-cli"),
        ]
        let cli = try #require(cliCandidates.first { FileManager.default.isExecutableFile(atPath: $0.path) })
        try expectVersion(executable: cli, expectedSubstring: expectedVersion)
    }
}

private func expectVersion(executable: URL, expectedSubstring: String) throws {
    let process = Process()
    process.executableURL = executable
    process.arguments = ["--version"]
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()
    let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    #expect(process.terminationStatus == 0)
    #expect((output + err).contains(expectedSubstring))
}

#else
@Test
func mcpServerTestsRequireTrait() {
    #expect(Bool(true))
}
#endif
