#!/usr/bin/env node

/**
 * WaxMCP launcher — zero-config MCP server for Wax memory.
 *
 * Usage:
 *   npx waxmcp                    # Start MCP server (stdio, default store)
 *   npx waxmcp --transport http   # Start HTTP MCP server on :3000
 *   npx waxmcp --no-embedder      # Text-only search (no vector search)
 *   npx waxmcp --embedder arctic  # Use Arctic embeddings (default: minilm)
 *
 * Environment:
 *   WAX_MCP_BIN        — Override path to wax-mcp binary
 *   WAX_STORE_PATH     — Override default ~/.wax/memory.wax
 *   WAX_MCP_HTTP_PORT  — Override default HTTP port (3000)
 */

const { spawnSync, spawn } = require("node:child_process");
const path = require("node:path");
const os = require("node:os");
const fs = require("node:fs");

const forwardedArgs = process.argv.slice(2);

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

function findBinary(name) {
  const candidates = [];
  const envKey = name === "wax-mcp" ? "WAX_MCP_BIN" : "WAX_CLI_BIN";
  if (process.env[envKey]) {
    candidates.push(process.env[envKey]);
  }
  const bundled = resolveBundledBinary(name);
  if (bundled) {
    candidates.push(bundled);
  }
  candidates.push(name);
  candidates.push(path.join(process.cwd(), ".build", "debug", name));
  return candidates;
}

function runBinary(name, args) {
  for (const command of findBinary(name)) {
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
    process.env.WAX_MCP_BIN
      ? `  1. $WAX_MCP_BIN = ${process.env.WAX_MCP_BIN}`
      : "  1. $WAX_MCP_BIN (not set)",
    `  2. Bundled binary at dist/darwin-${os.arch()}/${name}`,
    `  3. '${name}' in PATH`,
    `  4. ${path.join(process.cwd(), ".build", "debug", name)}`,
  ];
  console.error(`
ERROR: No valid ${name} binary found.

Checked:
${checkedLocations.join("\n")}

Fix options:
  Install:  npm install -g waxmcp
  Build:    swift build --product ${name} --traits MCPServer
  Override: export WAX_MCP_BIN=/path/to/${name}
`);
  process.exit(1);
}

// --- Subcommand: install ---
// Download or build the native binaries
if (forwardedArgs[0] === "install") {
  const installArgs = forwardedArgs.slice(1);
  const buildFromSource = installArgs.includes("--build");

  if (buildFromSource) {
    console.log("Building Wax from source (this may take a few minutes)...");
    const traits = installArgs.includes("--arctic")
      ? "MiniLMEmbeddings,ArcticEmbeddings,MCPServer"
      : "MiniLMEmbeddings,MCPServer";

    const result = spawnSync("swift", ["build", "--product", "wax-mcp", "--traits", traits], {
      stdio: "inherit",
      cwd: process.cwd(),
      env: process.env,
    });
    if (result.status !== 0) {
      console.error("Build failed. Make sure you have Swift 6+ installed.");
      process.exit(1);
    }
    console.log("Build complete. Binary: .build/debug/wax-mcp");
    process.exit(0);
  }

  // Try to find pre-built binary
  for (const command of findBinary("wax-mcp")) {
    if (path.isAbsolute(command) && isExecutable(command)) {
      console.log(`Found: ${command}`);
      process.exit(0);
    }
  }

  console.error("No pre-built binary found. Run 'waxmcp install --build' to build from source.");
  process.exit(1);
}

// --- Subcommand: vector-health ---
// Quick diagnostic to verify vector search is working
if (forwardedArgs[0] === "vector-health") {
  const httpPort = process.env.WAX_MCP_HTTP_PORT || "3000";
  const endpoint = process.env.WAX_MCP_HTTP_ENDPOINT || `http://127.0.0.1:${httpPort}/mcp`;

  console.log(`Checking vector search health at ${endpoint}...`);

  // Simple curl-based health check
  const curl = spawnSync("curl", [
    "-s", "-X", "POST", endpoint,
    "-H", "Content-Type: application/json",
    "-H", "Accept: application/json, text/event-stream",
    "-d", JSON.stringify({
      jsonrpc: "2.0",
      id: 1,
      method: "tools/call",
      params: { name: "stats", arguments: {} }
    })
  ], { encoding: "utf-8" });

  if (curl.status !== 0 || !curl.stdout) {
    console.error("❌ Wax MCP server is not running.");
    console.error("   Start it with: npx waxmcp --transport http");
    process.exit(1);
  }

  // Parse SSE response
  const lines = curl.stdout.split("\n");
  let stats = null;
  for (const line of lines) {
    if (line.startsWith("data: ")) {
      try {
        const data = JSON.parse(line.slice(6));
        if (data.result?.content?.[0]?.text) {
          stats = JSON.parse(data.result.content[0].text);
        }
      } catch {}
    }
  }

  if (!stats) {
    console.error("❌ Could not parse stats response.");
    process.exit(1);
  }

  console.log(`\nVector search enabled: ${stats.vectorSearchEnabled}`);
  console.log(`Query embedding available: ${stats.queryEmbeddingAvailable}`);
  console.log(`Embedder: ${stats.embedder ? stats.embedder.model : "none"}`);

  if (stats.vectorSearchEnabled) {
    console.log("\n✅ Vector search is working!");
  } else {
    console.log("\n❌ Vector search is DISABLED.");
    console.log("   The broker is running in text-only mode.");
    console.log("   Fix: rebuild with embedders:");
    console.log("     swift build --product wax-mcp --traits 'MiniLMEmbeddings,ArcticEmbeddings,MCPServer'");
    console.log("     swift build --product wax-cli --traits 'MiniLMEmbeddings,ArcticEmbeddings'");
  }
  process.exit(stats.vectorSearchEnabled ? 0 : 1);
}

// --- Subcommand: install-hermes-plugin ---
if (forwardedArgs[0] === "install-hermes-plugin") {
  const hermesPluginsDir = path.join(os.homedir(), ".hermes", "plugins", "wax-memory");
  const pluginSrcDir = path.join(__dirname, "..", "plugins", "hermes");

  if (!fs.existsSync(pluginSrcDir)) {
    console.error("❌ Hermes plugin not found in package.");
    console.error("   This is a packaging bug — please report it.");
    process.exit(1);
  }

  console.log(`Installing Wax Hermes plugin to ${hermesPluginsDir}...`);

  // Ensure parent directory exists
  fs.mkdirSync(path.dirname(hermesPluginsDir), { recursive: true });

  // Remove old installation if present
  if (fs.existsSync(hermesPluginsDir)) {
    fs.rmSync(hermesPluginsDir, { recursive: true });
  }

  // Copy plugin files
  fs.mkdirSync(hermesPluginsDir, { recursive: true });
  for (const file of fs.readdirSync(pluginSrcDir)) {
    const src = path.join(pluginSrcDir, file);
    const dest = path.join(hermesPluginsDir, file);
    if (fs.statSync(src).isDirectory()) {
      fs.cpSync(src, dest, { recursive: true });
    } else {
      fs.copyFileSync(src, dest);
    }
  }

  console.log("✅ Hermes plugin installed.");
  console.log("");
  console.log("Next steps:");
  console.log("  1. Start Wax MCP:  npx waxmcp --transport http");
  console.log("  2. Enable plugin:   hermes config set memory.provider wax-memory");
  console.log("  3. Run Hermes:      hermes");
  process.exit(0);
}

// --- Subcommand: install-openclaw-plugin ---
if (forwardedArgs[0] === "install-openclaw-plugin") {
  const openclawDir = path.join(os.homedir(), ".openclaw");
  const pluginSrcDir = path.join(__dirname, "..", "plugins", "openclaw");

  if (!fs.existsSync(pluginSrcDir)) {
    console.error("❌ OpenClaw plugin not found in package.");
    console.error("   This is a packaging bug — please report it.");
    process.exit(1);
  }

  console.log("OpenClaw plugin is distributed as an npm package.");
  console.log("");
  console.log("Install it with:");
  console.log("  npm install -g @wax/openclaw-wax-memory");
  console.log("");
  console.log("Or, if you have the OpenClaw CLI:");
  console.log("  openclaw plugin install @wax/openclaw-wax-memory");
  console.log("");
  console.log("The plugin source is also bundled at:");
  console.log(`  ${pluginSrcDir}`);
  process.exit(0);
}

// --- Subcommand: install-all-plugins ---
if (forwardedArgs[0] === "install-all-plugins") {
  console.log("Installing all Wax plugins...\n");

  // Hermes
  const hermesPluginsDir = path.join(os.homedir(), ".hermes", "plugins", "wax-memory");
  const hermesSrcDir = path.join(__dirname, "..", "plugins", "hermes");
  if (fs.existsSync(hermesSrcDir)) {
    fs.mkdirSync(path.dirname(hermesPluginsDir), { recursive: true });
    if (fs.existsSync(hermesPluginsDir)) {
      fs.rmSync(hermesPluginsDir, { recursive: true });
    }
    fs.mkdirSync(hermesPluginsDir, { recursive: true });
    for (const file of fs.readdirSync(hermesSrcDir)) {
      const src = path.join(hermesSrcDir, file);
      const dest = path.join(hermesPluginsDir, file);
      if (fs.statSync(src).isDirectory()) {
        fs.cpSync(src, dest, { recursive: true });
      } else {
        fs.copyFileSync(src, dest);
      }
    }
    console.log("✅ Hermes plugin installed to ~/.hermes/plugins/wax-memory/");
  }

  console.log("\n🎉 All plugins installed!");
  console.log("\nNext steps:");
  console.log("  1. Start Wax MCP:     npx waxmcp --transport http");
  console.log("  2. Enable in Hermes:  hermes config set memory.provider wax-memory");
  console.log("  3. Run Hermes:        hermes");
  console.log("\nFor OpenClaw:");
  console.log("  npm install -g @wax/openclaw-wax-memory");
  process.exit(0);
}

// --- Default: run MCP server ---
// Translate 'mcp serve' to native wax-mcp flags
const mcpFlags = [];
let i = 0;
while (i < forwardedArgs.length) {
  const arg = forwardedArgs[i];

  // Skip 'mcp serve' prefix (legacy compatibility)
  if (arg === "mcp") {
    i++;
    if (forwardedArgs[i] === "serve") {
      i++;
      continue;
    }
    // 'mcp' without 'serve' — pass through
    mcpFlags.push(arg);
    i++;
    continue;
  }

  // Pass through all other flags
  mcpFlags.push(arg);
  i++;
}

// Auto-detect if we should add default embedder
if (!mcpFlags.includes("--no-embedder") && !mcpFlags.some(f => f.startsWith("--embedder"))) {
  // Default to arctic (most reliable across builds)
  // MiniLM can produce non-finite embeddings in some release builds
  mcpFlags.unshift("--embedder", "arctic");
}

runBinary("wax-mcp", mcpFlags);
