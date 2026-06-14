# OnlyWallpaper

macOS 动态壁纸工具，使用 GPU 硬件加速渲染视频作为桌面背景。
将 MP4/MOV 视频文件设置为 macOS 桌面壁纸，支持开机自启等功能。

## 功能特性

| 特性 | 说明 |
|------|------|
| GPU 硬件加速 | WKWebView + Metal 视频解码，低功耗 |
| **多显示器支持** | 启动时为每个显示器创建独立壁纸窗口 |
| **锁屏/盒盖自动暂停** | 解锁/开盖自动恢复 |
| **手动暂停不自动恢复** | `⌘⇧P` 暂停后，开盖/解锁均不恢复，需再次按快捷键 |
| 全局快捷键 | `⌘⇧P` 随时暂停/恢复（多屏同步） |
| 实时功耗显示 | `status` 命令查看电池电量与系统功耗 |
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

显示运行状态、电池电量与系统实时功耗。

### 静音

```bash
./wallpaper --video /path/to/video.mp4 --mute
```

### 暂停/恢复

按下 `⌘⇧P`（Cmd+Shift+P）全局快捷键。任何应用中均可使用。

### 开机自启

```bash
./wallpaper --cmd enable-autostart --video /path/to/video.mp4
./wallpaper --cmd disable-autostart
```

## 行为说明

| 操作 | 效果 |
|------|------|
| 锁屏 | 自动暂停，解锁后自动恢复 |
| 盒盖 | 自动暂停，开盖后自动恢复 |
| `⌘⇧P` 快捷键 | 手动暂停/恢复（多屏同步） |
| 快捷键暂停后 → 锁屏/盒盖 → 解锁/开盖 | **不恢复**，需再次按快捷键恢复 |
| 多显示器 | 每个屏独立窗口，切歌/暂停全局同步 |
| 运行中插拔显示器 | 不响应，需重启程序生效 |
| 空闲无操作 | **不会自动暂停**（macOS 自身管理电源） |

## 编译

需要 macOS + Xcode Command Line Tools：

```bash
xcode-select --install
CGO_ENABLED=1 go build -o wallpaper
```

编译后生成单一二进制文件，无需额外 assets 目录（HTML 模板已内嵌）。

## 技术栈

- **Go** - 主程序逻辑
- **cgo + Objective-C** - macOS 原生窗口管理、系统通知监听
- **WKWebView** - HTML5 视频渲染
- **Carbon HotKey** - 全局快捷键

## 注意事项

1. **视频格式** — 仅支持 `.mp4` 和 `.mov`
2. **单实例** — 使用文件锁确保同时只有一个实例在运行
3. **编译要求** — 需要 macOS + Xcode Command Line Tools
