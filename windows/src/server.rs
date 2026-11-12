//! 极简 HTTP / WebSocket 服务（和 Mac 版同样的接口和消息，网页遥控器直接复用）

use std::collections::HashMap;
use std::io::{ErrorKind, Read, Write};
use std::net::{Shutdown, TcpListener, TcpStream};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant};

use base64::Engine;
use serde_json::{json, Value};

use crate::commands;
use crate::input::{self, Button, INPUT_LOCK};
use crate::util::log;

pub struct Config {
    pub port: u16,
    pub token: String,
}
pub static CONFIG: OnceLock<Config> = OnceLock::new();
fn cfg() -> &'static Config {
    CONFIG.get().expect("config")
}

/// 网页：开发时可以用环境变量 WATCHBRIDGE_WEB 指向 web 目录，否则用编译进程序的那份
pub fn page() -> Vec<u8> {
    if let Ok(dir) = std::env::var("WATCHBRIDGE_WEB") {
        if let Ok(b) = std::fs::read(std::path::Path::new(&dir).join("remote.html")) {
            return b;
        }
    }
    include_bytes!("../../web/remote.html").to_vec()
}

/// 网页指纹：网页变了，已经打开的设备重连时会自动刷新
fn page_hash() -> String {
    sha1_smol::Sha1::from(page()).digest().to_string()[..12].to_string()
}

// ---------- HTTP ----------

struct Request {
    method: String,
    path: String,
    query: HashMap<String, String>,
    headers: HashMap<String, String>,
    body: Vec<u8>,
    extra: Vec<u8>, // 请求后面已经读进来的字节（下一个请求或 WebSocket 数据）
}

fn url_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        match b[i] {
            b'+' => out.push(b' '),
            b'%' if i + 2 < b.len() => {
                if let Ok(v) = u8::from_str_radix(&s[i + 1..i + 3], 16) {
                    out.push(v);
                    i += 2;
                } else {
                    out.push(b'%');
                }
            }
            c => out.push(c),
        }
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// 读一个完整的请求（头 + Content-Length 指定的请求体）
fn read_request(stream: &mut TcpStream, buf: &mut Vec<u8>) -> Option<Request> {
    let mut tmp = [0u8; 16384];
    loop {
        if let Some(end) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            let head = String::from_utf8_lossy(&buf[..end]).into_owned();
            let mut lines = head.split("\r\n");
            let first = lines.next()?;
            let mut it = first.split(' ');
            let method = it.next()?.to_string();
            let target = it.next()?.to_string();
            let mut headers = HashMap::new();
            for l in lines {
                if let Some((k, v)) = l.split_once(':') {
                    headers.insert(k.trim().to_ascii_lowercase(), v.trim().to_string());
                }
            }
            let len: usize = headers.get("content-length").and_then(|v| v.parse().ok()).unwrap_or(0);
            if len > 1_000_000 {
                return None;
            }
            while buf.len() < end + 4 + len {
                let n = stream.read(&mut tmp).ok()?;
                if n == 0 {
                    return None;
                }
                buf.extend_from_slice(&tmp[..n]);
            }
            let body = buf[end + 4..end + 4 + len].to_vec();
            let extra = buf[end + 4 + len..].to_vec();
            let (path, q) = target.split_once('?').unwrap_or((&target, ""));
            let query = q
                .split('&')
                .filter_map(|kv| kv.split_once('=').map(|(k, v)| (url_decode(k), url_decode(v))))
                .collect();
            return Some(Request { method, path: url_decode(path), query, headers, body, extra });
        }
        if buf.len() > 1_000_000 {
            return None;
        }
        let n = stream.read(&mut tmp).ok()?;
        if n == 0 {
            return None;
        }
        buf.extend_from_slice(&tmp[..n]);
    }
}

fn respond(stream: &mut TcpStream, status: u16, body: &[u8], ctype: &str, keep_alive: bool) {
    let reason = match status {
        200 => "OK",
        400 => "Bad Request",
        401 => "Unauthorized",
        404 => "Not Found",
        422 => "Unprocessable",
        _ => "OK",
    };
    let head = format!(
        "HTTP/1.1 {status} {reason}\r\nContent-Type: {ctype}\r\nCache-Control: no-store\r\nContent-Length: {}\r\nConnection: {}\r\n\r\n",
        body.len(),
        if keep_alive { "keep-alive" } else { "close" }
    );
    let _ = stream.write_all(head.as_bytes());
    let _ = stream.write_all(body);
}

fn text(stream: &mut TcpStream, status: u16, s: &str) {
    respond(stream, status, s.as_bytes(), "text/plain; charset=utf-8", false);
}

fn authorized(req: &Request) -> bool {
    let t = &cfg().token;
    req.headers.get("authorization").map(|a| a == &format!("Bearer {t}")).unwrap_or(false)
        || req.query.get("token") == Some(t)
}

/// 请求体里取文字：JSON 的某个字段，或者整个请求体就是纯文本
fn body_value(req: &Request, keys: &[&str]) -> String {
    if let Ok(v) = serde_json::from_slice::<Value>(&req.body) {
        for k in keys {
            if let Some(s) = v.get(*k).and_then(|x| x.as_str()) {
                return s.to_string();
            }
        }
    }
    for k in keys {
        if let Some(s) = req.query.get(*k) {
            return s.clone();
        }
    }
    String::from_utf8_lossy(&req.body).trim().to_string()
}

pub fn start(port: u16) -> Result<(), String> {
    let listener = TcpListener::bind(("0.0.0.0", port)).map_err(|e| {
        if e.kind() == ErrorKind::AddrInUse { format!("端口 {port} 被别的程序占用") } else { format!("监听失败：{e}") }
    })?;
    log(format!("网页遥控已启动，端口 {port}"));
    thread::spawn(move || {
        for s in listener.incoming().flatten() {
            thread::spawn(move || handle_conn(s));
        }
    });
    Ok(())
}

fn handle_conn(mut stream: TcpStream) {
    let _ = stream.set_nodelay(true);
    let ip = stream.peer_addr().map(|a| a.ip().to_string()).unwrap_or_else(|_| "?".into());
    let mut buf = Vec::new();
    loop {
        let Some(req) = read_request(&mut stream, &mut buf) else { return };
        buf = req.extra.clone();
        match req.path.as_str() {
            "/ping" => return text(&mut stream, 200, "pong"),
            p if p.starts_with("/favicon") || p.starts_with("/apple-touch-icon") => return text(&mut stream, 404, ""),
            "/" | "/remote" => return respond(&mut stream, 200, &page(), "text/html; charset=utf-8", false),
            "/ca.cer" => return text(&mut stream, 404, "Windows 版还没有 HTTPS（下一步开发）"),
            "/ws" => {
                let key = req.headers.get("sec-websocket-key").cloned();
                let upgrade = req.headers.get("upgrade").map(|u| u.eq_ignore_ascii_case("websocket")).unwrap_or(false);
                match (upgrade, key) {
                    (true, Some(k)) => return websocket(stream, &k, authorized(&req), ip, req.extra),
                    _ => return text(&mut stream, 400, "需要 WebSocket"),
                }
            }
            _ => {}
        }
        if !authorized(&req) {
            log(format!("拒绝 {ip} {}：token 不对", req.path));
            return text(&mut stream, 401, "token 不对");
        }
        let _ = &req.method;
        match req.path.as_str() {
            "/type" => {
                let t = body_value(&req, &["text"]);
                if t.is_empty() {
                    return text(&mut stream, 400, "没有文字");
                }
                let _g = INPUT_LOCK.lock();
                input::type_text(&t);
                log(format!("{ip} 输入：{t}"));
                return text(&mut stream, 200, "已输入");
            }
            "/key" => {
                let k = body_value(&req, &["key", "text"]);
                let _g = INPUT_LOCK.lock();
                return if input::press_combo(&k) {
                    text(&mut stream, 200, &format!("已按 {k}"))
                } else {
                    text(&mut stream, 422, &format!("不认识这个按键：{k}"))
                };
            }
            "/command" => {
                let t = body_value(&req, &["text", "command"]);
                let (ok, reply) = {
                    let _g = INPUT_LOCK.lock();
                    commands::run(&t)
                };
                log(format!("{ip} 指令：{t} -> {reply}"));
                return text(&mut stream, if ok { 200 } else { 422 }, &reply);
            }
            "/batch" => {
                // 手表用：一次带多条遥控消息，连接保持复用
                let v: Value = serde_json::from_slice(&req.body).unwrap_or(Value::Null);
                let events = v.as_array().cloned().or_else(|| v.get("events").and_then(|e| e.as_array()).cloned()).unwrap_or_default();
                let mut replies = Vec::new();
                note_batch(&ip);
                for e in &events {
                    handle_message(e, &ip, &mut |r| replies.push(r));
                }
                let body = json!({"ok": true, "replies": replies}).to_string();
                respond(&mut stream, 200, body.as_bytes(), "application/json", true);
                continue;
            }
            _ => return text(&mut stream, 404, "没有这个接口"),
        }
    }
}

static LAST_BATCH: Mutex<Option<HashMap<String, Instant>>> = Mutex::new(None);

/// 手表 3 秒没新消息就松开按住的鼠标键
fn note_batch(ip: &str) {
    let mut m = LAST_BATCH.lock().unwrap();
    m.get_or_insert_with(HashMap::new).insert(ip.to_string(), Instant::now());
    drop(m);
    let ip = ip.to_string();
    thread::spawn(move || {
        thread::sleep(Duration::from_secs(3));
        let m = LAST_BATCH.lock().unwrap();
        if let Some(t) = m.as_ref().and_then(|m| m.get(&ip)) {
            if t.elapsed() >= Duration::from_millis(2900) {
                input::release_held();
            }
        }
    });
}

// ---------- 遥控消息 ----------

fn num(v: &Value, k: &str) -> f64 {
    v.get(k).and_then(|x| x.as_f64().or_else(|| x.as_str().and_then(|s| s.parse().ok()))).unwrap_or(0.0)
}
fn s<'a>(v: &'a Value, k: &str) -> Option<&'a str> {
    v.get(k).and_then(|x| x.as_str())
}

/// 执行一条遥控消息（输入动作），格式见 docs/开发说明.md 第 5 节
pub fn handle_message(m: &Value, ip: &str, reply: &mut dyn FnMut(Value)) {
    let _g = INPUT_LOCK.lock();
    match s(m, "t").unwrap_or("") {
        "move" => input::move_by(num(m, "dx"), num(m, "dy")),
        "moveTo" => {
            let (x, y) = input::point_in_primary(num(m, "x"), num(m, "y"));
            input::move_to(x, y);
        }
        "click" => input::click(Button::from(s(m, "b"))),
        "clickAt" => {
            let (x, y) = input::point_in_primary(num(m, "x"), num(m, "y"));
            input::move_to(x, y);
            thread::sleep(Duration::from_millis(15));
            input::click(Button::from(s(m, "b")));
        }
        "down" => input::button(Button::from(s(m, "b")), true),
        "up" => input::button(Button::from(s(m, "b")), false),
        "pen" => {
            // 绝对位置按住拖：p = 0 落笔 / 1 移动 / 2 抬笔
            let (x, y) = input::point_in_primary(num(m, "x"), num(m, "y"));
            match num(m, "p") as i32 {
                0 => {
                    input::release_held();
                    input::move_to(x, y);
                    thread::sleep(Duration::from_millis(8));
                    input::button(Button::Left, true);
                }
                1 => input::move_to(x, y),
                _ => {
                    input::move_to(x, y);
                    input::button(Button::Left, false);
                }
            }
        }
        "scroll" => input::scroll(num(m, "dx"), num(m, "dy")),
        "key" => {
            let k = s(m, "key").unwrap_or("");
            if !input::press_combo(k) {
                reply(json!({"t": "reply", "ok": false, "text": format!("不认识这个按键：{k}")}));
            }
        }
        "text" => {
            let t = s(m, "text").unwrap_or("");
            if t.is_empty() {
                return;
            }
            if m.get("paste").and_then(|x| x.as_bool()) == Some(true) {
                input::paste_text(t);
            } else {
                input::type_text(t);
            }
            log(format!("{ip} 输入：{t}"));
        }
        "cmd" => {
            let t = s(m, "text").unwrap_or("");
            let (ok, ans) = commands::run(t);
            log(format!("{ip} 指令：{t} -> {ans}"));
            if m.get("quiet").and_then(|x| x.as_bool()) != Some(true) || !ok {
                reply(json!({"t": "reply", "ok": ok, "text": ans}));
            }
        }
        "mission" => {
            input::press_combo("win+tab");
        }
        "ping" => reply(json!({"t": "pong", "id": m.get("id").cloned().unwrap_or(json!(0))})),
        _ => {}
    }
}

// ---------- WebSocket ----------

struct Ws {
    out: Mutex<TcpStream>,
}

impl Ws {
    fn frame(&self, opcode: u8, payload: &[u8]) -> bool {
        let mut f = vec![0x80 | opcode];
        let n = payload.len();
        if n < 126 {
            f.push(n as u8);
        } else if n < 65536 {
            f.push(126);
            f.extend_from_slice(&(n as u16).to_be_bytes());
        } else {
            f.push(127);
            f.extend_from_slice(&(n as u64).to_be_bytes());
        }
        f.extend_from_slice(payload);
        self.out.lock().map(|mut o| o.write_all(&f).is_ok()).unwrap_or(false)
    }
    fn send(&self, v: &Value) {
        self.frame(0x1, v.to_string().as_bytes());
    }
}

fn websocket(mut stream: TcpStream, key: &str, ok: bool, ip: String, leftover: Vec<u8>) {
    let mut h = sha1_smol::Sha1::new();
    h.update(key.as_bytes());
    h.update(b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
    let accept = base64::engine::general_purpose::STANDARD.encode(h.digest().bytes());
    let head = format!("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n");
    if stream.write_all(head.as_bytes()).is_err() {
        return;
    }
    let Ok(out) = stream.try_clone() else { return };
    let ws = Arc::new(Ws { out: Mutex::new(out) });
    if !ok {
        // 先升级再报错，网页才能拿到原因
        log(format!("拒绝遥控 {ip}：token 不对"));
        ws.send(&json!({"t": "error", "text": "token 不对"}));
        ws.frame(0x8, &[0x0F, 0xA1]); // 关闭码 4001
        let _ = stream.shutdown(Shutdown::Both);
        return;
    }
    log(format!("遥控已连接：{ip}"));
    ws.send(&json!({"t": "hello", "https": 0, "page": page_hash(), "os": "windows", "screen": false}));

    // 30 秒没收到任何消息（网页每 3 秒 ping 一次）就当断开
    let _ = stream.set_read_timeout(Some(Duration::from_secs(30)));
    let mut buf = leftover;
    let mut tmp = [0u8; 65536];
    let mut message: Vec<u8> = Vec::new();
    let mut msg_op = 0u8;
    'outer: loop {
        // 解析缓冲区里完整的帧
        loop {
            if buf.len() < 2 {
                break;
            }
            let (b0, b1) = (buf[0], buf[1]);
            let fin = b0 & 0x80 != 0;
            let opcode = b0 & 0x0F;
            let masked = b1 & 0x80 != 0;
            let mut len = (b1 & 0x7F) as usize;
            let mut off = 2;
            if len == 126 {
                if buf.len() < 4 {
                    break;
                }
                len = u16::from_be_bytes([buf[2], buf[3]]) as usize;
                off = 4;
            } else if len == 127 {
                if buf.len() < 10 {
                    break;
                }
                len = u64::from_be_bytes(buf[2..10].try_into().unwrap()) as usize;
                off = 10;
            }
            if len > 1_000_000 {
                break 'outer;
            }
            let mask_at = off;
            if masked {
                off += 4;
            }
            if buf.len() < off + len {
                break;
            }
            let mut payload = buf[off..off + len].to_vec();
            if masked {
                for (i, b) in payload.iter_mut().enumerate() {
                    *b ^= buf[mask_at + i % 4];
                }
            }
            buf.drain(..off + len);
            match opcode {
                0x8 => {
                    ws.frame(0x8, &payload[..payload.len().min(2)]);
                    break 'outer;
                }
                0x9 => {
                    ws.frame(0xA, &payload);
                }
                0xA => {}
                0x0 | 0x1 | 0x2 => {
                    if opcode != 0 {
                        msg_op = opcode;
                        message.clear();
                    }
                    message.extend_from_slice(&payload);
                    if fin {
                        if msg_op == 0x1 {
                            if let Ok(v) = serde_json::from_slice::<Value>(&message) {
                                on_ws_message(&v, &ws, &ip);
                            }
                        }
                        message.clear();
                    }
                }
                _ => break 'outer,
            }
        }
        match stream.read(&mut tmp) {
            Ok(0) => break,
            Ok(n) => buf.extend_from_slice(&tmp[..n]),
            Err(e) if e.kind() == ErrorKind::Interrupted => continue,
            Err(e) => {
                if e.kind() == ErrorKind::WouldBlock || e.kind() == ErrorKind::TimedOut {
                    log(format!("遥控 {ip} 30 秒没有动静，断开"));
                }
                break;
            }
        }
    }
    log(format!("遥控已断开：{ip}"));
    let _ = stream.shutdown(Shutdown::Both);
    let _g = INPUT_LOCK.lock();
    input::release_held();
}

fn on_ws_message(m: &Value, ws: &Arc<Ws>, ip: &str) {
    match s(m, "t").unwrap_or("") {
        "screen" => {
            if m.get("on").and_then(|x| x.as_bool()) == Some(true) {
                ws.send(&json!({"t": "screen", "ok": false, "text": "Windows 版看屏幕功能还在开发中"}));
            }
        }
        "screenAck" | "screenKey" | "focusCheck" | "axAt" | "hitAt" => {}
        "client" => log(format!(
            "{ip} 设备：{}，{}，{}",
            s(m, "dev").unwrap_or("?"),
            s(m, "ua").unwrap_or(""),
            s(m, "geo").unwrap_or("")
        )),
        "vstat" | "vlog" => log(format!("{ip} {}", m)),
        _ => {
            let ws = ws.clone();
            handle_message(m, ip, &mut |r| ws.send(&r));
        }
    }
}
