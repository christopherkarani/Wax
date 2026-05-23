# Deploying Wax for Hermes Agent Users

This guide covers how to publish and distribute Wax so Hermes Agent users can install and use it with minimal friction.

## Distribution Channels

| Channel | What | User Experience | Status |
|---|---|---|---|
| **npm** (`waxmcp`) | Pre-built binaries + launcher | `npx waxmcp --transport http` | ✅ Automated CI/CD |
| **GitHub** | Source + releases | Clone or download release | ✅ Available now |
| **Directory plugin** | Direct copy to `~/.hermes/plugins` | `cp -r wax-memory-plugin ~/.hermes/plugins/wax-memory` | ✅ Available now |
| **PyPI** (`hermes-wax-memory`) | Python package install | `pip install hermes-wax-memory` | 🚧 Needs setup |
| **Homebrew** | macOS package manager | `brew install wax` | 🚧 Needs formula update |

---

## 1. npm — Primary Distribution (Automated)

The `waxmcp` npm package bundles pre-built `wax-cli` and `wax-mcp` binaries for darwin-arm64 and darwin-x64.

### Current Release Pipeline

```
Git tag: waxmcp-v0.1.22
  → GitHub Actions builds binaries (darwin-x64, darwin-arm64)
  → Validates + publishes to npm
```

### Trigger a Release

```bash
# Option A: Bump version and release everything
scripts/release-all.sh patch    # or minor, major, or exact semver

# Follow the printed steps:
#   1. git diff --stat          (review)
#   2. git add -A && git commit -m "release: waxmcp v0.1.23"
#   3. git tag waxmcp-v0.1.23
#   4. git push origin main --tags

# Option B: Manual version bump
scripts/bump-version.sh 0.1.23
# Then commit, tag, and push
```

### What Gets Published

- `Resources/npm/waxmcp/` — npm package with:
  - `bin/waxmcp.js` — launcher script
  - `dist/darwin-arm64/` — arm64 binaries + resource bundles
  - `dist/darwin-x64/` — x64 binaries + resource bundles

### For Users

```bash
# Install globally
npm install -g waxmcp

# Or run without installing
npx waxmcp --transport http
```

---

## 2. Hermes Plugin — Three Install Methods

### Method A: Directory Plugin (Recommended for Development)

```bash
# From the Wax repo
cp -r Resources/hermes/wax-memory-plugin ~/.hermes/plugins/wax-memory

# Enable in Hermes config
hermes config set memory.provider wax-memory
```

### Method B: pip Install from GitHub

```bash
pip install "git+https://github.com/christopherkarani/Wax.git#subdirectory=Resources/hermes/wax-memory-plugin"
```

### Method C: PyPI (Future — Needs Setup)

```bash
# Publish to PyPI (one-time setup)
cd Resources/hermes/wax-memory-plugin
python -m build
twine upload dist/*

# User installs
pip install hermes-wax-memory
```

**To enable PyPI publishing:**

1. Create a PyPI account
2. Add `PYPI_TOKEN` to GitHub secrets
3. Add a GitHub Actions workflow (see example below)

```yaml
# .github/workflows/release-hermes-plugin.yml
name: Release Hermes Plugin
on:
  workflow_dispatch:
jobs:
  publish:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with: { python-version: "3.11" }
      - run: pip install build twine
      - run: cd Resources/hermes/wax-memory-plugin && python -m build
      - run: twine upload dist/*
        env:
          TWINE_USERNAME: __token__
          TWINE_PASSWORD: ${{ secrets.PYPI_TOKEN }}
```

---

## 3. Pre-built Binaries — What's Included

The `dist/` directory in the npm package contains:

```
dist/darwin-arm64/
├── wax-cli              ← Broker daemon
├── wax-cli.sha256
├── wax-mcp              ← MCP server
├── wax-mcp.sha256
├── Wax_WaxVectorSearchMiniLM.bundle
└── Wax_Wax.bundle
```

> **Vector search:** The release binaries include MiniLM embeddings by default (`--traits MCPServer` enables `MiniLMEmbeddings` by default). Arctic embeddings are NOT included in the default release build.

### Building with Arctic Embedders

For a release that includes BOTH MiniLM and Arctic:

```bash
# Build with both embedders
swift build --product wax-cli --traits "MiniLMEmbeddings,ArcticEmbeddings"
swift build --product wax-mcp --traits "MiniLMEmbeddings,ArcticEmbeddings,MCPServer"

# Copy to dist/
cp .build/debug/wax-cli Resources/npm/waxmcp/dist/darwin-arm64/
cp .build/debug/wax-mcp Resources/npm/waxmcp/dist/darwin-arm64/
```

---

## 4. Complete Deployment Checklist

### For a New Release

```bash
# 1. Bump version across all surfaces
scripts/bump-version.sh 0.1.23

# 2. Validate everything is in sync
scripts/validate-congruency.sh

# 3. Build release binaries
scripts/release-all.sh 0.1.23

# 4. Commit and tag
git add -A
git commit -m "release: waxmcp v0.1.23"
git tag waxmcp-v0.1.23
git push origin main --tags

# 5. GitHub Actions publishes to npm automatically
# 6. (Optional) Publish Hermes plugin to PyPI manually
```

### For Hermes Users (Post-Release)

```bash
# 1. Install Wax MCP
npm install -g waxmcp

# 2. Start the server
npx waxmcp --transport http

# 3. Install Hermes plugin
cp -r /path/to/Wax/Resources/hermes/wax-memory-plugin ~/.hermes/plugins/wax-memory

# 4. Enable
hermes config set memory.provider wax-memory

# 5. Run Hermes
hermes
```

---

## 5. Troubleshooting Deployments

### "Vector search is disabled"

The release binaries have MiniLM. If vector search is disabled, the broker (`wax-cli`) was likely started from a different binary path that lacks embedders.

**Fix:** Ensure `wax-mcp` uses the bundled `wax-cli` from the same `dist/` directory.

### "Plugin not found by Hermes"

Check that the plugin directory name matches the plugin name:
- Directory: `~/.hermes/plugins/wax-memory/`
- Plugin name in `plugin.yaml`: `name: wax-memory`

### "Version mismatch in release"

Run the validator:
```bash
scripts/validate-congruency.sh
# Shows exactly which surface is out of sync
```

---

## 6. Future Improvements

- [ ] **Homebrew formula** — `brew install wax` for one-command install
- [ ] **PyPI auto-publish** — GitHub Actions workflow for `hermes-wax-memory`
- [ ] **Linux binaries** — Build and distribute for Linux (blocked by CoreML dependency)
- [ ] **Docker image** — Containerized Wax MCP for server deployments
