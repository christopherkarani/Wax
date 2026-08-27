#!/usr/bin/env bash
# Product-owned Wax MCP HTTP LaunchAgent wrapper.
# Runtime binary is the waxmcp darwin-arm64 install, not Homebrew waxmcp.
set -euo pipefail

export WAX_MCP_FEATURE_LICENSE="${WAX_MCP_FEATURE_LICENSE:-0}"
export WAX_EMBEDDER_ALLOW_LOW_PRECISION_GPU="${WAX_EMBEDDER_ALLOW_LOW_PRECISION_GPU:-1}"
export WAX_EMBEDDER_BATCH_SIZE="${WAX_EMBEDDER_BATCH_SIZE:-1}"
export WAX_EMBEDDER_PREWARM_BATCH_SIZE="${WAX_EMBEDDER_PREWARM_BATCH_SIZE:-1}"
export WAX_EMBEDDER_TIMEOUT_SECS="${WAX_EMBEDDER_TIMEOUT_SECS:-120.0}"
export WAX_EMBEDDER_COMPUTE_UNITS="${WAX_EMBEDDER_COMPUTE_UNITS:-cpuAndNeuralEngine,cpuOnly,cpuAndGPU,all}"

BIN="${WAX_MCP_BIN:-$HOME/.local/share/waxmcp/runtime/darwin-arm64/wax-mcp}"
STORE="${WAX_STORE_PATH:-$HOME/.wax/memory.wax}"

if [[ ! -x "$BIN" ]]; then
  echo "start-wax-mcp-http: BIN is not executable: $BIN" >&2
  exit 1
fi

if [[ ! -e "$STORE" ]]; then
  echo "start-wax-mcp-http: STORE is missing: $STORE" >&2
  exit 1
fi

if command -v lsof >/dev/null 2>&1; then
  holder="$(lsof -nP -iTCP:3000 -sTCP:LISTEN -t 2>/dev/null | head -n1 || true)"
  if [[ -n "${holder}" ]]; then
    echo "start-wax-mcp-http: port 3000 already held by pid $holder; not killing" >&2
    exit 1
  fi
fi

exec "$BIN" \
  --store-path "$STORE" \
  --embedder minilm \
  --transport http \
  --http-host 127.0.0.1 \
  --http-port 3000 \
  --http-endpoint /mcp
