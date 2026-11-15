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
// Select outside fullscreen: returns YES when the cursor sits on a video and playback was toggled,
// so the press is consumed instead of also clicking the page underneath.
- (BOOL)browserRemoteInputControllerTogglePlaybackAtCursorPoint;
// build-16: scroll the innermost scrollable container under the cursor (episode lists,
// playlists, side panels). Returns YES when an inner container or a delegated iframe moved,
// so the document-level UIScrollView is not scrolled at the same time.
- (BOOL)browserRemoteInputControllerScrollInnerContainerByDelta:(CGPoint)delta;
// build-23: one Select press over an episode list pins that list as the arrow target, so the list
// can be paged without first switching to scroll mode. Returns an opaque non-empty token (the
// container's identity, stable for the life of the page) when the point sits in a scrollable
// region, or nil when it does not. A nil answer is the "clicked somewhere else" case that clears
// the pin.
- (nullable NSString *)browserRemoteInputControllerActivateScrollRegionAtCursorPoint;
// Scrolls the pinned container without re-detecting it under the cursor. NO when nothing is
// pinned any more (page navigated, element removed), which tells the caller to drop the pin.
- (BOOL)browserRemoteInputControllerScrollPinnedRegionByDelta:(CGPoint)delta;
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
