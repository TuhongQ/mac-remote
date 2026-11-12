//! 看屏幕：GDI 截主显示器 → 缩放 → 画上光标 → JPEG 图片，或 H.264 视频（OpenH264）→ WebSocket 二进制帧
//!
//! 和 Mac 版一样按回执控制节奏：手机每显示完一帧回一个 screenAck，没回执的帧最多 2 个，
//! 网络慢时自动降帧，不会越积越卡。画面没变化时不发。

use std::collections::HashMap;
use std::sync::{Arc, Condvar, Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant};

use windows_sys::Win32::Foundation::{HWND, POINT};
use windows_sys::Win32::Graphics::Gdi::{
    BitBlt, CreateCompatibleDC, CreateDIBSection, DeleteDC, DeleteObject, GetDC, ReleaseDC, SelectObject,
    SetBrushOrgEx, SetStretchBltMode, StretchBlt, BITMAPINFO, BITMAPINFOHEADER, BI_RGB, DIB_RGB_COLORS, HALFTONE,
    HBITMAP, HDC, HGDIOBJ, SRCCOPY,
};
use windows_sys::Win32::UI::WindowsAndMessaging::{
    DrawIconEx, GetCursorInfo, GetIconInfo, CURSORINFO, CURSOR_SHOWING, DI_NORMAL, ICONINFO,
};

use crate::h264::H264;
use crate::input::{dpi_scale, primary_bounds};
use crate::util::log;

const MAX_INFLIGHT: u32 = 2;

pub type SendBin = Box<dyn Fn(&[u8]) -> bool + Send + Sync>;

struct State {
    width: u32,
    fps: u32,
    inflight: u32,
    alive: bool,
    gen: u64, // 每次重新订阅 +1：网页清空了画布 / 解码器，要从头（关键帧）发
    video: bool,
    want_key: bool, // 手机要一个关键帧
}

struct Sub {
    st: Mutex<State>,
    cv: Condvar,
    send: SendBin,
}

fn subs() -> &'static Mutex<HashMap<usize, Arc<Sub>>> {
    static S: OnceLock<Mutex<HashMap<usize, Arc<Sub>>>> = OnceLock::new();
    S.get_or_init(|| Mutex::new(HashMap::new()))
}

/// 主显示器的逻辑尺寸（物理像素 ÷ 缩放比例），网页拿它换算触摸模式下的滚动距离
pub fn info() -> (i32, i32) {
    let r = primary_bounds();
    let k = dpi_scale();
    ((((r.right - r.left) as f64) / k).round() as i32, (((r.bottom - r.top) as f64) / k).round() as i32)
}

/// 开始 / 更新看屏幕。key = 这条连接的标识
pub fn subscribe(key: usize, width: u32, fps: u32, video: bool, send: impl FnOnce() -> SendBin) {
    // 视频最宽 2560（软件编码，再大太吃 CPU）；图片最宽 1920
    let width = width.clamp(320, if video { 2560 } else { 1920 });
    let fps = if fps == 0 { 30 } else { fps.clamp(2, 60) };
    let mut map = subs().lock().unwrap();
    if let Some(sub) = map.get(&key) {
        let mut st = sub.st.lock().unwrap();
        st.width = width;
        st.fps = fps;
        st.inflight = 0;
        st.gen += 1;
        st.video = video;
        sub.cv.notify_all();
        return;
    }
    let sub = Arc::new(Sub {
        st: Mutex::new(State { width, fps, inflight: 0, alive: true, gen: 1, video, want_key: false }),
        cv: Condvar::new(),
        send: send(),
    });
    map.insert(key, sub.clone());
    log(format!("屏幕镜像已开始（最宽 {width} 像素，最多 {fps} 帧/秒，{}）", if video { "视频" } else { "图片" }));
    thread::spawn(move || worker(sub));
}

pub fn ack(key: usize) {
    if let Some(sub) = subs().lock().unwrap().get(&key) {
        let mut st = sub.st.lock().unwrap();
        st.inflight = st.inflight.saturating_sub(1);
        sub.cv.notify_all();
    }
}

/// 手机要一个关键帧（它清空了解码器）
pub fn request_key(key: usize) {
    if let Some(sub) = subs().lock().unwrap().get(&key) {
        sub.st.lock().unwrap().want_key = true;
        sub.cv.notify_all();
    }
}

pub fn unsubscribe(key: usize) {
    if let Some(sub) = subs().lock().unwrap().remove(&key) {
        sub.st.lock().unwrap().alive = false;
        sub.cv.notify_all();
        log("屏幕镜像已停止");
    }
}

fn worker(sub: Arc<Sub>) {
    let mut cap = Capturer::new();
    let mut last_hash = 0u64;
    let mut last_gen = 0u64;
    let mut fails = 0u32;
    let mut enc: Option<H264> = None;
    let mut refresh_left = 0u32; // 视频：画面停下后再补发两次同样的画面，让画质补清楚
    let mut last_sent = Instant::now();
    loop {
        // 等回执：没回执的帧太多就先不截。1 秒还没回执就当丢了
        let (width, fps, gen, video, want_key) = {
            let mut st = sub.st.lock().unwrap();
            while st.alive && st.inflight >= MAX_INFLIGHT {
                let (g, t) = sub.cv.wait_timeout(st, Duration::from_secs(1)).unwrap();
                st = g;
                if t.timed_out() {
                    st.inflight = 0;
                }
            }
            if !st.alive {
                return;
            }
            let k = std::mem::take(&mut st.want_key);
            (st.width, st.fps, st.gen, st.video, k)
        };
        let t0 = Instant::now();
        let interval = Duration::from_secs_f64(1.0 / fps as f64);
        match cap.grab(width) {
            Some((px, w, h)) => {
                fails = 0;
                let hash = fnv(&px);
                let changed = hash != last_hash || gen != last_gen;
                if changed {
                    refresh_left = 2;
                }
                let refresh = !changed && video && refresh_left > 0 && last_sent.elapsed() > Duration::from_millis(250);
                if changed || want_key || refresh {
                    if !changed && !want_key {
                        refresh_left -= 1;
                    }
                    let ok = if video {
                        // 重新订阅（手机建了新解码器）或尺寸变了：新编码器，从关键帧开始
                        if gen != last_gen || enc.as_ref().map_or(true, |e| e.width != w as usize || e.height != h as usize) {
                            enc = match H264::new(w as usize, h as usize, fps) {
                                Ok(e) => Some(e),
                                Err(e) => {
                                    log(format!("H.264 编码器创建失败：{e}"));
                                    None
                                }
                            };
                        }
                        match enc.as_mut() {
                            Some(e) => {
                                if want_key {
                                    e.force_key();
                                }
                                let first = e.codec_string() == "?";
                                match e.encode(&px) {
                                    Ok(packets) => {
                                        if first {
                                            log(format!("H.264 编码：{w}×{h}，{}，编一帧 {} ms", e.codec_string(), t0.elapsed().as_millis()));
                                        }
                                        let mut alive = true;
                                        for p in packets {
                                            if p[0] != 1 {
                                                sub.st.lock().unwrap().inflight += 1; // 帧要等回执，配置不用
                                            }
                                            alive &= (sub.send)(&p);
                                        }
                                        Some(alive)
                                    }
                                    Err(err) => {
                                        log(format!("H.264 编码失败：{err}"));
                                        enc = None;
                                        None
                                    }
                                }
                            }
                            None => None,
                        }
                    } else {
                        enc = None;
                        let q = if fps > 30 { 45 } else { 60 };
                        let mut jpg = Vec::with_capacity(px.len() / 10);
                        let e = jpeg_encoder::Encoder::new(&mut jpg, q);
                        if e.encode(&px, w as u16, h as u16, jpeg_encoder::ColorType::Bgra).is_ok() {
                            sub.st.lock().unwrap().inflight += 1;
                            Some((sub.send)(&jpg))
                        } else {
                            None
                        }
                    };
                    match ok {
                        Some(false) => return, // 连接断了
                        Some(true) => {
                            last_hash = hash;
                            last_gen = gen;
                            last_sent = Instant::now();
                        }
                        None => {}
                    }
                }
            }
            None => {
                // 锁屏、UAC 弹窗（安全桌面）时截不到，过会儿再试
                fails += 1;
                if fails == 1 {
                    log("截屏失败（可能在锁屏或 UAC 安全桌面），稍后重试");
                }
                cap = Capturer::new();
                thread::sleep(Duration::from_millis(500));
                continue;
            }
        }
        // 等到下一帧的时间；新订阅、要关键帧、断开就马上走（回执不提前叫醒，帧率不超过设定）
        let deadline = t0 + interval;
        let mut st = sub.st.lock().unwrap();
        while st.alive && st.gen == gen && !st.want_key {
            let now = Instant::now();
            if now >= deadline {
                break;
            }
            st = sub.cv.wait_timeout(st, deadline - now).unwrap().0;
        }
    }
}

/// 快速指纹（只用来判断画面有没有变），每 8 字节取一次
fn fnv(px: &[u8]) -> u64 {
    let mut h = 0xcbf29ce484222325u64;
    for c in px.chunks_exact(8) {
        h ^= u64::from_le_bytes(c.try_into().unwrap());
        h = h.wrapping_mul(0x100000001b3);
    }
    h
}

/// 一块 32 位 DIB（自上而下），像素直接能读
struct Dib {
    dc: HDC,
    bmp: HBITMAP,
    old: HGDIOBJ,
    bits: *mut u8,
    w: i32,
    h: i32,
}

impl Dib {
    unsafe fn new(screen: HDC, w: i32, h: i32) -> Option<Dib> {
        let mut bi: BITMAPINFO = std::mem::zeroed();
        bi.bmiHeader.biSize = std::mem::size_of::<BITMAPINFOHEADER>() as u32;
        bi.bmiHeader.biWidth = w;
        bi.bmiHeader.biHeight = -h; // 负数 = 第一行在最上面
        bi.bmiHeader.biPlanes = 1;
        bi.bmiHeader.biBitCount = 32;
        bi.bmiHeader.biCompression = BI_RGB;
        let dc = CreateCompatibleDC(screen);
        if dc.is_null() {
            return None;
        }
        let mut bits: *mut core::ffi::c_void = std::ptr::null_mut();
        let bmp = CreateDIBSection(dc, &bi, DIB_RGB_COLORS, &mut bits, std::ptr::null_mut(), 0);
        if bmp.is_null() || bits.is_null() {
            DeleteDC(dc);
            return None;
        }
        let old = SelectObject(dc, bmp);
        Some(Dib { dc, bmp, old, bits: bits as *mut u8, w, h })
    }
    fn pixels(&self) -> Vec<u8> {
        unsafe { std::slice::from_raw_parts(self.bits, (self.w * self.h * 4) as usize).to_vec() }
    }
}

impl Drop for Dib {
    fn drop(&mut self) {
        unsafe {
            SelectObject(self.dc, self.old);
            DeleteObject(self.bmp);
            DeleteDC(self.dc);
        }
    }
}

struct Capturer {
    screen: HDC,
    full: Option<Dib>,
    small: Option<Dib>,
}

// 每个看屏幕的连接自己的线程里用自己的 Capturer
unsafe impl Send for Capturer {}

impl Capturer {
    fn new() -> Capturer {
        Capturer { screen: unsafe { GetDC(0 as HWND) }, full: None, small: None }
    }

    /// 截主显示器，缩到不超过 max_w 宽。返回 BGRA 像素和宽高
    fn grab(&mut self, max_w: u32) -> Option<(Vec<u8>, i32, i32)> {
        if self.screen.is_null() {
            return None;
        }
        let r = primary_bounds();
        let (sw, sh) = (r.right - r.left, r.bottom - r.top);
        if sw <= 0 || sh <= 0 {
            return None;
        }
        unsafe {
            if self.full.as_ref().map_or(true, |d| d.w != sw || d.h != sh) {
                self.full = None;
                self.full = Dib::new(self.screen, sw, sh);
            }
            let full = self.full.as_ref()?;
            if BitBlt(full.dc, 0, 0, sw, sh, self.screen, r.left, r.top, SRCCOPY) == 0 {
                return None;
            }
            draw_cursor(full.dc, r.left, r.top);

            let tw = (sw.min(max_w as i32)) & !1;
            if tw >= sw {
                return Some((full.pixels(), sw, sh));
            }
            let th = (((tw as f64) * sh as f64 / sw as f64).round() as i32) & !1;
            if self.small.as_ref().map_or(true, |d| d.w != tw || d.h != th) {
                self.small = None;
                self.small = Dib::new(self.screen, tw, th);
            }
            let small = self.small.as_ref()?;
            SetStretchBltMode(small.dc, HALFTONE);
            SetBrushOrgEx(small.dc, 0, 0, std::ptr::null_mut());
            if StretchBlt(small.dc, 0, 0, tw, th, full.dc, 0, 0, sw, sh, SRCCOPY) == 0 {
                return None;
            }
            Some((small.pixels(), tw, th))
        }
    }
}

impl Drop for Capturer {
    fn drop(&mut self) {
        self.full = None;
        self.small = None;
        if !self.screen.is_null() {
            unsafe { ReleaseDC(0 as HWND, self.screen) };
        }
    }
}

/// GDI 截图里没有光标，自己画上去
unsafe fn draw_cursor(dc: HDC, ox: i32, oy: i32) {
    let mut ci: CURSORINFO = std::mem::zeroed();
    ci.cbSize = std::mem::size_of::<CURSORINFO>() as u32;
    if GetCursorInfo(&mut ci) == 0 || ci.flags & CURSOR_SHOWING == 0 || ci.hCursor.is_null() {
        return;
    }
    let mut ii: ICONINFO = std::mem::zeroed();
    if GetIconInfo(ci.hCursor, &mut ii) == 0 {
        return;
    }
    let p: POINT = ci.ptScreenPos;
    DrawIconEx(dc, p.x - ox - ii.xHotspot as i32, p.y - oy - ii.yHotspot as i32, ci.hCursor, 0, 0, 0, std::ptr::null_mut(), DI_NORMAL);
    if !ii.hbmMask.is_null() {
        DeleteObject(ii.hbmMask);
    }
    if !ii.hbmColor.is_null() {
        DeleteObject(ii.hbmColor);
    }
}
