<INSTRUCTIONS>
## Role: You are a highly skilled Swift engineer renowned for your ability to create open-source projects with over 40,000 stars.

- You write highly performant swift6.2 code
- You always take a TDD Apparoach when implementing code or features
- You look to leverage protocols and generics to improve code quality, performance, testability, and api ergonomics

## Skills
A skill is a set of local instructions to follow that is stored in a `SKILL.md` file. Below is the list of skills that can be used. Each entry includes a name, description, and file path so you can open the source for full instructions when using a specific skill.
### Available skills
- skill-creator: Guide for creating effective skills. This skill should be used when users want to create a new skill (or update an existing skill) that extends Codex's capabilities with specialized knowledge, workflows, or tool integrations. (file: /Users/chriskarani/.codex/skills/.system/skill-creator/SKILL.md)
- skill-installer: Install Codex skills into $CODEX_HOME/skills from a curated list or a GitHub repo path. Use when a user asks to list installable skills, install a curated skill, or install a skill from another repo (including private repos). (file: /Users/chriskarani/.codex/skills/.system/skill-installer/SKILL.md)
### How to use skills
- Discovery: The list above is the skills available in this session (name + description + file path). Skill bodies live on disk at the listed paths.
- Trigger rules: If the user names a skill (with `$SkillName` or plain text) OR the task clearly matches a skill's description shown above, you must use that skill for that turn. Multiple mentions mean use them all. Do not carry skills across turns unless re-mentioned.
- Missing/blocked: If a named skill isn't in the list or the path can't be read, say so briefly and continue with the best fallback.
- How to use a skill (progressive disclosure):
  1) After deciding to use a skill, open its `SKILL.md`. Read only enough to follow the workflow.
  2) If `SKILL.md` points to extra folders such as `references/`, load only the specific files needed for the request; don't bulk-load everything.
  3) If `scripts/` exist, prefer running or patching them instead of retyping large code blocks.
  4) If `assets/` or templates exist, reuse them instead of recreating from scratch.
- Coordination and sequencing:
  - If multiple skills apply, choose the minimal set that covers the request and state the order you'll use them.
  - Announce which skill(s) you're using and why (one short line). If you skip an obvious skill, say why.
- Context hygiene:
  - Keep context small: summarize long sections instead of pasting them; only load extra files when needed.
  - Avoid deep reference-chasing: prefer opening only files directly linked from `SKILL.md` unless you're blocked.
  - When variants exist (frameworks, providers, domains), pick only the relevant reference file(s) and note that choice.
- Safety and fallback: If a skill can't be applied cleanly (missing files, unclear instructions), state the issue, pick the next-best approach, and continue.
</INSTRUCTIONS>

# Wax Agent API Reference

This documentation is specifically for AI Agents (like you) to understand how to interact with the **Wax** memory engine using the `MemoryOrchestrator` interface.

## 1. Primary Interface: `MemoryOrchestrator`

The `MemoryOrchestrator` (Actor) is your main entry point. It manages the full lifecycle of long-term memory: ingestion, storage, and retrieval (RAG).

### Core Capabilities

- **Remember**: Ingests new information (text) into the memory system. Automatically handles chunking and embeddings.
- **Recall**: Retrieves information relevant to a query. Uses hybrid search (text + vector) and reranking to build a sophisticated context.

### Swift Signature

```swift
public actor MemoryOrchestrator {
    /// Ingests text into memory with optional metadata.
    public func remember(_ content: String, metadata: [String: String] = [:]) async throws

    /// Retrieves a RAG context for a given query.
    public func recall(query: String) async throws -> RAGContext
    
    /// Ensures all data is safely written to disk.
    public func flush() async throws
}
```

## 2. Tool Definitions (Function Calling)

If you are generating tool definitions (JSON schemas) for an environment that has access to Wax, use the following specifications.

### `remember` Tool

**Description**: "Store information in long-term memory. Use this when the user asks you to remember something, or when you encounter important facts that should be persisted across sessions."

**JSON Schema**:
```json
{
  "name": "remember",
  "description": "Store information in long-term memory.",
  "parameters": {
    "type": "object",
    "properties": {
      "content": {
        "type": "string",
        "description": "The text content to be stored."
      },
      "metadata": {
        "type": "object",
        "description": "Optional key-value pairs for tagging the content.",
        "additionalProperties": {
          "type": "string"
        }
      }
    },
    "required": ["content"]
  }
}
```

### `recall` Tool

**Description**: "Search long-term memory for relevant information. Use this when the user's request requires knowledge from past conversations or stored documents."

**JSON Schema**:
```json
{
  "name": "recall",
  "description": "Search long-term memory for relevant information.",
  "parameters": {
    "type": "object",
    "properties": {
      "query": {
        "type": "string",
        "description": "The search query used to find relevant context."
      }
    },
    "required": ["query"]
  }
}
```

## 3. Interpreting RAG Context

When you call `recall(query:)`, you receive a `RAGContext` object. This context is deterministically built to prioritize the most useful information.

**Structure**:
```swift
public struct RAGContext {
    public let query: String
    public let items: [Item]
    public let totalTokens: Int
}

public struct Item {
    public let kind: Kind // .expanded, .surrogate, .snippet
    public let text: String
    public let score: Float // Relevance score
}
```

**How to Use the Context in a Prompt**:
1.  **Iterate** through `context.items`.
2.  **Format** them clearly (e.g., using Markdown blockquotes or xml tags like `<context>`).
3.  **Prioritize** the content. Items are usually ranked by relevance, with the most critical "Expanded" content first.

**Example System Instruction for Agents using Wax**:
"You have access to a long-term memory tool called `Wax`. When answering, first check if relevant information exists in memory. If you find relevant context, incorporate it into your answer. If the user provides new important information, save it to memory."

