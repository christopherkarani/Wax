"""Wax Memory Plugin — native Hermes MemoryProvider backed by Wax MCP."""

from __future__ import annotations

import json
import ipaddress
import logging
import os
import platform
import re
import subprocess
import threading
import time
from dataclasses import dataclass
from itertools import count
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional
from urllib.parse import urlparse

if __package__:
    # Hermes directory plugins are a synthetic package and do not put this
    # directory on sys.path. Relative sibling imports resolve via __path__;
    # hyphenated package segments cannot be loaded as dotted identifiers.
    from .wax_memory_schemas import (
        CORE_TOOL_NAMES,
        EXTENDED_TOOL_NAMES,
        STRUCTURED_TOOL_NAMES,
        TOOL_SCHEMAS as _TOOL_SCHEMAS,
        TOOLS_WITH_SESSION_ID,
        WAX_MEMORY_TYPES,
    )
    from .wax_memory_lifecycle import WaxProviderLifecycle
else:
    from wax_memory_schemas import (
        CORE_TOOL_NAMES,
        EXTENDED_TOOL_NAMES,
        STRUCTURED_TOOL_NAMES,
        TOOL_SCHEMAS as _TOOL_SCHEMAS,
        TOOLS_WITH_SESSION_ID,
        WAX_MEMORY_TYPES,
    )
    from wax_memory_lifecycle import WaxProviderLifecycle

logger = logging.getLogger(__name__)

PLUGIN_VERSION = "0.1.39"
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
        client: Optional[_WaxHTTPClient] = None
        try:
            client = _WaxHTTPClient(self.endpoint)
            result = client.call_tool("stats", {})
            if result["ok"] and result["text"]:
                stats = json.loads(result["text"])
                vector_configured = bool(stats.get("vectorSearchEnabled", False))
                query_available = bool(stats.get("queryEmbeddingAvailable", False))
                return {
                    "reachable": True,
                    "vector_search_enabled": vector_configured and query_available,
                    "vector_search_configured": vector_configured,
                    "query_embedding_available": query_available,
                    "embedding_status": stats.get("embeddingStatus"),
                    "embedding_status_reason": stats.get("embeddingStatusReason"),
                    "frames_without_vectors": stats.get("framesWithoutVectors", 0),
                    "embedder": stats.get("embedder"),
                    "frame_count": stats.get("frameCount", 0),
                }
        except Exception as exc:
            logger.debug("Wax MCP probe failed: %s", exc)
        finally:
            if client is not None:
                client.close()
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
        host = parsed.hostname
        try:
            is_loopback = bool(
                host
                and (
                    host.lower() == "localhost"
                    or ipaddress.ip_address(host).is_loopback
                )
            )
        except ValueError:
            is_loopback = False
        if parsed.scheme != "http" or not is_loopback:
            logger.error("Refusing to auto-start Wax MCP for unsupported endpoint: %s", self.endpoint)
            return False
        port = str(parsed.port or 3000)
        endpoint_path = parsed.path or "/mcp"
        cmd = [
            binary,
            "--transport", "http",
            "--http-host", host,
            "--http-port", port,
            "--http-endpoint", endpoint_path,
            "--embedder", "minilm",
        ]
        logger.info("Auto-starting Wax MCP: %s", " ".join(cmd))
        try:
            self._process = subprocess.Popen(
                cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            )
            deadline = time.time() + timeout
            while time.time() < deadline:
                if self._process.poll() is not None:
                    logger.error("Auto-started Wax MCP exited before becoming ready")
                    self._stop_process()
                    return False
                if self.probe().get("reachable"):
                    self._auto_started = True
                    return True
                time.sleep(0.2)
        except Exception as exc:
            logger.error("Failed to auto-start Wax MCP: %s", exc)
            self._stop_process()
            return False
        logger.error("Timed out waiting for auto-started Wax MCP")
        self._stop_process()
        return False

    def shutdown(self) -> None:
        if self._process:
            self._stop_process()

    def _stop_process(self) -> None:
        process = self._process
        self._process = None
        self._auto_started = False
        if process is None:
            return
        try:
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=5)
        except Exception:
            try:
                process.kill()
            except Exception:
                pass
            try:
                process.wait(timeout=5)
            except Exception:
                logger.error("Unable to reap auto-started Wax MCP process")

    def _find_wax_mcp_binary(self) -> Optional[str]:
        machine = platform.machine().lower()
        architecture = {
            "aarch64": "arm64",
            "arm64": "arm64",
            "amd64": "x64",
            "x86_64": "x64",
        }.get(machine, machine)
        system = platform.system().lower()
        install_root = os.environ.get(
            "WAX_MCP_INSTALL_ROOT",
            os.path.expanduser("~/.local/share/waxmcp"),
        )
        installed_runtime = os.path.join(
            os.path.expanduser(install_root),
            "runtime",
            f"{system}-{architecture}",
            "wax-mcp",
        )
        candidates = [
            os.environ.get("WAX_MCP_BIN"),
            installed_runtime,
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
        status = info.get("embedding_status") or "unavailable"
        reason = info.get("embedding_status_reason") or "query embedding is unavailable"
        missing = info.get("frames_without_vectors", 0)
        return (
            f"Vector search is unavailable (embeddingStatus={status}, reason={reason}, "
            f"framesWithoutVectors={missing}) — text search still works. "
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
        self._lifecycle = WaxProviderLifecycle(
            client=lambda: self._client,
            reset_transport=self._reset_transport_after_failed_open,
        )
        self._hermes_home: str = ""
        self._platform: str = "cli"
        self._cwd: str = os.getcwd()
        self._project: str = ""
        self._repo: str = ""
        self._vector_search_available = False
        self._prefetch_lock = threading.Lock()
        self._prefetch_text = ""
        self._prefetch_query = ""
        self._prefetch_count = 0
        self._generation = 0

    # Preserve the provider's established internal test seams while the
    # coordinator remains the sole owner of lifecycle state.
    @property
    def _session_id(self) -> Optional[str]:
        return self._lifecycle.session_id

    @_session_id.setter
    def _session_id(self, value: Optional[str]) -> None:
        self._lifecycle.session_id = value

    @property
    def _host_session_id(self) -> str:
        return self._lifecycle.host_session_id

    @_host_session_id.setter
    def _host_session_id(self, value: str) -> None:
        self._lifecycle.host_session_id = value

    @property
    def _accepting_background(self) -> bool:
        return self._lifecycle.accepting_background

    @_accepting_background.setter
    def _accepting_background(self, value: bool) -> None:
        self._lifecycle.accepting_background = value

    @property
    def _lifecycle_lock(self):
        return self._lifecycle.lifecycle_lock

    @property
    def _transition_lock(self):
        return self._lifecycle.transition_lock

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
        agent_context = kwargs.get("agent_context", "primary")
        if agent_context != "primary":
            logger.debug("Wax skipping init for non-primary context: %s", agent_context)
            return

        platform_name = kwargs.get("platform", "cli")
        cwd = str(kwargs.get("cwd") or os.getcwd())
        project = str(kwargs.get("project") or "").strip()
        repo = str(kwargs.get("repo") or "").strip()

        def _prepare() -> None:
            self._platform = platform_name
            self._cwd = cwd
            self._project = project
            self._repo = repo
            if self._hermes_home:
                self._config.update(load_plugin_config(self._hermes_home))
                endpoint = resolve_endpoint(self._config)
                if endpoint != self.endpoint and not self._injected_client:
                    self._replace_endpoint(endpoint)

            if not self._injected_client and self._auto_start_enabled():
                self._manager.auto_start()

            if not self._injected_client:
                info = self._manager.probe()
                self._vector_search_available = bool(info.get("vector_search_enabled"))
                if info.get("reachable") and not self._vector_search_available:
                    logger.warning("%s", self._manager.diagnose_vector_search())

        self._lifecycle.initialize_session(
            session_id,
            platform=platform_name,
            cwd=cwd,
            project=project,
            repo=repo,
            prepare=_prepare,
            invalidate_prefetch=self._invalidate_prefetch,
        )

    def _replace_endpoint(self, endpoint: str) -> None:
        old_client = self._client
        old_manager = self._manager
        old_session = self._session_id
        if old_session:
            try:
                result = old_client.call_tool("session_end", {"session_id": old_session})
                if not result.get("ok"):
                    logger.error("Wax endpoint-change session_end failed: %s", result.get("text"))
            except Exception as exc:
                logger.debug("Wax endpoint-change session_end failed: %s", exc)
        try:
            old_client.close()
        except Exception as exc:
            logger.debug("Wax endpoint-change transport close failed: %s", exc)
        try:
            old_manager.shutdown()
        except Exception as exc:
            logger.error("Wax endpoint-change process cleanup failed: %s", exc)
        self._session_id = None
        self.endpoint = endpoint
        self._client = _WaxHTTPClient(endpoint)
        self._manager = _WaxMCPManager(endpoint)

    def _open_session(self, host_session_id: str) -> None:
        self._lifecycle.configure(
            platform=self._platform,
            cwd=self._cwd,
            project=self._project,
            repo=self._repo,
        )
        self._lifecycle.open_session(host_session_id)

    def _reset_transport_after_failed_open(self) -> None:
        if self._injected_client:
            return
        try:
            self._client.close()
        except Exception as exc:
            logger.debug("Wax failed transport close after session_open error: %s", exc)
        self._client = _WaxHTTPClient(self.endpoint)

    def _ensure_session(self) -> Optional[str]:
        return self._lifecycle.ensure_session()

    def _admitted_session(self) -> Optional[str]:
        return self._lifecycle.admitted_session()

    def system_prompt_block(self) -> str:
        search_modes = "text, vector, and hybrid" if self._vector_search_available else "text"
        return (
            f"You have access to Wax memory — a persistent, searchable memory system "
            f"with {search_modes} search.\n"
            "Use wax_remember to save important facts, decisions, and lessons.\n"
            "Use wax_recall to retrieve prior context; it defaults to the current project. "
            "For facts about the person or standing cross-project preferences, pass scope=global. "
            "On project_miss, pass the intended project/repo or explicitly choose global.\n"
            "Use wax_handoff to capture session state for future sessions.\n"
            "Built-in MEMORY.md writes are mirrored into Wax automatically."
        )

    def _active_session(self, session_id: str = "") -> Optional[str]:
        # MemoryProvider callback session IDs belong to Hermes and are not Wax UUIDs.
        # Only the broker-issued ID returned by session_open is safe to forward.
        return self._session_id

    @staticmethod
    def _tool_args_for_session(
        base: Dict[str, Any], wax_session_id: Optional[str]
    ) -> Dict[str, Any]:
        args = dict(base)
        if wax_session_id:
            args["session_id"] = wax_session_id
        return args

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
        return self._tool_args_for_session(base, self._active_session(session_id))

    def _recall_text(self, query: str, session_id: str = "") -> str:
        active = self._ensure_session()
        if not active:
            return ""
        result = self._client.call_tool(
            "recall",
            self._tool_args_for_session(
                {"query": query, "limit": 5, "mode": "hybrid"}, active
            ),
        )
        if result["ok"] and result["text"]:
            return result["text"]
        return ""

    def queue_prefetch(self, query: str, *, session_id: str = "") -> None:
        if is_trivial_prompt(query) or _is_internal_gateway_turn(query):
            return
        wax_session_id = self._admitted_session()
        with self._lifecycle_lock:
            if not self._lifecycle.is_admitted(wax_session_id):
                return
            generation = self._invalidate_prefetch()

            def _warm() -> None:
                try:
                    result = self._client.call_tool(
                        "recall",
                        self._tool_args_for_session(
                            {"query": query, "limit": 5, "mode": "hybrid"}, wax_session_id
                        ),
                    )
                    text = result["text"] if result["ok"] and result["text"] else ""
                    self._set_prefetch(query, text, generation)
                except Exception as exc:
                    logger.debug("Wax queue_prefetch failed: %s", exc)

            self._spawn(_warm)

    def prefetch(self, query: str, *, session_id: str = "") -> str:
        if is_trivial_prompt(query) or _is_internal_gateway_turn(query):
            return ""
        with self._lifecycle_lock:
            if not self._accepting_background:
                return ""
        with self._prefetch_lock:
            cached_query = self._prefetch_query
            cached_text = self._prefetch_text
            generation = self._generation
        if cached_text and cached_query == query:
            return cached_text
        self._join_background(timeout=1.0)
        with self._prefetch_lock:
            if self._prefetch_text and self._prefetch_query == query:
                return self._prefetch_text
        try:
            text = self._recall_text(query, session_id)
            return self._set_prefetch(query, text, generation)
        except Exception as exc:
            logger.debug("Wax prefetch failed: %s", exc)
            return ""

    def recall_status(self) -> Optional[RecallStatus]:
        if self._lifecycle.is_shutdown:
            return None
        with self._prefetch_lock:
            if not self._prefetch_text:
                return None
            return RecallStatus(provider_label="Wax", count=self._prefetch_count, glyph="🧠")

    def _close_pool(self) -> None:
        self._lifecycle.close_pool()

    def _spawn(self, target: Callable[[], None]) -> None:
        self._lifecycle.spawn(target)

    def _join_background(self, timeout: Optional[float] = 2.0) -> bool:
        return self._lifecycle.join_background(timeout)

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
        wax_session_id = self._admitted_session()
        with self._lifecycle_lock:
            if not self._lifecycle.is_admitted(wax_session_id):
                return
            arguments = self._tool_args_for_session(
                {
                    "content": f"User: {user_content[:500]}\nAssistant: {assistant_content[:500]}",
                    "memory_type": "note",
                    "durability": "working",
                    "metadata": {"source": "hermes_sync_turn", "platform": self._platform},
                },
                wax_session_id,
            )

            def _sync() -> None:
                try:
                    self._client.call_tool("remember", arguments)
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
        if wax_tool in {
            "remember", "recall", "search", "handoff", "compact_context",
            "markdown_export", "knowledge_capture", "corpus_search", "promote",
        }:
            forwarded.pop("session_id", None)
        if wax_tool in {"remember", "recall"} and not str(forwarded.get("cwd") or "").strip() and self._cwd:
            forwarded["cwd"] = self._cwd
        try:
            if wax_tool in TOOLS_WITH_SESSION_ID:
                wax_session_id = self._admitted_session()
                with self._lifecycle_lock:
                    if not self._lifecycle.is_admitted(wax_session_id):
                        return json.dumps({
                            "ok": False,
                            "error": "Wax session unavailable; session_open did not return a valid UUID",
                            "retryable": True,
                        })
                    forwarded["session_id"] = wax_session_id
                    result = self._client.call_tool(wax_tool, forwarded)
            else:
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
        cwd = str(kwargs.get("cwd") or os.getcwd())
        project = str(kwargs.get("project") or "").strip()
        repo = str(kwargs.get("repo") or "").strip()
        switched = self._lifecycle.switch_session(
            new_session_id,
            reset=reset,
            rewound=rewound,
            cwd=cwd,
            project=project,
            repo=repo,
            invalidate_prefetch=self._invalidate_prefetch,
        )
        if switched:
            self._cwd = cwd
            self._project = project
            self._repo = repo

    def on_session_end(self, messages: List[Dict[str, Any]]) -> None:
        self._lifecycle.end_session(
            messages,
            invalidate_prefetch=self._invalidate_prefetch,
        )

    def on_pre_compress(self, messages: List[Dict[str, Any]]) -> str:
        try:
            user_msgs = [str(m.get("content", "")) for m in messages if m.get("role") == "user"]
            if not user_msgs:
                return ""
            query = " ".join(user_msgs[-3:])[:200]
            wax_session_id = self._admitted_session()
            with self._lifecycle_lock:
                if not self._lifecycle.is_admitted(wax_session_id):
                    return ""
                result = self._client.call_tool(
                    "compact_context",
                    self._tool_args_for_session(
                        {"query": query, "token_budget": 800}, wax_session_id
                    ),
                )
            if result["ok"]:
                return result["text"]
        except Exception as exc:
            logger.debug("Wax on_pre_compress failed: %s", exc)
        return ""

    def on_delegation(self, task: str, result: str, *, child_session_id: str = "", **kwargs) -> None:
        if not task or not result:
            return
        wax_session_id = self._admitted_session()
        with self._lifecycle_lock:
            if not self._lifecycle.is_admitted(wax_session_id):
                return
            arguments = self._tool_args_for_session(
                {
                    "content": f"Delegated: {task[:400]}\nResult: {result[:400]}",
                    "memory_type": "note",
                    "durability": "working",
                    "metadata": {
                        "source": "hermes_delegation",
                        "child_session_id": child_session_id or "",
                    },
                },
                wax_session_id,
            )

            def _write() -> None:
                try:
                    self._client.call_tool("remember", arguments)
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
        wax_session_id = self._admitted_session()
        with self._lifecycle_lock:
            if not self._lifecycle.is_admitted(wax_session_id):
                logger.warning("Wax on_memory_write skipped: session unavailable")
                return
            arguments = self._tool_args_for_session(
                {
                    "content": content,
                    "memory_type": memory_type,
                    "durability": "durable",
                    "metadata": {
                        "source": "hermes_memory_write",
                        "target": target,
                        "action": action,
                    },
                },
                wax_session_id,
            )

            def _write() -> None:
                try:
                    self._client.call_tool("remember", arguments)
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
        self._lifecycle.shutdown(
            self._manager.shutdown,
            invalidate_prefetch=self._invalidate_prefetch,
        )

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
