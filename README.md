# OnlyWallpaper

<a href="https://linux.do" alt="LINUX DO"><img src="https://shorturl.at/ggSqS" /></a>

macOS 动态壁纸工具，使用 GPU 硬件加速渲染视频作为桌面背景。
将 MP4/MOV 视频文件设置为 macOS 桌面壁纸，支持开机自启等功能。

**作者另一款开源编码 AI Agent**：[ally-agent](https://github.com/Bronya0/ally-agent)

## 功能特性

| 特性 | 说明 |
|------|------|
| GPU 硬件加速 | WKWebView + Metal 视频解码，低功耗 |
| **多显示器支持** | 启动时为每个显示器创建独立壁纸窗口 |
| **锁屏/盒盖自动暂停** | 解锁/开盖后按焦点和手动暂停状态决定是否恢复 |
| **应用焦点自动暂停** | 切到其他应用或打开 Finder 文件窗口时暂停，回到桌面且没有可见 Finder 窗口时恢复，无需额外权限 |
| **手动暂停不自动恢复** | `⌘⇧P` 暂停后，开盖/解锁均不恢复，需再次按快捷键 |
| 全局快捷键 | `⌘⇧P` 随时暂停/恢复（多屏同步） |
| 功耗参考显示 | `status` 命令查看电池电量与功耗传感器读数 |
| Dark Wake 防护 | 休眠中暗唤醒不恢复 |
| 播放列表 | `--dir` 模式自动顺序播放目录内所有视频（多屏同步切歌） |
| 开机自启 | 通过 launchd 配置，支持后台运行 |

## 快速开始

### 下载

从 [Releases](https://github.com/Bronya0/OnlyWallpaper/releases) 下载最新的二进制文件。

### 启动壁纸

```bash
chmod +x wallpaper
./wallpaper --video /path/to/video.mp4
```

程序会自行转入后台，不占用终端，不需要 `nohup` 或其他任务/服务托管。`--daemon` 是内部参数，正常启动不需要手动添加。
默认保留视频声音；需要静音时添加 `--mute`。自动暂停会同时暂停画面和声音。

播放目录内所有视频（自动顺序播放）：

```bash
./wallpaper --dir /path/to/video/folder
```

### 停止

```bash
./wallpaper --cmd stop
```

### 查看状态

```bash
./wallpaper --cmd status
```

显示运行状态、电池电量与功耗参考读数。

**功耗读数注意**：当前 `status` 优先读取 `SystemPowerIn`，插电时可能包含电池充电功率；没有该字段时尝试用电池电流和电压计算。传感器不一定每次调用都会刷新，因此不能把一次读数直接当成视频壁纸的耗电量或精密测量结果。

### 静音

```bash
./wallpaper --video /path/to/video.mp4 --mute
```

### 暂停/恢复

默认按应用焦点自动控制：切到其他应用时暂停；Finder 在前台时，还会检查当前桌面是否有可见的 Finder 文件窗口，有窗口就暂停。
关闭或最小化所有 Finder 文件窗口后，焦点仍在桌面才恢复，检测延迟约半秒；其他桌面上的窗口不会影响当前桌面。多屏统一暂停/恢复。
只读取窗口归属、层级和尺寸，不读取内容或标题，无需录屏或辅助功能权限。
这仍不是所有应用的窗口遮挡检测：其他应用的窗口还留在桌面上，但焦点回到 Finder 且没有可见 Finder 文件窗口时会恢复。

按下 `⌘⇧P`（Cmd+Shift+P）可切换手动暂停状态，任何应用中均可使用。
手动暂停后，回桌面、关掉 Finder 窗口、解锁或开盖都不会自动恢复；再次按快捷键解除手动暂停后，仍需焦点回到桌面且没有可见 Finder 文件窗口才播放。

### 开机自启

```bash
./wallpaper --cmd enable-autostart --video /path/to/video.mp4
./wallpaper --cmd disable-autostart
```

## 行为说明

| 操作 | 效果 |
|------|------|
| 切到其他应用 | 自动暂停视频和声音（多屏同步） |
| 打开 Finder 文件窗口 | 自动暂停视频和声音 |
| 关闭 / 最小化所有 Finder 文件窗口 | 焦点仍在桌面时自动恢复，手动暂停过则不恢复 |
| 回到桌面 | 没有可见 Finder 文件窗口且未手动暂停时自动恢复 |
| 锁屏 | 自动暂停，解锁后按焦点和手动状态决定是否恢复 |
| 盒盖 | 自动暂停，开盖后按焦点和手动状态决定是否恢复 |
| `⌘⇧P` 快捷键 | 手动暂停/恢复（多屏同步） |
| 快捷键暂停后 → 锁屏/盒盖 → 解锁/开盖 | **不恢复**，需再次按快捷键恢复 |
| 多显示器 | 每个屏独立窗口，切歌/暂停全局同步 |
| 运行中插拔显示器 | 不响应，需重启程序生效 |
| 空闲无操作 | **不会自动暂停**（macOS 自身管理电源） |

## 资源占用参考

以下仅为一次本机观察，不是性能保证：Apple M4、单显示器、1024×576 的约 30 秒 MP4，保留声音。
功耗测试保持其他窗口和焦点不变，并用临时测试版固定视频播放状态，避免自动暂停干扰；测试入口不在正式程序中。

| 状态 | 短测功耗读数均值（不含电池充电） |
|------|------------------------------|
| 播放 | 约 2.73 W |
| 暂停 | 约 2.26 W |
| 完全关闭视频壁纸 | 约 2.32 W |

功耗读取自 `PowerTelemetryData.SystemLoad`。本次传感器约每分钟刷新一次，360 次读取仅有 9 个刷新点，后续长测因供电条件变化中止。以上只能粗略说明当前场景下播放多耗约 0.4～0.5 W，暂停与关闭差异不明显，不能当作精确功耗或套用于其他视频、多屏、4K 或桌面完全可见的场景。

内存使用 macOS `footprint` 统计：当时主程序与 WebKit 渲染、GPU、网络进程合计约 **73.4 MB（70 MiB）**。这是当前时刻的值，不是播放峰值；不能只统计 Go 主进程，也不应将共享系统库重复算入总占用。

## 编译

需要 macOS + Xcode Command Line Tools：

```bash
xcode-select --install
CGO_ENABLED=1 go build -o wallpaper
```

编译后生成单一二进制文件，无需额外 assets 目录（HTML 模板已内嵌）。

### 回归测试

```bash
CGO_ENABLED=1 go test ./...
mkdir -p .tmp
clang -fobjc-arc -framework Foundation -framework JavaScriptCore tests/player_test.m -o .tmp/player_test
.tmp/player_test assets/player.html
clang -fobjc-arc -framework Cocoa -framework WebKit -framework CoreGraphics -framework Carbon tests/bridge_test.m -o .tmp/bridge_test
.tmp/bridge_test
```

播放状态测试使用 macOS 自带的 JavaScriptCore，不需要安装 Node.js。原生测试在独立进程里模拟焦点、休眠和锁屏通知，不会切换应用、打开壁纸窗口或读取个人视频。

## 技术栈

- **Go** - 主程序逻辑
- **cgo + Objective-C** - macOS 原生窗口管理、系统通知监听
- **WKWebView** - HTML5 视频渲染
- **Carbon HotKey** - 全局快捷键

## 注意事项

1. **视频格式** — 仅支持 `.mp4` 和 `.mov`
2. **单实例** — 使用文件锁确保同时只有一个实例在运行
3. **编译要求** — 需要 macOS + Xcode Command Line Tools
