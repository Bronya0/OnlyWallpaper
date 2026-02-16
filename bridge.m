#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import "bridge.h"

static NSWindow *wallpaperWindow = nil;
static WKWebView *webView = nil;
static id webDelegate = nil;
static NSString *currentTempHTMLPath = nil;

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
    [webView evaluateJavaScript:@"const v=document.getElementById('bg'); if(v){v.play().catch(()=>{});}" completionHandler:nil];
}
@end

static void setupSystemNotifications() {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    
    // 系统睡眠/锁屏时暂停
    [nc addObserverForName:NSWorkspaceWillSleepNotification object:nil queue:nil
                  usingBlock:^(NSNotification *note) {
        if (webView) [webView evaluateJavaScript:@"externalPause()" completionHandler:nil];
    }];
    
    // 唤醒/解锁时恢复
    [nc addObserverForName:NSWorkspaceDidWakeNotification object:nil queue:nil
                  usingBlock:^(NSNotification *note) {
        if (webView) [webView evaluateJavaScript:@"externalResume()" completionHandler:nil];
    }];
    
    // 应用终止前清理
    [nc addObserverForName:NSApplicationWillTerminateNotification object:nil queue:nil
                  usingBlock:^(NSNotification *note) {
        CleanupWallpaper();
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
        [config.preferences setValue:@YES forKey:@"developerExtrasEnabled"];
        
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

void PauseWallpaper() {
    if (webView) {
        [webView evaluateJavaScript:@"externalPause()" completionHandler:nil];
    }
}

void ResumeWallpaper() {
    if (webView) {
        [webView evaluateJavaScript:@"externalResume()" completionHandler:nil];
    }
}

int IsVideoPaused() {
    __block int result = -1;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    void (^evalBlock)(void) = ^{
        if (!webView) {
            result = -1;
            dispatch_semaphore_signal(sem);
            return;
        }
        [webView evaluateJavaScript:@"isPaused()" completionHandler:^(id res, NSError *err) {
            if (!err && [res isKindOfClass:[NSNumber class]]) {
                result = [res boolValue] ? 1 : 0;
            } else {
                result = -1;
            }
            dispatch_semaphore_signal(sem);
        }];
    };
    if ([NSThread isMainThread]) {
        evalBlock();
    } else {
        dispatch_async(dispatch_get_main_queue(), evalBlock);
    }
    long waitResult = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(300 * NSEC_PER_MSEC)));
    if (waitResult != 0) {
        return -1;
    }
    return result;
}

void CleanupWallpaper() {
    NSLog(@"🧹 CleanupWallpaper 被调用");
    @autoreleasepool {
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
