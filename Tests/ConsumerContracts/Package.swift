// swift-tools-version: 6.2
import PackageDescription

// Path-package identity is the directory name; `name:` pins it to "Wax" so this
// nested consumer works in a checkout named Wax and in worktrees that are not.
let waxDependency: Package.Dependency = .package(name: "Wax", path: "../..")

let package = Package(
    name: "WaxConsumerContracts",
    platforms: [.iOS(.v17), .macOS(.v14)],
    dependencies: [waxDependency],
    targets: [
        .executableTarget(
            name: "StrictConsumer",
            dependencies: [.product(name: "Wax", package: "Wax")],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "ConsumerContractTests",
            dependencies: [.product(name: "Wax", package: "Wax")],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
    ]
)
