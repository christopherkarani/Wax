<!-- HEADER:START -->
<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="../docs/assets/banner-dark.svg">
    <img src="../docs/assets/banner-light.svg" width="800" alt="Wax Banner">
  </picture>
</div>

<div style="height: 16px;"></div>

<p align="center">
  <strong>Wax es una capa de memoria de alto rendimiento en un solo archivo para agentes de IA en plataformas Apple.</strong><br/>
  En el dispositivo, privado y portable. Sin servidor y sin dependencia de la nube.
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

## ¿Qué es Wax?

Wax es un motor de persistencia nativo en Swift diseñado para la próxima generación de agentes de IA. Encapsula documentos, embeddings de alta dimensión y conocimiento estructurado en un único archivo portable `.wax`.

A diferencia de las bases de datos tradicionales que requieren configuraciones complejas o dependencias en la nube, Wax proporciona una **capa de memoria unificada** que reside completamente en el dispositivo, aprovechando la inferencia acelerada por Metal para una latencia de recuperación inferior a 10 ms.

### ¿Por qué Wax?

| Característica   | Wax                    | SQLite (FTS5)          | Vector DBs en la Nube  |
|:-----------------|:-----------------------|:-----------------------|:-----------------------|
| **Búsqueda**     | Híbrida (Texto + Vec)  | Solo Texto*            | Solo Vector*           |
| **Latencia**     | **~6ms (p95)**         | ~10ms (p95)            | 150ms - 500ms+         |
| **Privacidad**   | 100% Local             | 100% Local             | Alojado en la nube     |
| **Configuración**| Cero Config            | Baja                   | Compleja (Claves API)  |
| **Arquitectura** | Nativo Apple Silicon   | Genérico               | Varía                  |

### 📦 ¿Por qué un solo archivo `.wax`?
La mayoría de los sistemas RAG requieren una base de datos, un almacén de vectores y un servidor de archivos. Wax reúne documentos, metadatos e índices de alta dimensión en un solo binario portable.
*   **Cero Infraestructura:** Sin Docker, sin configuración de BD, sin facturas de nube.
*   **Verdaderamente Portable:** Envía la memoria de tu agente por AirDrop a otro Mac o sincronízala a través de iCloud.
*   **Atómico:** Un archivo para respaldar, un archivo para control de versiones, un archivo para eliminar.

---

## Rendimiento

Wax está optimizado para la arquitectura de la serie M, proporcionando una recuperación casi instantánea incluso con índices locales a gran escala.

### Latencia de recuperación (p95)
*Menor es mejor. Medido en milisegundos.*

```text
Wax (Híbrido) |██ 6.1ms
SQLite (Texto) |████ 12ms
RAG en la nube |██████████████████████████████████████████████████ 150ms+
```

### Tiempo de apertura en frío (p95)
*Menor es mejor. Medido en milisegundos.*

```text
Wax           |███ 9.2ms
Tradicional   |██████████████████████████████████████ 120ms+
```

> [!TIP]
> **Rendimiento de ingesta:** Wax maneja **85.9 docs/s** con indexación híbrida completa en un M3 Max.
> Informe completo de benchmarks: [docs/benchmarks/2026-03-06-performance-results.md](../docs/benchmarks/2026-03-06-performance-results.md)

---

## Arquitectura

Wax utiliza un modelo de **"Base de datos de bases de datos"**. Gestiona su propio formato de almacenamiento basado en tramas mientras integra motores de búsqueda especializados (SQLite FTS5 e HNSW acelerado por Metal) como blobs serializados dentro del archivo principal.

### Diseño interno del archivo

```text
┌──────────────────────────────────────────────────────────────────────────┐
│                    Páginas de encabezado duales (A/B)                    │
│   (Magic, Versión, Generación, Punteros a WAL y TOC, Checksums)          │
├──────────────────────────────────────────────────────────────────────────┤
│                       WAL (Write-Ahead Log)                              │
│ (Búfer circular atómico para mutaciones no confirmadas resilientes)      │
├──────────────────────────────────────────────────────────────────────────┤
│                       Tramas de datos comprimidos                        │
│   ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐       │
│   │ Trama 0 (LZ4)    │  │ Trama 1 (LZ4)    │  │ Trama 2 (LZ4)    │ ...   │
│   │ [Doc original]   │  │ [Metadatos/JSON] │  │ [Info sistema]   │       │
│   └──────────────────┘  └──────────────────┘  └──────────────────┘       │
├──────────────────────────────────────────────────────────────────────────┤
│                       Índices de búsqueda híbrida                        │
│   ┌──────────────────────────────┐  ┌──────────────────────────────┐     │
│   │ Blob SQLite FTS5             │  │ Índice Metal HNSW            │     │
│   │ (Búsqueda texto + Datos EAV) │  │ (Búsqueda vectorial)         │     │
│   └──────────────────────────────┘  └──────────────────────────────┘     │
├──────────────────────────────────────────────────────────────────────────┤
│                       TOC (Tabla de contenidos)                          │
│ (Índice de tramas, relaciones padre-hijo y manifiestos del motor)        │
└──────────────────────────────────────────────────────────────────────────┘
```

1. **Resiliencia atómica**: Los encabezados duales y el WAL aseguran que incluso si el proceso falla durante la escritura, el almacén permanezca consistente.
2. **Recuperación unificada**: Una sola consulta activa la ejecución paralela en los motores BM25 (texto) e HNSW (vector).
3. **Conocimiento estructurado**: Almacenamiento EAV (Entidad-Atributo-Valor) integrado para hechos persistentes y razonamiento a largo plazo.

---

## Inicio rápido

```swift
import Wax

// Usa una ubicación con permisos de escritura (funciona en apps y herramientas CLI)
let url = URL.documentsDirectory.appending(path: "agent.wax")

// 1. Abre un almacén de memoria
let memory = try await Memory(at: url)

// 2. Guarda una memoria
try await memory.save("El usuario está construyendo un rastreador de hábitos en SwiftUI.")

// 3. Busca con recuperación híbrida (texto + vector)
let results = try await memory.search("¿Qué está construyendo el usuario?")

if let best = results.items.first {
    print("Encontrado: \(best.text)")
    // → "Encontrado: El usuario está construyendo un rastreador de hábitos en SwiftUI."
}

try await memory.close()
```

<details>
<summary><strong>Ejemplo en SwiftUI</strong></summary>

```swift
import SwiftUI
import Wax

struct ContentView: View {
    @State private var result = "Buscando…"

    var body: some View {
        Text(result)
            .task {
                do {
                    let url = URL.documentsDirectory.appending(path: "agent.wax")
                    let memory = try await Memory(at: url)

                    try await memory.save("El usuario está construyendo un rastreador de hábitos en SwiftUI.")
                    let context = try await memory.search("¿Qué está construyendo el usuario?")

                    result = context.items.first?.text ?? "Nada encontrado"
                    try await memory.close()
                } catch {
                    result = "Error: \(error.localizedDescription)"
                }
            }
    }
}
```

</details>

<details>
<summary><strong>Herramienta CLI (main.swift)</strong></summary>

```swift
import Wax

@main
struct AgentMemory {
    static func main() async throws {
        let url = URL.documentsDirectory.appending(path: "agent.wax")
        let memory = try await Memory(at: url)

        try await memory.save("El usuario está construyendo un rastreador de hábitos en SwiftUI.")

        let results = try await memory.search("¿Qué está construyendo el usuario?")
        if let best = results.items.first {
            print("Encontrado: \(best.text)")
        }

        try await memory.close()
    }
}
```

</details>

¿Buscas almacenar hechos persistentes y razonamiento a largo plazo? Consulta [Memoria Estructurada](../Sources/WaxCore/WaxCore.docc/Articles/StructuredMemory.md).

---

## Instalación

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/christopherkarani/Wax.git", from: "0.1.8")
]
```

---

## Herramientas del ecosistema

### 🤖 Servidor MCP
Wax proporciona un servidor **Model Context Protocol (MCP)** de primer nivel. Conecta tu memoria local a Claude Code o cualquier agente compatible con MCP.

```bash
npx -y waxmcp@latest mcp install --scope user
```

### 🔍 WaxRepo
Una TUI de búsqueda semántica para tu historial de git. Indexa cualquier repositorio y encuentra código o commits utilizando lenguaje natural.

```bash
# Desde cualquier repositorio git
wax-repo index
wax-repo search "¿dónde implementamos el WAL?"
```

---

## Licencia

Wax se lanza bajo la Licencia Apache 2.0. Consulta [LICENSE](../LICENSE) para más detalles.

<div align="center">
<sub>Construido para desarrolladores que creen que los datos pertenecen al dispositivo del usuario.</sub>
</div>
