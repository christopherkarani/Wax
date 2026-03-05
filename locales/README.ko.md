<!-- HEADER:START -->
<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="../docs/assets/banner-dark.svg">
    <img src="../docs/assets/banner-light.svg" width="800" alt="Wax Banner" />
  </picture>
</div>

<p align="center">
  [English](../README.md) | [Español](README.es.md) | [日本語](README.ja.md) | [中文](README.zh-CN.md)
</p>
<!-- HEADER:END -->

<div style="height: 16px;"></div>



<!-- NAV:START -->
<!-- NAV:END -->

<!-- BADGES:START -->

<!-- BADGES:END -->

---

## Wax란?

대부분의 iOS AI 앱은 사용자가 앱을 닫는 순간 메모리를 잃습니다. Wax는 이 문제를 해결합니다.

Wax는 문서, 임베딩, 검색 인덱스, 메타데이터를 하나의 `.wax` 파일에 담는 포터블 AI 메모리 시스템입니다. Core Data, FAISS, Pinecone을 따로 조합하거나 벡터 DB 서버를 운영할 필요 없이, 에이전트가 온디바이스에서 지속 가능하고 검색 가능한 프라이빗 메모리를 사용하도록 해줍니다.

결과적으로 Wax는 Swift 네이티브, 무인프라 메모리 레이어를 제공해 AI 에이전트가 네트워크 호출, API 키, 프라이버시 타협 없이 장기 기억을 휴대할 수 있게 만듭니다.


## Smart Frame이란?

Wax는 AI 메모리를 비디오 인코딩에서 영감을 받은 **append-only Smart Frame 시퀀스**로 구성합니다.

Smart Frame은 콘텐츠와 함께 타임스탬프, 체크섬, 임베딩, 메타데이터를 담는 불변 단위입니다. 프레임은 계층형 surrogate를 지원해 전체 텍스트, 요약, 초소형 요약을 저장할 수 있고, 질의 시 속도와 재현율을 트레이드오프할 수 있습니다.

이 프레임 기반 설계는 다음을 가능하게 합니다.

- 기존 데이터를 수정하거나 손상시키지 않는 append-only 쓰기
- 지식이 시간에 따라 진화하는 과정을 타임라인으로 확인
- 커밋된 불변 프레임과 WAL 기반 충돌 안전성
- LZ4/zlib 기반 효율적 압축
- 손상 복원력을 높이는 이중 헤더 중복


## 핵심 개념

- **하이브리드 검색**: BM25 키워드 검색 + HNSW 벡터 유사도 결합. 표현이 달라도 올바른 메모리를 찾아냅니다.

- **온디바이스 임베딩**: CoreML + Metal 기반 MiniLM 로컬 실행. API 호출, 지연, 비용이 없습니다.

- **토큰 예산**: 하드 리밋을 설정하면 Wax가 매번 컨텍스트를 자동으로 축소/압축해 맞춰줍니다.

- **지식 그래프**: 엔티티-팩트 트리플 + 팩트 버저닝. 비정형 메모리와 함께 구조화 지식을 assert/retract/query 할 수 있습니다.

- **세션 핸드오프**: `handoff` / `handoff-latest`가 기본 제공되어 대화 연속성을 유지합니다.

- **단일 포터블 파일**: 전체 메모리 저장소가 하나의 `.wax` 파일입니다. 백업, 동기화, 이동이 쉽습니다.


## 사용 사례

- **대화형 에이전트**: 세션 간 선호도, 히스토리, 사실 기억
- **노트 앱**: 시맨틱 검색("WWDC에 대해 내가 쓴 내용 전부 찾기")
- **개인 비서**: 사용자 습관을 학습하되 데이터는 디바이스 밖으로 전송하지 않음
- **RAG 파이프라인**: 민감 정보/오프라인 우선 시나리오에 맞는 온디바이스 구축
- **Claude Code / MCP 에이전트**: MCP 서버를 통한 지속형 장기 메모리
- **Video RAG**: 전사/자막 인덱싱 기반 자연어 비디오 검색


## SDK & CLI

| 패키지 | 설치 | 설명 |
|---|---|---|
| **Swift SDK** | Swift Package Manager | iOS/macOS 앱용 코어 라이브러리 |
| **MCP Server** | `npx -y waxmcp@latest mcp install` | Claude Code / MCP 연동 |
| **CLI** | `npx -y waxmcp@latest` | remember, recall, search 터미널 명령 |

---

## 설치

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

Xcode에서는 **File > Add Package Dependencies**에서 저장소 URL을 붙여 넣으면 됩니다.

### MCP Server (Claude Code)

```bash
npx -y waxmcp@latest mcp install --scope user
```

### 모듈

| 모듈 | 용도 |
|---|---|
| `Wax` | 하이브리드 검색, RAG, 지식 그래프를 포함한 전체 오케스트레이터 |
| `WaxCore` | 저수준 프레임 저장소, WAL, 커밋 엔진 |
| `WaxTextSearch` | BM25 전문 검색 (GRDB + FTS5) |
| `WaxVectorSearch` | HNSW 벡터 유사도 검색 (USearch) |
| `WaxVectorSearchMiniLM` | 온디바이스 MiniLM 임베딩 프로바이더 |

---

## 빠른 시작

```swift
import Wax
import WaxVectorSearchMiniLM

// 1. 메모리 저장소 열기(또는 생성)
let memory = try await MemoryOrchestrator.openMiniLM(
    at: .documentsDirectory.appending(path: "agent.wax")
)

// 2. 메모리 저장
try await memory.remember("User prefers concise answers and hates bullet points.")
try await memory.remember("The user's name is Alex and they live in Toronto.")
try await memory.remember("Alex is building a habit tracker in SwiftUI.")

// 3. 관련 컨텍스트를 의미 기반으로 조회
let context = try await memory.recall(query: "how should I address the user?")
print(context.items.map(\.text))
// ["The user's name is Alex and they live in Toronto.",
//  "User prefers concise answers and hates bullet points."]
```

### 지식 그래프

```swift
// 엔티티 생성
try await memory.upsertEntity(key: "person:alex", kind: "person", aliases: ["Alex", "the user"])

// 팩트 단언
try await memory.assertFact(subject: "person:alex", predicate: "lives_in", object: "Toronto")
try await memory.assertFact(subject: "person:alex", predicate: "building", object: "habit tracker")

// 팩트 조회
let facts = try await memory.facts(subject: "person:alex")
```

### 세션 핸드오프

```swift
// 세션 종료 시 다음 세션을 위한 컨텍스트 저장
try await memory.rememberHandoff(
    summary: "Helped Alex debug a SwiftUI layout issue",
    project: "habit-tracker",
    pendingTasks: ["Fix the tab bar animation", "Add onboarding flow"]
)

// 다음 세션 시작 시 이어서 작업
if let handoff = try await memory.latestHandoff(project: "habit-tracker") {
    print(handoff.summary)
    print(handoff.pendingTasks)
}
```

---

## Claude Code 통합

MCP 서버 설치 후, Claude Code가 Wax를 메모리로 사용하도록 `CLAUDE.md`에 아래를 추가하세요.

<details>
<summary><strong>CLAUDE.md 스니펫</strong> (클릭해서 펼치기)</summary>

```markdown
## 규칙

1. **세션 시작** — `wax_handoff_latest` 호출로 이전 컨텍스트 복원
2. **응답 전** — `wax_recall` 호출로 이미 알고 있는 내용 확인
3. **지속 가치가 있는 정보를 학습했을 때** — `wax_remember` 호출
4. **정정받았을 때** — `wax_forget` 호출로 사실 업데이트
5. **세션 종료** — 요약 + pending tasks와 함께 `wax_handoff` 호출

## 도구

| Tool | 언제 사용 |
|------|------|
| `wax_remember` | 사용자가 선호/결정을 밝히거나 안정적 패턴을 학습했을 때 |
| `wax_recall` | 이전 컨텍스트가 필요할 수 있는 답변 전 |
| `wax_forget` | 사용자가 정정했거나 사실이 오래되었을 때 |
| `wax_context` | 특정 엔티티의 전체 맥락이 필요할 때 |
| `wax_reflect` | 지식 감사: 엔티티 수, 주요 predicate, 메모리 상태 |
| `wax_handoff` | 세션 종료 시. 연속성을 위해 `pending_tasks` 전달 |
| `wax_handoff_latest` | 세션 시작 시. 마지막 핸드오프 로드 |
```

</details>

---

## 아키텍처

<div align="center">
<img src="https://raw.githubusercontent.com/christopherkarani/Wax/main/Resources/website/static/img/architecture.svg" width="800" alt="Wax Architecture" />
</div>

---

## 성능

<div align="center">
<img src="Resources/website/static/img/benchmarks.svg" width="800" alt="Wax Performance Benchmarks" />
</div>

---

## 파일 포맷

모든 데이터는 단일 `.wax` 파일에 저장됩니다.

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

`.wal`, `.lock`, `.shm` 같은 사이드카 파일은 생성되지 않습니다.

---

## 비교

| | Wax | ChromaDB | Pinecone | Core Data + FAISS |
|---|---|---|---|---|
| 온디바이스 | Yes | No | No | Yes |
| 서버 불필요 | Yes | No | No | Yes |
| 하이브리드 검색 | Yes | Yes | Yes | Manual |
| 토큰 예산 | Yes | No | No | No |
| 지식 그래프 | Yes | No | No | No |
| 단일 파일 | Yes | No | No | No |
| Swift 네이티브 API | Yes | No | No | Partial |
| MCP 서버 | Yes | No | No | No |
| 프라이버시(데이터가 기기 내 유지) | Yes | No | No | Yes |

---

## 요구 사항

| | 최소 |
|---|---|
| Swift | 6.1+ |
| iOS | 18.0 |
| macOS | 15.0 |
| Xcode | 16.0 |

Metal 가속 임베딩을 위해 Apple Silicon을 권장합니다. Intel Mac은 자동으로 CPU로 폴백합니다.

---

## 로드맵

- [ ] CloudKit 동기화 (옵트인, 암호화)
- [ ] iCloud Drive `.wax` 문서 지원
- [ ] 메모리 클러스터링 및 중복 제거
- [ ] 더 작은 용량의 양자화 임베딩 모델
- [ ] 메모리 프로파일링용 Instruments 템플릿

---

## 기여하기

Issue와 PR을 환영합니다. Wax로 무언가를 만들고 있다면 [Discussion](https://github.com/christopherkarani/Wax/discussions)을 열어 공유해 주세요.

---

## Star 히스토리

[![Star History Chart](https://api.star-history.com/svg?repos=christopherkarani/wax&type=date&legend=top-left)](https://www.star-history.com/#christopherkarani/wax&type=date&legend=top-left)

---

## 라이선스

Apache License 2.0. 자세한 내용은 [LICENSE](LICENSE)를 확인하세요.

---

<div align="center">
<sub>사용자 데이터는 사용자의 기기에 있어야 한다고 믿는 개발자를 위해 만들었습니다.</sub>
</div>
