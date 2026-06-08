# OnlyWallpaper

macOS 动态壁纸工具，使用 GPU 硬件加速渲染视频作为桌面背景。
将 MP4/MOV 视频文件设置为 macOS 桌面壁纸，支持开机自启等功能。
**GPU 硬件加速** - 使用 WKWebView + Metal 视频解码，超低功耗。

## 功能特性

| 特性 | 说明 |
|------|------|
| GPU 硬件加速 | Metal 解码，功耗仅 10-50mW |
| 锁屏/睡眠自动暂停 | 省电，解锁后自动恢复 |
| 5 分钟无操作暂停 | 离开电脑自动暂停 |
| 全局快捷键 | `⌘⇧P` 随时暂停/恢复 |
| `status` 功耗显示 | 查看电池电量与系统实时功耗 |
| 开机自启 | 通过 launchd 配置，支持后台运行 |

## 用法

**直接下载：从右边 release 下载现成的二进制文件**

或者手动自行编译：

### 编译

```bash
CGO_ENABLED=1 go build -o wallpaper
```

编译后会生成一个单独的二进制文件(**无需额外的 assets 目录**)，所有资源(包括 HTML 模板)已内嵌于二进制中。



### 启动壁纸

```bash
chmod +x wallpaper
./wallpaper --video /path/to/video.mp4
```

### 停止壁纸

```bash
./wallpaper stop
```

### 查看状态

```bash
./wallpaper status
```

显示壁纸运行状态、电池电量与系统实时功耗。

### 暂停/恢复

按下 `⌘⇧P` (Cmd+Shift+P) 全局快捷键暂停或恢复壁纸播放。无需切换到壁纸窗口，任何应用中均可使用。

### 开机自启

设置开机自启（需指定视频路径）：
```bash
./wallpaper enable-autostart --video /path/to/video.mp4
```

取消开机自启：
```bash
./wallpaper disable-autostart
```

## 命令行参数

| 参数 | 说明 |
|------|------|
| `--video` | MP4/MOV 视频文件路径 |
| `--cmd` | 命令：`start` / `stop` / `status` / `enable-autostart` / `disable-autostart` |
| `--mute` | 静音模式（禁用音频） |

## 全局快捷键

| 快捷键 | 功能 |
|--------|------|
| `⌘⇧P` (Cmd+Shift+P) | 暂停/恢复壁纸播放 |

无论壁纸窗口是否在最前，快捷键全局生效。

## 打包和部署

- **单一二进制** - 所有资源（HTML、样式、脚本）已嵌入，无需携带额外文件
- **跨目录使用** - 可以将二进制文件放在任何位置，正常运行无需依赖目录结构
- **体积最小化** - 内置资源被编译进二进制，减少文件数量

## 注意事项

1. **视频格式** - 仅支持 .mp4 和 .mov 格式
2. **资源占用** - 视频播放会占用一定的 GPU 资源，功耗增加极少（我测试只有10-50mW，不到0.1W占用）
3. **编译要求** - 需要安装 Xcode Command Line Tools：
   ```bash
   xcode-select --install
   ```
4. **单实例运行** - 程序使用文件锁确保同时只有一个实例运行，新启动会自动停止旧实例

## 技术栈

- **Go** - 主程序逻辑
- **embed** - 资源内嵌
- **cgo** - Go 与 Objective-C 互操作
- **Objective-C** - macOS 原生窗口管理
- **WKWebView** - HTML5 视频渲染

