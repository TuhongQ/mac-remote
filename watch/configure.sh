#!/bin/bash
# 把这台 Mac 的地址和 token 写进手表 App 的默认设置（生成 MacRemoteWatch/Config.generated.swift，不进 git）。
# Mac 的 IP 变了就重新运行一次，或者在手表 App 的「设置 → 连接」里改。
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TOKEN="$(cat "$HOME/.config/watchbridge/token" 2>/dev/null || true)"
[[ -n "$TOKEN" ]] || { echo "找不到 ~/.config/watchbridge/token，请先运行一次 Mac 遥控 App"; exit 1; }
IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo 192.168.1.2)"
LOCAL="$(scutil --get LocalHostName 2>/dev/null || hostname -s).local"
PORT="${WATCHBRIDGE_PORT:-8765}"
cat > "$HERE/MacRemoteWatch/Config.generated.swift" <<SWIFT
// 由 configure.sh 生成，不要手改，也不要提交到 git（里面有 token）。
enum WatchDefaults {
    static let host = "$IP"
    static let altHost = "$LOCAL"
    static let port = $PORT
    static let token = "$TOKEN"
}
SWIFT
echo "已写入：Mac 地址 $IP（备用 $LOCAL），端口 $PORT"
