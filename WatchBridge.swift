// Mac 遥控（WatchBridge）— 菜单栏 App：iPhone / iPad / Apple Watch 通过局域网遥控 Mac。
// 鼠标、键盘、文字、语音指令，实时屏幕镜像（H.264 / JPEG），iPad 全屏适配，Apple Pencil 手写。
//
// 编译：./build-app.sh（打包成「Mac 遥控.app」并安装）
//      或 swiftc -O -import-objc-header CGVirtualDisplay.h WatchBridge.swift -o watchbridge
// 运行：./watchbridge [--port 8765]
//
// 接口（都需要 token：请求头 "Authorization: Bearer <token>"，或 URL 参数 ?token=<token>）:
//   GET  /ping                 -> "pong"（不需要 token）
//   POST /type     {"text": "你好"}       把文字输入到当前焦点
//   POST /key      {"key": "cmd+space"}   发送按键 / 组合键
//   POST /command  {"text": "打开 Safari"} 解析中文语音指令
//   POST /batch    [{"t":"move",…}, …]    一次发多条遥控消息（手表 App 用）
//   GET  /remote               遥控网页（web/remote.html，不需要 token）
//   GET  /ca.cer               本机根证书（手机信任后可用 https 和视频模式，不需要 token）
//   GET  /ws?token=…           遥控 WebSocket（消息格式见 docs/开发说明.md）
// 请求体也可以直接是纯文本。详细说明见 docs/。

import AppKit
import ApplicationServices
import CoreImage
import CryptoKit
import Foundation
import IOKit.pwr_mgt
import Network
import OpenDirectory
import ScreenCaptureKit
import ServiceManagement
import VideoToolbox

// MARK: - 配置

let configDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/watchbridge", isDirectory: true)
let tokenFile = configDir.appendingPathComponent("token")

func loadOrCreateToken() -> String {
    if let env = ProcessInfo.processInfo.environment["WATCHBRIDGE_TOKEN"], !env.isEmpty { return env }
    if let s = try? String(contentsOf: tokenFile, encoding: .utf8) {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
    }
    let chars = Array("abcdefghijkmnpqrstuvwxyz23456789")
    let token = String((0..<16).map { _ in chars.randomElement()! })
    try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
    try? token.write(to: tokenFile, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFile.path)
    return token
}

func argValue(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let port = UInt16(argValue("--port") ?? ProcessInfo.processInfo.environment["WATCHBRIDGE_PORT"] ?? "8765") ?? 8765
let token = loadOrCreateToken()

// MARK: - 键盘

let keyCodes: [String: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
    "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
    "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
    "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
    "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
    "n": 45, "m": 46, ".": 47, "`": 50,
    "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51,
    "esc": 53, "escape": 53, "forwarddelete": 117, "home": 115, "end": 119,
    "pageup": 116, "pagedown": 121,
    "left": 123, "right": 124, "down": 125, "up": 126,
    "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
    "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
]

/// 修饰键：标志位 + 物理键码（fn 的键码为 nil，单独按 fn 可能触发听写 / 表情面板，所以只设标志位）
let modifierKeys: [String: (CGEventFlags, CGKeyCode?)] = [
    "cmd": (.maskCommand, 55), "command": (.maskCommand, 55),
    "ctrl": (.maskControl, 59), "control": (.maskControl, 59),
    "opt": (.maskAlternate, 58), "option": (.maskAlternate, 58), "alt": (.maskAlternate, 58),
    "shift": (.maskShift, 56), "fn": (.maskSecondaryFn, nil),
]

/// 方向键、Home/End 等在真实键盘上会自带 fn / 小键盘标志，模拟时补上，Ctrl+方向键切换桌面才更可靠
let navKeys: Set<CGKeyCode> = [115, 116, 117, 119, 121, 123, 124, 125, 126]
let arrowKeys: Set<CGKeyCode> = [123, 124, 125, 126]

let eventSource = CGEventSource(stateID: .hidSystemState)

func postKey(_ code: CGKeyCode, flags: CGEventFlags = []) {
    var f = flags
    if navKeys.contains(code) { f.insert(.maskSecondaryFn) }
    if arrowKeys.contains(code) { f.insert(.maskNumericPad) }
    let down = CGEvent(keyboardEventSource: eventSource, virtualKey: code, keyDown: true)
    let up = CGEvent(keyboardEventSource: eventSource, virtualKey: code, keyDown: false)
    down?.flags = f
    up?.flags = f
    down?.post(tap: .cghidEventTap)
    usleep(8_000)
    up?.post(tap: .cghidEventTap)
    usleep(8_000)
}

/// 单独发一个修饰键的按下 / 抬起（让依赖修饰键状态的 App、系统快捷键也能识别）
func postModifier(_ code: CGKeyCode, down: Bool, flags: CGEventFlags) {
    guard let ev = CGEvent(keyboardEventSource: eventSource, virtualKey: code, keyDown: down) else { return }
    ev.type = .flagsChanged
    ev.flags = flags
    ev.post(tap: .cghidEventTap)
    usleep(4_000)
}

/// 解析 "cmd+shift+3" 这类组合键。返回 false 表示无法识别。
@discardableResult
func pressCombo(_ combo: String) -> Bool {
    let parts = combo.lowercased().replacingOccurrences(of: " ", with: "")
        .split(separator: "+", omittingEmptySubsequences: false).map(String.init)
    // "cmd++" 之类：最后一段为空时按 "=" 处理（即 ⌘+ 放大）
    var keyName = parts.last ?? ""
    if keyName.isEmpty && parts.count >= 2 { keyName = "=" }
    guard let code = keyCodes[keyName] else { return false }
    var mods: [(CGEventFlags, CGKeyCode?)] = []
    for m in parts.dropLast() where !m.isEmpty {
        guard let mk = modifierKeys[m] else { return false }
        mods.append(mk)
    }
    var flags: CGEventFlags = []
    for (f, c) in mods {
        flags.insert(f)
        if let c = c { postModifier(c, down: true, flags: flags) }
    }
    postKey(code, flags: flags)
    for (f, c) in mods.reversed() {
        flags.remove(f)
        if let c = c { postModifier(c, down: false, flags: flags) }
    }
    return true
}

/// 通过剪贴板粘贴文字（个别 App 不接受 Unicode 键盘事件时用），粘贴后恢复原剪贴板
func pasteText(_ text: String) {
    let pb = NSPasteboard.general
    let saved: [[(NSPasteboard.PasteboardType, Data)]] = (pb.pasteboardItems ?? []).map { item in
        item.types.compactMap { t in item.data(forType: t).map { (t, $0) } }
    }
    pb.clearContents()
    pb.setString(text, forType: .string)
    let changeCount = pb.changeCount
    pressCombo("cmd+v")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        guard pb.changeCount == changeCount else { return }  // 期间用户自己复制了东西，就不恢复
        pb.clearContents()
        let items: [NSPasteboardItem] = saved.map { pairs in
            let it = NSPasteboardItem()
            for (t, d) in pairs { it.setData(d, forType: t) }
            return it
        }
        if !items.isEmpty { pb.writeObjects(items) }
    }
}

/// 用 Unicode 事件直接输入文字（中文、emoji 都可以，不经过输入法）。
func typeText(_ text: String) {
    let src = CGEventSource(stateID: .hidSystemState)
    var buffer: [UniChar] = []
    func flush() {
        guard !buffer.isEmpty else { return }
        // 每个事件最多带 20 个 UTF-16 单元
        var i = 0
        while i < buffer.count {
            var end = min(i + 20, buffer.count)
            // 不要把代理对（emoji）拆开
            if end < buffer.count, UTF16.isLeadSurrogate(buffer[end - 1]) { end -= 1 }
            var chunk = Array(buffer[i..<end])
            let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)
            let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
            down?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            up?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
            usleep(10_000)
            i = end
        }
        buffer.removeAll()
    }
    for ch in text {
        if ch == "\n" || ch == "\r\n" {
            flush()
            postKey(36)
        } else if ch == "\t" {
            flush()
            postKey(48)
        } else {
            buffer.append(contentsOf: Array(String(ch).utf16))
        }
    }
    flush()
}

/// 一个字一个字地按真实按键输入（美式键盘布局）。锁屏的密码框是安全输入框，不接受上面那种 Unicode 事件，只认真按键
let shiftedKeys: [Character: Character] = [
    "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
    "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
]

func typeByKeys(_ text: String) {
    for ch in text {
        if ch == "\n" || ch == "\r\n" { postKey(36); continue }
        if ch == "\t" { postKey(48); continue }
        if ch == " " { postKey(49); continue }
        var base = ch, shift = false
        if let b = shiftedKeys[ch] { base = b; shift = true }
        else if ch.isUppercase, ch.isASCII { base = Character(ch.lowercased()); shift = true }
        guard let code = keyCodes[String(base)] else { typeText(String(ch)); continue }   // 键盘上没有的字（中文等）
        if shift {
            postModifier(56, down: true, flags: .maskShift)
            postKey(code, flags: .maskShift)
            postModifier(56, down: false, flags: [])
        } else {
            postKey(code)
        }
    }
}

// MARK: - 媒体键（播放/暂停、音量等）

enum MediaKey: Int32 {
    case soundUp = 0, soundDown = 1, brightnessUp = 2, brightnessDown = 3
    case mute = 7, play = 16, next = 17, previous = 18
}

func pressMedia(_ key: MediaKey) {
    func send(_ down: Bool) {
        let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
        let data1 = Int((key.rawValue << 16) | (down ? 0xA00 : 0xB00))
        let ev = NSEvent.otherEvent(
            with: .systemDefined, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: 0, context: nil,
            subtype: 8, data1: data1, data2: -1)
        ev?.cgEvent?.post(tap: .cghidEventTap)
    }
    send(true)
    usleep(8_000)
    send(false)
}

// MARK: - 鼠标

// 以下函数都只在主线程调用。

/// 自己记录光标位置：高频移动时，刚 post 的事件可能还没生效，直接读系统位置会丢位移、卡顿
var trackedCursor: CGPoint? = nil
var lastMouseWrite: TimeInterval = 0

func currentMouse() -> CGPoint {
    let now = ProcessInfo.processInfo.systemUptime
    if let p = trackedCursor, now - lastMouseWrite < 0.25 { return p }
    return CGEvent(source: nil)?.location ?? .zero
}

/// 多显示器：新位置在任意屏幕内就放行，否则贴住原来所在屏幕的边
func clampToScreens(_ p: CGPoint, from old: CGPoint) -> CGPoint {
    var id = CGDirectDisplayID()
    var n: UInt32 = 0
    if CGGetDisplaysWithPoint(p, 1, &id, &n) == .success, n > 0 { return p }
    var b = CGDisplayBounds(CGMainDisplayID())
    if CGGetDisplaysWithPoint(old, 1, &id, &n) == .success, n > 0 { b = CGDisplayBounds(id) }
    return CGPoint(x: min(max(p.x, b.minX), b.maxX - 1), y: min(max(p.y, b.minY), b.maxY - 1))
}

/// 当前按住不放的鼠标键（三指拖动 / 按住左键时）
var heldButton: CGMouseButton? = nil

func mouseTypes(_ b: CGMouseButton) -> (down: CGEventType, up: CGEventType, drag: CGEventType) {
    switch b {
    case .right: return (.rightMouseDown, .rightMouseUp, .rightMouseDragged)
    case .center: return (.otherMouseDown, .otherMouseUp, .otherMouseDragged)
    default: return (.leftMouseDown, .leftMouseUp, .leftMouseDragged)
    }
}

/// 连击计数：两次点击间隔小于系统双击间隔且位置接近，就算双击 / 三击
var lastClick: (time: TimeInterval, pos: CGPoint, button: CGMouseButton, count: Int) = (0, .zero, .left, 0)

func nextClickCount(_ b: CGMouseButton, at p: CGPoint) -> Int {
    let now = ProcessInfo.processInfo.systemUptime
    if b == lastClick.button, now - lastClick.time < NSEvent.doubleClickInterval,
       hypot(p.x - lastClick.pos.x, p.y - lastClick.pos.y) < 8 {
        lastClick.count += 1
    } else {
        lastClick.count = 1
    }
    lastClick.time = now
    lastClick.pos = p
    lastClick.button = b
    return lastClick.count
}

func moveMouse(dx: CGFloat, dy: CGFloat) {
    let old = currentMouse()
    let p = clampToScreens(CGPoint(x: old.x + dx, y: old.y + dy), from: old)
    let type = heldButton.map { mouseTypes($0).drag } ?? .mouseMoved
    guard let ev = CGEvent(mouseEventSource: eventSource, mouseType: type,
                           mouseCursorPosition: p, mouseButton: heldButton ?? .left) else { return }
    ev.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx.rounded()))
    ev.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy.rounded()))
    if heldButton != nil { ev.setIntegerValueField(.mouseEventClickState, value: Int64(lastClick.count)) }
    ev.post(tap: .cghidEventTap)
    trackedCursor = p
    lastMouseWrite = ProcessInfo.processInfo.systemUptime
}

func moveMouseTo(_ target: CGPoint) {
    let old = currentMouse()
    let p = clampToScreens(target, from: old)
    // 按住键时发拖动事件（Apple Pencil 写字 / 画画）
    let type = heldButton.map { mouseTypes($0).drag } ?? .mouseMoved
    guard let ev = CGEvent(mouseEventSource: eventSource, mouseType: type,
                           mouseCursorPosition: p, mouseButton: heldButton ?? .left) else { return }
    ev.setIntegerValueField(.mouseEventDeltaX, value: Int64((p.x - old.x).rounded()))
    ev.setIntegerValueField(.mouseEventDeltaY, value: Int64((p.y - old.y).rounded()))
    if heldButton != nil { ev.setIntegerValueField(.mouseEventClickState, value: Int64(lastClick.count)) }
    ev.post(tap: .cghidEventTap)
    trackedCursor = p
    lastMouseWrite = ProcessInfo.processInfo.systemUptime
}

func mouseButton(_ b: CGMouseButton, down: Bool) {
    let p = currentMouse()
    if down {
        _ = nextClickCount(b, at: p)
        heldButton = b
    } else {
        guard heldButton == b else { return }  // 没按下就不发抬起
        heldButton = nil
    }
    let t = mouseTypes(b)
    guard let ev = CGEvent(mouseEventSource: eventSource, mouseType: down ? t.down : t.up,
                           mouseCursorPosition: p, mouseButton: b) else { return }
    ev.setIntegerValueField(.mouseEventClickState, value: Int64(lastClick.count))
    ev.post(tap: .cghidEventTap)
}

func click(_ b: CGMouseButton = .left) {
    if let h = heldButton { mouseButton(h, down: false) }
    mouseButton(b, down: true)
    usleep(12_000)
    mouseButton(b, down: false)
}

func click(right: Bool = false, double: Bool = false) {
    click(right ? .right : .left)
    if double { usleep(30_000); click(right ? .right : .left) }
}

/// 遥控断开时，别让鼠标键一直按着
func releaseHeldButton() {
    if let b = heldButton { mouseButton(b, down: false) }
}

func scroll(lines: Int32) {
    CGEvent(scrollWheelEvent2Source: eventSource, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0)?
        .post(tap: .cghidEventTap)
}

/// 触控板式的像素滚动。phase: 1 开始 / 2 进行中 / 4 结束；momentum（惯性）: 1 开始 / 2 继续 / 3 结束。
/// 带上阶段信息后，Safari 的回弹、双指左右滑动前进后退等行为才和真触控板一致。
var scrollRemainder: (x: Double, y: Double) = (0, 0)
var scrollActive = false
let scrollPhaseField = CGEventField(rawValue: 99)!      // kCGScrollWheelEventScrollPhase
let momentumPhaseField = CGEventField(rawValue: 123)!   // kCGScrollWheelEventMomentumPhase

func postScroll(dx: Double, dy: Double, phase: Int64, momentum: Int64) {
    let fx = dx + scrollRemainder.x, fy = dy + scrollRemainder.y
    let ix = Int32(fx.rounded(.towardZero)), iy = Int32(fy.rounded(.towardZero))
    scrollRemainder = (fx - Double(ix), fy - Double(iy))
    let isEdge = phase == 1 || phase == 4 || momentum == 1 || momentum == 3
    if ix == 0 && iy == 0 && !isEdge { return }
    if phase == 4 || momentum == 3 {
        guard scrollActive else { return }  // 没在滚动就不发多余的结束事件
        scrollRemainder = (0, 0)
    }
    scrollActive = !(phase == 4 || momentum == 3)
    guard let ev = CGEvent(scrollWheelEvent2Source: eventSource, units: .pixel, wheelCount: 2,
                           wheel1: iy, wheel2: ix, wheel3: 0) else { return }
    ev.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    ev.setIntegerValueField(scrollPhaseField, value: phase)
    ev.setIntegerValueField(momentumPhaseField, value: momentum)
    ev.post(tap: .cghidEventTap)
}

// MARK: - 打开 App

let appAliases: [String: String] = [
    "微信": "WeChat", "浏览器": "Safari", "safari": "Safari", "谷歌": "Google Chrome",
    "chrome": "Google Chrome", "谷歌浏览器": "Google Chrome", "访达": "Finder",
    "备忘录": "Notes", "音乐": "Music", "终端": "Terminal", "系统设置": "System Settings",
    "设置": "System Settings", "日历": "Calendar", "邮件": "Mail", "信息": "Messages",
    "照片": "Photos", "计算器": "Calculator", "地图": "Maps", "提醒事项": "Reminders",
    "播客": "Podcasts", "视频": "TV", "预览": "Preview", "文本编辑": "TextEdit",
    "活动监视器": "Activity Monitor", "qq": "QQ", "钉钉": "DingTalk", "飞书": "Lark",
    "网易云音乐": "NeteaseMusic", "vscode": "Visual Studio Code", "代码编辑器": "Visual Studio Code",
]

func openApp(_ spoken: String) -> Bool {
    let key = spoken.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    guard !key.isEmpty else { return false }
    let name = appAliases[key.lowercased()] ?? appAliases[key] ?? key
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = ["-a", name]
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return false }
    p.waitUntilExit()
    return p.terminationStatus == 0
}

// MARK: - 语音指令解析

/// 去掉听写常带的结尾标点和空白
func clean(_ s: String) -> String {
    var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    while let last = t.last, "。，！？.,!? ".contains(last) { t.removeLast() }
    return t
}

func stripPrefix(_ s: String, _ prefixes: [String]) -> String? {
    for p in prefixes where s.hasPrefix(p) {
        return String(s.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
    }
    return nil
}

/// 返回 (成功?, 给手表显示/朗读的回复)
func runCommand(_ raw: String) -> (Bool, String) {
    let s = clean(raw)
    let lower = s.lowercased()

    // 带参数的指令
    if let rest = stripPrefix(s, ["输入", "打字", "键入"]) {
        typeText(rest); return (true, "已输入")
    }
    if let rest = stripPrefix(s, ["打开", "启动", "运行"]) {
        return openApp(rest) ? (true, "已打开 \(rest)") : (false, "找不到应用：\(rest)")
    }
    if let rest = stripPrefix(s, ["搜索", "查找"]) {
        pressCombo("cmd+space"); usleep(300_000); typeText(rest)
        return (true, "已在聚焦中搜索")
    }
    if let rest = stripPrefix(s, ["按键", "按下"]) {
        return pressCombo(rest) ? (true, "已按 \(rest)") : (false, "不认识这个按键：\(rest)")
    }

    // 固定指令：关键词 -> 动作。按顺序匹配，较长 / 较具体的放前面。
    let table: [([String], () -> Void, String)] = [
        (["下一首", "下一曲"], { pressMedia(.next) }, "下一首"),
        (["上一首", "上一曲"], { pressMedia(.previous) }, "上一首"),
        (["暂停", "播放", "继续播放"], { pressMedia(.play) }, "播放/暂停"),
        (["取消静音", "静音"], { pressMedia(.mute) }, "静音切换"),
        (["音量调大", "大声", "调大音量", "音量加"], { for _ in 0..<3 { pressMedia(.soundUp) } }, "音量 +"),
        (["音量调小", "小声", "调小音量", "音量减"], { for _ in 0..<3 { pressMedia(.soundDown) } }, "音量 -"),
        (["亮度调高", "调亮"], { for _ in 0..<3 { pressMedia(.brightnessUp) } }, "亮度 +"),
        (["亮度调低", "调暗"], { for _ in 0..<3 { pressMedia(.brightnessDown) } }, "亮度 -"),
        (["全屏"], { pressCombo("ctrl+cmd+f") }, "全屏切换"),  // 含"退出全屏"，必须在"退出"前面
        (["关闭窗口", "关掉窗口"], { pressCombo("cmd+w") }, "已关闭窗口"),
        (["退出应用", "退出程序", "退出"], { pressCombo("cmd+q") }, "已退出"),
        (["新标签", "新建标签"], { pressCombo("cmd+t") }, "新标签页"),
        (["新窗口", "新建窗口"], { pressCombo("cmd+n") }, "新窗口"),
        (["切换应用", "切换窗口", "上一个应用"], { pressCombo("cmd+tab") }, "已切换"),
        (["截图", "截屏"], { pressCombo("cmd+shift+3") }, "已截图"),
        (["锁屏", "锁定屏幕"], { pressCombo("ctrl+cmd+q") }, "已锁屏"),
        (["聚焦", "spotlight"], { pressCombo("cmd+space") }, "已打开聚焦"),
        (["全选"], { pressCombo("cmd+a") }, "全选"),
        (["复制"], { pressCombo("cmd+c") }, "已复制"),
        (["粘贴"], { pressCombo("cmd+v") }, "已粘贴"),
        (["剪切"], { pressCombo("cmd+x") }, "已剪切"),
        (["撤销"], { pressCombo("cmd+z") }, "已撤销"),
        (["保存"], { pressCombo("cmd+s") }, "已保存"),
        (["刷新"], { pressCombo("cmd+r") }, "已刷新"),
        (["删除", "退格"], { postKey(51) }, "删除"),
        (["回车", "确认", "确定", "发送"], { postKey(36) }, "回车"),
        (["返回", "取消"], { postKey(53) }, "Esc"),
        (["双击"], { click(double: true) }, "双击"),
        (["右键", "右击"], { click(right: true) }, "右键"),
        (["点击", "单击", "左键"], { click() }, "点击"),
        (["向下滚动", "往下滚", "下滚"], { scroll(lines: -8) }, "向下滚动"),
        (["向上滚动", "往上滚", "上滚"], { scroll(lines: 8) }, "向上滚动"),
        (["鼠标左移", "光标左移", "鼠标向左"], { moveMouse(dx: -150, dy: 0) }, "←"),
        (["鼠标右移", "光标右移", "鼠标向右"], { moveMouse(dx: 150, dy: 0) }, "→"),
        (["鼠标上移", "光标上移", "鼠标向上"], { moveMouse(dx: 0, dy: -150) }, "↑"),
        (["鼠标下移", "光标下移", "鼠标向下"], { moveMouse(dx: 0, dy: 150) }, "↓"),
        (["向左"], { postKey(123) }, "←"),
        (["向右"], { postKey(124) }, "→"),
        (["向上"], { postKey(126) }, "↑"),
        (["向下"], { postKey(125) }, "↓"),
    ]
    for (words, action, reply) in table where words.contains(where: { lower.contains($0) }) {
        action()
        return (true, reply)
    }
    return (false, "没听懂：\(s)")
}

// MARK: - 极简 HTTP 服务

struct Request {
    var method = ""
    var path = ""
    var query: [String: String] = [:]
    var headers: [String: String] = [:]
    var body = Data()
    var extra = Data()  // 请求之后多出来的字节（WebSocket 客户端可能紧跟着发帧）
}

func parseHead(_ data: Data) -> (Request, Int)? {
    guard let range = data.range(of: Data("\r\n\r\n".utf8)),
          let head = String(data: data[..<range.lowerBound], encoding: .utf8) else { return nil }
    var lines = head.components(separatedBy: "\r\n")
    let first = lines.removeFirst().split(separator: " ")
    guard first.count >= 2 else { return nil }
    var req = Request()
    req.method = String(first[0])
    let target = String(first[1])
    if let comps = URLComponents(string: target) {
        req.path = comps.path
        for item in comps.queryItems ?? [] { req.query[item.name] = item.value ?? "" }
    } else {
        req.path = target
    }
    for line in lines {
        guard let idx = line.firstIndex(of: ":") else { continue }
        let k = line[..<idx].trimmingCharacters(in: .whitespaces).lowercased()
        let v = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
        req.headers[k] = v
    }
    return (req, range.upperBound)
}

/// 从请求体里取出参数：支持 JSON {"text":...} / {"key":...}、表单 text=...、纯文本
func bodyValue(_ req: Request, keys: [String]) -> String {
    for k in keys { if let v = req.query[k], !v.isEmpty { return v } }
    let ctype = req.headers["content-type"] ?? ""
    if let obj = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any] {
        for k in keys { if let v = obj[k] { return "\(v)" } }
    }
    let str = String(data: req.body, encoding: .utf8) ?? ""
    if ctype.contains("x-www-form-urlencoded"), let comps = URLComponents(string: "?" + str) {
        for k in keys {
            if let v = comps.queryItems?.first(where: { $0.name == k })?.value {
                return v.replacingOccurrences(of: "+", with: " ")
            }
        }
    }
    return str
}

func authorized(_ req: Request) -> Bool {
    if let a = req.headers["authorization"], a == "Bearer \(token)" { return true }
    if req.query["token"] == token { return true }
    return false
}

func respond(_ conn: NWConnection, _ status: Int, _ text: String) {
    respond(conn, status, Data(text.utf8), type: "text/plain; charset=utf-8")
}

func respond(_ conn: NWConnection, _ status: Int, _ body: Data, type: String) {
    let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 422: "Unprocessable"][status] ?? "OK"
    var head = "HTTP/1.1 \(status) \(reason)\r\n"
    head += "Content-Type: \(type)\r\nCache-Control: no-store\r\n"
    head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
    conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
}

// MARK: - 遥控网页

/// 网页文件放在磁盘上，改网页不用重新编译（也就不会弄丢辅助功能权限）
func webFile(_ name: String) -> Data? {
    var dirs: [URL] = []
    if let e = ProcessInfo.processInfo.environment["WATCHBRIDGE_WEB"] { dirs.append(URL(fileURLWithPath: e)) }
    if let res = Bundle.main.resourceURL { dirs.append(res.appendingPathComponent("web")) }  // App 包里自带的网页
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
    dirs.append(exe.appendingPathComponent("web"))
    dirs.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/watchbridge/web"))
    dirs.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("web"))
    for d in dirs {
        if let data = try? Data(contentsOf: d.appendingPathComponent(name)) { return data }
    }
    return nil
}

// MARK: - WebSocket（遥控器用，低延迟、长连接）

final class WebSocketSession {
    let conn: NWConnection
    let ip: String
    private var buf: [UInt8] = []
    private var message: [UInt8] = []
    private var messageOpcode: UInt8 = 0
    private var closed = false
    private var finished = false
    private var lastRx = ProcessInfo.processInfo.systemUptime
    /// 所有连着的会话；网页每 3 秒 ping 一次，30 秒没动静（设备睡了 / 断网）就当断开，让屏幕适配及时恢复
    private static var live = [ObjectIdentifier: WebSocketSession]()
    private static let liveLock = NSLock()
    private static let watchdog: DispatchSourceTimer = {
        let t = DispatchSource.makeTimerSource(queue: .global())
        t.schedule(deadline: .now() + 10, repeating: 10)
        t.setEventHandler {
            let now = ProcessInfo.processInfo.systemUptime
            liveLock.lock(); let all = Array(live.values); liveLock.unlock()
            for s in all where now - s.lastRx > 30 {
                log("遥控 \(s.ip) 30 秒没有动静，断开")
                s.conn.cancel()
            }
        }
        t.resume()
        return t
    }()

    init(conn: NWConnection, ip: String) {
        self.conn = conn
        self.ip = ip
    }

    static func acceptKey(_ key: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        return Data(digest).base64EncodedString()
    }

    func start(key: String, authorized: Bool, leftover: Data = Data()) {
        let head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: \(Self.acceptKey(key))\r\n\r\n"
        conn.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        guard authorized else {
            // 先升级再报错，网页才能拿到原因
            log("拒绝遥控 \(ip)：token 不对")
            send(["t": "error", "text": "token 不对"])
            sendFrame(0x8, [0x0F, 0xA1])  // 关闭码 4001
            closed = true
            conn.send(content: nil, contentContext: .finalMessage, isComplete: true,
                      completion: .contentProcessed { [conn] _ in conn.cancel() })
            return
        }
        log("遥控已连接：\(ip)")
        _ = Self.watchdog
        Self.liveLock.lock(); Self.live[ObjectIdentifier(self)] = self; Self.liveLock.unlock()
        // page = 网页文件的指纹：Mac 更新了网页，已经打开的手机网页重连时会自动刷新
        let page = webFile("remote.html").map { SHA256.hash(data: $0).prefix(6).map { String(format: "%02x", $0) }.joined() } ?? ""
        send(["t": "hello", "https": httpsReady ? Int(httpsPort) : 0, "page": page,
              "locked": Waker.screenLocked(), "unlock": AutoUnlock.available])
        buf.append(contentsOf: leftover)
        parse()
        read()
    }

    private func read() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
            if let data = data { self.buf.append(contentsOf: data); self.lastRx = ProcessInfo.processInfo.systemUptime }
            self.parse()
            if done || error != nil || self.closed { self.finish(); return }
            self.read()
        }
    }

    private func parse() {
        while !closed {
            guard buf.count >= 2 else { return }
            let b0 = buf[0], b1 = buf[1]
            let fin = b0 & 0x80 != 0, opcode = b0 & 0x0F, masked = b1 & 0x80 != 0
            var len = Int(b1 & 0x7F)
            var off = 2
            if len == 126 {
                guard buf.count >= 4 else { return }
                len = Int(buf[2]) << 8 | Int(buf[3]); off = 4
            } else if len == 127 {
                guard buf.count >= 10 else { return }
                len = 0
                for i in 2..<10 { len = len << 8 | Int(buf[i]) }
                off = 10
            }
            guard len <= 1_000_000 else { closed = true; return }
            let maskAt = off
            if masked { off += 4 }
            guard buf.count >= off + len else { return }
            var payload = Array(buf[off..<(off + len)])
            if masked { for i in 0..<len { payload[i] ^= buf[maskAt + i % 4] } }
            buf.removeFirst(off + len)

            switch opcode {
            case 0x8: sendFrame(0x8, Array(payload.prefix(2))); closed = true
            case 0x9: sendFrame(0xA, payload)
            case 0xA: break
            case 0x0, 0x1, 0x2:
                if opcode != 0 { messageOpcode = opcode; message = [] }
                message += payload
                if fin {
                    if messageOpcode == 0x1, let s = String(bytes: message, encoding: .utf8) { onText(s) }
                    message = []
                }
            default: closed = true
            }
        }
    }

    private func onText(_ s: String) {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] else { return }
        DispatchQueue.main.async { handleRemote(obj, self) }
    }

    /// 发二进制帧（屏幕画面），发完回调，用来做「上一帧没发完就跳过」的限流
    func sendBinary(_ data: Data, done: @escaping () -> Void) {
        var f: [UInt8] = [0x82]
        let n = data.count
        if n < 126 { f.append(UInt8(n)) }
        else if n < 65536 { f += [126, UInt8(n >> 8), UInt8(n & 0xFF)] }
        else { f.append(127); for s in stride(from: 56, through: 0, by: -8) { f.append(UInt8((n >> s) & 0xFF)) } }
        conn.send(content: Data(f) + data, completion: .contentProcessed { _ in done() })
    }

    func sendFrame(_ opcode: UInt8, _ payload: [UInt8]) {
        var f: [UInt8] = [0x80 | opcode]
        let n = payload.count
        if n < 126 {
            f.append(UInt8(n))
        } else if n < 65536 {
            f += [126, UInt8(n >> 8), UInt8(n & 0xFF)]
        } else {
            f.append(127)
            for s in stride(from: 56, through: 0, by: -8) { f.append(UInt8((n >> s) & 0xFF)) }
        }
        f += payload
        conn.send(content: Data(f), completion: .contentProcessed { _ in })
    }

    func send(_ obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return }
        sendFrame(0x1, [UInt8](d))
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        Self.liveLock.lock(); Self.live.removeValue(forKey: ObjectIdentifier(self)); Self.liveLock.unlock()
        conn.cancel()
        log("遥控已断开：\(ip)")
        ScreenStreamer.shared.unsubscribe(self)
        let me = ObjectIdentifier(self)
        DispatchQueue.main.async { FitDisplay.shared.release(me) }
        DispatchQueue.main.async {
            releaseHeldButton()
            postScroll(dx: 0, dy: 0, phase: 4, momentum: 0)
        }
    }
}

func num(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? Double("\(v ?? 0)") ?? 0 }

func buttonFrom(_ v: Any?) -> CGMouseButton {
    switch v as? String {
    case "right": return .right
    case "middle": return .center
    default: return .left
    }
}

// MARK: - 程序坞：点图标时直接「按」它

enum DockHit {
    /// p 处是不是程序坞里的图标（应用、文件夹、废纸篓……），是就返回它
    static func item(at p: CGPoint) -> AXUIElement? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
        else { return nil }
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.25)
        var el: AXUIElement?
        guard AXUIElementCopyElementAtPosition(sys, Float(p.x), Float(p.y), &el) == .success, let e = el else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(e, &pid) == .success, pid == dock else { return nil }
        return attr(e, kAXRoleAttribute) == "AXDockItem" ? e : nil
    }
    static func attr(_ e: AXUIElement, _ name: String) -> String? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v as? String : nil
    }
    /// 程序坞设成了自动隐藏、并且 p 在它那条边上一窄条（14 点）里：返回贴着边的点（光标移过去程序坞就会出来）
    static func revealPoint(for p: CGPoint, in b: CGRect) -> CGPoint? {
        guard (CFPreferencesCopyAppValue("autohide" as CFString, "com.apple.dock" as CFString) as? Bool) == true else { return nil }
        let side = CFPreferencesCopyAppValue("orientation" as CFString, "com.apple.dock" as CFString) as? String ?? "bottom"
        let band: CGFloat = 14
        switch side {
        case "left":  return p.x - b.minX < band ? CGPoint(x: b.minX, y: p.y) : nil
        case "right": return b.maxX - p.x < band ? CGPoint(x: b.maxX - 1, y: p.y) : nil
        default:      return b.maxY - p.y < band ? CGPoint(x: p.x, y: b.maxY - 1) : nil
        }
    }
    /// 打开它（menu = true 时弹出它的右键菜单）
    static func press(_ e: AXUIElement, menu: Bool) {
        let r = AXUIElementPerformAction(e, (menu ? kAXShowMenuAction : kAXPressAction) as CFString)
        log("程序坞：\(menu ? "右键" : "打开")「\(attr(e, kAXTitleAttribute) ?? "?")」\(r == .success ? "" : "失败 \(r.rawValue)")")
    }
}
/// Pencil 落在程序坞图标上时记下是哪个（抬笔时按）
var penDock: (AXUIElement, CGPoint)?

/// 遥控消息（主线程执行）。消息格式见 web/remote.html 里的 send(...)
func handleRemote(_ m: [String: Any], _ s: WebSocketSession) {
    if m["t"] as? String == "screenAck" { ScreenStreamer.shared.acked(s); return }
    if m["t"] as? String == "screenKey" { ScreenStreamer.shared.requestKey(s); return }
    if m["t"] as? String == "vstat" {
        log("\(s.ip) 视频统计：\(m["codec"] ?? "?") \(m["size"] ?? "?")，收到 \(m["rx"] ?? 0) 帧，解出 \(m["out"] ?? 0) 帧，"
            + "排队 \(m["q"] ?? "?")，状态 \(m["state"] ?? "?")，清空 \(m["flushes"] ?? 0) 次，"
            + "画法 \(m["render"] ?? "?")，像素格式 \(m["fmt"] ?? "?")，不同画面 \(m["distinct"] ?? "?") 种\((m["drawErr"] as? String).map { $0.isEmpty ? "" : "，画图出错：" + $0 } ?? "")")
        return
    }
    if m["t"] as? String == "vlog" {
        log("\(s.ip) 视频解码出错：\(m["text"] ?? "?")（\(m["codec"] ?? "?")，画面 \(m["w"] ?? "?")，出错前解出 \(m["got"] ?? 0) 帧）")
        return
    }
    if m["t"] as? String == "client" {
        func yn(_ k: String) -> String { m[k] as? Bool == true ? "是" : (m[k] is NSNull || m[k] == nil ? "?" : "否") }
        log("\(s.ip) 设备：\(m["dev"] ?? "?")，HTTPS \(yn("secure"))，WebCodecs \(yn("webcodecs"))，"
            + "证书可用 \(yn("https"))\(m["httpsWhy"].map { "（\($0)）" } ?? "")，主屏幕 App \(yn("standalone"))，像素比 \(m["dpr"] ?? "?")，\(m["ua"] ?? "")，\(m["geo"] ?? "")")
        return
    }
    if m["t"] as? String == "screen" {
        let fitter = FitDisplay.shared, me = ObjectIdentifier(s)
        if m["on"] as? Bool == true {
            Waker.poke(ip: s.ip, reply: { s.send($0) })    // 屏幕睡着时看到的是黑屏，先点亮
            ScreenStreamer.shared.subscribe(s, width: Int(num(m["w"])), fps: Int(num(m["fps"])),
                                            ack: m["ack"] as? Bool == true, video: m["codec"] as? String == "h264")
            if let f = m["fit"] as? [String: Any], num(f["w"]) > 0, num(f["h"]) > 0 {
                // 让 Mac 改用这台设备的屏幕比例（铺满不留黑边）
                fitter.request(me, w: Int(num(f["w"])), h: Int(num(f["h"])))
            } else {
                fitter.release(me, after: 0.5)
            }
        } else {
            ScreenStreamer.shared.unsubscribe(s)
            fitter.release(me)
        }
        return
    }
    if m["t"] as? String == "unlock" {
        AutoUnlock.unlock(ip: s.ip, auto: m["auto"] as? Bool == true, reply: { [weak s] in s?.send($0) })
        return
    }
    handleRemote(m, ip: s.ip, reply: { s.send($0) })
    if m["t"] as? String == "axAt" {
        let b = CGDisplayBounds(ScreenStreamer.shared.displayID)
        let p = CGPoint(x: b.minX + num(m["x"]) * b.width, y: b.minY + num(m["y"]) * b.height)
        if let item = DockHit.item(at: p) {
            s.send(["t": "axAt", "dock": true, "title": DockHit.attr(item, kAXTitleAttribute) ?? "", "x": p.x, "y": p.y])
        } else {
            s.send(["t": "axAt", "dock": false, "x": p.x, "y": p.y])
        }
        return
    }
    if m["t"] as? String == "hitAt" {
        let b = CGDisplayBounds(ScreenStreamer.shared.displayID)
        let p = CGPoint(x: b.minX + num(m["x"]) * b.width, y: b.minY + num(m["y"]) * b.height)
        TextFocus.probe(p) { editable, info in
            s.send(["t": "hitAt", "editable": editable.map { $0 ? 1 : 0 } ?? -1, "info": info, "x": p.x, "y": p.y])
        }
        return
    }
    if m["t"] as? String == "focusCheck" {
        let id = m["id"] ?? 0
        TextFocus.checkFocus { editable, role in s.send(["t": "textFocus", "id": id, "editable": editable, "role": role]) }
        return
    }
    // Apple Pencil 轻点：看看点到的是不是输入框，是就让 iPad 弹出手写板
    if m["t"] as? String == "pen", Int(num(m["p"])) == 2, m["tap"] as? Bool == true {
        let id = m["id"] ?? 0, ip = s.ip
        let b = CGDisplayBounds(ScreenStreamer.shared.displayID)
        let p = CGPoint(x: b.minX + num(m["x"]) * b.width, y: b.minY + num(m["y"]) * b.height)
        TextFocus.check(at: p) { editable, info in
            log("\(ip) Pencil 点击：\(info)，\(editable ? "弹出手写板" : "不弹手写板")")
            s.send(["t": "textFocus", "id": id, "editable": editable, "role": info])
        }
    }
}

/// 点亮屏幕：发出去的模拟鼠标键盘不一定能唤醒睡着的显示器，要明确告诉系统「有人在用」（等于碰了一下真鼠标）
enum Waker {
    static let lock = NSLock()
    static var last = Date.distantPast, lastHint = Date.distantPast
    static var assertion: IOPMAssertionID = 0
    static let inputTypes: Set<String> = ["move", "click", "down", "up", "scroll", "key", "text", "cmd",
                                          "moveTo", "clickAt", "pen", "mission"]

    static func poke(ip: String, reply: ([String: Any]) -> Void) {
        let asleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
        lock.lock()
        let now = Date()
        // 每秒最多报一次：锁屏界面要先看到「有人在用」才会检查密码，不然输对了也会显示密码错误
        guard asleep || now.timeIntervalSince(last) > 1 else { lock.unlock(); return }
        last = now
        IOPMAssertionDeclareUserActivity("PC 遥控：手机在操作" as CFString, kIOPMUserActiveLocal, &assertion)
        var hint = false
        if asleep && now.timeIntervalSince(lastHint) > 20 { lastHint = now; hint = true }
        lock.unlock()
        guard asleep else { return }
        let locked = screenLocked()
        log("\(ip) 屏幕在睡眠，已唤醒\(locked ? "（锁屏中）" : "")")
        if hint && locked {
            reply(["t": "locked", "unlock": AutoUnlock.available])   // 网页决定：自动解锁，或提示怎么解锁
        }
    }

    static func screenLocked() -> Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return d["CGSSessionScreenIsLocked"] as? Bool == true
    }
}

/// 自动解锁：开机密码存在 Mac 的钥匙串里（不经过网络、不存在手机上）。手机请求解锁时，Mac 自己在锁屏界面输入密码
enum AutoUnlock {
    static let service = "WatchBridge.autounlock"
    private static let lock = NSLock()
    private static var cached: String??          // nil = 还没读过钥匙串
    private static var busy = false, failures = 0, lastTry = Date.distantPast

    static var available: Bool { password() != nil }

    static func password() -> String? {
        lock.lock(); defer { lock.unlock() }
        if let c = cached { return c }
        var out: CFTypeRef?
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: NSUserName(), kSecReturnData as String: true]
        let pw = SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess
            ? (out as? Data).flatMap { String(data: $0, encoding: .utf8) } : nil
        cached = .some(pw)
        return pw
    }

    static func save(_ pw: String?) -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: NSUserName()]
        SecItemDelete(base as CFDictionary)
        var ok = true
        if let pw = pw {
            var add = base
            add[kSecValueData as String] = Data(pw.utf8)
            add[kSecAttrLabel as String] = "Mac 遥控：自动解锁"
            ok = SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        lock.lock(); cached = .some(ok ? pw : nil); failures = 0; lock.unlock()
        return ok
    }

    /// 检查是不是当前用户的开机密码（存错了的话每次解锁都会输错）
    static func verify(_ pw: String) -> Bool {
        guard let node = try? ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeLocalNodes)),
              let rec = try? node.record(withRecordType: kODRecordTypeUsers, name: NSUserName(), attributes: nil)
        else { return false }
        return (try? rec.verifyPassword(pw)) != nil
    }

    static func unlock(ip: String, auto: Bool, reply: @escaping ([String: Any]) -> Void) {
        guard Waker.screenLocked() else {
            lock.lock(); failures = 0; lock.unlock()
            if !auto { reply(["t": "reply", "ok": true, "text": "Mac 没有锁屏"]) }
            return
        }
        guard let pw = password() else {
            reply(["t": "reply", "ok": false, "text": "还没设置自动解锁：在 Mac 菜单栏点「Mac 遥控」图标 →「自动解锁密码…」"])
            return
        }
        lock.lock()
        let now = Date()
        // 连续两次没解开就停下（防止反复输错被系统锁定），在 Mac 上手动解锁一次后恢复
        let refuse = busy ? "" : failures >= 2 ? "自动解锁连续失败两次，已暂停：请在 Mac 上解锁一次" :
            now.timeIntervalSince(lastTry) < 8 ? "" : nil
        if refuse == nil { busy = true; lastTry = now }
        lock.unlock()
        if let r = refuse { if !r.isEmpty { reply(["t": "reply", "ok": false, "text": r]) }; return }
        reply(["t": "reply", "ok": true, "text": "正在解锁 Mac……"])
        DispatchQueue.global().async {
            var id: IOPMAssertionID = 0
            IOPMAssertionDeclareUserActivity("PC 遥控：解锁" as CFString, kIOPMUserActiveLocal, &id)
            Thread.sleep(forTimeInterval: 1.2)       // 等屏幕亮起、密码框出现
            pressCombo("cmd+a"); postKey(51)        // 清掉密码框里可能已有的字
            typeByKeys(pw)
            postKey(36)
            var ok = false
            for _ in 0..<12 where !ok { Thread.sleep(forTimeInterval: 0.5); ok = !Waker.screenLocked() }
            lock.lock(); busy = false; failures = ok ? 0 : failures + 1; lock.unlock()
            log("\(ip) 自动解锁\(ok ? "成功" : "没成功")")
            reply(ok ? ["t": "reply", "ok": true, "text": "Mac 已解锁"]
                     : ["t": "reply", "ok": false, "text": "没能解锁：锁屏界面可能要先选用户。可以用键盘自己输入密码"])
        }
    }
}

func handleRemote(_ m: [String: Any], ip: String, reply: ([String: Any]) -> Void) {
    let t = m["t"] as? String ?? ""
    if Waker.inputTypes.contains(t) { Waker.poke(ip: ip, reply: reply) }
    switch t {
    case "move":
        moveMouse(dx: num(m["dx"]), dy: num(m["dy"]))
    case "click":
        click(buttonFrom(m["b"]))
    case "down":
        mouseButton(buttonFrom(m["b"]), down: true)
    case "up":
        mouseButton(buttonFrom(m["b"]), down: false)
    case "scroll":
        postScroll(dx: num(m["dx"]), dy: num(m["dy"]), phase: Int64(num(m["p"])), momentum: Int64(num(m["m"])))
    case "key":
        let k = m["key"] as? String ?? ""
        if !pressCombo(k) { reply(["t": "reply", "ok": false, "text": "不认识这个按键：\(k)"]) }
    case "text":
        let text = m["text"] as? String ?? ""
        guard !text.isEmpty else { return }
        if Waker.screenLocked() {
            typeByKeys(text)       // 锁屏输密码：只认真按键；密码不写日志
            log("\(ip) 锁屏界面输入了 \(text.count) 个字")
            return
        }
        if m["paste"] as? Bool == true { pasteText(text) } else { typeText(text) }
        log("\(ip) 输入：\(text)")
    case "cmd":
        let text = m["text"] as? String ?? ""
        let (ok, answer) = runCommand(text)
        log("\(ip) 指令：\(text) -> \(answer)")
        if m["quiet"] as? Bool != true || !ok { reply(["t": "reply", "ok": ok, "text": answer]) }
    case "moveTo":
        // 触摸屏模式：把光标移到手指下面（之后的滚动就落在那块内容上）
        let b = CGDisplayBounds(ScreenStreamer.shared.displayID)
        moveMouseTo(CGPoint(x: b.minX + num(m["x"]) * b.width, y: b.minY + num(m["y"]) * b.height))
    case "clickAt":
        // 屏幕镜像里点哪点哪：x、y 是画面里的相对位置（0~1）
        let b = CGDisplayBounds(ScreenStreamer.shared.displayID)
        let p = CGPoint(x: b.minX + num(m["x"]) * b.width, y: b.minY + num(m["y"]) * b.height)
        let btn = buttonFrom(m["b"])
        // 点到程序坞图标：直接「按」那个图标。光标一到程序坞就会放大 / 弹出，图标在动，光标去点容易点到旁边那个；
        // 这里在光标移过去之前就认好是哪个图标（和手机上看到的一样）
        if btn != .center, let item = DockHit.item(at: p) {
            DockHit.press(item, menu: btn == .right)
            moveMouseTo(p)
            return
        }
        // 程序坞自动隐藏时，手指很难点中屏幕最边上那一两个像素：点最边上一窄条 = 把光标移到边上叫出程序坞（不点下去）
        if btn == .left, let edge = DockHit.revealPoint(for: p, in: b) {
            moveMouseTo(edge)
            log("叫出程序坞")
            return
        }
        moveMouseTo(p)
        usleep(15_000)
        click(btn)
    case "pen":
        // Apple Pencil：x、y 是 Mac 屏幕上的相对位置（0~1）；p = 0 落笔 / 1 移动 / 2 抬笔
        let b = CGDisplayBounds(ScreenStreamer.shared.displayID)
        let p = CGPoint(x: b.minX + num(m["x"]) * b.width, y: b.minY + num(m["y"]) * b.height)
        switch Int(num(m["p"])) {
        case 0:
            TextFocus.prepare(at: p)
            releaseHeldButton()
            if let item = DockHit.item(at: p) {      // 笔点在程序坞图标上：抬笔时直接按它（同上）
                penDock = (item, p)
                moveMouseTo(p)
                return
            }
            penDock = nil
            moveMouseTo(p)
            usleep(8_000)
            mouseButton(.left, down: true)
        case 1:
            moveMouseTo(p)
        default:
            moveMouseTo(p)
            if let (item, at) = penDock {
                penDock = nil
                if hypot(p.x - at.x, p.y - at.y) < 20 { DockHit.press(item, menu: false) }
            } else {
                mouseButton(.left, down: false)
            }
        }
    case "mission":
        _ = openApp("Mission Control")
    case "ping":
        reply(["t": "pong", "id": m["id"] ?? 0])
    default:
        break
    }
}

/// 所有输入事件都在主线程串行执行，避免多个请求交错打字
func handle(_ req: Request, _ conn: NWConnection) {
    let ip: String = {
        if case let .hostPort(host, _) = conn.endpoint { return "\(host)" }
        return "?"
    }()
    if req.path == "/ping" { respond(conn, 200, "pong"); return }
    if req.path.hasPrefix("/favicon") || req.path.hasPrefix("/apple-touch-icon") { respond(conn, 404, ""); return }
    if req.path == "/ca.cer" {
        // 本机根证书（公开信息，不需要 token）。iPhone 用 Safari 打开会提示安装描述文件
        if let der = caCertDER() {
            respond(conn, 200, der, type: "application/x-x509-ca-cert")
        } else {
            respond(conn, 404, "证书还没生成")
        }
        return
    }
    if req.path == "/" || req.path == "/remote" {
        // 网页本身不含机密，不需要 token；token 由网页连接 /ws 时校验
        if let page = webFile("remote.html") {
            respond(conn, 200, page, type: "text/html; charset=utf-8")
        } else {
            respond(conn, 404, "找不到 web/remote.html，请重新运行 ./build-app.sh")
        }
        return
    }
    if req.path == "/ws" {
        guard req.headers["upgrade"]?.lowercased() == "websocket", let key = req.headers["sec-websocket-key"] else {
            respond(conn, 400, "需要 WebSocket"); return
        }
        WebSocketSession(conn: conn, ip: ip).start(key: key, authorized: authorized(req), leftover: req.extra)
        return
    }
    guard authorized(req) else {
        log("拒绝 \(ip) \(req.path)：token 不对")
        respond(conn, 401, "token 不对")
        return
    }
    DispatchQueue.main.async {
        switch req.path {
        case "/type":
            let text = bodyValue(req, keys: ["text"])
            guard !text.isEmpty else { respond(conn, 400, "没有文字"); return }
            typeText(text)
            log("\(ip) 输入：\(text)")
            respond(conn, 200, "已输入")
        case "/key":
            let key = clean(bodyValue(req, keys: ["key", "text"]))
            if pressCombo(key) {
                log("\(ip) 按键：\(key)")
                respond(conn, 200, "已按 \(key)")
            } else {
                respond(conn, 422, "不认识这个按键：\(key)")
            }
        case "/batch":
            // Apple Watch 用：watchOS 不允许 App 用 WebSocket，只能发 HTTP，所以一次带多条遥控消息，连接保持复用
            let obj = try? JSONSerialization.jsonObject(with: req.body)
            let events = (obj as? [[String: Any]]) ?? ((obj as? [String: Any])?["events"] as? [[String: Any]]) ?? []
            var replies: [[String: Any]] = []
            noteBatch(from: ip)
            for e in events { handleRemote(e, ip: ip, reply: { replies.append($0) }) }
            let body = (try? JSONSerialization.data(withJSONObject: ["ok": true, "replies": replies])) ?? Data()
            respondKeepAlive(conn, body, leftover: req.extra)
        case "/command":
            let text = bodyValue(req, keys: ["text", "command"])
            let (ok, reply) = runCommand(text)
            log("\(ip) 指令：\(text) -> \(reply)")
            respond(conn, ok ? 200 : 422, reply)
        default:
            respond(conn, 404, "没有这个接口")
        }
    }
}

/// 回复后不断开，继续读同一连接上的下一个请求（手表每秒发十几次，省掉反复建连接）
func respondKeepAlive(_ conn: NWConnection, _ body: Data, leftover: Data) {
    var head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nCache-Control: no-store\r\n"
    head += "Content-Length: \(body.count)\r\nConnection: keep-alive\r\n\r\n"
    conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { error in
        if error != nil { conn.cancel(); return }
        receive(conn, leftover)
    })
}

/// 手表断线时可能来不及发「松开鼠标键」，超过 3 秒没消息就自动松开
var lastBatchAt: [String: TimeInterval] = [:]
func noteBatch(from ip: String) {
    let now = ProcessInfo.processInfo.systemUptime
    if now - (lastBatchAt[ip] ?? 0) > 30 { log("手表已连接：\(ip)") }
    lastBatchAt[ip] = now
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
        if ProcessInfo.processInfo.systemUptime - (lastBatchAt[ip] ?? 0) >= 2.9 { releaseHeldButton() }
    }
}

func receive(_ conn: NWConnection, _ buffer: Data) {
    if !buffer.isEmpty, let (req0, bodyStart) = parseHead(buffer),
       buffer.count - bodyStart >= (Int(req0.headers["content-length"] ?? "0") ?? 0) {
        let len = Int(req0.headers["content-length"] ?? "0") ?? 0
        var req = req0
        req.body = buffer.subdata(in: bodyStart..<(bodyStart + len))
        req.extra = buffer.subdata(in: (bodyStart + len)..<buffer.count)
        handle(req, conn)
        return
    }
    conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
        var buf = buffer
        if let data = data { buf.append(data) }
        if buf.count > 1_000_000 { respond(conn, 400, "请求太大"); return }
        if let (req0, bodyStart) = parseHead(buf) {
            let len = Int(req0.headers["content-length"] ?? "0") ?? 0
            if buf.count - bodyStart >= len {
                var req = req0
                req.body = buf.subdata(in: bodyStart..<(bodyStart + len))
                req.extra = buf.subdata(in: (bodyStart + len)..<buf.count)
                handle(req, conn)
                return
            }
        }
        if done || error != nil { conn.cancel(); return }
        receive(conn, buf)
    }
}

func log(_ s: String) {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    print("[\(f.string(from: Date()))] \(s)")
    fflush(stdout)
}

func localIPs() -> [String] {
    var result: [String] = []
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
    defer { freeifaddrs(ifaddr) }
    for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let a = p.pointee
        guard let sa = a.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
        let name = String(cString: a.ifa_name)
        guard name.hasPrefix("en") else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        result.append("\(String(cString: host)) (\(name))")
    }
    return result
}


// MARK: - 让 Mac 适配 iPad 屏幕比例
// 建一个和 iPad 一样尺寸的虚拟显示器（2 倍高清），再让 Mac 屏幕镜像它——和 AirPlay 镜像时「为 Apple TV 优化」一个道理：
// 画面按 iPad 的比例和分辨率生成，iPad 上正好铺满、一像素对一像素；Mac 自己的屏幕这段时间左右会有黑边。
// 关掉 iPad 上的屏幕 / 断开 / App 退出都会恢复（配置只对本 App 生效，App 退出系统自动撤销，虚拟屏也随之消失）。
final class FitDisplay {
    static let shared = FitDisplay()
    private var virtual: CGVirtualDisplay?
    private var size: (w: Int, h: Int)?          // 当前适配的尺寸（点）
    private var mirroredMain: CGDirectDisplayID = 0
    private var revertWork: DispatchWorkItem?
    private var serial: UInt32 = 0
    private var busy = false                     // 正在建 / 改，期间来的请求先记下，做完再处理
    private var pendingSize: (w: Int, h: Int)?
    private static let maxPoints = 2560          // 最大支持 2560 点（5120 像素），转屏、换显示模式都不用重建
    /// 每台要求适配的设备想要的尺寸；最后一个说了算，它走了交给还在看的另一台
    private var requests: [ObjectIdentifier: (w: Int, h: Int, at: TimeInterval)] = [:]
    var owner: ObjectIdentifier? {
        requests.max { $0.value.at < $1.value.at }?.key
    }
    var active: Bool { virtual != nil }
    var sizeText: String { size.map { "\($0.w)×\($0.h)" } ?? "" }

    /// 主线程调用：这台设备要求 Mac 用 w×h（点）的屏幕
    func request(_ who: ObjectIdentifier, w rawW: Int, h rawH: Int) {
        revertWork?.cancel(); revertWork = nil
        // 太小的（比如手机）按比例放大到够用的桌面尺寸
        let k = max(1.0, 1100.0 / Double(max(rawW, 1)), 700.0 / Double(max(rawH, 1)))
        let w = min(Self.maxPoints, Int(Double(rawW) * k)) & ~1, h = min(Self.maxPoints, Int(Double(rawH) * k)) & ~1
        guard w >= 640, h >= 400 else { return }
        if requests[who] == nil || requests[who]!.w != w || requests[who]!.h != h {
            log("适配请求：\(w)×\(h) 点")
        }
        requests[who] = (w, h, ProcessInfo.processInfo.systemUptime)
        apply(w, h)
    }

    /// 主线程调用：这台设备不看了（关屏 / 断开）。等一会儿：还有别的设备要适配就交给它，没有就恢复
    func release(_ who: ObjectIdentifier, after sec: Double = 2) {
        guard requests.removeValue(forKey: who) != nil else { return }
        revertWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            if let next = self.requests.max(by: { $0.value.at < $1.value.at })?.value { self.apply(next.w, next.h) }
            else { self.revert() }
        }
        revertWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + sec, execute: w)
    }

    private func apply(_ w: Int, _ h: Int) {
        if busy { pendingSize = (w, h); return }
        if let s = size, abs(s.w - w) <= 4, abs(s.h - h) <= 4, virtual != nil { return }
        busy = true
        let finish: (Bool) -> Void = { [self] changed in
            busy = false
            if changed { ScreenStreamer.shared.restartCapture() }
            if let p = pendingSize { pendingSize = nil; apply(p.w, p.h) }
        }
        let settings = CGVirtualDisplaySettings(); settings.hiDPI = 1
        // 高清（2 倍像素）和普通两种模式都要给，系统才会提供「w×h 点、2w×2h 像素」的高清模式
        settings.modes = [CGVirtualDisplayMode(width: UInt(w * 2), height: UInt(h * 2), refreshRate: 60),
                          CGVirtualDisplayMode(width: UInt(w), height: UInt(h), refreshRate: 60)]

        // 已经在镜像了：只换模式（iPad 转屏等）
        if let v = virtual, mirroredMain != 0 {
            size = (w, h)
            _ = v.apply(settings)
            waitForMode(v.displayID, w, h) { [self] m in
                if let m = m { configure { CGConfigureDisplayWithDisplayMode($0, v.displayID, m, nil) } }
                log("Mac 屏幕改成 \(w)×\(h) 点（\(modeText(v.displayID))）")
                finish(true)
            }
            return
        }

        let d = CGVirtualDisplayDescriptor()
        d.setDispatchQueue(DispatchQueue.main)
        d.name = "Mac 遥控（iPad 镜像）"
        d.maxPixelsWide = UInt32(Self.maxPoints * 2); d.maxPixelsHigh = UInt32(Self.maxPoints * 2)
        d.sizeInMillimeters = CGSize(width: Double(w) / 132 * 25.4, height: Double(h) / 132 * 25.4)  // iPad 每英寸 132 点
        serial += 1
        d.vendorID = 0x4D52; d.productID = 0x4950; d.serialNum = serial
        d.terminationHandler = { _, _ in DispatchQueue.main.async { log("虚拟显示器被系统关掉了") } }
        guard let v = CGVirtualDisplay(descriptor: d), v.apply(settings) else {
            log("创建虚拟显示器失败")
            finish(false); return
        }
        virtual = v; size = (w, h)
        // 等它上线、高清模式出现，再在同一次配置里设好模式并让 Mac 屏幕镜像它
        waitForMode(v.displayID, w, h) { [self] m in
            guard virtual === v else { finish(false); return }
            let vid = v.displayID, main = CGMainDisplayID()
            guard main != vid else { finish(false); return }
            let err = configure { cfg in
                if let m = m { CGConfigureDisplayWithDisplayMode(cfg, vid, m, nil) }
                CGConfigureDisplayMirrorOfDisplay(cfg, main, vid)
            }
            guard err == .success else {
                log("镜像到虚拟显示器失败：\(err.rawValue)")
                teardown(); finish(false); return
            }
            mirroredMain = main
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                // 万一镜像后被换回了 1 倍模式，再设一次高清
                if let m = m, let cur = CGDisplayCopyDisplayMode(vid), cur.pixelWidth != m.pixelWidth {
                    configure { CGConfigureDisplayWithDisplayMode($0, vid, m, nil) }
                }
                log("Mac 屏幕已适配：\(w)×\(h) 点（\(modeText(vid))）")
                finish(true)
            }
        }
    }

    @discardableResult
    private func configure(_ body: (CGDisplayConfigRef?) -> Void) -> CGError {
        var cfg: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&cfg)
        body(cfg)
        return CGCompleteDisplayConfiguration(cfg, .forAppOnly)
    }

    private func modeText(_ id: CGDirectDisplayID) -> String {
        CGDisplayCopyDisplayMode(id).map { "\($0.pixelWidth)×\($0.pixelHeight) 像素" } ?? "?"
    }

    /// 等显示器上线并出现 w×h 点的高清模式（最多 2 秒；找不到高清就用同尺寸的普通模式）
    private func waitForMode(_ id: CGDirectDisplayID, _ w: Int, _ h: Int, tries: Int = 20, _ done: @escaping (CGDisplayMode?) -> Void) {
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        let modes = (CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode]) ?? []
        if let m = modes.first(where: { $0.width == w && $0.height == h && $0.pixelWidth == w * 2 }) { done(m); return }
        if tries <= 0 { done(modes.first { $0.width == w && $0.height == h }); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.waitForMode(id, w, h, tries: tries - 1, done) }
    }

    /// 主线程调用：恢复 Mac 原来的屏幕
    func revert() {
        revertWork?.cancel(); revertWork = nil
        requests.removeAll()
        pendingSize = nil
        guard virtual != nil else { return }
        teardown()
        log("Mac 屏幕已恢复原样")
        ScreenStreamer.shared.restartCapture()
    }

    private func teardown() {
        guard let v = virtual else { return }
        if mirroredMain != 0 { configure { CGConfigureDisplayMirrorOfDisplay($0, mirroredMain, kCGNullDirectDisplay) } }
        mirroredMain = 0
        virtual = nil; size = nil
        // 先撤销镜像，稍等再删虚拟屏
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { withExtendedLifetime(v) {} }
    }
}

// MARK: - Pencil 点到输入框：用辅助功能看笔尖下面是不是输入框、输入焦点是不是在输入框里

enum TextFocus {
    private static let queue = DispatchQueue(label: "textfocus")
    private static var enabledPids = Set<pid_t>()

    /// 落笔时：让笔下面那个 App 打开辅助功能树（Chrome、Electron 默认不开，网页里的输入框就看不到）
    static func prepare(at p: CGPoint) {
        queue.async {
            let sys = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(sys, 0.3)
            var el: AXUIElement?
            guard AXUIElementCopyElementAtPosition(sys, Float(p.x), Float(p.y), &el) == .success, let el = el else { return }
            var pid: pid_t = 0
            guard AXUIElementGetPid(el, &pid) == .success else { return }
            _ = enable(pid)
        }
    }

    /// 给这个 App 打开辅助功能树（只做一次）。返回是不是刚打开的
    private static func enable(_ pid: pid_t) -> Bool {
        guard pid > 0, pid != getpid(), !enabledPids.contains(pid) else { return false }
        enabledPids.insert(pid)
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        return AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success
    }

    /// 最前面的 App 也打开辅助功能树（第一次打开要等它建好）
    private static func enableFrontmost() {
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.3)
        var appRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(sys, kAXFocusedApplicationAttribute as CFString, &appRef) == .success,
           let a = appRef, CFGetTypeID(a) == AXUIElementGetTypeID() {
            var pid: pid_t = 0
            if AXUIElementGetPid(a as! AXUIElement, &pid) == .success, enable(pid) { Thread.sleep(forTimeInterval: 0.3) }
        }
    }

    private static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
    /// 点了就执行的东西：笔点到这些就不是在点输入框（哪怕它长在输入框里面，比如搜索框右边的 ✕）
    private static let pressRoles: Set<String> = ["AXButton", "AXLink", "AXMenuItem", "AXMenuBarItem", "AXMenuButton",
        "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXDisclosureTriangle", "AXTab", "AXSlider", "AXIncrementor",
        "AXColorWell", "AXDockItem", "AXSegmentedControl"]

    private static func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var r: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, name as CFString, &r) == .success ? r : nil
    }
    private static func role(_ e: AXUIElement) -> String { attr(e, kAXRoleAttribute) as? String ?? "?" }
    private static func isEditable(_ e: AXUIElement) -> Bool {
        if textRoles.contains(role(e)) { return true }
        if attr(e, "AXEditableAncestor") != nil { return true }      // 网页里的可编辑区域（contenteditable）
        var settable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(e, kAXValueAttribute as CFString, &settable)
        return settable.boolValue && attr(e, kAXSelectedTextRangeAttribute) != nil
    }

    /// 笔尖下面是不是输入框（往上找几层，比如点在输入框的占位文字上）。nil = 看不出来（App 的辅助功能树还没好）
    static func hit(_ p: CGPoint) -> (Bool?, String) {
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.4)
        var el: AXUIElement?
        guard AXUIElementCopyElementAtPosition(sys, Float(p.x), Float(p.y), &el) == .success, var e = el else { return (nil, "看不到") }
        AXUIElementSetMessagingTimeout(e, 0.4)
        var chain = role(e)
        if pressRoles.contains(chain) { return (false, chain) }
        for _ in 0..<4 {
            if isEditable(e) { return (true, chain) }
            guard let up = attr(e, kAXParentAttribute), CFGetTypeID(up) == AXUIElementGetTypeID() else { break }
            e = up as! AXUIElement
            let r = role(e)
            chain += "→" + r
            if pressRoles.contains(r) { return (false, chain) }
        }
        return (false, chain)
    }

    /// 现在的输入焦点是不是输入框。nil = 查不到
    private static func focus() -> (Bool?, String) {
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.5)
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &v) == .success, let v = v,
              CFGetTypeID(v) == AXUIElementGetTypeID() else { return (nil, "查不到") }
        let el = v as! AXUIElement
        AXUIElementSetMessagingTimeout(el, 0.5)
        let r = role(el), sub = attr(el, kAXSubroleAttribute) as? String ?? ""
        return (isEditable(el), sub.isEmpty ? r : "\(r)/\(sub)")
    }

    /// Pencil 点完之后：笔尖下面是输入框、并且输入焦点也在输入框里，才算点到了输入框。
    /// 只看焦点不行——很多 App 点按钮时焦点还留在旁边的输入框里
    static func check(at p: CGPoint, _ done: @escaping (_ editable: Bool, _ info: String) -> Void) {
        queue.asyncAfter(deadline: .now() + 0.15) {
            enableFrontmost()
            var h = hit(p), f = focus()
            // App 还没准备好，或者焦点还没切过去：等一下再看一次
            if h.0 == nil || (h.0 == true && f.0 == false) { Thread.sleep(forTimeInterval: 0.3); h = hit(p); f = focus() }
            done(h.0 == true && f.0 != false, "点到 \(h.1)，焦点 \(f.1)")
        }
    }

    /// 只查焦点（排查用）
    static func checkFocus(_ done: @escaping (_ editable: Bool, _ info: String) -> Void) {
        queue.asyncAfter(deadline: .now() + 0.15) {
            enableFrontmost()
            let f = focus()
            done(f.0 == true, "焦点 \(f.1)")
        }
    }

    /// 只看某个位置是什么（排查用，不点）
    static func probe(_ p: CGPoint, _ done: @escaping (_ editable: Bool?, _ info: String) -> Void) {
        queue.async { let h = hit(p); done(h.0, h.1) }
    }
}

// MARK: - 屏幕镜像（ScreenCaptureKit 截屏 → H.264 视频 或 JPEG 图片 → WebSocket 二进制帧）

/// H.264 硬件编码（VideoToolbox，低延迟模式，不用 B 帧）。输出 AVCC 格式，配合网页里的 WebCodecs 解码。
final class H264Encoder {
    let width: Int, height: Int
    private var session: VTCompressionSession?
    private var lastAvcC: Data?
    /// (类型, 数据)：1 = 解码配置（宽、高各 2 字节 + avcC），2 = 关键帧，3 = 普通帧
    var onOutput: ((UInt8, Data) -> Void)?

    init?(width: Int, height: Int, fps: Int) {
        self.width = width; self.height = height
        var s: VTCompressionSession?
        let lowLatency = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary
        var err = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                             codecType: kCMVideoCodecType_H264, encoderSpecification: lowLatency,
                                             imageBufferAttributes: nil, compressedDataAllocator: nil,
                                             outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        if err != noErr {
            err = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                             codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
                                             imageBufferAttributes: nil, compressedDataAllocator: nil,
                                             outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        }
        guard err == noErr, let session = s else { log("H.264 编码器创建失败：\(err)"); return nil }
        self.session = session
        // 码率按像素和帧率算：屏幕内容大多是静止的文字，0.12 bit/像素 已经很清楚
        let bitrate = Int(min(25_000_000, max(2_000_000, Double(width * height * fps) * 0.12)))
        let props: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_High_AutoLevel,
            kVTCompressionPropertyKey_AverageBitRate: bitrate,
            kVTCompressionPropertyKey_ExpectedFrameRate: fps,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 10,
            kVTCompressionPropertyKey_ColorPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kVTCompressionPropertyKey_TransferFunction: kCVImageBufferTransferFunction_ITU_R_709_2,
            kVTCompressionPropertyKey_YCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        ]
        for (k, v) in props { VTSessionSetProperty(session, key: k, value: v as CFTypeRef) }
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    func encode(_ pb: CVPixelBuffer, pts: CMTime, forceKey: Bool = false) {
        guard let session = session else { return }
        let opts = forceKey ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        VTCompressionSessionEncodeFrame(session, imageBuffer: pb, presentationTimeStamp: pts, duration: .invalid,
                                        frameProperties: opts, infoFlagsOut: nil) { [weak self] status, _, sb in
            guard status == noErr, let sb = sb, let self = self, let bb = sb.dataBuffer else { return }
            var key = true
            if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]],
               arr.first?[kCMSampleAttachmentKey_NotSync] as? Bool == true { key = false }
            if key, let fd = sb.formatDescription,
               let atoms = CMFormatDescriptionGetExtension(fd, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any],
               let avcC = atoms["avcC"] as? Data, avcC != self.lastAvcC {
                if self.lastAvcC == nil, avcC.count > 3 {
                    log("H.264 编码：\(self.width)×\(self.height)，avc1.\(avcC[1...3].map { String(format: "%02x", $0) }.joined())")
                }
                self.lastAvcC = avcC
                let dims = Data([UInt8(self.width >> 8), UInt8(self.width & 0xFF), UInt8(self.height >> 8), UInt8(self.height & 0xFF)])
                self.onOutput?(1, dims + avcC)
            }
            var out = Data(count: CMBlockBufferGetDataLength(bb))
            let ok = out.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            if ok == kCMBlockBufferNoErr { self.onOutput?(key ? 2 : 3, out) }
        }
    }

    func invalidate() {
        onOutput = nil
        if let s = session { VTCompressionSessionInvalidate(s) }
        session = nil
    }
    deinit { invalidate() }
}

/// 只在有手机打开「屏幕」时才截屏。画面没变化时系统不出新帧，不耗流量。
/// 手机每显示完一帧回一个 screenAck，Mac 按回执控制发送节奏，网络慢时自动降帧，不会越积越卡。
final class ScreenStreamer: NSObject, SCStreamOutput, SCStreamDelegate {
    static let shared = ScreenStreamer()
    private let queue = DispatchQueue(label: "screen.capture")
    private let ciContext = CIContext()
    private var stream: SCStream?
    private var currentDisplay: SCDisplay?
    private var starting = false
    /// 每台看屏幕的手机
    final class Sub {
        let session: WebSocketSession
        var width: Int
        var ack: Bool          // 手机会回执：显示完一帧才算送达
        var video: Bool        // true = H.264 视频；false = JPEG 图片
        var busy = false       // （图片，老网页没有回执时）这一帧还在往网络里写
        var sentAt: TimeInterval = 0
        var lastSeq = 0        // 已经发给它的最新画面编号
        var inflight = 0       // 已发出（视频：已编码）、还没收到回执的帧数
        var encoder: H264Encoder?
        var forceKey = true
        init(_ s: WebSocketSession, width: Int, ack: Bool, video: Bool) {
            session = s; self.width = width; self.ack = ack; self.video = video
        }
    }
    private var subs: [ObjectIdentifier: Sub] = [:]
    private var seq = 0
    private var lastJPEG: Data?
    private var lastJPEGSeq = 0
    private var lastPB: CVPixelBuffer?       // 最新一帧原始画面（视频补帧用）
    private var refreshLeft = 0
    private var idleWork: DispatchWorkItem?
    private var fps = 12
    private var captureWidth = 0
    private(set) var displayID: CGDirectDisplayID = CGMainDisplayID()
    private let maxInflight = 2

    var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    func subscribe(_ s: WebSocketSession, width: Int, fps: Int, ack: Bool = false, video: Bool = false) {
        queue.async {
            guard CGPreflightScreenCaptureAccess() else {
                DispatchQueue.main.async { _ = CGRequestScreenCaptureAccess() }  // 弹系统授权，并把 App 加进列表
                s.send(["t": "screen", "ok": false,
                        "text": "需要「屏幕录制」权限：系统设置 → 隐私与安全性 → 屏幕与系统录音，打开「Mac 遥控」，再从菜单栏退出并重开 App"])
                return
            }
            let w = max(320, min(width, video ? 2880 : 1800))   // 视频模式 iPad 大屏可以更清楚（12.9 寸原生 2732）
            let sub: Sub
            if let old = self.subs[ObjectIdentifier(s)] {
                sub = old
                sub.width = w; sub.ack = ack; sub.video = video
                sub.lastSeq = 0; sub.inflight = 0
            } else {
                sub = Sub(s, width: w, ack: ack, video: video)
                self.subs[ObjectIdentifier(s)] = sub
            }
            // 重新订阅 = 手机端解码器是新的，编码器也重建，从关键帧开始
            sub.encoder?.invalidate(); sub.encoder = nil; sub.forceKey = true
            let newFps = fps > 0 ? max(2, min(fps, 60)) : self.fps
            if newFps != self.fps {
                self.fps = newFps
                if let st = self.stream, let d = self.currentDisplay { st.updateConfiguration(self.makeConfig(display: d)) { _ in } }
            }
            s.send(["t": "screen", "ok": true, "codec": video ? "h264" : "jpeg"])
            if let d = self.currentDisplay { s.send(["t": "screenInfo", "w": d.width, "h": d.height]) }
            self.push(sub)
            self.reconfigure()
        }
    }

    /// 显示器配置变了（适配 / 恢复 iPad 比例）：停掉旧的截屏，按新的主显示器重新开始
    func restartCapture() {
        queue.async {
            guard !self.subs.isEmpty else { return }
            self.stream?.stopCapture { _ in }
            self.stream = nil
            self.currentDisplay = nil
            self.lastPB = nil
            self.queue.asyncAfter(deadline: .now() + 0.3) { self.reconfigure() }
        }
    }

    /// 手机要一个关键帧（它清空了解码器，或者丢了配置）
    func requestKey(_ s: WebSocketSession) {
        queue.async {
            guard let sub = self.subs[ObjectIdentifier(s)], sub.video else { return }
            sub.forceKey = true
            if let pb = self.lastPB, sub.inflight < self.maxInflight { self.encode(pb, for: sub) }
        }
    }

    /// 手机收到一帧后发来的回执
    func acked(_ s: WebSocketSession) {
        queue.async {
            guard let sub = self.subs[ObjectIdentifier(s)] else { return }
            sub.inflight = max(0, sub.inflight - 1)
            sub.sentAt = ProcessInfo.processInfo.systemUptime
            self.push(sub)   // 等回执期间有了新画面，就马上补发最新的
        }
    }

    func unsubscribe(_ s: WebSocketSession) {
        queue.async {
            guard let sub = self.subs.removeValue(forKey: ObjectIdentifier(s)) else { return }
            sub.encoder?.invalidate(); sub.encoder = nil
            if self.subs.isEmpty { self.stop() } else { self.reconfigure() }
        }
    }

    /// 画面宽度按最大的那台手机来（图片最多 1800、视频最多 2880 像素）
    private func wantedWidth() -> Int { subs.values.map { $0.width }.max() ?? 1280 }

    private func makeConfig(display: SCDisplay) -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        let w = min(wantedWidth(), display.width * 2) & ~1          // H.264 要偶数宽高
        c.width = w
        c.height = Int((Double(w) * Double(display.height) / Double(display.width)).rounded()) & ~1
        c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        c.showsCursor = true
        c.pixelFormat = kCVPixelFormatType_32BGRA
        c.colorSpaceName = CGColorSpace.sRGB
        c.queueDepth = 6
        captureWidth = w
        return c
    }

    /// 在 queue 上调用
    private func reconfigure() {
        if let st = stream, let d = currentDisplay {
            if wantedWidth() & ~1 != captureWidth { st.updateConfiguration(makeConfig(display: d)) { _ in } }
            return
        }
        guard !starting else { return }
        starting = true
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
            self.queue.async {
                self.starting = false
                guard !self.subs.isEmpty else { return }
                guard let content = content,
                      let d = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
                    self.broadcast(["t": "screen", "ok": false, "text": "截屏失败：\(error?.localizedDescription ?? "没有找到屏幕")"])
                    return
                }
                self.displayID = d.displayID
                self.currentDisplay = d
                let st = SCStream(filter: SCContentFilter(display: d, excludingWindows: []),
                                  configuration: self.makeConfig(display: d), delegate: self)
                do {
                    try st.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                } catch {
                    self.currentDisplay = nil
                    self.broadcast(["t": "screen", "ok": false, "text": "截屏失败：\(error.localizedDescription)"])
                    return
                }
                self.stream = st
                st.startCapture { err in
                    if let err = err {
                        log("屏幕镜像启动失败：\(err)")
                        self.queue.async { self.stream = nil; self.currentDisplay = nil }
                        self.broadcast(["t": "screen", "ok": false, "text": "截屏失败：\(err.localizedDescription)"])
                    } else {
                        self.broadcast(["t": "screenInfo", "w": d.width, "h": d.height])
                        let kinds = Set(self.subs.values.map { $0.video ? "视频" : "图片" }).sorted().joined(separator: "+")
                        log("屏幕镜像已开始（\(self.captureWidth) 像素宽，最多 \(self.fps) 帧/秒，\(kinds)）")
                    }
                }
            }
        }
    }

    private func stop() {
        stream?.stopCapture { _ in }
        stream = nil
        currentDisplay = nil
        lastJPEG = nil
        lastPB = nil
        idleWork?.cancel(); idleWork = nil
        seq = 0
        log("屏幕镜像已停止")
    }

    private func broadcast(_ obj: [String: Any]) {
        for sub in subs.values { sub.session.send(obj) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async {
            self.stream = nil
            self.currentDisplay = nil
            log("屏幕镜像中断：\(error.localizedDescription)")
            if !self.subs.isEmpty { self.reconfigure() }   // 比如换了显示器分辨率，自动重来
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pb = sb.imageBuffer else { return }
        // 只处理完整的新画面；画面静止时系统发的 idle 帧没有新内容
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = arr.first?[.status] as? Int, let st = SCFrameStatus(rawValue: raw), st != .complete { return }
        let now = ProcessInfo.processInfo.systemUptime
        for sub in subs.values where now - sub.sentAt > 1.0 {     // 回执丢了也别卡死
            if sub.inflight > 0 { sub.inflight = 0 }
        }
        lastPB = pb
        seq += 1
        // 画面静止后再补两帧同样的画面：视频编码会借机把画质补清楚，也把解码器里的最后一帧顶出来
        refreshLeft = 2
        scheduleRefresh()
        for sub in subs.values { push(sub) }
    }

    private func scheduleRefresh() {
        idleWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self = self, self.refreshLeft > 0, let pb = self.lastPB else { return }
            self.refreshLeft -= 1
            for sub in self.subs.values where sub.video && sub.inflight < self.maxInflight {
                self.encode(pb, for: sub)
            }
            if self.refreshLeft > 0 { self.scheduleRefresh() }
        }
        idleWork = w
        queue.asyncAfter(deadline: .now() + 0.25, execute: w)
    }

    /// 在 queue 上调用：这台手机准备好了、并且还没收到最新画面，就发给它
    private func push(_ sub: Sub) {
        guard subs[ObjectIdentifier(sub.session)] === sub, let pb = lastPB, sub.lastSeq < seq else { return }
        if sub.video {
            guard sub.inflight < maxInflight else { return }
            sub.lastSeq = seq
            encode(pb, for: sub)
        } else {
            if sub.ack { guard sub.inflight < maxInflight else { return } } else { guard !sub.busy else { return } }
            guard let jpeg = jpegForLatest() else { return }
            sub.busy = true
            sub.lastSeq = seq
            if sub.ack { sub.inflight += 1; sub.sentAt = ProcessInfo.processInfo.systemUptime }
            sub.session.sendBinary(jpeg) { [weak self] in
                self?.queue.async {
                    sub.busy = false
                    if !sub.ack { self?.push(sub) }
                }
            }
        }
    }

    /// JPEG 只在有手机用图片模式、并且真要发的时候才压
    private func jpegForLatest() -> Data? {
        if lastJPEGSeq == seq, let j = lastJPEG { return j }
        guard let pb = lastPB else { return nil }
        let img = CIImage(cvPixelBuffer: pb)
        let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        let q: Double = fps > 30 ? 0.4 : 0.55   // 帧率高时稍微降一点画质，控制流量
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let jpeg = ciContext.jpegRepresentation(of: img, colorSpace: space, options: [quality: q]) else { return nil }
        lastJPEG = jpeg; lastJPEGSeq = seq
        return jpeg
    }

    private func encode(_ pb: CVPixelBuffer, for sub: Sub) {
        // 每台设备按它自己要的宽度编码（编码器会自动缩放），不跟着别的设备、也不受截屏尺寸切换的影响
        let pw = CVPixelBufferGetWidth(pb), ph = CVPixelBufferGetHeight(pb)
        let w = min(sub.width, pw) & ~1
        let h = Int((Double(w) * Double(ph) / Double(pw)).rounded()) & ~1
        if sub.encoder == nil || sub.encoder!.width != w || sub.encoder!.height != h {
            sub.encoder?.invalidate()
            guard let enc = H264Encoder(width: w, height: h, fps: fps) else { return }
            let s = sub.session
            enc.onOutput = { kind, data in s.sendBinary(Data([kind]) + data) {} }
            sub.encoder = enc
            sub.forceKey = true
        }
        sub.inflight += 1
        sub.sentAt = ProcessInfo.processInfo.systemUptime
        sub.encoder!.encode(pb, pts: CMClockGetTime(CMClockGetHostTimeClock()), forceKey: sub.forceKey)
        sub.forceKey = false
    }
}

// MARK: - 启动（菜单栏 App）

let isAppBundle = Bundle.main.bundlePath.hasSuffix(".app")
let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/watchbridge.log")
if isAppBundle {
    // 从访达打开的 App 没有终端，输出写进日志文件
    try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    freopen(logURL.path, "a", stdout)
    freopen(logURL.path, "a", stderr)
}
setvbuf(stdout, nil, _IOLBF, 0)  // 按行刷新，日志才能及时写进去

func primaryIP() -> String? {
    let ips = localIPs()
    let pick = ips.first(where: { $0.hasSuffix("(en0)") }) ?? ips.first
    return pick.map { String($0.split(separator: " ")[0]) }
}

func remoteURL() -> String {
    "http://\(primaryIP() ?? "127.0.0.1"):\(port)/remote?token=\(token)"
}

// MARK: 网页遥控服务

enum ServerState { case starting, ready, failed(String) }
var serverState = ServerState.starting

let params = NWParameters.tcp
params.allowLocalEndpointReuse = true
func startListener() {
    guard let nwPort = NWEndpoint.Port(rawValue: port), let listener = try? NWListener(using: params, on: nwPort) else {
        serverState = .failed("无法监听端口 \(port)")
        log("无法监听端口 \(port)")
        return
    }
    // 同时用 Bonjour 广播，方便排查
    listener.service = NWListener.Service(name: "WatchBridge", type: "_watchbridge._tcp")
    listener.newConnectionHandler = { conn in
        conn.start(queue: .global())
        receive(conn, Data())
    }
    listener.stateUpdateHandler = { state in
        switch state {
        case .ready:
            DispatchQueue.main.async { serverState = .ready }
            log("网页遥控已启动，端口 \(port)")
            log("iPhone 遥控器：\(remoteURL().replacingOccurrences(of: token, with: "<token>"))")
        case .failed(let e):
            let msg: String
            if case .posix(let code) = e, code == .EADDRINUSE {
                msg = "端口 \(port) 被别的程序占用"
            } else {
                msg = "监听失败：\(e)"
            }
            DispatchQueue.main.async { serverState = .failed(msg) }
            log(msg)
        default: break
        }
    }
    listener.start(queue: .global())
    httpListener = listener
}
var httpListener: NWListener?

// MARK: HTTPS（视频模式要用：浏览器只允许 https 网页用 WebCodecs 解码视频；屏幕常亮、网页语音识别也要 https）

let httpsPort: UInt16 = port &+ 1  // 默认 8766
var httpsReady = false
let tlsDir = configDir.appendingPathComponent("tls", isDirectory: true)
let p12Pass = "macremote"

@discardableResult
func runTool(_ path: String, _ args: [String], cwd: URL) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.currentDirectoryURL = cwd
    let errPipe = Pipe()
    p.standardOutput = FileHandle.nullDevice
    p.standardError = errPipe
    do { try p.run() } catch { log("运行 \(path) 失败：\(error)"); return false }
    let err = errPipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    if p.terminationStatus != 0 {
        log("openssl \(args.first ?? "") 失败：\(String(data: err, encoding: .utf8) ?? "")")
        return false
    }
    return true
}

/// 证书里要写上 iPhone 访问 Mac 时用的地址（IP 变了就重新签发服务器证书，根证书不变，iPhone 不用重新信任）
func certSANs() -> String {
    var names = localIPs().map { "IP:" + String($0.split(separator: " ")[0]) }
    names.append("IP:127.0.0.1")
    names.append("DNS:localhost")
    let host = ProcessInfo.processInfo.hostName
    if !host.isEmpty, host != "localhost" { names.append("DNS:" + (host.hasSuffix(".local") ? host : host + ".local")) }
    return names.joined(separator: ",")
}

func caCertDER() -> Data? {
    guard let pem = try? String(contentsOf: tlsDir.appendingPathComponent("ca.pem"), encoding: .utf8) else { return nil }
    let b64 = pem.components(separatedBy: "\n").filter { !$0.hasPrefix("-----") }.joined()
    return Data(base64Encoded: b64)
}

func ensureTLSIdentity() -> sec_identity_t? {
    let fm = FileManager.default
    let ssl = "/usr/bin/openssl"
    try? fm.createDirectory(at: tlsDir, withIntermediateDirectories: true)
    try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tlsDir.path)
    func f(_ n: String) -> URL { tlsDir.appendingPathComponent(n) }
    let sansFile = f("server.sans")

    if !fm.fileExists(atPath: f("ca.pem").path) || !fm.fileExists(atPath: f("ca.key").path) {
        let shortHost = ProcessInfo.processInfo.hostName.replacingOccurrences(of: ".local", with: "")
        let cnf = """
        [req]
        distinguished_name = dn
        prompt = no
        x509_extensions = v3_ca
        [dn]
        CN = Mac 遥控 本机证书 (\(shortHost))
        O = Mac Remote Local
        [v3_ca]
        basicConstraints = critical, CA:TRUE
        keyUsage = critical, keyCertSign, cRLSign
        subjectKeyIdentifier = hash
        """
        try? cnf.write(to: f("ca.cnf"), atomically: true, encoding: .utf8)
        guard runTool(ssl, ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256", "-days", "3650", "-utf8",
                            "-keyout", "ca.key", "-out", "ca.pem", "-config", "ca.cnf"], cwd: tlsDir) else { return nil }
        try? fm.removeItem(at: sansFile)
        log("已生成本机根证书")
    }

    let sans = "v2|" + certSANs()  // 前缀是证书格式版本，改了格式就会自动重新签发
    if (try? String(contentsOf: sansFile, encoding: .utf8)) != sans || !fm.fileExists(atPath: f("server.p12").path) {
        let cnf = """
        [req]
        distinguished_name = dn
        prompt = no
        [dn]
        CN = Mac Remote
        [ext]
        basicConstraints = critical, CA:FALSE
        keyUsage = critical, digitalSignature, keyEncipherment
        extendedKeyUsage = serverAuth
        subjectAltName = \(certSANs())
        subjectKeyIdentifier = hash
        authorityKeyIdentifier = keyid, issuer
        """
        try? cnf.write(to: f("server.cnf"), atomically: true, encoding: .utf8)
        // iOS 要求服务器证书有效期不超过 825 天
        guard runTool(ssl, ["req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", "server.key",
                            "-out", "server.csr", "-config", "server.cnf"], cwd: tlsDir),
              runTool(ssl, ["x509", "-req", "-in", "server.csr", "-CA", "ca.pem", "-CAkey", "ca.key", "-CAcreateserial",
                            "-out", "server.pem", "-days", "800", "-sha256", "-extfile", "server.cnf", "-extensions", "ext"], cwd: tlsDir),
              runTool(ssl, ["pkcs12", "-export", "-inkey", "server.key", "-in", "server.pem", "-certfile", "ca.pem",
                            "-out", "server.p12", "-passout", "pass:\(p12Pass)"], cwd: tlsDir)
        else { return nil }
        try? sans.write(to: sansFile, atomically: true, encoding: .utf8)
        log("已签发服务器证书：\(sans)")
    }

    guard let p12 = try? Data(contentsOf: f("server.p12")) else { return nil }
    var opts: [String: Any] = [kSecImportExportPassphrase as String: p12Pass]
    if #available(macOS 15.0, *) { opts[kSecImportToMemoryOnly as String] = true }  // 不写进钥匙串
    var items: CFArray?
    let status = SecPKCS12Import(p12 as CFData, opts as CFDictionary, &items)
    guard status == errSecSuccess, let arr = items as? [[String: Any]], let first = arr.first,
          let idRef = first[kSecImportItemIdentity as String] else {
        log("导入证书失败：\(status)")
        return nil
    }
    let identity = idRef as! SecIdentity
    return sec_identity_create(identity)
}

func startTLSListener() {
    guard let identity = ensureTLSIdentity() else { log("HTTPS 未启动（证书生成失败），视频模式不可用"); return }
    let tls = NWProtocolTLS.Options()
    sec_protocol_options_set_local_identity(tls.securityProtocolOptions, identity)
    let tcp = NWProtocolTCP.Options()
    let p = NWParameters(tls: tls, tcp: tcp)
    p.allowLocalEndpointReuse = true
    guard let nwPort = NWEndpoint.Port(rawValue: httpsPort), let l = try? NWListener(using: p, on: nwPort) else {
        log("无法监听 HTTPS 端口 \(httpsPort)"); return
    }
    l.newConnectionHandler = { conn in
        let ip = peerIP(conn)
        var ready = false
        conn.stateUpdateHandler = { st in
            switch st {
            case .ready: ready = true
            case .failed(let e), .waiting(let e):
                // 握手没成功：几乎都是这台设备没装 / 没信任证书（设备会直接拒绝），写日志方便排查
                if !ready { noteTLSFailure(ip, e) }
            default: break
            }
        }
        conn.start(queue: .global())
        receive(conn, Data())
    }
    l.stateUpdateHandler = { state in
        switch state {
        case .ready:
            DispatchQueue.main.async { httpsReady = true }
            log("HTTPS 已启动，端口 \(httpsPort)")
        case .failed(let e):
            DispatchQueue.main.async { httpsReady = false }
            log("HTTPS 监听失败：\(e)")
        default: break
        }
    }
    l.start(queue: .global())
    tlsListener = l
}
var tlsListener: NWListener?

private var tlsFailLogged: [String: Date] = [:]
private let tlsFailLock = NSLock()
func noteTLSFailure(_ ip: String, _ e: NWError) {
    tlsFailLock.lock()
    let last = tlsFailLogged[ip] ?? .distantPast
    let now = Date()
    if now.timeIntervalSince(last) > 60 { tlsFailLogged[ip] = now }
    tlsFailLock.unlock()
    guard now.timeIntervalSince(last) > 60 else { return }
    log("⚠️ \(ip) 的 HTTPS 握手失败：\(e)（多半是这台设备没装 Mac 的证书，或「证书信任设置」里没打开）")
}

func peerIP(_ conn: NWConnection) -> String {
    if case let .hostPort(host, _) = conn.endpoint {
        var h = "\(host)"
        if let pct = h.firstIndex(of: "%") { h = String(h[..<pct]) }
        if h.hasPrefix("::ffff:") { h = String(h.dropFirst(7)) }
        return h
    }
    return "?"
}

// MARK: Apple TV 遥控器（后台运行 atv-core 的接收端 atv-cli）

final class AtvRunner {
    static let shared = AtvRunner()
    static let uiPort = 8767   // atv-cli 自带的设置网页，避开 8765
    private var proc: Process?
    private var quitting = false
    private(set) var lastError: String?

    var executable: URL? { Bundle.main.url(forAuxiliaryExecutable: "atv-cli") }
    var isRunning: Bool { proc?.isRunning ?? false }

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "atvEnabled") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "atvEnabled")
            newValue ? start() : stop()
        }
    }

    /// 上次异常退出留下的进程会占着端口，先清掉（只清本 App 里那一份）
    func killOrphans() {
        guard let exe = executable else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-f", exe.path]
        try? p.run()
        p.waitUntilExit()
    }

    func start() {
        guard enabled, !quitting, !isRunning else { return }
        guard let exe = executable else { lastError = "App 里没有 Apple TV 组件"; return }
        let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
        let atvLog = logs.appendingPathComponent("atv-remote.log")
        if !FileManager.default.fileExists(atPath: atvLog.path) {
            FileManager.default.createFile(atPath: atvLog.path, contents: nil)
        }
        let p = Process()
        p.executableURL = exe
        p.arguments = ["--target", "mac", "--pin", "1111", "--ui-port", "\(Self.uiPort)", "--no-open"]
        var env = ProcessInfo.processInfo.environment
        env["ATV_DEBUG_LOG"] = env["ATV_DEBUG_LOG"] ?? "0"
        env["RUST_LOG"] = env["RUST_LOG"] ?? "info"
        p.environment = env
        p.currentDirectoryURL = logs
        if let h = try? FileHandle(forWritingTo: atvLog) {
            h.seekToEndOfFile()
            p.standardOutput = h
            p.standardError = h
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.proc = nil
                if self.quitting || !self.enabled { return }
                self.lastError = "意外退出（代码 \(proc.terminationStatus)），3 秒后重启"
                log("Apple TV 接收端退出，代码 \(proc.terminationStatus)，3 秒后重启")
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.start() }
            }
        }
        do {
            try p.run()
            proc = p
            lastError = nil
            log("Apple TV 接收端已启动（配对码 1111）")
        } catch {
            lastError = "启动失败：\(error.localizedDescription)"
        }
    }

    func stop() {
        proc?.terminate()
        proc = nil
    }

    func shutdown() {
        quitting = true
        stop()
    }
}

// MARK: 二维码窗口

func qrImage(_ text: String, scale: CGFloat = 10) -> NSImage? {
    guard let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    f.setValue(Data(text.utf8), forKey: "inputMessage")
    f.setValue("M", forKey: "inputCorrectionLevel")
    guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) else { return nil }
    let rep = NSCIImageRep(ciImage: out)
    let img = NSImage(size: rep.size)
    img.addRepresentation(rep)
    return img
}

final class QRWindow: NSObject, NSWindowDelegate {
    static let shared = QRWindow()
    private var window: NSWindow?

    func show() {
        let url = remoteURL()
        let w = window ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 470),
                                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "iPhone 网页遥控器"
        w.isReleasedWhenClosed = false
        w.delegate = self

        let title = NSTextField(labelWithString: "用 iPhone 相机扫一扫")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let img = NSImageView()
        img.image = qrImage(url)
        img.imageScaling = .scaleProportionallyUpOrDown
        img.widthAnchor.constraint(equalToConstant: 240).isActive = true
        img.heightAnchor.constraint(equalToConstant: 240).isActive = true
        let hint = NSTextField(wrappingLabelWithString:
            "iPhone 和这台 Mac 要连同一个 Wi-Fi。\n扫码后在 Safari 打开，点「分享 → 添加到主屏幕」，以后就像 App 一样用。")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .center
        hint.preferredMaxLayoutWidth = 290
        let link = NSTextField(labelWithString: url)
        link.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        link.textColor = .tertiaryLabelColor
        link.isSelectable = true
        link.lineBreakMode = .byTruncatingMiddle
        link.widthAnchor.constraint(lessThanOrEqualToConstant: 300).isActive = true
        let copy = NSButton(title: "复制链接", target: self, action: #selector(copyLink))
        copy.bezelStyle = .rounded

        let stack = NSStackView(views: [title, img, hint, link, copy])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        w.contentView = stack
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    @objc func copyLink() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(remoteURL(), forType: .string)
    }
}

// MARK: 菜单栏

final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    var trusted = AXIsProcessTrusted()
    var timer: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()
        DispatchQueue.global().async { _ = AutoUnlock.available }   // 先读一次钥匙串（要是弹授权框，趁现在人在电脑前）

        startListener()
        DispatchQueue.global().async { startTLSListener() }  // 第一次要生成证书，放后台
        AtvRunner.shared.killOrphans()
        if trusted { AtvRunner.shared.start() }

        // 第一次运行：默认开机自启（菜单里可以关）
        if #available(macOS 13.0, *), isAppBundle, UserDefaults.standard.object(forKey: "didSetupLogin") == nil {
            UserDefaults.standard.set(true, forKey: "didSetupLogin")
            try? SMAppService.mainApp.register()
        }

        if !trusted && ProcessInfo.processInfo.environment["WATCHBRIDGE_NO_PROMPT"] == nil {
            log("还没有辅助功能权限，弹出授权提示")
            requestPermission()
        }
        // 授权是在系统设置里完成的，这里定时检查；授权后自动重启一次，让接收端也拿到权限
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let now = AXIsProcessTrusted()
            if now != self.trusted {
                self.trusted = now
                self.updateIcon()
                if now { log("已获得辅助功能权限，重启 App"); self.relaunch() }
            }
        }
    }

    func applicationWillTerminate(_ n: Notification) {
        AtvRunner.shared.shutdown()
        FitDisplay.shared.revert()
    }

    func updateIcon() {
        let name = trusted ? "appletvremote.gen4" : "exclamationmark.triangle"
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Mac 遥控")
            ?? NSImage(systemSymbolName: "iphone", accessibilityDescription: "Mac 遥控")
        img?.isTemplate = true
        statusItem.button?.image = img
    }

    func requestPermission() {
        // 带 prompt 调用会把本 App 自动加进「辅助功能」列表，用户只需要打开开关
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(u)
        }
    }

    func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }

    // 每次打开菜单时重新生成，状态总是最新的
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func info(_ title: String) {
            let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            it.isEnabled = false
            menu.addItem(it)
        }
        func item(_ title: String, _ action: Selector, key: String = "", on: Bool? = nil) {
            let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
            it.target = self
            if let on = on { it.state = on ? .on : .off }
            menu.addItem(it)
        }

        let header = NSMenuItem(title: "Mac 遥控", action: nil, keyEquivalent: "")
        header.attributedTitle = NSAttributedString(string: "Mac 遥控", attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
        menu.addItem(header)

        if trusted {
            info("✅ 辅助功能已授权")
        } else {
            item("⚠️ 还没授权辅助功能，点这里去授权…", #selector(grant))
        }

        if !ScreenStreamer.shared.hasPermission {
            item("屏幕录制未授权（手机看屏幕要用），点这里去授权…", #selector(grantScreen))
        }

        switch serverState {
        case .ready: info("✅ 网页遥控：\(primaryIP() ?? "127.0.0.1"):\(port)")
        case .starting: info("… 网页遥控启动中")
        case .failed(let m): info("❌ 网页遥控：\(m)")
        }

        if FitDisplay.shared.active {
            info("📐 Mac 屏幕正按 iPad 比例显示（\(FitDisplay.shared.sizeText)）")
            item("立即恢复 Mac 屏幕", #selector(restoreScreen))
        }

        let atv = AtvRunner.shared
        if atv.executable == nil {
            info("❌ Apple TV 遥控器：组件缺失")
        } else if !atv.enabled {
            info("⏸ Apple TV 遥控器：已关闭")
        } else if atv.isRunning {
            info("✅ Apple TV 遥控器：运行中（配对码 1111）")
        } else if !trusted {
            info("⏸ Apple TV 遥控器：授权后自动启动")
        } else {
            info("❌ Apple TV 遥控器：\(atv.lastError ?? "未运行")")
        }

        menu.addItem(.separator())
        item("用 iPhone 扫码打开网页遥控器…", #selector(showQR))
        item("复制网页遥控链接", #selector(copyLink))
        menu.addItem(.separator())
        if atv.executable != nil {
            item("启用 Apple TV 遥控器", #selector(toggleAtv), on: atv.enabled)
            item("Apple TV 遥控器设置（触控板模式、速度）…", #selector(openAtvSettings))
        }
        item(AutoUnlock.available ? "自动解锁：已设置密码（点这里修改或清除）…" : "设置自动解锁密码…", #selector(setUnlockPassword),
             on: AutoUnlock.available)
        item("使用说明…", #selector(showHelp))
        menu.addItem(.separator())
        if #available(macOS 13.0, *) {
            item("开机自动启动", #selector(toggleLogin), on: SMAppService.mainApp.status == .enabled)
        }
        item("打开日志", #selector(openLog))
        menu.addItem(.separator())
        item("退出 Mac 遥控", #selector(quit), key: "q")
    }

    @objc func grant() { requestPermission() }
    @objc func grantScreen() {
        _ = CGRequestScreenCaptureAccess()
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(u)
        }
    }
    @objc func setUnlockPassword() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "自动解锁"
        a.informativeText = "输入这台 Mac 的开机密码。手机连上时如果 Mac 锁着，会自动用它解锁。\n\n"
            + "密码只存在这台 Mac 的钥匙串里，不会发到手机或网络上。\n"
            + "注意：拿到遥控链接（带 token）的设备都能解锁这台 Mac，链接别给别人。"
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "开机密码"
        a.accessoryView = field
        a.addButton(withTitle: "保存")
        a.addButton(withTitle: "取消")
        if AutoUnlock.available { a.addButton(withTitle: "清除密码") }
        a.window.initialFirstResponder = field
        switch a.runModal() {
        case .alertFirstButtonReturn:
            let pw = field.stringValue
            guard !pw.isEmpty else { return }
            guard AutoUnlock.verify(pw) else {
                let e = NSAlert(); e.messageText = "密码不对"; e.informativeText = "这不是当前用户「\(NSUserName())」的开机密码，没有保存。"
                e.runModal(); return
            }
            if AutoUnlock.save(pw) { log("已设置自动解锁密码") }
        case .alertThirdButtonReturn:
            _ = AutoUnlock.save(nil); log("已清除自动解锁密码")
        default: break
        }
    }
    @objc func showQR() { QRWindow.shared.show() }
    @objc func restoreScreen() { FitDisplay.shared.revert() }
    @objc func copyLink() { QRWindow.shared.copyLink() }
    @objc func toggleAtv() { AtvRunner.shared.enabled.toggle() }
    @objc func openAtvSettings() {
        if let u = URL(string: "http://127.0.0.1:\(AtvRunner.uiPort)") { NSWorkspace.shared.open(u) }
    }
    @objc func openLog() { NSWorkspace.shared.open(logURL) }
    @objc func quit() { NSApp.terminate(nil) }

    @objc func toggleLogin() {
        guard #available(macOS 13.0, *) else { return }
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled { try svc.unregister() } else { try svc.register() }
        } catch {
            let a = NSAlert()
            a.messageText = "设置开机启动失败"
            a.informativeText = "\(error.localizedDescription)\n可以到 系统设置 → 通用 → 登录项 里手动添加。"
            NSApp.activate(ignoringOtherApps: true)
            a.runModal()
        }
    }

    @objc func showHelp() {
        let a = NSAlert()
        a.messageText = "两种遥控方式"
        a.informativeText = """
        ① 网页遥控（功能最全）
        菜单里点「用 iPhone 扫码…」，扫码后在 Safari 打开，添加到主屏幕。支持单指移动、轻点、双指滚动和右键、捏合缩放、三指拖动、四指切桌面，以及中文输入法、键盘听写、语音指令。

        ② iPhone 自带的 Apple TV 遥控器
        iPhone 控制中心 → Apple TV 遥控器 → 顶部选择这台 Mac → 配对码输入 1111。
        滑动移动鼠标、轻点点击；从触控区最右侧上下滑 = 滚动；按住约半秒再移动 = 拖动；点键盘图标可以打字和听写。

        iPhone 和 Mac 必须连同一个 Wi-Fi。
        """
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)  // 只在菜单栏显示，不占 Dock
app.run()
