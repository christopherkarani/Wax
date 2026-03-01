#!/usr/bin/env node

const { spawnSync } = require("node:child_process");
const path = require("node:path");
const os = require("node:os");
const fs = require("node:fs");

const forwardedArgs = process.argv.slice(2);
const args = forwardedArgs.length > 0 ? forwardedArgs : ["mcp", "serve"];

// Detect if we're in MCP server mode (default or explicit "mcp serve")
const isMCPServe =
  (forwardedArgs.length === 0) ||
  (forwardedArgs.length >= 2 && forwardedArgs[0] === "mcp" && forwardedArgs[1] === "serve");

function isExecutable(filePath) {
  try {
    fs.accessSync(filePath, fs.constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

function platformDistDir() {
  if (os.platform() !== "darwin") {
    return null;
  }

  const arch = os.arch();
  const mappedArch = arch === "x64" ? "x64" : arch === "arm64" ? "arm64" : null;
  if (!mappedArch) {
    return null;
  }

  return path.join(__dirname, "..", "dist", `darwin-${mappedArch}`);
}

function resolveBundledBinary(name) {
  const distDir = platformDistDir();
  if (!distDir) return null;
  return path.join(distDir, name);
}

// --- MCP mode: invoke wax-mcp directly ---
if (isMCPServe) {
  // Extract flags that come after "mcp serve" (e.g. --store-path, --no-embedder)
  const mcpFlags = forwardedArgs.length >= 2 ? forwardedArgs.slice(2) : [];

  const mcpCandidates = [];
  if (process.env.WAX_MCP_BIN) {
    mcpCandidates.push(process.env.WAX_MCP_BIN);
  }
  const bundledMcp = resolveBundledBinary("wax-mcp");
  if (bundledMcp) {
    mcpCandidates.push(bundledMcp);
  }
  mcpCandidates.push("wax-mcp");
  mcpCandidates.push(path.join(process.cwd(), ".build", "debug", "wax-mcp"));

  for (const command of mcpCandidates) {
    if (path.isAbsolute(command) && !isExecutable(command)) {
      continue;
    }
    const result = spawnSync(command, mcpFlags, {
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

  // All wax-mcp candidates exhausted — fail with clear error
  const mcpCheckedLocations = [
    process.env.WAX_MCP_BIN
      ? `  1. $WAX_MCP_BIN = ${process.env.WAX_MCP_BIN}`
      : "  1. $WAX_MCP_BIN (not set)",
    `  2. Bundled binary at dist/darwin-${os.arch()}/wax-mcp`,
    "  3. 'wax-mcp' in PATH",
    `  4. ${path.join(process.cwd(), ".build", "debug", "wax-mcp")}`,
  ];
  console.error(`
ERROR: No valid wax-mcp binary found.

Checked:
${mcpCheckedLocations.join("\n")}

Fix options:
  Install:  npx waxmcp@latest
  Build:    swift build --product wax-mcp --traits MCPServer
  Override: export WAX_MCP_BIN=/path/to/wax-mcp
`);
  process.exit(1);
}

// --- CLI mode: invoke wax CLI binary ---
const candidates = [];
if (process.env.WAX_CLI_BIN) {
  candidates.push(process.env.WAX_CLI_BIN);
}
const bundledCli = resolveBundledBinary("wax-cli");
if (bundledCli) {
  candidates.push(bundledCli);
}
candidates.push("wax-cli");
candidates.push(path.join(process.cwd(), ".build", "debug", "wax-cli"));

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
  `  2. Bundled binary at dist/darwin-${os.arch()}/wax-cli`,
  "  3. 'wax-cli' in PATH",
  `  4. ${path.join(process.cwd(), ".build", "debug", "wax-cli")}`,
];
console.error(`
ERROR: No valid wax-cli binary found.

Checked:
${checkedLocations.join("\n")}

Fix options:
  Install:  npx waxmcp@latest
  Build:    swift build --product wax-cli --traits MCPServer
  Override: export WAX_CLI_BIN=/path/to/wax-cli
`);
process.exit(1);
