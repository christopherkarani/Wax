"""Behavioral tests for the Wax Hermes MemoryProvider.

Seam: WaxMemoryProvider public Hermes contract + injected MCP client.
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock

PLUGIN_DIR = Path(__file__).resolve().parents[1]
if str(PLUGIN_DIR) not in sys.path:
    sys.path.insert(0, str(PLUGIN_DIR))

import hermes_wax_memory as plugin  # noqa: E402


class FakeClient:
    def __init__(self) -> None:
        self.calls: list[tuple[str, dict]] = []
        self.responses: dict[str, dict] = {}
        self.closed = False
        self.lock = threading.Lock()

    def call_tool(self, tool_name: str, arguments: dict) -> dict:
        with self.lock:
            self.calls.append((tool_name, dict(arguments)))
        if tool_name in self.responses:
            return self.responses[tool_name]
        if tool_name == "session_start":
            return {
                "ok": True,
                "text": json.dumps({"session_id": arguments.get("session_id", "sess-1")}),
                "raw": {},
            }
        if tool_name == "session_synthesize":
            return {
                "ok": True,
                "text": json.dumps({"handoff": "Synthesized Harbor handoff"}),
                "raw": {},
            }
        if tool_name == "recall":
            query = str(arguments.get("query", ""))
            text = "Cedar Loft invoice" if "invoice" in query.lower() else "Harbor ship Friday"
            return {"ok": True, "text": text, "raw": {}}
        if tool_name == "stats":
            return {
                "ok": True,
                "text": json.dumps({
                    "vectorSearchEnabled": True,
                    "queryEmbeddingAvailable": True,
                    "embedder": {"model": "minilm"},
                    "frameCount": 3,
                }),
                "raw": {},
            }
        return {"ok": True, "text": json.dumps({"ok": True}), "raw": {}}

    def close(self) -> None:
        self.closed = True

    def tools_called(self) -> list[str]:
        return [name for name, _ in self.calls]

    def last_args(self, tool_name: str) -> dict:
        for name, args in reversed(self.calls):
            if name == tool_name:
                return args
        raise AssertionError(f"{tool_name} was not called")


def _provider(client: FakeClient | None = None, **env) -> plugin.WaxMemoryProvider:
    client = client or FakeClient()
    with mock.patch.dict(os.environ, env, clear=False):
        provider = plugin.WaxMemoryProvider(client=client)
    provider._client = client
    return provider


class ConfigResolutionTests(unittest.TestCase):
    def test_env_endpoint_wins_over_config_file(self) -> None:
        with tempfile.TemporaryDirectory() as home:
            path = Path(home) / "wax-memory.json"
            path.write_text(json.dumps({"endpoint": "http://file.example/mcp"}), encoding="utf-8")
            with mock.patch.dict(os.environ, {"WAX_MCP_HTTP_ENDPOINT": "http://env.example/mcp"}):
                cfg = plugin.load_plugin_config(home)
                self.assertEqual(plugin.resolve_endpoint(cfg), "http://env.example/mcp")

    def test_config_file_used_when_env_absent(self) -> None:
        with tempfile.TemporaryDirectory() as home:
            path = Path(home) / "wax-memory.json"
            path.write_text(json.dumps({"endpoint": "http://file.example/mcp/"}), encoding="utf-8")
            with mock.patch.dict(os.environ, {}, clear=False):
                os.environ.pop("WAX_MCP_HTTP_ENDPOINT", None)
                cfg = plugin.load_plugin_config(home)
            self.assertEqual(plugin.resolve_endpoint(cfg), "http://file.example/mcp")


class AvailabilityTests(unittest.TestCase):
    def test_is_available_does_not_call_mcp(self) -> None:
        client = FakeClient()
        provider = _provider(client)
        self.assertTrue(provider.is_available())
        self.assertEqual(client.calls, [])

    def test_is_available_without_injected_client_does_not_construct_probe(self) -> None:
        with mock.patch.object(plugin, "_HAS_HTTP", True), mock.patch.object(
            plugin, "_WaxHTTPClient"
        ) as http_cls, mock.patch.object(plugin, "_WaxMCPManager") as mgr_cls:
            provider = plugin.WaxMemoryProvider()
            self.assertTrue(provider.is_available())
            http_cls.return_value.call_tool.assert_not_called()
            mgr_cls.return_value.probe.assert_not_called()

    def test_unavailable_reason_when_http_stack_missing(self) -> None:
        with mock.patch.object(plugin, "_HAS_HTTP", False):
            provider = plugin.WaxMemoryProvider()
            self.assertFalse(provider.is_available())
            self.assertIn("requests", provider.unavailable_reason())


class SessionLifecycleTests(unittest.TestCase):
    def test_initialize_starts_wax_session(self) -> None:
        client = FakeClient()
        provider = _provider(client)
        provider.initialize("hermes-sess", hermes_home="/tmp/hermes", platform="cli")
        self.assertEqual(client.tools_called(), ["session_start"])
        self.assertEqual(client.last_args("session_start")["session_id"], "hermes-sess")
        self.assertEqual(client.last_args("session_start")["agent_id"], "hermes-cli")

    def test_initialize_skips_non_primary_context(self) -> None:
        client = FakeClient()
        provider = _provider(client)
        provider.initialize("hermes-sess", agent_context="cron", platform="cron")
        self.assertEqual(client.calls, [])

    def test_session_switch_resumes_new_id(self) -> None:
        client = FakeClient()
        provider = _provider(client)
        provider.initialize("old-sess", platform="cli")
        provider.on_session_switch("new-sess", parent_session_id="old-sess", reset=False)
        self.assertIn("session_resume", client.tools_called())
        self.assertEqual(provider._session_id, "new-sess")

    def test_session_switch_reset_ends_then_starts(self) -> None:
        client = FakeClient()
        provider = _provider(client)
        provider.initialize("old-sess", platform="cli")
        provider.on_session_switch("new-sess", parent_session_id="old-sess", reset=True)
        self.assertEqual(
            [name for name in client.tools_called() if name.startswith("session_")],
            ["session_start", "session_end", "session_start"],
        )

    def test_session_end_synthesizes_then_handoff(self) -> None:
        client = FakeClient()
        provider = _provider(client)
        provider.initialize("sess-1", platform="cli")
        provider.on_session_end([{"role": "user", "content": "Ship Friday"}])
        tools = client.tools_called()
        self.assertIn("session_synthesize", tools)
        self.assertIn("handoff", tools)
        self.assertIn("session_end", tools)
        self.assertIn("Synthesized Harbor handoff", client.last_args("handoff")["content"])
        self.assertTrue(client.closed)

    def test_session_end_waits_for_inflight_remember_before_close(self) -> None:
        started = threading.Event()
        release = threading.Event()
        order: list[str] = []
        client = FakeClient()
        orig = client.call_tool

        def slow(tool_name: str, arguments: dict) -> dict:
            if tool_name == "remember":
                order.append("remember-start")
                started.set()
                self.assertTrue(release.wait(2), "remember was not released")
                order.append("remember-done")
            elif tool_name == "session_end":
                order.append("session_end")
            return orig(tool_name, arguments)

        client.call_tool = slow  # type: ignore[method-assign]
        provider = _provider(client)
        provider.initialize("sess-1", platform="cli")
        provider.sync_turn("What is the dock code?", "4412", session_id="sess-1")
        self.assertTrue(started.wait(1), "remember never started")

        ended = threading.Event()

        def end_session() -> None:
            provider.on_session_end([])
            order.append("on_session_end-returned")
            ended.set()

        worker = threading.Thread(target=end_session)
        worker.start()
        time.sleep(0.05)
        self.assertNotIn("session_end", order)
        self.assertFalse(client.closed)
        release.set()
        self.assertTrue(ended.wait(2), "on_session_end did not finish")
        worker.join(timeout=2)
        self.assertIn("remember-done", order)
        self.assertIn("session_end", order)
        self.assertLess(order.index("remember-done"), order.index("session_end"))
        self.assertTrue(client.closed)


class ToolRoutingTests(unittest.TestCase):
    def test_core_tools_do_not_include_session_lifecycle(self) -> None:
        names = {schema["name"] for schema in _provider().get_tool_schemas()}
        self.assertIn("wax_remember", names)
        self.assertIn("wax_recall", names)
        self.assertNotIn("wax_session_start", names)
        self.assertNotIn("wax_compact_context", names)

    def test_structured_tools_on_by_default(self) -> None:
        names = {schema["name"] for schema in _provider().get_tool_schemas()}
        self.assertIn("wax_entity_upsert", names)
        self.assertIn("wax_facts_query", names)

    def test_remember_memory_type_matches_wax_mcp(self) -> None:
        remember = next(
            schema for schema in _provider().get_tool_schemas() if schema["name"] == "wax_remember"
        )
        self.assertEqual(
            remember["parameters"]["properties"]["memory_type"]["enum"],
            plugin.WAX_MEMORY_TYPES,
        )

    def test_handle_tool_call_does_not_inject_session_id_into_handoff_latest(self) -> None:
        client = FakeClient()
        provider = _provider(client)
        provider.initialize("sess-1", platform="cli")
        provider.handle_tool_call("wax_handoff_latest", {"project": "Wax"})
        self.assertNotIn("session_id", client.last_args("handoff_latest"))

    def test_handle_tool_call_injects_session_id_into_remember(self) -> None:
        client = FakeClient()
        provider = _provider(client)
        provider.initialize("sess-1", platform="cli")
        provider.handle_tool_call("wax_remember", {"content": "Dock code is 4412"})
        self.assertEqual(client.last_args("remember")["session_id"], "sess-1")

    def test_handle_tool_call_returns_tool_text_not_envelope(self) -> None:
        client = FakeClient()
        client.responses["stats"] = {"ok": True, "text": '{"frameCount": 3}', "raw": {}}
        provider = _provider(client)
        result = provider.handle_tool_call("wax_stats", {})
        self.assertEqual(result, '{"frameCount": 3}')

    def test_handle_tool_call_error_is_json(self) -> None:
        client = FakeClient()

        def boom(tool_name: str, arguments: dict) -> dict:
            raise plugin.WaxMCPError("broker down")

        client.call_tool = boom  # type: ignore[method-assign]
        provider = _provider(client)
        payload = json.loads(provider.handle_tool_call("wax_stats", {}))
        self.assertFalse(payload["ok"])
        self.assertIn("broker down", payload["error"])


class PrefetchAndSyncTests(unittest.TestCase):
    def test_prefetch_skips_trivial_prompts(self) -> None:
        client = FakeClient()
        provider = _provider(client)
        self.assertEqual(provider.prefetch("ok"), "")
        self.assertNotIn("recall", client.tools_called())

    def test_prefetch_returns_cached_queue_result(self) -> None:
        client = FakeClient()
        provider = _provider(client)
        provider.initialize("sess-1", platform="cli")
        provider.queue_prefetch("when do we ship", session_id="sess-1")
        deadline = time.time() + 2
        while time.time() < deadline and provider.recall_status() is None:
            time.sleep(0.01)
        text = provider.prefetch("when do we ship", session_id="sess-1")
        self.assertIn("Harbor ship Friday", text)
        status = provider.recall_status()
        self.assertIsNotNone(status)
        self.assertGreaterEqual(status.count, 1)

    def test_prefetch_does_not_return_stale_query_cache(self) -> None:
        client = FakeClient()
        provider = _provider(client)
        provider.initialize("sess-1", platform="cli")
        provider._set_prefetch("when do we ship", "Harbor ship Friday")
        text = provider.prefetch("invoice total for Cedar Loft", session_id="sess-1")
        self.assertIn("Cedar Loft invoice", text)
        self.assertNotIn("Harbor ship Friday", text)

    def test_sync_turn_skips_internal_gateway_noise(self) -> None:
        client = FakeClient()
        provider = _provider(client)
        provider.initialize("sess-1", platform="cli")
        provider.sync_turn("[CONTEXT COMPACTION] trimmed", "ok", session_id="sess-1")
        provider._join_background()
        self.assertNotIn("remember", client.tools_called())

    def test_sync_turn_stores_working_note(self) -> None:
        client = FakeClient()
        provider = _provider(client)
        provider.initialize("sess-1", platform="cli")
        provider.sync_turn("What is the dock code?", "4412", session_id="sess-1")
        provider._join_background()
        args = client.last_args("remember")
        self.assertEqual(args["memory_type"], "note")
        self.assertEqual(args["durability"], "working")

    def test_sync_turn_returns_before_remember_completes(self) -> None:
        started = threading.Event()
        release = threading.Event()
        client = FakeClient()
        orig = client.call_tool

        def slow(tool_name: str, arguments: dict) -> dict:
            if tool_name == "remember":
                started.set()
                self.assertTrue(release.wait(2), "remember was not released")
            return orig(tool_name, arguments)

        client.call_tool = slow  # type: ignore[method-assign]
        provider = _provider(client)
        provider.initialize("sess-1", platform="cli")
        started_at = time.time()
        provider.sync_turn("What is the dock code?", "4412", session_id="sess-1")
        self.assertLess(time.time() - started_at, 0.5)
        self.assertTrue(started.wait(1), "remember never started")
        release.set()
        provider._join_background()
        self.assertEqual(client.last_args("remember")["memory_type"], "note")

    def test_prefetch_does_not_publish_after_session_switch(self) -> None:
        started = threading.Event()
        release = threading.Event()
        client = FakeClient()
        orig = client.call_tool

        def slow(tool_name: str, arguments: dict) -> dict:
            if tool_name == "recall" and arguments.get("session_id") == "old-sess":
                started.set()
                self.assertTrue(release.wait(2), "old recall was not released")
                return {"ok": True, "text": "OLD SESSION CONTEXT", "raw": {}}
            return orig(tool_name, arguments)

        client.call_tool = slow  # type: ignore[method-assign]
        provider = _provider(client)
        provider.initialize("old-sess", platform="cli")
        provider.queue_prefetch("invoice total", session_id="old-sess")
        self.assertTrue(started.wait(1), "old recall never started")
        provider.on_session_switch("new-sess", parent_session_id="old-sess")
        release.set()
        provider._join_background()
        self.assertIsNone(provider.recall_status())
        self.assertNotIn("OLD SESSION CONTEXT", provider.prefetch("invoice total", session_id="new-sess"))


class MemoryWriteAndBackupTests(unittest.TestCase):
    def test_memory_write_mirrors_user_preference(self) -> None:
        client = FakeClient()
        provider = _provider(client)
        provider.initialize("sess-1", platform="cli")
        provider.on_memory_write("add", "user", "Prefers Swift over Java")
        provider._join_background()
        args = client.last_args("remember")
        self.assertEqual(args["memory_type"], "user_preference")
        self.assertEqual(args["content"], "Prefers Swift over Java")

    def test_backup_paths_include_store_override(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            store = Path(tmp) / "memory.wax"
            store.write_text("x", encoding="utf-8")
            with mock.patch.dict(os.environ, {"WAX_STORE_PATH": str(store)}):
                paths = _provider().backup_paths()
            self.assertIn(str(store), paths)


class PackagingTests(unittest.TestCase):
    def test_entry_point_uses_memory_providers_group(self) -> None:
        text = (PLUGIN_DIR / "pyproject.toml").read_text(encoding="utf-8")
        self.assertIn('hermes_agent.memory_providers', text)
        self.assertIn('wax-memory = "hermes_wax_memory:register"', text)

    def test_plugin_yaml_declares_session_hooks(self) -> None:
        text = (PLUGIN_DIR / "plugin.yaml").read_text(encoding="utf-8")
        self.assertIn("on_session_end", text)
        self.assertIn("on_session_switch", text)

    def test_register_binds_memory_provider(self) -> None:
        bound: list[object] = []

        class Ctx:
            def register_memory_provider(self, provider: object) -> None:
                bound.append(provider)

        plugin.register(Ctx())
        self.assertEqual(len(bound), 1)
        self.assertIsInstance(bound[0], plugin.WaxMemoryProvider)

    def test_requests_is_the_only_http_stack(self) -> None:
        source = (PLUGIN_DIR / "hermes_wax_memory.py").read_text(encoding="utf-8")
        self.assertNotIn("import httpx", source)
        self.assertNotIn("urllib.request", source)
        self.assertFalse(hasattr(plugin, "_HAS_HTTPX"))


if __name__ == "__main__":
    unittest.main()
