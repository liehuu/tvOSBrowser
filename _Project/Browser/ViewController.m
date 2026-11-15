//
//  ViewController.m
//  Browser
//
//  Created by Steven Troughton-Smith on 20/09/2015.
//  Improved by Jip van Akker on 14/10/2015 through 10/01/2019
//

#import "BrowserMenuCoordinator.h"
#import "BrowserDOMInteractionService.h"
#import "BrowserNavigationService.h"
#import "BrowserPageActionCoordinator.h"
#import "BrowserPreferencesStore.h"
#import "BrowserRemoteInputController.h"
#import "BrowserSessionStore.h"
#import "BrowserTabViewModel.h"
#import "BrowserTabCoordinator.h"
#import "BrowserTabOverviewController.h"
#import "BrowserVideoPlaybackCoordinator.h"
#import "BrowserViewModel.h"
#import "ViewController.h"

static NSString * const kBrowserGlobalSelectPressEndedNotification = @"BrowserGlobalSelectPressEndedNotification";
static NSString * const kBrowserGlobalArrowPressNotification = @"BrowserGlobalArrowPressNotification";
static NSString * const kBrowserGlobalArrowPressTypeKey = @"type";
static NSString * const kBrowserGlobalArrowPressBeganKey = @"began";
static NSString * const kBrowserGlobalLongPressNotification = @"BrowserGlobalLongPressNotification";
static NSString * const kBrowserGlobalLongPressTypeKey = @"type";
static NSString * const kBrowserGlobalLongPressSourceKey = @"source";
static NSString * const kBrowserGlobalLongPressSourceAuxKey = @"aux";

static UIColor *kTextColor(void) {
    if (@available(tvOS 13, *)) {
        return UIColor.labelColor;
    } else {
        return UIColor.blackColor;
    }
}

@interface ViewController () <BrowserMenuCoordinatorHost, BrowserPageActionCoordinatorHost, BrowserRemoteInputControllerHost, BrowserTabCoordinatorHost, BrowserTabOverviewControllerHost, BrowserTopBarViewDelegate, BrowserVideoPlaybackCoordinatorHost>

@property (nonatomic) BrowserDOMInteractionService *domInteractionService;
@property (nonatomic) BrowserMenuCoordinator *menuCoordinator;
@property (nonatomic) BrowserNavigationService *navigationService;
@property (nonatomic) BrowserPageActionCoordinator *pageActionCoordinator;
@property (nonatomic) BrowserPreferencesStore *preferencesStore;
@property (nonatomic) BrowserRemoteInputController *remoteInputController;
@property (nonatomic) BrowserSessionStore *sessionStore;
@property (nonatomic) BrowserTabCoordinator *tabCoordinator;
@property (nonatomic) BrowserTabOverviewController *tabOverviewController;
@property (nonatomic) BrowserVideoPlaybackCoordinator *videoPlaybackCoordinator;
@property (nonatomic) BrowserViewModel *viewModel;
@property (nonatomic) BOOL displayedHintsOnLaunch;
@property (nonatomic) BOOL scrollViewAllowBounces;
@property (nonatomic, getter=isTopBarFocusActive) BOOL topBarFocusActive;
@property (nonatomic) BOOL pseudoFullscreenActive;
@property (nonatomic) BOOL pseudoFullscreenCursorModeWasEnabled;
@property (nonatomic) BOOL pseudoFullscreenTopBarWasVisible;
@property (nonatomic, copy) NSString *pseudoFullscreenURLString;
@property (nonatomic) UIView *playbackHUDContainer;
@property (nonatomic) UILabel *playbackTimeLabel;
@property (nonatomic) UILabel *playbackActionLabel;
@property (nonatomic) UIView *playbackProgressTrack;
@property (nonatomic) UIView *playbackProgressFill;
@property (nonatomic) NSTimer *playbackHUDTimer;
@property (nonatomic) CGFloat playbackProgressRatio;
@property (nonatomic) NSTimer *playbackSeekRepeatTimer;
@property (nonatomic) CGFloat playbackSeekRepeatDelta;
@property (nonatomic) NSLayoutConstraint *playbackProgressWidthConstraint;

@end

@implementation ViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.definesPresentationContext = YES;
    self.scrollViewAllowBounces = YES;

    self.preferencesStore = [BrowserPreferencesStore new];
    [self.preferencesStore ensureUserAgentConsistency];

    self.viewModel = [BrowserViewModel new];
    self.viewModel.topNavigationBarVisible = self.preferencesStore.topNavigationBarVisible;
    self.viewModel.textFontSize = self.preferencesStore.textFontSize;
    self.viewModel.fullscreenVideoPlaybackEnabled = self.preferencesStore.fullscreenVideoPlaybackEnabled;

    self.domInteractionService = [BrowserDOMInteractionService new];
    self.navigationService = [[BrowserNavigationService alloc] initWithPreferencesStore:self.preferencesStore];
    self.sessionStore = [BrowserSessionStore new];
    self.menuCoordinator = [[BrowserMenuCoordinator alloc] initWithHost:self preferencesStore:self.preferencesStore];
    self.remoteInputController = [[BrowserRemoteInputController alloc] initWithHost:self rootView:self.view];
    [self.view addSubview:self.remoteInputController.cursorView];
    self.videoPlaybackCoordinator = [[BrowserVideoPlaybackCoordinator alloc] initWithHost:self
                                                                      domInteractionService:self.domInteractionService];
    self.tabCoordinator = [[BrowserTabCoordinator alloc] initWithHost:self
                                                             viewModel:self.viewModel
                                                      preferencesStore:self.preferencesStore
                                                     navigationService:self.navigationService
                                                          sessionStore:self.sessionStore
                                                    browserContainerView:self.browserContainerView
                                                              rootView:self.view
                                                            topMenuView:self.topMenuView
                                                            cursorView:self.remoteInputController.cursorView
                                               manualScrollPanRecognizer:self.remoteInputController.manualScrollPanRecognizer
                                                           webViewDelegate:self
                                                       scrollViewAllowBounces:self.scrollViewAllowBounces];
    self.tabOverviewController = [[BrowserTabOverviewController alloc] initWithHost:self
                                                                            viewModel:self.viewModel
                                                                             rootView:self.view
                                                                           topMenuView:self.topMenuView
                                                                           cursorView:self.remoteInputController.cursorView];
    self.pageActionCoordinator = [[BrowserPageActionCoordinator alloc] initWithHost:self
                                                               domInteractionService:self.domInteractionService
                                                                   navigationService:self.navigationService
                                                            videoPlaybackCoordinator:self.videoPlaybackCoordinator];

    self.topMenuView.delegate = self;
    self.topMenuView.loadingSpinner.hidesWhenStopped = YES;
    self.remoteInputController.cursorView.hidden = NO;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleApplicationWillResignActive:)
                                                 name:UIApplicationWillResignActiveNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleApplicationDidEnterBackground:)
                                                 name:UIApplicationDidEnterBackgroundNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleApplicationWillTerminate:)
                                                 name:UIApplicationWillTerminateNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleGlobalSelectPressEndedNotification:)
                                                 name:kBrowserGlobalSelectPressEndedNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handlePseudoFullscreenRequestNotification:)
                                                 name:BrowserPseudoFullscreenRequestNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleGlobalArrowPressNotification:)
                                                 name:kBrowserGlobalArrowPressNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleGlobalLongPressNotification:)
                                                 name:kBrowserGlobalLongPressNotification
                                               object:nil];

    [self.tabCoordinator restoreInitialStateOrCreateFirstTab];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self.tabCoordinator webViewDidAppear];
    if (!self.preferencesStore.dontShowHintsOnLaunch && !self.displayedHintsOnLaunch) {
        [self showHintsAlert];
    }
    self.displayedHintsOnLaunch = YES;
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Notifications

- (void)handleApplicationWillResignActive:(NSNotification *)notification {
    (void)notification;
    [self.tabCoordinator persistSession];
}

- (void)handleApplicationDidEnterBackground:(NSNotification *)notification {
    (void)notification;
    [self.tabCoordinator persistSession];
}

- (void)handleApplicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [self.tabCoordinator persistSession];
}

- (void)handleGlobalSelectPressEndedNotification:(NSNotification *)notification {
    (void)notification;
    [self.remoteInputController handleGlobalSelectPressEndedNotification];
}

- (void)handleGlobalArrowPressNotification:(NSNotification *)notification {
    id typeValue = notification.userInfo[kBrowserGlobalArrowPressTypeKey];
    id beganValue = notification.userInfo[kBrowserGlobalArrowPressBeganKey];
    if (![typeValue isKindOfClass:[NSNumber class]]) {
        return;
    }
    UIPressType type = (UIPressType)[typeValue integerValue];
    BOOL began = [beganValue isKindOfClass:[NSNumber class]] ? [beganValue boolValue] : NO;
    [self.remoteInputController handleGlobalArrowPressType:type began:began];
}

// Long press arrives from the UIApplication sendEvent: bridge, which is the only channel that
// actually sees Menu/PlayPause under GCEventViewController.
- (void)handleGlobalLongPressNotification:(NSNotification *)notification {
    id typeValue = notification.userInfo[kBrowserGlobalLongPressTypeKey];
    if (![typeValue isKindOfClass:[NSNumber class]]) {
        return;
    }
    UIPressType type = (UIPressType)[typeValue integerValue];
    id sourceValue = notification.userInfo[kBrowserGlobalLongPressSourceKey];
    BOOL isAuxKey = [sourceValue isKindOfClass:[NSString class]] &&
                    [sourceValue isEqualToString:kBrowserGlobalLongPressSourceAuxKey];

    if (self.tabOverviewController.visible || self.topBarFocusActive) {
        NSLog(@"[LongPress] ignored type=%ld (overlay active)", (long)type);
        return;
    }

    UIViewController *presented = self.presentedViewController;
    if (presented != nil) {
        NSLog(@"[LongPress] ignored type=%ld (presented=%@)", (long)type, NSStringFromClass([presented class]));
        return;
    }

    if (type == UIPressTypePlayPause && !isAuxKey) {
        NSLog(@"[LongPress] PlayPause -> toggle pseudo fullscreen");
        [self.remoteInputController handleGlobalLongPressType:type];
        return;
    }

    if (type == UIPressTypeMenu && isAuxKey) {
        // An aux key must not arm the Menu suppression flag, so call the host directly.
        NSLog(@"[LongPress] aux key -> favorites");
        [self.menuCoordinator showFavoritesMenu];
        return;
    }

    if (type == UIPressTypeMenu) {
        NSLog(@"[LongPress] Menu -> favorites");
        [self.remoteInputController handleGlobalLongPressType:type];
    }
}

#pragma mark - Helpers

- (BrowserWebView *)webview {
    return self.tabCoordinator.activeWebView;
}

- (CGPoint)browserDOMPointForCursor {
    return [self.domInteractionService DOMPointForCursorOrigin:self.remoteInputController.cursorView.frame.origin
                                                        inView:self.view
                                                       webView:self.webview];
}

- (void)loadHomePage {
    [self.tabCoordinator loadHomePage];
}

- (void)showAdvancedMenu {
    [self deactivateTopBarFocusMode];
    [self.menuCoordinator showAdvancedMenu];
}

- (BOOL)canActivateTopBarFocusMode {
    return self.presentedViewController == nil &&
        !self.tabOverviewController.visible &&
        self.viewModel.topNavigationBarVisible &&
        !self.topMenuView.hidden;
}

- (void)activateTopBarFocusMode {
    if (![self canActivateTopBarFocusMode]) {
        return;
    }
    if (self.topBarFocusActive) {
        return;
    }

    self.topBarFocusActive = YES;
    [self.topMenuView setFocusModeActive:YES];
    [self.remoteInputController refreshInteractionState];
    [self setNeedsFocusUpdate];
    [self updateFocusIfNeeded];
}

- (void)deactivateTopBarFocusMode {
    if (!self.topBarFocusActive) {
        return;
    }

    self.topBarFocusActive = NO;
    [self.topMenuView setFocusModeActive:NO];
    [self.remoteInputController refreshInteractionState];
    [self setNeedsFocusUpdate];
    [self updateFocusIfNeeded];
}

- (void)performTopBarAction:(BrowserTopBarAction)action {
    [self deactivateTopBarFocusMode];

    switch (action) {
        case BrowserTopBarActionBack:
            if (self.webview.canGoBack) {
                [self.webview goBack];
            }
            break;
        case BrowserTopBarActionRefresh:
            [self.webview reload];
            break;
        case BrowserTopBarActionForward:
            if (self.webview.canGoForward) {
                [self.webview goForward];
            }
            break;
        case BrowserTopBarActionHome:
            [self loadHomePage];
            break;
        case BrowserTopBarActionTabs:
            [self browserShowTabOverview];
            break;
        case BrowserTopBarActionURL:
            [self showInputURLorSearchGoogle];
            break;
        case BrowserTopBarActionFullscreen:
            if (self.viewModel.topNavigationBarVisible) {
                UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Hide Top Navigation bar?"
                                                                                         message:@"You can still open the side menu by double-tapping the Play/Pause button."
                                                                                  preferredStyle:UIAlertControllerStyleAlert];
                [alertController addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
                [alertController addAction:[UIAlertAction actionWithTitle:@"Hide Bar"
                                                                    style:UIAlertActionStyleDestructive
                                                                  handler:^(__unused UIAlertAction *action) {
                    [self browserHideTopNav];
                }]];
                [self browserPresentViewController:alertController];
            } else {
                [self browserShowTopNav];
            }
            break;
        case BrowserTopBarActionMenu:
            [self showAdvancedMenu];
            break;
    }
}

- (void)updateTextFontSize {
    if (self.webview == nil) {
        return;
    }

    NSString *jsString = [[NSString alloc] initWithFormat:
                          @"(function(){"
                           "var value='%lu%%';"
                           "var multiplier=%lu/100;"
                           "if (document.documentElement && document.documentElement.style) {"
                               "document.documentElement.style.setProperty('-webkit-text-size-adjust', value, 'important');"
                               "document.documentElement.style.setProperty('text-size-adjust', value, 'important');"
                           "}"
                           "if (document.body && document.body.style) {"
                               "document.body.style.setProperty('-webkit-text-size-adjust', value, 'important');"
                               "document.body.style.setProperty('text-size-adjust', value, 'important');"
                           "}"
                           "if (!document.body || !window.getComputedStyle) { return value; }"
                           "var elements = document.querySelectorAll('body, body *');"
                           "for (var i = 0; i < elements.length; i++) {"
                               "var element = elements[i];"
                               "if (!element || !element.tagName) { continue; }"
                               "var tagName = element.tagName.toLowerCase();"
                               "if (tagName === 'script' || tagName === 'style' || tagName === 'noscript') { continue; }"
                               "var originalSize = element.getAttribute('data-browser-original-font-size');"
                               "if (!originalSize) {"
                                   "var computedSize = window.getComputedStyle(element).fontSize || '';"
                                   "if (computedSize.indexOf('px') == -1) { continue; }"
                                   "var parsedSize = parseFloat(computedSize);"
                                   "if (!isFinite(parsedSize) || parsedSize <= 0) { continue; }"
                                   "originalSize = String(parsedSize);"
                                   "element.setAttribute('data-browser-original-font-size', originalSize);"
                               "}"
                               "var baseSize = parseFloat(originalSize);"
                               "if (!isFinite(baseSize) || baseSize <= 0) { continue; }"
                               "element.style.setProperty('font-size', (baseSize * multiplier) + 'px', 'important');"
                           "}"
                           "return value;"
                          "})()",
                          (unsigned long)self.viewModel.textFontSize,
                          (unsigned long)self.viewModel.textFontSize];
    [self.webview stringByEvaluatingJavaScriptFromString:jsString];
}

- (void)showInputURLorSearchGoogle {
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Enter URL or Search Terms"
                                                                             message:@""
                                                                      preferredStyle:UIAlertControllerStyleAlert];

    [alertController addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.keyboardType = UIKeyboardTypeURL;
        textField.placeholder = @"Enter URL or Search Terms";
        textField.textColor = kTextColor();
        [textField setReturnKeyType:UIReturnKeyDone];
    }];

    __weak typeof(self) weakSelf = self;
    [alertController addAction:[UIAlertAction actionWithTitle:@"Search Google"
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(__unused UIAlertAction *action) {
        UITextField *textField = alertController.textFields.firstObject;
        NSURLRequest *searchRequest = [weakSelf.navigationService googleSearchRequestForQuery:textField.text];
        if (searchRequest != nil) {
            [weakSelf.webview loadRequest:searchRequest];
        } else {
            [weakSelf requestURLorSearchInput];
        }
    }]];
    [alertController addAction:[UIAlertAction actionWithTitle:@"Go To Website"
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(__unused UIAlertAction *action) {
        UITextField *textField = alertController.textFields.firstObject;
        if (textField.text.length == 0) {
            [weakSelf requestURLorSearchInput];
            return;
        }
        NSURLRequest *navigationRequest = [weakSelf.navigationService requestForEnteredAddressString:textField.text];
        if (navigationRequest != nil) {
            [weakSelf.webview loadRequest:navigationRequest];
        } else {
            [weakSelf requestURLorSearchInput];
        }
    }]];
    [alertController addAction:[UIAlertAction actionWithTitle:nil style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alertController animated:YES completion:nil];

    UITextField *textField = alertController.textFields.firstObject;
    if (self.webview.request == nil || self.webview.request.URL.absoluteString.length > 0) {
        [textField becomeFirstResponder];
    }
}

- (void)requestURLorSearchInput {
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Quick Menu"
                                                                             message:@""
                                                                      preferredStyle:UIAlertControllerStyleAlert];

    if (self.webview.canGoForward) {
        [alertController addAction:[UIAlertAction actionWithTitle:@"Go Forward"
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(__unused UIAlertAction *action) {
            [self.webview goForward];
        }]];
    }

    [alertController addAction:[UIAlertAction actionWithTitle:@"Input URL or Search with Google"
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(__unused UIAlertAction *action) {
        [self showInputURLorSearchGoogle];
    }]];

    if (self.webview.request != nil && self.webview.request.URL.absoluteString.length > 0) {
        [alertController addAction:[UIAlertAction actionWithTitle:@"Reload Page"
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(__unused UIAlertAction *action) {
            self.tabCoordinator.previousURL = @"";
            [self.webview reload];
        }]];
    }

    [alertController addAction:[UIAlertAction actionWithTitle:nil style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alertController animated:YES completion:nil];
}

- (void)showHintsAlert {
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Usage Guide"
                                                                             message:@"Double press the touch area to switch between cursor & scroll mode.\nPress the touch area while in cursor mode to click.\nUse the Up/Down/Left/Right arrows to move the cursor step by step (hold to keep moving).\nSingle tap the Menu button to Go Back, or Exit on root page.\nLong press the Menu button to open Favorites (bookmarks). A remote's Stop button also opens it.\nSingle tap the Play/Pause button to: Go Forward, Enter URL or Reload Page.\nDouble tap the Play/Pause to show the Advanced Menu with more options.\nLong press the Play/Pause button to toggle fullscreen for the playing video.\nThe website's own fullscreen button is also redirected to this fullscreen.\nIn fullscreen: Left/Right seek back/forward 10s (hold to keep seeking), Up or Down shows/hides the timecode bar, Play/Pause plays or pauses, Select shows the timecode bar, Menu leaves fullscreen.\nUse the tabs icon in the top bar to open the tab overview."
                                                                      preferredStyle:UIAlertControllerStyleAlert];

    __weak typeof(self) weakSelf = self;
    if (self.preferencesStore.dontShowHintsOnLaunch) {
        [alertController addAction:[UIAlertAction actionWithTitle:@"Always Show On Launch"
                                                            style:UIAlertActionStyleDestructive
                                                          handler:^(__unused UIAlertAction *action) {
            weakSelf.preferencesStore.dontShowHintsOnLaunch = NO;
        }]];
    } else {
        [alertController addAction:[UIAlertAction actionWithTitle:@"Don't Show This Again"
                                                            style:UIAlertActionStyleDestructive
                                                          handler:^(__unused UIAlertAction *action) {
            weakSelf.preferencesStore.dontShowHintsOnLaunch = YES;
        }]];
    }
    [alertController addAction:[UIAlertAction actionWithTitle:@"Dismiss"
                                                        style:UIAlertActionStyleCancel
                                                      handler:nil]];
    [self presentViewController:alertController animated:YES completion:nil];
}

- (void)browserHandlePrimaryAction {
    if (!self.remoteInputController.cursorModeEnabled || self.webview == nil) {
        return;
    }

    CGPoint point = [self.view convertPoint:self.remoteInputController.cursorView.frame.origin toView:self.webview];
    if (point.y < 0) {
        [self activateTopBarFocusMode];
        return;
    }

    CGPoint domPoint = [self browserDOMPointForCursor];
    [self.pageActionCoordinator handlePageSelectionAtDOMPoint:domPoint webView:self.webview];
}

- (NSArray<id<UIFocusEnvironment>> *)preferredFocusEnvironments {
    if (self.topBarFocusActive) {
        UIView *preferredFocusItem = [self.topMenuView preferredFocusItem];
        if (preferredFocusItem != nil) {
            return @[preferredFocusItem];
        }
    }
    return [super preferredFocusEnvironments];
}

#pragma mark - BrowserTopBarViewDelegate

- (void)browserTopBarView:(__unused BrowserTopBarView *)topBarView didTriggerAction:(BrowserTopBarAction)action {
    [self performTopBarAction:action];
}

#pragma mark - BrowserMenuCoordinatorHost

- (BrowserWebView *)browserWebView {
    return self.webview;
}

- (NSString *)browserPreviousURL {
    return self.tabCoordinator.previousURL;
}

- (void)setBrowserPreviousURL:(NSString *)browserPreviousURL {
    self.tabCoordinator.previousURL = browserPreviousURL ?: @"";
}

- (NSUInteger)browserTextFontSize {
    return self.viewModel.textFontSize;
}

- (void)setBrowserTextFontSize:(NSUInteger)browserTextFontSize {
    self.viewModel.textFontSize = browserTextFontSize;
    self.preferencesStore.textFontSize = self.viewModel.textFontSize;
}

- (BOOL)browserTopMenuShowing {
    return self.viewModel.topNavigationBarVisible;
}

- (BOOL)browserFullscreenVideoPlaybackEnabled {
    return self.viewModel.fullscreenVideoPlaybackEnabled;
}

- (void)setBrowserFullscreenVideoPlaybackEnabled:(BOOL)browserFullscreenVideoPlaybackEnabled {
    self.viewModel.fullscreenVideoPlaybackEnabled = browserFullscreenVideoPlaybackEnabled;
    self.preferencesStore.fullscreenVideoPlaybackEnabled = browserFullscreenVideoPlaybackEnabled;
}

- (void)browserPresentViewController:(UIViewController *)viewController {
    [self deactivateTopBarFocusMode];
    [self presentViewController:viewController animated:YES completion:nil];
}

- (void)browserLoadHomePage {
    [self loadHomePage];
}

- (void)browserShowHints {
    [self showHintsAlert];
}

- (void)browserShowTabOverview {
    [self deactivateTopBarFocusMode];
    [self.tabCoordinator prepareTabOverviewThumbnails];
    [self.tabOverviewController show];
}

- (void)browserCreateNewTabLoadingHomePage:(BOOL)loadHomePage {
    [self.tabCoordinator createNewTabLoadingHomePage:loadHomePage];
}

- (void)browserHideTopNav {
    [self deactivateTopBarFocusMode];
    self.viewModel.topNavigationBarVisible = NO;
    self.preferencesStore.topNavigationBarVisible = NO;
    [self.tabCoordinator setTopNavigationVisible:NO];
}

- (void)browserShowTopNav {
    self.viewModel.topNavigationBarVisible = YES;
    self.preferencesStore.topNavigationBarVisible = YES;
    [self.tabCoordinator setTopNavigationVisible:YES];
}

- (void)browserUpdateTextFontSize {
    [self updateTextFontSize];
}

- (void)browserCaptureSnapshotForCurrentTab {
    [self.tabCoordinator captureSnapshotForCurrentTab];
}

- (void)browserRecreateActiveWebViewPreservingCurrentURL {
    [self.tabCoordinator recreateActiveWebViewPreservingCurrentURL];
}

- (void)browserBringCursorToFront {
    [self.view bringSubviewToFront:self.remoteInputController.cursorView];
}

- (void)browserPlayVideoUnderCursorIfAvailable {
    [self.videoPlaybackCoordinator playVideoUnderCursorIfAvailable];
}

#pragma mark - BrowserVideoPlaybackCoordinatorHost

- (BOOL)browserIsCursorModeEnabled {
    return self.remoteInputController.cursorModeEnabled;
}

- (CGPoint)browserDOMCursorPoint {
    return [self browserDOMPointForCursor];
}

- (UIViewController *)browserPresentedViewController {
    return self.presentedViewController;
}

- (NSString *)browserCurrentPageTitle {
    return self.webview.title;
}

#pragma mark - BrowserTabCoordinatorHost

- (void)browserTabCoordinatorPresentViewController:(UIViewController *)viewController {
    [self browserPresentViewController:viewController];
}

- (void)browserTabCoordinatorUpdateTextFontSize {
    [self updateTextFontSize];
}

- (BOOL)browserTabCoordinatorIsCursorModeEnabled {
    return self.remoteInputController.cursorModeEnabled;
}

- (BOOL)browserTabCoordinatorIsTabOverviewVisible {
    return self.tabOverviewController.visible;
}

#pragma mark - BrowserTabOverviewControllerHost

- (BOOL)browserTabOverviewControllerCursorModeEnabled {
    return self.remoteInputController.cursorModeEnabled;
}

- (void)browserTabOverviewControllerSetCursorModeEnabled:(BOOL)enabled {
    [self.remoteInputController setCursorModeEnabled:enabled];
}

- (void)browserTabOverviewControllerPresentViewController:(UIViewController *)viewController {
    [self presentViewController:viewController animated:YES completion:nil];
}

- (void)browserTabOverviewControllerCreateNewTabLoadingHomePage:(BOOL)loadHomePage {
    [self.tabCoordinator createNewTabLoadingHomePage:loadHomePage];
}

- (void)browserTabOverviewControllerSwitchToTabAtIndex:(NSInteger)tabIndex {
    [self.tabCoordinator switchToTabAtIndex:tabIndex];
}

- (void)browserTabOverviewControllerCloseTabAtIndex:(NSInteger)tabIndex {
    [self.tabCoordinator closeTabAtIndex:tabIndex];
}

#pragma mark - BrowserPageActionCoordinatorHost

- (void)browserPageActionCoordinatorPresentViewController:(UIViewController *)viewController {
    [self browserPresentViewController:viewController];
}

- (BOOL)browserPageActionCoordinatorCreateNewTabWithRequest:(NSURLRequest *)request {
    return [self.tabCoordinator createNewTabWithRequest:request];
}

#pragma mark - BrowserRemoteInputControllerHost

- (UIScrollView *)browserRemoteInputControllerActiveScrollView {
    return self.webview.scrollView;
}

- (UIViewController *)browserRemoteInputControllerPresentedViewController {
    return self.presentedViewController;
}

- (BOOL)browserRemoteInputControllerTopBarFocusActive {
    return self.topBarFocusActive;
}

- (BOOL)browserRemoteInputControllerCanActivateTopBarFocus {
    return [self canActivateTopBarFocusMode];
}

- (void)browserRemoteInputControllerActivateTopBarFocus {
    [self activateTopBarFocusMode];
}

- (void)browserRemoteInputControllerDeactivateTopBarFocus {
    [self deactivateTopBarFocusMode];
}

- (BOOL)browserRemoteInputControllerTabOverviewVisible {
    return self.tabOverviewController.visible;
}

- (BOOL)browserRemoteInputControllerTabOverviewContainsPoint:(CGPoint)point {
    return [self.tabOverviewController containsPoint:point];
}

- (BOOL)browserRemoteInputControllerHandleTabOverviewSelectionAtPoint:(CGPoint)point {
    return [self.tabOverviewController handleSelectionAtPoint:point];
}

- (void)browserRemoteInputControllerDismissTabOverview {
    [self.tabOverviewController dismiss];
}

- (void)browserRemoteInputControllerHandleTabOverviewAlternateAction {
    [self.tabOverviewController handleAlternateAction];
}

- (void)browserRemoteInputControllerHandlePrimaryAction {
    [self browserHandlePrimaryAction];
}

- (void)browserRemoteInputControllerHandleMenuPress {
    // In pseudo fullscreen, a single Menu press leaves fullscreen first (like a video player).
    if (self.pseudoFullscreenActive) {
        [self exitPseudoFullscreen];
        return;
    }

    UIAlertController *alertController = (UIAlertController *)self.presentedViewController;
    if (alertController != nil) {
        [self.presentedViewController dismissViewControllerAnimated:YES completion:nil];
    } else if (self.webview.canGoBack) {
        [self.webview goBack];
    } else {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Exit App?"
                                                                       message:nil
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Exit"
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(__unused UIAlertAction *action) {
            exit(EXIT_SUCCESS);
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Dismiss" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

- (void)browserRemoteInputControllerHandlePlayPausePress {
    UIAlertController *alertController = (UIAlertController *)self.presentedViewController;
    if (alertController != nil) {
        [self.presentedViewController dismissViewControllerAnimated:YES completion:nil];
    } else {
        [self requestURLorSearchInput];
    }
}

- (void)browserRemoteInputControllerHandleAdvancedMenuPress {
    [self showAdvancedMenu];
}

- (void)browserRemoteInputControllerHandleFavoritesPress {
    [self.menuCoordinator showFavoritesMenu];
}

- (BOOL)browserRemoteInputControllerPseudoFullscreenActive {
    return self.pseudoFullscreenActive;
}

// Fullscreen only: Left/Right seek instead of moving the cursor, and the HUD reports the result.
- (void)browserRemoteInputControllerSeekBySeconds:(double)delta began:(BOOL)began {
    if (!self.pseudoFullscreenActive) {
        return;
    }
    if (began) {
        [self beginPlaybackSeekRepeatWithDelta:delta];
    } else {
        [self cancelPlaybackSeekRepeat];
    }
}

- (void)browserRemoteInputControllerTogglePlaybackHUD {
    [self togglePlaybackHUD];
}

- (void)browserRemoteInputControllerTogglePlaybackPlayState {
    [self togglePlaybackPlayState];
}

- (void)handlePseudoFullscreenRequestNotification:(NSNotification *)notification {
    BOOL enter = YES;
    id value = notification.userInfo[BrowserPseudoFullscreenRequestEnterKey];
    if ([value isKindOfClass:[NSNumber class]]) {
        enter = [value boolValue];
    }
    NSLog(@"[PseudoFullscreen] native request enter=%@ active=%@",
          enter ? @"YES" : @"NO",
          self.pseudoFullscreenActive ? @"YES" : @"NO");

    if (enter) {
        [self enterPseudoFullscreenFromPage];
    } else if (self.pseudoFullscreenActive) {
        [self exitPseudoFullscreen];
    }
}

#pragma mark - Pseudo fullscreen (long press Play/Pause)

// The frame-side engine is installed by the injected user script in every frame, so driving it
// from here also reaches videos inside cross-origin iframes, which contentDocument cannot.
- (NSString *)browserPseudoFullscreenEnterScript {
    return
    @"(function(){"
    "var applied=false;"
    "if(typeof window.__browserPfApply==='function'){"
        "try{window.__browserPfApply();applied=true;}catch(e){}"
    "}"
    "var fanned=false;"
    "if(typeof window.__browserPfFanOut==='function'){"
        "try{fanned=window.__browserPfFanOut('apply');}catch(e){}"
    "}"
    "if(!applied&&!fanned){return 'no-engine';}"
    "return applied?('ok'+(fanned?'+frames':'')):('frames-only');"
    "})()";
}

- (NSString *)browserPseudoFullscreenExitScript {
    return
    @"(function(){"
    "if(typeof window.__browserPfFanOut==='function'){"
        "try{window.__browserPfFanOut('clear');}catch(e){}"
    "}"
    "if(typeof window.__browserPfClear==='function'){"
        "try{window.__browserPfClear();return 'ok';}catch(e){}"
    "}"
    "return 'no-engine';"
    "})()";
}

- (void)browserRemoteInputControllerHandlePseudoFullscreenPress {
    if (self.pseudoFullscreenActive) {
        [self exitPseudoFullscreen];
    } else {
        [self enterPseudoFullscreenAndRememberChrome];
    }
}

#pragma mark - Pseudo fullscreen: apply the page-side styling only

// Returns the JS result string and does not touch the chrome. Retries once with a manually
// injected engine so a page that loaded before the user script was live still works.
- (NSString *)applyPseudoFullscreenStyling {
    BrowserWebView *webView = self.webview;
    if (webView == nil) {
        return @"no-webview";
    }

    NSString *result = [webView stringByEvaluatingJavaScriptFromString:[self browserPseudoFullscreenEnterScript]];
    if ([result isEqualToString:@"no-engine"] || result.length == 0) {
        NSLog(@"[PseudoFullscreen] engine missing, injecting on demand");
        [webView installPseudoFullscreenEngineFallback];
        result = [webView stringByEvaluatingJavaScriptFromString:[self browserPseudoFullscreenEnterScript]];
    }
    NSLog(@"[PseudoFullscreen] style result=%@", result ?: @"(nil)");
    return result ?: @"";
}

// Enter initiated by a remote-key shortcut: remember the previous chrome/cursor state so the
// same shortcut can restore it.
- (void)enterPseudoFullscreenAndRememberChrome {
    if (self.pseudoFullscreenActive) {
        return;
    }
    self.pseudoFullscreenTopBarWasVisible = self.viewModel.topNavigationBarVisible;
    self.pseudoFullscreenCursorModeWasEnabled = self.remoteInputController.cursorModeEnabled;
    self.pseudoFullscreenActive = YES;
    self.pseudoFullscreenURLString = [self.webview.request.URL absoluteString];

    [self applyPseudoFullscreenStyling];

    // Keep the self-drawn cursor above the web content so it stays visible and tracking.
    [self.view bringSubviewToFront:self.remoteInputController.cursorView];

    // Fullscreen playback needs a pointer: force cursor mode on while it lasts.
    if (!self.remoteInputController.cursorModeEnabled) {
        [self.remoteInputController setCursorModeEnabled:YES];
    }

    if (self.viewModel.topNavigationBarVisible) {
        [self browserHideTopNav];
    }

    // Reveal the timecode/progress HUD so the duration and position are visible right away.
    [self startPlaybackHUDSession];
}

// Enter requested by the page itself (its own fullscreen button). The page called
// requestFullscreen; we neutralised that and restyle here instead, so no native container is
// created and the app chrome can actually hide.
- (void)enterPseudoFullscreenFromPage {
    if (self.pseudoFullscreenActive) {
        [self applyPseudoFullscreenStyling];
        return;
    }
    [self enterPseudoFullscreenAndRememberChrome];
}

- (void)exitPseudoFullscreen {
    BrowserWebView *webView = self.webview;
    if (webView != nil) {
        NSString *result = [webView stringByEvaluatingJavaScriptFromString:[self browserPseudoFullscreenExitScript]];
        NSLog(@"[PseudoFullscreen] exit result=%@", result);
    }

    self.pseudoFullscreenActive = NO;
    [self stopPlaybackHUDSession];

    // Restore the cursor mode the user had before going fullscreen.
    if (!self.pseudoFullscreenCursorModeWasEnabled && self.remoteInputController.cursorModeEnabled) {
        [self.remoteInputController setCursorModeEnabled:NO];
    }
    self.pseudoFullscreenCursorModeWasEnabled = NO;

    if (self.pseudoFullscreenTopBarWasVisible && !self.viewModel.topNavigationBarVisible) {
        [self browserShowTopNav];
    }
    self.pseudoFullscreenTopBarWasVisible = NO;
    self.pseudoFullscreenURLString = nil;
}

#pragma mark - Playback HUD (elapsed / duration / progress + seek feedback)

static NSString *BrowserFormatTimecode(double seconds) {
    if (!isfinite(seconds) || seconds < 0) {
        return @"--:--";
    }
    NSInteger total = (NSInteger)lround(seconds);
    NSInteger hours = total / 3600;
    NSInteger minutes = (total % 3600) / 60;
    NSInteger secs = total % 60;
    if (hours > 0) {
        return [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)hours, (long)minutes, (long)secs];
    }
    return [NSString stringWithFormat:@"%02ld:%02ld", (long)minutes, (long)secs];
}

- (void)buildPlaybackHUDIfNeeded {
    if (self.playbackHUDContainer != nil) {
        return;
    }

    UIView *container = [[UIView alloc] initWithFrame:CGRectZero];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    container.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.62];
    container.layer.cornerRadius = 18.0;
    container.hidden = YES;
    container.userInteractionEnabled = NO;

    UILabel *timeLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    timeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    timeLabel.font = [UIFont monospacedDigitSystemFontOfSize:38.0 weight:UIFontWeightMedium];
    timeLabel.textColor = [UIColor whiteColor];
    timeLabel.textAlignment = NSTextAlignmentCenter;
    timeLabel.text = @"--:-- / --:--";

    UIView *track = [[UIView alloc] initWithFrame:CGRectZero];
    track.translatesAutoresizingMaskIntoConstraints = NO;
    track.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.28];
    track.layer.cornerRadius = 4.0;
    track.clipsToBounds = YES;

    UIView *fill = [[UIView alloc] initWithFrame:CGRectZero];
    fill.translatesAutoresizingMaskIntoConstraints = NO;
    fill.backgroundColor = [UIColor whiteColor];
    fill.layer.cornerRadius = 4.0;
    [track addSubview:fill];

    UILabel *actionLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    actionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    actionLabel.font = [UIFont systemFontOfSize:26.0 weight:UIFontWeightSemibold];
    actionLabel.textColor = [UIColor whiteColor];
    actionLabel.textAlignment = NSTextAlignmentCenter;
    actionLabel.text = @"";

    [container addSubview:timeLabel];
    [container addSubview:track];
    [container addSubview:actionLabel];
    [self.view addSubview:container];

    [NSLayoutConstraint activateConstraints:@[
        [container.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [container.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:48.0],
        [container.widthAnchor constraintEqualToConstant:620.0],

        [timeLabel.topAnchor constraintEqualToAnchor:container.topAnchor constant:18.0],
        [timeLabel.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:24.0],
        [timeLabel.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-24.0],

        [track.topAnchor constraintEqualToAnchor:timeLabel.bottomAnchor constant:14.0],
        [track.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:24.0],
        [track.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-24.0],
        [track.heightAnchor constraintEqualToConstant:8.0],

        [fill.leadingAnchor constraintEqualToAnchor:track.leadingAnchor],
        [fill.topAnchor constraintEqualToAnchor:track.topAnchor],
        [fill.bottomAnchor constraintEqualToAnchor:track.bottomAnchor],

        [actionLabel.topAnchor constraintEqualToAnchor:track.bottomAnchor constant:12.0],
        [actionLabel.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:24.0],
        [actionLabel.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-24.0],
        [actionLabel.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-16.0],
    ]];

    // Kept as a strong property so the multiplier can be swapped on every progress update.
    self.playbackProgressWidthConstraint =
        [fill.widthAnchor constraintEqualToAnchor:track.widthAnchor multiplier:0.0001];
    self.playbackProgressWidthConstraint.active = YES;

    self.playbackHUDContainer = container;
    self.playbackTimeLabel = timeLabel;
    self.playbackProgressTrack = track;
    self.playbackProgressFill = fill;
    self.playbackActionLabel = actionLabel;
    self.playbackProgressRatio = 0.0;

    // Keep the cursor above the HUD so it never swallows the pointer.
    if (self.remoteInputController.cursorView.superview == self.view) {
        [self.view bringSubviewToFront:self.remoteInputController.cursorView];
    }
}

// Reads "<current>|<duration>|<paused>" from the frame engine, merging iframe answers.
- (NSString *)queryPlaybackState {
    BrowserWebView *webView = self.webview;
    if (webView == nil) {
        return @"none";
    }
    NSString *result = [webView stringByEvaluatingJavaScriptFromString:
        @"(function(){"
        "if(typeof window.__browserPfCollectState==='function'){try{return window.__browserPfCollectState();}catch(e){}}"
        "if(typeof window.__browserPfState==='function'){try{return window.__browserPfState();}catch(e){}}"
        "return 'none';"
        "})()"];
    return result.length > 0 ? result : @"none";
}

- (void)updatePlaybackHUDWithState:(NSString *)state {
    [self buildPlaybackHUDIfNeeded];

    double current = 0.0;
    double duration = 0.0;
    BOOL paused = YES;
    BOOL hasState = NO;

    if ([state isKindOfClass:[NSString class]] &&
        ![state isEqualToString:@"none"] &&
        [state containsString:@"|"]) {
        NSArray<NSString *> *parts = [state componentsSeparatedByString:@"|"];
        if (parts.count >= 3) {
            current = [parts[0] doubleValue];
            duration = [parts[1] doubleValue];
            paused = ([parts[2] integerValue] != 0);
            hasState = (duration > 0.0);
        }
    }

    if (hasState) {
        self.playbackTimeLabel.text = [NSString stringWithFormat:@"%@ / %@",
                                       BrowserFormatTimecode(current),
                                       BrowserFormatTimecode(duration)];
        double ratio = current / duration;
        if (!isfinite(ratio)) {
            ratio = 0.0;
        }
        self.playbackProgressRatio = MIN(MAX(ratio, 0.0), 1.0);
    } else {
        self.playbackTimeLabel.text = @"--:-- / --:--";
        self.playbackProgressRatio = 0.0;
    }

    [self applyPlaybackProgressRatio];
}

- (void)applyPlaybackProgressRatio {
    NSLayoutConstraint *widthConstraint = self.playbackProgressWidthConstraint;
    UIView *track = self.playbackProgressTrack;
    UIView *fill = self.playbackProgressFill;
    if (widthConstraint == nil || track == nil || fill == nil) {
        return;
    }
    CGFloat ratio = MIN(MAX(self.playbackProgressRatio, 0.0), 1.0);
    widthConstraint.active = NO;

    // Auto Layout multipliers are immutable, so swap in a fresh constraint for the new ratio.
    NSLayoutConstraint *replacement =
        [fill.widthAnchor constraintEqualToAnchor:track.widthAnchor multiplier:MAX(ratio, 0.0001)];
    replacement.active = YES;
    self.playbackProgressWidthConstraint = replacement;
}

- (void)showPlaybackHUD {
    if (!self.pseudoFullscreenActive) {
        return;
    }
    [self buildPlaybackHUDIfNeeded];
    [self updatePlaybackHUDWithState:[self queryPlaybackState]];
    self.playbackHUDContainer.hidden = NO;
    [self.view bringSubviewToFront:self.playbackHUDContainer];
    if (self.remoteInputController.cursorView.superview == self.view) {
        [self.view bringSubviewToFront:self.remoteInputController.cursorView];
    }
    [self schedulePlaybackHUDAutoHide];
}

// The HUD must not sit on top of the video forever: hide it 4 s after the last interaction.
- (void)schedulePlaybackHUDAutoHide {
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(autoHidePlaybackHUD)
                                               object:nil];
    [self performSelector:@selector(autoHidePlaybackHUD) withObject:nil afterDelay:4.0];
}

- (void)autoHidePlaybackHUD {
    if (!self.pseudoFullscreenActive) {
        return;
    }
    if (self.playbackSeekRepeatTimer != nil) {
        [self schedulePlaybackHUDAutoHide];
        return;
    }
    [self hidePlaybackHUD];
}

- (void)hidePlaybackHUD {
    self.playbackHUDContainer.hidden = YES;
    self.playbackActionLabel.text = @"";
}

- (void)startPlaybackHUDSession {
    [self buildPlaybackHUDIfNeeded];
    [self showPlaybackHUD];
    [self startPlaybackHUDRefreshTimer];
}

// Polls the page for the current position while the HUD is on screen.
- (void)startPlaybackHUDRefreshTimer {
    [self.playbackHUDTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.playbackHUDTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                            repeats:YES
                                                              block:^(NSTimer *timer) {
        (void)timer;
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        if (!strongSelf.pseudoFullscreenActive) {
            [strongSelf stopPlaybackHUDSession];
            return;
        }
        if (strongSelf.playbackHUDContainer.hidden) {
            return;
        }
        [strongSelf updatePlaybackHUDWithState:[strongSelf queryPlaybackState]];
    }];
}

- (void)stopPlaybackHUDSession {
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(autoHidePlaybackHUD)
                                               object:nil];
    [self.playbackHUDTimer invalidate];
    self.playbackHUDTimer = nil;
    [self.playbackSeekRepeatTimer invalidate];
    self.playbackSeekRepeatTimer = nil;
    self.playbackSeekRepeatDelta = 0.0;
    [self hidePlaybackHUD];
}

- (void)togglePlaybackHUD {
    if (!self.pseudoFullscreenActive) {
        return;
    }
    if (self.playbackHUDContainer == nil || self.playbackHUDContainer.hidden) {
        [self showPlaybackHUD];
        if (self.playbackHUDTimer == nil) {
            [self startPlaybackHUDRefreshTimer];
        }
    } else {
        [self hidePlaybackHUD];
    }
}

// Seek by delta seconds through the frame engine (postMessage fan-out reaches cross-origin players).
- (NSString *)seekPlaybackBySeconds:(double)delta {
    BrowserWebView *webView = self.webview;
    if (webView == nil) {
        return @"no-webview";
    }
    NSString *script = [NSString stringWithFormat:
        @"(function(){"
        "var d=%.2f;"
        "var said='none';"
        "if(typeof window.__browserPfSeek==='function'){try{said=window.__browserPfSeek(d);}catch(e){}}"
        "if(typeof window.__browserPfFanOutMessage==='function'){"
            "try{window.__browserPfFanOutMessage({__browserPf:'seek',delta:d});}catch(e){}"
        "}"
        "return said;"
        "})()", delta];
    NSString *result = [webView stringByEvaluatingJavaScriptFromString:script];
    NSLog(@"[PlaybackHUD] seek delta=%.1f result=%@", delta, result ?: @"(nil)");
    return result ?: @"";
}

- (void)seekPlaybackBySeconds:(double)delta showFeedback:(BOOL)showFeedback {
    NSString *result = [self seekPlaybackBySeconds:delta];
    if (showFeedback) {
        [self buildPlaybackHUDIfNeeded];
        self.playbackActionLabel.text = (delta >= 0)
            ? [NSString stringWithFormat:@"⏩ +%.0fs", delta]
            : [NSString stringWithFormat:@"⏪ %.0fs", delta];
        self.playbackHUDContainer.hidden = NO;
        [self.view bringSubviewToFront:self.playbackHUDContainer];
        if (self.remoteInputController.cursorView.superview == self.view) {
            [self.view bringSubviewToFront:self.remoteInputController.cursorView];
        }
        [self schedulePlaybackHUDAutoHide];
    }
    // Refresh right away, then let the poll pick up the settled position.
    [self updatePlaybackHUDWithState:[self queryPlaybackState]];
    (void)result;
}

- (void)beginPlaybackSeekRepeatWithDelta:(double)delta {
    [self cancelPlaybackSeekRepeat];
    self.playbackSeekRepeatDelta = delta;
    [self seekPlaybackBySeconds:delta showFeedback:YES];

    __weak typeof(self) weakSelf = self;
    self.playbackSeekRepeatTimer = [NSTimer scheduledTimerWithTimeInterval:0.45
                                                                  repeats:YES
                                                                    block:^(NSTimer *timer) {
        (void)timer;
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        if (!strongSelf.pseudoFullscreenActive || strongSelf.playbackSeekRepeatDelta == 0.0) {
            [strongSelf cancelPlaybackSeekRepeat];
            return;
        }
        [strongSelf seekPlaybackBySeconds:strongSelf.playbackSeekRepeatDelta showFeedback:YES];
    }];
}

- (void)cancelPlaybackSeekRepeat {
    BOOL hadTimer = (self.playbackSeekRepeatTimer != nil);
    [self.playbackSeekRepeatTimer invalidate];
    self.playbackSeekRepeatTimer = nil;
    self.playbackSeekRepeatDelta = 0.0;
    if (hadTimer) {
        self.playbackActionLabel.text = @"";
    }
}

- (void)togglePlaybackPlayState {
    BrowserWebView *webView = self.webview;
    if (webView == nil) {
        return;
    }
    NSString *result = [webView stringByEvaluatingJavaScriptFromString:
        @"(function(){"
        "var said='none';"
        "if(typeof window.__browserPfTogglePlay==='function'){try{said=window.__browserPfTogglePlay();}catch(e){}}"
        "if(typeof window.__browserPfFanOutMessage==='function'){"
            "try{window.__browserPfFanOutMessage({__browserPf:'toggle'});}catch(e){}"
        "}"
        "return said;"
        "})()"];
    NSLog(@"[PlaybackHUD] toggle result=%@", result ?: @"(nil)");
    [self buildPlaybackHUDIfNeeded];
    self.playbackActionLabel.text = [result isEqualToString:@"playing"] ? @"▶︎ Play" :
                                    ([result isEqualToString:@"paused"] ? @"⏸ Pause" : @"");
    self.playbackHUDContainer.hidden = NO;
    if (self.remoteInputController.cursorView.superview == self.view) {
        [self.view bringSubviewToFront:self.remoteInputController.cursorView];
    }
    [self updatePlaybackHUDWithState:[self queryPlaybackState]];
}

- (NSString *)browserRemoteInputControllerHoverStateAtCursorPoint:(CGPoint)point {
    if (self.webview.request == nil) {
        return @"false";
    }
    CGPoint webPoint = [self.view convertPoint:point toView:self.webview];
    if (webPoint.y < 0) {
        return @"false";
    }
    CGPoint domPoint = [self browserDOMPointForCursor];
    return [self.pageActionCoordinator hoverStateAtDOMPoint:domPoint webView:self.webview];
}

- (void)browserRemoteInputControllerSetWebInteractionEnabled:(BOOL)enabled {
    self.webview.userInteractionEnabled = enabled;
}

- (void)browserRemoteInputControllerPersistSession {
    [self.tabCoordinator persistSession];
}

#pragma mark - BrowserWebViewDelegate

- (BOOL)webView:(id)webView shouldCreateNewTabWithRequest:(NSURLRequest *)request navigationType:(NSInteger)navigationType {
    (void)webView;
    (void)navigationType;
    return [self.tabCoordinator createNewTabWithRequest:request];
}

- (BOOL)webView:(id)webView shouldStartLoadWithRequest:(NSURLRequest *)request navigationType:(NSInteger)navigationType {
    (void)navigationType;
    [self.tabCoordinator prepareTabForRequest:request webView:webView];
    return YES;
}

- (void)webViewDidStartLoad:(id)webView {
    [self.tabCoordinator webViewDidStartLoad:webView];

    // Only leave pseudo fullscreen when the top-level document actually changed. A subresource
    // or fragment navigation must not resurrect the chrome mid-playback (that is exactly the
    // "fullscreen still shows the address bar" symptom).
    if (self.pseudoFullscreenActive) {
        NSString *currentURLString = [[(BrowserWebView *)webView request].URL absoluteString];
        BOOL samePage = (currentURLString.length > 0) &&
                        [currentURLString isEqualToString:self.pseudoFullscreenURLString];
        if (!samePage) {
            NSLog(@"[PseudoFullscreen] document changed (%@), leaving pseudo fullscreen",
                  currentURLString ?: @"(nil)");
            self.pseudoFullscreenActive = NO;
            [self stopPlaybackHUDSession];
            BOOL shouldRestoreTopBar = self.pseudoFullscreenTopBarWasVisible && !self.viewModel.topNavigationBarVisible;
            self.pseudoFullscreenTopBarWasVisible = NO;
            self.pseudoFullscreenURLString = nil;
            if (!self.pseudoFullscreenCursorModeWasEnabled && self.remoteInputController.cursorModeEnabled) {
                [self.remoteInputController setCursorModeEnabled:NO];
            }
            self.pseudoFullscreenCursorModeWasEnabled = NO;
            if (shouldRestoreTopBar) {
                [self browserShowTopNav];
            }
        }
    }
}

- (void)webViewDidFinishLoad:(id)webView {
    [self.tabCoordinator webViewDidFinishLoad:webView];
    if (self.tabOverviewController.visible) {
        BrowserTabViewModel *tab = [self.tabCoordinator tabForWebView:webView];
        NSInteger tabIndex = tab != nil ? [self.viewModel.tabs indexOfObject:tab] : NSNotFound;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self.tabOverviewController.visible) {
                return;
            }
            if (tabIndex != NSNotFound) {
                [self.tabOverviewController updateCardAtIndex:tabIndex];
            } else {
                [self.tabOverviewController reload];
            }
        });
    }
}

- (void)webView:(id)webView didFailLoadWithError:(NSError *)error {
    BrowserTabViewModel *tab = [self.tabCoordinator tabForWebView:webView];
    if (tab == nil) {
        return;
    }

    NSURL *failingURL = error.userInfo[NSURLErrorFailingURLErrorKey];
    NSURLRequest *currentRequest = [webView request];
    NSString *currentRequestURLString = currentRequest.URL.absoluteString ?: @"";
    if (failingURL != nil &&
        currentRequestURLString.length > 0 &&
        ![failingURL.absoluteString isEqualToString:currentRequestURLString]) {
        return;
    }

    if (tab == self.tabCoordinator.activeTab) {
        [self.topMenuView.loadingSpinner stopAnimating];
    }
    if (tab != self.tabCoordinator.activeTab) {
        return;
    }
    if ([self.navigationService shouldIgnoreLoadError:error]) {
        return;
    }

    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Could Not Load Webpage"
                                                                             message:error.localizedDescription
                                                                      preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    if (tab.requestURL.length > 1) {
        [alertController addAction:[UIAlertAction actionWithTitle:@"Google This Page"
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(__unused UIAlertAction *action) {
            NSURLRequest *searchRequest = [weakSelf.navigationService googleSearchRequestForFailedRequestURLString:tab.requestURL];
            if (searchRequest != nil) {
                [weakSelf.webview loadRequest:searchRequest];
            }
        }]];
    }
    if (self.webview.request != nil && self.webview.request.URL.absoluteString.length > 0) {
        [alertController addAction:[UIAlertAction actionWithTitle:@"Reload Page"
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(__unused UIAlertAction *action) {
            weakSelf.tabCoordinator.previousURL = @"";
            [weakSelf.webview reload];
        }]];
    } else {
        [alertController addAction:[UIAlertAction actionWithTitle:@"Enter a URL or Search"
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(__unused UIAlertAction *action) {
            [weakSelf requestURLorSearchInput];
        }]];
    }
    [alertController addAction:[UIAlertAction actionWithTitle:nil style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alertController animated:YES completion:nil];
}

#pragma mark - Presses / Touches

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    [self.remoteInputController handlePressesBegan:presses withEvent:event];
    [super pressesBegan:presses withEvent:event];
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    if ([self.remoteInputController handlePressesEnded:presses withEvent:event]) {
        return;
    }
    [super pressesEnded:presses withEvent:event];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if ([self.remoteInputController handleTouchesBegan:touches withEvent:event]) {
        return;
    }
    [super touchesBegan:touches withEvent:event];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if ([self.remoteInputController handleTouchesMoved:touches withEvent:event]) {
        return;
    }
    [super touchesMoved:touches withEvent:event];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)touches;
    (void)event;
    [self.remoteInputController handleTouchesEnded];
    [super touchesEnded:touches withEvent:event];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)touches;
    (void)event;
    [self.remoteInputController handleTouchesEnded];
    [super touchesCancelled:touches withEvent:event];
}

@end
