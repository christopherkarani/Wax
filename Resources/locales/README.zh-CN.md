<!-- HEADER:START -->
<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="../docs/assets/banner-dark.svg">
    <img src="../docs/assets/banner-light.svg" width="800" alt="Wax Banner">
  </picture>
</div>

<div style="height: 16px;"></div>

<p align="center">
  <strong>Wax 是为 Apple 平台 AI Agent 打造的高性能单文件记忆层。</strong><br/>
  设备端、私有且便携。不需要服务器，也不依赖云端。
</p>

<p align="center">
  <a href="https://github.com/christopherkarani/Wax/releases"><img src="https://img.shields.io/github/v/release/christopherkarani/Wax?style=flat-square&logo=swift&logoColor=white&label=Swift" alt="Swift" /></a>
  <a href="https://developer.apple.com/ios/"><img src="https://img.shields.io/badge/platform-iOS%20%7C%20macOS-lightgrey?style=flat-square" alt="Platforms" /></a>
  <a href="https://github.com/christopherkarani/Wax/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-Apache%202.0-blue?style=flat-square" alt="License" /></a>
  <a href="https://github.com/christopherkarani/Wax/stargazers"><img src="https://img.shields.io/github/stars/christopherkarani/Wax?style=flat-square&logo=github" alt="Stars" /></a>
</p>

<p align="center">
  [English](../README.md) | [Español](README.es.md) | [Français](README.fr.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Português](README.pt.md) | [中文](README.zh-CN.md)
</p>
<!-- HEADER:END -->

---

## Wax 是什么？

Wax 是一款专为下一代 AI Agent 设计的 Swift 原生持久化引擎。它将文档、高维嵌入（embeddings）和结构化知识封装到单个便携的 `.wax` 文件中。

与需要复杂设置或依赖云端的传统数据库不同，Wax 提供了一个完全运行在设备端的**统一记忆层**，利用 Metal 加速推理，实现低于 10ms 的检索延迟。

### 为什么选择 Wax？

| 特性             | Wax                    | SQLite (FTS5)          | 云端向量数据库         |
|:-----------------|:-----------------------|:-----------------------|:-----------------------|
| **搜索**         | 混合（文本 + 向量）      | 仅文本*                | 仅向量*                |
| **延迟**         | **~6ms (p95)**         | ~10ms (p95)            | 150ms - 500ms+         |
| **隐私**         | 100% 本地              | 100% 本地              | 云端托管               |
| **设置**         | 零配置                 | 低                     | 复杂（需要 API 密钥）  |
| **架构**         | Apple 芯片原生支持      | 通用                   | 各异                   |

### 📦 为什么采用单个 `.wax` 文件？
大多数 RAG 系统需要数据库、向量存储和文件服务器。Wax 将所有内容（文档、元数据和高维索引）捆绑到一个便携的二进制文件中。
*   **零基础设施：** 无需 Docker，无需数据库设置，无云端账单。
*   **真正便携：** 通过 AirDrop 将 Agent 的记忆发送到另一台 Mac，或通过 iCloud 进行同步。
*   **原子化：** 一个文件用于备份，一个文件用于版本控制，一个文件即可删除。

---

## 性能

Wax 针对 M 系列芯片架构进行了优化，即使在大规模本地索引下也能提供近乎瞬时的检索。

### 检索延迟 (p95)
*越低越好。以毫秒为单位。*

```text
Wax (混合)    |██ 6.1ms
SQLite (文本) |████ 12ms
云端 RAG      |██████████████████████████████████████████████████ 150ms+
```

### 冷启动时间 (p95)
*越低越好。以毫秒为单位。*

```text
Wax           |███ 9.2ms
传统方式      |██████████████████████████████████████ 120ms+
```

> [!TIP]
> **注入吞吐量：** 在 M3 Max 上，Wax 在开启完整混合索引的情况下，处理速度达到 **85.9 docs/s**。
> 完整基准测试报告：[docs/benchmarks/2026-03-06-performance-results.md](../docs/benchmarks/2026-03-06-performance-results.md)

---

## 架构

Wax 采用**“数据库中的数据库”**模型。它管理自己的基于帧（frame-based）的存储格式，同时将专用搜索引擎（SQLite FTS5 和 Metal 加速的 HNSW）作为序列化 blob 嵌入到主文件中。

### 内部文件布局

```text
┌──────────────────────────────────────────────────────────────────────────┐
│                          双 Header 页面 (A/B)                            │
│   (Magic, 版本, 世代, 指向 WAL 和 TOC 的指针, 校验和)                    │
├──────────────────────────────────────────────────────────────────────────┤
│                          WAL (预写日志)                                  │
│   (用于防崩溃的未提交变更的原子环形缓冲区)                               │
├──────────────────────────────────────────────────────────────────────────┤
│                          压缩数据帧                                      │
│   ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐       │
│   │ 帧 0 (LZ4)       │  │ 帧 1 (LZ4)       │  │ 帧 2 (LZ4)       │ ...   │
│   │ [原始文档]       │  │ [元数据/JSON]    │  │ [系统信息]       │       │
│   └──────────────────┘  └──────────────────┘  └──────────────────┘       │
├──────────────────────────────────────────────────────────────────────────┤
│                          混合搜索索引                                    │
│   ┌──────────────────────────────┐  ┌──────────────────────────────┐     │
│   │ SQLite FTS5 Blob             │  │ Metal HNSW 索引              │     │
│   │ (文本搜索 + EAV 事实)        │  │ (向量搜索)                   │     │
│   └──────────────────────────────┘  └──────────────────────────────┘     │
├──────────────────────────────────────────────────────────────────────────┤
│                          TOC (目录)                                      │
│   (所有帧的索引、父子关系及引擎配置清单)                                 │
└──────────────────────────────────────────────────────────────────────────┘
```

1. **原子韧性**：双 Header 和 WAL 确保即使进程在写入中途崩溃，存储仍保持一致。
2. **统一检索**：单个查询即可触发 BM25（文本）和 HNSW（向量）引擎的并行执行。
3. **结构化知识**：内置 EAV（实体-属性-值）存储，用于持久化事实和长期推理。

---

## 快速开始

```swift
import Wax

// 使用可写入的位置（适用于应用和 CLI 工具）
let url = URL.documentsDirectory.appending(path: "agent.wax")

// 1. 打开记忆存储
let memory = try await Memory(at: url)

// 2. 保存记忆
try await memory.save("用户正在使用 SwiftUI 开发一个习惯追踪器。")

// 3. 使用混合检索（文本 + 向量）进行搜索
let results = try await memory.search("用户正在开发什么？")

if let best = results.items.first {
    print("找到：\(best.text)")
    // → "找到：用户正在使用 SwiftUI 开发一个习惯追踪器。"
}

try await memory.close()
```

<details>
<summary><strong>SwiftUI 示例</strong></summary>

```swift
import SwiftUI
import Wax

struct ContentView: View {
    @State private var result = "搜索中…"

    var body: some View {
        Text(result)
            .task {
                do {
                    let url = URL.documentsDirectory.appending(path: "agent.wax")
                    let memory = try await Memory(at: url)

                    try await memory.save("用户正在使用 SwiftUI 开发一个习惯追踪器。")
                    let context = try await memory.search("用户正在开发什么？")

                    result = context.items.first?.text ?? "未找到"
                    try await memory.close()
                } catch {
                    result = "错误：\(error.localizedDescription)"
                }
            }
    }
}
```

</details>

<details>
<summary><strong>CLI 工具 (main.swift)</strong></summary>

```swift
import Wax

@main
struct AgentMemory {
    static func main() async throws {
        let url = URL.documentsDirectory.appending(path: "agent.wax")
        let memory = try await Memory(at: url)

        try await memory.save("用户正在使用 SwiftUI 开发一个习惯追踪器。")

        let results = try await memory.search("用户正在开发什么？")
        if let best = results.items.first {
            print("找到：\(best.text)")
        }

        try await memory.close()
    }
}
```

</details>

想要存储持久化事实和长期推理？请参阅 [结构化记忆](../Sources/WaxCore/WaxCore.docc/Articles/StructuredMemory.md)。

---

## 安装

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/christopherkarani/Wax.git", from: "0.1.8")
]
```

---

## 生态系统工具

### 🤖 MCP 服务
Wax 提供一流的 **Model Context Protocol (MCP)** 服务。将您的本地记忆连接到 Claude Code 或任何兼容 MCP 的 Agent。

```bash
npx -y waxmcp@latest mcp install --scope user
```

### 🔍 WaxRepo
针对 git 历史记录的语义搜索 TUI。索引任何代码库，并使用自然语言查找代码或提交记录。

```bash
# 在任何 git 代码库中运行
wax-repo index
wax-repo search "我们在哪里实现了 WAL？"
```

---

## 许可证

Wax 采用 Apache License 2.0 发布。详见 [LICENSE](../LICENSE)。

<div align="center">
<sub>为坚信“用户数据应属于用户设备”的开发者而打造。</sub>
</div>
