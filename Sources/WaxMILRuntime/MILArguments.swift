import Foundation

/// The operations this interpreter implements: the union of what the bundled embedding and
/// reranker programs use, plus the comparison family that shares its kernel.
enum MILOpKind: String, Sendable {
    case add, sub, mul
    case realDiv = "real_div"
    case equal
    case notEqual = "not_equal"
    case greater
    case greaterEqual = "greater_equal"
    case less
    case lessEqual = "less_equal"
    case select
    case cast
    case clip
    case concat
    case constexprBlockwiseShiftScale = "constexpr_blockwise_shift_scale"
    case expandDims = "expand_dims"
    case gather
    case gelu
    case layerNorm = "layer_norm"
    case linear
    case matmul
    case reduceL2Norm = "reduce_l2_norm"
    case reduceSum = "reduce_sum"
    case reshape
    case shape
    case sliceByIndex = "slice_by_index"
    case softmax
    case tanh
    case tile
    case transpose
}

/// Resolved operands of one instruction, with typed accessors that report errors against the
/// operation's name and source line.
struct MILArguments {
    let opType: String
    let line: Int
    private let values: [String: MILValue]

    init(instruction: Instruction, slots: [MILValue?]) throws {
        opType = instruction.opType
        line = instruction.line
        var values: [String: MILValue] = [:]
        for (key, operand) in instruction.operands {
            values[key] = try operand.resolve(slots, op: instruction.opType, line: instruction.line)
        }
        self.values = values
    }

    func failure(_ message: String) -> MILRuntimeError {
        .invalidArgument(op: opType, line: line, message: message)
    }

    func has(_ key: String) -> Bool { values[key] != nil }

    func tensor(_ key: String) throws -> MILTensor {
        guard let value = values[key] else { throw failure("missing argument \(key)") }
        guard case .tensor(let tensor) = value else { throw failure("argument \(key) must be a tensor") }
        return tensor
    }

    func optionalTensor(_ key: String) throws -> MILTensor? {
        values[key] == nil ? nil : try tensor(key)
    }

    func tensors(_ key: String) throws -> [MILTensor] {
        guard let value = values[key] else { throw failure("missing argument \(key)") }
        switch value {
        case .list(let items):
            return try items.map {
                guard case .tensor(let tensor) = $0 else { throw failure("argument \(key) must hold tensors") }
                return tensor
            }
        case .tensor(let tensor):
            return [tensor]
        case .string:
            throw failure("argument \(key) must be a tuple of tensors")
        }
    }

    func ints(_ key: String) throws -> [Int] {
        try tensor(key).int32s.map(Int.init)
    }

    func optionalInts(_ key: String) throws -> [Int]? {
        values[key] == nil ? nil : try ints(key)
    }

    func int(_ key: String, default fallback: Int? = nil) throws -> Int {
        guard values[key] != nil else {
            guard let fallback else { throw failure("missing argument \(key)") }
            return fallback
        }
        let all = try ints(key)
        guard all.count == 1 else { throw failure("argument \(key) must be a scalar") }
        return all[0]
    }

    func bool(_ key: String, default fallback: Bool) throws -> Bool {
        guard values[key] != nil else { return fallback }
        return try int(key) != 0
    }

    func bools(_ key: String) throws -> [Bool]? {
        values[key] == nil ? nil : try ints(key).map { $0 != 0 }
    }

    func float(_ key: String, default fallback: Float? = nil) throws -> Float {
        guard values[key] != nil else {
            guard let fallback else { throw failure("missing argument \(key)") }
            return fallback
        }
        let all = try tensor(key).floats
        guard all.count == 1 else { throw failure("argument \(key) must be a scalar") }
        return all[0]
    }

    func string(_ key: String, default fallback: String? = nil) throws -> String {
        guard let value = values[key] else {
            guard let fallback else { throw failure("missing argument \(key)") }
            return fallback
        }
        guard case .string(let text) = value else { throw failure("argument \(key) must be a string") }
        return text
    }

    /// Normalises a possibly negative axis against `rank`.
    func axis(_ value: Int, rank: Int) throws -> Int {
        let normalized = value < 0 ? value + rank : value
        guard normalized >= 0, normalized < max(rank, 1) else {
            throw failure("axis \(value) is out of range for rank \(rank)")
        }
        return normalized
    }
}
