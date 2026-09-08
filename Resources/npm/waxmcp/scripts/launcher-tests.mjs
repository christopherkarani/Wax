#!/usr/bin/env node
import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const scriptsDir = path.dirname(fileURLToPath(import.meta.url));
const packageRoot = path.resolve(scriptsDir, "..");
const launcher = path.join(packageRoot, "bin", "waxmcp.js");
const packageVersion = JSON.parse(
  fs.readFileSync(path.join(packageRoot, "package.json"), "utf8")
).version;
const requiredRuntimeBundles = [
  "GRDB_GRDB.bundle",
  "MetalANNS_MetalANNSCore.bundle",
  "Wax_Wax.bundle",
  "Wax_WaxBertTokenizer.bundle",
  "Wax_WaxVectorSearch.bundle",
  "Wax_WaxVectorSearchMiniLM.bundle",
  "swift-crypto_Crypto.bundle",
  "swift-nio_NIOPosix.bundle",
];

function makeExecutable(file, content) {
  fs.writeFileSync(file, content, { mode: 0o755 });
  fs.chmodSync(file, 0o755);
}

function makeRuntimeSource(directory, serverContent, cliContent) {
  fs.mkdirSync(directory);
  const server = path.join(directory, "wax-mcp");
  const cli = path.join(directory, "wax-cli");
  makeExecutable(server, serverContent);
  makeExecutable(cli, cliContent);
  for (const bundle of requiredRuntimeBundles) {
    const bundlePath = path.join(directory, bundle);
    fs.mkdirSync(bundlePath);
    fs.writeFileSync(path.join(bundlePath, "resource.txt"), `${bundle}\n`);
  }
  return { server, cli };
}

function sha256(file) {
  return crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex");
}

function runAsync(args, env) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [launcher, ...args], { env });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", chunk => { stdout += chunk; });
    child.stderr.on("data", chunk => { stderr += chunk; });
    child.on("error", reject);
    child.on("close", status => resolve({ status, stdout, stderr }));
  });
}

test("install stages and idempotently upgrades the complete runtime", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "waxmcp-install-test-"));
  try {
    const sourceDir = path.join(root, "source");
    const installRoot = path.join(root, "installed");
    const { server, cli } = makeRuntimeSource(
      sourceDir,
      "#!/bin/sh\necho server-v1\n",
      "#!/bin/sh\necho cli-v1\n"
    );
    const env = {
      ...process.env,
      WAX_MCP_BIN: server,
      WAX_CLI_BIN: cli,
      WAX_MCP_INSTALL_ROOT: installRoot,
    };

    const first = spawnSync(process.execPath, [launcher, "install"], { env, encoding: "utf8" });
    assert.equal(first.status, 0, first.stderr);
    const platformKey = `${os.platform()}-${os.arch()}`;
    const installedServer = path.join(installRoot, "runtime", platformKey, "wax-mcp");
    const installedCLI = path.join(installRoot, "runtime", platformKey, "wax-cli");
    const httpLauncher = path.join(installRoot, "bin", "start-wax-mcp-http.sh");
    assert.match(fs.readFileSync(installedServer, "utf8"), /server-v1/);
    assert.match(fs.readFileSync(installedCLI, "utf8"), /cli-v1/);
    assert.equal(fs.existsSync(`${installedServer}.sha256`), true);
    assert.equal(fs.existsSync(`${installedCLI}.sha256`), true);
    for (const bundle of requiredRuntimeBundles) {
      assert.equal(fs.existsSync(path.join(installRoot, "runtime", platformKey, bundle)), true);
    }
    const installManifest = JSON.parse(fs.readFileSync(path.join(installRoot, "install.json")));
    assert.equal(installManifest.version, packageVersion);
    assert.equal(installManifest.platform, platformKey);
    assert.deepEqual(installManifest.runtime.bundles, requiredRuntimeBundles);
    assert.equal(installManifest.runtime.files["wax-mcp"], sha256(installedServer));
    assert.equal(installManifest.runtime.files["wax-cli"], sha256(installedCLI));
    assert.equal(
      installManifest.runtime.files[`${requiredRuntimeBundles[0]}/resource.txt`],
      sha256(path.join(installRoot, "runtime", platformKey, requiredRuntimeBundles[0], "resource.txt"))
    );
    assert.equal(fs.existsSync(path.join(installRoot, "skills", "wax-mcp", "SKILL.md")), true);
    assert.equal(fs.existsSync(path.join(installRoot, "plugins", "hermes", "hermes_wax_memory.py")), true);
    assert.equal(fs.existsSync(path.join(installRoot, "plugins", "hermes", "wax_memory_lifecycle.py")), true);
    assert.match(fs.readFileSync(httpLauncher, "utf8"), /--transport http/);
    assert.equal((fs.statSync(httpLauncher).mode & 0o111) !== 0, true);
    assert.equal(JSON.parse(fs.readFileSync(path.join(installRoot, "install.json"))).version, packageVersion);

    makeExecutable(server, "#!/bin/sh\necho server-v2\n");
    const second = spawnSync(process.execPath, [launcher, "setup"], { env, encoding: "utf8" });
    assert.equal(second.status, 0, second.stderr);
    assert.match(fs.readFileSync(installedServer, "utf8"), /server-v2/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("raw launcher and staged HTTP launcher both default to MiniLM", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "waxmcp-embedder-default-test-"));
  try {
    const sourceDir = path.join(root, "source");
    const installRoot = path.join(root, "installed");
    const capturedArgs = path.join(root, "args.txt");
    const { server, cli } = makeRuntimeSource(
      sourceDir,
      "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$WAX_ARGS_FILE\"\n",
      "#!/bin/sh\nexit 0\n"
    );
    const env = {
      ...process.env,
      WAX_MCP_BIN: server,
      WAX_CLI_BIN: cli,
      WAX_ARGS_FILE: capturedArgs,
      WAX_MCP_INSTALL_ROOT: installRoot,
    };

    const raw = spawnSync(process.execPath, [launcher, "--transport", "http"], {
      env,
      encoding: "utf8",
    });
    assert.equal(raw.status, 0, raw.stderr);
    assert.deepEqual(
      fs.readFileSync(capturedArgs, "utf8").trim().split("\n").slice(0, 2),
      ["--embedder", "minilm"]
    );

    const installed = spawnSync(process.execPath, [launcher, "install"], {
      env,
      encoding: "utf8",
    });
    assert.equal(installed.status, 0, installed.stderr);
    const stagedLauncher = fs.readFileSync(
      path.join(installRoot, "bin", "start-wax-mcp-http.sh"),
      "utf8"
    );
    assert.match(stagedLauncher, /--embedder minilm/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("install-hermes-plugin also stages a verified persistent runtime", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "waxmcp-hermes-install-test-"));
  try {
    const sourceDir = path.join(root, "source");
    const installRoot = path.join(root, "installed");
    const hermesHome = path.join(root, "hermes");
    const { server, cli } = makeRuntimeSource(
      sourceDir,
      "#!/bin/sh\necho server\n",
      "#!/bin/sh\necho cli\n"
    );

    const result = spawnSync(process.execPath, [launcher, "install-hermes-plugin"], {
      env: {
        ...process.env,
        WAX_MCP_BIN: server,
        WAX_CLI_BIN: cli,
        WAX_MCP_INSTALL_ROOT: installRoot,
        HERMES_HOME: hermesHome,
      },
      encoding: "utf8",
    });
    assert.equal(result.status, 0, result.stderr);

    const platformKey = `${os.platform()}-${os.arch()}`;
    const installedServer = path.join(installRoot, "runtime", platformKey, "wax-mcp");
    const installedCLI = path.join(installRoot, "runtime", platformKey, "wax-cli");
    const stagedLauncher = path.join(installRoot, "bin", "start-wax-mcp-http.sh");
    assert.equal(fs.existsSync(installedServer), true);
    assert.equal(fs.existsSync(`${installedServer}.sha256`), true);
    assert.equal(fs.existsSync(installedCLI), true);
    assert.equal(fs.existsSync(`${installedCLI}.sha256`), true);
    assert.equal(fs.existsSync(stagedLauncher), true);
    assert.equal(
      fs.existsSync(path.join(hermesHome, "plugins", "wax-memory", "hermes_wax_memory.py")),
      true
    );
    assert.equal(
      fs.existsSync(path.join(hermesHome, "plugins", "wax-memory", "cli.py")),
      true
    );
    assert.match(result.stdout, new RegExp(stagedLauncher.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
    assert.doesNotMatch(result.stdout, /npx waxmcp --transport http/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("install-hermes-plugin preserves an existing manifest-verified runtime", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "waxmcp-hermes-preserve-runtime-test-"));
  try {
    const sourceDir = path.join(root, "source");
    const installRoot = path.join(root, "installed");
    const hermesHome = path.join(root, "hermes");
    const { server, cli } = makeRuntimeSource(
      sourceDir,
      "#!/bin/sh\necho source-build-server\n",
      "#!/bin/sh\necho source-build-cli\n"
    );
    const installEnv = {
      ...process.env,
      WAX_MCP_BIN: server,
      WAX_CLI_BIN: cli,
      WAX_MCP_INSTALL_ROOT: installRoot,
    };

    const install = spawnSync(process.execPath, [launcher, "install"], {
      env: installEnv,
      encoding: "utf8",
    });
    assert.equal(install.status, 0, install.stderr);

    const platformKey = `${os.platform()}-${os.arch()}`;
    const installedServer = path.join(installRoot, "runtime", platformKey, "wax-mcp");
    const installedCLI = path.join(installRoot, "runtime", platformKey, "wax-cli");
    const serverBefore = sha256(installedServer);
    const cliBefore = sha256(installedCLI);
    const serverChecksumBefore = fs.readFileSync(`${installedServer}.sha256`, "utf8");
    const cliChecksumBefore = fs.readFileSync(`${installedCLI}.sha256`, "utf8");
    const provenanceBefore = fs.readFileSync(path.join(installRoot, "install.json"), "utf8");

    const hermesInstall = spawnSync(process.execPath, [launcher, "install-hermes-plugin"], {
      env: {
        ...process.env,
        WAX_MCP_INSTALL_ROOT: installRoot,
        HERMES_HOME: hermesHome,
      },
      encoding: "utf8",
    });
    assert.equal(hermesInstall.status, 0, hermesInstall.stderr);
    assert.match(hermesInstall.stdout, /Reusing manifest-verified Wax MCP runtime/);
    assert.equal(sha256(installedServer), serverBefore);
    assert.equal(sha256(installedCLI), cliBefore);
    assert.equal(fs.readFileSync(`${installedServer}.sha256`, "utf8"), serverChecksumBefore);
    assert.equal(fs.readFileSync(`${installedCLI}.sha256`, "utf8"), cliChecksumBefore);
    assert.equal(fs.readFileSync(path.join(installRoot, "install.json"), "utf8"), provenanceBefore);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("install-hermes-plugin replaces a runtime that fails binary or resource digest verification", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "waxmcp-hermes-repair-runtime-test-"));
  try {
    const sourceDir = path.join(root, "source");
    const installRoot = path.join(root, "installed");
    const hermesHome = path.join(root, "hermes");
    const { server, cli } = makeRuntimeSource(
      sourceDir,
      "#!/bin/sh\necho replacement-server\n",
      "#!/bin/sh\necho replacement-cli\n"
    );
    const env = {
      ...process.env,
      WAX_MCP_BIN: server,
      WAX_CLI_BIN: cli,
      WAX_MCP_INSTALL_ROOT: installRoot,
      HERMES_HOME: hermesHome,
    };

    const install = spawnSync(process.execPath, [launcher, "install"], {
      env,
      encoding: "utf8",
    });
    assert.equal(install.status, 0, install.stderr);

    const platformKey = `${os.platform()}-${os.arch()}`;
    const installedServer = path.join(installRoot, "runtime", platformKey, "wax-mcp");
    const installedCLI = path.join(installRoot, "runtime", platformKey, "wax-cli");
    fs.writeFileSync(installedServer, "tampered", { mode: 0o755 });

    const hermesInstall = spawnSync(process.execPath, [launcher, "install-hermes-plugin"], {
      env,
      encoding: "utf8",
    });
    assert.equal(hermesInstall.status, 0, hermesInstall.stderr);
    assert.equal(sha256(installedServer), sha256(server));
    assert.equal(sha256(installedCLI), sha256(cli));
    assert.doesNotMatch(hermesInstall.stdout, /Reusing manifest-verified/);

    const installedResource = path.join(
      installRoot, "runtime", platformKey, requiredRuntimeBundles[0], "resource.txt"
    );
    const sourceResource = path.join(sourceDir, requiredRuntimeBundles[0], "resource.txt");
    fs.writeFileSync(installedResource, "tampered-resource\n");
    const resourceRepair = spawnSync(process.execPath, [launcher, "install-hermes-plugin"], {
      env,
      encoding: "utf8",
    });
    assert.equal(resourceRepair.status, 0, resourceRepair.stderr);
    assert.equal(sha256(installedResource), sha256(sourceResource));
    assert.doesNotMatch(resourceRepair.stdout, /Reusing manifest-verified/);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("install-hermes-plugin rejects stale provenance and restages the whole runtime", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "waxmcp-hermes-stale-runtime-test-"));
  try {
    const sourceDir = path.join(root, "source");
    const installRoot = path.join(root, "installed");
    const hermesHome = path.join(root, "hermes");
    const { server, cli } = makeRuntimeSource(
      sourceDir,
      "#!/bin/sh\necho generation-one-server\n",
      "#!/bin/sh\necho generation-one-cli\n"
    );
    const env = {
      ...process.env,
      WAX_MCP_BIN: server,
      WAX_CLI_BIN: cli,
      WAX_MCP_INSTALL_ROOT: installRoot,
      HERMES_HOME: hermesHome,
    };
    const install = spawnSync(process.execPath, [launcher, "install"], { env, encoding: "utf8" });
    assert.equal(install.status, 0, install.stderr);

    const manifestPath = path.join(installRoot, "install.json");
    const staleManifest = JSON.parse(fs.readFileSync(manifestPath));
    staleManifest.version = "0.0.0-stale";
    fs.writeFileSync(manifestPath, `${JSON.stringify(staleManifest, null, 2)}\n`);
    makeExecutable(server, "#!/bin/sh\necho generation-two-server\n");
    makeExecutable(cli, "#!/bin/sh\necho generation-two-cli\n");

    const hermesInstall = spawnSync(process.execPath, [launcher, "install-hermes-plugin"], {
      env,
      encoding: "utf8",
    });
    assert.equal(hermesInstall.status, 0, hermesInstall.stderr);
    assert.doesNotMatch(hermesInstall.stdout, /Reusing manifest-verified/);
    const platformKey = `${os.platform()}-${os.arch()}`;
    assert.equal(
      sha256(path.join(installRoot, "runtime", platformKey, "wax-mcp")),
      sha256(server)
    );
    assert.equal(JSON.parse(fs.readFileSync(manifestPath)).version, packageVersion);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("install rolls back the live runtime when a later commit step fails", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "waxmcp-post-runtime-rollback-test-"));
  try {
    const sourceDir = path.join(root, "source");
    const installRoot = path.join(root, "installed");
    const { server, cli } = makeRuntimeSource(
      sourceDir,
      "#!/bin/sh\necho generation-one-server\n",
      "#!/bin/sh\necho generation-one-cli\n"
    );
    const env = {
      ...process.env,
      WAX_MCP_BIN: server,
      WAX_CLI_BIN: cli,
      WAX_MCP_INSTALL_ROOT: installRoot,
    };
    const first = spawnSync(process.execPath, [launcher, "install"], { env, encoding: "utf8" });
    assert.equal(first.status, 0, first.stderr);
    const platformKey = `${os.platform()}-${os.arch()}`;
    const runtimeDir = path.join(installRoot, "runtime", platformKey);
    const firstServer = sha256(path.join(runtimeDir, "wax-mcp"));
    const firstCLI = sha256(path.join(runtimeDir, "wax-cli"));
    const firstResource = sha256(path.join(runtimeDir, requiredRuntimeBundles[0], "resource.txt"));
    const firstManifest = fs.readFileSync(path.join(installRoot, "install.json"), "utf8");
    const firstLauncher = fs.readFileSync(path.join(installRoot, "bin", "start-wax-mcp-http.sh"), "utf8");
    const firstSkill = fs.readFileSync(path.join(installRoot, "skills", "wax-mcp", "SKILL.md"), "utf8");

    makeExecutable(server, "#!/bin/sh\necho generation-two-server\n");
    makeExecutable(cli, "#!/bin/sh\necho generation-two-cli\n");
    fs.writeFileSync(
      path.join(sourceDir, requiredRuntimeBundles[0], "resource.txt"),
      "generation-two-resource\n"
    );
    const failed = spawnSync(process.execPath, [launcher, "install"], {
      env: { ...env, NODE_ENV: "test", WAX_MCP_TEST_FAIL_AFTER_RUNTIME_SWAP: "1" },
      encoding: "utf8",
    });
    assert.notEqual(failed.status, 0);
    assert.equal(sha256(path.join(runtimeDir, "wax-mcp")), firstServer);
    assert.equal(sha256(path.join(runtimeDir, "wax-cli")), firstCLI);
    assert.equal(
      sha256(path.join(runtimeDir, requiredRuntimeBundles[0], "resource.txt")),
      firstResource
    );
    assert.equal(fs.readFileSync(path.join(installRoot, "install.json"), "utf8"), firstManifest);
    assert.equal(
      fs.readFileSync(path.join(runtimeDir, "runtime-manifest.json"), "utf8"),
      firstManifest
    );
    assert.equal(
      fs.readFileSync(path.join(installRoot, "bin", "start-wax-mcp-http.sh"), "utf8"),
      firstLauncher
    );
    assert.equal(
      fs.readFileSync(path.join(installRoot, "skills", "wax-mcp", "SKILL.md"), "utf8"),
      firstSkill
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("failed runtime generation swap rolls back without mixing binaries", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "waxmcp-runtime-rollback-test-"));
  try {
    const sourceDir = path.join(root, "source");
    const installRoot = path.join(root, "installed");
    const { server, cli } = makeRuntimeSource(
      sourceDir,
      "#!/bin/sh\necho generation-one-server\n",
      "#!/bin/sh\necho generation-one-cli\n"
    );
    const env = {
      ...process.env,
      WAX_MCP_BIN: server,
      WAX_CLI_BIN: cli,
      WAX_MCP_INSTALL_ROOT: installRoot,
    };
    const first = spawnSync(process.execPath, [launcher, "install"], { env, encoding: "utf8" });
    assert.equal(first.status, 0, first.stderr);
    const platformKey = `${os.platform()}-${os.arch()}`;
    const runtimeDir = path.join(installRoot, "runtime", platformKey);
    const firstServer = sha256(path.join(runtimeDir, "wax-mcp"));
    const firstCLI = sha256(path.join(runtimeDir, "wax-cli"));
    const installedResource = path.join(runtimeDir, requiredRuntimeBundles[0], "resource.txt");
    const firstResource = sha256(installedResource);
    const firstManifest = fs.readFileSync(path.join(installRoot, "install.json"), "utf8");

    makeExecutable(server, "#!/bin/sh\necho generation-two-server\n");
    makeExecutable(cli, "#!/bin/sh\necho generation-two-cli\n");
    fs.writeFileSync(
      path.join(sourceDir, requiredRuntimeBundles[0], "resource.txt"),
      "generation-two-resource\n"
    );
    const failed = spawnSync(process.execPath, [launcher, "install"], {
      env: { ...env, NODE_ENV: "test", WAX_MCP_TEST_FAIL_RUNTIME_SWAP: "1" },
      encoding: "utf8",
    });
    assert.notEqual(failed.status, 0);
    assert.equal(sha256(path.join(runtimeDir, "wax-mcp")), firstServer);
    assert.equal(sha256(path.join(runtimeDir, "wax-cli")), firstCLI);
    assert.equal(sha256(installedResource), firstResource);
    assert.equal(fs.readFileSync(path.join(installRoot, "install.json"), "utf8"), firstManifest);
    assert.equal(
      fs.readFileSync(path.join(runtimeDir, "runtime-manifest.json"), "utf8"),
      firstManifest
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("first-run install-hermes-plugin stages bundled runtime binaries", {
  skip: process.platform !== "darwin" || process.arch !== "arm64",
}, () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "waxmcp-hermes-bundled-runtime-test-"));
  try {
    const installRoot = path.join(root, "installed");
    const hermesHome = path.join(root, "hermes");
    const result = spawnSync(process.execPath, [launcher, "install-hermes-plugin"], {
      env: {
        ...process.env,
        WAX_MCP_BIN: "",
        WAX_CLI_BIN: "",
        WAX_MCP_INSTALL_ROOT: installRoot,
        HERMES_HOME: hermesHome,
      },
      encoding: "utf8",
    });
    assert.equal(result.status, 0, result.stderr);

    const platformKey = `${os.platform()}-${os.arch()}`;
    for (const name of ["wax-mcp", "wax-cli"]) {
      const bundled = path.join(packageRoot, "dist", platformKey, name);
      const installed = path.join(installRoot, "runtime", platformKey, name);
      assert.equal(sha256(installed), sha256(bundled));
      assert.equal(
        fs.readFileSync(`${installed}.sha256`, "utf8"),
        fs.readFileSync(`${bundled}.sha256`, "utf8")
      );
    }
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("install refuses symlinked managed paths without touching their targets", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "waxmcp-symlink-test-"));
  try {
    const sourceDir = path.join(root, "source");
    const installRoot = path.join(root, "installed");
    const victim = path.join(root, "victim");
    fs.mkdirSync(victim);
    const { server, cli } = makeRuntimeSource(
      sourceDir,
      "#!/bin/sh\necho safe-server\n",
      "#!/bin/sh\necho safe-cli\n"
    );
    const sentinel = path.join(victim, "sentinel.txt");
    fs.writeFileSync(sentinel, "unchanged");
    fs.mkdirSync(installRoot);
    fs.symlinkSync(victim, path.join(installRoot, "runtime"));

    const env = {
      ...process.env,
      WAX_MCP_BIN: server,
      WAX_CLI_BIN: cli,
      WAX_MCP_INSTALL_ROOT: installRoot,
    };
    const runtimeAttack = spawnSync(process.execPath, [launcher, "install"], {
      env,
      encoding: "utf8",
    });
    assert.notEqual(runtimeAttack.status, 0);
    assert.equal(fs.readFileSync(sentinel, "utf8"), "unchanged");
    assert.deepEqual(fs.readdirSync(victim), ["sentinel.txt"]);

    fs.unlinkSync(path.join(installRoot, "runtime"));
    fs.mkdirSync(path.join(installRoot, "runtime"));
    fs.symlinkSync(victim, path.join(installRoot, "skills"));
    const skillAttack = spawnSync(process.execPath, [launcher, "install"], {
      env,
      encoding: "utf8",
    });
    assert.notEqual(skillAttack.status, 0);
    assert.equal(fs.readFileSync(sentinel, "utf8"), "unchanged");
    assert.deepEqual(fs.readdirSync(victim), ["sentinel.txt"]);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("install refuses a symlinked install root without touching its target", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "waxmcp-root-symlink-test-"));
  try {
    const sourceDir = path.join(root, "source");
    const victim = path.join(root, "victim");
    const installRoot = path.join(root, "linked-root");
    fs.mkdirSync(victim);
    const sentinel = path.join(victim, "sentinel.txt");
    fs.writeFileSync(sentinel, "unchanged");
    fs.symlinkSync(victim, installRoot);
    const { server, cli } = makeRuntimeSource(
      sourceDir,
      "#!/bin/sh\necho safe-server\n",
      "#!/bin/sh\necho safe-cli\n"
    );
    const result = spawnSync(process.execPath, [launcher, "install"], {
      env: {
        ...process.env,
        WAX_MCP_BIN: server,
        WAX_CLI_BIN: cli,
        WAX_MCP_INSTALL_ROOT: installRoot,
      },
      encoding: "utf8",
    });
    assert.notEqual(result.status, 0);
    assert.equal(fs.readFileSync(sentinel, "utf8"), "unchanged");
    assert.deepEqual(fs.readdirSync(victim), ["sentinel.txt"]);
    assert.equal(fs.lstatSync(installRoot).isSymbolicLink(), true);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("install refuses a symlinked parent of the HTTP launcher", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "waxmcp-bin-symlink-test-"));
  try {
    const sourceDir = path.join(root, "source");
    const installRoot = path.join(root, "installed");
    const victim = path.join(root, "victim");
    fs.mkdirSync(victim);
    const sentinel = path.join(victim, "sentinel.txt");
    fs.writeFileSync(sentinel, "unchanged");
    fs.mkdirSync(installRoot);
    fs.symlinkSync(victim, path.join(installRoot, "bin"));
    const { server, cli } = makeRuntimeSource(
      sourceDir,
      "#!/bin/sh\necho safe-server\n",
      "#!/bin/sh\necho safe-cli\n"
    );
    const result = spawnSync(process.execPath, [launcher, "install"], {
      env: {
        ...process.env,
        WAX_MCP_BIN: server,
        WAX_CLI_BIN: cli,
        WAX_MCP_INSTALL_ROOT: installRoot,
      },
      encoding: "utf8",
    });
    assert.notEqual(result.status, 0);
    assert.equal(fs.readFileSync(sentinel, "utf8"), "unchanged");
    assert.deepEqual(fs.readdirSync(victim), ["sentinel.txt"]);
    assert.equal(fs.lstatSync(path.join(installRoot, "bin")).isSymbolicLink(), true);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("install-hermes-plugin refuses a symlinked plugin destination", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "waxmcp-hermes-symlink-test-"));
  try {
    const sourceDir = path.join(root, "source");
    const installRoot = path.join(root, "installed");
    const hermesHome = path.join(root, "hermes");
    const victim = path.join(root, "victim");
    fs.mkdirSync(victim);
    const sentinel = path.join(victim, "sentinel.txt");
    fs.writeFileSync(sentinel, "unchanged");
    const { server, cli } = makeRuntimeSource(
      sourceDir,
      "#!/bin/sh\necho safe-server\n",
      "#!/bin/sh\necho safe-cli\n"
    );
    const env = {
      ...process.env,
      WAX_MCP_BIN: server,
      WAX_CLI_BIN: cli,
      WAX_MCP_INSTALL_ROOT: installRoot,
      HERMES_HOME: hermesHome,
    };
    const install = spawnSync(process.execPath, [launcher, "install"], { env, encoding: "utf8" });
    assert.equal(install.status, 0, install.stderr);
    fs.mkdirSync(path.join(hermesHome, "plugins"), { recursive: true });
    fs.symlinkSync(victim, path.join(hermesHome, "plugins", "wax-memory"));
    const hermesInstall = spawnSync(process.execPath, [launcher, "install-hermes-plugin"], {
      env,
      encoding: "utf8",
    });
    assert.notEqual(hermesInstall.status, 0);
    assert.equal(fs.readFileSync(sentinel, "utf8"), "unchanged");
    assert.deepEqual(fs.readdirSync(victim), ["sentinel.txt"]);
    assert.equal(fs.lstatSync(path.join(hermesHome, "plugins", "wax-memory")).isSymbolicLink(), true);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("install refuses a group or world-writable custom install root", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "waxmcp-unsafe-root-test-"));
  const unsafeRoot = path.join(root, "shared");
  try {
    const sourceDir = path.join(root, "source");
    const { server, cli } = makeRuntimeSource(
      sourceDir,
      "#!/bin/sh\necho safe-server\n",
      "#!/bin/sh\necho safe-cli\n"
    );
    fs.mkdirSync(unsafeRoot, { mode: 0o777 });
    fs.chmodSync(unsafeRoot, 0o777);
    const installRoot = path.join(unsafeRoot, "waxmcp");

    const result = spawnSync(process.execPath, [launcher, "install"], {
      env: {
        ...process.env,
        WAX_MCP_BIN: server,
        WAX_CLI_BIN: cli,
        WAX_MCP_INSTALL_ROOT: installRoot,
      },
      encoding: "utf8",
    });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /unsafe install directory permissions/);
    assert.equal(fs.existsSync(installRoot), false);

    fs.mkdirSync(installRoot, { mode: 0o700 });
    const existingRootResult = spawnSync(process.execPath, [launcher, "install"], {
      env: {
        ...process.env,
        WAX_MCP_BIN: server,
        WAX_CLI_BIN: cli,
        WAX_MCP_INSTALL_ROOT: installRoot,
      },
      encoding: "utf8",
    });
    assert.notEqual(existingRootResult.status, 0);
    assert.match(existingRootResult.stderr, /unsafe install directory permissions/);
    assert.deepEqual(fs.readdirSync(installRoot), []);
  } finally {
    fs.chmodSync(unsafeRoot, 0o700);
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("install refuses symlinked files at every atomic destination", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "waxmcp-file-symlink-test-"));
  try {
    const sourceDir = path.join(root, "source");
    const { server, cli } = makeRuntimeSource(
      sourceDir,
      "#!/bin/sh\necho safe-server\n",
      "#!/bin/sh\necho safe-cli\n"
    );
    const platformKey = `${os.platform()}-${os.arch()}`;
    const destinations = [
      path.join("runtime", platformKey, "wax-mcp"),
      path.join("runtime", platformKey, "wax-mcp.sha256"),
      path.join("bin", "start-wax-mcp-http.sh"),
      "install.json",
    ];

    for (const [index, relativeDestination] of destinations.entries()) {
      const installRoot = path.join(root, `installed-${index}`);
      const victim = path.join(root, `victim-${index}.txt`);
      fs.writeFileSync(victim, `unchanged-${index}`);
      const destination = path.join(installRoot, relativeDestination);
      fs.mkdirSync(path.dirname(destination), { recursive: true });
      fs.symlinkSync(victim, destination);
      const result = spawnSync(process.execPath, [launcher, "install"], {
        env: {
          ...process.env,
          WAX_MCP_BIN: server,
          WAX_CLI_BIN: cli,
          WAX_MCP_INSTALL_ROOT: installRoot,
        },
        encoding: "utf8",
      });
      assert.notEqual(result.status, 0, `accepted symlink at ${relativeDestination}`);
      assert.equal(fs.readFileSync(victim, "utf8"), `unchanged-${index}`);
      assert.equal(fs.lstatSync(destination).isSymbolicLink(), true);
    }
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("vector-health performs the MCP initialize and session handshake", async () => {
  const sessionID = "test-mcp-session";
  const seen = [];
  const server = http.createServer((request, response) => {
    let body = "";
    request.on("data", chunk => { body += chunk; });
    request.on("end", () => {
      if (request.method === "DELETE") {
        assert.equal(request.headers["mcp-session-id"], sessionID);
        seen.push("DELETE");
        response.statusCode = 204;
        response.end();
        return;
      }
      const message = JSON.parse(body);
      if (message.method === "initialize") {
        seen.push("initialize");
        response.setHeader("MCP-Session-Id", sessionID);
        response.setHeader("Content-Type", "application/json");
        response.end(JSON.stringify({ jsonrpc: "2.0", id: 1, result: { capabilities: {} } }));
        return;
      }
      assert.equal(request.headers["mcp-session-id"], sessionID);
      if (message.method === "notifications/initialized") {
        seen.push("initialized");
        response.statusCode = 202;
        response.end();
        return;
      }
      assert.equal(message.method, "tools/call");
      assert.equal(message.params?.name, "stats");
      seen.push("stats");
      response.setHeader("Content-Type", "text/event-stream");
      response.end(`data: ${JSON.stringify({
        jsonrpc: "2.0",
        id: 2,
        result: {
          content: [{
            type: "text",
            text: JSON.stringify({
              vectorSearchEnabled: true,
              queryEmbeddingAvailable: true,
              embedder: { model: "minilm" },
            }),
          }],
        },
      })}\n\n`);
    });
  });
  await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
  try {
    const address = server.address();
    const result = await runAsync(["vector-health"], {
      ...process.env,
      WAX_MCP_HTTP_ENDPOINT: `http://127.0.0.1:${address.port}/mcp`,
    });
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /Vector search is working/);
    assert.deepEqual(seen, ["initialize", "initialized", "stats", "DELETE"]);
  } finally {
    await new Promise(resolve => server.close(resolve));
  }
});

test("vector-health closes the MCP session when stats cannot be parsed", async () => {
  const sessionID = "test-mcp-unparsed-session";
  let deleted = false;
  const server = http.createServer((request, response) => {
    let body = "";
    request.on("data", chunk => { body += chunk; });
    request.on("end", () => {
      if (request.method === "DELETE") {
        assert.equal(request.headers["mcp-session-id"], sessionID);
        deleted = true;
        response.statusCode = 204;
        response.end();
        return;
      }
      const message = JSON.parse(body);
      if (message.method === "initialize") {
        response.setHeader("MCP-Session-Id", sessionID);
        response.setHeader("Content-Type", "application/json");
        response.end(JSON.stringify({ jsonrpc: "2.0", id: 1, result: { capabilities: {} } }));
        return;
      }
      assert.equal(request.headers["mcp-session-id"], sessionID);
      if (message.method === "notifications/initialized") {
        response.statusCode = 202;
        response.end();
        return;
      }
      response.setHeader("Content-Type", "application/json");
      response.end("not-json");
    });
  });
  await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
  try {
    const address = server.address();
    const result = await runAsync(["vector-health"], {
      ...process.env,
      WAX_MCP_HTTP_ENDPOINT: `http://127.0.0.1:${address.port}/mcp`,
    });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /Could not parse stats response/);
    assert.equal(deleted, true, "vector-health must close its MCP session");
  } finally {
    await new Promise(resolve => server.close(resolve));
  }
});

test("vector-health fails with useful diagnostics when query embedding is unavailable", async () => {
  const sessionID = "test-mcp-degraded-session";
  let deleted = false;
  const server = http.createServer((request, response) => {
    let body = "";
    request.on("data", chunk => { body += chunk; });
    request.on("end", () => {
      if (request.method === "DELETE") {
        assert.equal(request.headers["mcp-session-id"], sessionID);
        deleted = true;
        response.statusCode = 204;
        response.end();
        return;
      }
      const message = JSON.parse(body);
      if (message.method === "initialize") {
        response.setHeader("MCP-Session-Id", sessionID);
        response.setHeader("Content-Type", "application/json");
        response.end(JSON.stringify({ jsonrpc: "2.0", id: 1, result: { capabilities: {} } }));
        return;
      }
      assert.equal(request.headers["mcp-session-id"], sessionID);
      if (message.method === "notifications/initialized") {
        response.statusCode = 202;
        response.end();
        return;
      }
      response.setHeader("Content-Type", "text/event-stream");
      response.end(`data: ${JSON.stringify({
        jsonrpc: "2.0",
        id: 2,
        result: {
          content: [{
            type: "text",
            text: JSON.stringify({
              vectorSearchEnabled: true,
              queryEmbeddingAvailable: false,
              embeddingStatus: "unavailable",
              embeddingStatusReason: "MiniLM model failed to load",
              framesWithoutVectors: 7,
              embedder: { model: "minilm" },
            }),
          }],
        },
      })}\n\n`);
    });
  });
  await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
  try {
    const address = server.address();
    const result = await runAsync(["vector-health"], {
      ...process.env,
      WAX_MCP_HTTP_ENDPOINT: `http://127.0.0.1:${address.port}/mcp`,
    });
    assert.notEqual(result.status, 0);
    assert.match(result.stdout, /DEGRADED|unavailable/i);
    assert.match(result.stdout, /MiniLM model failed to load/);
    assert.match(result.stdout, /Frames without vectors: 7/);
    assert.match(result.stdout, /start-wax-mcp-http\.sh|--embedder minilm/);
    assert.doesNotMatch(result.stdout, /Vector search is working/);
    assert.equal(deleted, true, "degraded vector-health must close its MCP session");
  } finally {
    await new Promise(resolve => server.close(resolve));
  }
});
