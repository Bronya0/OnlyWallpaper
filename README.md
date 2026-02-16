# OnlyWallpaper
OnlyWallpaper

mac壁纸，调用gpu渲染视频h5，这样来省电。
macOS 开发的天条： 所有 UI 操作必须在主线程执行

# 编译
CGO_ENABLED=1 go build -o wallpaper

# 运行
./wallpaper --video /Users/bronya/Movies/屏保/mylivewallpapers-com-Yae-Miko-Watching-the-Rain.mp4

# 停止
./wallpaper --cmd stop
