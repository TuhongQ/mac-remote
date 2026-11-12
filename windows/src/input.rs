//! 鼠标、键盘、滚轮、文字输入（SendInput）。
//! 网页发来的按键名是 Mac 的写法（cmd+c、ctrl+←切桌面……），在这里翻译成 Windows 的等价操作。

use std::mem::size_of;
use std::sync::Mutex;

use windows_sys::Win32::Foundation::{HANDLE, POINT, RECT};
use windows_sys::Win32::Graphics::Gdi::{GetMonitorInfoW, MonitorFromPoint, MONITORINFO, MONITOR_DEFAULTTOPRIMARY};
use windows_sys::Win32::System::DataExchange::{
    CloseClipboard, EmptyClipboard, GetClipboardData, GetClipboardSequenceNumber, OpenClipboard, SetClipboardData,
};
use windows_sys::Win32::System::Memory::{GlobalAlloc, GlobalLock, GlobalUnlock, GMEM_MOVEABLE};
use windows_sys::Win32::System::Shutdown::LockWorkStation;
use windows_sys::Win32::UI::HiDpi::GetDpiForSystem;
use windows_sys::Win32::UI::Input::KeyboardAndMouse::*;
use windows_sys::Win32::UI::WindowsAndMessaging::{
    GetCursorPos, GetSystemMetrics, SM_CXVIRTUALSCREEN, SM_CYVIRTUALSCREEN, SM_XVIRTUALSCREEN, SM_YVIRTUALSCREEN,
};

const CF_UNICODETEXT: u32 = 13;

/// 所有输入串行执行，防止两台设备 / 两个请求的字交错
pub static INPUT_LOCK: Mutex<()> = Mutex::new(());

struct State {
    held: Option<Button>,        // 正在按住的鼠标键
    frac: (f64, f64),            // 光标移动的小数部分
    wheel: (f64, f64),           // 滚轮的小数部分
}
static STATE: Mutex<State> = Mutex::new(State { held: None, frac: (0.0, 0.0), wheel: (0.0, 0.0) });

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Button {
    Left,
    Right,
    Middle,
}

impl Button {
    pub fn from(s: Option<&str>) -> Button {
        match s {
            Some("right") => Button::Right,
            Some("middle") => Button::Middle,
            _ => Button::Left,
        }
    }
    fn flags(self, down: bool) -> u32 {
        match (self, down) {
            (Button::Left, true) => MOUSEEVENTF_LEFTDOWN,
            (Button::Left, false) => MOUSEEVENTF_LEFTUP,
            (Button::Right, true) => MOUSEEVENTF_RIGHTDOWN,
            (Button::Right, false) => MOUSEEVENTF_RIGHTUP,
            (Button::Middle, true) => MOUSEEVENTF_MIDDLEDOWN,
            (Button::Middle, false) => MOUSEEVENTF_MIDDLEUP,
        }
    }
}

fn send(inputs: &[INPUT]) {
    if inputs.is_empty() {
        return;
    }
    unsafe { SendInput(inputs.len() as u32, inputs.as_ptr(), size_of::<INPUT>() as i32) };
}

fn mouse_input(dx: i32, dy: i32, data: i32, flags: u32) -> INPUT {
    INPUT {
        r#type: INPUT_MOUSE,
        Anonymous: INPUT_0 {
            mi: MOUSEINPUT { dx, dy, mouseData: data as _, dwFlags: flags, time: 0, dwExtraInfo: 0 },
        },
    }
}

fn key_input(vk: u16, scan: u16, flags: u32) -> INPUT {
    INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 { ki: KEYBDINPUT { wVk: vk, wScan: scan, dwFlags: flags, time: 0, dwExtraInfo: 0 } },
    }
}

// ---------- 鼠标 ----------

fn virtual_screen() -> (i32, i32, i32, i32) {
    unsafe {
        (
            GetSystemMetrics(SM_XVIRTUALSCREEN),
            GetSystemMetrics(SM_YVIRTUALSCREEN),
            GetSystemMetrics(SM_CXVIRTUALSCREEN).max(1),
            GetSystemMetrics(SM_CYVIRTUALSCREEN).max(1),
        )
    }
}

pub fn cursor() -> (i32, i32) {
    let mut p = POINT { x: 0, y: 0 };
    unsafe { GetCursorPos(&mut p) };
    (p.x, p.y)
}

/// 主显示器的范围（物理像素）。屏幕镜像、clickAt 的坐标都相对它
pub fn primary_bounds() -> RECT {
    unsafe {
        let mon = MonitorFromPoint(POINT { x: 0, y: 0 }, MONITOR_DEFAULTTOPRIMARY);
        let mut mi: MONITORINFO = std::mem::zeroed();
        mi.cbSize = size_of::<MONITORINFO>() as u32;
        GetMonitorInfoW(mon, &mut mi);
        mi.rcMonitor
    }
}

/// 把光标移到 (x, y)（物理像素）。用绝对坐标，不受系统「提高指针精确度」影响；按住键时就是拖动
pub fn move_to(x: i32, y: i32) {
    let (vx, vy, vw, vh) = virtual_screen();
    let x = x.clamp(vx, vx + vw - 1);
    let y = y.clamp(vy, vy + vh - 1);
    let nx = ((x - vx) as f64 * 65535.0 / (vw - 1).max(1) as f64).round() as i32;
    let ny = ((y - vy) as f64 * 65535.0 / (vh - 1).max(1) as f64).round() as i32;
    send(&[mouse_input(nx, ny, 0, MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK)]);
}

/// 网页发来的位移是「点」，按系统缩放比例换成像素（150% 缩放时 1 点 = 1.5 像素）
pub fn dpi_scale() -> f64 {
    (unsafe { GetDpiForSystem() } as f64 / 96.0).max(1.0)
}

pub fn move_by(dx: f64, dy: f64) {
    let k = dpi_scale();
    let mut st = STATE.lock().unwrap();
    let fx = dx * k + st.frac.0;
    let fy = dy * k + st.frac.1;
    let (ix, iy) = (fx.trunc(), fy.trunc());
    st.frac = (fx - ix, fy - iy);
    drop(st);
    if ix == 0.0 && iy == 0.0 {
        return;
    }
    let (cx, cy) = cursor();
    move_to(cx + ix as i32, cy + iy as i32);
}

/// 主显示器上的相对位置（0~1）→ 像素
pub fn point_in_primary(x: f64, y: f64) -> (i32, i32) {
    let r = primary_bounds();
    let w = (r.right - r.left) as f64;
    let h = (r.bottom - r.top) as f64;
    ((r.left as f64 + x * w).round() as i32, (r.top as f64 + y * h).round() as i32)
}

pub fn button(b: Button, down: bool) {
    let mut st = STATE.lock().unwrap();
    if down {
        st.held = Some(b);
    } else if st.held != Some(b) {
        return; // 没按下就不发抬起
    } else {
        st.held = None;
    }
    drop(st);
    send(&[mouse_input(0, 0, 0, b.flags(down))]);
}

/// 单击（Windows 自己按两次点击的间隔和距离判断双击）
pub fn click(b: Button) {
    release_held();
    send(&[mouse_input(0, 0, 0, b.flags(true)), mouse_input(0, 0, 0, b.flags(false))]);
}

pub fn release_held() {
    let held = STATE.lock().unwrap().held.take();
    if let Some(b) = held {
        send(&[mouse_input(0, 0, 0, b.flags(false))]);
    }
}

/// 滚动。dx、dy 是网页发来的「像素」（Mac 的写法：手指往上 dy 为负 = 内容往上 = 往下滚）。
/// Windows 滚轮 120 = 一格（约 3 行）；发小于 120 的值就是平滑滚动（浏览器等都支持）
pub fn scroll(dx: f64, dy: f64) {
    const K: f64 = 2.4; // 1 像素 ≈ 2.4 个滚轮单位（一格 120 ≈ 50 像素）
    let mut st = STATE.lock().unwrap();
    let fy = dy * K + st.wheel.1;
    let fx = -dx * K + st.wheel.0;
    let (iy, ix) = (fy.trunc(), fx.trunc());
    st.wheel = (fx - ix, fy - iy);
    drop(st);
    let mut v = Vec::new();
    if iy != 0.0 {
        v.push(mouse_input(0, 0, iy as i32, MOUSEEVENTF_WHEEL));
    }
    if ix != 0.0 {
        v.push(mouse_input(0, 0, ix as i32, MOUSEEVENTF_HWHEEL));
    }
    send(&v);
}

pub fn scroll_lines(lines: i32) {
    send(&[mouse_input(0, 0, lines * 40, MOUSEEVENTF_WHEEL)]);
}

// ---------- 键盘 ----------

fn vk_for(name: &str) -> Option<u16> {
    let n = name;
    if n.len() == 1 {
        let c = n.chars().next().unwrap();
        if c.is_ascii_alphabetic() {
            return Some(c.to_ascii_uppercase() as u16);
        }
        if c.is_ascii_digit() {
            return Some(c as u16);
        }
        return Some(match c {
            '=' => VK_OEM_PLUS,
            '-' => VK_OEM_MINUS,
            '[' => VK_OEM_4,
            ']' => VK_OEM_6,
            ';' => VK_OEM_1,
            '\'' => VK_OEM_7,
            ',' => VK_OEM_COMMA,
            '.' => VK_OEM_PERIOD,
            '/' => VK_OEM_2,
            '\\' => VK_OEM_5,
            '`' => VK_OEM_3,
            _ => return None,
        });
    }
    if let Some(num) = n.strip_prefix('f').and_then(|s| s.parse::<u16>().ok()) {
        if (1..=24).contains(&num) {
            return Some(VK_F1 + num - 1);
        }
    }
    Some(match n {
        "return" | "enter" => VK_RETURN,
        "tab" => VK_TAB,
        "space" => VK_SPACE,
        "delete" | "backspace" => VK_BACK,
        "esc" | "escape" => VK_ESCAPE,
        "forwarddelete" | "del" => VK_DELETE,
        "insert" => VK_INSERT,
        "home" => VK_HOME,
        "end" => VK_END,
        "pageup" => VK_PRIOR,
        "pagedown" => VK_NEXT,
        "left" => VK_LEFT,
        "right" => VK_RIGHT,
        "up" => VK_UP,
        "down" => VK_DOWN,
        "printscreen" | "prtsc" => VK_SNAPSHOT,
        _ => return None,
    })
}

/// 方向键、Home/End、Delete、Win 键等要带「扩展键」标志，否则会被当成小键盘
fn is_extended(vk: u16) -> bool {
    matches!(
        vk,
        VK_LEFT | VK_RIGHT | VK_UP | VK_DOWN | VK_HOME | VK_END | VK_PRIOR | VK_NEXT | VK_INSERT | VK_DELETE
            | VK_LWIN | VK_RWIN | VK_SNAPSHOT
    )
}

fn key(vk: u16, down: bool) -> INPUT {
    let mut f = if down { 0 } else { KEYEVENTF_KEYUP };
    if is_extended(vk) {
        f |= KEYEVENTF_EXTENDEDKEY;
    }
    let scan = unsafe { MapVirtualKeyW(vk as u32, MAPVK_VK_TO_VSC) } as u16;
    key_input(vk, scan, f)
}

pub fn tap_key(vk: u16) {
    send(&[key(vk, true), key(vk, false)]);
}

/// Mac 写法的组合键 → Windows 的等价组合（找不到就原样，cmd 当 Ctrl）
fn translate(combo: &str) -> String {
    let c = combo.to_ascii_lowercase().replace(' ', "").replace("command", "cmd").replace("control", "ctrl")
        .replace("option", "alt").replace("opt", "alt");
    let mapped = match c.as_str() {
        "ctrl+left" => "win+ctrl+left",         // 切换桌面
        "ctrl+right" => "win+ctrl+right",
        "ctrl+up" | "ctrl+down" => "win+tab",  // 调度中心 / 应用窗口 → 任务视图
        "f11" => "win+d",                       // 显示桌面
        "ctrl+cmd+f" => "f11",                  // 全屏
        "cmd+space" => "win+s",                 // 聚焦 → 搜索
        "ctrl+space" => "win+space",            // 切换输入法
        "cmd+tab" => "alt+tab",
        "cmd+q" => "alt+f4",                    // 退出 App
        "cmd+shift+4" | "cmd+shift+5" => "win+shift+s", // 截图（选区域）
        "cmd+shift+3" => "win+printscreen",     // 全屏截图并保存
        "cmd+[" => "alt+left",                  // 后退
        "cmd+]" => "alt+right",                 // 前进
        "cmd+," => "win+i",                     // 设置
        _ => "",
    };
    if mapped.is_empty() { c } else { mapped.to_string() }
}

/// 按组合键，例如 "cmd+c"、"ctrl+cmd+f"。返回 false = 不认识
pub fn press_combo(combo: &str) -> bool {
    let c = translate(combo);
    if c == "ctrl+cmd+q" || c == "win+l" {
        unsafe { LockWorkStation() }; // 锁屏不能用模拟按键，只能调系统接口
        return true;
    }
    let parts: Vec<&str> = c.split('+').collect();
    let mut key_name = parts.last().copied().unwrap_or("");
    if key_name.is_empty() && parts.len() >= 2 {
        key_name = "="; // "cmd++" = 放大
    }
    let Some(main) = vk_for(key_name) else { return false };
    let mut mods = Vec::new();
    for m in &parts[..parts.len().saturating_sub(1)] {
        let vk = match *m {
            "" => continue,
            "cmd" | "ctrl" => VK_CONTROL,
            "shift" => VK_SHIFT,
            "alt" => VK_MENU,
            "win" | "super" => VK_LWIN,
            "fn" => continue,
            _ => return false,
        };
        if !mods.contains(&vk) {
            mods.push(vk);
        }
    }
    let mut v: Vec<INPUT> = mods.iter().map(|m| key(*m, true)).collect();
    v.push(key(main, true));
    v.push(key(main, false));
    v.extend(mods.iter().rev().map(|m| key(*m, false)));
    send(&v);
    true
}

/// 打字：直接发 Unicode（不经过输入法），中文、emoji 都可以；换行变回车，制表符变 Tab
pub fn type_text(text: &str) {
    let mut v: Vec<INPUT> = Vec::new();
    for ch in text.chars() {
        match ch {
            '\r' => continue,
            '\n' => {
                v.push(key(VK_RETURN, true));
                v.push(key(VK_RETURN, false));
            }
            '\t' => {
                v.push(key(VK_TAB, true));
                v.push(key(VK_TAB, false));
            }
            _ => {
                let mut buf = [0u16; 2];
                for unit in ch.encode_utf16(&mut buf) {
                    v.push(key_input(0, *unit, KEYEVENTF_UNICODE));
                    v.push(key_input(0, *unit, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP));
                }
            }
        }
        if v.len() >= 64 {
            send(&v);
            v.clear();
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
    }
    send(&v);
}

// ---------- 剪贴板粘贴（个别程序收不到 Unicode 按键时用）----------

fn clipboard_get() -> Option<Vec<u16>> {
    unsafe {
        if OpenClipboard(std::ptr::null_mut()) == 0 {
            return None;
        }
        let h = GetClipboardData(CF_UNICODETEXT);
        let mut out = None;
        if !h.is_null() {
            let p = GlobalLock(h as _) as *const u16;
            if !p.is_null() {
                let mut n = 0;
                while *p.add(n) != 0 {
                    n += 1;
                }
                out = Some(std::slice::from_raw_parts(p, n + 1).to_vec());
                GlobalUnlock(h as _);
            }
        }
        CloseClipboard();
        out
    }
}

pub fn clipboard_set(text: &[u16]) -> bool {
    unsafe {
        if OpenClipboard(std::ptr::null_mut()) == 0 {
            return false;
        }
        EmptyClipboard();
        let bytes = text.len() * 2;
        let h = GlobalAlloc(GMEM_MOVEABLE, bytes);
        if h.is_null() {
            CloseClipboard();
            return false;
        }
        let p = GlobalLock(h) as *mut u16;
        std::ptr::copy_nonoverlapping(text.as_ptr(), p, text.len());
        GlobalUnlock(h);
        SetClipboardData(CF_UNICODETEXT, h as HANDLE);
        CloseClipboard();
        true
    }
}

pub fn paste_text(text: &str) {
    let saved = clipboard_get();
    let w: Vec<u16> = text.encode_utf16().chain(std::iter::once(0)).collect();
    if !clipboard_set(&w) {
        type_text(text);
        return;
    }
    let seq = unsafe { GetClipboardSequenceNumber() };
    press_combo("ctrl+v");
    // 0.8 秒后恢复原来的剪贴板（这期间用户自己复制了东西就不恢复）
    std::thread::spawn(move || {
        std::thread::sleep(std::time::Duration::from_millis(800));
        if unsafe { GetClipboardSequenceNumber() } == seq {
            if let Some(s) = saved {
                clipboard_set(&s);
            }
        }
    });
}

// ---------- 媒体键 ----------

pub enum Media {
    PlayPause,
    Next,
    Previous,
    Mute,
    VolumeUp,
    VolumeDown,
}

pub fn media(m: Media) {
    tap_key(match m {
        Media::PlayPause => VK_MEDIA_PLAY_PAUSE,
        Media::Next => VK_MEDIA_NEXT_TRACK,
        Media::Previous => VK_MEDIA_PREV_TRACK,
        Media::Mute => VK_VOLUME_MUTE,
        Media::VolumeUp => VK_VOLUME_UP,
        Media::VolumeDown => VK_VOLUME_DOWN,
    });
}
