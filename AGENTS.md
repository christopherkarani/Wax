# Wax Agent Instructions

## Public Repository Hygiene

This repository is the public, front-facing Wax source tree. Keep it limited to
source code, tests, release automation, product documentation, examples, and
public integration assets.

Do not commit or track:

- planning scratchpads, execution ledgers, remediation checklists, or task logs
- agent lessons, session notes, handoff notes, or private workflow rules
- marketing drafts for articles, social posts, launch copy, or prompt ideation
- screenshots, issue snapshots, browser captures, or temporary debugging images
- loose root-level analysis reports that are not part of the official docs
- customer, investor, pricing, launch, or unreleased product planning material

Use external/private notes for working plans. If a public plan is genuinely part
of the product documentation, place it under an official docs surface and make
sure it is written as user-facing documentation, not as an internal task list.

Before committing, run:

```bash
git ls-files | rg '(^tasks/|^marketing/|issue[0-9]+_|snapshot|screenshot|TECHNICAL_ANALYSIS|audit-.*ledger|lessons\.md|todo\.md)'
```

The command should return no matches unless the file is intentionally public and
has been reviewed as part of the docs or release surface.

## Change Discipline

- Keep changes scoped to the user request.
- Preserve unrelated local work and generated artifacts.
- Prefer tests or concrete verification for source changes.
- Do not stage build output, caches, screenshots, or local tool directories.
