#!/bin/bash
# Build the x64 Windows installer and portable ZIP on a Mac.
set -euo pipefail
cd "$(dirname "$0")"
windows_dir="$PWD"
upstream_url="https://github.com/corvofeng/atv-core.git"
upstream_sha="8a4ada29bb7cad31e0315c3387b277eb9ab8c988"
version="$(awk -F '"' '/^version = "/ {print $2; exit}' Cargo.toml)"
target="x86_64-pc-windows-gnu"

if ! command -v zig >/dev/null; then
  for zig_dir in "$HOME"/.local/zig/zig-*/; do
    [[ -x "${zig_dir}zig" ]] && export PATH="$zig_dir:$PATH"
  done
fi
command -v zig >/dev/null || { echo "请安装 Zig" >&2; exit 1; }
command -v makensis >/dev/null || { echo "请安装 NSIS (makensis)" >&2; exit 1; }
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
payload="$work_dir/PCRemote"
package_dir="$windows_dir/../build/windows-release/$version"
mkdir -p "$payload" "$package_dir"

./build-exe.sh
cp ../build/PCRemote.exe "$payload/PCRemote.exe"

git init -q "$work_dir/atv-core"
git -C "$work_dir/atv-core" fetch --depth=1 "$upstream_url" "$upstream_sha"
git -C "$work_dir/atv-core" checkout --detach FETCH_HEAD
git -C "$work_dir/atv-core" apply "$windows_dir/apple-tv.patch"
(
  cd "$work_dir/atv-core"
  cargo zigbuild --locked --release --target "$target" -p atv-cli
)
cp "$work_dir/atv-core/target/$target/release/atv-cli.exe" "$payload/AppleTVRemote.exe"
cp README.md "$payload/README-Windows.md"
cp Third-party-notices.txt "$payload/"
makensis "-DPACKAGE_DIR=$package_dir" "-DPAYLOAD_DIR=$payload" "-DPRODUCT_VERSION=$version.0" installer.nsi
(
  cd "$work_dir"
  # Recreate the archive to prevent entries from a previous build carrying over.
  rm -f "$package_dir/PCRemote-Windows-x64-Portable.zip"
  zip -q "$package_dir/PCRemote-Windows-x64-Portable.zip" PCRemote/*
)
(
  cd "$package_dir"
  shasum -a 256 PCRemote-Windows-x64-Setup.exe PCRemote-Windows-x64-Portable.zip > SHA256SUMS.txt
)
echo "$package_dir"
