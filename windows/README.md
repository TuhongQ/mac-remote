# PC 遥控（Windows 版）

用 iPhone 或 iPad 在同一局域网内遥控 Windows 电脑。网页遥控器和 Mac 版共用界面。

## 下载和使用

支持 Windows 10/11 x64。在 [GitHub 发布页](https://github.com/TuhongQ/mac-remote/releases/tag/windows-v0.1.0) 下载安装版，或下载免安装 ZIP 并解压到固定目录。安装版默认安装在当前用户目录，保留免安装版的两个程序。

1. 启动「PC Remote」或双击 `PCRemote.exe`。更新旧版前，从托盘退出旧程序。
2. 如果 Windows 防火墙询问，在信任的局域网上选「专用网络」并允许连接。
3. 手机和电脑连接同一个 Wi-Fi，从托盘选「用 iPhone 扫码打开网页遥控器…」，用 Safari 打开。网页地址包含连接凭据，请只提供给获准遥控这台电脑的人。
4. 可以在 Safari 中选择「分享 → 添加到主屏幕」。开机自启动可在电脑的托盘菜单关掉。

### Apple TV 遥控器

从 Windows 开始菜单启动「Apple TV Remote」，也可从 PC 遥控托盘菜单启动，或直接双击同目录里的 `AppleTVRemote.exe`。打开 iPhone 或 iPad 控制中心里的 Apple TV 遥控器，选择这台电脑，用 Windows 托盘里显示的 PIN 配对。

- MENU（返回）是鼠标左键，Home（电视图标）是鼠标右键。
- 在 Apple TV Remote 托盘打开设置，可配置 iOS 遥控器上的后退与前进媒体按钮，支持单击、双击、滚动和常用按键等操作。
- 鼠标模式可滑动移动光标，沿触控区右边缘上下滑动滚动，按住再移动可拖拽。iOS 遥控器由 iOS 决定何时显示键盘。

### 网页键盘和触控板

- 单指轻点是左键，双指轻点是右键。iPad 浏览屏幕时，点进 Windows 能识别的输入框会打开网页键盘，点编辑区可调出系统键盘输入中文。
- 键盘按屏幕大小和转向调整布局。支持整段发送和发送后按回车，收到发送成功回执后收起面板。
- iPad 的屏幕状态用白字透明叠层显示帧率和「视频」或「图片」。

### 视频模式（一次性设置）

视频模式使用 H.264，需 HTTPS 和支持 WebCodecs 的 Safari。视频帧率设置最高可选 120 FPS，实际帧率取决于电脑编码性能、网络和手机或平板。首次使用请信任这台电脑的证书：

1. 手机 Safari 打开遥控页 → 右上角「设置」，在「视频模式」那一段点「下载电脑的证书」→ 允许下载描述文件
2. iPhone「设置」→「已下载描述文件」→ 安装
3. 「设置 → 通用 → 关于本机 → 证书信任设置」→ 打开「PC 遥控 本机证书」
4. 回到遥控页刷新，会自动换成 `https://电脑IP:8766/…`；以后从主屏幕打开前，先删掉旧的主屏幕图标，在 HTTPS 页面里重新「添加到主屏幕」

证书只在这台电脑和你的手机之间用：根证书第一次运行时生成，存在 `%APPDATA%\WatchBridge\tls`；电脑 IP 变了会自动重新签发服务器证书，手机不用重装。没装证书时自动用图片模式。

### 操作管理员窗口

Windows 不允许普通程序操作「以管理员身份运行」的窗口（任务管理器、注册表编辑器、安装程序等）。前台是这类窗口时，手机上点了没反应，会弹提示。需要的话在托盘菜单选「以管理员身份重新启动」（每次开机后要重新选；开机自启动的是普通权限）。

程序没有窗口，只在任务栏右下角的托盘里有个图标（可能收在「^」里）。左键或右键点它弹出菜单：

| 菜单 | 作用 |
|---|---|
| ✅ 网页遥控：IP:8765 | 当前地址；端口被占用时显示原因 |
| 用 iPhone 扫码打开网页遥控器… | 浏览器里显示二维码 |
| 复制网页遥控链接 | 带 token 的链接复制到剪贴板 |
| 以管理员身份重新启动 | 能操作任务管理器等管理员窗口（见上） |
| 打开 Apple TV 遥控器… | 随包安装的 Apple TV Remote |
| 使用说明… | 打开本说明 |
| 开机自动启动 | 写在 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` |
| 打开日志 | `%LOCALAPPDATA%\WatchBridge\watchbridge.log` |
| 退出 PC 遥控 | |

### 手势和按键

网页手势和快捷方式沿用 [Mac 版操作说明](https://github.com/TuhongQ/mac-remote/blob/main/docs/%E4%BD%BF%E7%94%A8%E8%AF%B4%E6%98%8E.md) 中的布局。网页连上 Windows 时会把按钮上的说法换成 Windows 的。按键的对应关系：

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

- 看屏幕只显示主显示器；视频是 CPU 软件编码（OpenH264），最宽 2560 像素，帧率取决于电脑 CPU；锁屏和 UAC 弹窗（安全桌面）时画面停住，回到桌面后继续
- 滚动用的是滚轮事件（支持平滑滚动），没有 Mac 触控板那种滚动阶段，回弹手感会略有不同
- 熄屏时碰一下触摸板会点亮屏幕；但**锁屏界面不能遥控输入密码**（Windows 不允许普通程序操作锁屏），要在电脑上解锁，或用 Windows Hello。（Mac 版锁屏时会提示用手机键盘输入密码）
- 网页遥控暂不支持调亮度
- iPad 全屏时不能像 Mac 那样临时改成 iPad 的屏幕比例（Windows 建虚拟显示器要装驱动）

### 文件位置

| | |
|---|---|
| token | `%APPDATA%\WatchBridge\token`（删掉后重启程序会生成新的） |
| 证书 | `%APPDATA%\WatchBridge\tls\`（删掉后会生成新的根证书，手机要重新安装信任） |
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
| `src/screen.rs` | 看屏幕：GDI 截主显示器、缩放、画光标，JPEG 或 H.264，按手机回执控制发送节奏，画面没变就不发 |
| `src/h264.rs` | OpenH264 编码，输出和 Mac 版一样的格式（avcC 配置 + AVCC 帧），不依赖 Windows，可在 Mac 上测 |
| `src/tls.rs` | 本机根证书和服务器证书（rcgen）、rustls 配置，不依赖 Windows，可在 Mac 上测 |
| `src/tray.rs` | 托盘图标和菜单、二维码页面、开机启动 |
| `src/util.rs` | 配置目录、token、日志、本机 IP |

### 在 Windows 上编译

```powershell
# 装 Rust：https://rustup.rs
cd windows
cargo build --locked --release
# 结果：target\release\PCRemote.exe
```

### 在 Mac 上交叉编译

```bash
rustup target add x86_64-pc-windows-gnu
cargo install cargo-zigbuild        # 用 Zig 当链接器（Homebrew 的 MinGW 在新系统上可能装不了）
# 下载 zig 解压到 ~/.local/zig/（https://ziglang.org/download/），然后：
./build-exe.sh                      # 结果：../build/PCRemote.exe
```

运行 `./build-release.sh` 可同时构建安装版、免安装 ZIP 和校验文件，输出位于 `../build/windows-release/<版本>/`。需另装 NSIS（`makensis`）。脚本固定 Apple TV Remote 的公开上游版本，再应用本目录中的补丁。

实现要点：

- 进程设为 **Per-Monitor DPI 感知 V2**：光标、显示器坐标都用物理像素；网页发来的相对位移按系统缩放比例换成像素
- 光标用**绝对坐标**移动（`MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK`），不受「提高指针精确度」影响；按住鼠标键时移动就是拖动
- 打字用 `KEYEVENTF_UNICODE`，不经过输入法；方向键等要加 `KEYEVENTF_EXTENDEDKEY`
- 锁屏不能模拟 Win+L，用 `LockWorkStation()`
- 滚动：网页的「像素」× 2.4 = 滚轮单位（一格 120），不足一格的值就是平滑滚动；方向和 Mac 版自然滚动一致
- 所有输入在一把全局锁下串行执行，防止多台设备的字交错
- 每个 WebSocket 连接两个线程：连接线程负责读写（消息排队，HTTPS 连接不能两个线程同时写；读超时 4 ms，轮流读和写），输入线程按顺序执行鼠标键盘（连续的移动合并）。打开程序之类的慢动作不会卡住画面和心跳；输入卡住超过 5 秒写日志
- `SendInput` 被拒绝、或前台窗口是管理员权限时，给手机发提示（UIPI 会悄悄丢掉输入）
- HTTPS 在 端口+1（默认 8766），握手用 rustls（ring）；`hello` 里的 `https` 是这个端口，网页据此试探并切到 HTTPS
- WebSocket 连上先发 `{"t":"hello","os":"windows",…}`，网页据此换按钮说法
- 看屏幕：网页发 `{"t":"screen","on":true,"w":…,"fps":…}`，回 `{"t":"screen","ok":true,"codec":"jpeg"}` 和 `screenInfo`（逻辑像素），之后每帧一个二进制 JPEG；网页显示完回 `screenAck`，未回执最多 2 帧
