#!/bin/bash
# 打包并安装「Mac 遥控.app」：网页遥控 + Apple Watch 快捷指令接口 + iPhone 自带的 Apple TV 遥控器。
# 用法：./build-app.sh            编译、安装到 /Applications 并启动
#       ./build-app.sh --no-install  只打包到 build/，不安装
# 可选：ATV_CORE=/path/to/atv-core  指定 atv-core 源码位置（默认 ../atv-core），找不到就不带 Apple TV 遥控器功能
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Mac 遥控"
EXEC="MacRemote"
BUNDLE_ID="com.local.macremote"
ATV_CORE="${ATV_CORE:-$HERE/../atv-core}"
OUT="$HERE/build/$APP_NAME.app"
DEST="/Applications/$APP_NAME.app"

command -v swiftc >/dev/null || { echo "找不到 swiftc，请先运行：xcode-select --install"; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources/web"

echo "▸ 编译 Mac 遥控……"
swiftc -O -import-objc-header "$HERE/CGVirtualDisplay.h" "$HERE/WatchBridge.swift" -o "$OUT/Contents/MacOS/$EXEC"
cp "$HERE/web/"* "$OUT/Contents/Resources/web/"

HAS_ATV=0
if [[ -d "$ATV_CORE/crates/atv-cli" ]] && command -v cargo >/dev/null; then
  echo "▸ 编译 Apple TV 遥控器接收端（atv-core）……"
  (cd "$ATV_CORE" && cargo build --release -p atv-cli 2>&1 | grep -E "^(error|warning: unused)|Finished" || true)
  if [[ -x "$ATV_CORE/target/release/atv-cli" ]]; then
    cp "$ATV_CORE/target/release/atv-cli" "$OUT/Contents/MacOS/atv-cli"
    HAS_ATV=1
  fi
  [[ -f "$ATV_CORE/mac-app/resources/AppIcon.icns" ]] && cp "$ATV_CORE/mac-app/resources/AppIcon.icns" "$OUT/Contents/Resources/AppIcon.icns"
else
  echo "⚠️  没找到 atv-core（$ATV_CORE）或 cargo，这次打包不含 Apple TV 遥控器功能"
fi

cat > "$OUT/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>$EXEC</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key>
  <string>需要访问局域网，iPhone 才能连接到这台 Mac 进行遥控。</string>
  <key>NSBonjourServices</key>
  <array>
    <string>_watchbridge._tcp</string>
    <string>_companion-link._tcp</string>
    <string>_mediaremotetv._tcp</string>
    <string>_airplay._tcp</string>
  </array>
</dict>
</plist>
EOF

# 固定的本机签名：macOS 的辅助功能授权认的是签名。用同一把私钥签名，重新编译后授权仍然有效；
# 用临时签名（-）的话每次编译都要重新授权。私钥放在单独的钥匙串文件里，不加入系统钥匙串列表、不改信任设置。
SIGN_DIR="$HOME/.config/watchbridge/signing"
SIGN_KC="$SIGN_DIR/macremote-signing.keychain-db"
SIGN_NAME="Mac Remote Local Signing"
ensure_signing() {
  mkdir -p "$SIGN_DIR"; chmod 700 "$SIGN_DIR"
  if [[ -f "$SIGN_KC" && -f "$SIGN_DIR/password" ]]; then
    security unlock-keychain -p "$(cat "$SIGN_DIR/password")" "$SIGN_KC"
    return
  fi
  echo "▸ 第一次运行：生成本机签名证书……"
  local pw tmp old_kcs
  pw="$(/usr/bin/openssl rand -hex 16)"
  printf '%s' "$pw" > "$SIGN_DIR/password"; chmod 600 "$SIGN_DIR/password"
  tmp="$(mktemp -d)"
  cat > "$tmp/sign.cnf" <<CNF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = $SIGN_NAME
[ext]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CNF
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 7300 -keyout "$tmp/key.pem" -out "$tmp/cert.pem" -config "$tmp/sign.cnf" 2>/dev/null
  /usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$SIGN_NAME" -out "$tmp/id.p12" -passout "pass:$pw"
  old_kcs="$(security list-keychains -d user | sed 's/[" ]//g')"
  rm -f "$SIGN_KC"
  security create-keychain -p "$pw" "$SIGN_KC"
  # shellcheck disable=SC2086
  security list-keychains -d user -s $old_kcs   # 保持原来的钥匙串搜索列表不变
  security set-keychain-settings "$SIGN_KC"      # 不自动锁定
  security unlock-keychain -p "$pw" "$SIGN_KC"
  security import "$tmp/id.p12" -k "$SIGN_KC" -P "$pw" -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$pw" "$SIGN_KC" >/dev/null
  rm -rf "$tmp"
}

echo "▸ 签名……"
SIGN_ARGS=(--sign -)
if [[ -z "${ADHOC_SIGN:-}" ]] && ensure_signing; then
  SIGN_ARGS=(--keychain "$SIGN_KC" --sign "$SIGN_NAME")
else
  echo "⚠️  本机签名不可用，改用临时签名（每次编译后要重新授权辅助功能）"
fi
[[ $HAS_ATV == 1 ]] && codesign --force "${SIGN_ARGS[@]}" --identifier "$BUNDLE_ID.atv-cli" "$OUT/Contents/MacOS/atv-cli"
codesign --force "${SIGN_ARGS[@]}" --identifier "$BUNDLE_ID" "$OUT"

if [[ "${1:-}" == "--no-install" ]]; then
  echo "✅ 已打包：$OUT"
  exit 0
fi

# 旧版的后台服务（install.sh 装的 LaunchAgent）会占用 8765 端口，换成 App 后不再需要
OLD_PLIST="$HOME/Library/LaunchAgents/com.local.watchbridge.plist"
if [[ -f "$OLD_PLIST" ]]; then
  echo "▸ 停用旧版后台服务 com.local.watchbridge……"
  launchctl bootout "gui/$(id -u)/com.local.watchbridge" 2>/dev/null || true
  rm -f "$OLD_PLIST"
fi

echo "▸ 安装到 $DEST ……"
pkill -x "$EXEC" 2>/dev/null || true
sleep 1
rm -rf "$DEST"
ditto "$OUT" "$DEST"

# 用固定签名后，重新安装不会让辅助功能授权失效，所以这里不再清理授权记录。

open "$DEST"
echo
echo "✅ 已安装并启动「$APP_NAME」，图标在屏幕右上角菜单栏。"
echo "   第一次启动会请求「辅助功能」权限：在弹出的系统设置里打开「$APP_NAME」的开关即可，App 会自动重启生效。"
