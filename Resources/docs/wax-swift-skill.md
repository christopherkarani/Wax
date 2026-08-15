# Wax Skill (Apple Apps)

Agent skill for **adding [Wax](https://github.com/christopherkarani/Wax) on-device memory** to iOS, iPadOS, and macOS apps.

Published as a dedicated repo so coding agents can install it without cloning the full Wax monorepo:

**https://github.com/christopherkarani/wax-skill**

Works with agents that support the [Agent Skills](https://agentskills.io/) format — including **Claude Code**, **Cursor**, **Codex**, and others.

This skill teaches agents how to:

- Add the Wax Swift package via SPM / Xcode
- Use the public `Memory` facade (`save` / `search` / `flush` / `close`)
- Configure embeddings (built-in MiniLM or custom `EmbeddingProvider`)
- Choose retrieval modes and verify what actually ran
- Avoid package-only internals that apps cannot import

> **Not** the MCP operator skill. If you want your coding agent itself to remember across sessions via Wax MCP tools (`remember`, `recall`, `handoff`), use the [`wax-mcp`](https://github.com/christopherkarani/Wax/tree/main/Resources/skills/public/wax-mcp) skill instead.

## Install

### One command (recommended)

```bash
npx skills add christopherkarani/wax-skill
```

This detects installed agents and copies the skill into the right directories (Cursor, Claude Code, Codex, etc.).

### Claude Code

```bash
claude install-skill https://github.com/christopherkarani/wax-skill/tree/main/skills/wax
```

### Manual install

Clone or copy `skills/wax` into your agent’s skills directory:

| Agent | Global path | Project path |
|-------|-------------|--------------|
| Claude Code | `~/.claude/skills/wax` | `.claude/skills/wax` |
| Cursor | `~/.cursor/skills/wax` | `.cursor/skills/wax` |
| Codex | `~/.agents/skills/wax` | `.agents/skills/wax` |

```bash
git clone https://github.com/christopherkarani/wax-skill.git /tmp/wax-skill
cp -R /tmp/wax-skill/skills/wax ~/.cursor/skills/wax   # Cursor example
```

## Usage

Once installed, ask your agent something like:

```text
Add Wax on-device memory to this iOS app so chat history persists across launches.
```

```text
Wire hybrid search with the built-in MiniLM embedder in our macOS SwiftUI target.
```

The agent should load this skill and follow the public `Memory` API — not package-only types.

## Skill layout

```text
skills/
  wax/
    SKILL.md              # Agent instructions
    agents/openai.yaml    # Host display metadata
    references/           # Public API + constraints
    templates/            # Copy-ready Swift skeletons
```

## Maintaining this skill

| Role | Location |
|------|----------|
| Source of truth | [`Resources/skills/public/wax`](https://github.com/christopherkarani/Wax/tree/main/Resources/skills/public/wax) in the Wax monorepo |
| Install / distribution repo | [`christopherkarani/wax-skill`](https://github.com/christopherkarani/wax-skill) |
| Publish | `Resources/scripts/publish-wax-skill.sh` |

```bash
# Preview
Resources/scripts/publish-wax-skill.sh --dry-run

# Push latest skill content to christopherkarani/wax-skill
Resources/scripts/publish-wax-skill.sh
```

## License

Apache-2.0 — same as [Wax](https://github.com/christopherkarani/Wax).
