#!/usr/bin/env bash
# Installs a swift.org Swift toolchain on Ubuntu 24.04 aarch64 (GitHub's
# ubuntu-24.04-arm runners) and puts it on GITHUB_PATH. swift-actions/setup-swift
# v2 only downloads x86_64 Ubuntu toolchains. The archive's signature is checked
# against swift.org's published keys before it is unpacked.
#
# Usage: SWIFT_RELEASE=6.2.1 install_swift_linux_aarch64.sh
#   SWIFT_ARCH (default: uname -m) and SWIFT_INSTALL_DIR (default: $RUNNER_TEMP)
#   exist so the download and signature check can be exercised on other hosts.
set -euo pipefail

: "${SWIFT_RELEASE:?set SWIFT_RELEASE, for example 6.2.1}"
arch="${SWIFT_ARCH:-$(uname -m)}"
install_dir="${SWIFT_INSTALL_DIR:-${RUNNER_TEMP:-$(mktemp -d)}}"

if [[ "$arch" != "aarch64" ]]; then
  echo "FAIL: this installer is for aarch64; use swift-actions/setup-swift on x86_64 (got $arch)" >&2
  exit 1
fi

# Toolchain runtime dependencies listed for Ubuntu 24.04 on swift.org.
if [[ "$(uname -m)" == "aarch64" ]] && command -v apt-get >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y \
    binutils git gnupg2 libc6-dev libcurl4-openssl-dev libedit2 libgcc-13-dev \
    libncurses-dev libpython3-dev libsqlite3-0 libstdc++-13-dev libxml2-dev \
    libz3-dev pkg-config tzdata unzip zlib1g-dev
fi

name="swift-${SWIFT_RELEASE}-RELEASE-ubuntu24.04-${arch}"
base="https://download.swift.org/swift-${SWIFT_RELEASE}-release/ubuntu2404-${arch}/swift-${SWIFT_RELEASE}-RELEASE"
mkdir -p "$install_dir"
cd "$install_dir"

curl -fsSL --retry 3 -o "$name.tar.gz" "$base/$name.tar.gz"
curl -fsSL --retry 3 -o "$name.tar.gz.sig" "$base/$name.tar.gz.sig"

# A private keyring in a short path: gpg-agent's socket path must stay under
# the Unix socket limit.
GNUPGHOME="$(mktemp -d /tmp/swift-gpg.XXXXXX)"
export GNUPGHOME
trap 'gpgconf --kill gpg-agent >/dev/null 2>&1 || true; rm -rf "$GNUPGHOME"' EXIT
curl -fsSL --retry 3 https://swift.org/keys/all-keys.asc | gpg --batch --quiet --import
gpg --batch --verify "$name.tar.gz.sig" "$name.tar.gz"

tar -xzf "$name.tar.gz"
rm -f "$name.tar.gz" "$name.tar.gz.sig"
bin_dir="$install_dir/$name/usr/bin"
[[ -x "$bin_dir/swift" ]] || { echo "FAIL: $bin_dir/swift missing after unpacking" >&2; exit 1; }

if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "$bin_dir" >>"$GITHUB_PATH"
fi
if [[ "$(uname -m)" == "$arch" ]]; then
  "$bin_dir/swift" --version
fi
echo "install_swift_linux_aarch64: $bin_dir"
