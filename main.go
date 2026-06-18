package main

/*
#cgo CFLAGS: -x objective-c -fobjc-arc
#cgo LDFLAGS: -framework Cocoa -framework WebKit -framework CoreGraphics -framework Carbon
#include "bridge.h"
#include <stdlib.h>
*/
import "C"
import (
	"context"
	"embed"
	"flag"
	"fmt"
	"log"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unsafe"

	"github.com/gofrs/flock"
)

//go:embed assets/player.html
var embeddedAssets embed.FS

const (
	lockFile = "/tmp/desktop-wallpaper.lock"
)

var (
	videoPath string
	cmd       string
	daemon    bool
	mute      bool
	dirPath   string
)

func init() {
	flag.StringVar(&videoPath, "video", "", "MP4/MOV 视频文件路径（绝对路径）")
	flag.StringVar(&cmd, "cmd", "start", "命令: start|stop|status|enable-autostart|disable-autostart")
	flag.BoolVar(&daemon, "daemon", false, "后台运行模式（内部使用）")
	flag.BoolVar(&mute, "mute", false, "静音模式（禁用音频）")
	flag.StringVar(&dirPath, "dir", "", "视频目录（自动顺序播放目录内所有 mp4/mov 文件）")
}

func main() {
	runtime.LockOSThread()
	log.SetFlags(log.Ltime | log.Lmicroseconds)
	normalizeArgs()
	flag.Parse()

	if cmd == "start" && !daemon {
		if videoPath == "" && dirPath == "" {
			fmt.Println("❌ 请指定 --video /path/to/video.mp4 或 --dir /path/to/folder")
			flag.Usage()
			os.Exit(1)
		}
		// --dir 模式下先校验目录存在
		if dirPath != "" {
			if info, err := os.Stat(dirPath); err != nil || !info.IsDir() {
				fmt.Printf("❌ 目录无效: %s\n", dirPath)
				os.Exit(1)
			}
		}
		if err := startBackground(); err != nil {
			fmt.Printf("❌ 后台启动失败: %v\n", err)
			os.Exit(1)
		}
		fmt.Println("✅ 已转入后台运行（可用 `wallpaper --cmd status` 查看，`wallpaper --cmd stop` 退出）")
		fmt.Println("💡 新版本下载：https://github.com/Bronya0/OnlyWallpaper")
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
			if pid > 0 && isWallpaperProcess(pid) {
				log.Printf("⚠️  检测到旧实例 (PID: %d)，正在终止...", pid)
				proc, err := os.FindProcess(pid)
				if err == nil {
					log.Println("📡 发送 SIGTERM 信号...")
					proc.Signal(syscall.SIGTERM)
					// 等待释放：轮询进程是否仍然持有锁
					done := false
					for i := 0; i < 50; i++ { // 最多等 5 秒
						time.Sleep(100 * time.Millisecond)
						if l, e := lock.TryLock(); e == nil && l {
							lock.Unlock() // 临时释放，下面正式获取
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
			} else if pid > 0 {
				log.Printf("⚠️  锁文件指向 PID %d，但该进程非 wallpaper 实例（可能 PID 已被复用），忽略", pid)
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

	// 从嵌入的文件系统中提取模板到临时位置
	templateContent, err := embeddedAssets.ReadFile("assets/player.html")
	if err != nil {
		fmt.Printf("❌ 无法读取内嵌的 HTML 模板: %v\n", err)
		os.Exit(1)
	}

	// 替换静音占位符
	mutedAttr := ""
	if mute {
		mutedAttr = "muted"
	}
	templateStr := strings.ReplaceAll(string(templateContent), "{{MUTED}}", mutedAttr)
	templateContent = []byte(templateStr)

	// 创建临时 HTML 文件
	tmpFile, err := os.CreateTemp("", "player-*.html")
	if err != nil {
		fmt.Printf("❌ 无法创建临时文件: %v\n", err)
		os.Exit(1)
	}
	defer os.Remove(tmpFile.Name())

	if _, err := tmpFile.Write(templateContent); err != nil {
		tmpFile.Close()
		fmt.Printf("❌ 无法写入模板数据: %v\n", err)
		os.Exit(1)
	}
	tmpFile.Close()

	templatePath := tmpFile.Name()

	// 初始化壁纸
	fmt.Printf("🎬 正在启动动态壁纸: %s\n", filepath.Base(absPath))
	fmt.Println("🔋 省电特性:")
	fmt.Println("   • Metal 硬件加速解码")
	fmt.Println("   • 锁屏/睡眠自动暂停")
	fmt.Println("   • 5分钟无操作自动暂停")
	if mute {
		fmt.Println("   • 静音播放（已禁用音频）")
	} else {
		fmt.Println("   • 音频输出（可使用 --mute 禁用）")
	}
	fmt.Println("   • ⌘⇧P 暂停/恢复播放")
	fmt.Println()

	// --dir 模式：扫描目录，设置播放列表
	if dirPath != "" {
		files, err := scanDir(dirPath)
		if err == nil && len(files) > 0 {
			joined := strings.Join(files, "|")
			cPlaylist := C.CString(joined)
			C.SetPlaylist(cPlaylist)
			C.free(unsafe.Pointer(cPlaylist))
			if len(files) > 1 {
				fmt.Printf("🎵 播放列表: %d 个文件（自动顺序播放）\n\n", len(files))
			}
			// 用列表第一个作为初始视频
			absPath, _ = filepath.Abs(files[0])
		}
	}

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
	fmt.Println("💡 全局快捷键 ⌘⇧P 可暂停/恢复播放")

	// 运行主事件循环（阻塞主线程）
	log.Println("🚀 启动主事件循环 (RunApp)")
	C.RunApp()

	// 主循环结束后清理
	log.Println("🧹 主循环结束，执行最终清理")
	C.CleanupWallpaper()
}

func startBackground() error {
	// 前置验证：在启动后台进程前检查基本条件，确保错误能输出到前台
	if videoPath == "" && dirPath == "" {
		return fmt.Errorf("视频路径或目录不能为空")
	}

	// --dir 模式：扫描目录，把 --dir 替换成显式的 --video（第一个文件）
	// 这样 daemon 子进程能直接走 --video 分支，避免子进程丢失视频路径
	dirInArgs := dirPath != ""
	if dirInArgs {
		files, err := scanDir(dirPath)
		if err != nil {
			return fmt.Errorf("扫描目录失败: %v", err)
		}
		if len(files) == 0 {
			return fmt.Errorf("目录 %s 中没有 mp4/mov 文件", dirPath)
		}
		videoPath = files[0]
	}

	absPath, err := filepath.Abs(videoPath)
	if err != nil {
		return fmt.Errorf("无效的视频路径: %v", err)
	}

	// 检查视频文件是否存在
	if _, err := os.Stat(absPath); os.IsNotExist(err) {
		return fmt.Errorf("视频文件不存在: %s", absPath)
	}

	// 检查视频格式
	if !strings.HasSuffix(strings.ToLower(absPath), ".mp4") && !strings.HasSuffix(strings.ToLower(absPath), ".mov") {
		return fmt.Errorf("仅支持 .mp4/.mov 格式视频")
	}

	// 检查嵌入的模板
	if _, err := embeddedAssets.ReadFile("assets/player.html"); err != nil {
		return fmt.Errorf("内嵌的 HTML 模板损坏: %v", err)
	}

	// 所有验证通过，启动后台进程
	exePath, err := os.Executable()
	if err != nil {
		return err
	}

	// 构造子进程参数：从原 os.Args 中剥离 --dir（及其值），其余原样保留
	args := make([]string, 0, len(os.Args))
	hasDaemon := false
	hasVideo := false
	skipNext := false
	for _, arg := range os.Args[1:] {
		if skipNext {
			// 上一个 token 是裸 --dir，当前 token 是它的值，跳过
			skipNext = false
			continue
		}
		if arg == "--daemon" || strings.HasPrefix(arg, "--daemon=") {
			hasDaemon = true
		}
		if arg == "--video" || strings.HasPrefix(arg, "--video=") {
			hasVideo = true
		}
		if arg == "--dir" {
			skipNext = true // 下一个参数是目录路径，一并丢弃
			continue
		}
		if strings.HasPrefix(arg, "--dir=") {
			continue // --dir=xxx 自包含，直接跳过
		}
		args = append(args, arg)
	}

	// --dir 模式：注入解析出的 --video（绝对路径），让子进程走单文件分支
	if dirInArgs && !hasVideo {
		args = append(args, "--video", absPath)
	}

	if !hasDaemon {
		args = append(args, "--daemon")
	}

	proc := exec.Command(exePath, args...)
	proc.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	devNull, err := os.OpenFile("/dev/null", os.O_RDWR, 0)
	if err != nil {
		return err
	}
	proc.Stdin = devNull
	proc.Stdout = devNull
	proc.Stderr = devNull
	if err := proc.Start(); err != nil {
		devNull.Close()
		return err
	}
	devNull.Close()
	return proc.Process.Release()
}

func stopWallpaper() {
	pid, err := readPID()
	if err != nil || pid == 0 {
		fmt.Println("⚠️  未检测到运行中的壁纸实例")
		os.Remove(lockFile)
		return
	}

	fmt.Println("🛑 正在停止动态壁纸...")

	// 尝试发送终止信号（进程可能已提前退出，忽略错误）
	if proc, err := os.FindProcess(pid); err == nil {
		proc.Signal(syscall.SIGTERM)
	}

	// 等待锁释放（内核会在进程退出时自动释放文件锁）
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

	// 超时兜底：强制 Kill 后再做最后一次锁检查
	if isWallpaperProcess(pid) {
		fmt.Println("⚠️  优雅停止超时，强制结束进程...")
		if proc, err := os.FindProcess(pid); err == nil {
			proc.Kill()
		}
		for i := 0; i < 10; i++ { // 再等 1 秒
			time.Sleep(100 * time.Millisecond)
			if l, _ := lock.TryLock(); l {
				lock.Unlock()
				os.Remove(lockFile)
				fmt.Println("✅ 壁纸已强制停止")
				return
			}
		}
	}
	fmt.Println("⚠️  停止操作超时，请手动检查（ps aux | grep wallpaper）")
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
	showPowerInfo()
}

func showPowerInfo() {
	// 电池电量与电源来源（3 秒超时）
	ctxBatt, cancelBatt := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancelBatt()
	if out, err := exec.CommandContext(ctxBatt, "pmset", "-g", "batt").Output(); err == nil {
		output := string(out)

		var source string
		if strings.Contains(output, "AC Power") {
			source = "接通电源"
		} else if strings.Contains(output, "Battery Power") {
			source = "使用电池"
		}

		re := regexp.MustCompile(`(\d+)%`)
		if m := re.FindStringSubmatch(output); len(m) >= 2 {
			line := fmt.Sprintf("🔋 电池: %s%%", m[1])
			if source != "" {
				line += fmt.Sprintf(" (%s)", source)
			}
			fmt.Println(line)
		}
	}

	// 系统功耗（3 秒超时）
	// Intel Mac：SystemPowerIn 字段，Apple Silicon：电池电流×电压
	ctxPower, cancelPower := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancelPower()
	if out, err := exec.CommandContext(ctxPower, "ioreg", "-r", "-c", "AppleSmartBattery").Output(); err == nil {
		output := string(out)
		var powerMW int

		// 优先尝试 SystemPowerIn（Intel Mac）
		re := regexp.MustCompile(`"SystemPowerIn"\s*=\s*(\d+)`)
		if m := re.FindStringSubmatch(output); len(m) >= 2 {
			if mw, err := strconv.Atoi(m[1]); err == nil && mw > 0 {
				powerMW = mw
			}
		}

		// Apple Silicon：从电池放电电流×电压计算（不插电时 Amperage 为负值）
		if powerMW == 0 {
			volRe := regexp.MustCompile(`"AppleRawBatteryVoltage"\s*=\s*(\d+)`)
			ampRe := regexp.MustCompile(`"Amperage"\s*=\s*(\d+)`)
			volM := volRe.FindStringSubmatch(output)
			ampM := ampRe.FindStringSubmatch(output)
			if len(volM) >= 2 && len(ampM) >= 2 {
				if voltage, err := strconv.Atoi(volM[1]); err == nil && voltage > 0 {
					// Amperage 是 int64，ioreg 按 uint64 打印
					if amperageRaw, err := strconv.ParseUint(ampM[1], 10, 64); err == nil {
						amperage := int64(amperageRaw)
						if amperage < 0 {
							amperage = -amperage // 放电取绝对值
						}
						if amperage > 0 {
							// P(W) = I(A) × V(V) = I(mA) × V(mV) / 1e6
							powerMW = int(int64(voltage) * amperage / 1000)
						}
					}
				}
			}
		}

		if powerMW > 0 {
			fmt.Printf("⚡ 系统功耗: %.1fW\n", float64(powerMW)/1000)
		}
	}
}

func scanDir(dir string) ([]string, error) {
	absDir, err := filepath.Abs(dir)
	if err != nil {
		return nil, err
	}
	entries, err := os.ReadDir(absDir)
	if err != nil {
		return nil, err
	}
	var files []string
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		name := strings.ToLower(e.Name())
		if strings.HasSuffix(name, ".mp4") || strings.HasSuffix(name, ".mov") {
			// 统一返回绝对路径，避免 daemon 子进程与 ObjC 加载时的相对路径问题
			files = append(files, filepath.Join(absDir, e.Name()))
		}
	}
	sort.Strings(files)
	return files, nil
}

func writePID() {
	if err := os.WriteFile(lockFile, []byte(fmt.Sprintf("%d", os.Getpid())), 0644); err != nil {
		log.Printf("⚠️  写入 PID 文件失败: %v", err)
	}
}

func readPID() (int, error) {
	data, err := os.ReadFile(lockFile)
	if err != nil {
		return 0, err
	}
	var pid int
	if _, err := fmt.Sscanf(string(data), "%d", &pid); err != nil || pid == 0 {
		return 0, fmt.Errorf("无效的 PID 文件内容: %s", strings.TrimSpace(string(data)))
	}
	return pid, nil
}

// isWallpaperProcess 校验给定 PID 指向的进程是否是本程序（避免 PID 复用后误杀无关进程）。
// 通过 ps 读取进程的可执行路径名，与本二进制名（wallpaper）做后缀匹配。
func isWallpaperProcess(pid int) bool {
	selfName := filepath.Base(os.Args[0])
	out, err := exec.Command("ps", "-p", strconv.Itoa(pid), "-o", "comm=").Output()
	if err != nil {
		return false
	}
	comm := strings.TrimSpace(string(out))
	if comm == "" {
		return false
	}
	// comm 可能是绝对路径或纯名字，统一取 basename 比较
	return filepath.Base(comm) == selfName
}
