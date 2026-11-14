"use strict";

// Where each platform's Wax runtime lives and what its SwiftPM resource
// bundles are called. Apple builds emit `<Package>_<Target>.bundle`
// directories; Linux builds emit `<Package>_<Target>.resources`, and do not
// link MetalANNS or the Apple-only swift-crypto and swift-nio privacy bundles.

const os = require("node:os");

const appleRuntime = {
  bundleSuffix: ".bundle",
  requiredBundles: [
    "GRDB_GRDB.bundle",
    "MetalANNS_MetalANNSCore.bundle",
    "Wax_Wax.bundle",
    "Wax_WaxBertTokenizer.bundle",
    "Wax_WaxVectorSearch.bundle",
    "Wax_WaxVectorSearchMiniLM.bundle",
    "swift-crypto_Crypto.bundle",
    "swift-nio_NIOPosix.bundle",
  ],
  vectorBundle: "Wax_WaxVectorSearchMiniLM.bundle",
};

const linuxRuntime = {
  bundleSuffix: ".resources",
  requiredBundles: [
    "GRDB_GRDB.resources",
    "Wax_Wax.resources",
    "Wax_WaxBertTokenizer.resources",
    "Wax_WaxVectorSearch.resources",
    "Wax_WaxVectorSearchMiniLM.resources",
  ],
  vectorBundle: "Wax_WaxVectorSearchMiniLM.resources",
};

// `dist/<key>` directories a package may carry prebuilt binaries for, keyed by
// `${os.platform()}-${os.arch()}`. Prebuilt Apple binaries are Apple Silicon
// only (MetalANNS Float16).
const distPlatforms = {
  "darwin-arm64": appleRuntime,
  "linux-x64": linuxRuntime,
  "linux-arm64": linuxRuntime,
};

function platformKey(platform = os.platform(), arch = os.arch()) {
  return `${platform}-${arch}`;
}

// The resource layout of a runtime built on `platform`, whether or not a
// prebuilt dist exists for it. Null for platforms Wax does not build on.
function runtimeLayout(platform = os.platform()) {
  if (platform === "darwin") return appleRuntime;
  if (platform === "linux") return linuxRuntime;
  return null;
}

// The `dist/<key>` directory name for this host, or null when no prebuilt
// runtime can exist for it.
function distPlatformKey(platform = os.platform(), arch = os.arch()) {
  const key = platformKey(platform, arch);
  return Object.prototype.hasOwnProperty.call(distPlatforms, key) ? key : null;
}

module.exports = {
  distPlatforms,
  distPlatformKey,
  platformKey,
  runtimeLayout,
};
