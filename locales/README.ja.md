<!-- HEADER:START -->
<div align="center">
<img src="Resources/website/static/img/banner.svg" width="800" alt="Wax Banner" />
</div>
<!-- HEADER:END -->

<div style="height: 16px;"></div>

<p align="center">
  <strong>Wax は Apple プラットフォーム向け AI エージェントの単一ファイルメモリレイヤーです。</strong><br/>
  オンデバイス、プライベート、ポータブル。サーバー不要、クラウド不要、1つの <code>.wax</code> ファイルだけで動作します。
</p>

<p align="center">
  <strong>Languages:</strong>
  <a href="README.md">English</a> ·
  <a href="README.zh-CN.md">简体中文</a> ·
  <a href="README.ko.md">한국어</a> ·
  <a href="README.ja.md">日本語</a> ·
  <a href="README.es.md">Español</a> ·
  <a href="README.pt.md">Português</a>
</p>

<!-- NAV:START -->
<p align="center">
  <a href="https://wax.sh">Web サイト</a>
  ·
  <a href="https://wax.sh/docs">ドキュメント</a>
  ·
  <a href="https://github.com/christopherkarani/Wax/discussions">ディスカッション</a>
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

## Wax とは？

多くの iOS AI アプリは、ユーザーが閉じた瞬間に記憶を失います。Wax はこの問題を解決します。

Wax は、ドキュメント、埋め込み、検索インデックス、メタデータを 1 つの `.wax` ファイルにまとめるポータブルな AI メモリシステムです。Core Data、FAISS、Pinecone を個別に組み合わせたり、ベクターデータベースサーバーを運用したりする必要はありません。Wax により、エージェントはオンデバイスで永続的かつ検索可能なプライベートメモリを持てます。

その結果、Wax は Swift ネイティブでインフラ不要のメモリレイヤーとして、AI エージェントに長期記憶を提供します。ネットワーク呼び出しなし、API キーなし、プライバシーの妥協なしです。


## Smart Frame とは？

Wax は AI メモリを、動画エンコーディングに着想を得た **追記専用（append-only）の Smart Frame シーケンス**として管理します。

Smart Frame は、コンテンツに加えてタイムスタンプ、チェックサム、埋め込み、メタデータを格納する不変ユニットです。フレームは階層的 surrogate をサポートし、全文・要約・マイクロ要約を保持して、クエリ時に速度と再現率をトレードオフできます。

このフレーム設計により、次が実現できます。

- 既存データを変更・破損しない追記専用書き込み
- 知識の変化を時系列で追えるタイムライン型の可視化
- コミット済み不変フレームと WAL によるクラッシュセーフティ
- LZ4/zlib による効率的圧縮
- 破損耐性を高めるデュアルヘッダー冗長化


## コアコンセプト

- **ハイブリッド検索**: BM25 キーワード検索と HNSW ベクトル類似度を融合。表現が違っても正しい記憶を引き当てます。

- **オンデバイス埋め込み**: MiniLM を CoreML + Metal でローカル実行。API 呼び出し、遅延、追加コストは不要です。

- **トークン予算**: 上限を設定すれば、Wax が毎回コンテキストを自動で圧縮・調整して収めます。

- **ナレッジグラフ**: エンティティ関係トリプルとファクトのバージョニングを提供。非構造化メモリと並行して assert/retract/query が可能です。

- **セッションハンドオフ**: `handoff` / `handoff-latest` を標準提供し、会話継続を簡単にします。

- **単一ポータブルファイル**: メモリストア全体が 1 つの `.wax` ファイル。バックアップ、同期、移動が容易です。


## ユースケース

- **対話エージェント**: セッションをまたいで設定・履歴・事実を記憶
- **ノートアプリ**: セマンティック検索（「WWDC について書いた内容を全部探す」）
- **パーソナルアシスタント**: データを端末外に送らずに利用者の習慣を学習
- **RAG パイプライン**: センシティブ用途やオフライン優先向けに完全オンデバイスで構築
- **Claude Code / MCP エージェント**: MCP サーバー経由で長期記憶を永続化
- **Video RAG**: 文字起こしや字幕を索引化し、自然言語で動画検索


## SDK と CLI

| パッケージ | インストール | 説明 |
|---|---|---|
| **Swift SDK** | Swift Package Manager | iOS / macOS アプリ向けコアライブラリ |
| **MCP Server** | `npx -y waxmcp@latest mcp install` | Claude Code / MCP 連携 |
| **CLI** | `npx -y waxmcp@latest` | remember / recall / search 用ターミナルコマンド |

---

## インストール

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

Xcode では **File > Add Package Dependencies** からリポジトリ URL を貼り付けます。

### MCP Server (Claude Code)

```bash
npx -y waxmcp@latest mcp install --scope user
```

### モジュール

| モジュール | 役割 |
|---|---|
| `Wax` | ハイブリッド検索、RAG、ナレッジグラフを備えたフルオーケストレーター |
| `WaxCore` | 低レベルのフレームストレージ、WAL、コミットエンジン |
| `WaxTextSearch` | BM25 全文検索（GRDB + FTS5） |
| `WaxVectorSearch` | HNSW ベクトル類似検索（USearch） |
| `WaxVectorSearchMiniLM` | オンデバイス MiniLM 埋め込みプロバイダー |

---

## クイックスタート

```swift
import Wax
import WaxVectorSearchMiniLM

// 1. メモリストアを開く（なければ作成）
let memory = try await MemoryOrchestrator.openMiniLM(
    at: .documentsDirectory.appending(path: "agent.wax")
)

// 2. 記憶を保存
try await memory.remember("User prefers concise answers and hates bullet points.")
try await memory.remember("The user's name is Alex and they live in Toronto.")
try await memory.remember("Alex is building a habit tracker in SwiftUI.")

// 3. 関連コンテキストを意味検索で取得
let context = try await memory.recall(query: "how should I address the user?")
print(context.items.map(\.text))
// ["The user's name is Alex and they live in Toronto.",
//  "User prefers concise answers and hates bullet points."]
```

### ナレッジグラフ

```swift
// エンティティを作成
try await memory.upsertEntity(key: "person:alex", kind: "person", aliases: ["Alex", "the user"])

// ファクトを追加
try await memory.assertFact(subject: "person:alex", predicate: "lives_in", object: "Toronto")
try await memory.assertFact(subject: "person:alex", predicate: "building", object: "habit tracker")

// ファクトを取得
let facts = try await memory.facts(subject: "person:alex")
```

### セッションハンドオフ

```swift
// セッション終了時に次回用コンテキストを保存
try await memory.rememberHandoff(
    summary: "Helped Alex debug a SwiftUI layout issue",
    project: "habit-tracker",
    pendingTasks: ["Fix the tab bar animation", "Add onboarding flow"]
)

// 次回セッション開始時に続きから再開
if let handoff = try await memory.latestHandoff(project: "habit-tracker") {
    print(handoff.summary)
    print(handoff.pendingTasks)
}
```

---

## Claude Code 連携

MCP サーバーをインストールしたら、Claude Code が Wax をメモリとして使うように `CLAUDE.md` へ次を追加します。

<details>
<summary><strong>CLAUDE.md スニペット</strong>（クリックして展開）</summary>

```markdown
## Rules

1. **Session start** — call `wax_handoff_latest` to resume prior context
2. **Before answering** — call `wax_recall` to check what you already know
3. **When you learn something durable** — call `wax_remember`
4. **When corrected** — call `wax_forget` with what changed
5. **Session end** — call `wax_handoff` with summary + pending tasks

## Tools

| Tool | When |
|------|------|
| `wax_remember` | User states a preference, makes a decision, or you learn a stable pattern |
| `wax_recall` | Before answering anything that might have prior context |
| `wax_forget` | User corrects you or facts become outdated |
| `wax_context` | Need the full picture of a specific entity |
| `wax_reflect` | Audit what you know — entity counts, top predicates, memory health |
| `wax_handoff` | Session ending. Pass `pending_tasks` array for continuity |
| `wax_handoff_latest` | Session starting. Loads last handoff |
```

</details>

---

## アーキテクチャ

<div align="center">
<img src="https://raw.githubusercontent.com/christopherkarani/Wax/main/Resources/website/static/img/architecture.svg" width="800" alt="Wax Architecture" />
</div>

---

## パフォーマンス

<div align="center">
<img src="Resources/website/static/img/benchmarks.svg" width="800" alt="Wax Performance Benchmarks" />
</div>

---

## ファイルフォーマット

すべては 1 つの `.wax` ファイルに保存されます。

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

`.wal`、`.lock`、`.shm` などのサイドカーファイルは作成されません。

---

## 比較

| | Wax | ChromaDB | Pinecone | Core Data + FAISS |
|---|---|---|---|---|
| オンデバイス | Yes | No | No | Yes |
| サーバー不要 | Yes | No | No | Yes |
| ハイブリッド検索 | Yes | Yes | Yes | Manual |
| トークン予算 | Yes | No | No | No |
| ナレッジグラフ | Yes | No | No | No |
| 単一ファイル | Yes | No | No | No |
| Swift ネイティブ API | Yes | No | No | Partial |
| MCP サーバー | Yes | No | No | No |
| プライバシー（データは端末内） | Yes | No | No | Yes |

---

## 要件

| | 最小 |
|---|---|
| Swift | 6.1+ |
| iOS | 18.0 |
| macOS | 15.0 |
| Xcode | 16.0 |

Metal による埋め込み高速化のため Apple Silicon を推奨します。Intel Mac は自動で CPU にフォールバックします。

---

## ロードマップ

- [ ] CloudKit 同期（オプトイン、暗号化）
- [ ] iCloud Drive `.wax` ドキュメント対応
- [ ] メモリクラスタリングと重複排除
- [ ] より小型な量子化埋め込みモデル
- [ ] メモリプロファイリング用 Instruments テンプレート

---

## コントリビュート

Issue と PR を歓迎します。Wax で何か作っているなら、ぜひ [Discussion](https://github.com/christopherkarani/Wax/discussions) を開いて共有してください。

---

## Star History

[![Star History Chart](https://api.star-history.com/svg?repos=christopherkarani/wax&type=date&legend=top-left)](https://www.star-history.com/#christopherkarani/wax&type=date&legend=top-left)

---

## ライセンス

Apache License 2.0。詳細は [LICENSE](LICENSE) を参照してください。

---

<div align="center">
<sub>ユーザーデータはユーザーのデバイスにあるべきだと考える開発者のために。</sub>
</div>
