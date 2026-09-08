"""Wax Memory Plugin for Hermes Agent.

Re-exports the canonical implementation so both directory-based
(~/.hermes/plugins/wax-memory/) and pip-based installs work.
"""

try:
    from .hermes_wax_memory import WaxMCPError, WaxMemoryProvider, register
except ImportError:
    from hermes_wax_memory import WaxMCPError, WaxMemoryProvider, register

__all__ = ["WaxMemoryProvider", "register", "WaxMCPError"]
