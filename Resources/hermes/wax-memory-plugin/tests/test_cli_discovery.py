"""Loader-faithful Hermes import tests for wax-memory CLI and package.

Seam: Hermes directory loading. User providers are imported as
``_hermes_user_memory.wax-memory`` / ``.cli`` via spec_from_file_location.
Plugin Doctor uses PluginManager, which execs ``__init__.py`` as
``hermes_plugins.wax_memory`` with submodule_search_locations and does
**not** put the plugin directory on ``sys.path``.
"""

from __future__ import annotations

import os
import subprocess
import sys
import unittest
from pathlib import Path

PLUGIN_DIR = Path(__file__).resolve().parents[1]
HERMES_ROOT = Path.home() / ".hermes" / "hermes-agent"
HERMES_PYTHON = HERMES_ROOT / "venv" / "bin" / "python"


def _run_isolated(script: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, "-I", "-c", script, str(PLUGIN_DIR)],
        capture_output=True,
        text=True,
        check=False,
    )


_HERMES_MEMORY_CLI_SCRIPT = r"""
import argparse
import importlib.machinery
import importlib.util
import sys
from pathlib import Path

plugin_dir = Path(sys.argv[1]).resolve()
if str(plugin_dir) in sys.path:
    raise AssertionError("plugin dir must not be on sys.path")

user_ns = "_hermes_user_memory"
package_name = f"{user_ns}.wax-memory"

def register_synthetic(name, search_locations):
    spec = importlib.machinery.ModuleSpec(name, None, is_package=True)
    spec.submodule_search_locations = search_locations
    sys.modules[name] = importlib.util.module_from_spec(spec)

register_synthetic(user_ns, [])
register_synthetic(package_name, [str(plugin_dir)])

cli_name = f"{package_name}.cli"
spec = importlib.util.spec_from_file_location(cli_name, plugin_dir / "cli.py")
assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec)
sys.modules[cli_name] = module
spec.loader.exec_module(module)

assert callable(getattr(module, "register_cli", None)), "register_cli missing"
parser = argparse.ArgumentParser()
module.register_cli(parser)
args = parser.parse_args(["doctor"])
assert args.wax_memory_command == "doctor"
assert callable(args.func)
assert str(plugin_dir) not in sys.path
print("ok")
"""


_HERMES_MEMORY_PROVIDER_SCRIPT = r"""
import importlib.machinery
import importlib.util
import sys
from pathlib import Path

plugin_dir = Path(sys.argv[1]).resolve()
if str(plugin_dir) in sys.path:
    raise AssertionError("plugin dir must not be on sys.path")

user_ns = "_hermes_user_memory"
package_name = f"{user_ns}.wax-memory"

def register_synthetic(name, search_locations):
    spec = importlib.machinery.ModuleSpec(name, None, is_package=True)
    spec.submodule_search_locations = search_locations
    sys.modules[name] = importlib.util.module_from_spec(spec)

register_synthetic(user_ns, [])
register_synthetic(package_name, [str(plugin_dir)])

init_file = plugin_dir / "__init__.py"
for sub_file in sorted(plugin_dir.glob("*.py")):
    if sub_file.name == "__init__.py":
        continue
    full_name = f"{package_name}.{sub_file.stem}"
    if full_name in sys.modules:
        continue
    sub_spec = importlib.util.spec_from_file_location(full_name, sub_file)
    assert sub_spec is not None and sub_spec.loader is not None
    sub_mod = importlib.util.module_from_spec(sub_spec)
    sys.modules[full_name] = sub_mod
    sub_spec.loader.exec_module(sub_mod)

spec = importlib.util.spec_from_file_location(
    package_name,
    init_file,
    submodule_search_locations=[str(plugin_dir)],
)
assert spec is not None and spec.loader is not None
package = importlib.util.module_from_spec(spec)
sys.modules[package_name] = package
spec.loader.exec_module(package)

assert hasattr(package, "WaxMemoryProvider"), "WaxMemoryProvider not exported"
assert callable(getattr(package, "register", None)), "register not exported"
assert str(plugin_dir) not in sys.path
print("ok")
"""


_PLUGIN_MANAGER_INIT_SCRIPT = r"""
import importlib.util
import sys
import types
from pathlib import Path

plugin_dir = Path(sys.argv[1]).resolve()
if str(plugin_dir) in sys.path:
    raise AssertionError("plugin dir must not be on sys.path")

parent = types.ModuleType("hermes_plugins")
parent.__path__ = []
parent.__package__ = "hermes_plugins"
sys.modules["hermes_plugins"] = parent

module_name = "hermes_plugins.wax_memory"
spec = importlib.util.spec_from_file_location(
    module_name,
    plugin_dir / "__init__.py",
    submodule_search_locations=[str(plugin_dir)],
)
assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec)
module.__package__ = module_name
module.__path__ = [str(plugin_dir)]
sys.modules[module_name] = module
spec.loader.exec_module(module)

assert hasattr(module, "WaxMemoryProvider"), "WaxMemoryProvider not exported"
assert callable(getattr(module, "register", None)), "register not exported"
assert str(plugin_dir) not in sys.path
print("ok")
"""


class HermesLoaderDiscoveryTests(unittest.TestCase):
    def _assert_isolated_ok(self, script: str) -> None:
        completed = _run_isolated(script)
        self.assertEqual(
            completed.returncode,
            0,
            f"stdout={completed.stdout!r}\nstderr={completed.stderr!r}",
        )
        self.assertIn("ok", completed.stdout)

    def test_register_cli_loads_as_hermes_user_memory_cli(self) -> None:
        self._assert_isolated_ok(_HERMES_MEMORY_CLI_SCRIPT)

    def test_package_exports_provider_after_memory_loader_siblings(self) -> None:
        self._assert_isolated_ok(_HERMES_MEMORY_PROVIDER_SCRIPT)

    def test_package_exports_provider_when_plugin_manager_loads_init(self) -> None:
        self._assert_isolated_ok(_PLUGIN_MANAGER_INIT_SCRIPT)

    def test_discover_plugin_cli_commands_returns_wax_memory(self) -> None:
        """Call the real Hermes discovery function against a copied source plugin."""
        if not HERMES_PYTHON.is_file():
            self.skipTest("Hermes venv is not installed")
        script = r'''
import os
import shutil
import sys
import tempfile
from pathlib import Path

plugin_src = Path(sys.argv[1]).resolve()
if str(plugin_src) in sys.path:
    raise AssertionError("plugin dir must not be on sys.path")

home = Path(tempfile.mkdtemp(prefix="wax-dx-hermes-home-"))
try:
    os.environ["HERMES_HOME"] = str(home)
    os.environ["HERMES_ENABLE_PROJECT_PLUGINS"] = "0"
    dest = home / "plugins" / "wax-memory"
    shutil.copytree(
        plugin_src,
        dest,
        ignore=shutil.ignore_patterns("tests", "__pycache__", "*.pyc", ".pytest_cache"),
    )
    (home / "config.yaml").write_text(
        "memory:\n  provider: wax-memory\n",
        encoding="utf-8",
    )
    from plugins.memory import discover_plugin_cli_commands
    cmds = discover_plugin_cli_commands()
    names = [cmd.get("name") for cmd in cmds]
    if "wax-memory" not in names:
        raise AssertionError(f"discover_plugin_cli_commands names={names!r}")
    setup = next(cmd["setup_fn"] for cmd in cmds if cmd.get("name") == "wax-memory")
    if not callable(setup):
        raise AssertionError("setup_fn is not callable")
    if str(plugin_src) in sys.path:
        raise AssertionError("plugin dir must not be on sys.path")
    print("ok")
finally:
    shutil.rmtree(home, ignore_errors=True)
'''
        env = dict(os.environ)
        env["HERMES_ENABLE_PROJECT_PLUGINS"] = "0"
        completed = subprocess.run(
            [str(HERMES_PYTHON), "-c", script, str(PLUGIN_DIR)],
            cwd=str(HERMES_ROOT),
            capture_output=True,
            text=True,
            check=False,
            env=env,
        )
        self.assertEqual(
            completed.returncode,
            0,
            f"stdout={completed.stdout!r}\nstderr={completed.stderr!r}",
        )
        self.assertIn("ok", completed.stdout)


if __name__ == "__main__":
    unittest.main()
