#!/bin/bash
# 在 Mac 上交叉编译 Windows 版 PCRemote.exe，输出到 ../build/PCRemote.exe
# 需要：rustup target add x86_64-pc-windows-gnu；cargo install cargo-zigbuild；zig（https://ziglang.org/download/）
# zig 不在 PATH 里时，会找 ~/.local/zig/zig-*/zig
set -euo pipefail
cd "$(dirname "$0")"
if ! command -v zig >/dev/null; then
  Z="$(ls -d "$HOME"/.local/zig/zig-*/ 2>/dev/null | tail -1)"
  [[ -n "$Z" ]] && export PATH="$Z:$PATH"
fi
command -v zig >/dev/null || { echo "找不到 zig，请先下载：https://ziglang.org/download/"; exit 1; }
cargo zigbuild --locked --release --target x86_64-pc-windows-gnu
mkdir -p ../build
cp target/x86_64-pc-windows-gnu/release/PCRemote.exe ../build/PCRemote.exe
echo "✅ ../build/PCRemote.exe"
