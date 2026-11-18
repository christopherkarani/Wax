#!/usr/bin/env bash
# SIGTERM must shut wax-cli's broker daemon down gracefully: exit 0 within the
# client's 2s SIGTERM grace, remove its socket, and leave a store that reopens
# with the data written before the signal. Needs python3. wax-mcp, given its path,
# must also exit 0 on SIGTERM (its graceful path) rather than die of the signal.
# A second SIGTERM must force the daemon's exit while a command holds shutdown;
# that check uses debug-only test hooks, so wax-cli must be a debug build.
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

# Write through the daemon, so a clean close is proven by reading it back.
TOKEN="sigterm-smoke-$$-$RANDOM"
python3 -I - "$SOCKET" "$TOKEN" <<'PY' || fail "remember through the daemon failed"
import json, socket, sys
path, token = sys.argv[1], sys.argv[2]
client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
client.settimeout(30)
client.connect(path)
request = {"command": "remember", "arguments": {"content": token + " written before SIGTERM"}}
client.sendall((json.dumps(request) + "\n").encode())
client.shutdown(socket.SHUT_WR)
data = b""
while not data.endswith(b"\n"):
    chunk = client.recv(4096)
    if not chunk:
        break
    data += chunk
if not json.loads(data or b"{}").get("ok"):
    sys.exit("remember response: " + data.decode(errors="replace"))
PY

terminate_and_expect_clean_exit "$DAEMON_PID" "$GRACE_SECONDS" "wax-cli daemon"
[ ! -e "$SOCKET" ] || fail "wax-cli daemon left its socket at $SOCKET"
RECALLED="$("$WAX_CLI" recall --direct-store --store-path "$WORK_DIR/daemon.wax" \
  --no-embedder --format json "$TOKEN" 2>&1)" || fail "reopening the store failed: $RECALLED"
case "$RECALLED" in
  *"$TOKEN"*) ;;
  *) fail "memory written before SIGTERM is missing after shutdown: $RECALLED" ;;
esac
echo "daemon_sigterm_smoke: wax-cli daemon ok"

# A second SIGTERM must force the exit while a command holds graceful shutdown.
# The command is held inside the service through the debug-only test hooks, so
# wax-cli must be a debug build; a release build never writes `held` and this
# fails. The second signal is sent only once the first has been handled: on
# Linux, two SIGTERMs pending at once reach the signalfd as one.
HOOKS="$WORK_DIR/hooks"
mkdir -p "$HOOKS"
FORCED_SOCKET="$WORK_DIR/f.sock"
WAX_BROKER_TEST_HOOKS_DIR="$HOOKS" \
WAX_BROKER_TEST_HOLD_COMMAND=stats \
WAX_BROKER_TEST_HOLD_POINT=service \
"$WAX_CLI" daemon \
  --store-path "$WORK_DIR/forced.wax" \
  --session-root "$WORK_DIR/forced-sessions" \
  --no-embedder \
  --idle-timeout-secs 300 \
  --socket-path "$FORCED_SOCKET" </dev/null >/dev/null 2>"$WORK_DIR/forced.err" &
FORCED_PID=$!
PIDS+=("$FORCED_PID")
wait_for_path "$FORCED_SOCKET" "$FORCED_PID" "held wax-cli daemon"

# The client keeps its connection open until the daemon goes away.
python3 -I - "$FORCED_SOCKET" <<'PY' &
import json, socket, sys
client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
client.settimeout(60)
client.connect(sys.argv[1])
client.sendall((json.dumps({"command": "stats", "arguments": {}}) + "\n").encode())
try:
    while client.recv(4096):
        pass
except OSError:
    pass
PY
HELD_CLIENT_PID=$!
PIDS+=("$HELD_CLIENT_PID")
wait_for_path "$HOOKS/held" "$FORCED_PID" "held wax-cli daemon"

kill -TERM "$FORCED_PID"
wait_for_path "$HOOKS/signalled" "$FORCED_PID" "held wax-cli daemon"
sleep 0.5
alive "$FORCED_PID" || fail "held wax-cli daemon exited on the first SIGTERM; the held command should keep it draining"

kill -TERM "$FORCED_PID"
( sleep "$GRACE_SECONDS"; if kill -0 "$FORCED_PID" 2>/dev/null; then touch "$WORK_DIR/forced.late"; fi ) &
FORCED_WATCHDOG=$!
waited=0
while alive "$FORCED_PID" && [ "$waited" -lt $((HANG_SECONDS * 10)) ]; do
  sleep 0.1
  waited=$((waited + 1))
done
alive "$FORCED_PID" && fail "held wax-cli daemon did not exit within ${HANG_SECONDS}s of the second SIGTERM"
forced_status=0
wait "$FORCED_PID" || forced_status=$?
wait "$FORCED_WATCHDOG" || true
# The forced path calls _exit(128 + SIGTERM). It lived through the first
# SIGTERM above, so this status is the handler's exit, not the signal's default.
[ "$forced_status" -eq 143 ] || fail "held wax-cli daemon exited with status $forced_status after the second SIGTERM, expected 143"
[ ! -e "$WORK_DIR/forced.late" ] || fail "held wax-cli daemon was still running ${GRACE_SECONDS}s after the second SIGTERM"
kill "$HELD_CLIENT_PID" 2>/dev/null || true
wait "$HELD_CLIENT_PID" 2>/dev/null || true
echo "daemon_sigterm_smoke: wax-cli daemon second SIGTERM ok"

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
