#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"

cd "$ROOT_DIR"

python3 - "$ROOT_DIR" <<'PY'
import os
import re
import subprocess
import sys
from pathlib import Path

root = Path(sys.argv[1])

PUBLIC_PATHS = [
    "README.md",
    "Resources/docs",
    "Resources/locales",
    "Resources/npm/waxmcp/README.md",
    "Resources/openclaw/wax-memory-plugin/README.md",
    "Resources/skills/public",
    "Resources/website/docs",
    "Sources",
    "docs/openclaw-native-memory.md",
]

SHELL_LANGS = {"bash", "sh", "shell", "zsh", "console", "terminal"}
FENCE_RE = re.compile(r"^[ \t]*```([A-Za-z0-9_-]+)?[^\n]*$")
WAXCORE_GETTING_STARTED_DOCS = {
    "Sources/WaxCore/WaxCore.docc/Articles/GettingStarted.md",
    "Resources/website/docs/core/getting-started.md",
}
WAXCORE_GETTING_STARTED_REQUIRED_OPTIONS = {
    "walFsyncPolicy:",
    "walReplayStateSnapshotEnabled:",
}
WAXCORE_GETTING_STARTED_STALE_OPTIONS = {
    "fsyncPolicy:",
    "enableReplayStateSnapshot:",
}


class Failure:
    def __init__(self, path, line, message):
        self.path = path
        self.line = line
        self.message = message

    def __str__(self):
        return f"{self.path}:{self.line}: {self.message}"


def selected_files():
    override = os.environ.get("WAX_PUBLIC_SNIPPET_FILES")
    if override:
        files = [Path(item) for item in override.split(os.pathsep) if item]
        return [path if path.is_absolute() else root / path for path in files]

    output = subprocess.check_output(
        ["git", "ls-files", "-z", *PUBLIC_PATHS],
        cwd=root,
    )
    files = []
    for raw in output.split(b"\0"):
        if not raw:
            continue
        path = root / raw.decode("utf-8")
        if path.suffix == ".md":
            files.append(path)
    return files


def display_path(path):
    try:
        return str(path.relative_to(root))
    except ValueError:
        return str(path)


def shell_lines(block_lines):
    logical = ""
    start_line = None
    for line_no, line in block_lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if stripped.startswith("$ "):
            stripped = stripped[2:].lstrip()
        if stripped.startswith("> "):
            stripped = stripped[2:].lstrip()
        if start_line is None:
            start_line = line_no
        logical = f"{logical} {stripped}".strip()
        if logical.endswith("\\"):
            logical = logical[:-1].rstrip()
            continue
        yield start_line, logical
        logical = ""
        start_line = None
    if logical:
        yield start_line, logical


def check_shell_command(path, line_no, command, failures):
    if "--feature-license" in command and "mcp install" in command:
        failures.append(
            Failure(
                path,
                line_no,
                "public MCP install snippets must not advertise unsupported --feature-license",
            )
        )

    if re.search(r"\bnpx\s+(?!(-y|--yes)\s+)waxmcp@latest\b", command):
        failures.append(
            Failure(
                path,
                line_no,
                "public waxmcp@latest npx snippets must use -y/--yes for noninteractive installs",
            )
        )

    if re.search(r"\bwaxmcp@latest\s+mcp\s+install\b", command) and "--scope user" not in command:
        failures.append(
            Failure(
                path,
                line_no,
                "published waxmcp MCP install snippets must include --scope user",
            )
        )


def check_waxcore_getting_started_options(path, lines, failures):
    if path not in WAXCORE_GETTING_STARTED_DOCS:
        return

    content = "\n".join(lines)
    for stale_label in WAXCORE_GETTING_STARTED_STALE_OPTIONS:
        for index, line in enumerate(lines, start=1):
            if stale_label in line:
                failures.append(
                    Failure(
                        path,
                        index,
                        f"WaxOptions Getting Started snippet must use WAL-prefixed label instead of {stale_label}",
                    )
                )

    for required_label in WAXCORE_GETTING_STARTED_REQUIRED_OPTIONS:
        if required_label not in content:
            failures.append(
                Failure(
                    path,
                    1,
                    f"WaxOptions Getting Started snippet must include {required_label}",
                )
            )


def check_file(path):
    failures = []
    rel = display_path(path)
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except UnicodeDecodeError:
        failures.append(Failure(rel, 1, "file is not valid UTF-8"))
        return failures, 0

    check_waxcore_getting_started_options(rel, lines, failures)

    in_fence = False
    fence_lang = ""
    fence_start = 0
    block_lines = []
    fence_count = 0

    for index, line in enumerate(lines, start=1):
        match = FENCE_RE.match(line)
        if not match:
            if in_fence:
                block_lines.append((index, line))
            continue

        if not in_fence:
            in_fence = True
            fence_lang = (match.group(1) or "").lower()
            fence_start = index
            block_lines = []
            fence_count += 1
            continue

        if fence_lang in SHELL_LANGS:
            for command_line, command in shell_lines(block_lines):
                check_shell_command(rel, command_line, command, failures)
        in_fence = False
        fence_lang = ""
        fence_start = 0
        block_lines = []

    if in_fence:
        failures.append(Failure(rel, fence_start, "unclosed fenced code block"))

    return failures, fence_count


def main():
    files = selected_files()
    if not files:
        print("FAIL: no public Markdown files selected", file=sys.stderr)
        return 1

    all_failures = []
    total_fences = 0
    for path in files:
        failures, fence_count = check_file(path)
        all_failures.extend(failures)
        total_fences += fence_count

    if all_failures:
        for failure in all_failures:
            print(f"FAIL: {failure}", file=sys.stderr)
        return 1

    print(f"verify_public_snippets: ok ({len(files)} files, {total_fences} fenced snippets)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
PY
