// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WaxDemo",
    platforms: [
        .macOS(.v26),
    ],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "WaxDemo",
            dependencies: [
                .product(name: "Wax", package: "Wax"),
            ],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .executableTarget(
            name: "WaxDemoCorruptTOC",
            dependencies: [
                .product(name: "Wax", package: "Wax"),
            ],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
        .executableTarget(
            name: "WaxDemoMultiFooter",
            dependencies: [
                .product(name: "Wax", package: "Wax"),
            ],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
    ]
)
