"""Wax Memory Plugin for Hermes Agent.

Re-exports the canonical implementation so both directory-based
(~/.hermes/plugins/wax-memory/) and pip-based installs work.
"""
import importlib
import sys

# Support both Hermes directory-plugin loading (which registers submodules
# under _hermes_user_memory.<name>) and pip/standalone imports.
_mod = None
for _candidate in (
    "hermes_wax_memory",
    "_hermes_user_memory.wax-memory.hermes_wax_memory",
):
    if _candidate in sys.modules:
        _mod = sys.modules[_candidate]
        break
    try:
        _mod = importlib.import_module(_candidate)
        break
    except Exception:
        pass

if _mod is None:
    raise ImportError("hermes_wax_memory module not found")

WaxMemoryProvider = _mod.WaxMemoryProvider
register = _mod.register
WaxMCPError = _mod.WaxMCPError
__all__ = ["WaxMemoryProvider", "register", "WaxMCPError"]
