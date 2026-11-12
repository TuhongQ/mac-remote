//! 中文语音指令（和 Mac 版同一套说法）、打开程序

use crate::input::{self, Button, Media};
use crate::util::wide;
use windows_sys::Win32::UI::Input::KeyboardAndMouse::{VK_BACK, VK_DOWN, VK_ESCAPE, VK_LEFT, VK_RETURN, VK_RIGHT, VK_UP};
use windows_sys::Win32::System::Com::{CoInitializeEx, COINIT_APARTMENTTHREADED, COINIT_DISABLE_OLE1DDE};
use windows_sys::Win32::UI::Shell::ShellExecuteW;
use windows_sys::Win32::UI::WindowsAndMessaging::SW_SHOWNORMAL;

/// 中文名 / 别名 → 程序名（ShellExecute 能直接打开的名字或 URI）
const APP_ALIASES: &[(&str, &str)] = &[
    ("微信", "WeChat"),
    ("浏览器", "msedge"),
    ("edge", "msedge"),
    ("谷歌", "chrome"),
    ("谷歌浏览器", "chrome"),
    ("chrome", "chrome"),
    ("火狐", "firefox"),
    ("记事本", "notepad"),
    ("计算器", "calc"),
    ("画图", "mspaint"),
    ("文件", "explorer"),
    ("资源管理器", "explorer"),
    ("此电脑", "explorer"),
    ("设置", "ms-settings:"),
    ("系统设置", "ms-settings:"),
    ("任务管理器", "taskmgr"),
    ("终端", "wt"),
    ("命令行", "cmd"),
    ("命令提示符", "cmd"),
    ("控制面板", "control"),
    ("截图工具", "snippingtool"),
    ("word", "winword"),
    ("excel", "excel"),
    ("ppt", "powerpnt"),
    ("qq", "QQ"),
    ("钉钉", "DingTalk"),
    ("飞书", "Feishu"),
    ("vscode", "code"),
    ("代码编辑器", "code"),
    ("音乐", "mswindowsmusic:"),
    ("照片", "ms-photos:"),
    ("日历", "outlookcal:"),
    ("邮件", "outlookmail:"),
];

pub fn open_app(spoken: &str) -> bool {
    let key = spoken.trim().trim_matches(|c: char| c.is_ascii_punctuation() || "。，！？".contains(c));
    if key.is_empty() {
        return false;
    }
    let lower = key.to_lowercase();
    let name = APP_ALIASES
        .iter()
        .find(|(k, _)| *k == lower || *k == key)
        .map(|(_, v)| v.to_string())
        .unwrap_or_else(|| key.to_string());
    // ShellExecute 要求线程初始化过 COM，而且有时候会卡很久（找程序、弹「选择打开方式」）。
    // 放到单独的线程里，最多等 4 秒，不让它卡住后面的鼠标键盘
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let op = wide("open");
        let file = wide(&name);
        let r = unsafe {
            CoInitializeEx(std::ptr::null(), (COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE) as u32);
            ShellExecuteW(std::ptr::null_mut(), op.as_ptr(), file.as_ptr(), std::ptr::null(), std::ptr::null(), SW_SHOWNORMAL)
        };
        let _ = tx.send(r as isize > 32);
    });
    rx.recv_timeout(std::time::Duration::from_secs(4)).unwrap_or(true)
}

fn clean(s: &str) -> String {
    let mut t = s.trim().to_string();
    while t.ends_with(|c: char| "。，！？.,!? ".contains(c)) {
        t.pop();
    }
    t
}

fn strip_prefix<'a>(s: &'a str, prefixes: &[&str]) -> Option<&'a str> {
    prefixes.iter().find_map(|p| s.strip_prefix(p)).map(|r| r.trim())
}

/// 返回 (成功?, 回复文字)
pub fn run(raw: &str) -> (bool, String) {
    let s = clean(raw);
    let lower = s.to_lowercase();

    if let Some(rest) = strip_prefix(&s, &["输入", "打字", "键入"]) {
        input::type_text(rest);
        return (true, "已输入".into());
    }
    if let Some(rest) = strip_prefix(&s, &["打开", "启动", "运行"]) {
        return if open_app(rest) { (true, format!("已打开 {rest}")) } else { (false, format!("找不到程序：{rest}")) };
    }
    if let Some(rest) = strip_prefix(&s, &["搜索", "查找"]) {
        input::press_combo("cmd+space");
        std::thread::sleep(std::time::Duration::from_millis(400));
        input::type_text(rest);
        return (true, "已在 Windows 搜索里搜索".into());
    }
    if let Some(rest) = strip_prefix(&s, &["按键", "按下"]) {
        return if input::press_combo(rest) { (true, format!("已按 {rest}")) } else { (false, format!("不认识这个按键：{rest}")) };
    }

    // 关键词 → 动作，按顺序匹配，较长 / 较具体的放前面（和 Mac 版一致）
    type Act = fn();
    let table: &[(&[&str], Act, &str)] = &[
        (&["下一首", "下一曲"], || input::media(Media::Next), "下一首"),
        (&["上一首", "上一曲"], || input::media(Media::Previous), "上一首"),
        (&["暂停", "播放", "继续播放"], || input::media(Media::PlayPause), "播放/暂停"),
        (&["取消静音", "静音"], || input::media(Media::Mute), "静音切换"),
        (&["音量调大", "大声", "调大音量", "音量加"], || for _ in 0..3 { input::media(Media::VolumeUp) }, "音量 +"),
        (&["音量调小", "小声", "调小音量", "音量减"], || for _ in 0..3 { input::media(Media::VolumeDown) }, "音量 -"),
        (&["全屏"], || { input::press_combo("ctrl+cmd+f"); }, "全屏切换"),
        (&["关闭窗口", "关掉窗口"], || { input::press_combo("cmd+w"); }, "已关闭窗口"),
        (&["退出应用", "退出程序", "退出"], || { input::press_combo("cmd+q"); }, "已退出"),
        (&["新标签", "新建标签"], || { input::press_combo("cmd+t"); }, "新标签页"),
        (&["新窗口", "新建窗口"], || { input::press_combo("cmd+n"); }, "新窗口"),
        (&["切换应用", "切换窗口", "上一个应用"], || { input::press_combo("cmd+tab"); }, "已切换"),
        (&["截图", "截屏"], || { input::press_combo("cmd+shift+3"); }, "已截图（保存在图片 → 屏幕截图）"),
        (&["锁屏", "锁定屏幕"], || { input::press_combo("ctrl+cmd+q"); }, "已锁屏"),
        (&["聚焦", "spotlight", "开始菜单"], || { input::press_combo("cmd+space"); }, "已打开搜索"),
        (&["显示桌面", "回到桌面"], || { input::press_combo("win+d"); }, "显示桌面"),
        (&["任务视图", "调度中心"], || { input::press_combo("win+tab"); }, "任务视图"),
        (&["全选"], || { input::press_combo("cmd+a"); }, "全选"),
        (&["复制"], || { input::press_combo("cmd+c"); }, "已复制"),
        (&["粘贴"], || { input::press_combo("cmd+v"); }, "已粘贴"),
        (&["剪切"], || { input::press_combo("cmd+x"); }, "已剪切"),
        (&["撤销"], || { input::press_combo("cmd+z"); }, "已撤销"),
        (&["保存"], || { input::press_combo("cmd+s"); }, "已保存"),
        (&["刷新"], || { input::press_combo("f5"); }, "已刷新"),
        (&["删除", "退格"], || input::tap_key(VK_BACK), "删除"),
        (&["回车", "确认", "确定", "发送"], || input::tap_key(VK_RETURN), "回车"),
        (&["返回", "取消"], || input::tap_key(VK_ESCAPE), "Esc"),
        (&["双击"], || { input::click(Button::Left); input::click(Button::Left); }, "双击"),
        (&["右键", "右击"], || input::click(Button::Right), "右键"),
        (&["点击", "单击", "左键"], || input::click(Button::Left), "点击"),
        (&["向下滚动", "往下滚", "下滚"], || input::scroll_lines(-8), "向下滚动"),
        (&["向上滚动", "往上滚", "上滚"], || input::scroll_lines(8), "向上滚动"),
        (&["鼠标左移", "光标左移", "鼠标向左"], || input::move_by(-150.0, 0.0), "←"),
        (&["鼠标右移", "光标右移", "鼠标向右"], || input::move_by(150.0, 0.0), "→"),
        (&["鼠标上移", "光标上移", "鼠标向上"], || input::move_by(0.0, -150.0), "↑"),
        (&["鼠标下移", "光标下移", "鼠标向下"], || input::move_by(0.0, 150.0), "↓"),
        (&["向左"], || input::tap_key(VK_LEFT), "←"),
        (&["向右"], || input::tap_key(VK_RIGHT), "→"),
        (&["向上"], || input::tap_key(VK_UP), "↑"),
        (&["向下"], || input::tap_key(VK_DOWN), "↓"),
    ];
    for (words, act, reply) in table {
        if words.iter().any(|w| lower.contains(w)) {
            act();
            return (true, reply.to_string());
        }
    }
    if lower.contains("亮度") || lower.contains("调亮") || lower.contains("调暗") {
        return (false, "Windows 版暂不支持调亮度".into());
    }
    (false, format!("没听懂：{s}"))
}
