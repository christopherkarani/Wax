import Foundation
import WaxCore

extension BrokerCommand {
    /// Wire JSON/string → ``FactValue``. Shared by `fact_assert` and
    /// `knowledge_capture` decode.
    package static func parseFactValue(_ value: AgentBrokerValue) throws -> FactValue {
        switch value {
        case .string(let raw):
            return .string(raw)
        case .bool(let raw):
            return .bool(raw)
        case .int(let raw):
            return .int(raw)
        case .double(let raw):
            return .double(raw)
        case .object(let raw):
            if raw.count == 2,
               let type = raw["type"]?.stringValue,
               let genericValue = raw["value"] {
                switch type {
                case "entity":
                    guard let entity = genericValue.stringValue else {
                        throw BrokerValidationError.invalid("entity typed object value must be a string")
                    }
                    return .entity(EntityKey(entity))
                case "time_ms":
                    guard let time = genericValue.intValue else {
                        throw BrokerValidationError.invalid("time_ms typed object value must be an integer")
                    }
                    return .timeMs(time)
                case "data_base64":
                    guard let data = genericValue.stringValue, let decoded = Data(base64Encoded: data) else {
                        throw BrokerValidationError.invalid("data_base64 typed object value must be a base64 string")
                    }
                    return .data(decoded)
                default:
                    throw BrokerValidationError.invalid("typed object type must be one of: entity, time_ms, data_base64")
                }
            }
            if let entity = raw["entity"]?.stringValue, raw.count == 1 {
                return .entity(EntityKey(entity))
            }
            if let time = raw["time_ms"]?.intValue, raw.count == 1 {
                return .timeMs(time)
            }
            if let data = raw["data_base64"]?.stringValue, raw.count == 1, let decoded = Data(base64Encoded: data) {
                return .data(decoded)
            }
            throw BrokerValidationError.invalid("typed object values must be one of {entity}, {time_ms}, or {data_base64}")
        default:
            throw BrokerValidationError.invalid("object must be a string, number, bool, or typed object")
        }
    }

    package static func parseVersionRelation(_ raw: String) throws -> VersionRelation {
        guard let relation = VersionRelation(wireName: raw) else {
            throw BrokerValidationError.invalid("relation must be one of: sets, updates, extends, retracts")
        }
        return relation
    }

    package static func parseStructuredEvidence(_ value: AgentBrokerValue?) throws -> [StructuredEvidence] {
        guard let value else { return [] }
        guard let array = value.arrayValue else {
            throw BrokerValidationError.invalid("evidence must be an array")
        }
        return try array.map { item in
            guard let object = item.objectValue else {
                throw BrokerValidationError.invalid("evidence must contain only objects")
            }
            let allowedKeys: Set<String> = [
                "source_frame_id",
                "chunk_index",
                "span_start_utf8",
                "span_end_utf8",
                "extractor_id",
                "extractor_version",
                "confidence",
                "asserted_at_ms",
            ]
            let unknownKeys = Set(object.keys).subtracting(allowedKeys)
            guard unknownKeys.isEmpty else {
                throw BrokerValidationError.invalid("unknown evidence fields: \(unknownKeys.sorted().joined(separator: ", "))")
            }
            guard let sourceFrameId = object["source_frame_id"], case .int(let sourceRaw) = sourceFrameId, sourceRaw >= 0 else {
                throw BrokerValidationError.invalid("evidence.source_frame_id must be a non-negative integer")
            }
            let chunkIndex: UInt32? = try {
                guard let value = object["chunk_index"] else { return nil }
                guard case .int(let raw) = value, raw >= 0, raw <= Int64(UInt32.max) else {
                    throw BrokerValidationError.invalid("evidence.chunk_index must be a non-negative integer")
                }
                return UInt32(raw)
            }()
            let span = try parseEvidenceSpan(object)
            let extractorId = try requiredEvidenceString(object, key: "extractor_id")
            let extractorVersion = try requiredEvidenceString(object, key: "extractor_version")
            let confidence = try parseEvidenceConfidence(object["confidence"])
            guard let assertedAtValue = object["asserted_at_ms"], case .int(let assertedAtMs) = assertedAtValue else {
                throw BrokerValidationError.invalid("evidence.asserted_at_ms must be an integer")
            }
            return StructuredEvidence(
                sourceFrameId: UInt64(sourceRaw),
                chunkIndex: chunkIndex,
                spanUTF8: span,
                extractorId: extractorId,
                extractorVersion: extractorVersion,
                confidence: confidence,
                assertedAtMs: assertedAtMs
            )
        }
    }

    private static func parseEvidenceSpan(_ object: [String: AgentBrokerValue]) throws -> Range<Int>? {
        guard object["span_start_utf8"] != nil || object["span_end_utf8"] != nil else {
            return nil
        }
        guard let startValue = object["span_start_utf8"], case .int(let startRaw) = startValue,
              let endValue = object["span_end_utf8"], case .int(let endRaw) = endValue,
              startRaw >= 0, endRaw > startRaw,
              startRaw <= Int64(Int.max), endRaw <= Int64(Int.max) else {
            throw BrokerValidationError.invalid("evidence span must include non-negative span_start_utf8 and greater span_end_utf8")
        }
        return Int(startRaw)..<Int(endRaw)
    }

    private static func requiredEvidenceString(_ object: [String: AgentBrokerValue], key: String) throws -> String {
        guard let value = object[key], let raw = value.stringValue else {
            throw BrokerValidationError.invalid("evidence.\(key) must be a string")
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw BrokerValidationError.invalid("evidence.\(key) must not be empty")
        }
        return trimmed
    }

    private static func parseEvidenceConfidence(_ value: AgentBrokerValue?) throws -> Double? {
        guard let value else { return nil }
        guard let confidence = value.doubleValue, confidence.isFinite, (0...1).contains(confidence) else {
            throw BrokerValidationError.invalid("evidence.confidence must be a finite number between 0 and 1")
        }
        return confidence
    }
}
