"""Hermes CLI commands for the Wax memory provider."""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any, Optional

try:
    from .hermes_wax_memory import (
        DEFAULT_ENDPOINT,
        WaxMemoryProvider,
        load_plugin_config,
        resolve_endpoint,
    )
except ImportError:
    from hermes_wax_memory import (
        DEFAULT_ENDPOINT,
        WaxMemoryProvider,
        load_plugin_config,
        resolve_endpoint,
    )


def _without_yaml_comments(text: str) -> str:
    lines = []
    for line in text.splitlines():
        quote = ""
        escaped = False
        kept = []
        for character in line:
            if escaped:
                kept.append(character)
                escaped = False
                continue
            if character == "\\" and quote == '"':
                kept.append(character)
                escaped = True
                continue
            if character in {"'", '"'}:
                if not quote:
                    quote = character
                elif quote == character:
                    quote = ""
            if character == "#" and not quote:
                break
            kept.append(character)
        lines.append("".join(kept).rstrip())
    return "\n".join(lines)


def _yaml_key(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
        return value[1:-1]
    return value


def _split_flow(value: str) -> list[str]:
    value = value.strip()
    if len(value) >= 2 and (value[0], value[-1]) in {("{", "}"), ("[", "]")}:
        value = value[1:-1]
    parts: list[str] = []
    start = 0
    depth = 0
    quote = ""
    for index, character in enumerate(value):
        if character in {"'", '"'}:
            if not quote:
                quote = character
            elif quote == character:
                quote = ""
        elif not quote:
            if character in "{[":
                depth += 1
            elif character in "}]":
                depth -= 1
            elif character == "," and depth == 0:
                parts.append(value[start:index].strip())
                start = index + 1
    parts.append(value[start:].strip())
    return [part for part in parts if part]


def _mapping_pair(value: str) -> tuple[str, str] | None:
    depth = 0
    quote = ""
    for index, character in enumerate(value):
        if character in {"'", '"'}:
            if not quote:
                quote = character
            elif quote == character:
                quote = ""
        elif not quote:
            if character in "{[":
                depth += 1
            elif character in "}]":
                depth -= 1
            elif character == ":" and depth == 0:
                return _yaml_key(value[:index]), value[index + 1:].strip()
    return None


def _mapping_value(mapping: str, key: str) -> Optional[str]:
    stripped = mapping.strip()
    if stripped.startswith("{"):
        for item in _split_flow(stripped):
            pair = _mapping_pair(item)
            if pair and pair[0] == key:
                return pair[1]
        return None

    lines = mapping.splitlines()
    indents = [len(line) - len(line.lstrip()) for line in lines if line.strip()]
    if not indents:
        return None
    entry_indent = min(indents)
    for index, line in enumerate(lines):
        if not line.strip() or len(line) - len(line.lstrip()) != entry_indent:
            continue
        pair = _mapping_pair(line.strip())
        if not pair or pair[0] != key:
            continue
        if pair[1]:
            return pair[1]
        nested = []
        for later in lines[index + 1:]:
            if later.strip() and len(later) - len(later.lstrip()) <= entry_indent:
                break
            nested.append(later)
        return "\n".join(nested)
    return None


def _top_level_value(text: str, key: str) -> Optional[str]:
    lines = _without_yaml_comments(text).splitlines()
    for index, line in enumerate(lines):
        if not line.strip() or line != line.lstrip():
            continue
        pair = _mapping_pair(line)
        if not pair or pair[0] != key:
            continue
        if pair[1]:
            return pair[1]
        nested = []
        for later in lines[index + 1:]:
            if later.strip() and later == later.lstrip():
                break
            nested.append(later)
        return "\n".join(nested)
    return None


def _scalar(value: Optional[str]) -> str:
    return _yaml_key((value or "").strip())


def _list_contains(value: Optional[str], expected: str) -> bool:
    if value is None:
        return False
    stripped = value.strip()
    if stripped.startswith("["):
        return any(_scalar(item) == expected for item in _split_flow(stripped))
    return any(
        _scalar(line.strip()[1:].strip()) == expected
        for line in stripped.splitlines()
        if line.strip().startswith("-")
    )


def _hermes_config_conflicts(hermes_home: str | None) -> list[str]:
    home = Path(hermes_home or os.environ.get("HERMES_HOME") or Path.home() / ".hermes")
    path = home / "config.yaml"
    if not path.is_file():
        return []
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return []
    memory = _top_level_value(text, "memory")
    native = _scalar(_mapping_value(memory or "", "provider")) == "wax-memory"
    if not native:
        return []

    conflicts: list[str] = []
    mcp_servers = _top_level_value(text, "mcp_servers")
    if _mapping_value(mcp_servers or "", "wax") is not None:
        conflicts.append(
            "memory.provider wax-memory duplicates mcp_servers.wax; remove the generic MCP entry"
        )

    plugins = _top_level_value(text, "plugins")
    if _list_contains(_mapping_value(plugins or "", "enabled"), "wax-memory"):
        conflicts.append(
            "memory.provider wax-memory duplicates plugins.enabled wax-memory; remove the plugin entry"
        )
    return conflicts


def _print_status(args: Any) -> int:
    hermes_home = getattr(args, "hermes_home", None) or os.environ.get("HERMES_HOME")
    config = load_plugin_config(hermes_home)
    endpoint = resolve_endpoint(config)
    provider = WaxMemoryProvider(config=config)
    print(f"provider: {provider.name}")
    print(f"available: {provider.is_available()}")
    if reason := provider.unavailable_reason():
        print(f"unavailable_reason: {reason}")
    print(f"endpoint: {endpoint}")
    print(f"auto_start: {provider.auto_start_enabled()}")
    print(f"structured_memory: {provider.structured_memory_enabled()}")
    info = provider.probe_broker()
    print(f"reachable: {info.get('reachable', False)}")
    if info.get("reachable"):
        print(f"vector_search: {info.get('vector_search_enabled', False)}")
        print(f"query_embedding_available: {info.get('query_embedding_available', False)}")
        print(f"embedding_status: {info.get('embedding_status') or 'unknown'}")
        print(f"embedding_status_reason: {info.get('embedding_status_reason') or ''}")
        print(f"frames_without_vectors: {info.get('frames_without_vectors', 0)}")
        print(f"frame_count: {info.get('frame_count', 0)}")
        print(provider.diagnose_vector_search())
    else:
        print("broker: not running")
        print("hint: npx waxmcp --embedder minilm --transport http")
    conflicts = _hermes_config_conflicts(hermes_home)
    for conflict in conflicts:
        print(f"configuration_error: {conflict}")
    return 0 if info.get("reachable") and info.get("query_embedding_available") and not conflicts else 1


def _print_config(args: Any) -> None:
    hermes_home = getattr(args, "hermes_home", None) or os.environ.get("HERMES_HOME")
    config = load_plugin_config(hermes_home)
    payload = {
        "endpoint": resolve_endpoint(config),
        "auto_start": config.get("auto_start", False),
        "structured_memory": config.get("structured_memory", True),
        "default_endpoint": DEFAULT_ENDPOINT,
    }
    print(json.dumps(payload, indent=2))


def register_cli(subparser) -> None:
    """Build the `hermes wax-memory` argparse tree."""
    subs = subparser.add_subparsers(dest="wax_memory_command")
    subs.add_parser("status", help="Show Wax provider and broker status")
    subs.add_parser("doctor", help="Diagnose Wax MCP connectivity and vector search")
    subs.add_parser("config", help="Show resolved Wax provider config")

    def _dispatch(args) -> None:
        command = getattr(args, "wax_memory_command", None)
        if command == "status":
            _print_status(args)
        elif command == "doctor":
            exit_code = _print_status(args)
            if exit_code:
                raise SystemExit(exit_code)
        elif command == "config":
            _print_config(args)
        else:
            print("Usage: hermes wax-memory <status|doctor|config>")

    subparser.set_defaults(func=_dispatch)
