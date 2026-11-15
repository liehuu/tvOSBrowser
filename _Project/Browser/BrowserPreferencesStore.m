#import "BrowserPreferencesStore.h"

static NSString * const kUserAgentDefaultsKey = @"UserAgent";
static NSString * const kUserAgentModeDefaultsKey = @"UserAgentMode";
static NSString * const kMobileModeDefaultsKey = @"MobileMode";
static NSString * const kShowTopNavigationBarDefaultsKey = @"ShowTopNavigationBar";
static NSString * const kTextFontSizeDefaultsKey = @"TextFontSize";
static NSString * const kEnableFullscreenVideoPlaybackDefaultsKey = @"EnableFullscreenVideoPlayback";
static NSString * const kScalePagesToFitDefaultsKey = @"ScalePagesToFit";
static NSString * const kDontShowHintsOnLaunchDefaultsKey = @"DontShowHintsOnLaunch";
static NSString * const kDontShowFavoritesOnLaunchDefaultsKey = @"DontShowFavoritesOnLaunch";
static NSString * const kHomepageDefaultsKey = @"homepage";

static NSUInteger const kDefaultTextFontSize = 100;
static NSUInteger const kMinimumTextFontSize = 50;
static NSUInteger const kMaximumTextFontSize = 200;

@implementation BrowserPreferencesStore

+ (NSString *)desktopUserAgent {
    return @"Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15";
}

+ (NSString *)mobileUserAgent {
    return @"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1";
}

// build-16: a third, generic compatibility identity. Some sites reject Safari/WebKit UAs while
// serving desktop Chrome normally. This does not defeat server-side login or app-only streams.
+ (NSString *)chromeUserAgent {
    return @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36";
}

+ (NSString *)userAgentForMode:(NSInteger)mode {
    if (mode == 1) {
        return BrowserPreferencesStore.mobileUserAgent;
    }
    if (mode == 2) {
        return BrowserPreferencesStore.chromeUserAgent;
    }
    return BrowserPreferencesStore.desktopUserAgent;
}

- (NSUserDefaults *)defaults {
    return [NSUserDefaults standardUserDefaults];
}

- (void)ensureUserAgentConsistency {
    if (self.userAgent.length > 0) {
        return;
    }
    self.userAgent = [BrowserPreferencesStore userAgentForMode:self.userAgentMode];
}

// build-16: keep the stored UA, MobileMode flag and the three-state mode in sync. AppDelegate
// calls this on every launch so a Chrome-mode selection survives a restart instead of being
// overwritten with the desktop Safari string.
- (void)applyUserAgentForCurrentMode {
    NSInteger mode = self.userAgentMode;
    [[self defaults] setObject:[BrowserPreferencesStore userAgentForMode:mode] forKey:kUserAgentDefaultsKey];
    [[self defaults] setBool:(mode == 1) forKey:kMobileModeDefaultsKey];
    [[self defaults] synchronize];
}

- (NSInteger)userAgentMode {
    NSNumber *stored = [[self defaults] objectForKey:kUserAgentModeDefaultsKey];
    if (stored != nil) {
        NSInteger mode = stored.integerValue;
        return (mode >= 0 && mode <= 2) ? mode : 0;
    }
    // Migration: builds before build-16 only stored the MobileMode flag.
    return [[self defaults] boolForKey:kMobileModeDefaultsKey] ? 1 : 0;
}

- (void)setUserAgentMode:(NSInteger)userAgentMode {
    NSInteger mode = (userAgentMode >= 0 && userAgentMode <= 2) ? userAgentMode : 0;
    [[self defaults] setInteger:mode forKey:kUserAgentModeDefaultsKey];
    [self applyUserAgentForCurrentMode];
}

- (NSString *)userAgent {
    NSString *userAgent = [[self defaults] stringForKey:kUserAgentDefaultsKey];
    if (userAgent.length > 0) {
        return userAgent;
    }
    return [BrowserPreferencesStore userAgentForMode:self.userAgentMode];
}

- (void)setUserAgent:(NSString *)userAgent {
    [[self defaults] setObject:userAgent ?: @"" forKey:kUserAgentDefaultsKey];
    [[self defaults] synchronize];
}

- (BOOL)mobileModeEnabled {
    return [[self defaults] boolForKey:kMobileModeDefaultsKey];
}

- (void)setMobileModeEnabled:(BOOL)mobileModeEnabled {
    [[self defaults] setBool:mobileModeEnabled forKey:kMobileModeDefaultsKey];
    [[self defaults] synchronize];
}

- (BOOL)topNavigationBarVisible {
    NSNumber *showTopNavBar = [[self defaults] objectForKey:kShowTopNavigationBarDefaultsKey];
    return showTopNavBar ? showTopNavBar.boolValue : YES;
}

- (void)setTopNavigationBarVisible:(BOOL)topNavigationBarVisible {
    [[self defaults] setObject:@(topNavigationBarVisible) forKey:kShowTopNavigationBarDefaultsKey];
    [[self defaults] synchronize];
}

- (NSUInteger)textFontSize {
    NSNumber *textFontSizeValue = [[self defaults] objectForKey:kTextFontSizeDefaultsKey];
    if (textFontSizeValue == nil) {
        return kDefaultTextFontSize;
    }
    NSUInteger textFontSize = textFontSizeValue.unsignedIntegerValue;
    return MIN(kMaximumTextFontSize, MAX(kMinimumTextFontSize, textFontSize));
}

- (void)setTextFontSize:(NSUInteger)textFontSize {
    textFontSize = MIN(kMaximumTextFontSize, MAX(kMinimumTextFontSize, textFontSize));
    [[self defaults] setObject:@(textFontSize) forKey:kTextFontSizeDefaultsKey];
    [[self defaults] synchronize];
}

- (BOOL)fullscreenVideoPlaybackEnabled {
    return [[self defaults] boolForKey:kEnableFullscreenVideoPlaybackDefaultsKey];
}

- (void)setFullscreenVideoPlaybackEnabled:(BOOL)fullscreenVideoPlaybackEnabled {
    [[self defaults] setBool:fullscreenVideoPlaybackEnabled forKey:kEnableFullscreenVideoPlaybackDefaultsKey];
    [[self defaults] synchronize];
}

- (BOOL)scalePagesToFit {
    return [[self defaults] boolForKey:kScalePagesToFitDefaultsKey];
}

- (void)setScalePagesToFit:(BOOL)scalePagesToFit {
    [[self defaults] setBool:scalePagesToFit forKey:kScalePagesToFitDefaultsKey];
    [[self defaults] synchronize];
}

- (BOOL)dontShowHintsOnLaunch {
    return [[self defaults] boolForKey:kDontShowHintsOnLaunchDefaultsKey];
}

- (void)setDontShowHintsOnLaunch:(BOOL)dontShowHintsOnLaunch {
    [[self defaults] setBool:dontShowHintsOnLaunch forKey:kDontShowHintsOnLaunchDefaultsKey];
    [[self defaults] synchronize];
}

- (BOOL)dontShowFavoritesOnLaunch {
    return [[self defaults] boolForKey:kDontShowFavoritesOnLaunchDefaultsKey];
}

- (void)setDontShowFavoritesOnLaunch:(BOOL)dontShowFavoritesOnLaunch {
    [[self defaults] setBool:dontShowFavoritesOnLaunch forKey:kDontShowFavoritesOnLaunchDefaultsKey];
    [[self defaults] synchronize];
}

- (NSString *)homePageURLString {
    NSString *value = [[self defaults] stringForKey:kHomepageDefaultsKey];
    return value ?: @"";
}

- (void)setHomePageURLString:(NSString *)homePageURLString {
    [[self defaults] setObject:homePageURLString ?: @"" forKey:kHomepageDefaultsKey];
    [[self defaults] synchronize];
}

@end
