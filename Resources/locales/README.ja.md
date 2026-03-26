<!-- HEADER:START -->
<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="../docs/assets/banner-dark.svg">
    <img src="../docs/assets/banner-light.svg" width="800" alt="Wax Banner">
  </picture>
</div>

<div style="height: 16px;"></div>

<p align="center">
  <strong>Waxは、Appleプラットフォーム上のAIエージェントのための高性能な単一ファイルメモリレイヤーです。</strong><br/>
  オンデバイスで、プライベートかつポータブル。サーバーやクラウド前提の構成は不要です。
</p>

<p align="center">
  <a href="https://github.com/christopherkarani/Wax/releases"><img src="https://img.shields.io/github/v/release/christopherkarani/Wax?style=flat-square&logo=swift&logoColor=white&label=Swift" alt="Swift" /></a>
  <a href="https://developer.apple.com/ios/"><img src="https://img.shields.io/badge/platform-iOS%20%7C%20macOS-lightgrey?style=flat-square" alt="Platforms" /></a>
  <a href="https://github.com/christopherkarani/Wax/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-Apache%202.0-blue?style=flat-square" alt="License" /></a>
  <a href="https://github.com/christopherkarani/Wax/stargazers"><img src="https://img.shields.io/github/stars/christopherkarani/Wax?style=flat-square&logo=github" alt="Stars" /></a>
  <a href="https://discord.gg/NHgNh7HJ6M"><img src="https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fdiscord.com%2Fapi%2Fv10%2Finvites%2FNHgNh7HJ6M%3Fwith_counts%3Dtrue&query=%24.approximate_presence_count&suffix=%20online&logo=discord&label=Discord&color=5865F2&style=flat-square" alt="Discord" /></a>
</p>

<p align="center">
  [English](../README.md) | [Español](README.es.md) | [Français](README.fr.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Português](README.pt.md) | [中文](README.zh-CN.md)
</p>
<!-- HEADER:END -->

---

## Waxとは？

Waxは、次世代のAIエージェント向けに設計されたSwiftネイティブの永続化エンジンです。ドキュメント、高次元エンベディング、構造化された知識を、単一のポータブルな `.wax` ファイルにカプセル化します。

複雑なセットアップやクラウドへの依存を必要とする従来のデータベースとは異なり、Waxは完全にオンデバイスで動作する**統合メモリレイヤー**を提供し、Metalで加速された推論を活用することで10ms未満のリコール（想起）レイテンシを実現します。

### なぜWaxなのか？

| 機能             | Wax                    | SQLite (FTS5)          | クラウドベクトルDB      |
|:-----------------|:-----------------------|:-----------------------|:-----------------------|
| **検索**         | ハイブリッド (テキスト+ベクトル) | テキストのみ*          | ベクトルのみ*          |
| **レイテンシ**   | **~6ms (p95)**         | ~10ms (p95)            | 150ms - 500ms+         |
| **プライバシー** | 100% ローカル          | 100% ローカル          | クラウドホスト         |
| **セットアップ** | 構成不要               | 低                     | 複雑 (APIキーが必要)   |
| **アーキテクチャ** | Apple Siliconネイティブ | 汎用                   | 多様                   |

### 📦 なぜ単一の `.wax` ファイルなのか？
ほとんどのRAGシステムは、データベース、ベクトルストア、およびファイルサーバーを必要とします。Waxは、ドキュメント、メタデータ、および高次元インデックスのすべてを、1つのポータブルなバイナリにまとめます。
*   **インフラ構成不要:** Docker不要、DBセットアップ不要、クラウド費用不要。
*   **真のポータビリティ:** エージェントのメモリをAirDropで別のMacに送信したり、iCloud経由で同期したりできます。
*   **アトミック:** バックアップ、バージョン管理、削除のすべてが1つのファイルで完結します。

---

## パフォーマンス

WaxはMシリーズチップのアーキテクチャに最適化されており、大規模なローカルインデックスでも瞬時のリコールを提供します。

### リコールレイテンシ (p95)
*数値が低いほど優れています。ミリ秒単位で測定。*

```text
Wax (ハイブリッド) |██ 6.1ms
SQLite (テキスト) |████ 12ms
クラウドRAG       |██████████████████████████████████████████████████ 150ms+
```

### コールドオープン時間 (p95)
*数値が低いほど優れています。ミリ秒単位で測定。*

```text
Wax           |███ 9.2ms
従来型        |██████████████████████████████████████ 120ms+
```

> [!TIP]
> **取り込みスループット:** Waxは、M3 Max上で完全なハイブリッドインデックス作成を行いながら、**85.9 docs/s** を処理します。
> 完全なベンチマークレポート: [docs/benchmarks/2026-03-06-performance-results.md](../docs/benchmarks/2026-03-06-performance-results.md)

---

## アーキテクチャ

Waxは**「データベースのデータベース」**モデルを採用しています。独自のフレームベースのストレージ形式を管理しながら、特殊な検索エンジン（SQLite FTS5およびMetal加速HNSW）をシリアライズされたバイナリデータ（Blob）としてメインファイル内に埋め込みます。

### 内部ファイルレイアウト

```text
┌──────────────────────────────────────────────────────────────────────────┐
│                          デュアルヘッダーページ (A/B)                    │
│   (Magic, Version, Generation, WALおよびTOCへのポインタ, Checksum)       │
├──────────────────────────────────────────────────────────────────────────┤
│                          WAL (先行書き込みログ)                          │
│   (クラッシュに強い、未コミットの変更のためのアトミックなリングバッファ) │
├──────────────────────────────────────────────────────────────────────────┤
│                          圧縮データフレーム                              │
│   ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐       │
│   │ フレーム 0 (LZ4)  │  │ フレーム 1 (LZ4)  │  │ フレーム 2 (LZ4)  │ ...   │
│   │ [生ドキュメント]  │  │ [メタデータ/JSON] │  │ [システム情報]    │       │
│   └──────────────────┘  └──────────────────┘  └──────────────────┘       │
├──────────────────────────────────────────────────────────────────────────┤
│                          ハイブリッド検索インデックス                    │
│   ┌──────────────────────────────┐  ┌──────────────────────────────┐     │
│   │ SQLite FTS5 Blob             │  │ Metal HNSWインデックス       │     │
│   │ (テキスト検索 + EAVファクト) │  │ (ベクトル検索)               │     │
│   └──────────────────────────────┘  └──────────────────────────────┘     │
├──────────────────────────────────────────────────────────────────────────┤
│                          TOC (目次)                                      │
│   (全フレームのインデックス、親子関係、エンジンマニフェスト)             │
└──────────────────────────────────────────────────────────────────────────┘
```

1. **アトミックな復元力**: デュアルヘッダーとWALにより、書き込み中にプロセスがクラッシュしても、ストアの一貫性が保たれます。
2. **統合された検索**: 1つのクエリでBM25（テキスト）エンジンとHNSW（ベクトル）エンジンを並列実行します。
3. **構造化された知識**: 永続的な事実と長期的な推論のための組み込みEAV（エンティティ・アトリビュート・バリュー）ストレージ。

---

## クイックスタート

```swift
import Wax

// 書き込み可能な場所を使用（アプリとCLIツールの両方で動作）
let url = URL.documentsDirectory.appending(path: "agent.wax")

// 1. メモリストアを開く
let memory = try await Memory(at: url)

// 2. メモリを保存
try await memory.save("ユーザーはSwiftUIで習慣トラッカーを構築しています。")

// 3. ハイブリッドリコール（テキスト + ベクトル）で検索
let results = try await memory.search("ユーザーは何を構築していますか？")

if let best = results.items.first {
    print("検索結果: \(best.text)")
    // → "検索結果: ユーザーはSwiftUIで習慣トラッカーを構築しています。"
}

try await memory.close()
```

<details>
<summary><strong>SwiftUI の例</strong></summary>

```swift
import SwiftUI
import Wax

struct ContentView: View {
    @State private var result = "検索中…"

    var body: some View {
        Text(result)
            .task {
                do {
                    let url = URL.documentsDirectory.appending(path: "agent.wax")
                    let memory = try await Memory(at: url)

                    try await memory.save("ユーザーはSwiftUIで習慣トラッカーを構築しています。")
                    let context = try await memory.search("ユーザーは何を構築していますか？")

                    result = context.items.first?.text ?? "見つかりませんでした"
                    try await memory.close()
                } catch {
                    result = "エラー: \(error.localizedDescription)"
                }
            }
    }
}
```

</details>

<details>
<summary><strong>CLIツール (main.swift)</strong></summary>

```swift
import Wax

@main
struct AgentMemory {
    static func main() async throws {
        let url = URL.documentsDirectory.appending(path: "agent.wax")
        let memory = try await Memory(at: url)

        try await memory.save("ユーザーはSwiftUIで習慣トラッカーを構築しています。")

        let results = try await memory.search("ユーザーは何を構築していますか？")
        if let best = results.items.first {
            print("検索結果: \(best.text)")
        }

        try await memory.close()
    }
}
```

</details>

永続的な事実や長期的な推論を保存したいですか？ [構造化メモリ](../Sources/WaxCore/WaxCore.docc/Articles/StructuredMemory.md)をご覧ください。

---

## インストール

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/christopherkarani/Wax.git", from: "0.1.8")
]
```

---

## エコシステムツール

### 🤖 MCPサーバー
Waxは、ファーストクラスの **Model Context Protocol (MCP)** サーバーを提供します。ローカルメモリをClaude Codeや、MCP互換の任意のエージェントに接続できます。

```bash
npx -y waxmcp@latest mcp install --scope user
```

### 🔍 WaxRepo
git履歴のためのセマンティック検索TUIです。任意のレポジトリをインデックス化し、自然言語を使用してコードやコミットを検索できます。

```bash
# 任意のgitレポジトリ内から実行
wax-repo index
wax-repo search "WALはどこで実装されていますか？"
```

---

## ライセンス

WaxはApache License 2.0の下でリリースされています。詳細は [LICENSE](../LICENSE) をご覧ください。

<div align="center">
<sub>ユーザーデータはユーザーのデバイスに属すると信じる開発者のために構築されました。</sub>
</div>
