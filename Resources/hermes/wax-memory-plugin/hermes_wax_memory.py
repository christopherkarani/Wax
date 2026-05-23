"""Wax Memory Plugin — Native Hermes MemoryProvider backed by Wax MCP over HTTP.

Zero-config setup for Hermes Agent. The plugin auto-detects a running Wax MCP
server or can auto-start one. Provides clear diagnostics when vector search is
unavailable and guides the user to fix it.

Quick start:
    1. Install Wax MCP:  npx waxmcp install --build
    2. Enable plugin:    hermes config set memory.provider wax-memory
    3. Done — vector search works automatically when available.

Configuration chain (highest priority first):
  1. Environment: WAX_MCP_HTTP_ENDPOINT
  2. Hermes config: wax_memory.endpoint
  3. Default: http://127.0.0.1:3000/mcp

Install as directory plugin:
  cp -r /path/to/wax-memory-plugin ~/.hermes/plugins/wax-memory
"""

from __future__ import annotations

import json
import logging
import os
import subprocess
import time
from typing import Any, Dict, List, Optional

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Hermes MemoryProvider ABC — runtime import so standalone tests work
# ---------------------------------------------------------------------------
try:
    from agent.memory_provider import MemoryProvider
except ImportError:
    from abc import ABC, abstractmethod

    class MemoryProvider(ABC):
        @property
        @abstractmethod
        def name(self) -> str:
            return ""

        @abstractmethod
        def is_available(self) -> bool:
            return False

        @abstractmethod
        def initialize(self, session_id: str, **kwargs) -> None:
            pass

        def system_prompt_block(self) -> str:
            return ""

        def prefetch(self, query: str, *, session_id: str = "") -> str:
            return ""

        def sync_turn(self, user_content: str, assistant_content: str, *, session_id: str = "") -> None:
            pass

        @abstractmethod
        def get_tool_schemas(self) -> List[Dict[str, Any]]:
            return []

        def handle_tool_call(self, tool_name: str, args: Dict[str, Any], **kwargs) -> str:
            raise NotImplementedError

        def on_session_end(self, messages: List[Dict[str, Any]]) -> None:
            pass

        def shutdown(self) -> None:
            pass

        def get_config_schema(self) -> List[Dict[str, Any]]:
            return []

        def save_config(self, values: Dict[str, Any], hermes_home: str) -> None:
            pass


# ---------------------------------------------------------------------------
# HTTP client — Wax MCP SSE transport
# ---------------------------------------------------------------------------
try:
    import requests
    _HAS_REQUESTS = True
except ImportError:
    _HAS_REQUESTS = False


class _WaxHTTPClient:
    """Stateful HTTP client for Wax MCP SSE transport."""

    def __init__(self, endpoint: str) -> None:
        self.endpoint = endpoint
        self._session_id: Optional[str] = None
        self._initialized = False

    def _request(self, payload: Dict[str, Any], timeout: float = 30.0) -> Dict[str, Any]:
        headers = {
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        }
        if self._session_id:
            headers["MCP-Session-Id"] = self._session_id

        if _HAS_REQUESTS:
            resp = requests.post(
                self.endpoint, json=payload, headers=headers,
                timeout=timeout, stream=True,
            )
            resp.raise_for_status()
            for line in resp.iter_lines(decode_unicode=True):
                if line and line.startswith("data: "):
                    data_str = line[6:]
                    if data_str.strip():
                        return json.loads(data_str)
            raise WaxMCPError("Empty SSE response")
        else:
            import urllib.request
            data = json.dumps(payload).encode("utf-8")
            req = urllib.request.Request(
                self.endpoint, data=data, headers=headers, method="POST",
            )
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                body = resp.read().decode("utf-8")
                for line in body.splitlines():
                    if line.startswith("data: "):
                        data_str = line[6:]
                        if data_str.strip():
                            return json.loads(data_str)
                return json.loads(body)

    def _ensure_initialized(self) -> None:
        if self._initialized:
            return

        payload = {
            "jsonrpc": "2.0", "id": 0,
            "method": "initialize",
            "params": {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "hermes-wax-memory", "version": "0.1.23"},
            },
        }
        if _HAS_REQUESTS:
            resp = requests.post(
                self.endpoint, json=payload,
                headers={"Content-Type": "application/json", "Accept": "application/json, text/event-stream"},
                timeout=30.0, stream=True,
            )
            resp.raise_for_status()
            self._session_id = resp.headers.get("Mcp-Session-Id") or resp.headers.get("mcp-session-id")
            for line in resp.iter_lines(decode_unicode=True):
                if line and line.startswith("data: ") and len(line) > 6:
                    data = json.loads(line[6:])
                    if "error" in data:
                        raise WaxMCPError(data["error"].get("message", "Initialize failed"))
                    break
        else:
            import urllib.request
            data = json.dumps(payload).encode("utf-8")
            req = urllib.request.Request(
                self.endpoint, data=data,
                headers={"Content-Type": "application/json", "Accept": "application/json, text/event-stream"},
                method="POST",
            )
            with urllib.request.urlopen(req, timeout=30.0) as resp:
                self._session_id = resp.headers.get("Mcp-Session-Id") or resp.headers.get("mcp-session-id")
                body = resp.read().decode("utf-8")
                for line in body.splitlines():
                    if line.startswith("data: ") and len(line) > 6:
                        data = json.loads(line[6:])
                        if "error" in data:
                            raise WaxMCPError(data["error"].get("message", "Initialize failed"))
                        break

        self._initialized = True
        logger.debug("Wax HTTP session initialized: %s", self._session_id)

    def call_tool(self, tool_name: str, arguments: Dict[str, Any]) -> Dict[str, Any]:
        self._ensure_initialized()
        payload = {
            "jsonrpc": "2.0",
            "id": hash(f"{tool_name}:{json.dumps(arguments, sort_keys=True)}"),
            "method": "tools/call",
            "params": {"name": tool_name, "arguments": arguments},
        }
        data = self._request(payload)
        if "error" in data:
            raise WaxMCPError(data["error"].get("message", "Unknown MCP error"))

        result = data.get("result", {})
        content = result.get("content", [])
        text_parts = [
            block["text"] for block in content
            if block.get("type") == "text" and "text" in block
        ]
        return {
            "ok": not result.get("isError", False),
            "text": "\n".join(text_parts) if text_parts else "",
            "raw": result,
        }

    def close(self) -> None:
        if self._session_id and _HAS_REQUESTS:
            try:
                requests.delete(
                    self.endpoint,
                    headers={"MCP-Session-Id": self._session_id},
                    timeout=10.0,
                )
            except Exception:
                pass
        self._session_id = None
        self._initialized = False


class WaxMCPError(Exception):
    """Raised when the Wax MCP server returns an error."""


# ---------------------------------------------------------------------------
# MCP lifecycle manager — auto-start + diagnostics
# ---------------------------------------------------------------------------

class _WaxMCPManager:
    """Manages the Wax MCP server lifecycle for Hermes integration.

    - Probes if a Wax MCP server is already running
    - Optionally auto-starts one if configured
    - Provides clear diagnostics about vector search capability
    """

    def __init__(self, endpoint: str) -> None:
        self.endpoint = endpoint
        self._auto_started = False
        self._process: Optional[subprocess.Popen] = None
        self._vector_search_available: Optional[bool] = None

    def probe(self) -> Dict[str, Any]:
        """Probe the Wax MCP endpoint and return capability info."""
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
        except Exception as e:
            logger.debug("Wax MCP probe failed: %s", e)
        return {"reachable": False}

    def auto_start(self, timeout: float = 10.0) -> bool:
        """Try to auto-start wax-mcp if not running. Returns True if started."""
        # Check if already running
        info = self.probe()
        if info["reachable"]:
            return False

        # Try to find wax-mcp binary
        binary = self._find_wax_mcp_binary()
        if not binary:
            logger.warning(
                "Wax MCP binary not found. Install with:\n"
                "  npx waxmcp install --build\n"
                "Or build from source:\n"
                "  swift build --product wax-mcp --traits MCPServer"
            )
            return False

        # Start wax-mcp with default settings
        cmd = [
            binary,
            "--transport", "http",
            "--http-host", "127.0.0.1",
            "--http-port", "3000",
            "--embedder", "minilm",
        ]
        logger.info("Auto-starting Wax MCP: %s", " ".join(cmd))
        try:
            self._process = subprocess.Popen(
                cmd,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            # Wait for it to be ready
            deadline = time.time() + timeout
            while time.time() < deadline:
                time.sleep(0.2)
                info = self.probe()
                if info["reachable"]:
                    self._auto_started = True
                    logger.info("Wax MCP auto-started successfully")
                    return True
        except Exception as e:
            logger.error("Failed to auto-start Wax MCP: %s", e)
        return False

    def shutdown(self) -> None:
        """Shutdown auto-started Wax MCP server."""
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
        """Find wax-mcp binary in common locations."""
        candidates = [
            os.environ.get("WAX_MCP_BIN"),
            os.path.expanduser("~/.local/bin/wax-mcp"),
            "/usr/local/bin/wax-mcp",
            "/opt/homebrew/bin/wax-mcp",
            "wax-mcp",  # PATH
        ]
        # Also check next to current plugin
        plugin_dir = os.path.dirname(os.path.abspath(__file__))
        wax_repo = os.path.join(plugin_dir, "..", "..", "..", "..", "..", "..", ".build", "debug", "wax-mcp")
        candidates.insert(0, os.path.normpath(wax_repo))

        for candidate in candidates:
            if candidate and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
                return candidate
        return None

    def diagnose_vector_search(self) -> str:
        """Return a human-readable diagnosis of vector search status."""
        info = self.probe()
        if not info["reachable"]:
            return (
                "❌ Wax MCP server is not running.\n"
                "   Start it manually:  npx waxmcp --transport http\n"
                "   Or build from source: swift build --product wax-mcp --traits MCPServer"
            )

        if info.get("vector_search_enabled"):
            embedder = info.get("embedder", {})
            model = embedder.get("model", "unknown") if isinstance(embedder, dict) else "unknown"
            return f"✅ Vector search is active ({model})"

        return (
            "⚠️  Vector search is DISABLED — running in text-only mode.\n"
            "   The broker was built or started without an embedder.\n"
            "   Fix:\n"
            "     1. Build with embedders:\n"
            "        swift build --product wax-cli --traits 'MiniLMEmbeddings,ArcticEmbeddings'\n"
            "        swift build --product wax-mcp --traits 'MiniLMEmbeddings,ArcticEmbeddings,MCPServer'\n"
            "     2. Restart with embedder: npx waxmcp --embedder minilm --transport http\n"
            "   Text search still works fine — this is only about semantic/vector search."
        )


# ---------------------------------------------------------------------------
# Configuration helpers
# ---------------------------------------------------------------------------

def _get_endpoint(config: Optional[Dict[str, Any]] = None) -> str:
    if env := os.environ.get("WAX_MCP_HTTP_ENDPOINT"):
        return env.rstrip("/")
    if config and isinstance(config.get("endpoint"), str):
        return config["endpoint"].rstrip("/")
    return "http://127.0.0.1:3000/mcp"


# ---------------------------------------------------------------------------
# Tool schemas
# ---------------------------------------------------------------------------

_REMEMBER_SCHEMA = {
    "name": "wax_remember",
    "description": (
        "Store durable or working memory in Wax. Use for facts, decisions, "
        "lessons, and anything the agent should recall later."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "content": {"type": "string", "description": "Text content to store."},
            "session_id": {"type": "string", "description": "Optional session UUID."},
            "metadata": {"type": "object", "description": "Optional metadata.", "additionalProperties": True},
            "memory_type": {"type": "string", "enum": ["working", "episodic", "durable", "knowledge"]},
            "durability": {"type": "string", "enum": ["ephemeral", "working", "durable", "locked"]},
            "project": {"type": "string"},
            "repo": {"type": "string"},
            "confidence": {"type": "number", "minimum": 0.0, "maximum": 1.0},
            "expires_in_days": {"type": "integer", "minimum": 1, "maximum": 3650},
            "reviewed": {"type": "boolean"},
            "locked": {"type": "boolean"},
        },
        "required": ["content"],
        "additionalProperties": False,
    },
}

_RECALL_SCHEMA = {
    "name": "wax_recall",
    "description": (
        "Recall context from Wax memory using RAG assembly. Returns ranked "
        "memory excerpts. Use 'mode: vector' for semantic search, 'mode: text' "
        "for keyword search, or 'mode: hybrid' for both (default)."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "query": {"type": "string", "description": "Recall query text."},
            "limit": {"type": "integer", "minimum": 1, "maximum": 100, "description": "Max context items. Default: 5."},
            "session_id": {"type": "string"},
            "mode": {"type": "string", "enum": ["text", "vector", "hybrid"], "description": "Search mode. Default: hybrid."},
            "alpha": {"type": "number", "minimum": 0.0, "maximum": 1.0, "description": "Hybrid blend (0=text, 1=vector)."},
        },
        "required": ["query"],
        "additionalProperties": False,
    },
}

_SEARCH_SCHEMA = {
    "name": "wax_search",
    "description": (
        "Run direct Wax search and return ranked raw hits with previews. "
        "Cheaper than recall — use when you just want to find matching memories."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "query": {"type": "string"},
            "mode": {"type": "string", "enum": ["text", "vector", "hybrid"]},
            "topK": {"type": "integer", "minimum": 1, "maximum": 200, "description": "Max hit count. Default: 10."},
            "session_id": {"type": "string"},
            "alpha": {"type": "number", "minimum": 0.0, "maximum": 1.0},
        },
        "required": ["query"],
        "additionalProperties": False,
    },
}

_HANDOFF_SCHEMA = {
    "name": "wax_handoff",
    "description": "Store a cross-session handoff note for later retrieval.",
    "parameters": {
        "type": "object",
        "properties": {
            "content": {"type": "string"},
            "session_id": {"type": "string"},
            "project": {"type": "string"},
            "pending_tasks": {"type": "array", "items": {"type": "string"}},
        },
        "required": ["content"],
        "additionalProperties": False,
    },
}

_HANDOFF_LATEST_SCHEMA = {
    "name": "wax_handoff_latest",
    "description": "Fetch the latest handoff note, optionally scoped by project.",
    "parameters": {
        "type": "object",
        "properties": {"project": {"type": "string"}},
        "required": [],
        "additionalProperties": False,
    },
}

_COMPACT_CONTEXT_SCHEMA = {
    "name": "wax_compact_context",
    "description": (
        "Assemble short, medium, and long-horizon memory into a token-budgeted "
        "checkpoint for long-running agents."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "query": {"type": "string"},
            "session_id": {"type": "string"},
            "token_budget": {"type": "integer", "minimum": 128, "maximum": 32000},
            "max_items": {"type": "integer", "minimum": 1, "maximum": 64},
            "mode": {"type": "string", "enum": ["text", "vector", "hybrid"]},
            "alpha": {"type": "number", "minimum": 0.0, "maximum": 1.0},
        },
        "required": ["query"],
        "additionalProperties": False,
    },
}

_MARKDOWN_EXPORT_SCHEMA = {
    "name": "wax_markdown_export",
    "description": "Export Markdown projections (MEMORY.md, daily notes) from Wax.",
    "parameters": {
        "type": "object",
        "properties": {
            "output_dir": {"type": "string"},
            "session_id": {"type": "string"},
        },
        "required": ["output_dir"],
        "additionalProperties": False,
    },
}

_MARKDOWN_SYNC_SCHEMA = {
    "name": "wax_markdown_sync",
    "description": "Import and reconcile Markdown projections back into Wax.",
    "parameters": {
        "type": "object",
        "properties": {
            "root_dir": {"type": "string"},
            "dry_run": {"type": "boolean"},
        },
        "required": ["root_dir"],
        "additionalProperties": False,
    },
}

_STATS_SCHEMA = {
    "name": "wax_stats",
    "description": "Return Wax runtime and storage statistics.",
    "parameters": {
        "type": "object",
        "properties": {},
        "required": [],
        "additionalProperties": False,
    },
}

_SESSION_START_SCHEMA = {
    "name": "wax_session_start",
    "description": "Create a broker-managed virtual session.",
    "parameters": {
        "type": "object",
        "properties": {
            "session_id": {"type": "string"},
            "agent_id": {"type": "string"},
            "run_id": {"type": "string"},
        },
        "required": [],
        "additionalProperties": False,
    },
}

_SESSION_END_SCHEMA = {
    "name": "wax_session_end",
    "description": "End an active broker-managed virtual session.",
    "parameters": {
        "type": "object",
        "properties": {"session_id": {"type": "string"}},
        "required": [],
        "additionalProperties": False,
    },
}

_ENTITY_UPSERT_SCHEMA = {
    "name": "wax_entity_upsert",
    "description": "Upsert a structured-memory entity by key.",
    "parameters": {
        "type": "object",
        "properties": {
            "key": {"type": "string"},
            "kind": {"type": "string"},
            "aliases": {"type": "array", "items": {"type": "string"}},
        },
        "required": ["key", "kind"],
        "additionalProperties": False,
    },
}

_FACT_ASSERT_SCHEMA = {
    "name": "wax_fact_assert",
    "description": "Assert a structured-memory fact (S-P-O triple).",
    "parameters": {
        "type": "object",
        "properties": {
            "subject": {"type": "string"},
            "predicate": {"type": "string"},
            "object": {"description": "Fact value: string, number, boolean, or typed object."},
            "relation": {"type": "string", "enum": ["sets", "updates", "extends", "retracts"]},
            "valid_from": {"type": "integer"},
            "valid_to": {"type": "integer"},
        },
        "required": ["subject", "predicate", "object"],
        "additionalProperties": False,
    },
}

_FACTS_QUERY_SCHEMA = {
    "name": "wax_facts_query",
    "description": "Query structured-memory facts by subject, predicate, or time.",
    "parameters": {
        "type": "object",
        "properties": {
            "subject": {"type": "string"},
            "predicate": {"type": "string"},
            "as_of": {"type": "integer"},
            "system_as_of": {"type": "integer"},
            "valid_as_of": {"type": "integer"},
            "limit": {"type": "integer", "minimum": 1, "maximum": 500},
        },
        "required": [],
        "additionalProperties": False,
    },
}


# ---------------------------------------------------------------------------
# WaxMemoryProvider
# ---------------------------------------------------------------------------

class WaxMemoryProvider(MemoryProvider):
    """Hermes MemoryProvider that delegates to Wax MCP over HTTP."""

    def __init__(self) -> None:
        self.endpoint = _get_endpoint()
        self._client = _WaxHTTPClient(self.endpoint)
        self._manager = _WaxMCPManager(self.endpoint)
        self._structured_memory = os.environ.get("WAX_STRUCTURED_MEMORY", "1") == "1"
        self._session_id: Optional[str] = None
        self._hermes_home: str = ""
        self._vector_search_available = False
        logger.info("WaxMemoryProvider initialized — endpoint: %s", self.endpoint)

    # -- MemoryProvider ABC ------------------------------------------------

    @property
    def name(self) -> str:
        return "wax-memory"

    def is_available(self) -> bool:
        """Check if Wax MCP is reachable (auto-start if configured)."""
        info = self._manager.probe()
        if info["reachable"]:
            self._vector_search_available = info.get("vector_search_enabled", False)
            return True

        # Auto-start if WAX_MCP_AUTO_START is set
        if os.environ.get("WAX_MCP_AUTO_START", "0") == "1":
            if self._manager.auto_start():
                info = self._manager.probe()
                self._vector_search_available = info.get("vector_search_enabled", False)
                return True

        logger.warning(
            "Wax MCP not available at %s.\n%s",
            self.endpoint,
            self._manager.diagnose_vector_search(),
        )
        return False

    def initialize(self, session_id: str, **kwargs) -> None:
        self._hermes_home = kwargs.get("hermes_home", "")
        platform = kwargs.get("platform", "cli")
        agent_context = kwargs.get("agent_context", "primary")

        if agent_context != "primary":
            logger.debug("Wax skipping init for non-primary context: %s", agent_context)
            return

        # Log vector search status on first init
        if not self._vector_search_available:
            info = self._manager.probe()
            self._vector_search_available = info.get("vector_search_enabled", False)
            if not self._vector_search_available and info["reachable"]:
                logger.warning(
                    "Vector search is disabled. Text search still works.\n"
                    "To enable vector search, rebuild with embedders.\n"
                    "Run: npx waxmcp vector-health  (for full diagnostics)"
                )

        try:
            result = self._client.call_tool(
                "session_start",
                {"session_id": session_id, "agent_id": f"hermes-{platform}"},
            )
            if result["ok"]:
                try:
                    payload = json.loads(result["text"])
                    self._session_id = payload.get("session_id", session_id)
                except Exception:
                    self._session_id = session_id
                logger.info("Wax session started: %s", self._session_id)
            else:
                logger.error("Wax session_start failed: %s", result.get("text", "unknown"))
        except Exception as e:
            logger.error("Wax initialize failed: %s", e)

    def system_prompt_block(self) -> str:
        search_modes = "text, vector, and hybrid" if self._vector_search_available else "text"
        return (
            f"You have access to Wax memory — a persistent, searchable memory system "
            f"with {search_modes} search.\n"
            "Use wax_remember to save important facts, decisions, and lessons.\n"
            "Use wax_recall to retrieve prior context when needed.\n"
            "Use wax_handoff to capture session state for future sessions."
        )

    def prefetch(self, query: str, *, session_id: str = "") -> str:
        if not query or len(query) < 3:
            return ""
        try:
            result = self._client.call_tool(
                "recall",
                {"query": query, "limit": 5, "session_id": session_id or self._session_id},
            )
            if result["ok"] and result["text"]:
                return f"\n[Wax Memory Context]\n{result['text']}\n"
        except Exception as e:
            logger.debug("Wax prefetch failed: %s", e)
        return ""

    def sync_turn(self, user_content: str, assistant_content: str, *, session_id: str = "") -> None:
        if not user_content or not assistant_content:
            return
        try:
            summary = f"User: {user_content[:500]}\nAssistant: {assistant_content[:500]}"
            self._client.call_tool(
                "remember",
                {
                    "content": summary,
                    "session_id": session_id or self._session_id,
                    "memory_type": "working",
                    "durability": "working",
                    "metadata": {"source": "hermes_sync_turn", "platform": "cli"},
                },
            )
        except Exception as e:
            logger.debug("Wax sync_turn failed: %s", e)

    def get_tool_schemas(self) -> List[Dict[str, Any]]:
        tools = [
            _REMEMBER_SCHEMA,
            _RECALL_SCHEMA,
            _SEARCH_SCHEMA,
            _HANDOFF_SCHEMA,
            _HANDOFF_LATEST_SCHEMA,
            _COMPACT_CONTEXT_SCHEMA,
            _MARKDOWN_EXPORT_SCHEMA,
            _MARKDOWN_SYNC_SCHEMA,
            _STATS_SCHEMA,
            _SESSION_START_SCHEMA,
            _SESSION_END_SCHEMA,
        ]
        if self._structured_memory:
            tools.extend([
                _ENTITY_UPSERT_SCHEMA,
                _FACT_ASSERT_SCHEMA,
                _FACTS_QUERY_SCHEMA,
            ])
        return tools

    _TOOLS_WITH_SESSION_ID = {
        "remember", "recall", "search", "handoff", "handoff_latest",
        "compact_context", "markdown_export", "markdown_sync",
        "session_start", "session_end", "session_resume",
        "session_synthesize", "memory_append", "memory_search",
        "memory_get", "memory_promote", "promote",
        "knowledge_capture", "corpus_search",
    }

    def handle_tool_call(self, tool_name: str, args: Dict[str, Any], **kwargs) -> str:
        wax_tool = tool_name.replace("wax_", "", 1)
        try:
            if (self._session_id
                    and "session_id" not in args
                    and wax_tool in self._TOOLS_WITH_SESSION_ID):
                args = {**args, "session_id": self._session_id}
            result = self._client.call_tool(wax_tool, args)
            return json.dumps(result)
        except Exception as e:
            logger.error("Wax tool %s failed: %s", tool_name, e)
            return json.dumps({"error": str(e), "ok": False})

    def on_session_end(self, messages: List[Dict[str, Any]]) -> None:
        logger.info("Wax on_session_end triggered")
        try:
            summary_parts = []
            for msg in messages[-6:]:
                role = msg.get("role", "")
                content = msg.get("content", "")
                if content and len(content) < 500:
                    summary_parts.append(f"{role}: {content[:200]}")
            if summary_parts:
                summary = "\n".join(summary_parts)
                self._client.call_tool(
                    "handoff",
                    {"content": summary, "session_id": self._session_id, "pending_tasks": []},
                )
            if self._session_id:
                self._client.call_tool("session_end", {"session_id": self._session_id})
                logger.info("Wax session ended: %s", self._session_id)
        except Exception as e:
            logger.error("Wax on_session_end failed: %s", e)
        finally:
            self._session_id = None
            self._client.close()

    def on_pre_compress(self, messages: List[Dict[str, Any]]) -> str:
        try:
            user_msgs = [m.get("content", "") for m in messages if m.get("role") == "user"]
            if not user_msgs:
                return ""
            query = " ".join(user_msgs[-3:])[:200]
            result = self._client.call_tool(
                "compact_context",
                {"query": query, "session_id": self._session_id, "token_budget": 800},
            )
            if result["ok"]:
                return result["text"]
        except Exception as e:
            logger.debug("Wax on_pre_compress failed: %s", e)
        return ""

    def shutdown(self) -> None:
        if self._session_id:
            try:
                self._client.call_tool("session_end", {"session_id": self._session_id})
            except Exception as e:
                logger.debug("Wax shutdown cleanup failed: %s", e)
            finally:
                self._session_id = None
        self._client.close()
        self._manager.shutdown()

    def get_config_schema(self) -> List[Dict[str, Any]]:
        return [
            {
                "key": "endpoint",
                "description": "Wax MCP HTTP endpoint URL",
                "required": False,
                "default": "http://127.0.0.1:3000/mcp",
                "env_var": "WAX_MCP_HTTP_ENDPOINT",
            },
            {
                "key": "auto_start",
                "description": "Auto-start Wax MCP if not running (set WAX_MCP_AUTO_START=1)",
                "required": False,
                "default": False,
                "choices": [True, False],
            },
            {
                "key": "structured_memory",
                "description": "Enable structured memory tools",
                "required": False,
                "default": True,
                "choices": [True, False],
                "env_var": "WAX_STRUCTURED_MEMORY",
            },
        ]

    def save_config(self, values: Dict[str, Any], hermes_home: str) -> None:
        config_path = os.path.join(hermes_home, "wax-memory.json")
        try:
            with open(config_path, "w") as f:
                json.dump(values, f, indent=2)
        except Exception as e:
            logger.warning("Wax save_config failed: %s", e)


# ---------------------------------------------------------------------------
# Plugin entry point
# ---------------------------------------------------------------------------

def register(ctx) -> None:
    """Register Wax as a Hermes memory provider plugin."""
    ctx.register_memory_provider(WaxMemoryProvider())
