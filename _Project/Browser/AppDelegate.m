//
//  AppDelegate.m
//  Browser
//
//  Created by Steven Troughton-Smith on 20/09/2015.
//  Improved by Jip van Akker on 14/10/2015 through 10/01/2019
//

#import "AppDelegate.h"
#import "BrowserPreferencesStore.h"
#import "BrowserWebView.h"

@interface AppDelegate ()

@end

static NSUInteger const kBrowserURLCacheMemoryCapacity = 32 * 1024 * 1024;
static NSUInteger const kBrowserURLCacheDiskCapacity = 256 * 1024 * 1024;

// build-20: crash breadcrumbs.
//
// "The app sometimes quits while a page loads" cannot be diagnosed by reading the source and
// guessing which subscript could go out of range -- the previous attempt fixed one real bounds
// bug and the report came back unchanged. So the app now records why it died:
//
//   * NSSetUncaughtExceptionHandler catches Objective-C exceptions (NSRangeException,
//     NSInvalidArgumentException, ...) and writes name/reason/stack before the process exits.
//   * A last-checkpoint breadcrumb is written on every navigation start/finish, so the file
//     also shows which site was loading, which is the one fact no crash log on a TV gives you.
//
// The file lives in the app's own container and is readable over the network through the
// existing file-serving path; it is appended, never truncated, so several crashes accumulate.
static NSString *BrowserCrashLogPath(void) {
    static NSString *path = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *dir = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
        if (dir.length == 0) {
            dir = NSTemporaryDirectory();
        }
        path = [dir stringByAppendingPathComponent:@"browser-crash.log"];
    });
    return path;
}

static void BrowserAppendCrashLog(NSString *text) {
    if (text.length == 0) {
        return;
    }
    NSString *path = BrowserCrashLogPath();
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) {
        [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        return;
    }
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (handle == nil) {
        return;
    }
    @try {
        [handle seekToEndOfFile];
        [handle writeData:[text dataUsingEncoding:NSUTF8StringEncoding]];
    } @catch (NSException *exception) {
        // Never let logging itself become the crash.
        NSLog(@"[CrashLog] append failed: %@", exception);
    } @finally {
        [handle closeFile];
    }
}

static void BrowserUncaughtExceptionHandler(NSException *exception) {
    NSString *stamp = [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                     dateStyle:NSDateFormatterMediumStyle
                                                     timeStyle:NSDateFormatterMediumStyle];
    NSMutableString *report = [NSMutableString string];
    [report appendFormat:@"\n===== %@ =====\n", stamp];
    [report appendFormat:@"exception: %@\n", exception.name];
    [report appendFormat:@"reason: %@\n", exception.reason];
    [report appendString:@"symbols:\n"];
    for (NSString *line in exception.callStackSymbols) {
        [report appendFormat:@"  %@\n", line];
    }
    for (NSString *key in exception.userInfo) {
        [report appendFormat:@"userInfo[%@]: %@\n", key, exception.userInfo[key]];
    }
    NSLog(@"[Crash] %@: %@", exception.name, exception.reason);
    BrowserAppendCrashLog(report);
}

/// Called by the browser before each navigation so the log shows what was loading.
void BrowserRecordNavigationCheckpoint(NSString *URLString) {
    NSString *stamp = [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                     dateStyle:NSDateFormatterNoStyle
                                                     timeStyle:NSDateFormatterMediumStyle];
    BrowserAppendCrashLog([NSString stringWithFormat:@"[%@] navigating: %@\n", stamp,
                           URLString.length > 300 ? [URLString substringToIndex:300] : URLString]);
}

@implementation AppDelegate

- (void)restoreCookiesFromDefaults {
    NSData *cookieData = [[NSUserDefaults standardUserDefaults] objectForKey:@"ApplicationCookie"];
    if (cookieData.length == 0) {
        return;
    }

    [BrowserWebView restoreCookiesFromData:cookieData];
}

- (void)saveCookiesToDefaults {
    NSData *cookieData = [BrowserWebView cookieDataRepresentation];
    if (cookieData == nil) {
        return;
    }
    
    [[NSUserDefaults standardUserDefaults] setObject:cookieData forKey:@"ApplicationCookie"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}


- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
	// Override point for customization after application launch.
    // Install the crash recorder before anything else can fail: from here on a probabilistic
    // termination leaves a reason behind instead of just (crashed).
    NSSetUncaughtExceptionHandler(&BrowserUncaughtExceptionHandler);
    NSLog(@"[CrashLog] uncaught exception handler installed at %@", BrowserCrashLogPath());
    BrowserAppendCrashLog([NSString stringWithFormat:@"\n--- launch %@ ---\n",
                           [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                         dateStyle:NSDateFormatterMediumStyle
                                                         timeStyle:NSDateFormatterMediumStyle]]);
    // The default shared cache on tvOS is tiny, so CSS/JS/images get re-downloaded on every page
    // and even on every revisit. A real cache is the single biggest page-load win here.
    NSURLCache *browserCache = [[NSURLCache alloc] initWithMemoryCapacity:kBrowserURLCacheMemoryCapacity
                                                            diskCapacity:kBrowserURLCacheDiskCapacity
                                                                diskPath:@"BrowserURLCache"];
    [NSURLCache setSharedURLCache:browserCache];
    NSLog(@"[Cache] shared URL cache configured memory=%lu disk=%lu",
          (unsigned long)kBrowserURLCacheMemoryCapacity,
          (unsigned long)kBrowserURLCacheDiskCapacity);
    // build-16: honour the three-state UA mode (desktop Safari / mobile Safari / desktop Chrome)
    // instead of unconditionally rewriting the UA as desktop or mobile Safari.
    [[BrowserPreferencesStore new] applyUserAgentForCurrentMode];
    [self restoreCookiesFromDefaults];
	return YES;
}

- (void)applicationWillResignActive:(UIApplication *)application {
	// Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
	// Use this method to pause ongoing tasks, disable timers, and throttle down OpenGL ES frame rates. Games should use this method to pause the game.
    [self saveCookiesToDefaults];
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
	// Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later.
	// If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
    [self saveCookiesToDefaults];
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
	// Called as part of the transition from the background to the inactive state; here you can undo many of the changes made on entering the background.
    [self restoreCookiesFromDefaults];
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
	// Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
    [self restoreCookiesFromDefaults];
}

- (void)applicationWillTerminate:(UIApplication *)application {
	// Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
    [self saveCookiesToDefaults];
}

@end
