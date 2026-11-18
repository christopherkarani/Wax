import Testing

/// Canary for the Testing library itself. The external swiftlang/swift-testing package
/// silently passed false Bool comparisons such as `#expect(flag == false)` on the
/// Swift 6.4 toolchain, which made hundreds of assertions in this repo vacuous.
/// Each block below must record its issue; if the macro stops recording it,
/// `withKnownIssue` reports "known issue was not recorded" and this test fails.
@Test func swiftTestingRecordsFalseBoolComparisons() {
    let flag = !CommandLine.arguments.isEmpty  // true, computed at runtime
    let optionalFlag: Bool? = flag

    withKnownIssue("a false `== false` comparison must be recorded") {
        #expect(flag == false)
    }
    withKnownIssue("a false `!= true` comparison must be recorded") {
        #expect(flag != true)
    }
    withKnownIssue("a false optional `== false` comparison must be recorded") {
        #expect(optionalFlag == false)
    }
}
