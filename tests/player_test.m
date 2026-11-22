#import <Foundation/Foundation.h>
#import <JavaScriptCore/JavaScriptCore.h>

static NSString *gPlayerScript;
static NSUInteger gPassed = 0;
static NSUInteger gFailed = 0;

static void runTest(NSString *name, NSString *steps) {
    @autoreleasepool {
        JSContext *context = [[JSContext alloc] init];
        [context evaluateScript:
            @"const window = globalThis;"
             "const listeners = {};"
             "const mockVideo = {currentTime:0, paused:true, playCalls:0,"
             "play(){this.paused=false;this.playCalls++;return {catch(){}};},"
             "pause(){this.paused=true;}};"
             "const document = {hidden:false, getElementById(){return mockVideo;},"
             "addEventListener(name, callback){listeners[name]=callback;}};"
             "function expect(condition, message){if(!condition)throw new Error(message);}"];
        if (!context.exception) [context evaluateScript:gPlayerScript];
        if (!context.exception) [context evaluateScript:steps];
        if (context.exception) {
            fprintf(stderr, "FAIL %s: %s\n", name.UTF8String, context.exception.toString.UTF8String);
            gFailed++;
        } else {
            printf("PASS %s\n", name.UTF8String);
            gPassed++;
        }
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) {
            fprintf(stderr, "Usage: player_test assets/player.html\n");
            return 2;
        }
        NSError *error = nil;
        NSString *html = [NSString stringWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]
                                                   encoding:NSUTF8StringEncoding error:&error];
        if (!html) {
            fprintf(stderr, "Cannot read player: %s\n", error.localizedDescription.UTF8String);
            return 2;
        }
        NSRange start = [html rangeOfString:@"<script>"];
        NSRange end = [html rangeOfString:@"</script>"];
        if (start.location == NSNotFound || end.location == NSNotFound || end.location < NSMaxRange(start)) {
            fprintf(stderr, "Player script not found\n");
            return 2;
        }
        gPlayerScript = [html substringWithRange:NSMakeRange(NSMaxRange(start), end.location - NSMaxRange(start))];
        NSRegularExpression *autoplay = [NSRegularExpression regularExpressionWithPattern:
            @"<video\\b[^>]*\\bautoplay\\b" options:0 error:nil];
        if ([autoplay numberOfMatchesInString:html options:0 range:NSMakeRange(0, html.length)] != 0) {
            fprintf(stderr, "FAIL native state must arrive before autoplay\n");
            gFailed++;
        } else {
            printf("PASS no autoplay before native state\n");
            gPassed++;
        }

        runTest(@"initial page stays paused", @"expect(video.paused && window.autoPaused && video.playCalls===0, 'initial playback');");
        for (NSUInteger hidden = 0; hidden < 2; hidden++) {
            for (NSUInteger manual = 0; manual < 2; manual++) {
                for (NSUInteger automatic = 0; automatic < 2; automatic++) {
                    NSString *name = [NSString stringWithFormat:@"pause gates hidden=%lu manual=%lu automatic=%lu",
                                      (unsigned long)hidden, (unsigned long)manual, (unsigned long)automatic];
                    NSString *steps = [NSString stringWithFormat:
                        @"document.hidden=%@;window.setPlaybackState(%@,%@);expect(video.paused===%@, 'pause gates');",
                        hidden ? @"true" : @"false", manual ? @"true" : @"false", automatic ? @"true" : @"false",
                        (hidden || manual || automatic) ? @"true" : @"false"];
                    runTest(name, steps);
                }
            }
        }
        runTest(@"focus away pauses video and preserves position",
            @"window.setPlaybackState(false,false);video.currentTime=12.5;window.setPlaybackState(false,true);"
             "expect(video.paused, 'focus pause');video.currentTime=0;window.setPlaybackState(false,false);"
             "expect(!video.paused && video.currentTime===12.5, 'focus resume position');");
        runTest(@"visibility cannot override focus pause",
            @"window.setPlaybackState(false,true);document.hidden=true;listeners.visibilitychange();"
             "document.hidden=false;listeners.visibilitychange();expect(video.paused && video.playCalls===0, 'focus bypassed');");
        runTest(@"manual pause survives focus and visibility changes",
            @"window.setPlaybackState(false,false);video.currentTime=8;window.setPlaybackState(true,false);"
             "window.setPlaybackState(true,true);document.hidden=true;listeners.visibilitychange();"
             "video.currentTime=0;document.hidden=false;listeners.visibilitychange();window.setPlaybackState(true,false);"
             "expect(video.paused && video.currentTime===8, 'manual pause lost');"
             "window.setPlaybackState(false,false);expect(!video.paused, 'manual release');");
        runTest(@"hotkey release cannot override automatic pause",
            @"window.setPlaybackState(true,true);window.setPlaybackState(false,true);expect(video.paused, 'automatic pause lost');"
             "window.setPlaybackState(false,false);expect(!video.paused, 'automatic release');");
        runTest(@"native resume cannot override hidden page",
            @"window.setPlaybackState(false,false);video.currentTime=20;document.hidden=true;listeners.visibilitychange();"
             "window.setPlaybackState(false,false);expect(video.paused, 'hidden page resumed');"
             "video.currentTime=0;document.hidden=false;listeners.visibilitychange();"
             "expect(!video.paused && video.currentTime===20, 'visible resume position');");
        runTest(@"repeated pause preserves saved frame after decoder reset",
            @"window.setPlaybackState(false,false);video.currentTime=30;window.setPlaybackState(false,true);"
             "document.hidden=true;video.currentTime=0;listeners.visibilitychange();window.setPlaybackState(false,true);"
             "document.hidden=false;listeners.visibilitychange();expect(video.paused && video.currentTime===30, 'saved frame lost');");
        runTest(@"repeated resume does not seek backwards",
            @"window.setPlaybackState(false,false);video.currentTime=10;window.setPlaybackState(false,true);"
             "window.setPlaybackState(false,false);video.currentTime=15;window.setPlaybackState(false,false);"
             "listeners.visibilitychange();expect(video.currentTime===15 && video.playCalls===2, 'repeated resume rewound');");
        runTest(@"new playlist page respects existing manual pause",
            @"window.setPlaybackState(true,false);expect(video.paused && video.playCalls===0, 'playlist bypassed manual pause');");
        runTest(@"new playlist page respects existing focus pause",
            @"window.setPlaybackState(false,true);expect(video.paused && video.playCalls===0, 'playlist bypassed focus pause');");

        printf("%lu passed, %lu failed\n", (unsigned long)gPassed, (unsigned long)gFailed);
        return gFailed == 0 ? 0 : 1;
    }
}
