import Foundation
import Wax

func brokerPayloadObject(_ response: AgentBrokerResponse) throws -> [String: AgentBrokerValue] {
    guard let payload = response.payload, let object = payload.objectValue else {
        throw CLIError("Broker returned an unexpected payload")
    }
    return object
}

func brokerString(_ object: [String: AgentBrokerValue], _ key: String) -> String? {
    object[key]?.stringValue
}

func brokerInt(_ object: [String: AgentBrokerValue], _ key: String) -> Int? {
    object[key]?.intValue.map(Int.init)
}

func brokerInt64(_ object: [String: AgentBrokerValue], _ key: String) -> Int64? {
    object[key]?.intValue
}

func brokerBool(_ object: [String: AgentBrokerValue], _ key: String) -> Bool? {
    object[key]?.boolValue
}

func brokerArray(_ object: [String: AgentBrokerValue], _ key: String) -> [AgentBrokerValue] {
    object[key]?.arrayValue ?? []
}

extension AgentBrokerValue {
    func toJSONObject() -> Any {
        switch self {
        case .null:
            return NSNull()
        case .bool(let value):
            return value
        case .int(let value):
            return value
        case .double(let value):
            return value
        case .string(let value):
            return value
        case .array(let values):
            return values.map { $0.toJSONObject() }
        case .object(let values):
            return values.mapValues { $0.toJSONObject() }
        }
    }
}

extension Dictionary where Key == String, Value == AgentBrokerValue {
    func toJSONObject() -> [String: Any] {
        mapValues { $0.toJSONObject() }
    }
}
