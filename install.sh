#!/bin/bash
# 编译 WatchBridge 并设为开机自启（LaunchAgent）。
# 用法：./install.sh            编译并安装自启
#       ./install.sh uninstall  卸载自启
set -euo pipefail

BIN_DIR="$HOME/.local/bin"
BIN="$BIN_DIR/watchbridge"
LABEL="com.local.watchbridge"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/watchbridge.log"
HERE="$(cd "$(dirname "$0")" && pwd)"

if [[ "${1:-}" == "uninstall" ]]; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  echo "已卸载自启（程序还在 $BIN）"
  exit 0
fi

command -v swiftc >/dev/null || { echo "找不到 swiftc，请先运行：xcode-select --install"; exit 1; }

mkdir -p "$BIN_DIR" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
echo "编译中……"
swiftc -O -import-objc-header "$HERE/CGVirtualDisplay.h" "$HERE/WatchBridge.swift" -o "$BIN"
# iPhone 遥控网页（只改网页时，单独复制这个目录即可，不用重新编译）
WEB_DIR="$HOME/.local/share/watchbridge/web"
mkdir -p "$WEB_DIR"
cp "$HERE/web/"* "$WEB_DIR/"
# 固定签名标识，减少重新编译后辅助功能权限失效的情况
codesign --force --sign - --identifier "$LABEL" "$BIN"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$BIN</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

sleep 1
echo
echo "✅ 已安装并启动。日志：$LOG"
TOKEN_VAL="$(cat "$HOME/.config/watchbridge/token" 2>/dev/null || echo '启动后见日志')"
echo "Token：$TOKEN_VAL"
IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo 你的Mac的IP)"
echo "iPhone 遥控器：用 Safari 打开 http://$IP:8765/remote?token=$TOKEN_VAL"
echo
echo "下一步：系统设置 → 隐私与安全性 → 辅助功能，点 +，按 ⌘⇧G 输入 $BIN 并打开开关。"
echo "然后运行：launchctl kickstart -k gui/$(id -u)/$LABEL"
