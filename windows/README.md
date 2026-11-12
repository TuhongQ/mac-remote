# PC 遥控（Windows 版）

用 iPhone / iPad 遥控 **Windows 电脑**。和 Mac 版（本仓库根目录）用的是**同一个网页遥控器、同一套通信协议**，手机这边的操作完全一样。

> 开发进度：**第 1 步**（托盘程序、连接、鼠标、键盘、打字、手势、语音指令）已完成，等待在 Windows 电脑上实测。
> 第 2 步：看屏幕（图片 / H.264 视频模式、HTTPS 证书）。第 3 步：iPad 触摸屏模式细节、Pencil 手写板、安装包。

---

## 使用

### 运行

1. 把 `PCRemote.exe` 放到一个固定的位置（比如 `C:\Program Files\PCRemote\` 或「文档」里），双击运行
2. 第一次运行时：
   - **Windows 防火墙**会问是否允许它在网络上通信 → 勾选「专用网络」，点「允许」（不允许的话手机连不上）
   - 默认浏览器会打开一个二维码页面
   - 自动设为开机启动（托盘菜单里可以关）
3. 手机和电脑连同一个 Wi-Fi，用手机相机扫二维码，用 Safari 打开
4. Safari「分享 → 添加到主屏幕」

程序没有窗口，只在任务栏右下角的托盘里有个图标（可能收在「^」里）。左键或右键点它弹出菜单：

| 菜单 | 作用 |
|---|---|
| ✅ 网页遥控：IP:8765 | 当前地址；端口被占用时显示原因 |
| 用 iPhone 扫码打开网页遥控器… | 浏览器里显示二维码 |
| 复制网页遥控链接 | 带 token 的链接复制到剪贴板 |
| 使用说明… | 打开本说明 |
| 开机自动启动 | 写在 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` |
| 打开日志 | `%LOCALAPPDATA%\WatchBridge\watchbridge.log` |
| 退出 PC 遥控 | |

### 手势和按键

手势、键盘、语音指令和 Mac 版一样，见 [使用说明](../docs/使用说明.md) 第 6、7、15 节。网页连上 Windows 时会把按钮上的说法换成 Windows 的。按键的对应关系：

| 手机上 | Windows 上实际执行 |
|---|---|
| ⌘ + 字母（复制、粘贴、全选……） | Ctrl + 字母 |
| 四指左右滑 / 「◀ 桌面」「桌面 ▶」 | Win+Ctrl+← / → 切换虚拟桌面 |
| 四指上下滑 / 「任务视图」 | Win+Tab |
| 显示桌面 | Win+D |
| 搜索（原「聚焦」）、语音「搜索 xxx」 | Win+S |
| 切输入法 | Win+空格 |
| 切换应用 | Alt+Tab |
| 关闭程序（原「退出 App」） | Alt+F4 |
| 全屏 | F11 |
| 截图 | Win+Shift+S（选区域）；语音「截图」= Win+PrintScreen（保存到 图片\屏幕截图） |
| 后退 / 前进 | Alt+← / → |
| 语音「锁屏」 | 系统锁屏 |
| 媒体键、音量 | 播放 / 暂停、上一首 / 下一首、静音、音量 ± |
| 亮度 | 暂不支持 |

语音「打开 xxx」认识的中文名：浏览器（Edge）、谷歌浏览器、火狐、微信、QQ、钉钉、飞书、记事本、计算器、画图、文件 / 资源管理器、设置、任务管理器、终端、命令行、控制面板、截图工具、Word、Excel、PPT、VS Code、音乐、照片、日历、邮件；其他名字会直接交给 Windows 去找。

### 和 Mac 版的区别（现在）

- 还不能看屏幕（第 2 步）
- 滚动用的是滚轮事件（支持平滑滚动），没有 Mac 触控板那种滚动阶段，回弹手感会略有不同
- 不支持调亮度、iPhone 自带的「Apple TV 遥控器」
- iPad 全屏时不能像 Mac 那样临时改成 iPad 的屏幕比例（Windows 建虚拟显示器要装驱动）

### 文件位置

| | |
|---|---|
| token | `%APPDATA%\WatchBridge\token`（删掉后重启程序会生成新的） |
| 日志 | `%LOCALAPPDATA%\WatchBridge\watchbridge.log` |

参数：`PCRemote.exe --port 8765`（或环境变量 `WATCHBRIDGE_PORT`）；`WATCHBRIDGE_TOKEN` 指定 token；`WATCHBRIDGE_WEB` 指向网页目录（开发用）。

---

## 开发

Rust 写的，不依赖 .NET 或 VC++ 运行库，编译出来是单个 exe（网页 `../web/remote.html` 编译时嵌进去）。

| 文件 | 内容 |
|---|---|
| `src/main.rs` | 启动：DPI 感知、单实例、读端口和 token、启动服务、托盘 |
| `src/server.rs` | HTTP（/remote、/type、/key、/command、/batch）、WebSocket、遥控消息处理 |
| `src/input.rs` | SendInput：绝对坐标移动光标、按键（含扩展键标志）、Unicode 打字、滚轮、剪贴板粘贴、媒体键；Mac 按键名 → Windows 组合键的翻译表 |
| `src/commands.rs` | 中文语音指令、打开程序（ShellExecute + 别名表） |
| `src/tray.rs` | 托盘图标和菜单、二维码页面、开机启动 |
| `src/util.rs` | 配置目录、token、日志、本机 IP |

### 在 Windows 上编译

```powershell
# 装 Rust：https://rustup.rs
cd windows
cargo build --release
# 结果：target\release\PCRemote.exe
```

### 在 Mac 上交叉编译

```bash
rustup target add x86_64-pc-windows-gnu
cargo check --target x86_64-pc-windows-gnu      # 只检查，不需要链接器
# 出 exe 需要 MinGW 链接器：用 Zig 当链接器最省事
cargo install cargo-zigbuild                     # 并装好 zig（https://ziglang.org/download/）
cargo zigbuild --release --target x86_64-pc-windows-gnu
# 结果：target/x86_64-pc-windows-gnu/release/PCRemote.exe
```

实现要点：

- 进程设为 **Per-Monitor DPI 感知 V2**：光标、显示器坐标都用物理像素；网页发来的相对位移按系统缩放比例换成像素
- 光标用**绝对坐标**移动（`MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK`），不受「提高指针精确度」影响；按住鼠标键时移动就是拖动
- 打字用 `KEYEVENTF_UNICODE`，不经过输入法；方向键等要加 `KEYEVENTF_EXTENDEDKEY`
- 锁屏不能模拟 Win+L，用 `LockWorkStation()`
- 滚动：网页的「像素」× 2.4 = 滚轮单位（一格 120），不足一格的值就是平滑滚动；方向和 Mac 版自然滚动一致
- 所有输入在一把全局锁下串行执行，防止多台设备的字交错
- WebSocket 连上先发 `{"t":"hello","os":"windows","screen":false,…}`，网页据此换按钮说法、隐藏屏幕按钮
