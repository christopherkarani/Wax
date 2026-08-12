// swift-tools-version: 6.2
import Foundation
import PackageDescription

// Path-package identity is the directory name; `name:` pins it to "Wax" so this
// nested consumer works in a checkout named Wax and in worktrees that are not.
let waxDependency: Package.Dependency = .package(name: "Wax", path: "../..")

// StrictConsumer is the Task 1 RED compile probe (non-Sendable configure closures).
// `swift test` typechecks every target in the package, so omit the executable when
// running ConsumerContractTests: WAX_OMIT_STRICT_CONSUMER=1
let omitStrictConsumer = ProcessInfo.processInfo.environment["WAX_OMIT_STRICT_CONSUMER"] == "1"

let strictTargets: [Target] = omitStrictConsumer ? [] : [
    .executableTarget(
        name: "StrictConsumer",
        dependencies: [.product(name: "Wax", package: "Wax")],
        swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
    )
]

let package = Package(
    name: "WaxConsumerContracts",
    platforms: [.iOS(.v17), .macOS(.v14)],
    dependencies: [waxDependency],
    targets: strictTargets + [
        .testTarget(
            name: "ConsumerContractTests",
            dependencies: [.product(name: "Wax", package: "Wax")],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
    ]
)
