#if MCPServer
import MCP
import Wax

func brokerValue(from value: Value) -> AgentBrokerValue {
    switch value {
    case .null:
        return .null
    case .bool(let bool):
        return .bool(bool)
    case .int(let int):
        return .int(Int64(int))
    case .double(let double):
        return .double(double)
    case .string(let string):
        return .string(string)
    case .data(_, let data):
        return .string(data.base64EncodedString())
    case .array(let array):
        return .array(array.map(brokerValue(from:)))
    case .object(let object):
        return .object(object.mapValues(brokerValue(from:)))
    }
}

func mcpValue(from value: AgentBrokerValue) -> Value {
    switch value {
    case .null:
        return .null
    case .bool(let bool):
        return .bool(bool)
    case .int(let int):
        return .int(Int(int))
    case .double(let double):
        return .double(double)
    case .string(let string):
        return .string(string)
    case .array(let array):
        return .array(array.map(mcpValue(from:)))
    case .object(let object):
        return .object(object.mapValues(mcpValue(from:)))
    }
}
#endif
