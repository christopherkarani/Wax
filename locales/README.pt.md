<!-- HEADER:START -->
<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="../docs/assets/banner-dark.svg">
    <img src="../docs/assets/banner-light.svg" width="800" alt="Wax Banner">
  </picture>
</div>

<div style="height: 16px;"></div>

<p align="center">
  <strong>Wax é uma camada de memória de alto desempenho em um único arquivo para agentes de IA em plataformas Apple.</strong><br/>
  No dispositivo, privado e portátil — sem servidor, sem nuvem, infraestrutura zero.
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

## O que é o Wax?

Wax é um motor de persistência nativo em Swift projetado para a próxima geração de agentes de IA. Ele encapsula documentos, embeddings de alta dimensão e conhecimento estruturado em um único arquivo portátil `.wax`.

Ao contrário das bases de dados tradicionais que exigem configurações complexas ou dependências na nuvem, o Wax fornece uma **camada de memória unificada** que reside inteiramente no dispositivo, aproveitando a inferência acelerada por Metal para uma latência de recuperação inferior a 10ms.

### Porquê o Wax?

| Recurso          | Wax                    | SQLite (FTS5)          | Vector DBs na Nuvem    |
|:-----------------|:-----------------------|:-----------------------|:-----------------------|
| **Busca**        | Híbrida (Texto + Vetor)| Apenas Texto*          | Apenas Vetor*          |
| **Latência**     | **~6ms (p95)**         | ~10ms (p95)            | 150ms - 500ms+         |
| **Privacidade**  | 100% Local             | 100% Local             | Hospedado na nuvem     |
| **Configuração** | Configuração Zero      | Baixa                  | Complexa (Chaves API)  |
| **Arquitetura**  | Nativo Apple Silicon   | Genérico               | Varia                  |

### 📦 Porquê um único arquivo `.wax`?
A maioria dos sistemas RAG exige uma base de dados, um armazenamento vetorial e um servidor de arquivos. O Wax agrupa tudo — documentos, metadados e índices de alta dimensão — em um único binário portátil.
*   **Infraestrutura Zero:** Sem Docker, sem configuração de BD, sem fatura de nuvem.
*   **Verdadeiramente Portátil:** Envie a memória do seu agente via AirDrop para outro Mac ou sincronize-a via iCloud.
*   **Atómico:** Um arquivo para backup, um arquivo para controle de versão, um arquivo para excluir.

---

## Desempenho

O Wax é otimizado para a arquitetura da série M, proporcionando recuperação quase instantânea, mesmo com índices locais de grande escala.

### Latência de recuperação (p95)
*Quanto menor, melhor. Medido em milissegundos.*

```text
Wax (Híbrido) |██ 6.1ms
SQLite (Texto) |████ 12ms
RAG na Nuvem  |██████████████████████████████████████████████████ 150ms+
```

### Tempo de abertura a frio (p95)
*Quanto menor, melhor. Medido em milissegundos.*

```text
Wax           |███ 9.2ms
Tradicional   |██████████████████████████████████████ 120ms+
```

> [!TIP]
> **Taxa de ingestão:** O Wax processa **85,9 docs/s** com indexação híbrida completa em um M3 Max.
> Relatório completo de benchmarks: [docs/benchmarks/2026-03-06-performance-results.md](../docs/benchmarks/2026-03-06-performance-results.md)

---

## Arquitetura

O Wax usa um modelo de **"Base de Dados de Bases de Dados"**. Ele gerencia seu próprio formato de armazenamento baseado em frames enquanto incorpora motores de busca especializados (SQLite FTS5 e HNSW acelerado por Metal) como blobs serializados dentro do arquivo principal.

### Layout Interno do Arquivo

```text
┌──────────────────────────────────────────────────────────────────────────┐
│                    Páginas de Cabeçalho Duplo (A/B)                      │
│ (Magic, Versão, Geração, Ponteiros para WAL e TOC, Checksums)            │
├──────────────────────────────────────────────────────────────────────────┤
│                          WAL (Write-Ahead Log)                           │
│ (Buffer circular atómico para mutações não confirmadas resilientes)      │
├──────────────────────────────────────────────────────────────────────────┤
│                        Frames de Dados Comprimidos                       │
│   ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐       │
│   │ Frame 0 (LZ4)    │  │ Frame 1 (LZ4)    │  │ Frame 2 (LZ4)    │ ...   │
│   │ [Doc Bruto]      │  │ [Metadados/JSON] │  │ [Info Sistema]   │       │
│   └──────────────────┘  └──────────────────┘  └──────────────────┘       │
├──────────────────────────────────────────────────────────────────────────┤
│                        Índices de Busca Híbrida                          │
│   ┌──────────────────────────────┐  ┌──────────────────────────────┐     │
│   │ Blob SQLite FTS5             │  │ Índice Metal HNSW            │     │
│   │ (Busca Texto + Fatos EAV)    │  │ (Busca Vetorial)             │     │
│   └──────────────────────────────┘  └──────────────────────────────┘     │
├──────────────────────────────────────────────────────────────────────────┤
│                        TOC (Tabela de Conteúdos)                         │
│ (Índice de todos os frames, relações pai-filho e manifestos do motor)    │
└──────────────────────────────────────────────────────────────────────────┘
```

1. **Resiliência Atómica**: Cabeçalhos duplos e WAL garantem que, mesmo que o processo falhe durante a escrita, o armazenamento permaneça consistente.
2. **Recuperação Unificada**: Uma única consulta dispara a execução paralela nos motores BM25 (texto) e HNSW (vetor).
3. **Conhecimento Estruturado**: Armazenamento EAV (Entidade-Atributo-Valor) integrado para fatos persistentes e raciocínio de longo prazo.

---

## Início Rápido

Copie e cole isto em um arquivo `main.swift` para começar imediatamente.

```swift
import Foundation
import Wax
import WaxVectorSearchMiniLM

@main
struct AgentMemory {
    static func main() async throws {
        let url = URL(fileURLWithPath: "agent.wax")

        // 1. Inicializar um armazenamento de memória (embeddings MiniLM no dispositivo)
        let memory = try await MemoryOrchestrator.openMiniLM(at: url)

        // 2. Registrar uma nova memória
        try await memory.remember("O utilizador está a construir um rastreador de hábitos em SwiftUI.")

        // 3. Realizar recuperação semântica
        let context = try await memory.recall(query: "O que é que o utilizador está a construir?")

        if let bestMatch = context.items.first {
            print("Recuperação: \(bestMatch.text)") 
            // Saída: "Recuperação: O utilizador está a construir um rastreador de hábitos em SwiftUI."
        }
    }
}
```

Deseja armazenar fatos persistentes e raciocínio de longo prazo? Veja [Memória Estruturada](../Sources/WaxCore/WaxCore.docc/Articles/StructuredMemory.md).

---

## Instalação

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/christopherkarani/Wax.git", from: "0.1.8")
]
```

---

## Ferramentas do Ecossistema

### 🤖 Servidor MCP
O Wax fornece um servidor **Model Context Protocol (MCP)** de primeira classe. Conecte sua memória local ao Claude Code ou a qualquer agente compatível com MCP.

```bash
npx -y waxmcp@latest mcp install --scope user
```

### 🔍 WaxRepo
Um TUI de busca semântica para o seu histórico do git. Indexe qualquer repositório e encontre código ou commits usando linguagem natural.

```bash
# De dentro de qualquer repositório git
wax-repo index
wax-repo search "onde é que implementámos o WAL?"
```

---

## Licença

Wax é lançado sob a Licença Apache 2.0. Consulte [LICENSE](../LICENSE) para mais detalhes.

<div align="center">
<sub>Construído para programadores que acreditam que os dados pertencem ao dispositivo do utilizador.</sub>
</div>
