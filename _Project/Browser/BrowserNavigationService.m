#import "BrowserNavigationService.h"

#import "BrowserPreferencesStore.h"
#import "BrowserTabViewModel.h"

static NSString * const kHistoryDefaultsKey = @"HISTORY";
static NSUInteger const kMaximumHistoryCount = 100;

@interface BrowserNavigationService ()

@property (nonatomic) BrowserPreferencesStore *preferencesStore;

@end

@implementation BrowserNavigationService

- (instancetype)init {
    return [self initWithPreferencesStore:[BrowserPreferencesStore new]];
}

- (instancetype)initWithPreferencesStore:(BrowserPreferencesStore *)preferencesStore {
    self = [super init];
    if (self) {
        _preferencesStore = preferencesStore ?: [BrowserPreferencesStore new];
        [_preferencesStore ensureUserAgentConsistency];
    }
    return self;
}

- (NSURLRequest *)homePageRequest {
    NSString *homePageURLString = self.preferencesStore.homePageURLString;
    if (homePageURLString.length == 0) {
        homePageURLString = @"http://www.google.com";
    }
    return [self requestForURLString:homePageURLString];
}

- (NSURLRequest *)requestForEnteredAddressString:(NSString *)addressString {
    NSString *trimmedAddress = [self trimmedString:addressString];
    if (trimmedAddress.length == 0) {
        return nil;
    }
    
    if (![trimmedAddress hasPrefix:@"http://"] && ![trimmedAddress hasPrefix:@"https://"]) {
        trimmedAddress = [@"http://" stringByAppendingString:trimmedAddress];
    }
    return [self requestForURLString:trimmedAddress];
}

- (NSURLRequest *)googleSearchRequestForQuery:(NSString *)query {
    NSString *sanitizedQuery = [self sanitizedSearchQuery:query];
    if (sanitizedQuery.length == 0) {
        return nil;
    }
    
    // build-17: Baidu is the default search engine (Google is not reachable on most mainland
    // networks). The method names keep their historical "google" spelling so no call site or
    // selector has to change; only the destination differs.
    NSString *searchURLString = [NSString stringWithFormat:@"https://www.baidu.com/s?wd=%@", sanitizedQuery];
    return [self requestForURLString:searchURLString];
}

- (NSURLRequest *)googleSearchRequestForFailedRequestURLString:(NSString *)requestURLString {
    NSString *searchQuery = [self trimmedString:requestURLString];
    if (searchQuery.length == 0) {
        return nil;
    }
    
    if ([searchQuery hasSuffix:@"/"]) {
        searchQuery = [searchQuery substringToIndex:searchQuery.length - 1];
    }
    searchQuery = [searchQuery stringByReplacingOccurrencesOfString:@"http://" withString:@""];
    searchQuery = [searchQuery stringByReplacingOccurrencesOfString:@"https://" withString:@""];
    searchQuery = [searchQuery stringByReplacingOccurrencesOfString:@"www." withString:@""];
    
    return [self googleSearchRequestForQuery:searchQuery];
}

- (void)updateTab:(BrowserTabViewModel *)tab
    withPageTitle:(NSString *)pageTitle
  currentURLString:(NSString *)currentURLString {
    if (tab == nil) {
        return;
    }
    
    NSString *safeTitle = pageTitle ?: @"";
    NSString *safeURLString = currentURLString ?: @"";
    tab.title = safeTitle.length > 0 ? safeTitle : @"新建标签页";
    tab.URLString = safeURLString;
    
    [self persistHistoryItemWithURLString:safeURLString title:safeTitle];
}

- (BOOL)shouldIgnoreLoadError:(NSError *)error {
    NSInteger errorCode = error.code;
    return errorCode == 999 || errorCode == 204;
}

- (NSURLRequest *)requestForURLString:(NSString *)URLString {
    NSURL *URL = [NSURL URLWithString:URLString];
    if (URL == nil) {
        return nil;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL];
    NSString *userAgent = self.preferencesStore.userAgent;
    if (userAgent.length > 0) {
        [request setValue:userAgent forHTTPHeaderField:@"User-Agent"];
    }
    // build-17: Youku (and several other Chinese video sites) validate the top-level Referer and
    // treat a missing or foreign one as an unauthorised playback request, which the page then
    // reports as "log in to continue". A desktop browser always sends Referer for a navigation,
    // so a request that arrives without it is already the anomaly. Sending the site's own origin
    // makes the navigation look like the in-site click it actually is; nothing is forged about
    // the account, only the header a browser would have sent anyway.
    NSString *referer = [self refererForURL:URL];
    if (referer.length > 0) {
        [request setValue:referer forHTTPHeaderField:@"Referer"];
    }
    return request;
}

/// The origin to advertise as Referer for a navigation, or nil when the host is not one that
/// checks it. Only the scheme and host are used: no path, no account data.
- (NSString *)refererForURL:(NSURL *)URL {
    NSString *host = URL.host.lowercaseString;
    if (host.length == 0) {
        return nil;
    }
    static NSArray<NSString *> *refererCheckedSuffixes = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // youku.com / tudou.com are the same platform; iqiyi.com and bilibili.com apply the same
        // style of check, so they are covered here as well.
        refererCheckedSuffixes = @[@"youku.com",
                                   @"tudou.com",
                                   @"iqiyi.com",
                                   @"bilibili.com"];
    });
    for (NSString *suffix in refererCheckedSuffixes) {
        if ([host isEqualToString:suffix] ||
            ([host hasSuffix:[@"." stringByAppendingString:suffix]] && host.length > suffix.length + 1)) {
            NSString *scheme = URL.scheme.length > 0 ? URL.scheme : @"https";
            return [NSString stringWithFormat:@"%@://%@/", scheme, host];
        }
    }
    return nil;
}

- (NSString *)trimmedString:(NSString *)string {
    if (string == nil) {
        return @"";
    }
    return [string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

- (NSString *)sanitizedSearchQuery:(NSString *)query {
    NSString *trimmedQuery = [self trimmedString:query];
    if (trimmedQuery.length == 0) {
        return @"";
    }
    
    NSString *searchQuery = [trimmedQuery stringByReplacingOccurrencesOfString:@" " withString:@"+"];
    searchQuery = [searchQuery stringByReplacingOccurrencesOfString:@"." withString:@"+"];
    while ([searchQuery containsString:@"++"]) {
        searchQuery = [searchQuery stringByReplacingOccurrencesOfString:@"++" withString:@"+"];
    }
    
    return [searchQuery stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
}

- (void)persistHistoryItemWithURLString:(NSString *)URLString title:(NSString *)title {
    if (URLString.length == 0) {
        return;
    }
    
    NSArray *historyItem = @[URLString, title ?: @""];
    NSMutableArray *historyItems = [NSMutableArray arrayWithObject:historyItem];
    NSArray *storedHistory = [[NSUserDefaults standardUserDefaults] arrayForKey:kHistoryDefaultsKey];
    if (storedHistory.count > 0) {
        NSArray *latestItem = storedHistory.firstObject;
        if ([latestItem isKindOfClass:[NSArray class]] && latestItem.count > 0 && [latestItem[0] isEqualToString:URLString]) {
            [historyItems removeObjectAtIndex:0];
        }
        [historyItems addObjectsFromArray:storedHistory];
    }
    
    while (historyItems.count > kMaximumHistoryCount) {
        [historyItems removeLastObject];
    }
    
    [[NSUserDefaults standardUserDefaults] setObject:historyItems forKey:kHistoryDefaultsKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

@end
