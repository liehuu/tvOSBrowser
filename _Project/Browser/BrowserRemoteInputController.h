#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@protocol BrowserRemoteInputControllerHost <NSObject>

- (nullable UIScrollView *)browserRemoteInputControllerActiveScrollView;
- (nullable UIViewController *)browserRemoteInputControllerPresentedViewController;
- (BOOL)browserRemoteInputControllerTopBarFocusActive;
- (BOOL)browserRemoteInputControllerCanActivateTopBarFocus;
- (void)browserRemoteInputControllerActivateTopBarFocus;
- (void)browserRemoteInputControllerDeactivateTopBarFocus;
- (BOOL)browserRemoteInputControllerTabOverviewVisible;
- (BOOL)browserRemoteInputControllerTabOverviewContainsPoint:(CGPoint)point;
- (BOOL)browserRemoteInputControllerHandleTabOverviewSelectionAtPoint:(CGPoint)point;
- (void)browserRemoteInputControllerDismissTabOverview;
- (void)browserRemoteInputControllerHandleTabOverviewAlternateAction;
- (void)browserRemoteInputControllerHandlePrimaryAction;
- (void)browserRemoteInputControllerHandleMenuPress;
- (void)browserRemoteInputControllerHandlePlayPausePress;
// A learning remote's dedicated Play key arrives as a PlayPause press. Returns YES when a
// video was found, so the input controller treats the press as playback instead of the URL sheet.
- (BOOL)browserRemoteInputControllerHandleRemotePlayRequest;
- (void)browserRemoteInputControllerHandlePseudoFullscreenPress;
- (void)browserRemoteInputControllerHandleFavoritesPress;
- (BOOL)browserRemoteInputControllerPseudoFullscreenActive;
- (void)browserRemoteInputControllerSeekBySeconds:(double)delta began:(BOOL)began;
// Tiered seek: delta is the increment to apply now; displayedSeconds is the cumulative step the tap
// series has reached (10 / 60 / 300) and is what the HUD shows; tapCount is how many taps so far.
- (void)browserRemoteInputControllerApplySeekDelta:(double)delta
                                  displayedSeconds:(double)displayedSeconds
                                          tapCount:(NSInteger)tapCount;
- (void)browserRemoteInputControllerTogglePlaybackHUD;
- (void)browserRemoteInputControllerTogglePlaybackPlayState;
- (void)browserRemoteInputControllerHandleAdvancedMenuPress;
- (NSString *)browserRemoteInputControllerHoverStateAtCursorPoint:(CGPoint)point;
- (void)browserRemoteInputControllerSetWebInteractionEnabled:(BOOL)enabled;
- (void)browserRemoteInputControllerPersistSession;

@end

@interface BrowserRemoteInputController : NSObject

@property (nonatomic, readonly) UIImageView *cursorView;
@property (nonatomic, readonly) UIPanGestureRecognizer *manualScrollPanRecognizer;
@property (nonatomic, readonly) UITapGestureRecognizer *playPauseDoubleTapRecognizer;
@property (nonatomic, readonly, getter=isCursorModeEnabled) BOOL cursorModeEnabled;

- (instancetype)initWithHost:(id<BrowserRemoteInputControllerHost>)host
                    rootView:(UIView *)rootView NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

- (void)handleGlobalSelectPressEndedNotification;
- (void)handleGlobalArrowPressType:(UIPressType)type began:(BOOL)began;
- (void)handleGlobalLongPressType:(UIPressType)type;
// Clears any half-finished seek tap series (called when fullscreen ends, so a stale window cannot
// extend a series into normal browsing).
- (void)resetPseudoFullscreenSeekState;
- (void)handlePressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event;
- (BOOL)handlePressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event;
- (BOOL)handleTouchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event;
- (BOOL)handleTouchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event;
- (void)handleTouchesEnded;
- (void)setCursorModeEnabled:(BOOL)cursorModeEnabled;
- (void)refreshInteractionState;

@end

NS_ASSUME_NONNULL_END
