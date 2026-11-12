#!/bin/bash
# 一键把「Mac 遥控」装到 Apple Watch。
# 只需要你先做两件一次性的事（脚本检测到没做会停下来告诉你）：
#   1. Xcode → 设置 → Accounts 登录 Apple ID（免费的就行）
#   2. iPhone 用线连这台 Mac 并「信任」，iPhone 和手表都打开「开发者模式」
# 免费 Apple ID 签的 App 7 天后过期，到时重新运行这个脚本即可。
# 可选：TEAM=XXXXXXXXXX 指定签名团队；WATCH=<设备 ID> 指定手表
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PY=/usr/bin/python3

say()  { printf '▸ %s\n' "$*"; }
stop() { printf '\n✋ %s\n' "$*"; exit 1; }

command -v xcodebuild >/dev/null || stop "需要安装 Xcode（App Store 免费下载）。"

# 1. Mac 的地址和 token
say "写入 Mac 的地址和 token……"
./configure.sh

# 2. 签名团队
TEAM="${TEAM:-}"
if [[ -z "$TEAM" ]]; then
  defaults export com.apple.dt.Xcode "$TMP/xcode.plist" 2>/dev/null || true
  TEAM="$($PY -I - "$TMP/xcode.plist" <<'PYEOF' 2>/dev/null || true
import plistlib, sys
try:
    d = plistlib.load(open(sys.argv[1], 'rb'))
except Exception:
    sys.exit(0)
teams = []
for key in ('IDEProvisioningTeamByIdentifier', 'IDEProvisioningTeams'):
    for acct in (d.get(key) or {}).values():
        for t in acct if isinstance(acct, list) else [acct]:
            if isinstance(t, dict) and t.get('teamID'):
                teams.append(t['teamID'])
print(teams[0] if teams else '')
PYEOF
)"
fi
if [[ -z "$TEAM" ]]; then
  # 退一步：从钥匙串里的 Apple Development 证书读团队 ID（证书的 OU 字段）
  CERT="$(security find-certificate -c "Apple Development" -p 2>/dev/null || true)"
  [[ -n "$CERT" ]] && TEAM="$(printf '%s' "$CERT" | /usr/bin/openssl x509 -noout -subject 2>/dev/null | sed -n 's/.*OU=\([A-Z0-9]\{10\}\).*/\1/p' | head -1)"
fi
if [[ -z "$TEAM" ]]; then
  open -a Xcode || true
  stop "Xcode 还没登录 Apple ID。
   已经帮你打开 Xcode：按 ⌘, 打开设置 → Accounts → 左下角 + → Apple ID，登录后关掉设置窗口，再运行一次：
   ./watch/install-watch.sh"
fi
say "签名团队：$TEAM"

# 每个团队用自己的 Bundle ID，免费账号不会撞上别人已注册的
BUNDLE_ID="com.$(echo "$TEAM" | tr 'A-Z' 'a-z').macremote.watch"

# 3. 找手表
xcrun devicectl list devices --json-output "$TMP/devices.json" >/dev/null 2>&1 || true
read -r WATCH_ID WATCH_UDID WATCH_NAME < <($PY -I - "$TMP/devices.json" "${WATCH:-}" <<'PYEOF' || true
import json, sys
want = sys.argv[2]
try:
    devs = json.load(open(sys.argv[1]))['result']['devices']
except Exception:
    devs = []
best = None
for d in devs:
    hw = d.get('hardwareProperties', {})
    if hw.get('reality') != 'physical':
        continue
    kind = (str(hw.get('deviceType', '')) + ' ' + str(hw.get('platform', ''))).lower()
    if 'watch' not in kind:
        continue
    if want and want not in (d.get('identifier'), hw.get('udid')):
        continue
    name = d.get('deviceProperties', {}).get('name', 'Apple Watch').replace(' ', '_')
    best = (d.get('identifier'), hw.get('udid'), name)
    if d.get('connectionProperties', {}).get('tunnelState') == 'connected':
        break
print(*(best or ('', '', '')))
PYEOF
)
if [[ -z "${WATCH_ID:-}" ]]; then
  stop "没找到你的 Apple Watch。请检查：
   1. iPhone 用数据线连到这台 Mac，iPhone 上弹出「要信任此电脑吗」时点「信任」
   2. iPhone：设置 → 隐私与安全性 → 开发者模式 → 打开（会重启）
   3. 手表：设置 → 隐私与安全性 → 开发者模式 → 打开（会重启）
   4. 手表解锁、戴在手上、放在 iPhone 旁边
   第一次可能要在 Xcode 菜单 Window → Devices and Simulators 里等手表准备好（会显示「正在准备」，需要几分钟）。
   做完再运行一次：./watch/install-watch.sh"
fi
say "手表：${WATCH_NAME//_/ }"

# 4. 编译并签名（第一次会自动注册设备、生成免费证书和描述文件）
say "编译中（第一次要一两分钟）……"
if ! xcodebuild -project MacRemoteWatch.xcodeproj -scheme MacRemoteWatch -configuration Debug \
     -destination "id=$WATCH_UDID" -derivedDataPath "$HERE/build/dd" \
     -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
     DEVELOPMENT_TEAM="$TEAM" PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" CODE_SIGN_STYLE=Automatic \
     build > "$TMP/build.log" 2>&1; then
  grep -E "error:" "$TMP/build.log" | sort -u | head -15
  cp "$TMP/build.log" "$HERE/build/last-build.log" 2>/dev/null || true
  stop "编译 / 签名失败，上面是错误信息（完整日志：watch/build/last-build.log）。"
fi

APP="$HERE/build/dd/Build/Products/Debug-watchos/MacRemoteWatch.app"
[[ -d "$APP" ]] || stop "没找到编译出的 App：$APP"

# 5. 安装、启动
say "安装到手表（手表要保持解锁）……"
xcrun devicectl device install app --device "$WATCH_ID" "$APP" > "$TMP/install.log" 2>&1 || {
  tail -5 "$TMP/install.log"
  stop "安装失败。确认手表已解锁、离 iPhone 不远，再试一次。"
}
say "启动……"
if ! xcrun devicectl device process launch --device "$WATCH_ID" "$BUNDLE_ID" > "$TMP/launch.log" 2>&1; then
  echo "   （自动启动没成功，直接在手表上打开「Mac 遥控」就行）"
  if grep -qiE "untrusted|not trusted|profile" "$TMP/launch.log"; then
    echo "   如果提示「不受信任的开发者」：iPhone 设置 → 通用 → VPN 与设备管理 → 点你的 Apple ID → 信任。"
  fi
fi

echo
echo "✅ 已装到手表。抬起手臂转动手腕移动光标，表冠滚动，捏两下 = 右键。"
echo "   免费 Apple ID 签名 7 天后过期，到时重新运行：./watch/install-watch.sh"
