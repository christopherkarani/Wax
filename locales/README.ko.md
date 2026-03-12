<!-- HEADER:START -->
<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="../docs/assets/banner-dark.svg">
    <img src="../docs/assets/banner-light.svg" width="800" alt="Wax Banner">
  </picture>
</div>

<div style="height: 16px;"></div>

<p align="center">
  <strong>Wax는 Apple 플랫폼의 AI 에이전트를 위한 고성능 단일 파일 메모리 레이어입니다.</strong><br/>
  온디바이스, 프라이빗, 포ータ블 — 서버 없음, 클라우드 없음, 인프라 구성 필요 없음.
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

## Wax란 무엇인가요?

Wax는 차세대 AI 에이전트를 위해 설계된 Swift 네이티브 지속성 엔진입니다. 문서, 고차원 임베딩 및 구조화된 지식을 단일 포터블 `.wax` 파일로 캡슐화합니다.

복잡한 설정이나 클라우드 의존성이 필요한 기존 데이터베이스와 달리, Wax는 완전히 기기 내에서 실행되는 **통합 메모리 레이어**를 제공하며, Metal 가속 추론을 활용하여 10ms 미만의 리콜(재현) 지연 시간을 실현합니다.

### 왜 Wax인가요?

| 기능             | Wax                    | SQLite (FTS5)          | 클라우드 벡터 DB        |
|:-----------------|:-----------------------|:-----------------------|:-----------------------|
| **검색**         | 하이브리드 (텍스트 + 벡터) | 텍스트 전용*           | 벡터 전용*             |
| **지연 시간**     | **~6ms (p95)**         | ~10ms (p95)            | 150ms - 500ms+         |
| **개인정보 보호** | 100% 로컬              | 100% 로컬              | 클라우드 호스팅         |
| **설정**         | 설정 필요 없음          | 낮음                   | 복잡 (API 키 필요)      |
| **아키텍처**     | Apple Silicon 네이티브   | 범용                   | 다양함                 |

### 📦 왜 단일 `.wax` 파일인가요?
대부분의 RAG 시스템에는 데이터베이스, 벡터 저장소 및 파일 서버가 필요합니다. Wax는 문서, 메타데이터 및 고차원 인덱스를 포함한 모든 것을 하나의 포터블 바이너리로 묶습니다.
*   **인프라 필요 없음:** Docker 없음, DB 설정 없음, 클라우드 비용 없음.
*   **진정한 포터빌리티:** 에이전트의 메모리를 다른 Mac으로 AirDrop하거나 iCloud를 통해 동기화하세요.
*   **원자성:** 백업할 파일 하나, 버전 제어할 파일 하나, 삭제할 파일 하나면 충분합니다.

---

## 성능

Wax는 M 시리즈 아키텍처에 최적화되어 있어 대규모 로컬 인덱스에서도 즉각적인 리콜을 제공합니다.

### 리콜 지연 시간 (p95)
*수치가 낮을수록 좋습니다. 밀리초(ms) 단위로 측정.*

```text
Wax (하이브리드) |██ 6.1ms
SQLite (텍스트) |████ 12ms
클라우드 RAG     |██████████████████████████████████████████████████ 150ms+
```

### 콜드 오픈 시간 (p95)
*수치가 낮을수록 좋습니다. 밀리초(ms) 단위로 측정.*

```text
Wax           |███ 9.2ms
기존 방식      |██████████████████████████████████████ 120ms+
```

> [!TIP]
> **수집 처리량:** Wax는 M3 Max에서 전체 하이브리드 인덱싱을 통해 **초당 85.9개의 문서**를 처리합니다.
> 전체 벤치마크 보고서: [docs/benchmarks/2026-03-06-performance-results.md](../docs/benchmarks/2026-03-06-performance-results.md)

---

## 아키텍처

Wax는 **"데이터베이스의 데이터베이스"** 모델을 사용합니다. 자체적인 프레임 기반 저장소 형식을 관리하는 동시에 전문 검색 엔진(SQLite FTS5 및 Metal 가속 HNSW)을 메인 파일 내에 직렬화된 blob으로 내장합니다.

### 내부 파일 레이아웃

```text
┌──────────────────────────────────────────────────────────────────────────┐
│                          듀얼 헤더 페이지 (A/B)                          │
│   (Magic, 버전, 세대, WAL 및 TOC 포인터, 체크섬)                         │
├──────────────────────────────────────────────────────────────────────────┤
│                          WAL (Write-Ahead Log)                           │
│   (충돌 복원력이 있는 미커밋 변경사항을 위한 원자적 링 버퍼)             │
├──────────────────────────────────────────────────────────────────────────┤
│                          압축된 데이터 프레임                            │
│   ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐       │
│   │ 프레임 0 (LZ4)    │  │ 프레임 1 (LZ4)    │  │ 프레임 2 (LZ4)    │ ...   │
│   │ [원본 문서]       │  │ [메타데이터/JSON]  │  │ [시스템 정보]     │       │
│   └──────────────────┘  └──────────────────┘  └──────────────────┘       │
├──────────────────────────────────────────────────────────────────────────┤
│                          하이브리드 검색 인덱스                          │
│   ┌──────────────────────────────┐  ┌──────────────────────────────┐     │
│   │ SQLite FTS5 Blob             │  │ Metal HNSW 인덱스            │     │
│   │ (텍스트 검색 + EAV 사실)      │  │ (벡터 검색)                  │     │
│   └──────────────────────────────┘  └──────────────────────────────┘     │
├──────────────────────────────────────────────────────────────────────────┤
│                          TOC (Table of Contents)                         │
│   (모든 프레임 인덱스, 부모-자식 관계 및 엔진 매니페스트)                │
└──────────────────────────────────────────────────────────────────────────┘
```

1. **원자적 복원력**: 듀얼 헤더와 WAL은 쓰기 도중에 프로세스가 충돌하더라도 저장소의 일관성을 보장합니다.
2. **통합 검색**: 단일 쿼리로 BM25(텍스트) 및 HNSW(벡터) 엔진에서 병렬 실행을 트리거합니다.
3. **구조화된 지식**: 지속적인 사실 및 장기적인 추론을 위한 내장 EAV(Entity-Attribute-Value) 저장소.

---

## 빠른 시작

즉시 시작하려면 이것을 `main.swift` 파일에 복사하여 붙여넣으세요.

```swift
import Foundation
import Wax
import WaxVectorSearchMiniLM

@main
struct AgentMemory {
    static func main() async throws {
        let url = URL(fileURLWithPath: "agent.wax")

        // 1. 메모리 저장소 초기화 (기기 내 MiniLM 임베딩)
        let memory = try await MemoryOrchestrator.openMiniLM(at: url)

        // 2. 새로운 메모리 저장
        try await memory.remember("사용자가 SwiftUI로 습관 추적기를 만들고 있습니다.")

        // 3. 의미론적 리콜 수행
        let context = try await memory.recall(query: "사용자가 무엇을 만들고 있나요?")

        if let bestMatch = context.items.first {
            print("리콜: \(bestMatch.text)") 
            // 출력: "리콜: 사용자가 SwiftUI로 습관 추적기를 만들고 있습니다."
        }
    }
}
```

지속적인 사실과 장기적인 추론을 저장하고 싶으신가요? [구조화된 메모리](../Sources/WaxCore/WaxCore.docc/Articles/StructuredMemory.md)를 확인하세요.

---

## 설치

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/christopherkarani/Wax.git", from: "0.1.8")
]
```

---

## 에코시스템 도구

### 🤖 MCP 서버
Wax는 최고 수준의 **Model Context Protocol (MCP)** 서버를 제공합니다. 로컬 메모리를 Claude Code 또는 모든 MCP 호환 에이전트에 연결하세요.

```bash
npx -y waxmcp@latest mcp install --scope user
```

### 🔍 WaxRepo
git 기록을 위한 의미론적 검색 TUI입니다. 모든 저장소를 인덱싱하고 자연어를 사용하여 코드나 커밋을 찾으세요.

```bash
# git 저장소 내부에서 실행
wax-repo index
wax-repo search "WAL을 어디에 구현했나요?"
```

---

## 라이선스

Wax는 Apache License 2.0 하에 출시되었습니다. 자세한 내용은 [LICENSE](../LICENSE)를 참조하세요.

<div align="center">
<sub>사용자 데이터는 사용자의 기기에 있어야 한다고 믿는 개발자를 위해 만들어졌습니다.</sub>
</div>
