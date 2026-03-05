<!-- HEADER:START -->
<div align="center">
<img src="Resources/website/static/img/banner.svg" width="800" alt="Wax Banner" />
</div>
<!-- HEADER:END -->

<div style="height: 16px;"></div>

<p align="center">
  <strong>Wax 是 Apple 平台 AI Agent 的单文件记忆层。</strong><br/>
  设备端、本地私有、可移植：无需服务器、无需云端，全部存于一个 <code>.wax</code> 文件。
</p>

<p align="center">
  <strong>语言:</strong>
  <a href="README.md">English</a> ·
  <a href="README.zh-CN.md">简体中文</a> ·
  <a href="README.ko.md">한국어</a> ·
  <a href="README.ja.md">日本語</a> ·
  <a href="README.es.md">Español</a> ·
  <a href="README.pt.md">Português</a>
</p>

<!-- NAV:START -->
<p align="center">
  <a href="https://wax.sh">网站</a>
  ·
  <a href="https://wax.sh/docs">文档</a>
  ·
  <a href="https://github.com/christopherkarani/Wax/discussions">讨论区</a>
</p>
<!-- NAV:END -->

<!-- BADGES:START -->
<p align="center">
  <a href="https://github.com/christopherkarani/Wax/releases"><img src="https://img.shields.io/github/v/release/christopherkarani/Wax?style=flat-square&logo=swift&logoColor=white&label=SPM" alt="Swift Package" /></a>
  <a href="https://www.npmjs.com/package/waxmcp"><img src="https://img.shields.io/npm/v/waxmcp?style=flat-square&logo=npm" alt="npm" /></a>
  <a href="https://github.com/christopherkarani/Wax/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-Apache%202.0-blue?style=flat-square" alt="License" /></a>
</p>

<p align="center">
  <a href="https://github.com/christopherkarani/Wax/stargazers"><img src="https://img.shields.io/github/stars/christopherkarani/Wax?style=flat-square&logo=github" alt="Stars" /></a>
  <a href="https://github.com/christopherkarani/Wax/network/members"><img src="https://img.shields.io/github/forks/christopherkarani/Wax?style=flat-square&logo=github" alt="Forks" /></a>
  <a href="https://github.com/christopherkarani/Wax/issues"><img src="https://img.shields.io/github/issues/christopherkarani/Wax?style=flat-square&logo=github" alt="Issues" /></a>
</p>
<!-- BADGES:END -->

---

## Wax 是什么？

大多数 iOS AI 应用在用户关闭后就会失去记忆。Wax 解决了这个问题。

Wax 是一个可移植的 AI 记忆系统，把文档、向量嵌入、检索索引和元数据打包到单个 `.wax` 文件中。你不再需要同时维护 Core Data、FAISS、Pinecone，或部署向量数据库服务。Wax 让 Agent 获得持久、可搜索、私有、完全在设备端的记忆。

最终效果是：一个原生 Swift、零基础设施的记忆层，让 AI Agent 具备可随身携带的长期记忆，无需网络请求、无需 API Key、无需隐私妥协。


## 什么是 Smart Frame？

Wax 将 AI 记忆组织为**仅追加（append-only）的 Smart Frame 序列**，灵感来自视频编码。

Smart Frame 是不可变单元，存储内容以及时间戳、校验和、向量嵌入和元数据。Frame 支持分层 surrogate：可存储全文、摘要或微摘要，在查询时按速度与召回率做权衡。

这种基于 Frame 的设计带来：

- 仅追加写入，不修改也不破坏既有数据
- 以时间线方式查看知识如何演化
- 通过已提交的不可变 Frame 与 WAL 保证崩溃安全
- 通过 LZ4/zlib 获得高效压缩
- 双 Header 冗余，提升损坏恢复能力


## 核心概念

- **混合检索**：BM25 关键词检索 + HNSW 向量相似度融合。即使表达方式不同，也能找回正确记忆。

- **设备端嵌入**：由 MiniLM 驱动，通过 CoreML + Metal 本地运行。无 API 调用、无额外延迟、无额外成本。

- **Token 预算**：设置硬上限。Wax 每次都会自动裁剪并压缩上下文以适配预算。

- **知识图谱**：实体关系三元组 + 事实版本控制。可在非结构化记忆之外进行断言、撤回与结构化查询。

- **会话交接**：内建 `handoff` / `handoff-latest`，跨会话连续性开箱即用。

- **单文件可移植**：整个记忆存储就是一个 `.wax` 文件，可备份、可同步、可迁移。


## 使用场景

- **对话 Agent**：跨会话记住偏好、历史和事实
- **笔记应用**：语义搜索（例如“找出我写过 WWDC 的所有内容”）
- **个人助理**：学习用户习惯但不把数据发到设备外
- **RAG 流程**：完全设备端构建，适合敏感或离线优先场景
- **Claude Code / MCP Agent**：通过 MCP 服务获得持久化长期记忆
- **Video RAG**：索引转录与字幕，实现自然语言视频检索


## SDK 与 CLI

| 包 | 安装方式 | 说明 |
|---|---|---|
| **Swift SDK** | Swift Package Manager | iOS 与 macOS 应用核心库 |
| **MCP Server** | `npx -y waxmcp@latest mcp install` | Claude Code / MCP 集成 |
| **CLI** | `npx -y waxmcp@latest` | 终端命令：remember、recall、search |

---

## 安装

### Swift Package Manager

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/christopherkarani/Wax.git", from: "0.1.8")
],
targets: [
    .target(
        name: "MyApp",
        dependencies: [
            .product(name: "Wax", package: "Wax"),
            .product(name: "WaxVectorSearchMiniLM", package: "Wax")
        ]
    )
]
```

或在 Xcode 中：**File > Add Package Dependencies**，粘贴仓库 URL。

### MCP Server (Claude Code)

```bash
npx -y waxmcp@latest mcp install --scope user
```

### 模块

| 模块 | 用途 |
|---|---|
| `Wax` | 完整编排器：混合检索、RAG、知识图谱 |
| `WaxCore` | 底层 Frame 存储、WAL、提交引擎 |
| `WaxTextSearch` | BM25 全文检索（GRDB + FTS5） |
| `WaxVectorSearch` | HNSW 向量相似检索（USearch） |
| `WaxVectorSearchMiniLM` | 设备端 MiniLM 嵌入提供器 |

---

## 快速开始

```swift
import Wax
import WaxVectorSearchMiniLM

// 1. 打开（或创建）一个记忆存储
let memory = try await MemoryOrchestrator.openMiniLM(
    at: .documentsDirectory.appending(path: "agent.wax")
)

// 2. 写入记忆
try await memory.remember("User prefers concise answers and hates bullet points.")
try await memory.remember("The user's name is Alex and they live in Toronto.")
try await memory.remember("Alex is building a habit tracker in SwiftUI.")

// 3. 语义检索相关上下文
let context = try await memory.recall(query: "how should I address the user?")
print(context.items.map(\.text))
// ["The user's name is Alex and they live in Toronto.",
//  "User prefers concise answers and hates bullet points."]
```

### 知识图谱

```swift
// 创建实体
try await memory.upsertEntity(key: "person:alex", kind: "person", aliases: ["Alex", "the user"])

// 断言事实
try await memory.assertFact(subject: "person:alex", predicate: "lives_in", object: "Toronto")
try await memory.assertFact(subject: "person:alex", predicate: "building", object: "habit tracker")

// 查询事实
let facts = try await memory.facts(subject: "person:alex")
```

### 会话交接

```swift
// 会话结束：保存下次可继续的上下文
try await memory.rememberHandoff(
    summary: "Helped Alex debug a SwiftUI layout issue",
    project: "habit-tracker",
    pendingTasks: ["Fix the tab bar animation", "Add onboarding flow"]
)

// 下次会话开始：继续上次进度
if let handoff = try await memory.latestHandoff(project: "habit-tracker") {
    print(handoff.summary)
    print(handoff.pendingTasks)
}
```

---

## Claude Code 集成

安装 MCP 服务后，将下面内容加入你的 `CLAUDE.md`，让 Claude Code 使用 Wax 作为记忆层：

<details>
<summary><strong>CLAUDE.md 示例</strong>（点击展开）</summary>

```markdown
## 规则

1. **会话开始**：调用 `wax_handoff_latest` 恢复此前上下文
2. **回答前**：调用 `wax_recall` 检查已知信息
3. **学习到长期有效信息时**：调用 `wax_remember`
4. **被纠正时**：调用 `wax_forget` 更新错误信息
5. **会话结束**：调用 `wax_handoff` 并附上摘要与待办

## 工具

| Tool | 何时使用 |
|------|------|
| `wax_remember` | 用户表达偏好、做出决策，或你学到稳定模式 |
| `wax_recall` | 回答前需要历史上下文时 |
| `wax_forget` | 用户纠正你，或事实已过期 |
| `wax_context` | 需要某实体的完整上下文 |
| `wax_reflect` | 审计记忆状态：实体数量、谓词分布、健康度 |
| `wax_handoff` | 会话结束。可传 `pending_tasks` 保持连续性 |
| `wax_handoff_latest` | 会话开始。加载最近一次交接 |
```

</details>

---

## 架构

<div align="center">
<img src="https://raw.githubusercontent.com/christopherkarani/Wax/main/Resources/website/static/img/architecture.svg" width="800" alt="Wax Architecture" />
</div>

---

## 性能

<div align="center">
<img src="Resources/website/static/img/benchmarks.svg" width="800" alt="Wax Performance Benchmarks" />
</div>

---

## 文件格式

所有内容都在一个 `.wax` 文件里：

```
┌────────────────────────────┐
│ Header Pages (dual)        │  Magic, version, TOC pointer
├────────────────────────────┤
│ WAL Ring Buffer             │  Crash recovery
├────────────────────────────┤
│ Data Segments              │  LZ4/zlib compressed frames
├────────────────────────────┤
│ Text Index                 │  FTS5 full-text (BM25)
├────────────────────────────┤
│ Vector Index               │  HNSW embeddings (USearch)
├────────────────────────────┤
│ Knowledge Graph            │  Entity-fact triples
├────────────────────────────┤
│ TOC (Footer)               │  Segment offsets + checksums
└────────────────────────────┘
```

不会产生 `.wal`、`.lock`、`.shm` 或任何 sidecar 文件。

---

## 对比

| | Wax | ChromaDB | Pinecone | Core Data + FAISS |
|---|---|---|---|---|
| 设备端运行 | Yes | No | No | Yes |
| 无需服务器 | Yes | No | No | Yes |
| 混合检索 | Yes | Yes | Yes | Manual |
| Token 预算 | Yes | No | No | No |
| 知识图谱 | Yes | No | No | No |
| 单文件存储 | Yes | No | No | No |
| Swift 原生 API | Yes | No | No | Partial |
| MCP 服务 | Yes | No | No | No |
| 隐私（数据留在设备） | Yes | No | No | Yes |

---

## 运行要求

| | 最低要求 |
|---|---|
| Swift | 6.1+ |
| iOS | 18.0 |
| macOS | 15.0 |
| Xcode | 16.0 |

建议使用 Apple Silicon 以获得 Metal 加速嵌入。Intel Mac 会自动回退到 CPU。

---

## 路线图

- [ ] CloudKit 同步（可选开启、加密）
- [ ] iCloud Drive `.wax` 文档支持
- [ ] 记忆聚类与去重
- [ ] 更小体积的量化嵌入模型
- [ ] 用于记忆分析的 Instruments 模板

---

## 贡献

欢迎提交 Issue 和 PR。如果你正在用 Wax 构建产品，欢迎[发起 Discussion](https://github.com/christopherkarani/Wax/discussions)分享你的项目。

---

## Star 历史

[![Star History Chart](https://api.star-history.com/svg?repos=christopherkarani/wax&type=date&legend=top-left)](https://www.star-history.com/#christopherkarani/wax&type=date&legend=top-left)

---

## 许可证

Apache License 2.0，详情见 [LICENSE](LICENSE)。

---

<div align="center">
<sub>为相信“用户数据应属于用户设备”的开发者而构建。</sub>
</div>
