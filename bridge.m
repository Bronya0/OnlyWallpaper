#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#import <Carbon/Carbon.h>
#import <objc/runtime.h>
#import "bridge.h"

// MARK: - 每个显示器的壁纸实例（多屏支持）
// 一个外接显示器对应一个 WallpaperInstance，各自独立的 window + WKWebView，
// 切歌/暂停等控制由 ObjC 侧统一广播到所有实例。
@interface WallpaperInstance : NSObject
@property (strong) NSWindow *window;
@property (strong) WKWebView *webView;
@property (strong) id navigationDelegate; // WallpaperDelegate 实例
@property (copy)   NSString *tempHTMLPath;
@property (weak)   NSScreen *screen;
@end

@implementation WallpaperInstance
@end

// MARK: - 全局状态
static NSMutableArray<WallpaperInstance *> *gInstances = nil; // 每屏一个实例
static NSUInteger gMasterIndex = 0;     // 权威源（切歌检测以 master 为准）
static BOOL gUserPaused = NO;           // 全局手动暂停标志（统一管理，多屏同步）
static NSString *gTemplatePath = nil;   // 当前 HTML 模板路径（全局共享）
static NSArray<NSString*> *gPlaylist = nil;
static NSUInteger gCurrentVideoIndex = 0;
static NSTimer *gPlaybackTimer = nil;
static EventHotKeyRef gPauseHotKey = NULL;
static BOOL gCleanedUp = NO;            // CleanupWallpaper 幂等守卫，避免双重清理导致 SIGSEGV

// MARK: - 辅助函数
static NSString *renderHTMLToTempFile(NSString *templatePath, NSString *videoPath) {
    NSError *err = nil;
    NSString *html = [NSString stringWithContentsOfFile:templatePath
                                               encoding:NSUTF8StringEncoding
                                                  error:&err];
    if (err) return nil;
    
    // 使用 NSURL 处理路径，确保编码正确
    NSURL *videoURL = [NSURL fileURLWithPath:videoPath];
    NSString *fileURL = [videoURL absoluteString];
    
    html = [html stringByReplacingOccurrencesOfString:@"{{VIDEO_PATH}}"
                                          withString:fileURL];
                                          
    // 写入临时文件
    NSString *tempDir = NSTemporaryDirectory();
    NSString *uuid = [[NSUUID UUID] UUIDString];
    NSString *fileName = [NSString stringWithFormat:@"wallpaper_%@.html", uuid];
    NSString *tempPath = [tempDir stringByAppendingPathComponent:fileName];
    
    [html writeToFile:tempPath atomically:YES encoding:NSUTF8StringEncoding error:&err];
    
    if (err) return nil;
    return tempPath;
}

// 对所有实例广播 JS（忽略 nil webview）
static void broadcastJS(NSString *js) {
    if (!gInstances) return;
    for (WallpaperInstance *inst in gInstances) {
        if (inst.webView) {
            [inst.webView evaluateJavaScript:js completionHandler:nil];
        }
    }
}

// MARK: - WKNavigationDelegate
@interface WallpaperDelegate : NSObject<WKNavigationDelegate>
@end

@implementation WallpaperDelegate
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    NSString *js = @"const v=document.getElementById('bg'); if(v){v.play().catch(()=>{});}";
    if (gPlaylist.count > 1) {
        // 多文件列表：关掉 loop，由 ObjC 检测视频结束切下一首。
        // 单文件列表保持 HTML 原生 loop，避免每次播完整页重载产生黑屏闪烁
        js = @"const v=document.getElementById('bg'); if(v){v.loop=false;v.play().catch(()=>{});}";
    }
    [webView evaluateJavaScript:js completionHandler:nil];
}
@end

// MARK: - 全局快捷键（Cmd+Shift+P 暂停/恢复）
// 多屏同步：翻转全局 gUserPaused，对所有 webview 统一 pause/resume
// 同时把 userPaused 状态同步到每个 webview 的 window.userPaused，
// 使得 visibilitychange 的 visible 分支能与 ObjC 守卫保持一致
static OSStatus hotkeyHandler(EventHandlerCallRef next, EventRef event, void *userData) {
    gUserPaused = !gUserPaused;
    // 同步 JS 侧的 userPaused 标志（visibilitychange 依赖它判断是否自动恢复）
    broadcastJS([NSString stringWithFormat:@"window.userPaused=%@;", gUserPaused ? @"true" : @"false"]);
    if (gUserPaused) {
        broadcastJS(@"externalPause()");
    } else {
        broadcastJS(@"externalResume()");
    }
    return noErr;
}

static void setupHotkey() {
    EventTypeSpec eventSpec = {kEventClassKeyboard, kEventHotKeyPressed};
    InstallEventHandler(GetEventDispatcherTarget(), hotkeyHandler, 1, &eventSpec, NULL, NULL);
    EventHotKeyID hotKeyID = {'WpP1', 1};
    RegisterEventHotKey(kVK_ANSI_P, cmdKey + shiftKey, hotKeyID, GetEventDispatcherTarget(), 0, &gPauseHotKey);
}

static void setupSystemNotifications() {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    
    // 系统睡眠时暂停（盒盖休眠）
    [nc addObserverForName:NSWorkspaceWillSleepNotification object:nil queue:nil
                  usingBlock:^(NSNotification *note) {
        broadcastJS(@"externalPause()");
    }];
    
    // 显示器休眠时暂停（锁屏/关屏）
    [nc addObserverForName:NSWorkspaceScreensDidSleepNotification object:nil queue:nil
                  usingBlock:^(NSNotification *note) {
        broadcastJS(@"externalPause()");
    }];
    
    // 唤醒时恢复（忽略 Dark Wake：显示器仍休眠则不恢复）
    [nc addObserverForName:NSWorkspaceDidWakeNotification object:nil queue:nil
                  usingBlock:^(NSNotification *note) {
        if (CGDisplayIsAsleep(kCGDirectMainDisplay)) return;
        // 受全局手动暂停标志守卫：用户按过快捷键暂停则不自动恢复
        if (!gUserPaused) broadcastJS(@"externalResume()");
    }];
    
    // 用户会话锁定（锁屏/快速用户切换）时暂停
    [nc addObserverForName:NSWorkspaceSessionDidResignActiveNotification object:nil queue:nil
                  usingBlock:^(NSNotification *note) {
        broadcastJS(@"externalPause()");
    }];

    // 用户会话解锁后恢复（覆盖锁屏后解锁场景）
    [nc addObserverForName:NSWorkspaceSessionDidBecomeActiveNotification object:nil queue:nil
                  usingBlock:^(NSNotification *note) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!gUserPaused) broadcastJS(@"externalResume()");
        });
    }];
    // 注：不在 NSApplicationWillTerminateNotification 里调 CleanupWallpaper。
    // NSApp 终止流程中 run loop 上下文不再安全，[window close] 会触发 WKWebView
    // 退出回调访问已失效内存导致 SIGSEGV。统一由 Go 侧 RunApp 返回后调一次
    // CleanupWallpaper（此时已脱离事件循环），由幂等守卫保证不重复执行。
}

// MARK: - 播放列表（目录顺序播放，所有屏同步切歌）
// master 实例的 video.ended 作为权威信号，触发后所有实例统一切到下一首
static void loadVideoInListForAll(NSUInteger index) {
    if (!gPlaylist || index >= gPlaylist.count || gInstances.count == 0) return;
    gCurrentVideoIndex = index;
    NSString *videoPath = gPlaylist[index];
    NSLog(@"🎬 列表播放 [%lu/%lu]: %@", (unsigned long)(index + 1), (unsigned long)gPlaylist.count, videoPath);
    
    NSFileManager *fm = [NSFileManager defaultManager];
    for (WallpaperInstance *inst in gInstances) {
        NSString *newHtml = renderHTMLToTempFile(gTemplatePath, videoPath);
        if (!newHtml) continue;
        
        // 替换该实例的旧临时文件
        if (inst.tempHTMLPath) {
            [fm removeItemAtPath:inst.tempHTMLPath error:nil];
        }
        inst.tempHTMLPath = newHtml;
        
        NSURL *htmlURL = [NSURL fileURLWithPath:newHtml];
        [inst.webView loadFileURL:htmlURL allowingReadAccessToURL:[NSURL fileURLWithPath:@"/"]];
    }
}

static void onPlaybackTimer(NSTimer *timer) {
    if (gInstances.count == 0 || !gPlaylist) return;
    if (gPlaylist.count <= 1) return; // 单文件由 HTML 原生 loop 循环，无需切换
    // 越界保护（理论上仅启动多屏不会动态增减，但防御）
    if (gMasterIndex >= gInstances.count) gMasterIndex = 0;
    WKWebView *master = gInstances[gMasterIndex].webView;
    if (!master) return;
    [master evaluateJavaScript:@"video && video.ended" completionHandler:^(id result, NSError *error) {
        if ([result boolValue]) {
            NSUInteger next = (gCurrentVideoIndex + 1) % gPlaylist.count;
            loadVideoInListForAll(next);
        }
    }];
}

void SetPlaylist(const char *playlist) {
    if (!playlist) return;
    NSString *str = [NSString stringWithUTF8String:playlist];
    if (str.length == 0) return;

    gPlaylist = [str componentsSeparatedByString:@"|"];
    gCurrentVideoIndex = 0;
    NSLog(@"🎬 播放列表已设置: %lu 个文件", (unsigned long)gPlaylist.count);

    // 启动视频结束检测定时器（只检测 master）
    if (gPlaybackTimer) [gPlaybackTimer invalidate];
    gPlaybackTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
        onPlaybackTimer(t);
    }];
}

// MARK: - 在指定显示器上创建壁纸实例
// 返回 nil 表示创建失败，调用方应跳过该屏但不中断其他屏
static WallpaperInstance *createInstanceOnScreen(NSScreen *screen, NSString *videoPath) {
    WallpaperInstance *inst = [[WallpaperInstance alloc] init];
    inst.screen = screen;
    
    // 为该实例渲染独立的临时 HTML（切歌时可干净替换）
    NSString *tempHtmlPath = renderHTMLToTempFile(gTemplatePath, videoPath);
    if (!tempHtmlPath) {
        NSLog(@"❌ 屏 %@ 的 HTML 渲染失败", screen.localizedName);
        return nil;
    }
    inst.tempHTMLPath = tempHtmlPath;
    
    NSRect screenRect = [screen frame];
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:screenRect
                  styleMask:NSWindowStyleMaskBorderless
                    backing:NSBackingStoreBuffered
                      defer:NO];
    
    [window setLevel:(NSWindowLevel)(CGWindowLevelForKey(kCGDesktopIconWindowLevelKey) - 1)];
    [window setOpaque:NO];
    [window setBackgroundColor:[NSColor clearColor]];
    [window setIgnoresMouseEvents:YES]; // 点击穿透
    [window setHasShadow:NO];
    [window setCollectionBehavior:
        NSWindowCollectionBehaviorCanJoinAllSpaces |
        NSWindowCollectionBehaviorStationary |
        NSWindowCollectionBehaviorFullScreenAuxiliary];
    [window orderFrontRegardless];
    // 仅启动多屏：不监听屏幕变化，但窗口需要绑定到具体 screen，避免落到错误显示器
    // NSWindow 默认会在可见的主屏上，需显式指定到目标屏：
    // （注：setFrame 使用目标屏的全局坐标，已通过 initWithContentRect 传入，
    //  但 macOS 会按逻辑坐标放置，多屏下通常无需额外操作。）
    inst.window = window;
    
    // 配置 WKWebView
    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    config.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeNone;
    [config.preferences setValue:@NO forKey:@"developerExtrasEnabled"];
    
    WKWebView *wv = [[WKWebView alloc] initWithFrame:screenRect configuration:config];
    WallpaperDelegate *delegate = [[WallpaperDelegate alloc] init];
    wv.navigationDelegate = delegate;
    [wv setValue:@NO forKey:@"drawsBackground"];
    [window setContentView:wv];
    inst.webView = wv;
    inst.navigationDelegate = delegate;
    
    // 加载 HTML 文件，授权访问根目录
    NSURL *htmlURL = [NSURL fileURLWithPath:tempHtmlPath];
    NSURL *accessURL = [NSURL fileURLWithPath:@"/"];
    [wv loadFileURL:htmlURL allowingReadAccessToURL:accessURL];
    
    return inst;
}

// MARK: - C 桥接函数
int InitWallpaper(const char *videoPathC, const char *htmlTemplateC) {
    @autoreleasepool {
        // 确保 NSApp 初始化
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

        NSString *videoPath = [NSString stringWithUTF8String:videoPathC];
        NSString *htmlTemplate = [NSString stringWithUTF8String:htmlTemplateC];
        
        // 路径校验
        if (![[NSFileManager defaultManager] fileExistsAtPath:videoPath]) {
            fprintf(stderr, "❌ 视频文件不存在: %s\n", videoPathC);
            return -1;
        }
        if (![[NSFileManager defaultManager] fileExistsAtPath:htmlTemplate]) {
            fprintf(stderr, "❌ HTML 模板不存在: %s\n", htmlTemplateC);
            return -1;
        }
        
        // 保存模板路径，供后续切视频时重新生成 HTML
        gTemplatePath = htmlTemplate;
        
        // 遍历所有显示器，每个屏创建一个壁纸实例
        NSArray<NSScreen *> *screens = [NSScreen screens];
        gInstances = [NSMutableArray arrayWithCapacity:screens.count];
        for (NSUInteger i = 0; i < screens.count; i++) {
            NSScreen *screen = screens[i];
            WallpaperInstance *inst = createInstanceOnScreen(screen, videoPath);
            if (inst) {
                [gInstances addObject:inst];
                NSLog(@"🖥️  屏 %lu (%@): 壁纸已创建", (unsigned long)(i + 1), screen.localizedName);
            } else {
                NSLog(@"⚠️  屏 %lu (%@): 创建失败，已跳过", (unsigned long)(i + 1), screen.localizedName);
            }
        }
        
        if (gInstances.count == 0) {
            fprintf(stderr, "❌ 没有任何显示器成功创建壁纸\n");
            return -1;
        }
        gMasterIndex = 0;
        
        NSLog(@"✅ 壁纸已启动: %@（%lu 个显示器）", videoPath, (unsigned long)gInstances.count);
        
        // 设置系统通知
        setupSystemNotifications();
        // 注册全局快捷键
        setupHotkey();
        
        return 0;
    }
}

void StopApp() {
    NSLog(@"🛑 StopApp 被调用，发送退出事件");
    @autoreleasepool {
        // 必须在主线程执行 UI 操作
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSApp stop:nil];
            // 发送一个空事件来唤醒 RunLoop，确保 stop 立即生效
            NSEvent *event = [NSEvent otherEventWithType:NSEventTypeApplicationDefined
                                                location:NSZeroPoint
                                           modifierFlags:0
                                               timestamp:0
                                            windowNumber:0
                                                 context:nil
                                                 subtype:0
                                                   data1:0
                                                   data2:0];
            [NSApp postEvent:event atStart:YES];
        });
    }
}

void RunApp() {
    @autoreleasepool {
        [NSApp run];
    }
}

void CleanupWallpaper() {
    @autoreleasepool {
        // 幂等守卫：本函数会被 NSApplicationWillTerminateNotification 和
        // Go 侧 RunApp 返回后各调用一次，重复清理会访问已释放对象导致 SIGSEGV。
        if (gCleanedUp) return;
        gCleanedUp = YES;
        if (gPlaybackTimer) {
            [gPlaybackTimer invalidate];
            gPlaybackTimer = nil;
        }
        gPlaylist = nil;
        gTemplatePath = nil;
        gUserPaused = NO;
        if (gPauseHotKey) {
            UnregisterEventHotKey(gPauseHotKey);
            gPauseHotKey = NULL;
            NSLog(@"⌨️ 快捷键已注销");
        }
        // 先记录临时文件路径，再清理窗口和文件。
        // 注意：[window close] 会触发 WKWebView web process 异步退出，
        // 在进程整体退出阶段访问其内部状态会 SIGSEGV，故这里只释放强引用，
        // 让窗口随进程退出由 OS 回收，避免主动 close 引发的竞态。
        NSFileManager *fm = [NSFileManager defaultManager];
        NSUInteger count = gInstances.count;
        for (WallpaperInstance *inst in gInstances) {
            if (inst.tempHTMLPath) {
                [fm removeItemAtPath:inst.tempHTMLPath error:nil];
            }
        }
        gInstances = nil;
        if (count > 0) {
            NSLog(@"👋 壁纸已清理（%lu 个显示器）", (unsigned long)count);
        }
    }
}
