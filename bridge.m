#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#import <Carbon/Carbon.h>
#import <objc/runtime.h>
#import "bridge.h"

static NSWindow *wallpaperWindow = nil;
static WKWebView *webView = nil;
static id webDelegate = nil;
static NSString *currentTempHTMLPath = nil;
static EventHotKeyRef gPauseHotKey = NULL;
static NSArray<NSString*> *gPlaylist = nil;
static NSUInteger gCurrentVideoIndex = 0;
static NSString *gTemplatePath = nil;
static NSTimer *gPlaybackTimer = nil;

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
    NSLog(@"📄 生成临时文件: %@", tempPath);
    
    [html writeToFile:tempPath atomically:YES encoding:NSUTF8StringEncoding error:&err];
    
    if (err) return nil;
    return tempPath;
}

// MARK: - Objective-C 实现
@interface WallpaperDelegate : NSObject<WKNavigationDelegate>
@end

@implementation WallpaperDelegate
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    NSString *js = @"const v=document.getElementById('bg'); if(v){v.play().catch(()=>{});}";
    if (gPlaylist) {
        // 列表模式：关掉 loop，由 ObjC 检测视频结束切下一首
        js = @"const v=document.getElementById('bg'); if(v){v.loop=false;v.play().catch(()=>{});}";
    }
    [webView evaluateJavaScript:js completionHandler:nil];
}
@end

// MARK: - 全局快捷键（Cmd+Shift+P 暂停/恢复）
static OSStatus hotkeyHandler(EventHandlerCallRef next, EventRef event, void *userData) {
    if (webView) [webView evaluateJavaScript:@"togglePlayback()" completionHandler:nil];
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
        if (webView) [webView evaluateJavaScript:@"externalPause()" completionHandler:nil];
    }];
    
    // 显示器休眠时暂停（锁屏/关屏）
    [nc addObserverForName:NSWorkspaceScreensDidSleepNotification object:nil queue:nil
                  usingBlock:^(NSNotification *note) {
        if (webView) [webView evaluateJavaScript:@"externalPause()" completionHandler:nil];
    }];
    
    // 唤醒时恢复（忽略 Dark Wake：显示器仍休眠则不恢复）
    [nc addObserverForName:NSWorkspaceDidWakeNotification object:nil queue:nil
                  usingBlock:^(NSNotification *note) {
        // Dark Wake 时显示器未点亮，不恢复播放
        if (CGDisplayIsAsleep(kCGDirectMainDisplay)) return;
        if (webView) [webView evaluateJavaScript:@"externalResume()" completionHandler:nil];
    }];
    
    // 用户会话解锁后恢复（覆盖锁屏后解锁场景）
    [nc addObserverForName:NSWorkspaceSessionDidBecomeActiveNotification object:nil queue:nil
                  usingBlock:^(NSNotification *note) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (webView) [webView evaluateJavaScript:@"externalResume()" completionHandler:nil];
        });
    }];
    
    // 应用终止前清理
    [nc addObserverForName:NSApplicationWillTerminateNotification object:nil queue:nil
                  usingBlock:^(NSNotification *note) {
        CleanupWallpaper();
    }];
}

// MARK: - 播放列表（目录顺序播放）
static void loadVideoInList(NSUInteger index) {
    if (!gPlaylist || index >= gPlaylist.count) return;
    gCurrentVideoIndex = index;
    NSString *videoPath = gPlaylist[index];
    NSLog(@"🎬 列表播放 [%lu/%lu]: %@", (unsigned long)(index + 1), (unsigned long)gPlaylist.count, videoPath);
    
    NSString *newHtml = renderHTMLToTempFile(gTemplatePath, videoPath);
    if (!newHtml) return;
    
    if (currentTempHTMLPath) {
        [[NSFileManager defaultManager] removeItemAtPath:currentTempHTMLPath error:nil];
    }
    currentTempHTMLPath = newHtml;
    
    NSURL *htmlURL = [NSURL fileURLWithPath:newHtml];
    [webView loadFileURL:htmlURL allowingReadAccessToURL:[NSURL fileURLWithPath:@"/"]];
}

static void onPlaybackTimer(NSTimer *timer) {
    if (!webView || !gPlaylist) return;
    [webView evaluateJavaScript:@"video && video.ended" completionHandler:^(id result, NSError *error) {
        if ([result boolValue]) {
            NSUInteger next = (gCurrentVideoIndex + 1) % gPlaylist.count;
            loadVideoInList(next);
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
    
    // 启动视频结束检测定时器
    gPlaybackTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
        onPlaybackTimer(t);
    }];
}

// MARK: - C 桥接函数
int InitWallpaper(const char *videoPathC, const char *htmlTemplateC) {
    NSLog(@"🎬 InitWallpaper 被调用");
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
        
        // 渲染 HTML 到临时文件
        NSString *tempHtmlPath = renderHTMLToTempFile(htmlTemplate, videoPath);
        if (!tempHtmlPath) {
            fprintf(stderr, "❌ HTML 渲染失败\n");
            return -1;
        }
        currentTempHTMLPath = [tempHtmlPath copy];
        
        // 创建窗口
        NSRect screenRect = [[NSScreen mainScreen] frame];
        wallpaperWindow = [[NSWindow alloc]
            initWithContentRect:screenRect
                      styleMask:NSWindowStyleMaskBorderless
                        backing:NSBackingStoreBuffered
                          defer:NO];
        
        [wallpaperWindow setLevel:(NSWindowLevel)(CGWindowLevelForKey(kCGDesktopIconWindowLevelKey) - 1)];
        [wallpaperWindow setOpaque:NO];
        [wallpaperWindow setBackgroundColor:[NSColor clearColor]];
        [wallpaperWindow setIgnoresMouseEvents:YES]; // 点击穿透
        [wallpaperWindow setHasShadow:NO];
        [wallpaperWindow setCollectionBehavior:
            NSWindowCollectionBehaviorCanJoinAllSpaces |
            NSWindowCollectionBehaviorStationary |
            NSWindowCollectionBehaviorFullScreenAuxiliary];
        [wallpaperWindow orderFrontRegardless];
        
        // 配置 WKWebView
        WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
        // config.allowsInlineMediaPlayback = YES;
        config.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeNone;
        [config.preferences setValue:@NO forKey:@"developerExtrasEnabled"];
        
        webView = [[WKWebView alloc] initWithFrame:screenRect configuration:config];
        webDelegate = [[WallpaperDelegate alloc] init];
        webView.navigationDelegate = webDelegate;
        [webView setValue:@NO forKey:@"drawsBackground"];
        [wallpaperWindow setContentView:webView];
        
        // 加载 HTML 文件，并授权访问根目录（解决本地视频加载权限问题）
        NSURL *htmlURL = [NSURL fileURLWithPath:tempHtmlPath];
        NSURL *accessURL = [NSURL fileURLWithPath:@"/"];
        [webView loadFileURL:htmlURL allowingReadAccessToURL:accessURL];
        
        // 设置系统通知
        setupSystemNotifications();
        // 注册全局快捷键
        setupHotkey();
        
        NSLog(@"✅ 壁纸已启动: %@", videoPath);
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
    NSLog(@"🧹 CleanupWallpaper 被调用");
    @autoreleasepool {
        if (gPlaybackTimer) {
            [gPlaybackTimer invalidate];
            gPlaybackTimer = nil;
        }
        gPlaylist = nil;
        gTemplatePath = nil;
        if (gPauseHotKey) {
            UnregisterEventHotKey(gPauseHotKey);
            gPauseHotKey = NULL;
            NSLog(@"⌨️ 快捷键已注销");
        }
        if (wallpaperWindow) {
            [wallpaperWindow close];
            wallpaperWindow = nil;
            webView = nil;
            webDelegate = nil;
            NSLog(@"👋 壁纸已清理");
        }
        if (currentTempHTMLPath) {
            [[NSFileManager defaultManager] removeItemAtPath:currentTempHTMLPath error:nil];
            NSLog(@"🗑️ 临时文件已删除: %@", currentTempHTMLPath);
            currentTempHTMLPath = nil;
        }
    }
}
