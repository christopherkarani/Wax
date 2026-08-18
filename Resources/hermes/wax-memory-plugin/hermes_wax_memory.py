"""Wax Memory Plugin — native Hermes MemoryProvider backed by Wax MCP."""

from __future__ import annotations

import json
import logging
import os
import re
import subprocess
import threading
import time
from concurrent.futures import Future, ThreadPoolExecutor, wait
from dataclasses import dataclass
from itertools import count
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional
from urllib.parse import urlparse

try:
    from wax_memory_schemas import (
        CORE_TOOL_NAMES,
        EXTENDED_TOOL_NAMES,
        STRUCTURED_TOOL_NAMES,
        TOOL_SCHEMAS as _TOOL_SCHEMAS,
        TOOLS_WITH_SESSION_ID,
        WAX_MEMORY_TYPES,
    )
except ImportError:  # directory plugin loaded as a package
    from .wax_memory_schemas import (
        CORE_TOOL_NAMES,
        EXTENDED_TOOL_NAMES,
        STRUCTURED_TOOL_NAMES,
        TOOL_SCHEMAS as _TOOL_SCHEMAS,
        TOOLS_WITH_SESSION_ID,
        WAX_MEMORY_TYPES,
    )

logger = logging.getLogger(__name__)

PLUGIN_VERSION = "0.1.26"
DEFAULT_ENDPOINT = "http://127.0.0.1:3000/mcp"
CONFIG_FILENAME = "wax-memory.json"
MCP_PROTOCOL_VERSION = "2024-11-05"

try:
    from agent.memory_provider import MemoryProvider, RecallStatus, is_trivial_prompt
except ImportError:
    @dataclass(frozen=True)
    class RecallStatus:
        provider_label: str
        count: int
        glyph: str = "🧠"

    _TRIVIAL_PROMPT_RE = re.compile(
        r"^(yes|no|ok|okay|sure|thanks|thank you|y|n|yep|nope|yeah|nah|"
        r"hi|hey|hello|yo|sup|"
        r"continue|go ahead|do it|proceed|got it|cool|nice|great|done|next|lgtm|k)"
        r"""[\s!?.:;,\"'~\u2018\u2019\u201c\u201d\u2014\u2013\u2026()\[\]{}<>*&^%$#@!+=`\u00a0]*$""",
        re.IGNORECASE,
    )

    def is_trivial_prompt(text: Optional[str]) -> bool:
        if not text or not text.strip():
            return True
        stripped = text.strip()
        if stripped.startswith("/"):
            return True
        return bool(_TRIVIAL_PROMPT_RE.match(stripped))

    class MemoryProvider:
        """Stand-in when Hermes is not installed (unit tests / standalone)."""


try:
    import requests
    _HAS_HTTP = True
except ImportError:
    requests = None  # type: ignore[assignment]
    _HAS_HTTP = False

_INTERNAL_GATEWAY_TURN_RE = re.compile(
    r"^\s*(?:"
    r"\[ASYNC (?:DELEGATION )?(?:BATCH )?COMPLETE[^\]]*\]|"
    r"\[CONTEXT COMPACTION[^\]]*\]|"
    r"\[CONTEXT SUMMARY\]:?|"
    r"\[PRIOR CONTEXT[^\]]*\]|"
    r"\[Your active task list was preserved across context compression\]|"
    r"\[IMPORTANT: Background process \d+ matched watch pattern[^\n]*|"
    r"A background fan-out of \d+ subagent\(s\) you dispatched earlier has finished\.|"
    r"A background subagent you dispatched earlier has finished\."
    r")",
    re.IGNORECASE,
)


def _is_internal_gateway_turn(text: str) -> bool:
    return bool(_INTERNAL_GATEWAY_TURN_RE.match(text or ""))


def _truthy(value: Any, default: bool = False) -> bool:
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    return str(value).strip().lower() in {"1", "true", "yes", "on"}


def load_plugin_config(hermes_home: Optional[str] = None) -> Dict[str, Any]:
    config: Dict[str, Any] = {}
    home = hermes_home or os.environ.get("HERMES_HOME") or str(Path.home() / ".hermes")
    path = Path(home) / CONFIG_FILENAME
    if path.is_file():
        try:
            loaded = json.loads(path.read_text(encoding="utf-8"))
            if isinstance(loaded, dict):
                config.update(loaded)
        except Exception as exc:
            logger.debug("Wax config load failed: %s", exc)
    return config


def resolve_endpoint(config: Optional[Dict[str, Any]] = None) -> str:
    if env := os.environ.get("WAX_MCP_HTTP_ENDPOINT"):
        return env.rstrip("/")
    if config and isinstance(config.get("endpoint"), str) and config["endpoint"].strip():
        return config["endpoint"].rstrip("/")
    return DEFAULT_ENDPOINT


def _jsonrpc_error_message(data: Dict[str, Any]) -> str:
    error = data.get("error")
    if isinstance(error, dict):
        return str(error.get("message") or "Unknown MCP error")
    return "Unknown MCP error"


class WaxMCPError(Exception):
    """Raised when the Wax MCP server returns an error."""


class _WaxHTTPClient:
    """Stateful HTTP client for Wax MCP streamable HTTP / SSE transport."""

    def __init__(self, endpoint: str) -> None:
        self.endpoint = endpoint
        self._session_id: Optional[str] = None
        self._initialized = False
        self._ids = count(1)
        self._lock = threading.Lock()

    def _next_id(self) -> int:
        return next(self._ids)

    def _headers(self, include_session: bool = True) -> Dict[str, str]:
        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        }
        if include_session and self._session_id:
            headers["MCP-Session-Id"] = self._session_id
        return headers

    def _parse_sse_or_json(self, body: str) -> Dict[str, Any]:
        for line in body.splitlines():
            if line.startswith("data: "):
                data_str = line[6:]
                if data_str.strip():
                    return json.loads(data_str)
        if body.strip():
            return json.loads(body)
        raise WaxMCPError("Empty MCP response")

    def _post(self, payload: Dict[str, Any], timeout: float, expect_body: bool = True) -> Dict[str, Any]:
        if not _HAS_HTTP:
            raise WaxMCPError("Install the requests package (pip install requests>=2.28)")
        headers = self._headers()
        with requests.post(
            self.endpoint, json=payload, headers=headers, timeout=timeout,
        ) as resp:
            resp.raise_for_status()
            session = resp.headers.get("Mcp-Session-Id") or resp.headers.get("mcp-session-id")
            if session:
                self._session_id = session
            if not expect_body:
                return {}
            return self._parse_sse_or_json(resp.text or "")

    def _ensure_initialized(self) -> None:
        if self._initialized:
            return
        payload = {
            "jsonrpc": "2.0",
            "id": self._next_id(),
            "method": "initialize",
            "params": {
                "protocolVersion": MCP_PROTOCOL_VERSION,
                "capabilities": {},
                "clientInfo": {"name": "hermes-wax-memory", "version": PLUGIN_VERSION},
            },
        }
        data = self._post(payload, timeout=30.0)
        if "error" in data:
            raise WaxMCPError(_jsonrpc_error_message(data))
        try:
            self._post(
                {"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}},
                timeout=10.0,
                expect_body=False,
            )
        except Exception as exc:
            logger.debug("Wax initialized notification skipped: %s", exc)
        self._initialized = True
        logger.debug("Wax HTTP session initialized: %s", self._session_id)

    def call_tool(self, tool_name: str, arguments: Dict[str, Any]) -> Dict[str, Any]:
        with self._lock:
            self._ensure_initialized()
            payload = {
                "jsonrpc": "2.0",
                "id": self._next_id(),
                "method": "tools/call",
                "params": {"name": tool_name, "arguments": arguments},
            }
            data = self._post(payload, timeout=30.0)
        if "error" in data:
            raise WaxMCPError(_jsonrpc_error_message(data))
        result = data.get("result", {})
        content = result.get("content", [])
        text_parts = [
            block["text"] for block in content
            if isinstance(block, dict) and block.get("type") == "text" and "text" in block
        ]
        return {
            "ok": not result.get("isError", False),
            "text": "\n".join(text_parts) if text_parts else "",
            "raw": result,
        }

    def close(self) -> None:
        with self._lock:
            if self._session_id and _HAS_HTTP:
                try:
                    requests.delete(
                        self.endpoint,
                        headers={"MCP-Session-Id": self._session_id},
                        timeout=10.0,
                    )
                except Exception as exc:
                    logger.debug("Wax HTTP session close failed: %s", exc)
            self._session_id = None
            self._initialized = False


class _WaxMCPManager:
    def __init__(self, endpoint: str) -> None:
        self.endpoint = endpoint
        self._auto_started = False
        self._process: Optional[subprocess.Popen] = None

    def probe(self) -> Dict[str, Any]:
        try:
            client = _WaxHTTPClient(self.endpoint)
            result = client.call_tool("stats", {})
            client.close()
            if result["ok"] and result["text"]:
                stats = json.loads(result["text"])
                return {
                    "reachable": True,
                    "vector_search_enabled": stats.get("vectorSearchEnabled", False),
                    "query_embedding_available": stats.get("queryEmbeddingAvailable", False),
                    "embedder": stats.get("embedder"),
                    "frame_count": stats.get("frameCount", 0),
                }
        except Exception as exc:
            logger.debug("Wax MCP probe failed: %s", exc)
        return {"reachable": False}

    def auto_start(self, timeout: float = 10.0) -> bool:
        if self.probe().get("reachable"):
            return False
        binary = self._find_wax_mcp_binary()
        if not binary:
            logger.warning(
                "Wax MCP binary not found. Install with: npx waxmcp install --build"
            )
            return False
        parsed = urlparse(self.endpoint)
        host = parsed.hostname or "127.0.0.1"
        port = str(parsed.port or 3000)
        cmd = [
            binary,
            "--transport", "http",
            "--http-host", host,
            "--http-port", port,
            "--embedder", "minilm",
        ]
        logger.info("Auto-starting Wax MCP: %s", " ".join(cmd))
        try:
            self._process = subprocess.Popen(
                cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            deadline = time.time() + timeout
            while time.time() < deadline:
                time.sleep(0.2)
                if self.probe().get("reachable"):
                    self._auto_started = True
                    return True
        except Exception as exc:
            logger.error("Failed to auto-start Wax MCP: %s", exc)
        return False

    def shutdown(self) -> None:
        if self._auto_started and self._process:
            try:
                self._process.terminate()
                self._process.wait(timeout=5)
            except Exception:
                try:
                    self._process.kill()
                except Exception:
                    pass
            self._process = None
            self._auto_started = False

    def _find_wax_mcp_binary(self) -> Optional[str]:
        candidates = [
            os.environ.get("WAX_MCP_BIN"),
            os.path.expanduser("~/.local/bin/wax-mcp"),
            "/usr/local/bin/wax-mcp",
            "/opt/homebrew/bin/wax-mcp",
            "wax-mcp",
        ]
        plugin_dir = os.path.dirname(os.path.abspath(__file__))
        wax_repo = os.path.normpath(
            os.path.join(plugin_dir, "..", "..", "..", "..", "..", "..", ".build", "debug", "wax-mcp")
        )
        candidates.insert(0, wax_repo)
        for candidate in candidates:
            if candidate and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
                return candidate
        return None

    def diagnose_vector_search(self) -> str:
        info = self.probe()
        if not info.get("reachable"):
            return (
                "Wax MCP server is not running. "
                "Start it with: npx waxmcp --transport http"
            )
        if info.get("vector_search_enabled"):
            embedder = info.get("embedder", {})
            model = embedder.get("model", "unknown") if isinstance(embedder, dict) else "unknown"
            return f"Vector search is active ({model})"
        return (
            "Vector search is disabled — text search still works. "
            "Restart with: npx waxmcp --embedder minilm --transport http"
        )


class WaxMemoryProvider(MemoryProvider):
    """Hermes MemoryProvider that delegates to Wax MCP over HTTP."""

    def __init__(self, client: Any = None, config: Optional[Dict[str, Any]] = None) -> None:
        self._injected_client = client is not None
        self._config = dict(config or {})
        self.endpoint = resolve_endpoint(self._config)
        self._client = client or _WaxHTTPClient(self.endpoint)
        self._manager = _WaxMCPManager(self.endpoint)
        self._session_id: Optional[str] = None
        self._hermes_home: str = ""
        self._platform: str = "cli"
        self._vector_search_available = False
        self._prefetch_lock = threading.Lock()
        self._prefetch_text = ""
        self._prefetch_query = ""
        self._prefetch_count = 0
        self._generation = 0
        self._pool: Optional[ThreadPoolExecutor] = None
        self._in_flight: List[Future[None]] = []

    @property
    def name(self) -> str:
        return "wax-memory"

    def _structured_memory_enabled(self) -> bool:
        if "WAX_STRUCTURED_MEMORY" in os.environ:
            return _truthy(os.environ.get("WAX_STRUCTURED_MEMORY"), True)
        return _truthy(self._config.get("structured_memory"), True)

    def _extended_tools_enabled(self) -> bool:
        if "WAX_HERMES_EXTENDED_TOOLS" in os.environ:
            return _truthy(os.environ.get("WAX_HERMES_EXTENDED_TOOLS"), False)
        return _truthy(self._config.get("extended_tools"), False)

    def _auto_start_enabled(self) -> bool:
        if "WAX_MCP_AUTO_START" in os.environ:
            return _truthy(os.environ.get("WAX_MCP_AUTO_START"), False)
        return _truthy(self._config.get("auto_start"), False)

    def auto_start_enabled(self) -> bool:
        return self._auto_start_enabled()

    def structured_memory_enabled(self) -> bool:
        return self._structured_memory_enabled()

    def probe_broker(self) -> Dict[str, Any]:
        return self._manager.probe()

    def diagnose_vector_search(self) -> str:
        return self._manager.diagnose_vector_search()

    def is_available(self) -> bool:
        if self._injected_client:
            return True
        return _HAS_HTTP

    def unavailable_reason(self) -> str:
        if _HAS_HTTP or self._injected_client:
            return ""
        return "Install the requests package (pip install requests>=2.28) so Wax can reach the MCP broker."

    def initialize(self, session_id: str, **kwargs) -> None:
        self._hermes_home = kwargs.get("hermes_home") or self._hermes_home
        self._platform = kwargs.get("platform", "cli")
        agent_context = kwargs.get("agent_context", "primary")
        if agent_context != "primary":
            logger.debug("Wax skipping init for non-primary context: %s", agent_context)
            return

        if self._hermes_home:
            self._config.update(load_plugin_config(self._hermes_home))
            endpoint = resolve_endpoint(self._config)
            if endpoint != self.endpoint and not self._injected_client:
                self.endpoint = endpoint
                self._client = _WaxHTTPClient(self.endpoint)
                self._manager = _WaxMCPManager(self.endpoint)

        if not self._injected_client and self._auto_start_enabled():
            self._manager.auto_start()

        if not self._injected_client:
            info = self._manager.probe()
            self._vector_search_available = bool(info.get("vector_search_enabled"))
            if info.get("reachable") and not self._vector_search_available:
                logger.warning("%s", self._manager.diagnose_vector_search())

        self._start_session(session_id)

    def _start_session(self, session_id: str, resume: bool = False) -> None:
        tool = "session_resume" if resume else "session_start"
        args: Dict[str, Any] = {"session_id": session_id}
        if not resume:
            args["agent_id"] = f"hermes-{self._platform}"
        try:
            result = self._client.call_tool(tool, args)
            if result["ok"]:
                try:
                    payload = json.loads(result["text"]) if result["text"] else {}
                    self._session_id = payload.get("session_id", session_id)
                except Exception:
                    self._session_id = session_id
            else:
                if resume:
                    self._start_session(session_id, resume=False)
                    return
                logger.error("Wax %s failed: %s", tool, result.get("text", "unknown"))
                self._session_id = session_id
        except Exception as exc:
            if resume:
                logger.debug("Wax session_resume failed, starting new session: %s", exc)
                self._start_session(session_id, resume=False)
                return
            logger.error("Wax initialize failed: %s", exc)
            self._session_id = session_id

    def system_prompt_block(self) -> str:
        search_modes = "text, vector, and hybrid" if self._vector_search_available else "text"
        return (
            f"You have access to Wax memory — a persistent, searchable memory system "
            f"with {search_modes} search.\n"
            "Use wax_remember to save important facts, decisions, and lessons.\n"
            "Use wax_recall to retrieve prior context when needed.\n"
            "Use wax_handoff to capture session state for future sessions.\n"
            "Built-in MEMORY.md writes are mirrored into Wax automatically."
        )

    def _active_session(self, session_id: str = "") -> Optional[str]:
        return session_id or self._session_id

    def _invalidate_prefetch(self) -> int:
        with self._prefetch_lock:
            self._generation += 1
            self._prefetch_text = ""
            self._prefetch_query = ""
            self._prefetch_count = 0
            return self._generation

    def _set_prefetch(self, query: str, text: str, generation: Optional[int] = None) -> str:
        formatted = f"\n[Wax Memory Context]\n{text}\n" if text else ""
        count = max(1, text.count("\n") + 1) if text and text.strip() else 0
        with self._prefetch_lock:
            if generation is not None and generation != self._generation:
                return ""
            self._prefetch_query = query
            self._prefetch_text = formatted
            self._prefetch_count = count
        return formatted

    def _tool_args(self, base: Dict[str, Any], session_id: str = "") -> Dict[str, Any]:
        args = dict(base)
        active = self._active_session(session_id)
        if active:
            args["session_id"] = active
        return args

    def _recall_text(self, query: str, session_id: str = "") -> str:
        result = self._client.call_tool(
            "recall",
            self._tool_args({"query": query, "limit": 5, "mode": "hybrid"}, session_id),
        )
        if result["ok"] and result["text"]:
            return result["text"]
        return ""

    def queue_prefetch(self, query: str, *, session_id: str = "") -> None:
        if is_trivial_prompt(query) or _is_internal_gateway_turn(query):
            return
        with self._prefetch_lock:
            self._generation += 1
            generation = self._generation

        def _warm() -> None:
            try:
                text = self._recall_text(query, session_id)
                self._set_prefetch(query, text, generation)
            except Exception as exc:
                logger.debug("Wax queue_prefetch failed: %s", exc)

        self._spawn(_warm)

    def prefetch(self, query: str, *, session_id: str = "") -> str:
        if is_trivial_prompt(query) or _is_internal_gateway_turn(query):
            return ""
        with self._prefetch_lock:
            cached_query = self._prefetch_query
            cached_text = self._prefetch_text
        if cached_text and cached_query == query:
            return cached_text
        self._join_background(timeout=1.0)
        with self._prefetch_lock:
            if self._prefetch_text and self._prefetch_query == query:
                return self._prefetch_text
        try:
            text = self._recall_text(query, session_id)
            return self._set_prefetch(query, text)
        except Exception as exc:
            logger.debug("Wax prefetch failed: %s", exc)
            return ""

    def recall_status(self) -> Optional[RecallStatus]:
        with self._prefetch_lock:
            if not self._prefetch_text:
                return None
            return RecallStatus(provider_label="Wax", count=self._prefetch_count, glyph="🧠")

    def _ensure_pool(self) -> ThreadPoolExecutor:
        if self._pool is None:
            self._pool = ThreadPoolExecutor(max_workers=1, thread_name_prefix="wax-mem")
        return self._pool

    def _close_pool(self) -> None:
        pool = self._pool
        self._pool = None
        self._in_flight = []
        if pool is not None:
            pool.shutdown(wait=True, cancel_futures=False)

    def _spawn(self, target: Callable[[], None]) -> None:
        future = self._ensure_pool().submit(target)
        self._in_flight.append(future)
        self._in_flight = [item for item in self._in_flight if not item.done()]

    def _join_background(self, timeout: float = 2.0) -> None:
        pending = [item for item in self._in_flight if not item.done()]
        if pending:
            wait(pending, timeout=timeout)
        self._in_flight = [item for item in self._in_flight if not item.done()]

    def sync_turn(
        self,
        user_content: str,
        assistant_content: str,
        *,
        session_id: str = "",
        messages: Optional[List[Dict[str, Any]]] = None,
    ) -> None:
        if not user_content or not assistant_content:
            return
        if is_trivial_prompt(user_content) or _is_internal_gateway_turn(user_content):
            return

        def _sync() -> None:
            try:
                summary = f"User: {user_content[:500]}\nAssistant: {assistant_content[:500]}"
                self._client.call_tool(
                    "remember",
                    self._tool_args(
                        {
                            "content": summary,
                            "memory_type": "note",
                            "durability": "working",
                            "metadata": {"source": "hermes_sync_turn", "platform": self._platform},
                        },
                        session_id,
                    ),
                )
            except Exception as exc:
                logger.debug("Wax sync_turn failed: %s", exc)

        self._spawn(_sync)

    def get_tool_schemas(self) -> List[Dict[str, Any]]:
        names = set(CORE_TOOL_NAMES)
        if self._structured_memory_enabled():
            names.update(STRUCTURED_TOOL_NAMES)
        if self._extended_tools_enabled():
            names.update(EXTENDED_TOOL_NAMES)
        return [_TOOL_SCHEMAS[name] for name in _TOOL_SCHEMAS if name in names]

    def handle_tool_call(self, tool_name: str, args: Dict[str, Any], **kwargs) -> str:
        wax_tool = tool_name.replace("wax_", "", 1)
        forwarded = dict(args or {})
        if (
            self._session_id
            and "session_id" not in forwarded
            and wax_tool in TOOLS_WITH_SESSION_ID
        ):
            forwarded["session_id"] = self._session_id
        try:
            result = self._client.call_tool(wax_tool, forwarded)
            if result["ok"]:
                return result["text"] or json.dumps({"ok": True})
            return json.dumps({"ok": False, "error": result["text"] or "Wax tool failed"})
        except Exception as exc:
            logger.error("Wax tool %s failed: %s", tool_name, exc)
            return json.dumps({"error": str(exc), "ok": False})

    def on_session_switch(
        self,
        new_session_id: str,
        *,
        parent_session_id: str = "",
        reset: bool = False,
        rewound: bool = False,
        **kwargs,
    ) -> None:
        if rewound and new_session_id == (self._session_id or ""):
            self._invalidate_prefetch()
            return
        self._invalidate_prefetch()
        old = self._session_id
        if reset and old:
            try:
                self._client.call_tool("session_end", {"session_id": old})
            except Exception as exc:
                logger.debug("Wax session_end during reset failed: %s", exc)
            self._start_session(new_session_id, resume=False)
        else:
            self._start_session(new_session_id, resume=True)

    def on_session_end(self, messages: List[Dict[str, Any]]) -> None:
        logger.info("Wax on_session_end triggered")
        self._invalidate_prefetch()
        self._join_background()
        try:
            content = ""
            try:
                result = self._client.call_tool(
                    "session_synthesize",
                    {"session_id": self._session_id} if self._session_id else {},
                )
                if result["ok"] and result["text"]:
                    try:
                        payload = json.loads(result["text"])
                        content = (
                            payload.get("handoff")
                            or payload.get("content")
                            or payload.get("summary")
                            or result["text"]
                        )
                    except Exception:
                        content = result["text"]
            except Exception as exc:
                logger.debug("Wax session_synthesize failed: %s", exc)
            if not content:
                parts = []
                for msg in messages[-6:]:
                    role = msg.get("role", "")
                    text = msg.get("content", "")
                    if text and len(str(text)) < 500:
                        parts.append(f"{role}: {str(text)[:200]}")
                content = "\n".join(parts)
            if content:
                self._client.call_tool(
                    "handoff",
                    self._tool_args({"content": content, "pending_tasks": []}),
                )
            if self._session_id:
                self._client.call_tool("session_end", {"session_id": self._session_id})
        except Exception as exc:
            logger.error("Wax on_session_end failed: %s", exc)
        finally:
            self._session_id = None
            self._client.close()
            self._close_pool()

    def on_pre_compress(self, messages: List[Dict[str, Any]]) -> str:
        try:
            user_msgs = [str(m.get("content", "")) for m in messages if m.get("role") == "user"]
            if not user_msgs:
                return ""
            query = " ".join(user_msgs[-3:])[:200]
            result = self._client.call_tool(
                "compact_context",
                self._tool_args({"query": query, "token_budget": 800}),
            )
            if result["ok"]:
                return result["text"]
        except Exception as exc:
            logger.debug("Wax on_pre_compress failed: %s", exc)
        return ""

    def on_delegation(self, task: str, result: str, *, child_session_id: str = "", **kwargs) -> None:
        if not task or not result:
            return

        def _write() -> None:
            try:
                self._client.call_tool(
                    "remember",
                    self._tool_args(
                        {
                            "content": f"Delegated: {task[:400]}\nResult: {result[:400]}",
                            "memory_type": "note",
                            "durability": "working",
                            "metadata": {
                                "source": "hermes_delegation",
                                "child_session_id": child_session_id or "",
                            },
                        }
                    ),
                )
            except Exception as exc:
                logger.debug("Wax on_delegation failed: %s", exc)

        self._spawn(_write)

    def on_memory_write(
        self,
        action: str,
        target: str,
        content: str,
        metadata: Optional[Dict[str, Any]] = None,
    ) -> None:
        if action not in {"add", "replace"} or not content:
            return
        memory_type = "user_preference" if target == "user" else "note"

        def _write() -> None:
            try:
                self._client.call_tool(
                    "remember",
                    self._tool_args(
                        {
                            "content": content,
                            "memory_type": memory_type,
                            "durability": "durable",
                            "metadata": {
                                "source": "hermes_memory_write",
                                "target": target,
                                "action": action,
                            },
                        }
                    ),
                )
            except Exception as exc:
                logger.debug("Wax on_memory_write failed: %s", exc)

        self._spawn(_write)

    def backup_paths(self) -> List[str]:
        candidates = [
            os.environ.get("WAX_STORE_PATH"),
            os.path.expanduser("~/.wax/memory.wax"),
            os.path.expanduser("~/.local/share/waxmcp"),
        ]
        paths: List[str] = []
        for candidate in candidates:
            if candidate and os.path.exists(candidate):
                paths.append(os.path.abspath(candidate))
        return paths

    def shutdown(self) -> None:
        self._join_background()
        if self._session_id:
            try:
                self._client.call_tool("session_end", {"session_id": self._session_id})
            except Exception as exc:
                logger.debug("Wax shutdown cleanup failed: %s", exc)
            finally:
                self._session_id = None
        self._client.close()
        self._manager.shutdown()
        self._close_pool()

    def get_config_schema(self) -> List[Dict[str, Any]]:
        return [
            {
                "key": "endpoint",
                "description": "Wax MCP HTTP endpoint URL",
                "required": False,
                "default": DEFAULT_ENDPOINT,
                "env_var": "WAX_MCP_HTTP_ENDPOINT",
            },
            {
                "key": "auto_start",
                "description": "Auto-start Wax MCP if it is not already running",
                "required": False,
                "default": False,
                "type": "boolean",
                "choices": [True, False],
                "env_var": "WAX_MCP_AUTO_START",
            },
        ]

    def save_config(self, values: Dict[str, Any], hermes_home: str) -> None:
        config_path = Path(hermes_home) / CONFIG_FILENAME
        existing = load_plugin_config(hermes_home)
        existing.update(values)
        try:
            config_path.write_text(json.dumps(existing, indent=2) + "\n", encoding="utf-8")
            self._config.update(existing)
            self.endpoint = resolve_endpoint(self._config)
        except Exception as exc:
            logger.warning("Wax save_config failed: %s", exc)


def register(ctx) -> None:
    """Register Wax as a Hermes memory provider plugin."""
    ctx.register_memory_provider(WaxMemoryProvider())
    skills_dir = Path(__file__).resolve().parent / "skills" / "maintenance" / "SKILL.md"
    register_skill = getattr(ctx, "register_skill", None)
    if callable(register_skill) and skills_dir.is_file():
        try:
            register_skill(
                "maintenance",
                skills_dir,
                "Maintain the Wax memory store used by Hermes",
            )
        except Exception as exc:
            logger.debug("Wax skill registration skipped: %s", exc)
