#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/wax-public-snippets.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/Sources/WaxPublicSnippetCheck"

cat >"$TMP_DIR/Package.swift" <<SWIFT
// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "WaxPublicSnippetCheck",
    platforms: [
        .macOS(.v15),
    ],
    dependencies: [
        .package(path: "$ROOT_DIR"),
    ],
    targets: [
        .executableTarget(
            name: "WaxPublicSnippetCheck",
            dependencies: [
                .product(name: "Wax", package: "Wax"),
            ]
        ),
    ]
)
SWIFT

if [[ -f "$ROOT_DIR/Package.resolved" ]]; then
  cp "$ROOT_DIR/Package.resolved" "$TMP_DIR/Package.resolved"
fi

cat >"$TMP_DIR/Sources/WaxPublicSnippetCheck/main.swift" <<'SWIFT'
import Foundation
import Wax

@main
struct WaxPublicSnippetCheck {
    static func main() async throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-public-snippet-\(UUID().uuidString)")
            .appendingPathExtension("wax")
        defer { try? FileManager.default.removeItem(at: storeURL) }

        var config = Memory.Config()
        config.enableVectorSearch = false
        let memory = try await Memory(at: storeURL, config: config)

        try await memory.save(
            "The user is building a Swift package.",
            metadata: ["source": "public-snippet"]
        )

        var options = Memory.SearchOptions()
        options.mode = .textOnly
        options.topK = 3
        let context = try await memory.search("What is the user building?", options: options)

        _ = context.items.map(\.text)
        try await memory.close()
    }
}
SWIFT

swift build --package-path "$TMP_DIR" --disable-automatic-resolution
