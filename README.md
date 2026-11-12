# Mac 遥控

用 **iPhone、iPad、Apple Watch** 遥控 Mac：触控板、触摸屏、键盘、语音，实时看 Mac 屏幕，Apple Pencil 直接点、拖、写字。

Mac 上运行一个菜单栏 App，手机 / iPad 用 Safari 打开一个网页就能用，不用装 App。全部在局域网内完成，不经过任何服务器。

- 📖 [使用说明](docs/使用说明.md)：安装、授权、每个功能怎么用、设置项、常见问题
- 🛠 [开发说明](docs/开发说明.md)：架构、模块实现、通信协议、调试方法、怎么扩展

---

## 功能

**触控板遥控（iPhone / iPad）**
- 单指移动光标（带加速），轻点 / 双击 / 三击，双指右键、滚动（带惯性和触控板滚动阶段）、捏合缩放，三指拖动，四指切换桌面 / 调度中心
- 键盘：实时输入（支持手机中文输入法）、整段发送（配合手机听写做语音输入）、语音指令；常用快捷键面板
- 添加到主屏幕后像原生 App 一样全屏使用

**实时看 Mac 屏幕**
- 视频模式：Mac 用 VideoToolbox 硬件编码 H.264，手机用 WebCodecs 硬件解码，最高 60 帧、2880 像素宽，流量不到 1 Mbps（同样画面 JPEG 要 30+ Mbps）
- 按回执控制节奏，Wi-Fi 慢时自动降帧但不积压延迟；解码失败自动降分辨率；老版 Safari 自动改用 WebGL 绘制
- 没有 HTTPS 证书时自动退回 JPEG 图片模式

**iPad 专属**
- 全屏看屏幕：Mac 临时建一个 iPad 尺寸的虚拟显示器并镜像过去（像 AirPlay「为 Apple TV 优化」），画面一像素对一像素铺满 iPad；关屏自动恢复
- 两种操作方式一键切换：**触摸屏**（点哪操作哪、滑动滚动、长按右键 / 拖动，多指手势都支持）或**触控板**
- 点程序坞图标用辅助功能直接打开，不受放大 / 自动隐藏动画影响
- **Apple Pencil**：直接点、拖、画；点到 Mac 的输入框自动弹出全屏手写板，用 iPadOS「随手写」写字，实时打到 Mac 上

**其他入口**
- iPhone 控制中心自带的「Apple TV 遥控器」（配合 [atv-core](https://github.com/TuhongQ/atv-core)，配对码 1111）
- Apple Watch 快捷指令「Mac 鼠标」：菜单按钮 + 中文语音输入
- HTTP 接口：`/type`、`/key`、`/command`，任何能发 HTTP 请求的东西都能用（快捷指令、脚本……）

---

## 快速开始

需要：macOS 13+、Xcode 命令行工具（`xcode-select --install`），手机和 Mac 在同一个局域网。

```bash
git clone https://github.com/TuhongQ/mac-remote.git
cd mac-remote
./build-app.sh
```

1. 脚本会打包「Mac 遥控.app」，安装到「应用程序」并启动，图标在屏幕右上角菜单栏
2. 在弹出的系统设置里打开「辅助功能」→「Mac 遥控」，App 会自动重启生效
3. 点菜单栏图标 →「用 iPhone 扫码打开网页遥控器…」，手机相机扫码，用 Safari 打开
4. Safari「分享 → 添加到主屏幕」

想看 Mac 屏幕：第一次会请求「屏幕录制」权限；想用视频模式（推荐），按 [使用说明第 9 节](docs/使用说明.md#9-视频模式与-https-证书一次性设置) 给手机装一次证书。

可选：把 [atv-core](https://github.com/TuhongQ/atv-core) 克隆到同级目录并安装 Rust，`build-app.sh` 会顺带打包 iPhone「Apple TV 遥控器」的接收端。

---

## 项目结构

| 路径 | 说明 |
|---|---|
| `WatchBridge.swift` | Mac 端全部代码：HTTP / WebSocket / HTTPS 服务、键鼠模拟、语音指令、屏幕镜像、显示器适配、辅助功能、菜单栏 App |
| `CGVirtualDisplay.h` | 私有 API CGVirtualDisplay 的声明（显示器适配用） |
| `web/remote.html` | 手机 / iPad 遥控网页（单文件，打包进 App） |
| `build-app.sh` | 编译、签名、安装「Mac 遥控.app」 |
| `install.sh` | 旧版：命令行程序 + 后台服务（已被 App 取代） |
| `shortcuts/make-shortcut.py` | 生成手表快捷指令「Mac 鼠标」 |
| `watch/` | watchOS 体感鼠标 App（实验功能，未在真机验证） |
| `docs/` | 使用说明、开发说明 |

没有第三方依赖：Mac 端只用系统框架（AppKit、Network、ScreenCaptureKit、VideoToolbox、CoreGraphics、ApplicationServices），网页是原生 JS / CSS。

---

## 安全

- 访问需要 token（第一次启动随机生成，存在 `~/.config/watchbridge/token`）。拿到 token 的人能完全控制这台 Mac，链接、二维码、快捷指令文件都不要发给别人
- 只在可信的局域网里使用
- 本机根证书私钥只保存在 `~/.config/watchbridge/tls/`；token、证书、签名钥匙串都不在仓库里

## 环境

在 macOS 27（Apple Silicon）、iOS 27 iPhone、iPadOS 16.5 iPad Pro（M1）上开发和测试。
