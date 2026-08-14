#!/usr/bin/env node
import fs from "node:fs";
import crypto from "node:crypto";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const root = process.env.WAXMCP_PACKAGE_DIR
  ? path.resolve(process.env.WAXMCP_PACKAGE_DIR)
  : path.resolve(__dirname, "..");

const platforms = new Map([
  ["darwin-arm64", 0x0100000c],
  ["darwin-x64", 0x01000007],
]);
const binaries = ["wax-cli", "wax-mcp"];
const failures = [];
const packageVersion = JSON.parse(
  fs.readFileSync(path.join(root, "package.json"), "utf8"),
).version;

for (const [platform, expectedCpuType] of platforms) {
  const dir = path.join(root, "dist", platform);
  for (const binary of binaries) {
    const binaryPath = path.join(dir, binary);
    const checksumPath = `${binaryPath}.sha256`;
    if (!fs.existsSync(binaryPath)) {
      failures.push(path.relative(root, binaryPath));
      continue;
    }
    try {
      fs.accessSync(binaryPath, fs.constants.X_OK);
    } catch {
      failures.push(`${path.relative(root, binaryPath)} (not executable)`);
    }
    if (!fs.existsSync(checksumPath)) {
      failures.push(path.relative(root, checksumPath));
    } else {
      const expectedChecksum = fs
        .readFileSync(checksumPath, "utf8")
        .trim()
        .split(/\s+/)[0];
      const actualChecksum = crypto
        .createHash("sha256")
        .update(fs.readFileSync(binaryPath))
        .digest("hex");
      if (actualChecksum !== expectedChecksum) {
        failures.push(`${path.relative(root, binaryPath)} (checksum mismatch)`);
      }
    }

    const bytes = fs.readFileSync(binaryPath);
    if (bytes.length < 8 || bytes.readUInt32LE(0) !== 0xfeedfacf) {
      failures.push(`${path.relative(root, binaryPath)} (not a thin 64-bit Mach-O binary)`);
    } else if (bytes.readUInt32LE(4) !== expectedCpuType) {
      failures.push(`${path.relative(root, binaryPath)} (wrong CPU architecture)`);
    }
  }

  const compiledModels = [
    path.join(
      dir,
      "Wax_WaxVectorSearchMiniLM.bundle",
      "all-MiniLM-L6-v2.mlmodelc",
    ),
    path.join(
      dir,
      "Wax_WaxVectorSearchArctic.bundle",
      "snowflake-arctic-embed-s.mlmodelc",
    ),
  ];
  for (const modelRoot of compiledModels) {
    for (const required of [
      "model.mil",
      "coremldata.bin",
      "metadata.json",
      path.join("analytics", "coremldata.bin"),
      path.join("weights", "weight.bin"),
    ]) {
      const modelFile = path.join(modelRoot, required);
      if (!fs.existsSync(modelFile) || fs.statSync(modelFile).size === 0) {
        failures.push(`${path.relative(root, modelFile)} (missing or empty)`);
      }
    }
  }

  const vocab = path.join(
    dir,
    "Wax_WaxBertTokenizer.bundle",
    "bert_tokenizer_vocab.txt",
  );
  if (!fs.existsSync(vocab) || fs.statSync(vocab).size === 0) {
    failures.push(`${path.relative(root, vocab)} (missing or empty)`);
  }
}

const executablePlatform = process.env.WAXMCP_VERIFY_EXECUTABLE_PLATFORM;
if (executablePlatform) {
  if (!platforms.has(executablePlatform)) {
    failures.push(`unknown executable verification platform: ${executablePlatform}`);
  } else {
    const mcpPath = path.join(root, "dist", executablePlatform, "wax-mcp");
    try {
      const output = execFileSync(mcpPath, ["--version"], {
        encoding: "utf8",
        timeout: 10_000,
      }).trim();
      if (!output.includes(packageVersion)) {
        failures.push(
          `${path.relative(root, mcpPath)} (reports '${output}', expected ${packageVersion})`,
        );
      }
    } catch (error) {
      failures.push(`${path.relative(root, mcpPath)} (--version failed: ${error.message})`);
    }
  }
}

if (failures.length > 0) {
  console.error("waxmcp package integrity verification failed:");
  for (const item of failures) {
    console.error(`  - ${item}`);
  }
  process.exit(1);
}

console.log("waxmcp dist architecture, checksums, model resources, and version verified.");
