import Foundation
import Testing
import WaxMILRuntime

struct MILParserTests {
    static let sample = #"""
    program(1.3)
    [buildInfo = dict<string, string>({{"coremlc-version", "3600.25.1"}, {"coremltools-version", "9.0"}})]
    {
        func main<ios18>(tensor<int32, [?, ?]> attention_mask, tensor<int32, [?, 4]> input_ids) [FlexibleShapeInformation = tuple<tuple<string, dict<string, tensor<int32, [?]>>>>((("DefaultShapes", {{"input_ids", [1, 32]}})))] {
                tensor<int32, [1]> axes = const()[name = string("axes"), val = tensor<int32, [1]>([-1])];
                string dt = const()[name = string("dt"), val = string("fp32")];
                tensor<fp32, [?, ?]> mask = cast(dtype = dt, x = attention_mask)[name = string("cast_0")];
                tensor<fp16, [2, 3]> w = constexpr_blockwise_shift_scale(data = tensor<int8, [2, 3]>(BLOBFILE(path = string("@model_path/weights/weight.bin"), offset = uint64(64))), scale = tensor<fp16, [2, 1]>(BLOBFILE(path = string("@model_path/weights/weight.bin"), offset = uint64(192))))[name = string("w")];
                int32 n = const()[name = string("n"), val = int32(7)];
                tensor<int32, [2]> c = concat(axis = n, interleave = flag, values = (n, n))[name = string("c")];
            } -> (mask, c);
    }
    """#

    @Test func parsesProgramHeaderSignatureAndOutputs() throws {
        let program = try MILProgram(parsing: Self.sample)
        #expect(program.version == "1.3")
        let main = try #require(program.functions["main"])
        #expect(main.opset == "ios18")
        #expect(main.inputs == [
            MILNamedType(name: "attention_mask", type: .tensor(.int32, [.unknown, .unknown])),
            MILNamedType(name: "input_ids", type: .tensor(.int32, [.unknown, .fixed(4)])),
        ])
        #expect(main.outputs == ["mask", "c"])
        #expect(main.operations.map(\.opType) == ["const", "const", "cast", "constexpr_blockwise_shift_scale", "const", "concat"])
    }

    @Test func parsesConstValuesFromTheAttributeBlock() throws {
        let main = try #require(try MILProgram(parsing: Self.sample).functions["main"])
        #expect(main.operations[0].outputs == [MILNamedType(name: "axes", type: .tensor(.int32, [.fixed(1)]))])
        #expect(main.operations[0].value == .tensor(dataType: .int32, shape: [1], values: [-1]))
        #expect(main.operations[1].value == .string("fp32"))
        #expect(main.operations[1].outputs[0].type == .scalar(.string))
        #expect(main.operations[4].value == .tensor(dataType: .int32, shape: [], values: [7]))
    }

    @Test func parsesVariableLiteralAndTupleArguments() throws {
        let main = try #require(try MILProgram(parsing: Self.sample).functions["main"])
        let cast = main.operations[2]
        #expect(cast.arguments["x"] == .variable("attention_mask"))
        #expect(cast.arguments["dtype"] == .variable("dt"))
        #expect(cast.outputs[0].type == .tensor(.fp32, [.unknown, .unknown]))

        let dequant = main.operations[3]
        #expect(dequant.arguments["data"] == .literal(.blob(dataType: .int8, shape: [2, 3], path: "@model_path/weights/weight.bin", offset: 64)))
        #expect(dequant.arguments["scale"] == .literal(.blob(dataType: .fp16, shape: [2, 1], path: "@model_path/weights/weight.bin", offset: 192)))

        let concat = main.operations[5]
        #expect(concat.arguments["values"] == .tuple([.variable("n"), .variable("n")]))
    }

    @Test(arguments: [
        ("fp32(0x1.197998p-40)", MILDataType.fp32, Double(Float(0x1.197998p-40))),
        ("fp32(-0x1.fffffep+127)", .fp32, -Double(Float.greatestFiniteMagnitude)),
        ("fp16(inf)", .fp16, Double.infinity),
        ("fp16(-0x1.388p+13)", .fp16, -10000),
        ("fp32(0x1.6a09e6p-3)", .fp32, Double(Float(0x1.6a09e6p-3))),
        ("int32(-1)", .int32, -1),
        ("uint16(65535)", .uint16, 65535),
        ("bool(true)", .bool, 1),
        ("bool(false)", .bool, 0),
    ])
    func parsesScalarLiterals(text: String, dataType: MILDataType, expected: Double) throws {
        let source = program(outputs: "v", "        \(dataType.rawValue) v = const()[name = string(\"v\"), val = \(text)];")
        let op = try #require(try MILProgram(parsing: source).functions["main"]?.operations.first)
        #expect(op.value == .tensor(dataType: dataType, shape: [], values: [expected]))
    }

    @Test func parsesStringEscapesAndBoolTensors() throws {
        let source = program(outputs: "s, b", #"""
                string s = const()[name = string("s"), val = string("a \"quoted\" \\ name")];
                tensor<bool, [3]> b = const()[name = string("b"), val = tensor<bool, [3]>([true, false, true])];
        """#)
        let ops = try #require(try MILProgram(parsing: source).functions["main"]?.operations)
        #expect(ops[0].value == .string(#"a "quoted" \ name"#))
        #expect(ops[1].value == .tensor(dataType: .bool, shape: [3], values: [1, 0, 1]))
    }

    @Test func rejectsATensorLiteralWithTheWrongElementCount() {
        let source = program(outputs: "t", "        tensor<int32, [3]> t = const()[name = string(\"t\"), val = tensor<int32, [3]>([1, 2])];")
        #expect(throws: MILRuntimeError.self) { try MILProgram(parsing: source) }
    }

    @Test func reportsTheLineOfASyntaxError() throws {
        let source = "program(1.3)\n{\n    func main<ios18>() {\n        tensor<fp32, [1]> y = add(x = , y = b)[name = string(\"y\")];\n    } -> (y);\n}\n"
        do {
            _ = try MILProgram(parsing: source)
            Issue.record("expected a parse error")
        } catch let error as MILRuntimeError {
            guard case .parse(let line, _, _) = error else {
                Issue.record("unexpected error \(error)")
                return
            }
            #expect(line == 4)
        }
    }

    /// Operation counts taken from `grep -c '= <op>('` over each bundled model.mil.
    @Test(arguments: [
        (BundledModel.miniLM, ["linear": 36, "matmul": 12, "layer_norm": 13, "softmax": 6, "gelu": 6, "reduce_sum": 2]),
        (.e5, ["linear": 72, "matmul": 24, "layer_norm": 25, "constexpr_blockwise_shift_scale": 74, "reduce_l2_norm": 1]),
        (.arctic, ["linear": 72, "matmul": 24, "constexpr_blockwise_shift_scale": 74, "slice_by_index": 3, "select": 7]),
        (.reranker, ["linear": 38, "matmul": 12, "constexpr_blockwise_shift_scale": 39, "tanh": 1, "cast": 37]),
    ])
    func parsesEveryBundledModel(model: BundledModel, expectedCounts: [String: Int]) throws {
        let text = try String(contentsOf: model.programURL, encoding: .utf8)
        let program = try MILProgram(parsing: text)
        let main = try #require(program.functions["main"])
        var counts: [String: Int] = [:]
        for op in main.operations { counts[op.opType, default: 0] += 1 }
        for (op, expected) in expectedCounts {
            #expect(counts[op] == expected, "\(model) \(op)")
        }
        let names = Set(main.inputs.map(\.name))
        #expect(names.isSuperset(of: ["input_ids", "attention_mask"]))
        #expect(names.contains("token_type_ids") == (model == .reranker))
        #expect(main.outputs == [model.outputName])
    }
}
