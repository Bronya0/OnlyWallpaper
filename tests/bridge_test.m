#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#import <Carbon/Carbon.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>

// 在独立测试进程里替换系统输入，不切换应用、不锁屏、不打开壁纸窗口。
static BOOL gTestDisplaySleeping = NO;
static boolean_t testDisplayIsAsleep(CGDirectDisplayID display) { return gTestDisplaySleeping; }
static NSArray<NSDictionary *> *gTestWindows;
static BOOL gTestWindowInfoAvailable = YES;
static CGWindowListOption gTestWindowOptions;
static NSUInteger gTestWindowQueries = 0;
static CFArrayRef testWindowList(CGWindowListOption options, CGWindowID relativeToWindow) {
    gTestWindowOptions = options;
    gTestWindowQueries++;
    return gTestWindowInfoAvailable ? CFBridgingRetain(gTestWindows) : NULL;
}
#define CGDisplayIsAsleep testDisplayIsAsleep
#define CGWindowListCopyWindowInfo testWindowList
#import "../bridge.m"
#undef CGDisplayIsAsleep
#undef CGWindowListCopyWindowInfo

@interface TestApplication : NSObject
@property (copy) NSString *bundleIdentifier;
@property pid_t processIdentifier;
@end
@implementation TestApplication
@end

@interface TestWebView : NSObject
@property (copy) NSString *lastJavaScript;
@property NSUInteger calls;
- (void)evaluateJavaScript:(NSString *)script completionHandler:(void (^)(id, NSError *))handler;
@end
@implementation TestWebView
- (void)evaluateJavaScript:(NSString *)script completionHandler:(void (^)(id, NSError *))handler {
    self.lastJavaScript = script;
    self.calls++;
}
@end

static TestApplication *gTestApplication;
static NSNotificationCenter *gTestNotificationCenter;
static NSUInteger gPassed = 0;
static NSUInteger gFailed = 0;
static id testFrontmostApplication(id self, SEL selector) { return gTestApplication; }
static id testNotificationCenter(id self, SEL selector) { return gTestNotificationCenter; }

static void check(BOOL condition, const char *name) {
    printf("%s %s\n", condition ? "PASS" : "FAIL", name);
    if (condition) gPassed++; else gFailed++;
}
static void post(NSNotificationName name) {
    [gTestNotificationCenter postNotificationName:name object:nil];
}
static BOOL hasState(TestWebView *view, BOOL manual, BOOL automatic) {
    NSString *state = [NSString stringWithFormat:@"window.setPlaybackState(%@,%@);",
                       manual ? @"true" : @"false", automatic ? @"true" : @"false"];
    return [view.lastJavaScript containsString:state];
}

static NSDictionary *windowInfo(pid_t pid, NSInteger layer, double alpha, CGRect bounds) {
    return @{
        (__bridge id)kCGWindowOwnerPID: @(pid),
        (__bridge id)kCGWindowLayer: @(layer),
        (__bridge id)kCGWindowAlpha: @(alpha),
        (__bridge id)kCGWindowBounds: CFBridgingRelease(CGRectCreateDictionaryRepresentation(bounds))
    };
}

int main(void) {
    @autoreleasepool {
        gTestApplication = [[TestApplication alloc] init];
        gTestApplication.bundleIdentifier = @"com.apple.finder";
        gTestApplication.processIdentifier = 4242;
        gTestWindows = @[];
        gTestNotificationCenter = [[NSNotificationCenter alloc] init];
        Method appMethod = class_getInstanceMethod(NSWorkspace.class, @selector(frontmostApplication));
        Method centerMethod = class_getInstanceMethod(NSWorkspace.class, @selector(notificationCenter));
        IMP originalApp = method_setImplementation(appMethod, (IMP)testFrontmostApplication);
        IMP originalCenter = method_setImplementation(centerMethod, (IMP)testNotificationCenter);

        TestWebView *view = [[TestWebView alloc] init];
        WallpaperInstance *instance = [[WallpaperInstance alloc] init];
        instance.webView = (WKWebView *)view;
        gInstances = [NSMutableArray arrayWithObject:instance];
        setupSystemNotifications();
        check(hasState(view, NO, NO), "startup checks Finder focus");
        check(gFocusTimer != nil, "Finder window refresh timer starts");

        gTestApplication.bundleIdentifier = @"test.other.application";
        post(NSWorkspaceDidActivateApplicationNotification);
        check(hasState(view, NO, YES), "workspace activation notification pauses other apps");
        hotkeyHandler(NULL, NULL, NULL);
        gTestApplication.bundleIdentifier = @"com.apple.finder";
        post(NSWorkspaceDidActivateApplicationNotification);
        check(hasState(view, YES, NO), "returning to Finder preserves manual pause");
        hotkeyHandler(NULL, NULL, NULL);
        check(hasState(view, NO, NO), "hotkey releases manual pause on desktop");

        gTestApplication.bundleIdentifier = @"test.other.application";
        post(NSWorkspaceDidActivateApplicationNotification);
        hotkeyHandler(NULL, NULL, NULL);
        hotkeyHandler(NULL, NULL, NULL);
        check(hasState(view, NO, YES), "hotkey cannot override focus pause");
        WallpaperDelegate *delegate = [[WallpaperDelegate alloc] init];
        [delegate webView:(WKWebView *)view didFinishNavigation:nil];
        check(hasState(view, NO, YES) && ![view.lastJavaScript containsString:@"v.play("],
              "new page applies focus gate instead of unconditional play");
        gPlaylist = @[@"fixture-a.mp4", @"fixture-b.mp4"];
        NSUInteger before = view.calls;
        onPlaybackTimer(nil);
        check(view.calls == before, "playlist timer skips paused webview");
        gPlaylist = nil;

        gTestApplication.bundleIdentifier = @"com.apple.finder";
        post(NSWorkspaceDidActivateApplicationNotification);
        post(NSWorkspaceScreensDidSleepNotification);
        post(NSWorkspaceWillSleepNotification);
        check(hasState(view, NO, YES), "system and display sleep pause");
        post(NSWorkspaceDidWakeNotification);
        check(hasState(view, NO, YES), "system wake cannot override sleeping display");
        post(NSWorkspaceScreensDidWakeNotification);
        check(hasState(view, NO, NO), "display wake resumes on desktop");
        gTestDisplaySleeping = YES;
        post(NSWorkspaceDidWakeNotification);
        check(hasState(view, NO, YES), "dark wake stays paused");
        gTestDisplaySleeping = NO;
        post(NSWorkspaceScreensDidWakeNotification);

        NSDictionary *finderWindow = windowInfo(4242, 0, 1, CGRectMake(10, 10, 600, 400));
        gTestWindows = @[finderWindow];
        onFocusTimer(nil);
        check(hasState(view, NO, YES), "opening Finder window without app activation pauses");
        check(gTestWindowOptions == (kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements),
              "window query excludes minimized/off-space windows and desktop elements");
        before = view.calls;
        onFocusTimer(nil);
        check(view.calls == before, "unchanged Finder window state does not broadcast JS");
        hotkeyHandler(NULL, NULL, NULL);
        gTestWindows = @[]; // 最小化/关闭的窗口不在 OnScreenOnly 返回值中
        onFocusTimer(nil);
        check(hasState(view, YES, NO), "closing Finder window preserves manual pause");
        hotkeyHandler(NULL, NULL, NULL);
        check(hasState(view, NO, NO), "closing Finder window permits desktop playback");
        gTestWindows = @[finderWindow];
        onFocusTimer(nil);
        gTestWindows = @[];
        onFocusTimer(nil);
        check(hasState(view, NO, NO), "minimizing last Finder window resumes automatically");
        gTestWindows = @[
            windowInfo(9999, 0, 1, CGRectMake(0, 0, 600, 400)),
            windowInfo(4242, -1, 1, CGRectMake(0, 0, 600, 400)),
            windowInfo(4242, 0, 0, CGRectMake(0, 0, 600, 400)),
            windowInfo(4242, 0, 1, CGRectMake(0, 0, 0, 400))
        ];
        onFocusTimer(nil);
        check(hasState(view, NO, NO), "unrelated desktop transparent and empty windows do not pause");
        gTestWindows = @[[NSDictionary dictionaryWithObjectsAndKeys:
            @4242, (__bridge id)kCGWindowOwnerPID, @0, (__bridge id)kCGWindowLayer,
            @1, (__bridge id)kCGWindowAlpha, @"invalid", (__bridge id)kCGWindowBounds, nil]];
        onFocusTimer(nil);
        check(hasState(view, NO, NO), "invalid bounds are ignored safely");
        gTestWindowInfoAvailable = NO;
        onFocusTimer(nil);
        check(hasState(view, NO, YES), "unavailable window list fails closed");
        gTestWindowInfoAvailable = YES;
        gTestWindows = @[];
        onFocusTimer(nil);
        gTestApplication.bundleIdentifier = @"test.other.application";
        post(NSWorkspaceDidActivateApplicationNotification);
        NSUInteger queries = gTestWindowQueries;
        onFocusTimer(nil);
        check(queries == gTestWindowQueries, "other foreground apps do not poll Finder windows");
        gTestWindows = @[finderWindow];
        gTestApplication.bundleIdentifier = @"com.apple.finder";
        post(NSWorkspaceDidActivateApplicationNotification);
        check(hasState(view, NO, YES), "activating Finder with an existing window stays paused");
        gTestWindows = @[];
        onFocusTimer(nil);

        post(NSWorkspaceSessionDidResignActiveNotification);
        post(NSWorkspaceSessionDidBecomeActiveNotification);
        post(NSWorkspaceSessionDidResignActiveNotification);
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.6]];
        check(hasState(view, NO, YES), "delayed unlock callback cannot override a new lock");
        gSessionInactive = NO;
        gTestApplication = nil;
        post(NSWorkspaceDidActivateApplicationNotification);
        check(hasState(view, NO, YES), "unknown foreground app stays paused");

        CleanupWallpaper();
        gSystemSleeping = NO;
        post(NSWorkspaceWillSleepNotification);
        check(!gSystemSleeping && gNotificationObservers == nil, "cleanup removes workspace observers");
        check(gFocusTimer == nil, "cleanup stops Finder window refresh timer");
        method_setImplementation(appMethod, originalApp);
        method_setImplementation(centerMethod, originalCenter);
        printf("%lu passed, %lu failed\n", (unsigned long)gPassed, (unsigned long)gFailed);
        return gFailed == 0 ? 0 : 1;
    }
}
