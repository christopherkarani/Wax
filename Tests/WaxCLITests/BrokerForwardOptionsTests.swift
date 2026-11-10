import Foundation
import Testing
import Wax
@testable import wax_cli

@Suite("BrokerForwardOptions")
struct BrokerForwardOptionsTests {
    @Test func jsonArgsKeepNumbersAndBooleansApart() throws {
        let options = try BrokerForwardOptions.parse([
            "--json-args", #"{"a":1,"b":0,"d":true,"e":1.5,"f":false,"g":[1,true]}"#,
        ])
        let values = try options.values()
        #expect(values["a"] == .int(1))
        #expect(values["b"] == .int(0))
        #expect(values["d"] == .bool(true))
        #expect(values["e"] == .double(1.5))
        #expect(values["f"] == .bool(false))
        #expect(values["g"] == .array([.int(1), .bool(true)]))
    }

    /// A whole-valued double outside Int64 used to trap in `Int64(_:)`.
    @Test func jsonArgsKeepOutOfRangeWholeNumbersAsDoubles() throws {
        let options = try BrokerForwardOptions.parse([
            "--json-args", #"{"a":1,"b":0,"c":1e20,"d":true,"e":1.5}"#,
        ])
        let values = try options.values()
        #expect(values["a"] == .int(1))
        #expect(values["b"] == .int(0))
        #expect(values["c"] == .double(1e20))
        #expect(values["d"] == .bool(true))
        #expect(values["e"] == .double(1.5))
    }

    @Test func jsonArgsMustBeAnObject() throws {
        let options = try BrokerForwardOptions.parse(["--json-args", "[1]"])
        #expect(throws: CLIError.self) {
            _ = try options.values()
        }
    }
}
