# OnlyWallpaper

项目信息见 [README.md](./README.md)。

## 构建

```bash
CGO_ENABLED=1 go build -o wallpaper
```

需要 macOS + Xcode Command Line Tools。

## 关键实现

- **`main.go`** — Go 入口，命令行解析、单实例锁、后台进程管理、开机自启、功耗查询
- **`bridge.m`** — Objective-C 桥接，NSWindow/WKWebView 创建、系统通知监听（休眠/唤醒/锁屏/解锁）、全局快捷键（Carbon HotKey）
- **`assets/player.html`** — 视频播放页面，`visibilitychange` 处理锁屏/盒盖暂停，`userPaused` 标记控制手动暂停后是否自动恢复

## 暂停恢复逻辑

```
锁屏/盒盖 → WKWebView visibilitychange(hidden) → pause
解锁/开盖 → visibilitychange(visible) → 检查 userPaused：
  正常 → play
  手动暂停过 → 跳过恢复（仅恢复视频帧位置）

快捷键 → togglePlayback() → userPaused = !userPaused
```

## 发布

1. 编译：`CGO_ENABLED=1 go build -o wallpaper`
2. 打标签推送：`git tag vX.Y.Z && git push origin main --tags`
3. 创建 Release 并上传 `wallpaper` 二进制
