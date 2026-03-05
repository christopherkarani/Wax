<!-- HEADER:START -->
<div align="center">
<img src="Resources/website/static/img/banner.svg" width="800" alt="Wax Banner" />
</div>
<!-- HEADER:END -->

<div style="height: 16px;"></div>

<p align="center">
  <strong>Wax es una capa de memoria de archivo único para agentes de IA en plataformas Apple.</strong><br/>
  En dispositivo, privada y portable: sin servidor, sin nube, todo en un solo archivo <code>.wax</code>.
</p>

<p align="center">
  <strong>Idiomas:</strong>
  <a href="README.md">English</a> ·
  <a href="README.zh-CN.md">简体中文</a> ·
  <a href="README.ko.md">한국어</a> ·
  <a href="README.ja.md">日本語</a> ·
  <a href="README.es.md">Español</a> ·
  <a href="README.pt.md">Português</a>
</p>

<!-- NAV:START -->
<p align="center">
  <a href="https://wax.sh">Sitio web</a>
  ·
  <a href="https://wax.sh/docs">Docs</a>
  ·
  <a href="https://github.com/christopherkarani/Wax/discussions">Discusiones</a>
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

## ¿Qué es Wax?

La mayoría de apps de IA en iOS pierden la memoria en cuanto el usuario las cierra. Wax soluciona eso.

Wax es un sistema de memoria de IA portable que empaqueta documentos, embeddings, índices de búsqueda y metadatos en un único archivo `.wax`. En lugar de combinar Core Data, FAISS, Pinecone o levantar servidores de bases vectoriales, Wax te da memoria persistente, buscable y privada para tus agentes, totalmente en dispositivo.

El resultado es una capa de memoria nativa en Swift y sin infraestructura, que da memoria a largo plazo a los agentes de IA en cualquier lugar: sin llamadas de red, sin claves API y sin compromisos de privacidad.


## ¿Qué son los Smart Frames?

Wax organiza la memoria de IA como una **secuencia append-only de Smart Frames**, inspirada en codificación de video.

Un Smart Frame es una unidad inmutable que guarda contenido junto con marcas de tiempo, checksums, embeddings y metadatos. Los frames admiten surrogates por niveles: texto completo, resumen o micro-resumen, para balancear recall y velocidad al consultar.

Este diseño basado en frames permite:

- Escrituras append-only sin modificar ni corromper datos existentes
- Inspección tipo timeline de cómo evoluciona el conocimiento
- Seguridad ante fallos con frames inmutables confirmados y WAL
- Compresión eficiente con LZ4/zlib
- Redundancia de doble header para mayor resiliencia ante corrupción


## Conceptos clave

- **Recuperación híbrida**: búsqueda BM25 por palabras clave fusionada con similitud vectorial HNSW. Recupera la memoria correcta incluso con redacción distinta.

- **Embeddings on-device**: MiniLM en local con CoreML y Metal. Sin llamadas API, sin latencia extra, sin costo extra.

- **Presupuestos de tokens**: define un límite estricto. Wax recorta y comprime contexto automáticamente para encajar siempre.

- **Grafo de conocimiento**: triples entidad-relación con versionado de hechos. Puedes afirmar, retractar y consultar conocimiento estructurado junto con memoria no estructurada.

- **Session handoffs**: ciclo de sesión de primera clase con `handoff` / `handoff-latest` para continuidad entre conversaciones.

- **Archivo único portable**: toda la memoria vive en un archivo `.wax`. Respáldalo, sincronízalo, muévelo.


## Casos de uso

- **Agentes conversacionales** que recuerdan preferencias, historial y hechos entre sesiones
- **Apps de notas** con búsqueda semántica ("encuentra todo lo que escribí sobre WWDC")
- **Asistentes personales** que aprenden hábitos sin enviar datos fuera del dispositivo
- **Pipelines RAG** totalmente on-device para apps sensibles u offline-first
- **Agentes Claude Code / MCP** con memoria persistente vía servidor MCP
- **Video RAG** para indexar transcripciones y subtítulos con búsqueda de video en lenguaje natural


## SDKs y CLI

| Paquete | Instalación | Descripción |
|---|---|---|
| **Swift SDK** | Swift Package Manager | Librería principal para apps iOS y macOS |
| **MCP Server** | `npx -y waxmcp@latest mcp install` | Integración con Claude Code / MCP |
| **CLI** | `npx -y waxmcp@latest` | Comandos de terminal para remember, recall, search |

---

## Instalación

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

O en Xcode: **File > Add Package Dependencies** y pega la URL del repositorio.

### MCP Server (Claude Code)

```bash
npx -y waxmcp@latest mcp install --scope user
```

### Módulos

| Módulo | Propósito |
|---|---|
| `Wax` | Orquestador completo con búsqueda híbrida, RAG y grafo de conocimiento |
| `WaxCore` | Almacenamiento de frames, WAL y motor de commit de bajo nivel |
| `WaxTextSearch` | Búsqueda de texto BM25 (GRDB + FTS5) |
| `WaxVectorSearch` | Búsqueda por similitud vectorial HNSW (USearch) |
| `WaxVectorSearchMiniLM` | Proveedor MiniLM on-device |

---

## Inicio rápido

```swift
import Wax
import WaxVectorSearchMiniLM

// 1. Abre (o crea) una memoria
let memory = try await MemoryOrchestrator.openMiniLM(
    at: .documentsDirectory.appending(path: "agent.wax")
)

// 2. Guarda recuerdos
try await memory.remember("User prefers concise answers and hates bullet points.")
try await memory.remember("The user's name is Alex and they live in Toronto.")
try await memory.remember("Alex is building a habit tracker in SwiftUI.")

// 3. Recupera contexto relevante semánticamente
let context = try await memory.recall(query: "how should I address the user?")
print(context.items.map(\.text))
// ["The user's name is Alex and they live in Toronto.",
//  "User prefers concise answers and hates bullet points."]
```

### Grafo de conocimiento

```swift
// Crear entidades
try await memory.upsertEntity(key: "person:alex", kind: "person", aliases: ["Alex", "the user"])

// Afirmar hechos
try await memory.assertFact(subject: "person:alex", predicate: "lives_in", object: "Toronto")
try await memory.assertFact(subject: "person:alex", predicate: "building", object: "habit tracker")

// Consultar hechos
let facts = try await memory.facts(subject: "person:alex")
```

### Handoffs de sesión

```swift
// Fin de sesión: guardar contexto para la próxima
try await memory.rememberHandoff(
    summary: "Helped Alex debug a SwiftUI layout issue",
    project: "habit-tracker",
    pendingTasks: ["Fix the tab bar animation", "Add onboarding flow"]
)

// Inicio de la siguiente sesión: retomar donde quedaste
if let handoff = try await memory.latestHandoff(project: "habit-tracker") {
    print(handoff.summary)
    print(handoff.pendingTasks)
}
```

---

## Integración con Claude Code

Después de instalar el servidor MCP, agrega esto en tu `CLAUDE.md` para que Claude Code use Wax como memoria:

<details>
<summary><strong>Snippet de CLAUDE.md</strong> (haz clic para expandir)</summary>

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

## Arquitectura

<div align="center">
<img src="https://raw.githubusercontent.com/christopherkarani/Wax/main/Resources/website/static/img/architecture.svg" width="800" alt="Wax Architecture" />
</div>

---

## Rendimiento

<div align="center">
<img src="Resources/website/static/img/benchmarks.svg" width="800" alt="Wax Performance Benchmarks" />
</div>

---

## Formato de archivo

Todo vive en un único archivo `.wax`:

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

Sin archivos sidecar `.wal`, `.lock`, `.shm` ni similares.

---

## Comparación

| | Wax | ChromaDB | Pinecone | Core Data + FAISS |
|---|---|---|---|---|
| On-device | Yes | No | No | Yes |
| Sin servidor | Yes | No | No | Yes |
| Búsqueda híbrida | Yes | Yes | Yes | Manual |
| Presupuesto de tokens | Yes | No | No | No |
| Grafo de conocimiento | Yes | No | No | No |
| Archivo único | Yes | No | No | No |
| API Swift nativa | Yes | No | No | Partial |
| Servidor MCP | Yes | No | No | No |
| Privacidad (datos en dispositivo) | Yes | No | No | Yes |

---

## Requisitos

| | Mínimo |
|---|---|
| Swift | 6.1+ |
| iOS | 18.0 |
| macOS | 15.0 |
| Xcode | 16.0 |

Se recomienda Apple Silicon para embeddings acelerados por Metal. En Intel Mac hay fallback a CPU automáticamente.

---

## Hoja de ruta

- [ ] Sincronización CloudKit (opt-in, cifrada)
- [ ] Soporte de documentos `.wax` en iCloud Drive
- [ ] Clustering y deduplicación de memoria
- [ ] Modelos de embedding cuantizados para menor huella
- [ ] Plantilla de Instruments para perfilado de memoria

---

## Contribuir

Se aceptan issues y PRs. Si estás construyendo algo con Wax, abre una [Discussion](https://github.com/christopherkarani/Wax/discussions): nos encantaría verlo.

---

## Historial de estrellas

[![Star History Chart](https://api.star-history.com/svg?repos=christopherkarani/wax&type=date&legend=top-left)](https://www.star-history.com/#christopherkarani/wax&type=date&legend=top-left)

---

## Licencia

Apache License 2.0. Consulta [LICENSE](LICENSE) para más detalles.

---

<div align="center">
<sub>Hecho para desarrolladores que creen que los datos de usuario pertenecen al dispositivo del usuario.</sub>
</div>
