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
    if (!self.displayedHintsOnLaunch) {
        self.displayedHintsOnLaunch = YES;
        [self presentLaunchMenus];
    }
}

// Launch flow: favorites first (that is the shortcut the user asked for), then the usage hints.
// Presenting both at once would make the second one replace the first, so they are sequenced.
- (void)presentLaunchMenus {
    if (self.presentedViewController != nil) {
        return;
    }

    BOOL wantsFavoritesOnLaunch = !self.preferencesStore.dontShowFavoritesOnLaunch;
    if (wantsFavoritesOnLaunch) {
        __weak typeof(self) weakSelf = self;
        [self.menuCoordinator showFavoritesMenuWithAutoLaunchOption:YES
                                                         completion:^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }
            [strongSelf showLaunchHintsIfNeeded];
        }];
        return;
    }

    [self showLaunchHintsIfNeeded];
}

- (void)showLaunchHintsIfNeeded {
    if (self.preferencesStore.dontShowHintsOnLaunch) {
        return;
    }
    if (self.presentedViewController != nil) {
        return;
    }
    [self showHintsAlert];
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
// actually sees PlayPause under GCEventViewController. Favorites is no longer a long-press action:
// it opens on launch and from the top bar button.
- (void)handleGlobalLongPressNotification:(NSNotification *)notification {
    id typeValue = notification.userInfo[kBrowserGlobalLongPressTypeKey];
    if (![typeValue isKindOfClass:[NSNumber class]]) {
        return;
    }
    UIPressType type = (UIPressType)[typeValue integerValue];
    if (type != UIPressTypePlayPause && type != UIPressTypeSelect) {
        return;
    }

    if (self.tabOverviewController.visible || self.topBarFocusActive) {
        NSLog(@"[LongPress] ignored PlayPause (overlay active)");
        return;
    }

    UIViewController *presented = self.presentedViewController;
    if (presented != nil) {
        NSLog(@"[LongPress] ignored PlayPause (presented=%@)", NSStringFromClass([presented class]));
        return;
    }

    NSLog(@"[LongPress] PlayPause -> toggle pseudo fullscreen");
    [self.remoteInputController handleGlobalLongPressType:type];
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
        case BrowserTopBarActionFavorites:
            [self.menuCoordinator showFavoritesMenu];
            break;
        case BrowserTopBarActionFullscreen:
            if (self.viewModel.topNavigationBarVisible) {
                UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"隐藏顶部导航栏？"
                                                                                         message:@"仍可双击 Play/Pause 键打开侧边菜单。"
                                                                                  preferredStyle:UIAlertControllerStyleAlert];
                [alertController addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
                [alertController addAction:[UIAlertAction actionWithTitle:@"隐藏顶栏"
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
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"输入网址或搜索词"
                                                                             message:@""
                                                                      preferredStyle:UIAlertControllerStyleAlert];

    [alertController addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.keyboardType = UIKeyboardTypeURL;
        textField.placeholder = @"输入网址或搜索词";
        textField.textColor = kTextColor();
        [textField setReturnKeyType:UIReturnKeyDone];
    }];

    __weak typeof(self) weakSelf = self;
    [alertController addAction:[UIAlertAction actionWithTitle:@"用百度搜索"
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
    [alertController addAction:[UIAlertAction actionWithTitle:@"访问网址"
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
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"快捷菜单"
                                                                             message:@""
                                                                      preferredStyle:UIAlertControllerStyleAlert];

    if (self.webview.canGoForward) {
        [alertController addAction:[UIAlertAction actionWithTitle:@"前进"
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(__unused UIAlertAction *action) {
            [self.webview goForward];
        }]];
    }

    [alertController addAction:[UIAlertAction actionWithTitle:@"输入网址或用百度搜索"
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(__unused UIAlertAction *action) {
        [self showInputURLorSearchGoogle];
    }]];

    if (self.webview.request != nil && self.webview.request.URL.absoluteString.length > 0) {
        [alertController addAction:[UIAlertAction actionWithTitle:@"重新加载页面"
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
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"使用说明"
                                                                             message:@"双击触控区可在光标模式与滚动模式之间切换（双击窗口已放宽，更容易切出来）。\n光标模式下点按触控区即可点击。\n用上下左右键移动光标（单按 2pt，长按加速）；像关闭叉号这样的小按钮会自动吸附到最近的可点击控件。按住方向键，光标到达屏幕边缘后网页会自动继续翻动，不用切换模式也能直接下翻。\n滚动模式下方向键用于翻页；光标停在选集、播放列表等网页内部滚动区域时，方向键会优先翻动该区域，不必先切换模式。在网页里单击选集、播放列表等区域即可把它锁定给方向键，之后上/下键翻的就是这个列表；单击列表以外的区域或按一次 Menu 键即可解除，方向键重新控制整页。\n把光标移到顶栏任意图标（返回、刷新、前进、主页、标签页、收藏、隐藏顶栏、菜单）上按 Select 即可使用；地址栏会打开网址输入框。\n单按 Menu 键返回上一页，在首页则退出（若选集列表处于锁定状态，第一次 Menu 先解除锁定）。\n长按触控区（或长按 Play/Pause）可切换正在播放视频的伪全屏。\n网页自带的全屏按钮也会被重定向到这个全屏。\n全屏时：左右键快进/快退（按一下 10 秒、两下 1 分钟、三下 5 分钟；长按连续快进），上或下键显示/隐藏时间条，Play/Pause 或 Select 播放/暂停，Menu 退出全屏。\n光标停在视频上按 Select 可播放或暂停；其他位置按 Select 点击网页。\n启动时会自动打开收藏，也可点地址栏旁的金色星标打开。\n视频全屏时鼠标箭头会隐藏。\n单按 Play/Pause 键可开始播放视频（没有视频时打开网址输入框）。\n标签页面板中按上键或 Play/Pause 可关闭当前标签页。\n高级菜单 > 维护 里有清除缓存、清除 Cookies、清除全部浏览数据。\n高级菜单 > 兼容性 可循环切换浏览器标识（桌面 Safari / 移动 Safari / 桌面 Chrome）。\n较大的页面缓存与共享 Web 进程可加快加载速度。"
                                                                      preferredStyle:UIAlertControllerStyleAlert];

    __weak typeof(self) weakSelf = self;
    if (self.preferencesStore.dontShowHintsOnLaunch) {
        [alertController addAction:[UIAlertAction actionWithTitle:@"启动时始终显示"
                                                            style:UIAlertActionStyleDestructive
                                                          handler:^(__unused UIAlertAction *action) {
            weakSelf.preferencesStore.dontShowHintsOnLaunch = NO;
        }]];
    } else {
        [alertController addAction:[UIAlertAction actionWithTitle:@"不再显示"
                                                            style:UIAlertActionStyleDestructive
                                                          handler:^(__unused UIAlertAction *action) {
            weakSelf.preferencesStore.dontShowHintsOnLaunch = YES;
        }]];
    }
    [alertController addAction:[UIAlertAction actionWithTitle:@"关闭"
                                                        style:UIAlertActionStyleCancel
                                                      handler:nil]];
    [self presentViewController:alertController animated:YES completion:nil];
}

- (void)browserHandlePrimaryAction {
    BrowserWebView *webView = self.webview;
    if (webView == nil) {
        return;
    }

    CGPoint cursorOrigin = self.remoteInputController.cursorView.frame.origin;
    CGPoint point = [self.view convertPoint:cursorOrigin toView:webView];
    if (point.y < 0) {
        // Previously every Select in the top bar just activated focus mode, whose preferred item
        // defaults to the URL button -- so pressing any icon felt like "it opens the address bar".
        // Hit-test the actual icon under the cursor and run its action directly instead.
        CGPoint topBarPoint = [self.view convertPoint:cursorOrigin toView:self.topMenuView];
        BrowserTopBarAction action = [self.topMenuView actionForPoint:topBarPoint];
        if (action != BrowserTopBarActionNone) {
            NSLog(@"[TopBar] cursor Select -> action %ld at (%.0f,%.0f)", (long)action, topBarPoint.x, topBarPoint.y);
            [self performTopBarAction:action];
            return;
        }
        [self activateTopBarFocusMode];
        return;
    }

    if (!self.remoteInputController.cursorModeEnabled) {
        return;
    }

    CGPoint domPoint = [self browserDOMPointForCursor];
    [self.pageActionCoordinator handlePageSelectionAtDOMPoint:domPoint webView:webView];
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

// Third entry point for fullscreen, reachable from the Advanced Menu, for remotes where neither
// Play/Pause nor a clickpad hold is available.
- (void)browserTogglePseudoFullscreen {
    [self browserRemoteInputControllerHandlePseudoFullscreenPress];
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
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"退出应用？"
                                                                       message:nil
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"退出"
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(__unused UIAlertAction *action) {
            exit(EXIT_SUCCESS);
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
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

// A learning remote's dedicated Play key arrives as a PlayPause press. WebKit rejects play()
// without a user activation while pause() needs none, so drive the resume from native code: the
// injected engine fans the request out to every frame (including cross-origin iframes), and each
// frame only acts when its own video is paused. Returns whether any video was found, so the input
// controller can keep the URL sheet as the no-video fallback.
- (BOOL)browserRemoteInputControllerHandleRemotePlayRequest {
    BrowserWebView *webView = self.webview;
    if (webView == nil) {
        return NO;
    }
    NSString *script =
        @"(function(){"
        "var said='none';"
        "if(typeof window.__browserPfResumePlay==='function'){"
            "try{said=window.__browserPfResumePlay();}catch(e){said='error';}"
        "}"
        "if(typeof window.__browserPfFanOutMessage==='function'){"
            "try{window.__browserPfFanOutMessage({__browserPf:'resume'});}catch(e){}"
        "}"
        "var st='none';"
        "if(typeof window.__browserPfCollectState==='function'){"
            "try{st=window.__browserPfCollectState();}catch(e){}"
        "}"
        // A cross-origin player may not have answered the state poll yet. Counting an iframe as a
        // possible video keeps the Play key from falling through to the URL sheet on such pages.
        "var domVideo=false;"
        "try{domVideo=(document.querySelector('video')!==null)||(document.querySelectorAll('iframe').length>0);}catch(e){}"
        "var hasVideo=(said==='playing'||said==='already'||said==='clicked')||"
            "(st&&st!=='none'&&st!=='error'&&st.indexOf('|')>0)||domVideo;"
        "return hasVideo?'yes':'no';"
        "})()";
    NSString *result = [webView stringByEvaluatingJavaScriptFromString:script];
    NSLog(@"[RemotePlay] resume result=%@", result ?: @"(nil)");
    return [result isEqualToString:@"yes"];
}

// Select outside fullscreen: toggle the video only when the cursor is on it. The injected engine
// hit-tests the top frame; a hit on an iframe is fanned out so a cross-origin player still gets the
// request. Returns NO when nothing is under the cursor, so Select still falls through to a click.
// build-16: episode/playlist lists live in inner overflow containers. Ask the injected script
// to scroll the innermost scrollable ancestor under the cursor; 'inner'/'iframe' means it moved,
// so the caller must NOT also move the document-level UIScrollView.
- (BOOL)browserRemoteInputControllerScrollInnerContainerByDelta:(CGPoint)delta {
    BrowserWebView *webView = self.webview;
    if (webView == nil) {
        return NO;
    }
    CGPoint point = [self browserDOMPointForCursor];
    NSString *script = [NSString stringWithFormat:
        @"(function(){"
        "if(typeof window.__browserPfScrollAtPoint!=='function'){return 'none';}"
        "try{return window.__browserPfScrollAtPoint(%f,%f,%f,%f);}catch(e){return 'none';}"
        "})()", point.x, point.y, delta.x, delta.y];
    NSString *result = [webView stringByEvaluatingJavaScriptFromString:script];
    return [result isEqualToString:@"inner"] || [result isEqualToString:@"iframe"];
}

// build-23: pin the scrollable region under the cursor so the arrows can page it without a mode
// switch. Returns @"pinned" (non-nil) when a region was found, nil otherwise -- and "otherwise"
// deliberately includes "nothing scrollable here", because that is also the signal the caller uses
// to drop an existing pin when the user clicks elsewhere.
- (nullable NSString *)browserRemoteInputControllerActivateScrollRegionAtCursorPoint {
    BrowserWebView *webView = self.webview;
    if (webView == nil) {
        return nil;
    }
    CGPoint point = [self browserDOMPointForCursor];
    NSString *script = [NSString stringWithFormat:
        @"(function(){"
        "if(typeof window.__browserPfActivateScrollAtPoint!=='function'){return '';}"
        "try{return window.__browserPfActivateScrollAtPoint(%f,%f);}catch(e){return '';}"
        "})()", point.x, point.y];
    NSString *result = [webView stringByEvaluatingJavaScriptFromString:script];
    if (result.length == 0) {
        return nil;
    }
    NSLog(@"[ScrollPin] activated at (%.0f,%.0f) -> %@", point.x, point.y, result);
    return result;
}

// Scrolls the pinned container. 'none' means the pin is gone (page navigated, list re-rendered),
// which the caller treats as "unpin and fall back to the document".
- (BOOL)browserRemoteInputControllerScrollPinnedRegionByDelta:(CGPoint)delta {
    BrowserWebView *webView = self.webview;
    if (webView == nil) {
        return NO;
    }
    NSString *script = [NSString stringWithFormat:
        @"(function(){"
        "if(typeof window.__browserPfScrollPinned!=='function'){return 'none';}"
        "try{return window.__browserPfScrollPinned(%f,%f);}catch(e){return 'none';}"
        "})()", delta.x, delta.y];
    NSString *result = [webView stringByEvaluatingJavaScriptFromString:script];
    return [result isEqualToString:@"inner"];
}

- (void)browserRemoteInputControllerClearScrollPin {
    BrowserWebView *webView = self.webview;
    if (webView == nil) {
        return;
    }
    // build-25: the page-side half of dropping a pin. Without it the marker and the
    // overscroll-behavior:contain applied with it survive after the arrows are handed back, so an
    // abandoned pin keeps changing the page's own scroll chaining.
    [webView stringByEvaluatingJavaScriptFromString:
        @"(function(){"
        "if(typeof window.__browserPfClearScrollPin!=='function'){return 'none';}"
        "try{window.__browserPfClearScrollPin();return 'ok';}catch(e){return 'none';}"
        "})()"];
}

- (BOOL)browserRemoteInputControllerTogglePlaybackAtCursorPoint {
    BrowserWebView *webView = self.webview;
    if (webView == nil) {
        return NO;
    }
    CGPoint point = [self browserDOMPointForCursor];
    NSString *script = [NSString stringWithFormat:
        @"(function(){"
        "var said='none';"
        "if(typeof window.__browserPfCursorTogglePlay==='function'){"
            "try{said=window.__browserPfCursorTogglePlay(%f,%f);}catch(e){said='error';}"
        "}"
        "if(said==='iframe'&&typeof window.__browserPfFanOutMessage==='function'){"
            "try{window.__browserPfFanOutMessage({__browserPf:'cursorToggle',x:%f,y:%f});}catch(e){}"
        "}"
        "return (said==='playing'||said==='paused'||said==='clicked'||said==='iframe')?'yes':'no';"
        "})()",
        point.x, point.y, point.x, point.y];
    NSString *result = [webView stringByEvaluatingJavaScriptFromString:script];
    NSLog(@"[SelectPlay] cursor toggle result=%@ at (%.0f,%.0f)", result ?: @"(nil)", point.x, point.y);
    return [result isEqualToString:@"yes"];
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

// Tiered seek: the input controller counts the taps and hands over the finished step.
- (void)browserRemoteInputControllerApplySeekDelta:(double)delta
                                  displayedSeconds:(double)displayedSeconds
                                          tapCount:(NSInteger)tapCount {
    if (!self.pseudoFullscreenActive) {
        return;
    }
    NSLog(@"[PlaybackHUD] tiered seek taps=%ld delta=%.0f shown=%.0f",
          (long)tapCount, delta, displayedSeconds);
    [self seekPlaybackBySeconds:delta
                   showFeedback:YES
              displayedMagnitude:displayedSeconds
                         tapCount:tapCount];
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
// The reply says what was actually found, so the caller can refuse to enter a blank fullscreen.
- (NSString *)browserPseudoFullscreenEnterScript {
    return
    @"(function(){"
    "var applied='no-engine';"
    "if(typeof window.__browserPfApply==='function'){"
        "try{applied=window.__browserPfApply();}catch(e){applied='error';}"
    "}"
    "var fanned=false;"
    "if(typeof window.__browserPfFanOut==='function'){"
        "try{fanned=window.__browserPfFanOut('apply');}catch(e){}"
    "}"
    "if(applied==='no-engine'){return 'no-engine';}"
    "if(applied==='error'){return 'error';}"
    "if(applied==='ok'){return fanned?'video+frames':'video';}"
    "if(applied==='iframe'){return fanned?'iframe+frames':'iframe';}"
    "return fanned?'frames':'no-video';"
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

// True when the engine actually found something to promote to full frame. Entering on a page with
// no video anywhere would just black out the screen, so the caller checks first.
// The engine reports one of: no-engine | error | no-video | video | video+frames | iframe |
// iframe+frames | frames. Only the three concrete hits count.
static BOOL BrowserPseudoFullscreenResultHasTarget(NSString *result) {
    if (result.length == 0) {
        return NO;
    }
    static NSString * const kHitPrefixes[] = {@"video", @"iframe", @"frames"};
    for (NSUInteger i = 0; i < sizeof(kHitPrefixes) / sizeof(kHitPrefixes[0]); i++) {
        if ([result hasPrefix:kHitPrefixes[i]]) {
            return YES;
        }
    }
    return NO;
}

// Enter initiated by a remote-key shortcut. A page with no video at all would just go black, so the
// result of the styling call decides whether fullscreen may start. Held-Select is a very common
// key, so a false trigger has to be cheap to recover from; a false refusal also would be annoying,
// hence one retry: a player can mount a fraction of a second after the key goes down.
- (void)enterPseudoFullscreenAndRememberChrome {
    if (self.pseudoFullscreenActive) {
        return;
    }
    [self attemptPseudoFullscreenEnterWithRetry:YES];
}

- (void)attemptPseudoFullscreenEnterWithRetry:(BOOL)allowRetry {
    if (self.pseudoFullscreenActive) {
        return;
    }

    NSString *styleResult = [self applyPseudoFullscreenStyling];
    if (BrowserPseudoFullscreenResultHasTarget(styleResult)) {
        [self activatePseudoFullscreenChrome];
        return;
    }

    if (allowRetry) {
        NSLog(@"[PseudoFullscreen] no target yet (%@), retrying once", styleResult ?: @"(nil)");
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.22 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }
            [strongSelf attemptPseudoFullscreenEnterWithRetry:NO];
        });
        return;
    }

    NSLog(@"[PseudoFullscreen] no video target (%@), not entering", styleResult ?: @"(nil)");
    [self showNoVideoForFullscreenNotice];
}

// Remembers the previous chrome/cursor state, hides the chrome and starts the HUD. Kept separate
// because a page-initiated request is always honoured (the site asked for it), while the remote-key
// shortcut is only honoured when there is something to promote.
- (void)activatePseudoFullscreenChrome {
    if (self.pseudoFullscreenActive) {
        return;
    }

    self.pseudoFullscreenTopBarWasVisible = self.viewModel.topNavigationBarVisible;
    self.pseudoFullscreenCursorModeWasEnabled = self.remoteInputController.cursorModeEnabled;
    self.pseudoFullscreenActive = YES;
    self.pseudoFullscreenURLString = [self.webview.request.URL absoluteString];

    // Keep cursor mode on so the key routing stays consistent, but hide the arrow itself: a
    // fullscreen video has no pointer. refreshInteractionState reads pseudoFullscreenActive (set
    // above), so the cursor disappears as soon as fullscreen starts.
    if (!self.remoteInputController.cursorModeEnabled) {
        [self.remoteInputController setCursorModeEnabled:YES];
    }
    [self.remoteInputController refreshInteractionState];

    if (self.viewModel.topNavigationBarVisible) {
        [self browserHideTopNav];
    }

    // Reveal the timecode/progress HUD so the duration and position are visible right away.
    [self startPlaybackHUDSession];
}

// Holding the key on a page without a video must explain itself; a silent black screen looks like
// the shortcut is broken.
- (void)showNoVideoForFullscreenNotice {
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(hideNoVideoNotice)
                                               object:nil];
    [self buildPlaybackHUDIfNeeded];
    self.playbackActionLabel.text = @"此页面没有视频";
    self.playbackHUDContainer.hidden = NO;
    [self.view bringSubviewToFront:self.playbackHUDContainer];
    if (self.remoteInputController.cursorView.superview == self.view) {
        [self.view bringSubviewToFront:self.remoteInputController.cursorView];
    }
    [self performSelector:@selector(hideNoVideoNotice)
               withObject:nil
               afterDelay:2.0];
}

- (void)hideNoVideoNotice {
    if (self.pseudoFullscreenActive) {
        return;
    }
    self.playbackActionLabel.text = @"";
    self.playbackHUDContainer.hidden = YES;
}

// Enter requested by the page itself (its own fullscreen button). The page called
// requestFullscreen; we neutralised that and restyle here instead, so no native container is
// created and the app chrome can actually hide. No target check: the site asked for fullscreen.
- (void)enterPseudoFullscreenFromPage {
    if (self.pseudoFullscreenActive) {
        [self applyPseudoFullscreenStyling];
        return;
    }
    [self applyPseudoFullscreenStyling];
    [self activatePseudoFullscreenChrome];
}

- (void)exitPseudoFullscreen {
    BrowserWebView *webView = self.webview;
    if (webView != nil) {
        NSString *result = [webView stringByEvaluatingJavaScriptFromString:[self browserPseudoFullscreenExitScript]];
        NSLog(@"[PseudoFullscreen] exit result=%@", result);
    }

    self.pseudoFullscreenActive = NO;
    [self.remoteInputController resetPseudoFullscreenSeekState];
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
    // The arrow must come back even when cursor mode was already on (in that case the setter above
    // is skipped and would leave the cursor hidden).
    [self.remoteInputController refreshInteractionState];
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

// Seek feedback reads as a time span, not as a raw second count: "+1:00" beats "+60s".
static NSString *BrowserSeekFeedbackText(double delta) {
    BOOL forward = (delta >= 0);
    double magnitude = fabs(delta);
    NSString *arrow = forward ? @"⏩" : @"⏪";
    NSString *sign = forward ? @"+" : @"-";
    if (magnitude >= 60.0) {
        NSInteger total = (NSInteger)lround(magnitude);
        NSInteger minutes = total / 60;
        NSInteger secs = total % 60;
        if (secs == 0) {
            return [NSString stringWithFormat:@"%@ %@%ldm", arrow, sign, (long)minutes];
        }
        return [NSString stringWithFormat:@"%@ %@%ld:%02ld", arrow, sign, (long)minutes, (long)secs];
    }
    return [NSString stringWithFormat:@"%@ %@%.0fs", arrow, sign, magnitude];
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
    [self seekPlaybackBySeconds:delta
                   showFeedback:showFeedback
              displayedMagnitude:fabs(delta)
                       tapCount:0];
}

// displayedMagnitude is the cumulative step of the tap series, so three taps read "5m" even though
// the last increment was only the difference to the previous tier.
- (void)seekPlaybackBySeconds:(double)delta
                 showFeedback:(BOOL)showFeedback
            displayedMagnitude:(double)displayedMagnitude
                     tapCount:(NSInteger)tapCount {
    NSString *result = [self seekPlaybackBySeconds:delta];
    if (showFeedback) {
        [self buildPlaybackHUDIfNeeded];
        self.playbackActionLabel.text = BrowserSeekFeedbackText(delta >= 0 ? displayedMagnitude : -displayedMagnitude);
        if (tapCount >= 2) {
            self.playbackActionLabel.text = [NSString stringWithFormat:@"%@  ×%ld",
                                             self.playbackActionLabel.text, (long)tapCount];
        }
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
    self.playbackActionLabel.text = [result isEqualToString:@"playing"] ? @"▶︎ 播放" :
                                    ([result isEqualToString:@"paused"] ? @"⏸ 暂停" :
                                    ([result isEqualToString:@"clicked"] ? @"▶︎ 播放（点按）" : @""));
    self.playbackHUDContainer.hidden = NO;
    [self.view bringSubviewToFront:self.playbackHUDContainer];
    if (self.remoteInputController.cursorView.superview == self.view) {
        [self.view bringSubviewToFront:self.remoteInputController.cursorView];
    }
    [self updatePlaybackHUDWithState:[self queryPlaybackState]];
    [self schedulePlaybackHUDAutoHide];

    // The page may take a moment to actually start; re-poll shortly so the HUD tells the truth
    // instead of showing a stale "playing" that never happened.
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.55 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil || !strongSelf.pseudoFullscreenActive) {
            return;
        }
        [strongSelf updatePlaybackHUDWithState:[strongSelf queryPlaybackState]];
    });
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

    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"无法加载网页"
                                                                             message:error.localizedDescription
                                                                      preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    if (tab.requestURL.length > 1) {
        [alertController addAction:[UIAlertAction actionWithTitle:@"用百度搜索此页"
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(__unused UIAlertAction *action) {
            NSURLRequest *searchRequest = [weakSelf.navigationService googleSearchRequestForFailedRequestURLString:tab.requestURL];
            if (searchRequest != nil) {
                [weakSelf.webview loadRequest:searchRequest];
            }
        }]];
    }
    if (self.webview.request != nil && self.webview.request.URL.absoluteString.length > 0) {
        [alertController addAction:[UIAlertAction actionWithTitle:@"重新加载页面"
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(__unused UIAlertAction *action) {
            weakSelf.tabCoordinator.previousURL = @"";
            [weakSelf.webview reload];
        }]];
    } else {
        [alertController addAction:[UIAlertAction actionWithTitle:@"输入网址或搜索"
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
