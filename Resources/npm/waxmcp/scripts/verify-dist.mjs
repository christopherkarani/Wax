#!/usr/bin/env node
import fs from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);
const { distPlatforms } = require("../bin/runtime-platforms.js");

const root = process.env.WAXMCP_PACKAGE_DIR
  ? path.resolve(process.env.WAXMCP_PACKAGE_DIR)
  : path.resolve(__dirname, "..");

// The dist directories the package publishes, from its `os` and `cpu`
// fields: darwin + arm64 is dist/darwin-arm64, linux + x64 is dist/linux-x64.
// A package that declares neither publishes darwin-arm64 only.
function publishedPlatforms() {
  const pkg = JSON.parse(fs.readFileSync(path.join(root, "package.json"), "utf8"));
  const oses = Array.isArray(pkg.os) && pkg.os.length > 0 ? pkg.os : ["darwin"];
  const cpus = Array.isArray(pkg.cpu) && pkg.cpu.length > 0 ? pkg.cpu : ["arm64"];
  const platforms = [];
  for (const osName of oses) {
    for (const cpu of cpus) {
      const key = `${osName}-${cpu}`;
      if (Object.prototype.hasOwnProperty.call(distPlatforms, key)) platforms.push(key);
    }
  }
  return platforms.length > 0 ? platforms : ["darwin-arm64"];
}

const platforms = publishedPlatforms();
const binaries = ["wax-cli", "wax-mcp"];
const missing = [];

for (const platform of platforms) {
  const dir = path.join(root, "dist", platform);
  for (const binary of binaries) {
    const binaryPath = path.join(dir, binary);
    const checksumPath = `${binaryPath}.sha256`;
    if (!fs.existsSync(binaryPath)) {
      missing.push(path.relative(root, binaryPath));
      continue;
    }
    try {
      fs.accessSync(binaryPath, fs.constants.X_OK);
    } catch {
      missing.push(`${path.relative(root, binaryPath)} (not executable)`);
    }
    if (!fs.existsSync(checksumPath)) {
      missing.push(path.relative(root, checksumPath));
    }
  }
  // MiniLM resources: `.bundle` on Apple platforms, `.resources` on Linux.
  const vectorBundle = path.join(dir, distPlatforms[platform].vectorBundle);
  if (!fs.existsSync(vectorBundle) || !fs.lstatSync(vectorBundle).isDirectory()) {
    missing.push(path.relative(root, vectorBundle));
  }
}

if (missing.length > 0) {
  console.error("waxmcp package is missing required dist artifacts:");
  for (const item of missing) {
    console.error(`  - ${item}`);
  }
  process.exit(1);
}

console.log(`waxmcp dist artifacts verified: ${platforms.join(", ")}.`);
