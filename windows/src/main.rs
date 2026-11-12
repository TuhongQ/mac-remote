//! PC 遥控（Mac 遥控的 Windows 版）：托盘程序，iPhone / iPad 用同一个网页遥控器控制这台 Windows 电脑。
//! 运行：PCRemote.exe [--port 8765]
#![windows_subsystem = "windows"]

mod commands;
mod h264;
mod input;
mod screen;
mod server;
mod tls;
mod tray;
mod util;

use util::{log, wide};
use windows_sys::Win32::Foundation::{CloseHandle, GetLastError, ERROR_ALREADY_EXISTS};
use windows_sys::Win32::System::Threading::CreateMutexW;
use windows_sys::Win32::UI::HiDpi::{SetProcessDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2};
use windows_sys::Win32::UI::WindowsAndMessaging::{MessageBoxW, MB_ICONWARNING, MB_OK};

fn main() {
    // 哪个线程出错都写进日志（只结束那个线程，不让整个程序悄悄退出）
    std::panic::set_hook(Box::new(|info| {
        let name = std::thread::current().name().unwrap_or("?").to_string();
        log(format!("❌ 程序出错（线程 {name}）：{info}"));
    }));

    // 按物理像素工作：光标坐标、屏幕范围都不受系统缩放影响
    unsafe { SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) };

    // 只运行一个
    // --restart：旧进程正在退出（比如换成管理员身份），等它最多 10 秒
    let name = wide("Local\\WatchBridgePCRemote");
    let restart = std::env::args().any(|a| a == "--restart");
    let mut tries = 0;
    loop {
        let h = unsafe { CreateMutexW(std::ptr::null(), 0, name.as_ptr()) };
        if unsafe { GetLastError() } != ERROR_ALREADY_EXISTS {
            break;
        }
        tries += 1;
        if !restart || tries > 50 {
            return;
        }
        unsafe { CloseHandle(h) };
        std::thread::sleep(std::time::Duration::from_millis(200));
    }

    let args: Vec<String> = std::env::args().collect();
    let port = args
        .iter()
        .position(|a| a == "--port")
        .and_then(|i| args.get(i + 1))
        .and_then(|p| p.parse().ok())
        .or_else(|| std::env::var("WATCHBRIDGE_PORT").ok().and_then(|p| p.parse().ok()))
        .unwrap_or(8765u16);
    let token = util::load_or_create_token();
    let _ = server::CONFIG.set(server::Config { port, token });

    log(format!("PC 遥控启动（版本 {}）", env!("CARGO_PKG_VERSION")));
    let status = match server::start(port) {
        Ok(()) => {
            log(format!("iPhone 遥控器：http://{}:{port}/remote?token=<token>", util::primary_ip()));
            Ok(())
        }
        Err(e) => {
            log(&e);
            let t = wide("PC 遥控");
            let m = wide(&format!("{e}\n\n可能已经有一个 PC 遥控在运行，或者 Mac 遥控的旧程序占用了端口。"));
            unsafe { MessageBoxW(std::ptr::null_mut(), m.as_ptr(), t.as_ptr(), MB_OK | MB_ICONWARNING) };
            Err(e)
        }
    };
    tray::run(status);
}
