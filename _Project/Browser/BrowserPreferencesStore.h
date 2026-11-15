#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface BrowserPreferencesStore : NSObject

+ (NSString *)desktopUserAgent;
+ (NSString *)mobileUserAgent;
+ (NSString *)chromeUserAgent;
+ (NSString *)userAgentForMode:(NSInteger)mode;

@property (nonatomic, copy) NSString *userAgent;
// 0 = desktop Safari, 1 = mobile Safari, 2 = desktop Chrome (build-16).
@property (nonatomic) NSInteger userAgentMode;
@property (nonatomic) BOOL mobileModeEnabled;
@property (nonatomic) BOOL topNavigationBarVisible;
@property (nonatomic) NSUInteger textFontSize;
@property (nonatomic) BOOL fullscreenVideoPlaybackEnabled;
@property (nonatomic) BOOL scalePagesToFit;
@property (nonatomic) BOOL dontShowHintsOnLaunch;
@property (nonatomic) BOOL dontShowFavoritesOnLaunch;
@property (nonatomic, copy) NSString *homePageURLString;

- (void)ensureUserAgentConsistency;
- (void)applyUserAgentForCurrentMode;

@end

NS_ASSUME_NONNULL_END
