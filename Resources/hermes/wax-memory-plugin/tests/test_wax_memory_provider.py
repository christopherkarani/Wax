"""Behavioral tests for the Wax Hermes MemoryProvider.

Seam: WaxMemoryProvider public Hermes contract + injected MCP client.
"""

from __future__ import annotations

import json
import io
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import uuid
from argparse import Namespace
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock

PLUGIN_DIR = Path(__file__).resolve().parents[1]
HERMES_PYTHON = Path.home() / ".hermes" / "hermes-agent" / "venv" / "bin" / "python"
if str(PLUGIN_DIR) not in sys.path:
    sys.path.insert(0, str(PLUGIN_DIR))

import hermes_wax_memory as plugin  # noqa: E402
import cli as plugin_cli  # noqa: E402


WAX_SESSION_ID = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"
WAX_SESSION_ID_2 = "BBBBBBBB-CCCC-4DDD-8EEE-FFFFFFFFFFFF"


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
        if tool_name == "session_open":
            opened_id = (
                WAX_SESSION_ID_2
                if arguments.get("conversation_id") == "new-sess"
                else WAX_SESSION_ID
            )
            return {
                "ok": True,
                "text": json.dumps({"session_id": opened_id}),
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


def _run_isolated(script: str, *args: str) -> subprocess.CompletedProcess[str]:
    """Load plugin code in a fresh interpreter without this test's sys.path."""
    return subprocess.run(
        [sys.executable, "-I", "-c", script, *[str(arg) for arg in args]],
        capture_output=True,
        text=True,
        check=False,
    )


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

    def test_hermes_yaml_wax_memory_auto_start_used_when_json_missing(self) -> None:
        with tempfile.TemporaryDirectory() as home:
            (Path(home) / "config.yaml").write_text(
                "memory:\n  provider: wax-memory\nwax_memory:\n  endpoint: http://127.0.0.1:3000/mcp\n  auto_start: true\n",
                encoding="utf-8",
            )
            cfg = plugin.load_plugin_config(home)
            self.assertTrue(plugin._truthy(cfg.get("auto_start"), False))
            self.assertEqual(plugin.resolve_endpoint(cfg), "http://127.0.0.1:3000/mcp")
            provider = plugin.WaxMemoryProvider(config=cfg)
            self.assertTrue(provider.auto_start_enabled())

    def test_json_auto_start_overrides_hermes_yaml(self) -> None:
        with tempfile.TemporaryDirectory() as home:
            (Path(home) / "config.yaml").write_text(
                "wax_memory:\n  auto_start: true\n",
                encoding="utf-8",
            )
            (Path(home) / "wax-memory.json").write_text(
                json.dumps({"auto_start": False}),
                encoding="utf-8",
            )
            cfg = plugin.load_plugin_config(home)
            provider = plugin.WaxMemoryProvider(config=cfg)
            self.assertFalse(provider.auto_start_enabled())


class AutoStartTests(unittest.TestCase):
    class Process:
        def __init__(self, *, exit_code=None, wait_fails=False) -> None:
            self.exit_code = exit_code
            self.wait_fails = wait_fails
            self.terminated = False
            self.killed = False
            self.wait_calls = 0

        def poll(self):
            return self.exit_code

        def terminate(self) -> None:
            self.terminated = True

        def kill(self) -> None:
            self.killed = True
            self.wait_fails = False

        def wait(self, timeout=None):
            self.wait_calls += 1
            if self.wait_fails:
                raise subprocess.TimeoutExpired("wax-mcp", timeout)
            return self.exit_code or 0

    def test_auto_start_refuses_non_loopback_endpoint(self) -> None:
        manager = plugin._WaxMCPManager("http://memory.example:3000/mcp")
        with mock.patch.object(manager, "probe", return_value={"reachable": False}), mock.patch.object(
            manager, "_find_wax_mcp_binary", return_value="/tmp/wax-mcp"
        ), mock.patch.object(plugin.subprocess, "Popen") as popen:
            self.assertFalse(manager.auto_start(timeout=0))
        popen.assert_not_called()

    def test_auto_start_refuses_https_endpoint(self) -> None:
        manager = plugin._WaxMCPManager("https://localhost:3000/mcp")
        with mock.patch.object(manager, "probe", return_value={"reachable": False}), mock.patch.object(
            manager, "_find_wax_mcp_binary", return_value="/tmp/wax-mcp"
        ), mock.patch.object(plugin.subprocess, "Popen") as popen:
            self.assertFalse(manager.auto_start(timeout=0))
        popen.assert_not_called()

    def test_auto_start_forwards_custom_endpoint_path(self) -> None:
        manager = plugin._WaxMCPManager("http://127.0.0.1:4111/custom/mcp")
        process = self.Process()
        probes = iter(({"reachable": False}, {"reachable": True}))
        with mock.patch.object(manager, "probe", side_effect=lambda: next(probes)), mock.patch.object(
            manager, "_find_wax_mcp_binary", return_value="/tmp/wax-mcp"
        ), mock.patch.object(plugin.subprocess, "Popen", return_value=process) as popen, mock.patch.object(
            plugin.time, "sleep", return_value=None
        ):
            self.assertTrue(manager.auto_start(timeout=1))
        command = popen.call_args.args[0]
        self.assertEqual(command[command.index("--http-endpoint") + 1], "/custom/mcp")

    def test_auto_start_reaps_child_that_exits_before_probe_succeeds(self) -> None:
        manager = plugin._WaxMCPManager("http://127.0.0.1:3000/mcp")
        process = self.Process(exit_code=78)
        with mock.patch.object(manager, "probe", return_value={"reachable": False}), mock.patch.object(
            manager, "_find_wax_mcp_binary", return_value="/tmp/wax-mcp"
        ), mock.patch.object(plugin.subprocess, "Popen", return_value=process), mock.patch.object(
            plugin.time, "sleep", return_value=None
        ):
            self.assertFalse(manager.auto_start(timeout=1))
        self.assertGreaterEqual(process.wait_calls, 1)
        self.assertIsNone(manager._process)

    def test_auto_start_terminates_and_kills_child_after_timeout(self) -> None:
        manager = plugin._WaxMCPManager("http://localhost:3000/mcp")
        process = self.Process(wait_fails=True)
        with mock.patch.object(manager, "probe", return_value={"reachable": False}), mock.patch.object(
            manager, "_find_wax_mcp_binary", return_value="/tmp/wax-mcp"
        ), mock.patch.object(plugin.subprocess, "Popen", return_value=process):
            self.assertFalse(manager.auto_start(timeout=0))
        self.assertTrue(process.terminated)
        self.assertTrue(process.killed)
        self.assertGreaterEqual(process.wait_calls, 2)
        self.assertIsNone(manager._process)


class DiagnosticsTests(unittest.TestCase):
    def test_probe_requires_vector_index_and_query_embedding(self) -> None:
        for vector_enabled, query_available in ((True, False), (False, True)):
            with self.subTest(vector_enabled=vector_enabled, query_available=query_available):
                client = FakeClient()
                client.responses["stats"] = {
                    "ok": True,
                    "text": json.dumps({
                        "vectorSearchEnabled": vector_enabled,
                        "queryEmbeddingAvailable": query_available,
                        "embeddingStatus": "degraded",
                        "embeddingStatusReason": "query circuit open",
                        "framesWithoutVectors": 7,
                    }),
                    "raw": {},
                }
                with mock.patch.object(plugin, "_WaxHTTPClient", return_value=client):
                    info = plugin._WaxMCPManager(plugin.DEFAULT_ENDPOINT).probe()
                self.assertFalse(info["vector_search_enabled"])
                self.assertEqual(info["query_embedding_available"], query_available)
                self.assertEqual(info["embedding_status"], "degraded")
                self.assertEqual(info["embedding_status_reason"], "query circuit open")
                self.assertEqual(info["frames_without_vectors"], 7)
                self.assertTrue(client.closed)

    def test_system_prompt_offers_hybrid_only_when_query_embedding_is_available(self) -> None:
        client = FakeClient()
        provider = plugin.WaxMemoryProvider()
        provider._client = client
        provider._manager.probe = lambda: {
            "reachable": True,
            "vector_search_enabled": False,
            "query_embedding_available": False,
        }
        provider.initialize("sess-1", platform="cli")
        self.assertIn("with text search", provider.system_prompt_block())
        self.assertNotIn("vector, and hybrid", provider.system_prompt_block())


class CLIDoctorTests(unittest.TestCase):
    class Parser:
        def __init__(self) -> None:
            self.defaults = {}

        def add_subparsers(self, **kwargs):
            return self

        def add_parser(self, *args, **kwargs):
            return self

        def set_defaults(self, **kwargs) -> None:
            self.defaults.update(kwargs)

    @staticmethod
    def provider(info: dict):
        instance = mock.Mock()
        instance.name = "wax-memory"
        instance.is_available.return_value = True
        instance.unavailable_reason.return_value = ""
        instance.auto_start_enabled.return_value = False
        instance.structured_memory_enabled.return_value = True
        instance.probe_broker.return_value = info
        instance.diagnose_vector_search.return_value = "diagnostic"
        return instance

    def _dispatch(self, info: dict, hermes_home: str) -> None:
        parser = self.Parser()
        plugin_cli.register_cli(parser)
        args = Namespace(wax_memory_command="doctor", hermes_home=hermes_home)
        with mock.patch.object(plugin_cli, "WaxMemoryProvider", return_value=self.provider(info)):
            with redirect_stdout(io.StringIO()):
                parser.defaults["func"](args)

    def test_doctor_exits_nonzero_when_broker_is_unreachable(self) -> None:
        with tempfile.TemporaryDirectory() as home:
            with self.assertRaises(SystemExit) as raised:
                self._dispatch({"reachable": False}, home)
        self.assertNotEqual(raised.exception.code, 0)

    def test_doctor_exits_nonzero_when_query_embedding_is_unavailable(self) -> None:
        info = {
            "reachable": True,
            "vector_search_enabled": False,
            "query_embedding_available": False,
            "embedding_status": "degraded",
            "embedding_status_reason": "query circuit open",
            "frames_without_vectors": 4,
        }
        with tempfile.TemporaryDirectory() as home:
            with self.assertRaises(SystemExit) as raised:
                self._dispatch(info, home)
        self.assertNotEqual(raised.exception.code, 0)

    def test_doctor_fails_duplicate_native_and_generic_mcp_surfaces(self) -> None:
        config = """memory:\n  provider: wax-memory\nmcp_servers:\n  wax:\n    url: http://127.0.0.1:3000/mcp\n"""
        info = {"reachable": True, "vector_search_enabled": True, "query_embedding_available": True}
        with tempfile.TemporaryDirectory() as home:
            (Path(home) / "config.yaml").write_text(config, encoding="utf-8")
            with self.assertRaises(SystemExit) as raised:
                self._dispatch(info, home)
        self.assertNotEqual(raised.exception.code, 0)

    def test_doctor_fails_duplicate_plugins_enabled_entry(self) -> None:
        config = """memory:\n  provider: wax-memory\nplugins:\n  enabled: [wax-memory, other]\n"""
        info = {"reachable": True, "vector_search_enabled": True, "query_embedding_available": True}
        with tempfile.TemporaryDirectory() as home:
            (Path(home) / "config.yaml").write_text(config, encoding="utf-8")
            with self.assertRaises(SystemExit) as raised:
                self._dispatch(info, home)
        self.assertNotEqual(raised.exception.code, 0)

    def test_doctor_ignores_commented_out_plugin_entry(self) -> None:
        config = """memory:\n  provider: wax-memory\nplugins:\n  enabled:\n    # - wax-memory\n    - other\n"""
        info = {"reachable": True, "vector_search_enabled": True, "query_embedding_available": True}
        with tempfile.TemporaryDirectory() as home:
            (Path(home) / "config.yaml").write_text(config, encoding="utf-8")
            self._dispatch(info, home)

    def test_doctor_ignores_nested_fallback_provider(self) -> None:
        config = """memory:\n  fallback:\n    provider: wax-memory\nmcp_servers:\n  wax:\n    url: http://127.0.0.1:3000/mcp\nplugins:\n  enabled: [other]\n"""
        info = {"reachable": True, "vector_search_enabled": True, "query_embedding_available": True}
        with tempfile.TemporaryDirectory() as home:
            (Path(home) / "config.yaml").write_text(config, encoding="utf-8")
            self._dispatch(info, home)

    def test_doctor_detects_quoted_and_flow_style_duplicate_config(self) -> None:
        config = """\"memory\": {provider: wax-memory}\n'mcp_servers': {wax: {url: http://127.0.0.1:3000/mcp}}\n"""
        info = {"reachable": True, "vector_search_enabled": True, "query_embedding_available": True}
        with tempfile.TemporaryDirectory() as home:
            (Path(home) / "config.yaml").write_text(config, encoding="utf-8")
            with self.assertRaises(SystemExit) as raised:
                self._dispatch(info, home)
        self.assertNotEqual(raised.exception.code, 0)


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
    def test_initialize_opens_wax_session_without_forwarding_host_id_as_uuid(self) -> None:
        client = FakeClient()
        provider = _provider(client)
        provider.initialize("hermes-sess", hermes_home="/tmp/hermes", platform="cli")
        self.assertEqual(client.tools_called(), ["session_open"])
        opened = client.last_args("session_open")
        self.assertNotIn("session_id", opened)
        self.assertEqual(opened["conversation_id"], "hermes-sess")
        self.assertEqual(opened["run_id"], "hermes-sess")
        self.assertEqual(opened["agent_id"], "hermes-cli:hermes-sess")
        self.assertEqual(opened["cwd"], os.getcwd())
        self.assertEqual(provider._session_id, WAX_SESSION_ID)
        self.assertIsNotNone(uuid.UUID(provider._session_id))

    def test_initialize_forwards_explicit_cwd_to_session_open(self) -> None:
        client = FakeClient()
        provider = _provider(client)
        provider.initialize("hermes-sess", cwd="/tmp/wax-dx-cwd-project", platform="cli")
        opened = client.last_args("session_open")
        self.assertEqual(opened["cwd"], "/tmp/wax-dx-cwd-project")
        self.assertEqual(opened["conversation_id"], "hermes-sess")

    def test_failed_session_open_fails_closed_without_unscoped_remember(self) -> None:
        client = FakeClient()
        client.responses["session_open"] = {
            "ok": False,
            "text": "broker unavailable",
            "raw": {},
        }
        provider = _provider(client)
        provider.initialize("hermes-sess", platform="cli")
        result = json.loads(provider.handle_tool_call("wax_remember", {"content": "Dock code is 4412"}))
        self.assertIsNone(provider._session_id)
        self.assertFalse(result["ok"])
        self.assertTrue(result["retryable"])
        self.assertEqual(client.tools_called(), ["session_open", "session_open"])

    def test_tool_call_lazily_recovers_after_transient_session_open_failure(self) -> None:
        client = FakeClient()
        original = client.call_tool
        attempts = 0

        def fail_once(tool_name: str, arguments: dict) -> dict:
            nonlocal attempts
            if tool_name == "session_open":
                attempts += 1
                if attempts == 1:
                    return {"ok": False, "text": "temporary failure", "raw": {}}
            return original(tool_name, arguments)

        client.call_tool = fail_once  # type: ignore[method-assign]
        provider = _provider(client)
        provider.initialize("sess-1", platform="cli")
        self.assertIsNone(provider._session_id)
        provider.handle_tool_call("wax_recall", {"query": "dock code"})
        self.assertEqual(provider._session_id, WAX_SESSION_ID)
        self.assertEqual(client.last_args("recall")["session_id"], WAX_SESSION_ID)

    def test_auto_start_discovers_staged_install_runtime(self) -> None:
        client = FakeClient()
        provider = _provider(client)
        with tempfile.TemporaryDirectory() as install_root:
            machine = plugin.platform.machine().lower()
            architecture = {
                "aarch64": "arm64",
                "arm64": "arm64",
                "amd64": "x64",
                "x86_64": "x64",
            }.get(machine, machine)
            binary = os.path.join(
                install_root,
                "runtime",
                f"{plugin.platform.system().lower()}-{architecture}",
                "wax-mcp",
            )
            os.makedirs(os.path.dirname(binary))
            Path(binary).write_text("#!/bin/sh\n", encoding="utf-8")
            os.chmod(binary, 0o755)
            with mock.patch.dict(os.environ, {"WAX_MCP_INSTALL_ROOT": install_root}, clear=False):
                self.assertEqual(provider._manager._find_wax_mcp_binary(), binary)

    def test_on_memory_write_skips_when_session_unavailable(self) -> None:
        client = FakeClient()
        client.responses["session_open"] = {"ok": False, "text": "offline", "raw": {}}
        provider = _provider(client)
        provider.initialize("offline-chat", platform="cli")
        provider.on_memory_write("add", "user", "Prefers safe defaults")
        self.assertEqual(client.tools_called(), ["session_open", "session_open"])

    def test_initialize_skips_non_primary_context(self) -> None:
        client = FakeClient()
        provider = _provider(client)
        provider.initialize("hermes-sess", agent_context="cron", platform="cron")
        self.assertEqual(client.calls, [])

    def test_session_switch_opens_by_host_conversation_id(self) -> None:
        client = FakeClient()
        provider = _provider(client)
        provider.initialize("old-sess", platform="cli")
        provider.on_session_switch("new-sess", parent_session_id="old-sess", reset=False)
        self.assertEqual(client.tools_called(), ["session_open", "session_open"])
        opened = client.last_args("session_open")
        self.assertEqual(opened["conversation_id"], "new-sess")
        self.assertNotIn("session_id", opened)
        self.assertEqual(provider._session_id, WAX_SESSION_ID_2)

    def test_session_switch_clears_stale_project_context(self) -> None:
        client = FakeClient()
        provider = _provider(client)
        provider.initialize("old-sess", platform="cli", project="OldProject", repo="OldRepo")
        provider.on_session_switch("new-sess", parent_session_id="old-sess")
        opened = client.last_args("session_open")
        self.assertNotIn("project", opened)
        self.assertNotIn("repo", opened)

    def test_session_switch_reset_ends_then_starts(self) -> None:
        client = FakeClient()
        provider = _provider(client)
        provider.initialize("old-sess", platform="cli")
        provider.on_session_switch("new-sess", parent_session_id="old-sess", reset=True)
        self.assertEqual(
            [name for name in client.tools_called() if name.startswith("session_")],
            ["session_open", "session_end", "session_open"],
        )

    def test_session_switch_drains_old_write_before_installing_new_session(self) -> None:
        started = threading.Event()
        release = threading.Event()
        switched = threading.Event()
        captured: list[str] = []
        client = FakeClient()
        original = client.call_tool

        def slow(tool_name: str, arguments: dict) -> dict:
            if tool_name == "remember":
                captured.append(arguments.get("session_id", ""))
                started.set()
                self.assertTrue(release.wait(5), "old write was not released")
            return original(tool_name, arguments)

        client.call_tool = slow  # type: ignore[method-assign]
        provider = _provider(client)
        provider.initialize("old-sess", platform="cli")
        provider.sync_turn("Remember the old chat", "Saved", session_id="old-sess")
        self.assertTrue(started.wait(1), "old write did not start")

        worker = threading.Thread(
            target=lambda: (
                provider.on_session_switch("new-sess", parent_session_id="old-sess"),
                switched.set(),
            )
        )
        worker.start()
        self.assertFalse(switched.wait(0.1), "switch raced the in-flight old write")
        release.set()
        worker.join(timeout=2)
        self.assertTrue(switched.is_set())
        self.assertEqual(captured, [WAX_SESSION_ID])
        self.assertEqual(provider._session_id, WAX_SESSION_ID_2)

    def test_shutdown_serializes_with_session_switch(self) -> None:
        switch_started = threading.Event()
        release_switch = threading.Event()
        client = FakeClient()
        original = client.call_tool

        def block_new_open(tool_name: str, arguments: dict) -> dict:
            if tool_name == "session_open" and arguments.get("conversation_id") == "new-sess":
                switch_started.set()
                self.assertTrue(release_switch.wait(2), "switch was not released")
            return original(tool_name, arguments)

        client.call_tool = block_new_open  # type: ignore[method-assign]
        provider = _provider(client)
        provider.initialize("old-sess", platform="cli")
        switch = threading.Thread(target=provider.on_session_switch, args=("new-sess",))
        switch.start()
        self.assertTrue(switch_started.wait(1), "session switch never reached new open")
        shutdown = threading.Thread(target=provider.shutdown)
        shutdown.start()
        release_switch.set()
        switch.join(2)
        shutdown.join(2)
        self.assertFalse(switch.is_alive())
        self.assertFalse(shutdown.is_alive())
        self.assertIsNone(provider._session_id)
        self.assertFalse(provider._accepting_background)
        self.assertEqual(client.last_args("session_end")["session_id"], WAX_SESSION_ID_2)

    def test_non_primary_initialize_cannot_reenable_admission_during_switch(self) -> None:
        switch_started = threading.Event()
        release_switch = threading.Event()
        client = FakeClient()
        original = client.call_tool

        def block_new_open(tool_name: str, arguments: dict) -> dict:
            if tool_name == "session_open" and arguments.get("conversation_id") == "new-sess":
                switch_started.set()
                self.assertTrue(release_switch.wait(2), "switch was not released")
            return original(tool_name, arguments)

        client.call_tool = block_new_open  # type: ignore[method-assign]
        provider = _provider(client)
        provider.initialize("old-sess", platform="cli")
        switch = threading.Thread(target=provider.on_session_switch, args=("new-sess",))
        switch.start()
        self.assertTrue(switch_started.wait(1), "session switch never reached new open")
        provider.initialize("cron-sess", agent_context="cron", platform="cron")
        provider.on_memory_write("add", "user", "Must not reach the old session")
        self.assertNotIn("remember", client.tools_called())
        self.assertFalse(provider._accepting_background)
        release_switch.set()
        switch.join(2)
        self.assertFalse(switch.is_alive())
        self.assertEqual(provider._session_id, WAX_SESSION_ID_2)

    def test_primary_reinitialize_keeps_admission_closed_until_new_session_opens(self) -> None:
        initialize_started = threading.Event()
        release_initialize = threading.Event()
        client = FakeClient()
        original = client.call_tool

        def block_new_open(tool_name: str, arguments: dict) -> dict:
            if tool_name == "session_open" and arguments.get("conversation_id") == "new-sess":
                initialize_started.set()
                self.assertTrue(release_initialize.wait(2), "initialize was not released")
            return original(tool_name, arguments)

        client.call_tool = block_new_open  # type: ignore[method-assign]
        provider = _provider(client)
        provider.initialize("old-sess", platform="cli")
        initialize = threading.Thread(
            target=provider.initialize,
            args=("new-sess",),
            kwargs={"platform": "cli"},
        )
        initialize.start()
        self.assertTrue(initialize_started.wait(1), "initialize never reached new open")
        provider.on_memory_write("add", "user", "Must not reach the old session")
        self.assertNotIn("remember", client.tools_called())
        self.assertFalse(provider._accepting_background)
        release_initialize.set()
        initialize.join(2)
        self.assertFalse(initialize.is_alive())
        self.assertEqual(provider._session_id, WAX_SESSION_ID_2)

    def test_queued_reinitialize_closes_admission_before_transition_lock(self) -> None:
        client = FakeClient()
        provider = _provider(client)
        provider.initialize("old-sess", platform="cli")
        provider._transition_lock.acquire()
        initialize_started = threading.Event()

        def initialize() -> None:
            initialize_started.set()
            provider.initialize("new-sess", platform="cli")

        worker = threading.Thread(target=initialize)
        worker.start()
        self.assertTrue(initialize_started.wait(1))
        time.sleep(0.05)
        provider.on_memory_write("add", "user", "Must not enter the old session")
        self.assertNotIn("remember", client.tools_called())
        self.assertFalse(provider._accepting_background)
        provider._transition_lock.release()
        worker.join(2)
        self.assertFalse(worker.is_alive())

    def test_reinitialize_invalidates_cached_recall_from_previous_conversation(self) -> None:
        client = FakeClient()
        provider = _provider(client)
        provider.initialize("old-sess", platform="cli")
        provider._set_prefetch("same query", "OLD SESSION PRIVATE CONTEXT")
        provider.initialize("new-sess", platform="cli")
        recalled = provider.prefetch("same query")
        self.assertNotIn("OLD SESSION PRIVATE CONTEXT", recalled)
        self.assertIn("Harbor ship Friday", recalled)

    def test_endpoint_reconfiguration_closes_old_session_transport_and_process(self) -> None:
        old_client = FakeClient()
        new_client = FakeClient()
        old_manager = mock.Mock()
        new_manager = mock.Mock()
        old_manager.probe.return_value = {"reachable": True, "vector_search_enabled": True}
        new_manager.probe.return_value = {"reachable": True, "vector_search_enabled": True}
        with tempfile.TemporaryDirectory() as home:
            config_path = Path(home) / "wax-memory.json"
            config_path.write_text(json.dumps({"endpoint": "http://127.0.0.1:3000/mcp"}))
            with mock.patch.object(plugin, "_WaxHTTPClient", side_effect=[old_client, new_client]), mock.patch.object(
                plugin, "_WaxMCPManager", side_effect=[old_manager, new_manager]
            ):
                provider = plugin.WaxMemoryProvider()
                provider.initialize("old-sess", hermes_home=home, platform="cli")
                config_path.write_text(json.dumps({"endpoint": "http://localhost:4111/custom"}))
                provider.initialize("new-sess", hermes_home=home, platform="cli")
        self.assertEqual(old_client.last_args("session_end")["session_id"], WAX_SESSION_ID)
        self.assertTrue(old_client.closed)
        old_manager.shutdown.assert_called_once_with()
        self.assertIs(provider._client, new_client)
        self.assertIs(provider._manager, new_manager)

    def test_session_end_synthesizes_then_handoff(self) -> None:
        client = FakeClient()
        provider = _provider(client)
        provider.initialize("sess-1", platform="cli")
        provider.on_session_end([{"role": "user", "content": "Ship Friday"}])
        tools = client.tools_called()
        self.assertIn("session_synthesize", tools)
        self.assertIn("session_close", tools)
        self.assertNotIn("handoff", tools)
        self.assertNotIn("session_end", tools)
        self.assertIn("Synthesized Harbor handoff", client.last_args("session_close")["content"])
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
            elif tool_name == "session_close":
                order.append("session_close")
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
        self.assertIn("session_close", order)
        self.assertLess(order.index("remember-done"), order.index("session_close"))
        self.assertTrue(client.closed)

    def test_session_end_waits_past_old_two_second_timeout(self) -> None:
        started = threading.Event()
        release = threading.Event()
        ended = threading.Event()
        client = FakeClient()
        original = client.call_tool

        def slow(tool_name: str, arguments: dict) -> dict:
            if tool_name == "remember":
                started.set()
                self.assertTrue(release.wait(5), "remember was not released")
            return original(tool_name, arguments)

        client.call_tool = slow  # type: ignore[method-assign]
        provider = _provider(client)
        provider.initialize("sess-1", platform="cli")
        provider.sync_turn("Long write", "Still writing", session_id="sess-1")
        self.assertTrue(started.wait(1))
        worker = threading.Thread(target=lambda: (provider.on_session_end([]), ended.set()))
        worker.start()
        self.assertFalse(ended.wait(2.1), "session end returned before the write drained")
        self.assertNotIn("session_close", client.tools_called())
        release.set()
        worker.join(timeout=2)
        self.assertTrue(ended.is_set())
        self.assertIn("session_close", client.tools_called())

    def test_failed_switch_never_synthesizes_or_handoffs_previous_session(self) -> None:
        client = FakeClient()
        original = client.call_tool

        def fail_new(tool_name: str, arguments: dict) -> dict:
            if tool_name == "session_open" and arguments.get("conversation_id") == "new-sess":
                return {"ok": False, "text": "temporary failure", "raw": {}}
            return original(tool_name, arguments)

        client.call_tool = fail_new  # type: ignore[method-assign]
        provider = _provider(client)
        provider.initialize("old-sess", platform="cli")
        provider.on_session_switch("new-sess", parent_session_id="old-sess")
        self.assertIsNone(provider._session_id)
        before = len(client.calls)
        provider.on_session_end([{"role": "user", "content": "new chat content"}])
        later_tools = [name for name, _ in client.calls[before:]]
        self.assertNotIn("session_synthesize", later_tools)
        self.assertNotIn("handoff", later_tools)
        self.assertNotIn("session_close", later_tools)

    def test_failed_close_retains_recoverable_session_and_transport(self) -> None:
        client = FakeClient()
        client.responses["session_close"] = {
            "ok": False,
            "text": "temporary close failure",
            "raw": {},
        }
        provider = _provider(client)
        provider.initialize("sess-1", platform="cli")
        provider.on_session_end([{"role": "user", "content": "Ship Friday"}])
        self.assertEqual(provider._session_id, WAX_SESSION_ID)
        self.assertFalse(client.closed)
        self.assertTrue(provider._accepting_background)
        provider.handle_tool_call("wax_remember", {"content": "Dock code is 4412"})
        self.assertEqual(client.last_args("remember")["session_id"], WAX_SESSION_ID)

    def test_non_uuid_session_open_fails_closed_without_using_host_id(self) -> None:
        client = FakeClient()
        client.responses["session_open"] = {
            "ok": True,
            "text": json.dumps({"session_id": "hermes-opaque-conversation"}),
            "raw": {},
        }
        provider = _provider(client)
        provider.initialize("hermes-opaque-conversation", platform="cli")
        result = json.loads(
            provider.handle_tool_call("wax_remember", {"content": "Dock code is 4412"})
        )
        self.assertIsNone(provider._session_id)
        self.assertFalse(result["ok"])
        self.assertNotIn("remember", client.tools_called())
        for _name, args in client.calls:
            self.assertNotEqual(args.get("session_id"), "hermes-opaque-conversation")

    def test_teardown_drops_cached_recall_and_rejects_later_switch(self) -> None:
        client = FakeClient()
        provider = _provider(client)
        provider.initialize("old-sess", platform="cli")
        provider._set_prefetch("same query", "OLD SESSION PRIVATE CONTEXT")
        provider.shutdown()
        self.assertIsNone(provider.recall_status())
        self.assertEqual(provider.prefetch("same query"), "")
        self.assertIsNone(provider._session_id)
        self.assertFalse(provider._accepting_background)
        opens_before = client.tools_called().count("session_open")
        provider.on_session_switch("new-sess")
        self.assertIsNone(provider._session_id)
        self.assertEqual(client.tools_called().count("session_open"), opens_before)
        result = json.loads(
            provider.handle_tool_call("wax_remember", {"content": "must not persist"})
        )
        self.assertFalse(result["ok"])
        self.assertNotIn("remember", client.tools_called())

    def test_shutdown_reaps_auto_started_process(self) -> None:
        client = FakeClient()
        provider = _provider(client)
        process = AutoStartTests.Process()
        provider._manager._process = process
        provider._manager._auto_started = True
        provider.initialize("sess-1", platform="cli")
        provider.shutdown()
        self.assertTrue(process.terminated)
        self.assertGreaterEqual(process.wait_calls, 1)
        self.assertIsNone(provider._manager._process)
        self.assertFalse(provider._manager._auto_started)
        self.assertFalse(provider._accepting_background)

    def test_initialize_after_shutdown_recovers_without_stale_prefetch(self) -> None:
        client = FakeClient()
        provider = _provider(client)
        provider.initialize("old-sess", platform="cli")
        provider._set_prefetch("same query", "OLD SESSION PRIVATE CONTEXT")
        provider.shutdown()
        self.assertIsNone(provider.recall_status())
        provider.initialize("new-sess", platform="cli")
        self.assertEqual(provider._session_id, WAX_SESSION_ID_2)
        self.assertTrue(provider._accepting_background)
        recalled = provider.prefetch("same query")
        self.assertNotIn("OLD SESSION PRIVATE CONTEXT", recalled)
        self.assertIn("Harbor ship Friday", recalled)

    def test_native_remember_fails_closed_on_live_transport_outage(self) -> None:
        client = FakeClient()
        original = client.call_tool

        def outage(tool_name: str, arguments: dict) -> dict:
            if tool_name == "remember":
                raise plugin.WaxMCPError("connection refused")
            return original(tool_name, arguments)

        client.call_tool = outage  # type: ignore[method-assign]
        provider = _provider(client)
        provider.initialize("sess-1", platform="cli")
        result = json.loads(
            provider.handle_tool_call("wax_remember", {"content": "Dock code is 4412"})
        )
        self.assertFalse(result["ok"])
        self.assertIn("connection refused", result["error"])
        self.assertNotIn("remember", client.tools_called())


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

    def test_handle_tool_call_does_not_inject_session_id_into_unscoped_read_tools(self) -> None:
        client = FakeClient()
        provider = _provider(client, WAX_HERMES_EXTENDED_TOOLS="1")
        provider.initialize("sess-1", platform="cli")
        provider.handle_tool_call("wax_memory_get", {"memory_id": "durable:1"})
        provider.handle_tool_call("wax_corpus_search", {"query": "agent dx"})
        self.assertNotIn("session_id", client.last_args("memory_get"))
        self.assertNotIn("session_id", client.last_args("corpus_search"))

    def test_handle_tool_call_injects_session_id_into_remember(self) -> None:
        client = FakeClient()
        provider = _provider(client)
        provider.initialize("sess-1", cwd="/tmp/wax-dx-cwd-project", platform="cli")
        provider.handle_tool_call("wax_remember", {"content": "Dock code is 4412"})
        self.assertEqual(client.last_args("remember")["session_id"], WAX_SESSION_ID)
        self.assertEqual(client.last_args("remember")["cwd"], "/tmp/wax-dx-cwd-project")

    def test_handle_tool_call_injects_cwd_into_recall(self) -> None:
        client = FakeClient()
        provider = _provider(client)
        provider.initialize("sess-1", cwd="/tmp/wax-dx-cwd-project", platform="cli")
        provider.handle_tool_call("wax_recall", {"query": "dock code"})
        self.assertEqual(client.last_args("recall")["session_id"], WAX_SESSION_ID)
        self.assertEqual(client.last_args("recall")["cwd"], "/tmp/wax-dx-cwd-project")
        self.assertNotIn("session_id", next(
            schema for schema in provider.get_tool_schemas() if schema["name"] == "wax_recall"
        )["parameters"]["properties"])

    def test_handle_tool_call_replaces_opaque_host_session_id(self) -> None:
        client = FakeClient()
        provider = _provider(client)
        provider.initialize("sess-1", platform="cli")
        provider.handle_tool_call(
            "wax_recall",
            {"query": "dock code", "session_id": "sess-1"},
        )
        self.assertEqual(client.last_args("recall")["session_id"], WAX_SESSION_ID)

    def test_recall_schema_exposes_scope_and_project_routing(self) -> None:
        recall = next(
            schema for schema in _provider().get_tool_schemas() if schema["name"] == "wax_recall"
        )
        properties = recall["parameters"]["properties"]
        self.assertNotIn("session_id", properties)
        self.assertEqual(properties["scope"]["enum"], ["project", "session", "global"])
        self.assertIn("project", properties)
        self.assertIn("repo", properties)
        self.assertIn("cwd", properties)
        description = recall["description"].lower()
        self.assertIn("recent", description)
        self.assertIn("exact", description)
        self.assertIn("embeddings", description)

    def test_native_remember_schema_does_not_ask_agent_for_session_uuid(self) -> None:
        remember = next(
            schema for schema in _provider().get_tool_schemas() if schema["name"] == "wax_remember"
        )
        self.assertNotIn("session_id", remember["parameters"]["properties"])

    def test_default_native_tools_never_ask_agent_for_session_uuid(self) -> None:
        for schema in _provider().get_tool_schemas():
            self.assertNotIn("session_id", schema["parameters"]["properties"], schema["name"])

    def test_extended_native_tools_keep_provider_lifecycle_private(self) -> None:
        schemas = _provider(WAX_HERMES_EXTENDED_TOOLS="1").get_tool_schemas()
        names = {schema["name"] for schema in schemas}
        self.assertFalse(any(name.startswith("wax_session_") for name in names))
        for schema in schemas:
            self.assertNotIn("session_id", schema["parameters"]["properties"], schema["name"])

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

    def test_native_remember_does_not_return_until_broker_acknowledges(self) -> None:
        started = threading.Event()
        release = threading.Event()
        finished = threading.Event()
        client = FakeClient()
        original = client.call_tool

        def slow(tool_name: str, arguments: dict) -> dict:
            if tool_name == "remember":
                started.set()
                self.assertTrue(release.wait(2), "remember was not released")
            return original(tool_name, arguments)

        client.call_tool = slow  # type: ignore[method-assign]
        provider = _provider(client)
        provider.initialize("sess-1", platform="cli")
        holder: list[str] = []

        def call() -> None:
            holder.append(
                provider.handle_tool_call("wax_remember", {"content": "Dock code is 4412"})
            )
            finished.set()

        worker = threading.Thread(target=call)
        worker.start()
        self.assertTrue(started.wait(1), "native remember never reached the broker")
        self.assertFalse(finished.wait(0.2), "native remember returned before persistence")
        release.set()
        self.assertTrue(finished.wait(2), "native remember did not finish")
        worker.join(timeout=2)
        self.assertEqual(client.last_args("remember")["session_id"], WAX_SESSION_ID)
        self.assertTrue(holder)

    def test_native_remember_fails_closed_when_broker_write_fails(self) -> None:
        client = FakeClient()
        client.responses["remember"] = {"ok": False, "text": "disk full", "raw": {}}
        provider = _provider(client)
        provider.initialize("sess-1", platform="cli")
        result = json.loads(
            provider.handle_tool_call("wax_remember", {"content": "Dock code is 4412"})
        )
        self.assertFalse(result["ok"])
        self.assertIn("disk full", result["error"])


class PrefetchAndSyncTests(unittest.TestCase):
    def test_prefetch_skips_trivial_prompts(self) -> None:
        client = FakeClient()
        provider = _provider(client)
        self.assertEqual(provider.prefetch("ok"), "")
        self.assertNotIn("recall", client.tools_called())

    def test_prefetch_and_queue_fail_closed_when_session_unavailable(self) -> None:
        for action in ("prefetch", "queue"):
            client = FakeClient()
            client.responses["session_open"] = {"ok": False, "text": "offline", "raw": {}}
            provider = _provider(client)
            provider.initialize(f"offline-{action}", platform="cli")
            if action == "prefetch":
                self.assertEqual(provider.prefetch("what changed in this repo"), "")
            else:
                provider.queue_prefetch("what changed in this repo")
                provider._join_background()
            self.assertNotIn("recall", client.tools_called())

    def test_pre_compress_fails_closed_when_session_unavailable(self) -> None:
        client = FakeClient()
        client.responses["session_open"] = {"ok": False, "text": "offline", "raw": {}}
        provider = _provider(client)
        provider.initialize("offline-compress", platform="cli")
        result = provider.on_pre_compress([{"role": "user", "content": "Summarize this work"}])
        self.assertEqual(result, "")
        self.assertNotIn("compact_context", client.tools_called())

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
        self.assertEqual(args["session_id"], WAX_SESSION_ID)

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
            if (
                tool_name == "recall"
                and arguments.get("session_id") == WAX_SESSION_ID
            ):
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

    def test_prefetch_hooks_fail_closed_during_blocked_session_switch(self) -> None:
        switch_started = threading.Event()
        release_switch = threading.Event()
        client = FakeClient()
        original = client.call_tool

        def block_new_open(tool_name: str, arguments: dict) -> dict:
            if tool_name == "session_open" and arguments.get("conversation_id") == "new-sess":
                switch_started.set()
                self.assertTrue(release_switch.wait(2), "switch was not released")
            return original(tool_name, arguments)

        client.call_tool = block_new_open  # type: ignore[method-assign]
        provider = _provider(client)
        provider.initialize("old-sess", platform="cli")
        switch = threading.Thread(target=provider.on_session_switch, args=("new-sess",))
        switch.start()
        self.assertTrue(switch_started.wait(1), "session switch never reached new open")
        started_at = time.time()
        provider.queue_prefetch("Harbor shipment status")
        self.assertEqual(provider.prefetch("Harbor shipment status"), "")
        self.assertEqual(
            provider.on_pre_compress([{"role": "user", "content": "Harbor shipment status"}]),
            "",
        )
        self.assertLess(time.time() - started_at, 0.5)
        self.assertNotIn("recall", client.tools_called())
        self.assertNotIn("compact_context", client.tools_called())
        release_switch.set()
        switch.join(2)
        self.assertFalse(switch.is_alive())
        self.assertEqual(provider._session_id, WAX_SESSION_ID_2)
        self.assertIsNone(provider.recall_status())

    def test_concurrent_switch_and_end_leave_no_orphaned_provider_session(self) -> None:
        switch_started = threading.Event()
        release_switch = threading.Event()
        client = FakeClient()
        original = client.call_tool

        def block_new_open(tool_name: str, arguments: dict) -> dict:
            if tool_name == "session_open" and arguments.get("conversation_id") == "new-sess":
                switch_started.set()
                self.assertTrue(release_switch.wait(2), "switch was not released")
            return original(tool_name, arguments)

        client.call_tool = block_new_open  # type: ignore[method-assign]
        provider = _provider(client)
        provider.initialize("old-sess", platform="cli")
        switch = threading.Thread(target=provider.on_session_switch, args=("new-sess",))
        switch.start()
        self.assertTrue(switch_started.wait(1), "session switch never reached new open")
        ending = threading.Thread(
            target=provider.on_session_end,
            args=([{"role": "user", "content": "Close the active conversation"}],),
        )
        ending.start()
        release_switch.set()
        switch.join(2)
        ending.join(2)
        self.assertFalse(switch.is_alive())
        self.assertFalse(ending.is_alive())
        self.assertIsNone(provider._session_id)
        self.assertEqual(provider._host_session_id, "")
        self.assertFalse(provider._accepting_background)
        self.assertTrue(client.closed)
        self.assertEqual(client.last_args("session_close")["session_id"], WAX_SESSION_ID_2)


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
    def test_cli_loads_through_hermes_directory_plugin_namespace(self) -> None:
        """Hermes imports user-provider CLI modules without adding them to sys.path."""
        script = r'''
import argparse
import importlib.util
import sys
import types
from pathlib import Path

plugin_dir = Path(sys.argv[1])
root = types.ModuleType("_hermes_user_memory")
root.__path__ = []
package = types.ModuleType("_hermes_user_memory.wax-memory")
package.__path__ = [str(plugin_dir)]
sys.modules[root.__name__] = root
sys.modules[package.__name__] = package

module_name = "_hermes_user_memory.wax-memory.cli"
spec = importlib.util.spec_from_file_location(module_name, plugin_dir / "cli.py")
assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec)
sys.modules[module_name] = module
spec.loader.exec_module(module)
assert callable(module.register_cli)
parser = argparse.ArgumentParser()
module.register_cli(parser)
args = parser.parse_args(["doctor"])
assert args.wax_memory_command == "doctor"
assert callable(args.func)
'''
        completed = subprocess.run(
            [sys.executable, "-I", "-c", script, str(PLUGIN_DIR)],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_entry_point_uses_memory_providers_group(self) -> None:
        text = (PLUGIN_DIR / "pyproject.toml").read_text(encoding="utf-8")
        self.assertIn('hermes_agent.memory_providers', text)
        self.assertIn('wax-memory = "hermes_wax_memory:register"', text)
        self.assertIn('"wax_memory_lifecycle"', text)

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


class LoaderIsolationTests(unittest.TestCase):
    def test_provider_sources_do_not_import_hyphenated_user_memory_module(self) -> None:
        for name in ("hermes_wax_memory.py", "wax_memory_lifecycle.py"):
            source = (PLUGIN_DIR / name).read_text(encoding="utf-8")
            self.assertNotIn("importlib.import_module", source, name)
            self.assertNotIn("_hermes_user_memory.wax-memory.", source, name)

    def test_package_load_uses_sibling_lifecycle_not_sys_path_decoy(self) -> None:
        script = r'''
import importlib.util
import sys
import types
from pathlib import Path

plugin_dir = Path(sys.argv[1])
decoy_dir = Path(sys.argv[2])
sys.path.insert(0, str(decoy_dir))
assert str(plugin_dir) not in sys.path

root = types.ModuleType("_hermes_user_memory")
root.__path__ = []
package = types.ModuleType("_hermes_user_memory.wax-memory")
package.__path__ = [str(plugin_dir)]
package.__package__ = package.__name__
sys.modules[root.__name__] = root
sys.modules[package.__name__] = package

spec = importlib.util.spec_from_file_location(
    "_hermes_user_memory.wax-memory.hermes_wax_memory",
    plugin_dir / "hermes_wax_memory.py",
)
assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
assert module.WaxProviderLifecycle.__module__ == (
    "_hermes_user_memory.wax-memory.wax_memory_lifecycle"
), module.WaxProviderLifecycle.__module__
'''
        with tempfile.TemporaryDirectory() as decoy:
            decoy_path = Path(decoy)
            (decoy_path / "wax_memory_lifecycle.py").write_text(
                "raise RuntimeError('decoy wax_memory_lifecycle imported')\n",
                encoding="utf-8",
            )
            (decoy_path / "wax_memory_schemas.py").write_text(
                "raise RuntimeError('decoy wax_memory_schemas imported')\n",
                encoding="utf-8",
            )
            completed = _run_isolated(script, str(PLUGIN_DIR), str(decoy_path))
        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_flat_module_fallback_loads_without_package(self) -> None:
        script = r'''
import importlib.util
import sys
from pathlib import Path

plugin_dir = Path(sys.argv[1])
sys.path.insert(0, str(plugin_dir))
spec = importlib.util.spec_from_file_location(
    "hermes_wax_memory",
    plugin_dir / "hermes_wax_memory.py",
)
assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec)
sys.modules["hermes_wax_memory"] = module
spec.loader.exec_module(module)
assert not module.__package__, module.__package__
assert module.WaxMemoryProvider is not None
assert module.WaxProviderLifecycle.__module__ == "wax_memory_lifecycle"
'''
        completed = _run_isolated(script, str(PLUGIN_DIR))
        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_synthetic_package_provider_maps_opaque_ids_and_fails_closed(self) -> None:
        script = r'''
import importlib.util
import json
import sys
import types
import uuid
from pathlib import Path

plugin_dir = Path(sys.argv[1])
assert str(plugin_dir) not in sys.path

root = types.ModuleType("_hermes_user_memory")
root.__path__ = []
package = types.ModuleType("_hermes_user_memory.wax-memory")
package.__path__ = [str(plugin_dir)]
package.__package__ = package.__name__
sys.modules[root.__name__] = root
sys.modules[package.__name__] = package

spec = importlib.util.spec_from_file_location(
    "_hermes_user_memory.wax-memory.hermes_wax_memory",
    plugin_dir / "hermes_wax_memory.py",
)
assert spec is not None and spec.loader is not None
mod = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = mod
spec.loader.exec_module(mod)

WAX_A = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"
WAX_B = "BBBBBBBB-CCCC-4DDD-8EEE-FFFFFFFFFFFF"

class FakeClient:
    def __init__(self) -> None:
        self.calls = []
        self.responses = {}
        self.closed = False

    def call_tool(self, tool_name, arguments):
        self.calls.append((tool_name, dict(arguments)))
        if tool_name in self.responses:
            return self.responses[tool_name]
        if tool_name == "session_open":
            opened = WAX_B if arguments.get("conversation_id") == "beta" else WAX_A
            return {"ok": True, "text": json.dumps({"session_id": opened}), "raw": {}}
        if tool_name == "recall":
            return {"ok": True, "text": "Harbor ship Friday", "raw": {}}
        if tool_name == "session_synthesize":
            return {"ok": True, "text": json.dumps({"handoff": "done"}), "raw": {}}
        return {"ok": True, "text": json.dumps({"ok": True}), "raw": {}}

    def close(self) -> None:
        self.closed = True

client = FakeClient()
provider = mod.WaxMemoryProvider(client=client)
provider._client = client
provider.initialize("alpha-host", platform="cli", project="Wax", repo="Wax")
assert provider._session_id == WAX_A
assert uuid.UUID(provider._session_id)
opened = [args for name, args in client.calls if name == "session_open"][-1]
assert opened["conversation_id"] == "alpha-host"
assert opened["run_id"] == "alpha-host"
assert "session_id" not in opened

provider.handle_tool_call("wax_remember", {"content": "Dock code 4412"})
remember = [args for name, args in client.calls if name == "remember"][-1]
assert remember["session_id"] == WAX_A
assert remember["content"] == "Dock code 4412"

recalled = provider.handle_tool_call("wax_recall", {"query": "dock"})
assert "Harbor ship Friday" in recalled
assert [args for name, args in client.calls if name == "recall"][-1]["session_id"] == WAX_A

provider.on_session_switch("beta")
assert provider._session_id == WAX_B

client.responses["session_open"] = {"ok": False, "text": "offline", "raw": {}}
provider.initialize("gamma", platform="cli")
assert provider._session_id is None
failed = json.loads(provider.handle_tool_call("wax_remember", {"content": "must not persist"}))
assert failed["ok"] is False
assert [name for name, _ in client.calls].count("remember") == 1

del client.responses["session_open"]
provider.initialize("alpha-host", platform="cli")
assert provider._session_id == WAX_A
provider.on_session_end([{"role": "user", "content": "bye"}])
assert provider._session_id is None
assert client.closed
'''
        completed = _run_isolated(script, str(PLUGIN_DIR))
        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_synthetic_package_http_lifecycle_outage_and_recovery(self) -> None:
        """Hermes-style package load against an isolated MCP HTTP stub."""
        script = r'''
import http.server
import importlib.util
import json
import os
import sys
import threading
import types
import uuid
from pathlib import Path

plugin_dir = Path(sys.argv[1]).resolve()
assert str(plugin_dir) not in sys.path

class Stub(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        return

    def _read_json(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        return json.loads(raw.decode("utf-8") or "{}")

    def _send(self, code, payload=None, session=None, sse=False):
        body = b""
        if payload is not None:
            encoded = json.dumps(payload)
            body = (f"data: {encoded}\n\n" if sse else encoded).encode("utf-8")
        self.send_response(code)
        if session:
            self.send_header("Mcp-Session-Id", session)
        if payload is not None:
            self.send_header("Content-Type", "text/event-stream" if sse else "application/json")
            self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def _tool_result(self, rpc_id, payload, is_error=False):
        return {
            "jsonrpc": "2.0",
            "id": rpc_id,
            "result": {
                "isError": is_error,
                "content": [{"type": "text", "text": payload if isinstance(payload, str) else json.dumps(payload)}],
            },
        }

    def do_DELETE(self):
        if self.path != "/custom/mcp":
            self._send(404)
            return
        if self.server.down:
            self._send(503)
            return
        sid = self.headers.get("MCP-Session-Id") or self.headers.get("Mcp-Session-Id")
        self.server.mcp.discard(sid)
        self.server.deletes.append(sid)
        self._send(204)

    def do_POST(self):
        if self.path != "/custom/mcp":
            self._send(404)
            return
        body = self._read_json()
        if self.server.down:
            self._send(503)
            return
        method = body.get("method")
        rpc_id = body.get("id")
        mcp = self.headers.get("MCP-Session-Id") or self.headers.get("Mcp-Session-Id")
        if method == "initialize":
            sid = str(uuid.uuid4())
            self.server.mcp.add(sid)
            self._send(200, {"jsonrpc": "2.0", "id": rpc_id, "result": {"capabilities": {}}}, session=sid)
            return
        if method == "notifications/initialized":
            self._send(202)
            return
        if method != "tools/call":
            self._send(400, {"jsonrpc": "2.0", "id": rpc_id, "error": {"message": "unknown method"}})
            return
        if mcp not in self.server.mcp:
            self._send(404)
            return
        params = body.get("params") or {}
        name = params.get("name")
        args = dict(params.get("arguments") or {})
        self.server.calls.append((name, args))
        if name == "stats":
            self._send(200, self._tool_result(rpc_id, {
                "vectorSearchEnabled": True,
                "queryEmbeddingAvailable": True,
                "embedder": {"model": "minilm"},
                "frameCount": 0,
            }), sse=True)
            return
        if name == "session_open":
            assert "session_id" not in args, args
            conv = str(args.get("conversation_id") or "")
            opened = str(uuid.uuid5(uuid.NAMESPACE_DNS, "wax.stub." + conv))
            uuid.UUID(opened)
            self.server.broker[conv] = opened
            self._send(200, self._tool_result(rpc_id, {"session_id": opened}), sse=True)
            return
        if name == "remember":
            sid = args.get("session_id")
            uuid.UUID(str(sid))
            self.server.memories.setdefault(sid, []).append(args.get("content"))
            self._send(200, self._tool_result(rpc_id, {"ok": True}), sse=True)
            return
        if name == "recall":
            sid = args.get("session_id")
            uuid.UUID(str(sid))
            stored = self.server.memories.get(sid) or []
            text = "Harbor ship Friday" if stored else ""
            self._send(200, self._tool_result(rpc_id, text), sse=True)
            return
        if name in {"session_synthesize", "session_close", "session_end"}:
            self._send(200, self._tool_result(rpc_id, {"handoff": "done", "ok": True}), sse=True)
            return
        self._send(200, self._tool_result(rpc_id, {"ok": True}), sse=True)

class Server(http.server.ThreadingHTTPServer):
    allow_reuse_address = True
    daemon_threads = True

httpd = Server(("127.0.0.1", 0), Stub)
httpd.down = False
httpd.mcp = set()
httpd.broker = {}
httpd.memories = {}
httpd.calls = []
httpd.deletes = []
thread = threading.Thread(target=httpd.serve_forever, daemon=True)
thread.start()
port = httpd.server_address[1]
endpoint = f"http://127.0.0.1:{port}/custom/mcp"
os.environ["WAX_MCP_HTTP_ENDPOINT"] = endpoint
os.environ["WAX_MCP_AUTO_START"] = "0"

root = types.ModuleType("_hermes_user_memory")
root.__path__ = []
package = types.ModuleType("_hermes_user_memory.wax-memory")
package.__path__ = [str(plugin_dir)]
package.__package__ = package.__name__
sys.modules[root.__name__] = root
sys.modules[package.__name__] = package
spec = importlib.util.spec_from_file_location(
    "_hermes_user_memory.wax-memory.hermes_wax_memory",
    plugin_dir / "hermes_wax_memory.py",
)
assert spec is not None and spec.loader is not None
mod = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = mod
spec.loader.exec_module(mod)
assert mod.WaxProviderLifecycle.__module__ == "_hermes_user_memory.wax-memory.wax_memory_lifecycle"

provider = mod.WaxMemoryProvider()
for schema in provider.get_tool_schemas():
    assert "session_id" not in schema["parameters"]["properties"], schema["name"]

provider.initialize("alpha-host", platform="cli", project="Wax", repo="Wax")
assert uuid.UUID(provider._session_id)
alpha = provider._session_id
opens = [args for name, args in httpd.calls if name == "session_open"]
assert opens, httpd.calls
assert opens[-1]["conversation_id"] == "alpha-host"
assert opens[-1]["run_id"] == "alpha-host"
assert "session_id" not in opens[-1]

remembered = json.loads(provider.handle_tool_call("wax_remember", {"content": "Dock-alpha"}))
assert remembered.get("ok") is not False, remembered
assert httpd.calls[-1][0] == "remember"
assert httpd.calls[-1][1]["session_id"] == alpha
assert httpd.calls[-1][1]["content"] == "Dock-alpha"

recalled = provider.handle_tool_call("wax_recall", {"query": "dock"})
assert "Harbor ship Friday" in recalled
assert httpd.calls[-1][0] == "recall"
assert httpd.calls[-1][1]["session_id"] == alpha

provider.on_session_switch("beta-host")
beta = provider._session_id
assert uuid.UUID(beta)
assert beta != alpha
assert [args for name, args in httpd.calls if name == "session_open"][-1]["conversation_id"] == "beta-host"

httpd.down = True
failed = json.loads(provider.handle_tool_call("wax_remember", {"content": "must-not-store"}))
assert failed.get("ok") is False, failed
assert "must-not-store" not in str(httpd.memories)

httpd.mcp.clear()
httpd.down = False
provider.initialize("alpha-host", platform="cli", project="Wax", repo="Wax")
recovered = json.loads(provider.handle_tool_call("wax_remember", {"content": "Dock-recovered"}))
assert recovered.get("ok") is not False, recovered
assert uuid.UUID(provider._session_id)
assert provider._session_id == alpha
stored = [item for values in httpd.memories.values() for item in values]
assert "Dock-recovered" in stored
assert "must-not-store" not in stored

provider.on_session_end([{"role": "user", "content": "bye"}])
assert provider._session_id is None
httpd.shutdown()
httpd.server_close()
'''
        if not HERMES_PYTHON.is_file():
            self.skipTest("Hermes venv is not installed")
        completed = subprocess.run(
            [str(HERMES_PYTHON), "-c", script, str(PLUGIN_DIR)],
            capture_output=True,
            text=True,
            check=False,
            cwd=str(PLUGIN_DIR.parents[3]),
        )
        self.assertEqual(
            completed.returncode,
            0,
            f"stdout={completed.stdout!r}\nstderr={completed.stderr!r}",
        )


if __name__ == "__main__":
    unittest.main()
