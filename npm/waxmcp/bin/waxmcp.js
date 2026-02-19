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

console.error("waxmcp: no Wax CLI found.");
console.error("Install and build WaxCLI, or set WAX_CLI_BIN to the WaxCLI executable path.");
console.error("Example:");
console.error("  export WAX_CLI_BIN=/path/to/Wax/.build/debug/WaxCLI");
console.error("  npx -y waxmcp@latest mcp serve");
console.error("If using the published waxmcp package, packaged binaries are at dist/darwin-arm64 and dist/darwin-x64.");
process.exit(1);
