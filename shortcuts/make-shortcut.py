#!/usr/bin/env python3
"""生成「Mac 鼠标」快捷指令（手表上用菜单点按钮控制 Mac）。

用法：python3 shortcuts/make-shortcut.py [Mac的IP]
输出：build/Mac 鼠标.shortcut（已签名，双击就能添加到「快捷指令」，会同步到 iPhone 和手表）
文件里包含 token，不要发给别人；build/ 目录不进 git。
"""
import os
import plistlib
import subprocess
import sys
import urllib.parse
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT_DIR = os.path.join(ROOT, "build")
NAME = "Mac 鼠标"

token = open(os.path.expanduser("~/.config/watchbridge/token")).read().strip()
ip = sys.argv[1] if len(sys.argv) > 1 else subprocess.run(
    ["ipconfig", "getifaddr", "en0"], capture_output=True, text=True).stdout.strip()
port = int(os.environ.get("WATCHBRIDGE_PORT", "8765"))
base = f"http://{ip}:{port}"

# 菜单项 -> 发给 Mac 的语音指令（见 WatchBridge.swift 的 runCommand）。None 表示特殊处理。
MENU = [
    ("🎤 语音输入", None),   # 听写 -> /type（放第一个，最常用）
    ("👆 左键", "点击"),
    ("👆👆 双击", "双击"),
    ("✌️ 右键", "右键"),
    ("⬆️ 向上滚", "向上滚动"),
    ("⬇️ 向下滚", "向下滚动"),
    ("◀️ 光标左移", "鼠标左移"),
    ("▶️ 光标右移", "鼠标右移"),
    ("🔼 光标上移", "鼠标上移"),
    ("🔽 光标下移", "鼠标下移"),
    ("🗣 语音指令", None),   # 听写 -> /command
    ("⏎ 回车", "回车"),
    ("⏯ 播放/暂停", "播放"),
    ("✖️ 退出", None),
]


def uid():
    return str(uuid.uuid4()).upper()


def act(ident, **params):
    return {"WFWorkflowActionIdentifier": ident, "WFWorkflowActionParameters": params}


def text_token(s):
    return {"Value": {"string": s}, "WFSerializationType": "WFTextTokenString"}


def get_url(command):
    q = urllib.parse.urlencode({"token": token, "text": command})
    return act("is.workflow.actions.downloadurl", WFURL=f"{base}/command?{q}", WFHTTPMethod="GET")


def dictate_and_post(path):
    """听写一句话，然后把文字以 JSON {"text": ...} POST 给 Mac"""
    d = uid()
    var = {"Value": {"string": "￼", "attachmentsByRange": {
        "{0, 1}": {"OutputUUID": d, "Type": "ActionOutput", "OutputName": "听写文本"}}},
        "WFSerializationType": "WFTextTokenString"}
    return [
        # 固定用普通话识别，停止方式为「停顿后」
        act("is.workflow.actions.dictatetext", UUID=d, WFSpeechLanguage="zh-CN",
            WFDictateTextStopListening="After Pause"),
        act("is.workflow.actions.downloadurl",
            WFURL=f"{base}{path}?token={urllib.parse.quote(token)}",
            WFHTTPMethod="POST", WFHTTPBodyType="JSON",
            WFJSONValues={"Value": {"WFDictionaryFieldValueItems": [
                {"WFItemType": 0, "WFKey": text_token("text"), "WFValue": var}]},
                "WFSerializationType": "WFDictionaryFieldValue"}),
    ]


loop_id, menu_id = uid(), uid()
actions = [act("is.workflow.actions.repeat.count", GroupingIdentifier=loop_id, WFControlFlowMode=0, WFRepeatCount=300)]
actions.append(act("is.workflow.actions.choosefrommenu", GroupingIdentifier=menu_id, WFControlFlowMode=0,
                   WFMenuPrompt=NAME, WFMenuItems=[title for title, _ in MENU]))
for title, command in MENU:
    actions.append(act("is.workflow.actions.choosefrommenu", GroupingIdentifier=menu_id,
                       WFControlFlowMode=1, WFMenuItemTitle=title))
    if title.endswith("语音输入"):
        actions += dictate_and_post("/type")
    elif title.endswith("语音指令"):
        actions += dictate_and_post("/command")
    elif title.endswith("退出"):
        actions.append(act("is.workflow.actions.exit"))
    else:
        actions.append(get_url(command))
actions.append(act("is.workflow.actions.choosefrommenu", GroupingIdentifier=menu_id, WFControlFlowMode=2, UUID=uid()))
actions.append(act("is.workflow.actions.repeat.count", GroupingIdentifier=loop_id, WFControlFlowMode=2, UUID=uid()))

workflow = {
    "WFWorkflowActions": actions,
    "WFWorkflowClientVersion": "2700.0.0",
    "WFWorkflowMinimumClientVersion": 900,
    "WFWorkflowMinimumClientVersionString": "900",
    "WFWorkflowIcon": {"WFWorkflowIconStartColor": 463140863, "WFWorkflowIconGlyphNumber": 59511},
    "WFWorkflowTypes": ["Watch"],          # 在 Apple Watch 上显示
    "WFWorkflowInputContentItemClasses": [],
    "WFWorkflowImportQuestions": [],
    "WFWorkflowHasShortcutInputVariables": False,
    "WFQuickActionSurfaces": [],
}

os.makedirs(OUT_DIR, exist_ok=True)
unsigned = os.path.join(OUT_DIR, f"{NAME}.unsigned.shortcut")
signed = os.path.join(OUT_DIR, f"{NAME}.shortcut")
with open(unsigned, "wb") as f:
    plistlib.dump(workflow, f, fmt=plistlib.FMT_BINARY)
r = subprocess.run(["shortcuts", "sign", "--mode", "anyone", "--input", unsigned, "--output", signed],
                   capture_output=True, text=True)
os.remove(unsigned)
if r.returncode != 0 or not os.path.exists(signed):
    sys.exit("签名失败：" + (r.stderr or r.stdout).strip())
print(f"已生成：{signed}（Mac 地址 {ip}:{port}，{len(MENU)} 个菜单项）")
