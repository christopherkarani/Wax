#!/usr/bin/env node

const { spawnSync } = require("node:child_process");
const path = require("node:path");
const os = require("node:os");
const fs = require("node:fs");

const forwardedArgs = process.argv.slice(2);
const args = forwardedArgs.length > 0 ? forwardedArgs : ["mcp", "serve"];

function isExecutable(filePath) {
  try {
    fs.accessSync(filePath, fs.constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

function resolveBundledBinary() {
  if (os.platform() !== "darwin") {
    return null;
  }

  const arch = os.arch();
  const mappedArch = arch === "x64" ? "x64" : arch === "arm64" ? "arm64" : null;
  if (!mappedArch) {
    return null;
  }

  return path.join(__dirname, "..", "dist", `darwin-${mappedArch}`, "WaxCLI");
}

const candidates = [];
if (process.env.WAX_CLI_BIN) {
  candidates.push(process.env.WAX_CLI_BIN);
}
const bundledBinary = resolveBundledBinary();
if (bundledBinary) {
  candidates.push(bundledBinary);
}
candidates.push("wax");
candidates.push("WaxCLI");
candidates.push(path.join(process.cwd(), ".build", "debug", "WaxCLI"));

for (const command of candidates) {
  if (path.isAbsolute(command) && !isExecutable(command)) {
    continue;
  }
  const result = spawnSync(command, args, {
    stdio: "inherit",
    env: process.env,
  });

  if (result.error && result.error.code === "ENOENT") {
    continue;
  }

  if (result.error) {
    console.error(`waxmcp: failed to launch '${command}': ${result.error.message}`);
    process.exit(1);
  }

  process.exit(result.status === null ? 1 : result.status);
}

const checkedLocations = [
  process.env.WAX_CLI_BIN
    ? `  1. $WAX_CLI_BIN = ${process.env.WAX_CLI_BIN}`
    : "  1. $WAX_CLI_BIN (not set)",
  `  2. Bundled binary at dist/darwin-${os.arch()}/WaxCLI`,
  "  3. 'wax' in PATH",
  "  4. 'WaxCLI' in PATH",
  `  5. ${path.join(process.cwd(), ".build", "debug", "WaxCLI")}`,
];
console.error(`
ERROR: No valid WaxCLI binary found.

Checked:
${checkedLocations.join("\n")}

Fix options:
  Install:  npx waxmcp@latest
  Build:    swift build --product WaxCLI --traits MCPServer
  Override: export WAX_CLI_BIN=/path/to/WaxCLI
`);
process.exit(1);
