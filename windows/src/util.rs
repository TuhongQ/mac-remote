//! 配置目录、token、日志、本机 IP

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::net::UdpSocket;
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};

use windows_sys::Win32::System::SystemInformation::GetLocalTime;

fn env_dir(var: &str) -> PathBuf {
    std::env::var_os(var).map(PathBuf::from).unwrap_or_else(|| PathBuf::from("."))
}

/// %APPDATA%\WatchBridge（token、证书）
pub fn config_dir() -> PathBuf {
    let d = env_dir("APPDATA").join("WatchBridge");
    let _ = fs::create_dir_all(&d);
    d
}

/// %LOCALAPPDATA%\WatchBridge（日志）
pub fn log_dir() -> PathBuf {
    let d = env_dir("LOCALAPPDATA").join("WatchBridge");
    let _ = fs::create_dir_all(&d);
    d
}

pub fn log_path() -> PathBuf {
    log_dir().join("watchbridge.log")
}

/// 访问 token：环境变量 WATCHBRIDGE_TOKEN → 文件 → 随机生成 16 位
pub fn load_or_create_token() -> String {
    if let Ok(t) = std::env::var("WATCHBRIDGE_TOKEN") {
        if !t.is_empty() {
            return t;
        }
    }
    let file = config_dir().join("token");
    if let Ok(s) = fs::read_to_string(&file) {
        let t = s.trim().to_string();
        if !t.is_empty() {
            return t;
        }
    }
    const CHARS: &[u8] = b"abcdefghijkmnpqrstuvwxyz23456789";
    let mut buf = [0u8; 16];
    getrandom::getrandom(&mut buf).expect("随机数");
    let token: String = buf.iter().map(|b| CHARS[*b as usize % CHARS.len()] as char).collect();
    let _ = fs::write(&file, &token);
    token
}

static LOG: OnceLock<Mutex<Option<fs::File>>> = OnceLock::new();

/// 写一行日志：[时:分:秒] 内容
pub fn log(msg: impl AsRef<str>) {
    let mut t = unsafe { std::mem::zeroed() };
    unsafe { GetLocalTime(&mut t) };
    let t: windows_sys::Win32::Foundation::SYSTEMTIME = t;
    let line = format!("[{:02}:{:02}:{:02}] {}\r\n", t.wHour, t.wMinute, t.wSecond, msg.as_ref());
    let m = LOG.get_or_init(|| {
        Mutex::new(OpenOptions::new().create(true).append(true).open(log_path()).ok())
    });
    if let Ok(mut f) = m.lock() {
        if let Some(f) = f.as_mut() {
            let _ = f.write_all(line.as_bytes());
        }
    }
}

/// 局域网 IP（不真的发包：UDP「连接」一个外网地址，看系统选了哪个本机地址）
pub fn primary_ip() -> String {
    UdpSocket::bind("0.0.0.0:0")
        .and_then(|s| {
            s.connect("8.8.8.8:80")?;
            s.local_addr()
        })
        .map(|a| a.ip().to_string())
        .unwrap_or_else(|_| "127.0.0.1".into())
}

/// UTF-16 字符串（Win32 API 用），带结尾 0
pub fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}
