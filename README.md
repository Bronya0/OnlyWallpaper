# OnlyWallpaper

macOS 动态壁纸工具，使用 GPU 硬件加速渲染视频作为桌面背景。

## 功能介绍

将 MP4 视频文件设置为 macOS 桌面壁纸，支持视频播放控制、省电优化等功能。

## 特性

- **GPU 硬件加速** - 使用 WKWebView + Metal 视频解码，低 CPU 占用
- **省电优化** - 锁屏/睡眠自动暂停、5分钟无操作自动暂停、静音播放
- **点击穿透** - 窗口不阻挡鼠标操作，不影响正常使用
- **多桌面支持** - 窗口自动复制到所有桌面空间
- **单实例运行** - 通过文件锁确保只有一个壁纸实例运行

## 用法

### 编译

```bash
CGO_ENABLED=1 go build -o wallpaper
```

### 启动壁纸

```bash
./wallpaper --video /path/to/video.mp4
```

### 停止壁纸

```bash
./wallpaper --cmd stop
```

### 查看状态

```bash
./wallpaper --cmd status
```

## 命令行参数

| 参数 | 说明 |
|------|------|
| `--video` | MP4 视频文件路径（绝对路径） |
| `--cmd` | 命令：`start`/`stop`/`status`（默认 start） |

## 注意事项

1. **仅支持 MP4/MOV 格式** - 目前只支持 .mp4 和 .mov 扩展名的视频文件

2. **绝对路径** - 视频路径必须使用绝对路径，不能使用 `~/` 简写

3. **权限要求** - 可能需要授予辅助功能权限才能正常显示桌面窗口

4. **资源占用** - 视频播放会占用一定的 GPU 资源，建议在不需要时使用 `stop` 命令停止

5. **多显示器** - 当前版本仅支持主显示器

6. **编译要求** - 需要安装 Xcode Command Line Tools：
   ```bash
   xcode-select --install
   ```

## 技术栈

- **Go** - 主程序逻辑
- **cgo** - Go 与 Objective-C 互操作
- **Objective-C** - macOS 原生窗口管理
- **WKWebView** - HTML5 视频渲染
