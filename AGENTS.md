# OnlyWallpaper

项目信息见 [README.md](./README.md)。

## 构建

```bash
CGO_ENABLED=1 go build -o wallpaper
```

需要 macOS + Xcode Command Line Tools。

## 后台运行

普通 `--video` / `--dir` 启动命令会自行转入后台；不使用额外的任务/服务托管，也不需要手动加 `--daemon`。
默认有声音，`--mute` 才静音。退出使用 `--cmd stop`。

## 关键实现

- **`main.go`** — Go 入口，命令行解析、单实例锁、后台进程管理、开机自启、功耗查询
- **`bridge.m`** — Objective-C 桥接，NSWindow/WKWebView 创建、应用焦点及系统通知监听、全局快捷键（Carbon HotKey）
- **`assets/player.html`** — 视频播放页面，`setPlaybackState()` 与 `visibilitychange` 共用暂停规则，保留播放位置

## 暂停恢复逻辑

```
其他应用获得焦点 / 可见 Finder 文件窗口 / 锁屏 / 盒盖 → 原生 autoPaused = true → pause
回到桌面（Finder） / 解锁 / 开盖 → 重新计算全部自动暂停条件
快捷键 → 原生 gUserPaused = !gUserPaused
原生 setPlaybackState(userPaused, autoPaused) → 多屏同步
只有页面可见且 userPaused、autoPaused 都为 false 才播放
启动及切歌的新页面默认暂停，导航完成后同步原生状态

Finder 获得焦点时，用 CGWindowListCopyWindowInfo 检查当前桌面的正常可见窗口。
每 0.5 秒检测 Finder 内开窗/关窗/最小化，仅状态变化时广播 JS；退出时停止定时器。
仍不检测其他应用窗口的遮挡面积；最小化、其他 Space 和桌面元素不算 Finder 文件窗口。
NSWorkspace 通知必须注册到 workspace.notificationCenter，并在主线程处理。
```

## 验证

- Go 回归测试：`CGO_ENABLED=1 go test ./...`。
- `tests/player_test.m` 用 JavaScriptCore 验证页面暂停条件，`tests/bridge_test.m` 模拟原生焦点、Finder 窗口与休眠通知；完整命令见 README 的回归测试部分。
- 测试不操作真实窗口、不读取个人视频。临时二进制、测量脚本及采样数据放在 `.tmp/`，不提交到 Git。
- 功耗读数不是壁纸独占功耗；插电时 `SystemPowerIn` 可能含充电，传感器也可能延迟刷新。资源数据须注明条件与限制。

## 发布

1. 编译：`CGO_ENABLED=1 go build -o wallpaper`
2. 打标签推送：`git tag vX.Y.Z && git push origin main --tags`
3. 创建 Release 并上传 `wallpaper` 二进制
