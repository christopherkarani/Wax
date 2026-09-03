import Testing

#if MCPServer
import MCP
@testable import wax_mcp

@Suite
struct RememberSchemaMaxLengthTests {
    private static let advertisedMaxContentLength = 131_072

    @Test
    func rememberSchemaAdvertisesContentMaxLength() {
        #expect(contentMaxLength(ToolSchemas.waxRemember) == Self.advertisedMaxContentLength)
    }

    @Test
    func memoryAppendSchemaAdvertisesContentMaxLength() {
        #expect(contentMaxLength(ToolSchemas.waxMemoryAppend) == Self.advertisedMaxContentLength)
    }

    @Test
    func knowledgeCaptureSchemaAdvertisesContentMaxLength() {
        #expect(contentMaxLength(ToolSchemas.waxKnowledgeCapture) == Self.advertisedMaxContentLength)
    }

    @Test
    func toolsListPublishesContentMaxLength() {
        let schemas = Dictionary(
            uniqueKeysWithValues: ToolSchemas.tools(
                structuredMemoryEnabled: true,
                profile: .full
            ).map { ($0.name, $0.inputSchema) }
        )
        for name in ["remember", "memory_append", "knowledge_capture"] {
            #expect(
                contentMaxLength(schemas[name]) == Self.advertisedMaxContentLength,
                "\(name) tools/list schema must advertise content.maxLength \(Self.advertisedMaxContentLength)"
            )
        }
    }
}

private func contentMaxLength(_ schema: Value?) -> Int? {
    guard let schema,
          case .object(let root) = schema,
          case .object(let properties)? = root["properties"],
          case .object(let content)? = properties["content"]
    else {
        return nil
    }
    switch content["maxLength"] {
    case .int(let value):
        return value
    case .double(let value):
        return Int(value)
    default:
        return nil
    }
}
#endif
