"""Hermes CLI commands for the Wax memory provider."""

from __future__ import annotations

import json
import os
from typing import Any

from hermes_wax_memory import (
    DEFAULT_ENDPOINT,
    WaxMemoryProvider,
    load_plugin_config,
    resolve_endpoint,
)


def _print_status(args: Any) -> None:
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
        print(f"frame_count: {info.get('frame_count', 0)}")
        print(provider.diagnose_vector_search())
    else:
        print("broker: not running")
        print("hint: npx waxmcp --embedder minilm --transport http")


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
        if command in {"status", "doctor"}:
            _print_status(args)
        elif command == "config":
            _print_config(args)
        else:
            print("Usage: hermes wax-memory <status|doctor|config>")

    subparser.set_defaults(func=_dispatch)
