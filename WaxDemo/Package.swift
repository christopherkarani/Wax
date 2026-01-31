// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WaxDemo",
    platforms: [
        .macOS(.v26),
    ],
    dependencies: [
        .package(path: "../Wax"),
    ],
    targets: [
        .executableTarget(
            name: "WaxDemo",
            dependencies: [
                .product(name: "WaxCore", package: "Wax"),
            ],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .executableTarget(
            name: "WaxDemoCorruptTOC",
            dependencies: [
                .product(name: "WaxCore", package: "Wax"),
            ],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .executableTarget(
            name: "WaxDemoMultiFooter",
            dependencies: [
                .product(name: "WaxCore", package: "Wax"),
            ],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
    ]
)
