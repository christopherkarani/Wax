#!/usr/bin/env node

/**
 * WaxMCP launcher — zero-config MCP server for Wax memory.
 *
 * Usage:
 *   npx waxmcp                    # Start MCP server (stdio, default store)
 *   npx waxmcp --transport http   # Start HTTP MCP server on :3000
 *   npx waxmcp --no-embedder      # Text-only search (no vector search)
 *   npx waxmcp --embedder arctic  # Opt in to Arctic embeddings (default: minilm)
 *   npx waxmcp mcp doctor         # Validate setup (routes to wax-cli)
 *
 * Environment:
 *   WAX_MCP_BIN            Path to the wax-mcp server binary
 *   WAX_CLI_BIN            Path to the wax-cli binary
 *   WAX_MCP_HTTP_PORT      HTTP port assumed by vector-health (default 3000)
 *   WAX_MCP_HTTP_ENDPOINT  Full endpoint URL assumed by vector-health
 */

const { spawnSync, spawn } = require("node:child_process");
const crypto = require("node:crypto");
const path = require("node:path");
const os = require("node:os");
const fs = require("node:fs");

const forwardedArgs = process.argv.slice(2);
const packageRoot = path.join(__dirname, "..");
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
const runtimeManifestName = "runtime-manifest.json";

function printLauncherHelp() {
  console.log(`Wax MCP — local shared memory for AI agents

Usage:
  waxmcp mcp serve [server options]   Start the MCP server (stdio by default)
  waxmcp install                     Stage runtime, skill, and HTTP launcher
  waxmcp setup                       Alias for install
  waxmcp doctor [options]            Validate a local stdio runtime
  waxmcp vector-health               Validate the shared HTTP server
  waxmcp install-hermes-plugin       Install the native Hermes provider

Common server options:
  --transport http --http-host 127.0.0.1 --http-port 3000
  --embedder minilm | --embedder arctic | --no-embedder

Environment:
  WAX_MCP_INSTALL_ROOT   Install root (default: ~/.local/share/waxmcp)
  WAX_MCP_HTTP_ENDPOINT Shared HTTP endpoint (default: http://127.0.0.1:3000/mcp)
  WAX_MCP_BIN            Override wax-mcp binary
  WAX_CLI_BIN            Override wax-cli binary`);
}

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
  // Prebuilt npm artifacts are Apple Silicon only (MetalANNS Float16).
  if (os.arch() !== "arm64") {
    return null;
  }
  return path.join(__dirname, "..", "dist", "darwin-arm64");
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
  const installRoot = process.env.WAX_MCP_INSTALL_ROOT || path.join(os.homedir(), ".local", "share", "waxmcp");
  candidates.push(path.join(installRoot, "runtime", `${os.platform()}-${os.arch()}`, name));
  const bundled = resolveBundledBinary(name);
  if (bundled) {
    candidates.push(bundled);
  }
  candidates.push(name);
  candidates.push(path.join(process.cwd(), ".build", "debug", name));
  return candidates;
}

function firstInstallSource(name, builtFromSource) {
  const envKey = name === "wax-mcp" ? "WAX_MCP_BIN" : "WAX_CLI_BIN";
  const candidates = [];
  if (builtFromSource) {
    candidates.push(path.join(process.cwd(), ".build", "debug", name));
  }
  if (process.env[envKey]) candidates.push(process.env[envKey]);
  const bundled = resolveBundledBinary(name);
  if (bundled) candidates.push(bundled);
  candidates.push(path.join(process.cwd(), ".build", "debug", name));
  return candidates.find(candidate => path.isAbsolute(candidate) && isExecutable(candidate)) || null;
}

function canonicalTargetRoot(rawPath) {
  const resolved = path.resolve(rawPath);
  const missing = [];
  let existing = resolved;
  while (!fs.existsSync(existing)) {
    const parent = path.dirname(existing);
    if (parent === existing) break;
    missing.unshift(path.basename(existing));
    existing = parent;
  }
  assertSafeOwnedDirectory(existing);
  assertSafeInstallAncestry(existing);
  const canonical = path.join(fs.realpathSync(existing), ...missing);
  if (canonical === path.parse(canonical).root) {
    throw new Error("refusing to use a filesystem root as an install root");
  }
  return canonical;
}

function assertSafeOwnedDirectory(directory) {
  const stat = fs.lstatSync(directory);
  if (stat.isSymbolicLink() || !stat.isDirectory()) {
    throw new Error(`refusing unsafe install directory: ${directory}`);
  }
  if (typeof process.getuid === "function" && stat.uid !== process.getuid()) {
    throw new Error(`unsafe install directory owner: ${directory}`);
  }
  if ((stat.mode & 0o022) !== 0) {
    throw new Error(`unsafe install directory permissions: ${directory}`);
  }
}

function assertSafeInstallAncestry(directory) {
  const uid = typeof process.getuid === "function" ? process.getuid() : null;
  let current = fs.realpathSync(directory);
  while (true) {
    const stat = fs.lstatSync(current);
    const owned = uid === null || stat.uid === uid;
    const writableByOthers = (stat.mode & 0o022) !== 0;
    const sticky = (stat.mode & 0o1000) !== 0;
    if (writableByOthers && !(sticky && !owned)) {
      throw new Error(`unsafe install directory permissions: ${current}`);
    }
    // A non-writable system-owned directory, or a sticky system temp directory,
    // is a trusted boundary above the user-managed path.
    if (!owned) break;
    const parent = path.dirname(current);
    if (parent === current) break;
    current = parent;
  }
}

function isWithin(root, target) {
  const relative = path.relative(root, target);
  return relative === "" || (!relative.startsWith(`..${path.sep}`) && relative !== "..");
}

function assertSafeManagedPath(root, target) {
  if (!isWithin(root, target)) {
    throw new Error(`refusing to write outside install root: ${target}`);
  }
  const relative = path.relative(root, target);
  let current = root;
  for (const component of relative.split(path.sep).filter(Boolean)) {
    current = path.join(current, component);
    if (fs.existsSync(current) && fs.lstatSync(current).isSymbolicLink()) {
      throw new Error(`refusing to follow symlink in install path: ${current}`);
    }
  }
}

function ensureDirectoryNoSymlinks(directory) {
  const missing = [];
  let existing = directory;
  while (!fs.existsSync(existing)) {
    const parent = path.dirname(existing);
    if (parent === existing) break;
    missing.unshift(path.basename(existing));
    existing = parent;
  }
  const existingStat = fs.lstatSync(existing);
  if (existingStat.isSymbolicLink() || !existingStat.isDirectory()) {
    throw new Error(`refusing unsafe install directory: ${existing}`);
  }
  assertSafeOwnedDirectory(existing);
  let current = existing;
  for (const component of missing) {
    current = path.join(current, component);
    try {
      fs.mkdirSync(current, { mode: 0o755 });
    } catch (error) {
      if (error.code !== "EEXIST") throw error;
    }
    assertSafeOwnedDirectory(current);
  }
}

function copyDirectory(source, destination, installRoot) {
  if (!fs.existsSync(source)) return false;
  assertSafeManagedPath(installRoot, destination);
  const parent = path.dirname(destination);
  ensureDirectoryNoSymlinks(parent);
  assertSafeManagedPath(installRoot, destination);
  if (fs.existsSync(destination)) {
    assertSafeOwnedDirectory(destination);
    assertTreeHasNoSymlinks(destination);
  }
  const stagingRoot = fs.mkdtempSync(path.join(parent, ".waxmcp-copy-"));
  const staged = path.join(stagingRoot, "payload");
  const backup = path.join(stagingRoot, "previous");
  try {
    fs.cpSync(source, staged, { recursive: true });
    assertTreeHasNoSymlinks(staged);
    fsyncTree(staged);
    assertSafeManagedPath(installRoot, destination);
    if (fs.existsSync(destination)) fs.renameSync(destination, backup);
    fs.renameSync(staged, destination);
    fs.rmSync(backup, { recursive: true, force: true });
  } catch (error) {
    if (!fs.existsSync(destination) && fs.existsSync(backup)) {
      fs.renameSync(backup, destination);
    }
    throw error;
  } finally {
    fs.rmSync(stagingRoot, { recursive: true, force: true });
  }
  return true;
}

function sha256(file) {
  return crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex");
}

function atomicWriteFile(destination, content, installRoot, options = {}) {
  assertSafeManagedPath(installRoot, destination);
  const parent = path.dirname(destination);
  ensureDirectoryNoSymlinks(parent);
  assertSafeManagedPath(installRoot, destination);
  const temporaryRoot = fs.mkdtempSync(path.join(parent, ".waxmcp-write-"));
  const temporary = path.join(temporaryRoot, "payload");
  let descriptor;
  try {
    descriptor = fs.openSync(temporary, "wx", options.mode ?? 0o600);
    fs.writeFileSync(descriptor, content);
    fs.fsyncSync(descriptor);
    fs.closeSync(descriptor);
    descriptor = undefined;
    assertSafeManagedPath(installRoot, destination);
    fs.renameSync(temporary, destination);
  } finally {
    if (descriptor !== undefined) fs.closeSync(descriptor);
    fs.rmSync(temporaryRoot, { recursive: true, force: true });
  }
}

function installExecutable(source, destination, installRoot) {
  atomicWriteFile(destination, fs.readFileSync(source), installRoot, { mode: 0o755 });
  fs.chmodSync(destination, 0o755);
  const checksum = sha256(destination);
  atomicWriteFile(
    `${destination}.sha256`,
    `${checksum}  ${path.basename(destination)}\n`,
    installRoot
  );
  if (sha256(destination) !== checksum) {
    throw new Error(`checksum verification failed after installing ${path.basename(destination)}`);
  }
}

function assertTreeHasNoSymlinks(root) {
  if (!fs.existsSync(root)) return;
  const stat = fs.lstatSync(root);
  if (stat.isSymbolicLink()) {
    throw new Error(`refusing to follow symlink in install path: ${root}`);
  }
  if (!stat.isDirectory()) return;
  assertSafeOwnedDirectory(root);
  for (const name of fs.readdirSync(root)) {
    assertTreeHasNoSymlinks(path.join(root, name));
  }
}

function listRegularFiles(root, relative = "") {
  const files = [];
  for (const name of fs.readdirSync(path.join(root, relative)).sort()) {
    const childRelative = path.join(relative, name);
    const child = path.join(root, childRelative);
    const stat = fs.lstatSync(child);
    if (stat.isSymbolicLink()) {
      throw new Error(`refusing to follow symlink in runtime: ${child}`);
    }
    if (stat.isDirectory()) {
      files.push(...listRegularFiles(root, childRelative));
    } else if (stat.isFile()) {
      files.push(childRelative);
    } else {
      throw new Error(`unsupported runtime entry: ${child}`);
    }
  }
  return files;
}

function runtimeBundleNames(directory) {
  return fs.readdirSync(directory)
    .filter(name => name.endsWith(".bundle") && !name.endsWith("Tests.bundle"))
    .filter(name => fs.lstatSync(path.join(directory, name)).isDirectory())
    .sort();
}

function findRuntimeResourceSource(serverSource, cliSource) {
  for (const directory of [...new Set([path.dirname(serverSource), path.dirname(cliSource)])]) {
    const bundles = runtimeBundleNames(directory);
    if (requiredRuntimeBundles.every(name => bundles.includes(name))) {
      return { directory, bundles };
    }
  }
  throw new Error(
    `runtime resources are incomplete; required bundles: ${requiredRuntimeBundles.join(", ")}`
  );
}

function runtimeDataFiles(runtimeDir) {
  return listRegularFiles(runtimeDir).filter(relative =>
    relative !== runtimeManifestName
      && relative !== "wax-mcp.sha256"
      && relative !== "wax-cli.sha256"
  );
}

function manifestsEqual(left, right) {
  return JSON.stringify(left) === JSON.stringify(right);
}

function verifyRuntimeGeneration(runtimeDir, manifest, packageInfo, platformKey) {
  if (!manifest || manifest.version !== packageInfo.version || manifest.platform !== platformKey) {
    return false;
  }
  if (!manifest.runtime || !Array.isArray(manifest.runtime.bundles)) return false;
  if (!manifest.runtime.files || typeof manifest.runtime.files !== "object") return false;
  if (!requiredRuntimeBundles.every(name => manifest.runtime.bundles.includes(name))) return false;

  assertTreeHasNoSymlinks(runtimeDir);
  const allowedTopLevel = new Set([
    "wax-mcp", "wax-mcp.sha256", "wax-cli", "wax-cli.sha256", runtimeManifestName,
    ...manifest.runtime.bundles,
  ]);
  if (fs.readdirSync(runtimeDir).some(name => !allowedTopLevel.has(name))) return false;
  const actualBundles = runtimeBundleNames(runtimeDir);
  if (JSON.stringify(actualBundles) !== JSON.stringify(manifest.runtime.bundles)) return false;

  const actualFiles = runtimeDataFiles(runtimeDir);
  const recordedFiles = Object.keys(manifest.runtime.files).sort();
  if (JSON.stringify(actualFiles) !== JSON.stringify(recordedFiles)) return false;
  for (const relative of actualFiles) {
    const digest = manifest.runtime.files[relative];
    if (!/^[a-f0-9]{64}$/.test(digest) || sha256(path.join(runtimeDir, relative)) !== digest) {
      return false;
    }
  }

  for (const name of ["wax-mcp", "wax-cli"]) {
    const executable = path.join(runtimeDir, name);
    const checksumFile = `${executable}.sha256`;
    if (!isExecutable(executable)) return false;
    const fields = fs.readFileSync(checksumFile, "utf8").trim().split(/\s+/);
    if (fields.length !== 2 || fields[1] !== name || fields[0] !== manifest.runtime.files[name]) {
      return false;
    }
  }
  return true;
}

function hasVerifiedRuntime(runtimeDir, installRoot, packageInfo, platformKey) {
  const installManifestPath = path.join(installRoot, "install.json");
  const runtimeManifestPath = path.join(runtimeDir, runtimeManifestName);
  for (const file of [installManifestPath, runtimeManifestPath]) {
    assertSafeManagedPath(installRoot, file);
    if (!fs.existsSync(file) || !fs.lstatSync(file).isFile()) return false;
  }

  try {
    const installManifest = JSON.parse(fs.readFileSync(installManifestPath, "utf8"));
    const runtimeManifest = JSON.parse(fs.readFileSync(runtimeManifestPath, "utf8"));
    return manifestsEqual(installManifest, runtimeManifest)
      && verifyRuntimeGeneration(runtimeDir, runtimeManifest, packageInfo, platformKey);
  } catch (error) {
    if (String(error.message).includes("symlink")) throw error;
    return false;
  }
}

function fsyncPath(target) {
  let descriptor;
  try {
    descriptor = fs.openSync(target, "r");
    fs.fsyncSync(descriptor);
  } catch (error) {
    if (!["EINVAL", "ENOTSUP", "EISDIR", "EBADF"].includes(error.code)) throw error;
  } finally {
    if (descriptor !== undefined) fs.closeSync(descriptor);
  }
}

function fsyncTree(root) {
  for (const relative of listRegularFiles(root)) {
    fsyncPath(path.join(root, relative));
  }
  const directories = [];
  function collect(directory) {
    for (const name of fs.readdirSync(directory)) {
      const child = path.join(directory, name);
      if (fs.lstatSync(child).isDirectory()) collect(child);
    }
    directories.push(directory);
  }
  collect(root);
  for (const directory of directories) fsyncPath(directory);
}

function materializeRuntimeGeneration(
  stagingRuntimeDir,
  serverSource,
  cliSource,
  installRoot,
  packageInfo,
  platformKey
) {
  assertSafeManagedPath(installRoot, stagingRuntimeDir);
  ensureDirectoryNoSymlinks(path.dirname(stagingRuntimeDir));
  fs.mkdirSync(stagingRuntimeDir, { mode: 0o755 });
  assertSafeOwnedDirectory(stagingRuntimeDir);
  installExecutable(serverSource, path.join(stagingRuntimeDir, "wax-mcp"), installRoot);
  installExecutable(cliSource, path.join(stagingRuntimeDir, "wax-cli"), installRoot);
  const resources = findRuntimeResourceSource(serverSource, cliSource);
  for (const bundle of resources.bundles) {
    fs.cpSync(path.join(resources.directory, bundle), path.join(stagingRuntimeDir, bundle), {
      recursive: true,
      errorOnExist: true,
      force: false,
    });
  }
  assertTreeHasNoSymlinks(stagingRuntimeDir);
  const files = Object.fromEntries(
    runtimeDataFiles(stagingRuntimeDir).map(relative => [
      relative,
      sha256(path.join(stagingRuntimeDir, relative)),
    ])
  );
  const manifest = {
    version: packageInfo.version,
    platform: platformKey,
    installed_at: new Date().toISOString(),
    runtime: { bundles: resources.bundles, files },
  };
  atomicWriteFile(
    path.join(stagingRuntimeDir, runtimeManifestName),
    `${JSON.stringify(manifest, null, 2)}\n`,
    installRoot
  );
  if (!verifyRuntimeGeneration(stagingRuntimeDir, manifest, packageInfo, platformKey)) {
    throw new Error("staged runtime failed manifest verification");
  }
  fsyncTree(stagingRuntimeDir);
  return manifest;
}

function commitReplace(live, staged, installRoot, commits) {
  assertSafeManagedPath(installRoot, live);
  assertSafeManagedPath(installRoot, staged);
  if (!fs.existsSync(staged)) {
    throw new Error(`missing staged payload: ${staged}`);
  }
  if (fs.lstatSync(staged).isSymbolicLink()) {
    throw new Error(`refusing to follow symlink in install path: ${staged}`);
  }
  const parent = path.dirname(live);
  ensureDirectoryNoSymlinks(parent);
  if (fs.existsSync(live)) {
    if (fs.lstatSync(live).isSymbolicLink()) {
      throw new Error(`refusing to follow symlink in install path: ${live}`);
    }
    assertTreeHasNoSymlinks(live);
  }
  const backupRoot = fs.mkdtempSync(path.join(parent, ".waxmcp-commit-"));
  const backup = path.join(backupRoot, "previous");
  const hadLive = fs.existsSync(live);
  try {
    if (hadLive) fs.renameSync(live, backup);
    fs.renameSync(staged, live);
    fsyncPath(parent);
    commits.push({ live, backupRoot, backup, hadLive });
  } catch (error) {
    if (!fs.existsSync(live) && hadLive && fs.existsSync(backup)) {
      fs.renameSync(backup, live);
    }
    fs.rmSync(backupRoot, { recursive: true, force: true });
    throw error;
  }
}

function rollbackCommits(commits) {
  for (const commit of [...commits].reverse()) {
    const leftover = path.join(path.dirname(commit.live), `.waxmcp-rolled-${crypto.randomUUID()}`);
    try {
      if (fs.existsSync(commit.live)) fs.renameSync(commit.live, leftover);
      if (commit.hadLive && fs.existsSync(commit.backup)) {
        fs.renameSync(commit.backup, commit.live);
      }
      fsyncPath(path.dirname(commit.live));
    } finally {
      fs.rmSync(leftover, { recursive: true, force: true });
      fs.rmSync(commit.backupRoot, { recursive: true, force: true });
    }
  }
  commits.length = 0;
}

function finalizeCommits(commits) {
  for (const commit of commits) {
    fs.rmSync(commit.backupRoot, { recursive: true, force: true });
    fsyncPath(path.dirname(commit.live));
  }
  commits.length = 0;
}

function stageInstallation(builtFromSource, options = {}) {
  let installRoot;
  try {
    installRoot = canonicalTargetRoot(
      process.env.WAX_MCP_INSTALL_ROOT || path.join(os.homedir(), ".local", "share", "waxmcp")
    );
  } catch (error) {
    console.error(`waxmcp: ${error.message}`);
    process.exit(1);
  }
  ensureDirectoryNoSymlinks(installRoot);
  const canonicalPackageRoot = fs.realpathSync(packageRoot);
  if (isWithin(canonicalPackageRoot, installRoot) || isWithin(installRoot, canonicalPackageRoot)) {
    console.error("waxmcp: install root must not overlap the waxmcp package directory.");
    process.exit(1);
  }
  const platformKey = `${os.platform()}-${os.arch()}`;
  const runtimeDir = path.join(installRoot, "runtime", platformKey);
  const skillDestination = path.join(installRoot, "skills", "wax-mcp");
  const hermesDestination = path.join(installRoot, "plugins", "hermes");
  const launcherPath = path.join(installRoot, "bin", "start-wax-mcp-http.sh");
  const installManifestPath = path.join(installRoot, "install.json");
  const packageInfo = JSON.parse(fs.readFileSync(path.join(packageRoot, "package.json"), "utf8"));
  ensureDirectoryNoSymlinks(path.dirname(runtimeDir));
  const reuseRuntime = options.preserveVerifiedRuntime === true
    && hasVerifiedRuntime(runtimeDir, installRoot, packageInfo, platformKey);
  let serverSource = null;
  let cliSource = null;
  if (reuseRuntime) {
    console.log(`Reusing manifest-verified Wax MCP runtime at ${runtimeDir}`);
  } else {
    serverSource = firstInstallSource("wax-mcp", builtFromSource);
    cliSource = firstInstallSource("wax-cli", builtFromSource);
    if (!serverSource || !cliSource) {
      throw new Error(
        "both wax-mcp and wax-cli are required for installation. Run 'waxmcp install --build' from a Wax source checkout, or use the packaged runtime."
      );
    }
  }

  const skillSource = path.join(packageRoot, "skills", "wax-mcp");
  if (!fs.existsSync(skillSource)) {
    throw new Error(`operator skill is missing at ${skillSource}`);
  }
  const hermesSource = path.join(packageRoot, "plugins", "hermes");
  const launcher = `#!/usr/bin/env bash
set -euo pipefail
install_root="$(cd "$(dirname "$0")/.." && pwd)"
exec "$install_root/runtime/${platformKey}/wax-mcp" \\
  --transport http \\
  --http-host 127.0.0.1 \\
  --http-port "\${WAX_MCP_HTTP_PORT:-3000}" \\
  --http-endpoint /mcp \\
  --embedder minilm "$@"
`;

  const stagingRoot = fs.mkdtempSync(path.join(installRoot, ".waxmcp-stage-"));
  const stagedRuntime = path.join(stagingRoot, "runtime", platformKey);
  const stagedSkill = path.join(stagingRoot, "skills", "wax-mcp");
  const stagedHermes = path.join(stagingRoot, "plugins", "hermes");
  const stagedLauncher = path.join(stagingRoot, "bin", "start-wax-mcp-http.sh");
  const stagedManifest = path.join(stagingRoot, "install.json");
  const commits = [];
  try {
    let installManifest;
    if (reuseRuntime) {
      installManifest = JSON.parse(fs.readFileSync(installManifestPath, "utf8"));
    } else {
      installManifest = materializeRuntimeGeneration(
        stagedRuntime, serverSource, cliSource, installRoot, packageInfo, platformKey
      );
    }

    ensureDirectoryNoSymlinks(path.dirname(stagedSkill));
    fs.cpSync(skillSource, stagedSkill, { recursive: true });
    if (fs.existsSync(hermesSource)) {
      ensureDirectoryNoSymlinks(path.dirname(stagedHermes));
      fs.cpSync(hermesSource, stagedHermes, { recursive: true });
    }
    ensureDirectoryNoSymlinks(path.dirname(stagedLauncher));
    atomicWriteFile(stagedLauncher, launcher, installRoot, { mode: 0o755 });
    fs.chmodSync(stagedLauncher, 0o755);
    if (!reuseRuntime) {
      atomicWriteFile(
        stagedManifest,
        `${JSON.stringify(installManifest, null, 2)}\n`,
        installRoot
      );
    }
    assertTreeHasNoSymlinks(stagingRoot);
    fsyncTree(stagingRoot);

    if (process.env.NODE_ENV === "test" && process.env.WAX_MCP_TEST_FAIL_RUNTIME_SWAP === "1") {
      throw new Error("injected runtime swap failure");
    }

    if (!reuseRuntime) {
      commitReplace(runtimeDir, stagedRuntime, installRoot, commits);
      if (process.env.NODE_ENV === "test" && process.env.WAX_MCP_TEST_FAIL_AFTER_RUNTIME_SWAP === "1") {
        throw new Error("injected post-runtime commit failure");
      }
    }
    commitReplace(skillDestination, stagedSkill, installRoot, commits);
    if (fs.existsSync(stagedHermes)) {
      commitReplace(hermesDestination, stagedHermes, installRoot, commits);
    }
    commitReplace(launcherPath, stagedLauncher, installRoot, commits);
    if (!reuseRuntime) {
      commitReplace(installManifestPath, stagedManifest, installRoot, commits);
    }
    const committed = commits.splice(0, commits.length);
    finalizeCommits(committed);
  } catch (error) {
    rollbackCommits(commits);
    throw error;
  } finally {
    fs.rmSync(stagingRoot, { recursive: true, force: true });
  }

  console.log(`Installed Wax MCP ${packageInfo.version} to ${installRoot}`);
  console.log(`  Runtime: ${runtimeDir}`);
  console.log(`  Skill:   ${skillDestination}`);
  console.log(`  HTTP:    ${launcherPath}`);
  console.log("Run the HTTP launcher once, then point every host at http://127.0.0.1:3000/mcp.");
  return { installRoot, runtimeDir, skillDestination, launcherPath };
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

if (["--help", "-h", "help"].includes(forwardedArgs[0])) {
  printLauncherHelp();
  process.exit(0);
}

// --- Subcommand: install/setup ---
// Stage binaries, the operator skill, the Hermes provider, and a stable HTTP launcher.
if (forwardedArgs[0] === "install" || forwardedArgs[0] === "setup") {
  const installArgs = forwardedArgs.slice(1);
  if (installArgs.includes("--help") || installArgs.includes("-h")) {
    console.log("Usage: waxmcp install [--build] [--arctic]\n\nStages the complete runtime under WAX_MCP_INSTALL_ROOT or ~/.local/share/waxmcp.");
    process.exit(0);
  }
  const buildFromSource = installArgs.includes("--build");

  if (buildFromSource) {
    console.log("Building Wax from source (this may take a few minutes)...");
    const traits = installArgs.includes("--arctic")
      ? "MiniLMEmbeddings,ArcticEmbeddings,MCPServer"
      : "MiniLMEmbeddings,MCPServer";

    for (const product of ["wax-cli", "wax-mcp"]) {
      const result = spawnSync("swift", ["build", "--product", product, "--traits", traits], {
        stdio: "inherit",
        cwd: process.cwd(),
        env: process.env,
      });
      if (result.status !== 0) {
        console.error(`Build failed for ${product}. Make sure you have Swift 6+ installed.`);
        process.exit(1);
      }
    }
  }
  try {
    stageInstallation(buildFromSource);
  } catch (error) {
    console.error(`waxmcp: ${error.message}`);
    process.exit(1);
  }
  process.exit(0);
}

// --- Subcommand: vector-health ---
// Quick diagnostic to verify vector search is working
if (forwardedArgs[0] === "vector-health") {
  const httpPort = process.env.WAX_MCP_HTTP_PORT || "3000";
  const endpoint = process.env.WAX_MCP_HTTP_ENDPOINT || `http://127.0.0.1:${httpPort}/mcp`;

  console.log(`Checking vector search health at ${endpoint}...`);

  function post(payload, sessionId = null, includeHeaders = false) {
    const args = [
      "-sS", "--max-time", "5", "-X", "POST", endpoint,
      "-H", "Content-Type: application/json",
      "-H", "Accept: application/json, text/event-stream",
    ];
    if (sessionId) args.push("-H", `MCP-Session-Id: ${sessionId}`);
    if (includeHeaders) args.push("-D", "-");
    args.push("-d", JSON.stringify(payload));
    return spawnSync("curl", args, { encoding: "utf-8" });
  }

  function closeSession(sessionId) {
    return spawnSync("curl", [
      "-sS", "--max-time", "5", "-X", "DELETE", endpoint,
      "-H", `MCP-Session-Id: ${sessionId}`,
    ], { encoding: "utf-8" });
  }

  const initialized = post({
    jsonrpc: "2.0",
    id: 1,
    method: "initialize",
    params: {
      protocolVersion: "2024-11-05",
      capabilities: {},
      clientInfo: { name: "waxmcp-vector-health", version: "1.0" },
    },
  }, null, true);
  if (initialized.status !== 0 || !initialized.stdout) {
    console.error("❌ Wax MCP server is not running.");
    console.error("   Start it with: npx waxmcp --transport http");
    process.exit(1);
  }
  const sessionMatch = initialized.stdout.match(/^mcp-session-id:\s*(.+)\r?$/im);
  const sessionId = sessionMatch?.[1]?.trim();
  if (!sessionId) {
    console.error("❌ Wax MCP initialize did not return an MCP-Session-Id header.");
    process.exit(1);
  }
  let exitCode = 1;
  try {
    post({ jsonrpc: "2.0", method: "notifications/initialized", params: {} }, sessionId);
    const curl = post({
      jsonrpc: "2.0",
      id: 2,
      method: "tools/call",
      params: { name: "stats", arguments: {} },
    }, sessionId);

    const lines = (curl.stdout || "").split("\n");
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
      try {
        const data = JSON.parse(curl.stdout);
        if (data.result?.content?.[0]?.text) stats = JSON.parse(data.result.content[0].text);
      } catch {}
    }

    if (!stats) {
      console.error("❌ Could not parse stats response.");
    } else {
      console.log(`\nVector search enabled: ${stats.vectorSearchEnabled}`);
      console.log(`Query embedding available: ${stats.queryEmbeddingAvailable}`);
      console.log(`Embedder: ${stats.embedder ? stats.embedder.model : "none"}`);
      if (stats.embeddingStatus) {
        console.log(`Embedding status: ${stats.embeddingStatus}`);
      }
      if (stats.embeddingStatusReason) {
        console.log(`Embedding status reason: ${stats.embeddingStatusReason}`);
      }
      if (stats.framesWithoutVectors !== undefined) {
        console.log(`Frames without vectors: ${stats.framesWithoutVectors}`);
      }

      const healthy = stats.vectorSearchEnabled === true && stats.queryEmbeddingAvailable === true;
      exitCode = healthy ? 0 : 1;
      if (healthy) {
        console.log("\n✅ Vector search is working!");
      } else {
        const installRoot = path.resolve(
          process.env.WAX_MCP_INSTALL_ROOT || path.join(os.homedir(), ".local", "share", "waxmcp")
        );
        const persistentLauncher = path.join(installRoot, "bin", "start-wax-mcp-http.sh");
        console.log("\n❌ Vector search is DEGRADED.");
        if (stats.vectorSearchEnabled !== true) {
          console.log("   The vector lane is disabled, so recall is text-only.");
        }
        if (stats.queryEmbeddingAvailable !== true) {
          console.log("   Query embeddings are unavailable, so semantic retrieval cannot run.");
        }
        console.log("\n   Fix:");
        console.log("     npx -y waxmcp@latest install");
        console.log(`     ${persistentLauncher}`);
        console.log("   Then rerun: npx -y waxmcp@latest vector-health");
        console.log("\n   Building from source? Build both binaries with MiniLM:");
        console.log("     swift build --product wax-mcp --traits 'MiniLMEmbeddings,MCPServer'");
        console.log("     swift build --product wax-cli --traits 'MiniLMEmbeddings'");
      }
    }
  } finally {
    closeSession(sessionId);
  }
  process.exit(exitCode);
}

if (forwardedArgs[0] === "doctor") {
  runBinary("wax-cli", ["mcp", "doctor", ...forwardedArgs.slice(1)]);
}

// --- Subcommand: install-hermes-plugin ---
if (forwardedArgs[0] === "install-hermes-plugin") {
  const hermesHome = canonicalTargetRoot(
    process.env.HERMES_HOME || path.join(os.homedir(), ".hermes")
  );
  const hermesPluginsDir = path.join(hermesHome, "plugins", "wax-memory");
  const pluginSrcDir = path.join(__dirname, "..", "plugins", "hermes");

  if (!fs.existsSync(pluginSrcDir)) {
    console.error("❌ Hermes plugin not found in package.");
    console.error("   This is a packaging bug — please report it.");
    process.exit(1);
  }

  console.log(`Installing Wax Hermes plugin to ${hermesPluginsDir}...`);

  let installation;
  try {
    installation = stageInstallation(false, { preserveVerifiedRuntime: true });
    copyDirectory(pluginSrcDir, hermesPluginsDir, hermesHome);
  } catch (error) {
    console.error(`waxmcp: ${error.message}`);
    process.exit(1);
  }

  console.log("✅ Hermes plugin installed.");
  console.log("");
  console.log("Next steps:");
  console.log(`  1. Start Wax MCP:  ${installation.launcherPath}`);
  console.log("  2. Verify vectors: npx -y waxmcp@latest vector-health");
  console.log("  3. Select provider: hermes config set memory.provider wax-memory");
  console.log("  4. Run Hermes:     hermes");
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
  const hermesHome = canonicalTargetRoot(
    process.env.HERMES_HOME || path.join(os.homedir(), ".hermes")
  );
  const hermesPluginsDir = path.join(hermesHome, "plugins", "wax-memory");
  const hermesSrcDir = path.join(__dirname, "..", "plugins", "hermes");
  if (fs.existsSync(hermesSrcDir)) {
    copyDirectory(hermesSrcDir, hermesPluginsDir, hermesHome);
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
// Maintenance commands that are exposed by wax-cli must be dispatched before
// the MCP flag translation below. Otherwise the launcher would pass the
// subcommand token to wax-mcp, which treats it as an unknown server argument.
if (forwardedArgs[0] === "task-state-migrate") {
  runBinary("wax-cli", forwardedArgs);
}

// Translate the legacy 'mcp' prefix to native wax-mcp flags
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
    if (i < forwardedArgs.length) {
      // Management subcommands (doctor/install/uninstall) belong to wax-cli.
      runBinary("wax-cli", forwardedArgs.slice(i - 1));
    }
    // Trailing bare 'mcp': nothing to forward, start a plain server.
    continue;
  }

  // Pass through all other flags
  mcpFlags.push(arg);
  i++;
}

// Auto-detect if we should add default embedder
if (!mcpFlags.includes("--no-embedder") && !mcpFlags.some(f => f.startsWith("--embedder"))) {
  mcpFlags.unshift("--embedder", "minilm");
}

runBinary("wax-mcp", mcpFlags);
