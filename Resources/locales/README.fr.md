<!-- HEADER:START -->
<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="../docs/assets/banner-dark.svg">
    <img src="../docs/assets/banner-light.svg" width="800" alt="Wax Banner">
  </picture>
</div>

<div style="height: 16px;"></div>

<p align="center">
  <strong>Wax est une couche de mémoire haute performance en un seul fichier pour les agents IA sur les plateformes Apple.</strong><br/>
  Sur l'appareil, privé et portable. Pas de serveur et pas de dépendance au cloud.
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

## Qu'est-ce que Wax ?

Wax est un moteur de persistance natif en Swift conçu pour la prochaine génération d'agents IA. Il encapsule des documents, des embeddings de haute dimension et des connaissances structurées dans un seul fichier portable `.wax`.

Contrairement aux bases de données traditionnelles qui nécessitent des configurations complexes ou des dépendances cloud, Wax fournit une **couche de mémoire unifiée** qui réside entièrement sur l'appareil, exploitant l'inférence accélérée par Metal pour une latence de rappel inférieure à 10ms.

### Pourquoi Wax ?

| Fonctionnalité   | Wax                    | SQLite (FTS5)          | Vector DBs Cloud       |
|:-----------------|:-----------------------|:-----------------------|:-----------------------|
| **Recherche**    | Hybride (Texte + Vect) | Texte Uniquement*      | Vecteur Uniquement*    |
| **Latence**      | **~6ms (p95)**         | ~10ms (p95)            | 150ms - 500ms+         |
| **Confidentialité** | 100% Local          | 100% Local             | Hébergé sur le Cloud   |
| **Configuration** | Zéro Config           | Faible                 | Complexe (Clés API)    |
| **Architecture** | Apple Silicon Native   | Générique              | Varie                  |

### 📦 Pourquoi un seul fichier `.wax` ?
La plupart des systèmes RAG nécessitent une base de données, un stockage vectoriel et un serveur de fichiers. Wax regroupe documents, métadonnées et indices de haute dimension dans un seul binaire portable.
*   **Zéro Infrastructure :** Pas de Docker, pas de configuration de base de données, pas de facture cloud.
*   **Vraiment Portable :** Envoyez la mémoire de votre agent par AirDrop vers un autre Mac, ou synchronisez-la via iCloud.
*   **Atomique :** Un seul fichier à sauvegarder, un seul fichier pour le contrôle de version, un seul fichier à supprimer.

---

## Performance

Wax est optimisé pour l'architecture de la série M, offrant un rappel quasi instantané même avec des indices locaux à grande échelle.

### Latence de rappel (p95)
*Plus c'est bas, mieux c'est. Mesuré en millisecondes.*

```text
Wax (Hybride) |██ 6.1ms
SQLite (Texte) |████ 12ms
Cloud RAG     |██████████████████████████████████████████████████ 150ms+
```

### Temps d'ouverture à froid (p95)
*Plus c'est bas, mieux c'est. Mesuré en millisecondes.*

```text
Wax           |███ 9.2ms
Traditionnel  |██████████████████████████████████████ 120ms+
```

> [!TIP]
> **Débit d'ingestion :** Wax traite **85,9 docs/s** avec une indexation hybride complète sur un M3 Max.
> Rapport de benchmark complet : [docs/benchmarks/2026-03-06-performance-results.md](../docs/benchmarks/2026-03-06-performance-results.md)

---

## Architecture

Wax utilise un modèle de **"Base de données de bases de données"**. Il gère son propre format de stockage basé sur des trames tout en intégrant des moteurs de recherche spécialisés (SQLite FTS5 et HNSW accéléré par Metal) sous forme de blobs sérialisés dans le fichier principal.

### Disposition interne du fichier

```text
┌──────────────────────────────────────────────────────────────────────────┐
│                      Pages d'en-tête doubles (A/B)                       │
│ (Magic, Version, Génération, Pointeurs vers WAL & TOC, Checksums)        │
├──────────────────────────────────────────────────────────────────────────┤
│                          WAL (Write-Ahead Log)                           │
│ (Buffer circulaire atomique pour les mutations non validées résilientes) │
├──────────────────────────────────────────────────────────────────────────┤
│                         Trames de données compressées                    │
│   ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐       │
│   │ Trame 0 (LZ4)    │  │ Trame 1 (LZ4)    │  │ Trame 2 (LZ4)    │ ...   │
│   │ [Doc brut]       │  │ [Métadonnées]    │  │ [Infos système]  │       │
│   └──────────────────┘  └──────────────────┘  └──────────────────┘       │
├──────────────────────────────────────────────────────────────────────────┤
│                        Indices de recherche hybrides                     │
│   ┌──────────────────────────────┐  ┌──────────────────────────────┐     │
│   │ Blob SQLite FTS5             │  │ Indice Metal HNSW            │     │
│   │ (Recherche texte + Faits EAV)│  │ (Recherche vectorielle)      │     │
│   └──────────────────────────────┘  └──────────────────────────────┘     │
├──────────────────────────────────────────────────────────────────────────┤
│                          TOC (Table des matières)                        │
│ (Index de toutes les trames, relations parent-enfant, manifestes moteur) │
└──────────────────────────────────────────────────────────────────────────┘
```

1. **Résilience atomique** : Les doubles en-têtes et le WAL garantissent que même si le processus plante en pleine écriture, le magasin reste cohérent.
2. **Récupération unifiée** : Une seule requête déclenche une exécution parallèle sur les moteurs BM25 (texte) et HNSW (vecteur).
3. **Connaissances structurées** : Stockage EAV (Entité-Attribut-Valeur) intégré pour les faits persistants et le raisonnement à long terme.

---

## Démarrage rapide

```swift
import Wax

// Utiliser un emplacement accessible en écriture (fonctionne dans les apps et les outils CLI)
let url = URL.documentsDirectory.appending(path: "agent.wax")

// 1. Ouvrir un magasin de mémoire
let memory = try await Memory(at: url)

// 2. Sauvegarder une mémoire
try await memory.save("L'utilisateur construit un suivi d'habitudes en SwiftUI.")

// 3. Rechercher avec rappel hybride (texte + vecteur)
let results = try await memory.search("Qu'est-ce que l'utilisateur construit ?")

if let best = results.items.first {
    print("Trouvé : \(best.text)")
    // → "Trouvé : L'utilisateur construit un suivi d'habitudes en SwiftUI."
}

try await memory.close()
```

<details>
<summary><strong>Exemple SwiftUI</strong></summary>

```swift
import SwiftUI
import Wax

struct ContentView: View {
    @State private var result = "Recherche…"

    var body: some View {
        Text(result)
            .task {
                do {
                    let url = URL.documentsDirectory.appending(path: "agent.wax")
                    let memory = try await Memory(at: url)

                    try await memory.save("L'utilisateur construit un suivi d'habitudes en SwiftUI.")
                    let context = try await memory.search("Qu'est-ce que l'utilisateur construit ?")

                    result = context.items.first?.text ?? "Rien trouvé"
                    try await memory.close()
                } catch {
                    result = "Erreur : \(error.localizedDescription)"
                }
            }
    }
}
```

</details>

<details>
<summary><strong>Outil CLI (main.swift)</strong></summary>

```swift
import Wax

@main
struct AgentMemory {
    static func main() async throws {
        let url = URL.documentsDirectory.appending(path: "agent.wax")
        let memory = try await Memory(at: url)

        try await memory.save("L'utilisateur construit un suivi d'habitudes en SwiftUI.")

        let results = try await memory.search("Qu'est-ce que l'utilisateur construit ?")
        if let best = results.items.first {
            print("Trouvé : \(best.text)")
        }

        try await memory.close()
    }
}
```

</details>

Vous cherchez à stocker des faits persistants et un raisonnement à long terme ? Voir [Mémoire structurée](../Sources/WaxCore/WaxCore.docc/Articles/StructuredMemory.md).

---

## Installation

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/christopherkarani/Wax.git", from: "0.1.8")
]
```

---

## Outils de l'écosystème

### 🤖 Serveur MCP
Wax fournit un serveur **Model Context Protocol (MCP)** de premier ordre. Connectez votre mémoire locale à Claude Code ou à tout agent compatible MCP.

```bash
npx -y waxmcp@latest mcp install --scope user
```

### 🔍 WaxRepo
Un TUI de recherche sémantique pour votre historique git. Indexez n'importe quel dépôt et trouvez du code ou des commits en utilisant le langage naturel.

```bash
# Depuis n'importe quel dépôt git
wax-repo index
wax-repo search "où avons-nous implémenté le WAL ?"
```

---

## Licence

Wax est publié sous la licence Apache 2.0. Voir [LICENSE](../LICENSE) pour plus de détails.

<div align="center">
<sub>Conçu pour les développeurs qui croient que les données utilisateur appartiennent à l'appareil de l'utilisateur.</sub>
</div>
