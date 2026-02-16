package main

/*
#cgo CFLAGS: -x objective-c -fobjc-arc
#cgo LDFLAGS: -framework Cocoa -framework WebKit -framework CoreGraphics
#include "bridge.h"
#include <stdlib.h>
*/
import "C"
import (
	"flag"
	"fmt"
	"log"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"time"
	"unsafe"

	"github.com/gofrs/flock"
)

const (
	lockFile     = "/tmp/desktop-wallpaper.lock"
	htmlTemplate = "assets/player.html"
)

var (
	videoPath string
	cmd       string
	daemon    bool
)

func init() {
	flag.StringVar(&videoPath, "video", "", "MP4/MOV 视频文件路径（绝对路径）")
	flag.StringVar(&cmd, "cmd", "start", "命令: start|stop|status|enable-autostart|disable-autostart")
	flag.BoolVar(&daemon, "daemon", false, "后台运行模式（内部使用）")
}

func main() {
	runtime.LockOSThread()
	log.SetFlags(log.Ltime | log.Lmicroseconds)
	normalizeArgs()
	flag.Parse()

	if cmd == "start" && !daemon {
		if videoPath == "" {
			fmt.Println("❌ 请指定 --video /path/to/video.mp4")
			flag.Usage()
			os.Exit(1)
		}
		if err := startBackground(); err != nil {
			fmt.Printf("❌ 后台启动失败: %v\n", err)
			os.Exit(1)
		}
		fmt.Println("✅ 已转入后台运行（可用 `wallpaper --cmd status` 查看，`wallpaper --cmd stop` 退出）")
		return
	}

	// 单实例锁
	lock := flock.New(lockFile)
	if cmd != "stop" && cmd != "status" {
		log.Println("🔒 尝试获取单实例锁...")
		locked, err := lock.TryLock()
		if err != nil || !locked {
			// 尝试自动终止旧进程
			pid, _ := readPID()
			if pid > 0 {
				log.Printf("⚠️  检测到旧实例 (PID: %d)，正在终止...", pid)
				proc, err := os.FindProcess(pid)
				if err == nil {
					log.Println("📡 发送 SIGTERM 信号...")
					proc.Signal(syscall.SIGTERM)
					// 等待释放：轮询进程是否存在
					done := false
					for i := 0; i < 50; i++ { // 最多等 5 秒
						time.Sleep(100 * time.Millisecond)
						// 检查进程是否还在
						if err := proc.Signal(syscall.Signal(0)); err != nil {
							// 进程已消失
							log.Println("✅ 旧进程已退出")
							done = true
							break
						}
					}

					if !done {
						// 强制清理
						log.Println("⚠️  旧实例未响应，尝试强制清理 (Kill)...")
						proc.Kill()
						time.Sleep(200 * time.Millisecond)
					}

					// 再次确认锁
					log.Println("🔒 再次尝试获取锁...")
					if l, _ := lock.TryLock(); l {
						locked = true
						log.Println("✅ 锁获取成功")
					} else {
						log.Println("❌ 锁获取失败")
					}
				}
			}

			if !locked {
				fmt.Println("❌ 无法获取锁，请手动运行: wallpaper stop")
				os.Exit(1)
			}
		} else {
			log.Println("✅ 首次锁获取成功")
		}
		// 写入当前 PID
		writePID()
		defer func() {
			log.Println("🔓 释放锁并清理 PID 文件")
			lock.Unlock()
			os.Remove(lockFile)
		}()
	}

	switch cmd {
	case "start":
		if videoPath == "" {
			fmt.Println("❌ 请指定 --video /path/to/video.mp4")
			flag.Usage()
			os.Exit(1)
		}
		startWallpaper(videoPath)
	case "stop":
		stopWallpaper()
	case "status":
		checkStatus()
	case "enable-autostart":
		if videoPath == "" {
			fmt.Println("❌ 请指定 --video /path/to/video.mp4")
			os.Exit(1)
		}
		enableAutostart(videoPath)
	case "disable-autostart":
		disableAutostart()
	default:
		fmt.Printf("❌ 未知命令: %s (支持: start|stop|status|enable-autostart|disable-autostart)\n", cmd)
		os.Exit(1)
	}
}

func enableAutostart(video string) {
	absPath, err := filepath.Abs(video)
	if err != nil {
		fmt.Printf("❌ 路径无效: %v\n", err)
		return
	}

	exePath, err := os.Executable()
	if err != nil {
		fmt.Printf("❌ 无法获取程序路径: %v\n", err)
		return
	}

	plistContent := fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.user.onlywallpaper</string>
    <key>ProgramArguments</key>
    <array>
        <string>%s</string>
        <string>--video</string>
        <string>%s</string>
        <string>--daemon</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>StandardOutPath</key>
    <string>/dev/null</string>
    <key>StandardErrorPath</key>
    <string>/dev/null</string>
</dict>
</plist>`, exePath, absPath)

	homeDir, err := os.UserHomeDir()
	if err != nil {
		fmt.Printf("❌ 无法获取用户目录: %v\n", err)
		return
	}

	launchAgentsDir := filepath.Join(homeDir, "Library", "LaunchAgents")
	if err := os.MkdirAll(launchAgentsDir, 0755); err != nil {
		fmt.Printf("❌ 无法创建 LaunchAgents 目录: %v\n", err)
		return
	}

	plistPath := filepath.Join(launchAgentsDir, "com.user.onlywallpaper.plist")
	if err := os.WriteFile(plistPath, []byte(plistContent), 0644); err != nil {
		fmt.Printf("❌ 写入 plist 失败: %v\n", err)
		return
	}

	fmt.Printf("📄 已生成 plist 文件: %s\n", plistPath)

	// Unload first to avoid error if already loaded
	exec.Command("launchctl", "unload", plistPath).Run()

	if err := exec.Command("launchctl", "load", plistPath).Run(); err != nil {
		fmt.Printf("❌ 加载自启动服务失败: %v\n", err)
		fmt.Println("💡 请尝试手动运行: launchctl load " + plistPath)
	} else {
		fmt.Println("✅ 已配置开机自启")
	}
}

func disableAutostart() {
	homeDir, err := os.UserHomeDir()
	if err != nil {
		fmt.Printf("❌ 无法获取用户目录: %v\n", err)
		return
	}

	plistPath := filepath.Join(homeDir, "Library", "LaunchAgents", "com.user.onlywallpaper.plist")

	if _, err := os.Stat(plistPath); os.IsNotExist(err) {
		fmt.Println("⚠️  未找到自启配置文件")
		return
	}

	exec.Command("launchctl", "unload", plistPath).Run()

	if err := os.Remove(plistPath); err != nil {
		fmt.Printf("❌ 删除配置文件失败: %v\n", err)
	} else {
		fmt.Println("✅ 已取消开机自启")
	}
}

func normalizeArgs() {
	if len(os.Args) < 2 {
		return
	}
	for _, arg := range os.Args[1:] {
		if arg == "--cmd" || strings.HasPrefix(arg, "--cmd=") {
			return
		}
	}
	sub := os.Args[1]
	if strings.HasPrefix(sub, "-") {
		return
	}
	switch sub {
	case "stop", "status":
		os.Args = append([]string{os.Args[0], "--cmd", sub}, os.Args[2:]...)
	case "enable-autostart", "disable-autostart":
		os.Args = append([]string{os.Args[0], "--cmd", sub}, os.Args[2:]...)
	case "start":
		os.Args = append([]string{os.Args[0]}, os.Args[2:]...)
	}
}

func startWallpaper(video string) {
	// 路径规范化
	absPath, err := filepath.Abs(video)
	if err != nil {
		fmt.Printf("❌ 无效路径: %v\n", err)
		os.Exit(1)
	}

	// 校验 MP4
	if absPath != "" && !strings.HasSuffix(strings.ToLower(absPath), ".mp4") && !strings.HasSuffix(strings.ToLower(absPath), ".mov") {
		fmt.Println("❌ 仅支持 .mp4/.mov 格式视频")
		os.Exit(1)
	}

	// 检查模板
	exePath, _ := os.Executable()
	templatePath := filepath.Join(filepath.Dir(exePath), htmlTemplate)
	if _, err := os.Stat(templatePath); os.IsNotExist(err) {
		fmt.Printf("❌ 未找到 HTML 模板: %s\n", templatePath)
		fmt.Println("💡 请确保 assets/player.html 存在于程序目录")
		os.Exit(1)
	}

	// 初始化壁纸
	fmt.Printf("🎬 正在启动动态壁纸: %s\n", filepath.Base(absPath))
	fmt.Println("🔋 省电特性:")
	fmt.Println("   • Metal 硬件加速解码")
	fmt.Println("   • 锁屏/睡眠自动暂停")
	fmt.Println("   • 5分钟无操作自动暂停")
	fmt.Println("   • 静音播放（禁用音频解码）")
	fmt.Println()

	cVideo := C.CString(absPath)
	cTemplate := C.CString(templatePath)
	defer C.free(unsafe.Pointer(cVideo))
	defer C.free(unsafe.Pointer(cTemplate))

	ret := C.InitWallpaper(cVideo, cTemplate)
	if ret != 0 {
		fmt.Println("❌ 壁纸启动失败（查看上方错误）")
		os.Exit(1)
	}

	// 优雅退出处理
	go func() {
		sigCh := make(chan os.Signal, 1)
		signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
		sig := <-sigCh
		log.Printf("\n👋 接收到信号: %v，正在清理壁纸资源...", sig)
		C.StopApp()
	}()

	fmt.Println("✅ 壁纸已激活（按 Ctrl+C 或运行 `wallpaper stop` 退出）")

	// 运行主事件循环（阻塞主线程）
	log.Println("🚀 启动主事件循环 (RunApp)")
	C.RunApp()

	// 主循环结束后清理
	log.Println("🧹 主循环结束，执行最终清理")
	C.CleanupWallpaper()
}

func startBackground() error {
	exePath, err := os.Executable()
	if err != nil {
		return err
	}
	args := make([]string, 0, len(os.Args))
	hasDaemon := false
	for _, arg := range os.Args[1:] {
		if arg == "--daemon" || strings.HasPrefix(arg, "--daemon=") {
			hasDaemon = true
		}
		args = append(args, arg)
	}
	if !hasDaemon {
		args = append(args, "--daemon")
	}

	cmd := exec.Command(exePath, args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	devNull, err := os.OpenFile("/dev/null", os.O_RDWR, 0)
	if err != nil {
		return err
	}
	cmd.Stdin = devNull
	cmd.Stdout = devNull
	cmd.Stderr = devNull
	if err := cmd.Start(); err != nil {
		devNull.Close()
		return err
	}
	devNull.Close()
	return cmd.Process.Release()
}

func stopWallpaper() {
	// 读取 PID
	pid, err := readPID()
	if err != nil || pid == 0 {
		fmt.Println("⚠️  未检测到运行中的壁纸实例")
		// 清理可能存在的僵尸锁文件
		os.Remove(lockFile)
		return
	}

	// 查找并终止进程
	proc, err := os.FindProcess(pid)
	if err != nil {
		fmt.Println("⚠️  进程已不存在")
		os.Remove(lockFile)
		return
	}

	fmt.Println("🛑 正在停止动态壁纸...")
	err = proc.Signal(syscall.SIGTERM)
	if err != nil {
		fmt.Printf("❌ 停止失败: %v\n", err)
		return
	}

	// 等待锁释放
	lock := flock.New(lockFile)
	for i := 0; i < 20; i++ {
		locked, _ := lock.TryLock()
		if locked {
			lock.Unlock()
			os.Remove(lockFile)
			fmt.Println("✅ 壁纸已停止")
			return
		}
		time.Sleep(100 * time.Millisecond)
	}
	fmt.Println("⚠️  停止操作超时，请手动检查")
}

func checkStatus() {
	lock := flock.New(lockFile)
	locked, _ := lock.TryLock()
	if locked {
		lock.Unlock()
		fmt.Println("⏹️  壁纸状态: 未运行")
	} else {
		fmt.Println("✅ 壁纸状态: 运行中")
	}
}

func writePID() {
	os.WriteFile(lockFile, []byte(fmt.Sprintf("%d", os.Getpid())), 0644)
}

func readPID() (int, error) {
	data, err := os.ReadFile(lockFile)
	if err != nil {
		return 0, err
	}
	var pid int
	fmt.Sscanf(string(data), "%d", &pid)
	return pid, nil
}
