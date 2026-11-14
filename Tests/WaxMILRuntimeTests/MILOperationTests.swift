import Foundation
import Testing
import WaxMILRuntime

private func floats(_ values: [Float], _ shape: [Int]) -> MILTensor { MILTensor(float32: values, shape: shape) }
private func ints(_ values: [Int32], _ shape: [Int]) -> MILTensor { MILTensor(int32: values, shape: shape) }

private func expectClose(_ actual: [Float], _ expected: [Float], tolerance: Float = 1e-5, _ comment: Comment? = nil) {
    #expect(actual.count == expected.count, comment)
    guard actual.count == expected.count else { return }
    let worst = maxAbsDifference(actual, expected)
    #expect(worst <= tolerance, "max |diff| \(worst): \(actual) vs \(expected) \(comment?.rawValue ?? "")")
}

struct MILBroadcastingTests {
    @Test func addBroadcastsLeadingAndInnerAxes() throws {
        // [2, 1, 3] + [4, 1] -> [2, 4, 3]
        let x: [Float] = [1, 2, 3, 10, 20, 30]
        let y: [Float] = [100, 200, 300, 400]
        let result = try runProgram(
            program(params: "tensor<fp32, [2, 1, 3]> x, tensor<fp32, [4, 1]> b",
                    "        tensor<fp32, [2, 4, 3]> y = add(x = x, y = b)[name = string(\"y\")];"),
            inputs: ["x": floats(x, [2, 1, 3]), "b": floats(y, [4, 1])]
        )
        #expect(result.shape == [2, 4, 3])
        var expected: [Float] = []
        for i in 0..<2 { for j in 0..<4 { for k in 0..<3 { expected.append(x[i * 3 + k] + y[j]) } } }
        #expect(result.floats == expected)
    }

    @Test func attentionMaskStyleBroadcastAndScalarOperands() throws {
        // scores [2, 3, 2, 2] + mask [2, 1, 1, 2]; then (1 - m) * -10000 with scalar first operand.
        var rng = SplitMix64(seed: 1)
        let scores = rng.floats(24)
        let mask: [Float] = [1, 0, 1, 1]
        let text = program(params: "tensor<fp32, [2, 3, 2, 2]> s, tensor<fp32, [2, 1, 1, 2]> m", """
                fp32 one = const()[name = string("one"), val = fp32(0x1p+0)];
                fp32 big = const()[name = string("big"), val = fp32(-0x1.388p+13)];
                tensor<fp32, [2, 1, 1, 2]> inv = sub(x = one, y = m)[name = string("inv")];
                tensor<fp32, [2, 1, 1, 2]> bias = mul(x = inv, y = big)[name = string("bias")];
                tensor<fp32, [2, 3, 2, 2]> y = add(x = s, y = bias)[name = string("y")];
        """)
        let result = try runProgram(text, inputs: ["s": floats(scores, [2, 3, 2, 2]), "m": floats(mask, [2, 1, 1, 2])])
        var expected: [Float] = []
        for b in 0..<2 { for h in 0..<3 { for q in 0..<2 { for k in 0..<2 {
            expected.append(scores[((b * 3 + h) * 2 + q) * 2 + k] + (1 - mask[b * 2 + k]) * -10000)
        } } } }
        #expect(result.floats == expected)
    }

    @Test func integerArithmeticAndRealDivTruncate() throws {
        let text = program(params: "tensor<int32, [2]> a, tensor<int32, [2]> b", outputs: "q, s", """
                tensor<int32, [2]> q = real_div(x = a, y = b)[name = string("q")];
                int32 k = const()[name = string("k"), val = int32(30522)];
                tensor<int32, [2]> s = add(x = a, y = k)[name = string("s")];
        """)
        let model = try MILModel(programText: text)
        let out = try model.predict(["a": ints([7, -7], [2]), "b": ints([2, 2], [2])])
        #expect(out["q"]?.int32s == [3, -3])
        #expect(out["q"]?.dataType == .int32)
        #expect(out["s"]?.int32s == [30529, 30515])
    }

    @Test(arguments: [
        ("equal", [false, true, false]),
        ("not_equal", [true, false, true]),
        ("greater", [false, false, true]),
        ("greater_equal", [false, true, true]),
        ("less", [true, false, false]),
        ("less_equal", [true, true, false]),
    ])
    func comparisonsAgainstAScalar(op: String, expected: [Bool]) throws {
        let text = program(params: "tensor<int32, [3]> a", """
                int32 zero = const()[name = string("zero"), val = int32(0)];
                tensor<bool, [3]> y = \(op)(x = a, y = zero)[name = string("y")];
        """)
        let result = try runProgram(text, inputs: ["a": ints([-1, 0, 4], [3])])
        #expect(result.dataType == .bool)
        #expect(result.int32s == expected.map { $0 ? 1 : 0 })
    }

    @Test func selectBroadcastsConditionAndOperands() throws {
        // The negative-index fix-up the embedders use: select(ids, ids + vocab, ids >= 0).
        let text = program(params: "tensor<int32, [2, 3]> ids", """
                int32 zero = const()[name = string("zero"), val = int32(0)];
                int32 vocab = const()[name = string("vocab"), val = int32(10)];
                tensor<bool, [2, 3]> ok = greater_equal(x = ids, y = zero)[name = string("ok")];
                tensor<int32, [2, 3]> wrapped = add(x = ids, y = vocab)[name = string("wrapped")];
                tensor<int32, [2, 3]> y = select(a = ids, b = wrapped, cond = ok)[name = string("y")];
        """)
        let result = try runProgram(text, inputs: ["ids": ints([1, -1, 3, -10, 0, 9], [2, 3])])
        #expect(result.int32s == [1, 9, 3, 0, 0, 9])

        let floatText = program(params: "tensor<bool, [2, 1]> c, tensor<fp32, [2, 3]> a", """
                fp32 b = const()[name = string("b"), val = fp32(-0x1p+0)];
                tensor<fp32, [2, 3]> y = select(a = a, b = b, cond = c)[name = string("y")];
        """)
        let floatResult = try runProgram(floatText, inputs: [
            "c": MILTensor(bool: [true, false], shape: [2, 1]),
            "a": floats([1, 2, 3, 4, 5, 6], [2, 3]),
        ])
        #expect(floatResult.floats == [1, 2, 3, -1, -1, -1])
    }
}

struct MILNormalisationTests {
    static func referenceLayerNorm(_ x: [Float], cols: Int, gamma: [Float], beta: [Float], epsilon: Double) -> [Float] {
        stride(from: 0, to: x.count, by: cols).flatMap { start -> [Float] in
            let row = x[start..<(start + cols)].map(Double.init)
            let mean = row.reduce(0, +) / Double(cols)
            let variance = row.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(cols)
            return row.enumerated().map { j, v in
                Float((v - mean) / (variance + epsilon).squareRoot() * Double(gamma[j]) + Double(beta[j]))
            }
        }
    }

    @Test func layerNormOverTheLastAxisWithGammaAndBeta() throws {
        var rng = SplitMix64(seed: 2)
        let x = rng.floats(2 * 3 * 8).map { $0 * 5 + 2 }
        let gamma = rng.floats(8)
        let beta = rng.floats(8)
        let text = program(params: "tensor<fp32, [2, 3, 8]> x", """
                tensor<int32, [1]> axes = const()[name = string("axes"), val = tensor<int32, [1]>([-1])];
                tensor<fp32, [8]> g = const()[name = string("g"), val = tensor<fp32, [8]>([\(gamma.map { "\($0)" }.joined(separator: ", "))])];
                tensor<fp32, [8]> b = const()[name = string("b"), val = tensor<fp32, [8]>([\(beta.map { "\($0)" }.joined(separator: ", "))])];
                fp32 eps = const()[name = string("eps"), val = fp32(0x1.197998p-40)];
                tensor<fp32, [?, ?, 8]> y = layer_norm(axes = axes, beta = b, epsilon = eps, gamma = g, x = x)[name = string("y")];
        """)
        let result = try runProgram(text, inputs: ["x": floats(x, [2, 3, 8])])
        expectClose(result.floats, Self.referenceLayerNorm(x, cols: 8, gamma: gamma, beta: beta, epsilon: 1e-12), tolerance: 2e-5)
    }

    @Test func layerNormOverTwoTrailingAxesWithoutAffine() throws {
        var rng = SplitMix64(seed: 3)
        let x = rng.floats(2 * 2 * 3)
        let text = program(params: "tensor<fp32, [2, 2, 3]> x", """
                tensor<int32, [2]> axes = const()[name = string("axes"), val = tensor<int32, [2]>([-1, 1])];
                tensor<fp32, [2, 2, 3]> y = layer_norm(axes = axes, x = x)[name = string("y")];
        """)
        let result = try runProgram(text, inputs: ["x": floats(x, [2, 2, 3])])
        expectClose(result.floats, Self.referenceLayerNorm(x, cols: 6, gamma: .init(repeating: 1, count: 6), beta: .init(repeating: 0, count: 6), epsilon: 1e-5), tolerance: 2e-5)
    }

    @Test func layerNormRejectsANonTrailingAxis() throws {
        let text = program(params: "tensor<fp32, [2, 3]> x", """
                tensor<int32, [1]> axes = const()[name = string("axes"), val = tensor<int32, [1]>([0])];
                tensor<fp32, [2, 3]> y = layer_norm(axes = axes, x = x)[name = string("y")];
        """)
        #expect(throws: MILRuntimeError.self) {
            try runProgram(text, inputs: ["x": floats([1, 2, 3, 4, 5, 6], [2, 3])])
        }
    }

    @Test(arguments: [1, -1, 0])
    func softmaxAlongAnAxis(axis: Int) throws {
        var rng = SplitMix64(seed: 4)
        let shape = [2, 3, 4]
        let x = rng.floats(24).map { $0 * 8 }
        let text = program(params: "tensor<fp32, [2, 3, 4]> x", """
                int32 axis = const()[name = string("axis"), val = int32(\(axis))];
                tensor<fp32, [2, 3, 4]> y = softmax(axis = axis, x = x)[name = string("y")];
        """)
        let result = try runProgram(text, inputs: ["x": floats(x, shape)])
        let a = axis < 0 ? axis + 3 : axis
        let strides = [12, 4, 1]
        var expected = [Float](repeating: 0, count: 24)
        for i in 0..<24 {
            let coordinate = a == 0 ? i / 12 : (a == 1 ? (i / 4) % 3 : i % 4)
            let base = i - coordinate * strides[a]
            let row = (0..<shape[a]).map { Double(x[base + $0 * strides[a]]) }
            let m = row.max()!
            let denominator = row.reduce(0) { $0 + exp($1 - m) }
            expected[i] = Float(exp(row[coordinate] - m) / denominator)
        }
        expectClose(result.floats, expected, tolerance: 1e-6)
    }

    @Test func reductionsKeepOrDropAxes() throws {
        let x: [Float] = [3, 4, 0, 1, 2, 2]
        let text = program(params: "tensor<fp32, [2, 3]> x", outputs: "s, k, n", """
                tensor<int32, [1]> ax1 = const()[name = string("ax1"), val = tensor<int32, [1]>([1])];
                bool no = const()[name = string("no"), val = bool(false)];
                bool yes = const()[name = string("yes"), val = bool(true)];
                tensor<fp32, [2]> s = reduce_sum(axes = ax1, keep_dims = no, x = x)[name = string("s")];
                tensor<fp32, [2, 1]> k = reduce_sum(axes = ax1, keep_dims = yes, x = x)[name = string("k")];
                tensor<fp32, [2, 1]> n = reduce_l2_norm(axes = ax1, keep_dims = yes, x = x)[name = string("n")];
        """)
        let out = try MILModel(programText: text).predict(["x": floats(x, [2, 3])])
        #expect(out["s"]?.floats == [7, 5])
        #expect(out["k"]?.shape == [2, 1])
        #expect(out["n"]?.floats == [5, 3])
    }

    @Test func geluTanhClipAndCast() throws {
        let text = program(params: "tensor<fp32, [4]> x", outputs: "g, ga, t, c, i, u", """
                string exact = const()[name = string("exact"), val = string("EXACT")];
                string approx = const()[name = string("approx"), val = string("TANH_APPROXIMATION")];
                tensor<fp32, [4]> g = gelu(mode = exact, x = x)[name = string("g")];
                tensor<fp32, [4]> ga = gelu(mode = approx, x = x)[name = string("ga")];
                tensor<fp32, [4]> t = tanh(x = x)[name = string("t")];
                fp32 lo = const()[name = string("lo"), val = fp32(-0x1p+0)];
                fp32 hi = const()[name = string("hi"), val = fp32(0x1p+1)];
                tensor<fp32, [4]> c = clip(alpha = lo, beta = hi, x = x)[name = string("c")];
                string i16 = const()[name = string("i16"), val = string("int16")];
                tensor<int16, [4]> i = cast(dtype = i16, x = x)[name = string("i")];
                string u16 = const()[name = string("u16"), val = string("uint16")];
                tensor<int32, [4]> neg = const()[name = string("neg"), val = tensor<int32, [4]>([-1, 0, 65536, 7])];
                tensor<uint16, [4]> u = cast(dtype = u16, x = neg)[name = string("u")];
        """)
        let out = try MILModel(programText: text).predict(["x": floats([-1, 0, 1, 2.5], [4])])
        expectClose(try #require(out["g"]).floats, [-0.15865525, 0, 0.84134475, 2.48447584], tolerance: 1e-6)
        expectClose(try #require(out["ga"]).floats, [-0.15880801, 0, 0.84119199, 2.48491573], tolerance: 1e-6)
        expectClose(try #require(out["t"]).floats, [-0.76159416, 0, 0.76159416, 0.98661430], tolerance: 1e-6)
        #expect(out["c"]?.floats == [-1, 0, 1, 2])
        #expect(out["i"]?.int32s == [-1, 0, 1, 2])
        #expect(out["i"]?.dataType == .int16)
        #expect(out["u"]?.int32s == [65535, 0, 0, 7])
    }
}

struct MILIndexingTests {
    @Test func gatherRowsWithTwoDimensionalIndices() throws {
        // Embedding lookup: table [5, 2], ids [2, 3] -> [2, 3, 2]; negative ids count from the end.
        let table: [Float] = [0, 0.5, 1, 1.5, 2, 2.5, 3, 3.5, 4, 4.5]
        let text = program(params: "tensor<int32, [2, 3]> ids", """
                tensor<fp32, [5, 2]> table = const()[name = string("table"), val = tensor<fp32, [5, 2]>([\(table.map { "\($0)" }.joined(separator: ", "))])];
                int32 axis = const()[name = string("axis"), val = int32(0)];
                int32 bd = const()[name = string("bd"), val = int32(0)];
                bool vi = const()[name = string("vi"), val = bool(false)];
                tensor<fp32, [2, 3, 2]> y = gather(axis = axis, batch_dims = bd, indices = ids, validate_indices = vi, x = table)[name = string("y")];
        """)
        let result = try runProgram(text, inputs: ["ids": ints([4, 0, 2, -1, 1, 1], [2, 3])])
        #expect(result.shape == [2, 3, 2])
        #expect(result.floats == [4, 4.5, 0, 0.5, 2, 2.5, 4, 4.5, 1, 1.5, 1, 1.5])
    }

    @Test func gatherAlongAnInnerAxisAndAScalarIndex() throws {
        let text = program(params: "tensor<fp32, [2, 3]> x", outputs: "y, batch", """
                int32 one = const()[name = string("one"), val = int32(1)];
                tensor<int32, [2]> picks = const()[name = string("picks"), val = tensor<int32, [2]>([2, 0])];
                tensor<fp32, [2, 2]> y = gather(axis = one, indices = picks, x = x)[name = string("y")];
                tensor<int32, [2]> dims = shape(x = x)[name = string("dims")];
                int32 zero = const()[name = string("zero"), val = int32(0)];
                int32 batch = gather(axis = zero, indices = zero, x = dims)[name = string("batch")];
        """)
        let out = try MILModel(programText: text).predict(["x": floats([1, 2, 3, 4, 5, 6], [2, 3])])
        #expect(out["y"]?.floats == [3, 1, 6, 4])
        #expect(out["batch"]?.shape == [])
        #expect(out["batch"]?.int32s == [2])
    }

    @Test func gatherRejectsAnOutOfRangeIndex() {
        let text = program(params: "tensor<int32, [1]> ids", """
                tensor<fp32, [2, 1]> table = const()[name = string("table"), val = tensor<fp32, [2, 1]>([1, 2])];
                int32 axis = const()[name = string("axis"), val = int32(0)];
                tensor<fp32, [1, 1]> y = gather(axis = axis, indices = ids, x = table)[name = string("y")];
        """)
        #expect(throws: MILRuntimeError.self) { try runProgram(text, inputs: ["ids": ints([2], [1])]) }
    }

    @Test func sliceTakesTheClsTokenWithMasksAndSqueeze() throws {
        // hidden [2, 3, 4] -> hidden[:, 0, :] as in the Arctic and reranker graphs.
        let x = (0..<24).map(Float.init)
        let text = program(params: "tensor<fp32, [2, 3, 4]> x", """
                tensor<int32, [3]> b = const()[name = string("b"), val = tensor<int32, [3]>([0, 0, 0])];
                tensor<int32, [3]> e = const()[name = string("e"), val = tensor<int32, [3]>([0, 1, 4])];
                tensor<bool, [3]> em = const()[name = string("em"), val = tensor<bool, [3]>([true, false, true])];
                tensor<bool, [3]> sq = const()[name = string("sq"), val = tensor<bool, [3]>([false, true, false])];
                tensor<fp32, [?, 4]> y = slice_by_index(begin = b, end = e, end_mask = em, squeeze_mask = sq, x = x)[name = string("y")];
        """)
        let result = try runProgram(text, inputs: ["x": floats(x, [2, 3, 4])])
        #expect(result.shape == [2, 4])
        #expect(result.floats == [0, 1, 2, 3, 12, 13, 14, 15])
    }

    @Test func slicePrefixWithADynamicEndAndBeginMask() throws {
        // position_ids[:, :seq] with end = concat(1, seq) and end_mask [true, false].
        let text = program(params: "tensor<int32, [1, 6]> pos, tensor<int32, [2]> end", """
                tensor<int32, [2]> b = const()[name = string("b"), val = tensor<int32, [2]>([0, 0])];
                tensor<bool, [2]> em = const()[name = string("em"), val = tensor<bool, [2]>([true, false])];
                tensor<int32, [1, ?]> y = slice_by_index(begin = b, end = end, end_mask = em, x = pos)[name = string("y")];
        """)
        let result = try runProgram(text, inputs: ["pos": ints([0, 1, 2, 3, 4, 5], [1, 6]), "end": ints([1, 4], [2])])
        #expect(result.shape == [1, 4])
        #expect(result.int32s == [0, 1, 2, 3])
    }

    @Test func sliceWithNegativeBoundsAndStrides() throws {
        let x = (0..<10).map(Float.init)
        let text = program(params: "tensor<fp32, [10]> x", outputs: "a, r", """
                tensor<int32, [1]> b1 = const()[name = string("b1"), val = tensor<int32, [1]>([-8])];
                tensor<int32, [1]> e1 = const()[name = string("e1"), val = tensor<int32, [1]>([-1])];
                tensor<int32, [1]> s2 = const()[name = string("s2"), val = tensor<int32, [1]>([3])];
                tensor<fp32, [3]> a = slice_by_index(begin = b1, end = e1, stride = s2, x = x)[name = string("a")];
                tensor<int32, [1]> z = const()[name = string("z"), val = tensor<int32, [1]>([0])];
                tensor<int32, [1]> m = const()[name = string("m"), val = tensor<int32, [1]>([-2])];
                tensor<bool, [1]> t = const()[name = string("t"), val = tensor<bool, [1]>([true])];
                tensor<fp32, [5]> r = slice_by_index(begin = z, begin_mask = t, end = z, end_mask = t, stride = m, x = x)[name = string("r")];
        """)
        let out = try MILModel(programText: text).predict(["x": floats(x, [10])])
        #expect(out["a"]?.floats == [2, 5, 8])
        #expect(out["r"]?.floats == [9, 7, 5, 3, 1])
    }
}

struct MILShapeOperationTests {
    @Test func transposeAcceptsNegativePermutationEntries() throws {
        // perm [0, 2, -1, -3] == [0, 2, 3, 1], the key transpose in the attention blocks.
        let shape = [2, 3, 2, 4]
        let x = (0..<48).map(Float.init)
        let text = program(params: "tensor<fp32, [2, 3, 2, 4]> x", """
                tensor<int32, [4]> p = const()[name = string("p"), val = tensor<int32, [4]>([0, 2, -1, -3])];
                tensor<fp32, [2, 2, 4, 3]> y = transpose(perm = p, x = x)[name = string("y")];
        """)
        let result = try runProgram(text, inputs: ["x": floats(x, shape)])
        var expected: [Float] = []
        for a in 0..<2 { for c in 0..<2 { for d in 0..<4 { for b in 0..<3 {
            expected.append(x[((a * 3 + b) * 2 + c) * 4 + d])
        } } } }
        #expect(result.floats == expected)
    }

    @Test func reshapeInfersMinusOneAndConcatPromotesScalars() throws {
        let text = program(params: "tensor<fp32, [2, 6]> x", outputs: "y, shp", """
                tensor<int32, [2]> dims = shape(x = x)[name = string("dims")];
                int32 zero = const()[name = string("zero"), val = int32(0)];
                int32 batch = gather(axis = zero, indices = zero, x = dims)[name = string("batch")];
                int32 minus = const()[name = string("minus"), val = int32(-1)];
                int32 three = const()[name = string("three"), val = int32(3)];
                bool no = const()[name = string("no"), val = bool(false)];
                tensor<int32, [3]> shp = concat(axis = zero, interleave = no, values = (batch, minus, three))[name = string("shp")];
                tensor<fp32, [?, ?, 3]> y = reshape(shape = shp, x = x)[name = string("y")];
        """)
        let out = try MILModel(programText: text).predict(["x": floats((0..<12).map(Float.init), [2, 6])])
        #expect(out["shp"]?.int32s == [2, -1, 3])
        #expect(out["y"]?.shape == [2, 2, 3])
        #expect(out["y"]?.floats == (0..<12).map(Float.init))
    }

    @Test func concatFloatsAlongAnInnerAxis() throws {
        let text = program(params: "tensor<fp32, [2, 1]> a, tensor<fp32, [2, 2]> b", """
                int32 one = const()[name = string("one"), val = int32(1)];
                bool no = const()[name = string("no"), val = bool(false)];
                tensor<fp32, [2, 3]> y = concat(axis = one, interleave = no, values = (a, b))[name = string("y")];
        """)
        let result = try runProgram(text, inputs: ["a": floats([1, 2], [2, 1]), "b": floats([3, 4, 5, 6], [2, 2])])
        #expect(result.floats == [1, 3, 4, 2, 5, 6])
    }

    @Test func expandDimsAndTile() throws {
        let text = program(params: "tensor<int32, [1, 3]> t, tensor<fp32, [2, 3]> m", outputs: "y, e", """
                tensor<int32, [2]> reps = const()[name = string("reps"), val = tensor<int32, [2]>([2, 1])];
                tensor<int32, [?, ?]> y = tile(reps = reps, x = t)[name = string("y")];
                tensor<int32, [1]> ax = const()[name = string("ax"), val = tensor<int32, [1]>([-1])];
                tensor<fp32, [2, 3, 1]> e = expand_dims(axes = ax, x = m)[name = string("e")];
        """)
        let out = try MILModel(programText: text).predict(["t": ints([7, 8, 9], [1, 3]), "m": floats([1, 2, 3, 4, 5, 6], [2, 3])])
        #expect(out["y"]?.shape == [2, 3])
        #expect(out["y"]?.int32s == [7, 8, 9, 7, 8, 9])
        #expect(out["e"]?.shape == [2, 3, 1])
    }
}

struct MILLinearAlgebraTests {
    @Test func linearMatchesARowTimesWeightTransposePlusBias() throws {
        var rng = SplitMix64(seed: 5)
        let x = rng.floats(2 * 3 * 5)
        let w = rng.floats(4 * 5)
        let b = rng.floats(4)
        let list: ([Float]) -> String = { $0.map { "\($0)" }.joined(separator: ", ") }
        let text = program(params: "tensor<fp32, [2, 3, 5]> x", outputs: "y, nb", """
                tensor<fp32, [4, 5]> w = const()[name = string("w"), val = tensor<fp32, [4, 5]>([\(list(w))])];
                tensor<fp32, [4]> b = const()[name = string("b"), val = tensor<fp32, [4]>([\(list(b))])];
                tensor<fp32, [2, 3, 4]> y = linear(bias = b, weight = w, x = x)[name = string("y")];
                tensor<fp32, [2, 3, 4]> nb = linear(weight = w, x = x)[name = string("nb")];
        """)
        let out = try MILModel(programText: text).predict(["x": floats(x, [2, 3, 5])])
        var expected: [Float] = []
        var noBias: [Float] = []
        for r in 0..<6 {
            for n in 0..<4 {
                let dot = (0..<5).reduce(0.0) { $0 + Double(x[r * 5 + $1]) * Double(w[n * 5 + $1]) }
                expected.append(Float(dot + Double(b[n])))
                noBias.append(Float(dot))
            }
        }
        expectClose(try #require(out["y"]).floats, expected)
        expectClose(try #require(out["nb"]).floats, noBias)
    }

    @Test(arguments: [(false, false), (true, false), (false, true), (true, true)])
    func matmulHonoursTransposeFlagsAndBroadcastsBatches(transposeX: Bool, transposeY: Bool) throws {
        var rng = SplitMix64(seed: 6)
        let (m, k, n) = (3, 4, 2)
        let xShape = transposeX ? [2, 1, k, m] : [2, 1, m, k]
        let yShape = transposeY ? [3, n, k] : [3, k, n]
        let x = rng.floats(xShape.reduce(1, *))
        let y = rng.floats(yShape.reduce(1, *))
        func shapeText(_ s: [Int]) -> String { s.map(String.init).joined(separator: ", ") }
        let text = program(params: "tensor<fp32, [\(shapeText(xShape))]> x, tensor<fp32, [\(shapeText(yShape))]> b", """
                bool tx = const()[name = string("tx"), val = bool(\(transposeX))];
                bool ty = const()[name = string("ty"), val = bool(\(transposeY))];
                tensor<fp32, [2, 3, 3, 2]> y = matmul(transpose_x = tx, transpose_y = ty, x = x, y = b)[name = string("y")];
        """)
        let result = try runProgram(text, inputs: ["x": floats(x, xShape), "b": floats(y, yShape)])
        var expected: [Float] = []
        for b0 in 0..<2 { for b1 in 0..<3 { for i in 0..<m { for j in 0..<n {
            var sum = 0.0
            for p in 0..<k {
                let xv = transposeX ? x[b0 * k * m + p * m + i] : x[b0 * m * k + i * k + p]
                let yv = transposeY ? y[b1 * n * k + j * k + p] : y[b1 * k * n + p * n + j]
                sum += Double(xv) * Double(yv)
            }
            expected.append(Float(sum))
        } } } }
        expectClose(result.floats, expected)
    }

    @Test func matmulOfAVectorAndAMatrixDropsTheVectorAxis() throws {
        let text = program(params: "tensor<fp32, [3]> v, tensor<fp32, [3, 2]> m", """
                tensor<fp32, [2]> y = matmul(x = v, y = m)[name = string("y")];
        """)
        let result = try runProgram(text, inputs: ["v": floats([1, 2, 3], [3]), "m": floats([1, 0, 0, 1, 1, 1], [3, 2])])
        #expect(result.shape == [2])
        #expect(result.floats == [4, 5])
    }
}

struct MILExecutionContractTests {
    @Test func rejectsUnsupportedOperationsAtLoad() {
        let text = program(params: "tensor<fp32, [2]> x", "        tensor<fp32, [2]> y = erf(x = x)[name = string(\"y\")];")
        #expect(throws: MILRuntimeError.unsupportedOperation(op: "erf", line: 4)) { try MILModel(programText: text) }
    }

    @Test func rejectsAResultThatContradictsTheDeclaredShape() {
        let text = program(params: "tensor<fp32, [2]> x", "        tensor<fp32, [3]> y = tanh(x = x)[name = string(\"y\")];")
        #expect(throws: MILRuntimeError.self) {
            try runProgram(text, inputs: ["x": floats([1, 2], [2])])
        }
    }

    @Test func validatesInputsAgainstTheSignature() throws {
        let model = try MILModel(programText: program(params: "tensor<int32, [?, 4]> x", "        tensor<int32, [?, 4]> y = add(x = x, y = x)[name = string(\"y\")];"))
        #expect(throws: MILRuntimeError.missingInput("x")) { try model.predict([:]) }
        #expect(throws: MILRuntimeError.self) { try model.predict(["x": ints([1, 2, 3], [1, 3])]) }
        #expect(throws: MILRuntimeError.self) { try model.predict(["x": floats([1, 2, 3, 4], [1, 4])]) }
        #expect(throws: MILRuntimeError.unexpectedInput("z")) { try model.predict(["x": ints([1, 2, 3, 4], [1, 4]), "z": ints([1], [1])]) }
        #expect(try model.predict(["x": ints([1, 2, 3, 4, 5, 6, 7, 8], [2, 4])])["y"]?.int32s == [2, 4, 6, 8, 10, 12, 14, 16])
    }

    @Test func foldsInputIndependentOperationsAndFreesNothingItStillNeeds() throws {
        // `twice` depends only on constants (folded at load); `y` reuses `x` after `t` consumed it.
        let text = program(params: "tensor<fp32, [2]> x", outputs: "y, twice", """
                fp32 two = const()[name = string("two"), val = fp32(0x1p+1)];
                fp32 twice = mul(x = two, y = two)[name = string("twice")];
                tensor<fp32, [2]> t = mul(x = x, y = twice)[name = string("t")];
                tensor<fp32, [2]> y = add(x = t, y = x)[name = string("y")];
        """)
        let out = try MILModel(programText: text).predict(["x": floats([1, -2], [2])])
        #expect(out["twice"]?.floats == [4])
        #expect(out["y"]?.floats == [5, -10])
    }
}
