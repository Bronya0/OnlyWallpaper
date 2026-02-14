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
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/gofrs/flock"
)

const (
	lockFile     = "/tmp/desktop-wallpaper.lock"
	htmlTemplate = "assets/player.html"
)

var (
	videoPath string
	cmd       string
)

func init() {
	flag.StringVar(&videoPath, "video", "", "MP4 视频文件路径（绝对路径）")
	flag.StringVar(&cmd, "cmd", "start", "命令: start|stop|status")
}

func main() {
	flag.Parse()

	// 单实例锁
	lock := flock.New(lockFile)
	if cmd != "stop" && cmd != "status" {
		locked, err := lock.TryLock()
		if err != nil || !locked {
			// 尝试自动终止旧进程
			pid, _ := readPID()
			if pid > 0 {
				fmt.Printf("⚠️  检测到旧实例 (PID: %d)，正在终止...\n", pid)
				proc, err := os.FindProcess(pid)
				if err == nil {
					proc.Signal(syscall.SIGTERM)
					// 等待释放
					for i := 0; i < 20; i++ {
						time.Sleep(100 * time.Millisecond)
						if l, _ := lock.TryLock(); l {
							locked = true
							break
						}
					}
				}
			}
			
			if !locked {
				fmt.Println("❌ 无法获取锁，请手动运行: wallpaper stop")
				os.Exit(1)
			}
		}
		// 写入当前 PID
		writePID()
		defer func() {
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
	default:
		fmt.Printf("❌ 未知命令: %s (支持: start|stop|status)\n", cmd)
		os.Exit(1)
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
	if !strings.HasSuffix(strings.ToLower(absPath), ".mp4") {
		fmt.Println("❌ 仅支持 .mp4 格式视频")
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

	ret := C.InitWallpaper(C.CString(absPath), C.CString(templatePath))
	if ret != 0 {
		fmt.Println("❌ 壁纸启动失败（查看上方错误）")
		os.Exit(1)
	}

	// 优雅退出处理
	go func() {
		sigCh := make(chan os.Signal, 1)
		signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
		<-sigCh
		fmt.Println("\n👋 正在清理壁纸资源...")
		C.CleanupWallpaper()
		time.Sleep(200 * time.Millisecond) // 等待窗口销毁
		os.Exit(0)
	}()

	fmt.Println("✅ 壁纸已激活（按 Ctrl+C 或运行 `wallpaper stop` 退出）")

	// 运行主事件循环（阻塞主线程）
	C.RunApp()
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
		// 检查视频是否暂停
		paused := C.IsVideoPaused()
		if paused == 1 {
			fmt.Println("⏸️  壁纸状态: 运行中（视频已暂停）")
		} else {
			fmt.Println("▶️  壁纸状态: 运行中（视频播放中）")
		}
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
