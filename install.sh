#!/bin/sh
# Explyt AI Agent installer starter for Linux and macOS (spec 019, RQ-19).
#
#   curl --proto '=https' --tlsv1.2 -fsSL https://raw.githubusercontent.com/explyt/explyt-ai-agent-distribution/main/install.sh | sh
#   ... | sh -s -- --channel dogfood
#
# It holds no installer logic. It downloads and verifies the Node version below, fetches the
# @explyt/ai-agent tarball with that Node's npm, unpacks only dist/install/installer.js and
# runs it; the installer does the rest and this script exits with its exit code. It needs no
# Node, npm or administrator rights.
set -eu

EXPLYT_NODE_VERSION="22.23.3"
PACKAGE="@explyt/ai-agent"

fail() {
  printf 'explyt installer: %s\n' "$1" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || fail "the tool '$1' is required and was not found"
}

channel="stable"
pass_args=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --channel)
      [ "$#" -ge 2 ] || fail "--channel takes stable or dogfood"
      channel="$2"
      pass_args="$pass_args --channel $2"
      shift 2
      ;;
    --channel=*)
      channel="${1#--channel=}"
      pass_args="$pass_args --channel $channel"
      shift
      ;;
    --json)
      pass_args="$pass_args --json"
      shift
      ;;
    *)
      fail "unknown argument $1; usage: install.sh [--channel stable|dogfood] [--json]"
      ;;
  esac
done
case "$channel" in
  stable) tag="latest" ;;
  dogfood) tag="dogfood" ;;
  *) fail "--channel takes stable or dogfood, not $channel" ;;
esac

need uname
need tar
need mktemp
if command -v curl >/dev/null 2>&1; then
  # HTTPS only, redirects included, so a redirect cannot downgrade SHASUMS and the archive together.
  fetch() { curl --proto '=https' --tlsv1.2 -fsSL "$1" -o "$2"; }
elif command -v wget >/dev/null 2>&1; then
  fetch() { wget --https-only -q "$1" -O "$2"; }
else
  fail "the tool 'curl' (or 'wget') is required and was not found"
fi
if command -v sha256sum >/dev/null 2>&1; then
  digest() { sha256sum "$1" | cut -d ' ' -f 1; }
elif command -v shasum >/dev/null 2>&1; then
  digest() { shasum -a 256 "$1" | cut -d ' ' -f 1; }
else
  fail "the tool 'sha256sum' (or 'shasum') is required and was not found"
fi

os="$(uname -s)"
machine="$(uname -m)"
case "$os" in
  Linux) platform="linux" ;;
  Darwin) platform="darwin" ;;
  *) fail "the platform $os-$machine is not supported (supported: linux-x64, darwin-x64, darwin-arm64, win32-x64)" ;;
esac
case "$machine" in
  x86_64|amd64) arch="x64" ;;
  arm64|aarch64) arch="arm64" ;;
  *) fail "the platform $platform-$machine is not supported (supported: linux-x64, darwin-x64, darwin-arm64, win32-x64)" ;;
esac
if [ "$platform" = "linux" ] && [ "$arch" != "x64" ]; then
  fail "the platform linux-$arch is not supported (supported: linux-x64, darwin-x64, darwin-arm64, win32-x64)"
fi
if [ "$platform" = "linux" ]; then
  if [ -e /etc/alpine-release ] || { command -v ldd >/dev/null 2>&1 && ldd --version 2>&1 | grep -qi musl; }; then
    fail "the platform linux-$arch on musl is not supported (the official Node builds need glibc)"
  fi
fi

data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
root="$data_home/explyt-ai-agent"
node_dir="$root/node/$EXPLYT_NODE_VERSION"
node_bin="$node_dir/bin/node"
npm_cli="$node_dir/lib/node_modules/npm/bin/npm-cli.js"
cache="$root/install/npm-cache"
userconfig="$root/install/npmrc"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM

if [ ! -x "$node_bin" ]; then
  archive="node-v$EXPLYT_NODE_VERSION-$platform-$arch.tar.gz"
  base="https://nodejs.org/dist/v$EXPLYT_NODE_VERSION"
  printf 'Downloading Node %s\n' "$EXPLYT_NODE_VERSION" >&2
  fetch "$base/SHASUMS256.txt" "$work/SHASUMS256.txt" || fail "cannot download $base/SHASUMS256.txt"
  fetch "$base/$archive" "$work/$archive" || fail "cannot download $base/$archive"
  expected="$(grep "  $archive\$" "$work/SHASUMS256.txt" | cut -d ' ' -f 1)"
  [ -n "$expected" ] || fail "SHASUMS256.txt lists no $archive"
  actual="$(digest "$work/$archive")"
  [ "$actual" = "$expected" ] || fail "the Node archive checksum does not match (SHA-256 $actual, expected $expected)"
  mkdir -p "$work/node" "$root/node"
  tar -xzf "$work/$archive" -C "$work/node" --strip-components=1 || fail "cannot unpack $archive"
  rm -rf "$node_dir"
  mv "$work/node" "$node_dir"
fi

mkdir -p "$root/install"
[ -f "$userconfig" ] || printf 'registry=https://registry.npmjs.org/\n' > "$userconfig"

printf 'Fetching %s@%s\n' "$PACKAGE" "$tag" >&2
# Only the variables npm needs; a user's npm_config_* must not reach it (RQ-21).
tarball="$(cd "$work" && env -i HOME="$HOME" PATH="$node_dir/bin:/usr/bin:/bin" "$node_bin" "$npm_cli" pack "$PACKAGE@$tag" \
  --cache "$cache" --userconfig "$userconfig" --silent)" || fail "cannot fetch $PACKAGE@$tag"
tar -xzf "$work/$tarball" -C "$work" package/dist/install/installer.js || fail "the $PACKAGE tarball carries no installer"

# The installer's exit code is this script's exit code.
# Under `curl ... | sh` stdin is this script, so the PATH question reads the terminal.
status=0
if [ -t 2 ] && (: </dev/tty) 2>/dev/null; then
  # shellcheck disable=SC2086
  PATH="$node_dir/bin:$PATH" "$node_bin" "$work/package/dist/install/installer.js" $pass_args </dev/tty || status=$?
else
  # shellcheck disable=SC2086
  PATH="$node_dir/bin:$PATH" "$node_bin" "$work/package/dist/install/installer.js" $pass_args </dev/null || status=$?
fi
exit "$status"
