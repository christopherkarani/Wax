#!/usr/bin/env bash
# SIGTERM must shut wax-cli's broker daemon down gracefully: exit 0 within the
# client's 2s SIGTERM grace and remove its socket. wax-mcp, given its path,
# must also exit 0 on SIGTERM (its graceful path) rather than die of the signal.
# Dispatch signal delivery differs by platform (kqueue on Darwin, signalfd on
# Linux), so CI runs this on Linux as well as macOS.
#
# Usage: daemon_sigterm_smoke.sh <path-to-wax-cli> [<path-to-wax-mcp>]
set -euo pipefail

WAX_CLI="${1:?usage: daemon_sigterm_smoke.sh <wax-cli> [<wax-mcp>]}"
WAX_MCP="${2:-}"
GRACE_SECONDS=2
HANG_SECONDS=30

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Short path: Unix socket paths are limited to about 104 bytes.
WORK_DIR="$(mktemp -d /tmp/wxsmoke.XXXXXX)"
PIDS=()
cleanup() {
  for pid in "${PIDS[@]}"; do
    kill -KILL "$pid" 2>/dev/null || true
  done
  pkill -KILL -f "daemon --store-path $WORK_DIR/" 2>/dev/null || true
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

alive() {
  kill -0 "$1" 2>/dev/null
}

# Sends SIGTERM to $1 and waits for it. Fails unless it exits 0 within $2
# seconds. A watchdog marks the deadline, so the bound is wall time from the kill.
terminate_and_expect_clean_exit() {
  local pid="$1" limit="$2" name="$3"
  local late_marker="$WORK_DIR/$name.late"
  kill -TERM "$pid"
  ( sleep "$limit"; if kill -0 "$pid" 2>/dev/null; then touch "$late_marker"; fi ) &
  local watchdog=$!

  local waited=0
  while alive "$pid" && [ "$waited" -lt $((HANG_SECONDS * 10)) ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  if alive "$pid"; then
    kill -KILL "$pid" 2>/dev/null || true
    fail "$name did not exit within ${HANG_SECONDS}s of SIGTERM"
  fi

  local status=0
  wait "$pid" || status=$?
  wait "$watchdog" || true
  [ "$status" -eq 0 ] || fail "$name exited with status $status after SIGTERM, expected 0"
  [ ! -e "$late_marker" ] || fail "$name was still running ${limit}s after SIGTERM"
}

wait_for_path() {
  local path="$1" pid="$2" name="$3"
  local waited=0
  while [ ! -e "$path" ]; do
    alive "$pid" || fail "$name exited before creating $path"
    [ "$waited" -lt $((HANG_SECONDS * 10)) ] || fail "$name never created $path"
    sleep 0.1
    waited=$((waited + 1))
  done
}

SOCKET="$WORK_DIR/d.sock"
"$WAX_CLI" daemon \
  --store-path "$WORK_DIR/daemon.wax" \
  --session-root "$WORK_DIR/sessions" \
  --no-embedder \
  --idle-timeout-secs 300 \
  --socket-path "$SOCKET" </dev/null >/dev/null 2>"$WORK_DIR/daemon.err" &
DAEMON_PID=$!
PIDS+=("$DAEMON_PID")
wait_for_path "$SOCKET" "$DAEMON_PID" "wax-cli daemon"
terminate_and_expect_clean_exit "$DAEMON_PID" "$GRACE_SECONDS" "wax-cli daemon"
[ ! -e "$SOCKET" ] || fail "wax-cli daemon left its socket at $SOCKET"
echo "daemon_sigterm_smoke: wax-cli daemon ok"

if [ -n "$WAX_MCP" ]; then
  # stdin stays open through a FIFO, so wax-mcp is idle, not at EOF, when signalled.
  FIFO="$WORK_DIR/mcp.in"
  mkfifo "$FIFO"
  exec 3<>"$FIFO"
  HOME="$WORK_DIR" "$WAX_MCP" \
    --store-path "$WORK_DIR/mcp.wax" \
    --session-root "$WORK_DIR/mcp-sessions" \
    --no-embedder <&3 >/dev/null 2>"$WORK_DIR/mcp.err" &
  MCP_PID=$!
  PIDS+=("$MCP_PID")
  waited=0
  until grep -q "starting" "$WORK_DIR/mcp.err" 2>/dev/null; do
    alive "$MCP_PID" || fail "wax-mcp exited before starting: $(cat "$WORK_DIR/mcp.err")"
    [ "$waited" -lt $((HANG_SECONDS * 10)) ] || fail "wax-mcp never started"
    sleep 0.1
    waited=$((waited + 1))
  done
  # wax-mcp checkpoints its session and stops its broker on the way out, so
  # only the hang bound applies; the status proves the graceful path ran.
  terminate_and_expect_clean_exit "$MCP_PID" "$HANG_SECONDS" "wax-mcp"
  exec 3>&-
  echo "daemon_sigterm_smoke: wax-mcp ok"
fi

echo "daemon_sigterm_smoke: ok"
