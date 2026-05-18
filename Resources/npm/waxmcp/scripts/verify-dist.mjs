#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const root = process.env.WAXMCP_PACKAGE_DIR
  ? path.resolve(process.env.WAXMCP_PACKAGE_DIR)
  : path.resolve(__dirname, "..");

const platforms = ["darwin-arm64", "darwin-x64"];
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
}

if (missing.length > 0) {
  console.error("waxmcp package is missing required dist artifacts:");
  for (const item of missing) {
    console.error(`  - ${item}`);
  }
  process.exit(1);
}

console.log("waxmcp dist artifacts verified.");
