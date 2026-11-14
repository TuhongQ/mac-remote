//! 托盘图标和菜单（对应 Mac 版的菜单栏图标）

use std::sync::OnceLock;

use qrcode::render::svg;
use qrcode::QrCode;
use windows_sys::Win32::Foundation::{HWND, LPARAM, LRESULT, POINT, WPARAM};
use windows_sys::Win32::System::LibraryLoader::GetModuleHandleW;
use windows_sys::Win32::System::Registry::{
    RegCloseKey, RegDeleteValueW, RegOpenKeyExW, RegQueryValueExW, RegSetValueExW, HKEY, HKEY_CURRENT_USER, KEY_READ,
    KEY_WRITE, REG_SZ,
};
use windows_sys::Win32::UI::Shell::{
    ShellExecuteW, Shell_NotifyIconW, NIF_ICON, NIF_MESSAGE, NIF_TIP, NIM_ADD, NIM_DELETE, NOTIFYICONDATAW,
};
use windows_sys::Win32::UI::WindowsAndMessaging::*;

use crate::server::CONFIG;
use crate::util::{self, log, wide};

const WM_TRAY: u32 = WM_APP + 1;
const ID_QR: usize = 1;
const ID_COPY: usize = 2;
const ID_LOGIN: usize = 3;
const ID_LOG: usize = 4;
const ID_QUIT: usize = 5;
const ID_HELP: usize = 6;
const ID_ADMIN: usize = 7;
const ID_APPLE_TV: usize = 8;

static STATUS: OnceLock<Result<(), String>> = OnceLock::new();
static TASKBAR_CREATED: OnceLock<u32> = OnceLock::new();

fn remote_url() -> String {
    let c = CONFIG.get().unwrap();
    format!("http://{}:{}/remote?token={}", util::primary_ip(), c.port, c.token)
}

fn open(target: &str) {
    let op = wide("open");
    let f = wide(target);
    unsafe { ShellExecuteW(std::ptr::null_mut(), op.as_ptr(), f.as_ptr(), std::ptr::null(), std::ptr::null(), SW_SHOWNORMAL) };
}

fn apple_tv_exe() -> Option<std::path::PathBuf> {
    let path = std::env::current_exe().ok()?.with_file_name("AppleTVRemote.exe");
    path.is_file().then_some(path)
}

/// 二维码：生成一个本地网页（内嵌 SVG 二维码）用默认浏览器打开
fn show_qr() {
    let url = remote_url();
    let Ok(code) = QrCode::new(url.as_bytes()) else { return };
    let img = code.render::<svg::Color>().min_dimensions(320, 320).quiet_zone(true).build();
    let html = format!(
        "<!doctype html><meta charset=utf-8><title>PC 遥控 · 扫码连接</title>\
         <body style=\"font-family:system-ui,'Microsoft YaHei';text-align:center;padding:30px;background:#f4f5f7\">\
         <h2>用 iPhone / iPad 相机扫码</h2>{img}\
         <p style=\"color:#555\">手机和这台电脑要连同一个 Wi-Fi。扫码后用 Safari 打开，再「分享 → 添加到主屏幕」。</p>\
         <p style=\"color:#888;font-size:13px;word-break:break-all\">{url}</p></body>"
    );
    let path = std::env::temp_dir().join("pc-remote-qr.html");
    if std::fs::write(&path, html).is_ok() {
        open(&path.to_string_lossy());
    }
}

static CLIPBOARD_WINDOW: std::sync::atomic::AtomicPtr<std::ffi::c_void> =
    std::sync::atomic::AtomicPtr::new(std::ptr::null_mut());

pub fn clipboard_window() -> HWND {
    CLIPBOARD_WINDOW.load(std::sync::atomic::Ordering::Relaxed)
}

pub fn start_clipboard_window() {
    let class = wide("STATIC");
    unsafe {
        let owner = CreateWindowExW(
            0, class.as_ptr(), std::ptr::null(), 0, 0, 0, 0, 0,
            HWND_MESSAGE, std::ptr::null_mut(), std::ptr::null_mut(), std::ptr::null(),
        );
        CLIPBOARD_WINDOW.store(owner, std::sync::atomic::Ordering::Relaxed);
    }
}

fn copy_link() {
    let w: Vec<u16> = remote_url().encode_utf16().chain(std::iter::once(0)).collect();
    crate::input::clipboard_set(&w);
}

// ---------- 开机自动启动（HKCU\...\Run）----------

const RUN_KEY: &str = "Software\\Microsoft\\Windows\\CurrentVersion\\Run";
const RUN_NAME: &str = "PCRemote";

fn login_enabled() -> bool {
    unsafe {
        let mut key: HKEY = std::ptr::null_mut();
        let k = wide(RUN_KEY);
        if RegOpenKeyExW(HKEY_CURRENT_USER, k.as_ptr(), 0, KEY_READ, &mut key) != 0 {
            return false;
        }
        let n = wide(RUN_NAME);
        let ok = RegQueryValueExW(key, n.as_ptr(), std::ptr::null(), std::ptr::null_mut(), std::ptr::null_mut(), std::ptr::null_mut()) == 0;
        RegCloseKey(key);
        ok
    }
}

fn set_login(on: bool) {
    unsafe {
        let mut key: HKEY = std::ptr::null_mut();
        let k = wide(RUN_KEY);
        if RegOpenKeyExW(HKEY_CURRENT_USER, k.as_ptr(), 0, KEY_WRITE, &mut key) != 0 {
            return;
        }
        let n = wide(RUN_NAME);
        if on {
            let exe = std::env::current_exe().map(|p| p.to_string_lossy().into_owned()).unwrap_or_default();
            let v = wide(&format!("\"{exe}\""));
            RegSetValueExW(key, n.as_ptr(), 0, REG_SZ, v.as_ptr() as *const u8, (v.len() * 2) as u32);
        } else {
            RegDeleteValueW(key, n.as_ptr());
        }
        RegCloseKey(key);
    }
}

// ---------- 托盘 ----------

fn add_icon(hwnd: HWND) {
    unsafe {
        let mut nid: NOTIFYICONDATAW = std::mem::zeroed();
        nid.cbSize = std::mem::size_of::<NOTIFYICONDATAW>() as u32;
        nid.hWnd = hwnd;
        nid.uID = 1;
        nid.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
        nid.uCallbackMessage = WM_TRAY;
        nid.hIcon = LoadIconW(std::ptr::null_mut(), IDI_APPLICATION);
        let tip = wide("PC 遥控（iPhone / iPad 遥控这台电脑）");
        nid.szTip[..tip.len().min(127)].copy_from_slice(&tip[..tip.len().min(127)]);
        Shell_NotifyIconW(NIM_ADD, &nid);
    }
}

fn remove_icon(hwnd: HWND) {
    unsafe {
        let mut nid: NOTIFYICONDATAW = std::mem::zeroed();
        nid.cbSize = std::mem::size_of::<NOTIFYICONDATAW>() as u32;
        nid.hWnd = hwnd;
        nid.uID = 1;
        Shell_NotifyIconW(NIM_DELETE, &nid);
    }
}

fn show_menu(hwnd: HWND) {
    unsafe {
        let m = CreatePopupMenu();
        let item = |flags: u32, id: usize, text: &str| {
            let t = wide(text);
            AppendMenuW(m, flags, id, t.as_ptr());
        };
        let port = CONFIG.get().unwrap().port;
        match STATUS.get() {
            Some(Ok(())) => {
                item(MF_STRING | MF_GRAYED, 0, &format!("✅ 网页遥控：{}:{port}", util::primary_ip()));
                let hp = crate::server::HTTPS_PORT.load(std::sync::atomic::Ordering::Relaxed);
                item(MF_STRING | MF_GRAYED, 0, &if hp > 0 { format!("✅ 视频模式（HTTPS）：端口 {hp}") } else { "⚠️ HTTPS 没有启动，只能用图片模式（见日志）".to_string() });
            }
            Some(Err(e)) => item(MF_STRING | MF_GRAYED, 0, &format!("❌ {e}")),
            None => {}
        }
        AppendMenuW(m, MF_SEPARATOR, 0, std::ptr::null());
        item(MF_STRING, ID_QR, "用 iPhone 扫码打开网页遥控器…");
        item(MF_STRING, ID_COPY, "复制网页遥控链接");
        if !crate::input::self_elevated() && apple_tv_exe().is_some() {
            item(MF_STRING, ID_APPLE_TV, "打开 Apple TV 遥控器…");
        }
        AppendMenuW(m, MF_SEPARATOR, 0, std::ptr::null());
        item(MF_STRING, ID_HELP, "使用说明…");
        item(MF_STRING | if login_enabled() { MF_CHECKED } else { 0 }, ID_LOGIN, "开机自动启动");
        item(MF_STRING, ID_LOG, "打开日志");
        if crate::input::self_elevated() {
            item(MF_STRING | MF_GRAYED, 0, "🛡 正在以管理员身份运行");
        } else {
            item(MF_STRING, ID_ADMIN, "以管理员身份重新启动（能操作任务管理器等窗口）");
        }
        AppendMenuW(m, MF_SEPARATOR, 0, std::ptr::null());
        item(MF_STRING, ID_QUIT, "退出 PC 遥控");
        let mut p = POINT { x: 0, y: 0 };
        GetCursorPos(&mut p);
        SetForegroundWindow(hwnd); // 不然点菜单外面菜单不会消失
        TrackPopupMenu(m, TPM_RIGHTBUTTON, p.x, p.y, 0, hwnd, std::ptr::null());
        DestroyMenu(m);
    }
}

unsafe extern "system" fn wndproc(hwnd: HWND, msg: u32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    match msg {
        WM_TRAY => {
            let ev = (lp & 0xFFFF) as u32;
            if ev == WM_RBUTTONUP || ev == WM_LBUTTONUP {
                show_menu(hwnd);
            }
            0
        }
        WM_COMMAND => {
            match wp & 0xFFFF {
                ID_QR => show_qr(),
                ID_COPY => copy_link(),
                ID_LOGIN => set_login(!login_enabled()),
                ID_LOG => open(&util::log_path().to_string_lossy()),
                ID_ADMIN => restart_as_admin(hwnd),
                ID_HELP => open("https://github.com/TuhongQ/mac-remote/blob/windows/windows/README.md"),
                ID_APPLE_TV if !crate::input::self_elevated() => {
                    if let Some(path) = apple_tv_exe() {
                        open(&path.to_string_lossy());
                    }
                }
                ID_QUIT => {
                    remove_icon(hwnd);
                    log("退出");
                    PostQuitMessage(0);
                }
                _ => {}
            }
            0
        }
        WM_DESTROY => {
            remove_icon(hwnd);
            PostQuitMessage(0);
            0
        }
        _ => {
            // 资源管理器重启后托盘图标会丢，收到这个消息时重新加上
            if Some(&msg) == TASKBAR_CREATED.get() {
                add_icon(hwnd);
                return 0;
            }
            DefWindowProcW(hwnd, msg, wp, lp)
        }
    }
}

/// 用 UAC 提权重新启动自己；新进程等旧的退出后接手（--restart）
fn restart_as_admin(hwnd: HWND) {
    let Ok(exe) = std::env::current_exe() else { return };
    let mut args: Vec<String> = std::env::args().skip(1).filter(|a| a != "--restart").collect();
    args.push("--restart".into());
    let (verb, file, params) = (wide("runas"), wide(&exe.to_string_lossy()), wide(&args.join(" ")));
    let r = unsafe { ShellExecuteW(hwnd, verb.as_ptr(), file.as_ptr(), params.as_ptr(), std::ptr::null(), SW_SHOWNORMAL) };
    if r as isize > 32 {
        log("以管理员身份重新启动");
        unsafe {
            remove_icon(hwnd);
            PostQuitMessage(0);
        }
    } else {
        log("没有以管理员身份重新启动（取消了 UAC 确认）");
    }
}

pub fn run(status: Result<(), String>) {
    let _ = STATUS.set(status);
    unsafe {
        let tc = wide("TaskbarCreated");
        let _ = TASKBAR_CREATED.set(RegisterWindowMessageW(tc.as_ptr()));
        let hinst = GetModuleHandleW(std::ptr::null());
        let cls = wide("PCRemoteTray");
        let mut wc: WNDCLASSW = std::mem::zeroed();
        wc.lpfnWndProc = Some(wndproc);
        wc.hInstance = hinst;
        wc.lpszClassName = cls.as_ptr();
        RegisterClassW(&wc);
        let title = wide("PC 遥控");
        // 隐藏的顶层窗口（不用 HWND_MESSAGE，才能收到 TaskbarCreated 广播）
        let hwnd = CreateWindowExW(0, cls.as_ptr(), title.as_ptr(), 0, 0, 0, 0, 0, std::ptr::null_mut(), std::ptr::null_mut(), hinst, std::ptr::null());
        add_icon(hwnd);
        // 第一次运行默认打开开机自动启动（和 Mac 版一致）
        let first = util::config_dir().join("launched");
        if !first.exists() {
            set_login(true);
            let _ = std::fs::write(&first, "1");
            show_qr();
        }
        let mut msg: MSG = std::mem::zeroed();
        while GetMessageW(&mut msg, std::ptr::null_mut(), 0, 0) > 0 {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }
}
