---
sidebar_position: 1
title: "Wax for iOS developers"
sidebar_label: "Overview"
---

Wax is an on-device memory library for Swift apps. You store text (and embeddings) in a single `.wax` file on the device, then search it later — no server, no API key.

This site is aimed at people adding Wax to **iOS and iPadOS** apps, especially apps that also use Apple's **Foundation Models** for on-device generation.

## What you get

- **`Memory`** — public API: open a store, `save`, `search`, `flush`, `close`
- **Built-in MiniLM embeddings** on iOS 18+ (default package trait) so hybrid text + vector search works without wiring your own model
- **Foundation Models adapters** on iOS 26+ — prompt injection, memory tools, and turn persistence around `LanguageModelSession`

## Start here

1. [Get started on iOS](./ios/getting-started) — add the package in Xcode, open a store, save and search
2. [Foundation Models](./ios/foundation-models) — give an on-device model durable memory
3. [Memory API](./ios/memory-api) — config, retrieval modes, embeddings, diagnostics

API reference also ships as DocC inside the package (`Sources/Wax/Wax.docc`).

## Requirements

| Feature | Minimum |
| --- | --- |
| Wax library | iOS 17 / iPadOS 17 |
| Built-in MiniLM embeddings | iOS 18 / iPadOS 18 |
| Foundation Models tools & session | iOS 26 / iPadOS 26 |

## Public vs internal APIs

Use **`import Wax`** and **`Memory`**. Types like `MemoryOrchestrator` are package-internal; app targets cannot call them. Older pages under Orchestrator / WaxCore describe internals for contributors — not the app-facing surface.
