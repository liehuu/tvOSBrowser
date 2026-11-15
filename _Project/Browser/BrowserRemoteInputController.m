#import "BrowserRemoteInputController.h"

static UIImage *BrowserDefaultCursor(void) {
    static UIImage *image;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        image = [UIImage imageNamed:@"Cursor"];
    });
    return image;
}

static UIImage *BrowserPointerCursor(void) {
    static UIImage *image;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        image = [UIImage imageNamed:@"Pointer"];
    });
    return image;
}

static NSString *BrowserPressTypeString(UIPressType type) {
    switch (type) {
        case UIPressTypeMenu: return @"Menu";
        case UIPressTypePlayPause: return @"PlayPause";
        case UIPressTypeSelect: return @"Select";
        case UIPressTypeUpArrow: return @"Up";
        case UIPressTypeDownArrow: return @"Down";
        case UIPressTypeLeftArrow: return @"Left";
        case UIPressTypeRightArrow: return @"Right";
        default: return [NSString stringWithFormat:@"Type-%ld", (long)type];
    }
}

static NSString *BrowserPressPhaseString(UIPressPhase phase) {
    switch (phase) {
        case UIPressPhaseBegan: return @"Began";
        case UIPressPhaseChanged: return @"Changed";
        case UIPressPhaseStationary: return @"Stationary";
        case UIPressPhaseEnded: return @"Ended";
        case UIPressPhaseCancelled: return @"Cancelled";
        default: return [NSString stringWithFormat:@"Phase-%ld", (long)phase];
    }
}

@interface BrowserRemoteInputController ()

@property (nonatomic, weak) id<BrowserRemoteInputControllerHost> host;
@property (nonatomic, weak) UIView *rootView;
@property (nonatomic, readwrite) UIImageView *cursorView;
@property (nonatomic, readwrite) UIPanGestureRecognizer *manualScrollPanRecognizer;
@property (nonatomic, readwrite) UITapGestureRecognizer *playPauseDoubleTapRecognizer;
@property (nonatomic, readwrite, getter=isCursorModeEnabled) BOOL cursorModeEnabled;
@property (nonatomic) CGPoint lastTouchLocation;
@property (nonatomic) CADisplayLink *manualScrollDisplayLink;
@property (nonatomic) CGPoint manualScrollVelocity;
@property (nonatomic) CFTimeInterval manualScrollLastTimestamp;
@property (nonatomic) CFTimeInterval manualScrollLastMovementTimestamp;
@property (nonatomic) CFTimeInterval lastDirectSelectPressTimestamp;
@property (nonatomic) CFTimeInterval lastSelectPressTimestamp;
@property (nonatomic) BOOL awaitingSecondSelectPress;
@property (nonatomic) NSTimer *cursorArrowRepeatTimer;
@property (nonatomic) UIPressType cursorArrowRepeatPressType;
// build-22: true between a press's begin and its end, independent of the repeat timer. The timer
// is cancelled and restarted by the duplicate-begin path, so it cannot be used as the token.
@property (nonatomic) BOOL arrowPressActive;
// build-23: true while a Select press has pinned a scrollable region (an episode list) as the
// arrow target. Cleared by a Select that lands outside any scrollable region, and by anything that
// invalidates the page.
@property (nonatomic) BOOL scrollPinActive;
@property (nonatomic) CFTimeInterval lastArrowEndedTimestamp;
@property (nonatomic) UIPressType lastArrowEndedType;
@property (nonatomic) BOOL playPauseLongPressConsumed;
@property (nonatomic) BOOL selectLongPressConsumed;
@property (nonatomic) CFTimeInterval lastSelectLongPressTimestamp;
// Tiered seek in pseudo fullscreen: 1 tap = 10 s, 2 taps = 60 s, 3+ taps = 300 s.
@property (nonatomic) NSInteger seekTapCount;
@property (nonatomic) double seekTapDirection;
@property (nonatomic) CFTimeInterval seekPressBeganTimestamp;
@property (nonatomic) BOOL seekHoldActive;
@property (nonatomic) NSTimer *seekTapWindowTimer;

- (void)handleFullscreenSeekPressWithDirection:(double)direction began:(BOOL)began;
- (void)resetSeekTapSeries;

@end

@implementation BrowserRemoteInputController

- (instancetype)initWithHost:(id<BrowserRemoteInputControllerHost>)host
                    rootView:(UIView *)rootView {
    self = [super init];
    if (self) {
        _host = host;
        _rootView = rootView;
        _lastTouchLocation = CGPointMake(-1, -1);
        _cursorModeEnabled = YES;

        _cursorView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 64, 64)];
        _cursorView.center = CGPointMake(CGRectGetMidX([UIScreen mainScreen].bounds), CGRectGetMidY([UIScreen mainScreen].bounds));
        _cursorView.image = BrowserDefaultCursor();

        _playPauseDoubleTapRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handlePlayPauseDoubleTap:)];
        _playPauseDoubleTapRecognizer.numberOfTapsRequired = 2;
        _playPauseDoubleTapRecognizer.allowedPressTypes = @[@(UIPressTypePlayPause)];
        [rootView addGestureRecognizer:_playPauseDoubleTapRecognizer];

        _manualScrollPanRecognizer = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleManualScrollPan:)];
        _manualScrollPanRecognizer.allowedTouchTypes = @[ @(UITouchTypeIndirect) ];
        _manualScrollPanRecognizer.cancelsTouchesInView = NO;
        _manualScrollPanRecognizer.enabled = NO;
        [rootView addGestureRecognizer:_manualScrollPanRecognizer];
    }
    return self;
}

- (void)setCursorModeEnabled:(BOOL)cursorModeEnabled {
    BOOL wasCursorModeEnabled = self.cursorModeEnabled;
    _cursorModeEnabled = cursorModeEnabled;
    self.lastTouchLocation = CGPointMake(-1, -1);
    [self stopManualScrollInertia];
    // build-22: the mode switch is a double-Select, and the arrows that follow are a NEW press
    // sequence. Any press state carried over from before the switch would make the first arrow of
    // the new sequence look like a duplicate and be swallowed, or leave a dead token behind that
    // blocks the next real press. Clearing both tokens here makes every switch start clean.
    self.arrowPressActive = NO;
    self.cursorArrowRepeatPressType = (UIPressType)-1;
    [self cancelCursorArrowRepeat];
    [self refreshInteractionState];
    if (!wasCursorModeEnabled && cursorModeEnabled) {
        [self.host browserRemoteInputControllerPersistSession];
    }
}

- (void)refreshInteractionState {
    UIScrollView *scrollView = [self.host browserRemoteInputControllerActiveScrollView];
    BOOL topBarFocusActive = [self.host browserRemoteInputControllerTopBarFocusActive];
    BOOL shouldAllowWebInteraction = !self.cursorModeEnabled &&
        ![self.host browserRemoteInputControllerTabOverviewVisible] &&
        !topBarFocusActive;
    scrollView.scrollEnabled = shouldAllowWebInteraction;
    self.manualScrollPanRecognizer.enabled = shouldAllowWebInteraction;
    [self.host browserRemoteInputControllerSetWebInteractionEnabled:shouldAllowWebInteraction];
    // Fullscreen playback has no pointer: the arrow must disappear while the video is promoted.
    self.cursorView.hidden = !self.cursorModeEnabled ||
        [self.host browserRemoteInputControllerTabOverviewVisible] ||
        topBarFocusActive ||
        [self.host browserRemoteInputControllerPseudoFullscreenActive];
}

- (BOOL)applyManualScrollDelta:(CGPoint)delta allowInnerScroll:(BOOL)allowInnerScroll {
    // build-16: discrete arrow steps prefer the innermost scrollable element under the cursor.
    // The inertia display link passes NO: a synchronous JS round-trip every frame would block
    // the main thread. Returning YES here keeps the document-level UIScrollView still.
    if (allowInnerScroll &&
        [self.host browserRemoteInputControllerScrollInnerContainerByDelta:delta]) {
        return YES;
    }
    UIScrollView *scrollView = [self.host browserRemoteInputControllerActiveScrollView];
    if (scrollView == nil) {
        return NO;
    }

    CGPoint contentOffset = scrollView.contentOffset;
    CGFloat maxOffsetX = MAX(0.0, scrollView.contentSize.width - CGRectGetWidth(scrollView.bounds));
    CGFloat maxOffsetY = MAX(0.0, scrollView.contentSize.height - CGRectGetHeight(scrollView.bounds));
    CGFloat nextOffsetX = MIN(MAX(contentOffset.x + delta.x, 0.0), maxOffsetX);
    CGFloat nextOffsetY = MIN(MAX(contentOffset.y + delta.y, 0.0), maxOffsetY);
    CGPoint nextOffset = CGPointMake(nextOffsetX, nextOffsetY);
    [scrollView setContentOffset:nextOffset animated:NO];
    return !CGPointEqualToPoint(contentOffset, nextOffset);
}

- (void)stopManualScrollInertia {
    [self.manualScrollDisplayLink invalidate];
    self.manualScrollDisplayLink = nil;
    self.manualScrollVelocity = CGPointZero;
    self.manualScrollLastTimestamp = 0;
    self.manualScrollLastMovementTimestamp = 0;
}

- (void)startManualScrollInertiaWithVelocity:(CGPoint)velocity {
    [self stopManualScrollInertia];
    if (fabs(velocity.x) < 25.0 && fabs(velocity.y) < 25.0) {
        return;
    }

    self.manualScrollVelocity = velocity;
    self.manualScrollLastTimestamp = 0;
    self.manualScrollDisplayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(handleManualScrollDisplayLink:)];
    [self.manualScrollDisplayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)handleManualScrollDisplayLink:(CADisplayLink *)displayLink {
    if (self.cursorModeEnabled ||
        [self.host browserRemoteInputControllerTabOverviewVisible] ||
        [self.host browserRemoteInputControllerTopBarFocusActive]) {
        [self stopManualScrollInertia];
        return;
    }

    if (self.manualScrollLastTimestamp <= 0) {
        self.manualScrollLastTimestamp = displayLink.timestamp;
        return;
    }

    CFTimeInterval deltaTime = displayLink.timestamp - self.manualScrollLastTimestamp;
    self.manualScrollLastTimestamp = displayLink.timestamp;

    CGPoint step = CGPointMake(self.manualScrollVelocity.x * deltaTime, self.manualScrollVelocity.y * deltaTime);
    BOOL didMove = [self applyManualScrollDelta:step allowInnerScroll:NO];

    CGFloat decay = pow(0.92, deltaTime * 60.0);
    self.manualScrollVelocity = CGPointMake(self.manualScrollVelocity.x * decay, self.manualScrollVelocity.y * decay);

    if (!didMove ||
        (fabs(self.manualScrollVelocity.x) < 10.0 && fabs(self.manualScrollVelocity.y) < 10.0)) {
        [self stopManualScrollInertia];
        [self.host browserRemoteInputControllerPersistSession];
    }
}

- (void)handleGlobalSelectPressEndedNotification {
    if ([self.host browserRemoteInputControllerPresentedViewController] != nil) {
        return;
    }

    if ([self.host browserRemoteInputControllerTopBarFocusActive]) {
        return;
    }

    if ((CACurrentMediaTime() - self.lastDirectSelectPressTimestamp) < 0.15) {
        return;
    }

    [self handleSelectPressEnded];
}

- (void)handleDeferredSelectPressAction {
    if (!self.awaitingSecondSelectPress) {
        return;
    }

    self.awaitingSecondSelectPress = NO;
    self.lastTouchLocation = CGPointMake(-1, -1);

    if ([self.host browserRemoteInputControllerPresentedViewController] != nil) {
        return;
    }

    if ([self.host browserRemoteInputControllerTabOverviewVisible]) {
        [self.host browserRemoteInputControllerHandleTabOverviewSelectionAtPoint:self.cursorView.frame.origin];
        return;
    }

    if ([self.host browserRemoteInputControllerPseudoFullscreenActive]) {
        // Fullscreen Select is handled synchronously in handlePressesEnded. Running a deferred
        // page action here would toggle playback a second time 0.46 s later.
        return;
    }

    // build-23: a single Select over an episode list pins that list for the arrows, and a single
    // Select anywhere else unpins it. This runs here rather than on press-down so it shares the
    // double-Select discriminator: a fast second press still switches scroll mode instead of
    // pinning, and the user keeps the old gesture as a fallback.
    [self updateScrollPinForSelectPress];

    if ([self.host browserRemoteInputControllerTogglePlaybackAtCursorPoint]) {
        return;
    }

    [self.host browserRemoteInputControllerHandlePrimaryAction];
}

- (void)handleSelectPressEnded {
    CFTimeInterval now = CACurrentMediaTime();
    // build-16: widen the double-Select window and, crucially, keep the deferred single-tap
    // action scheduled AFTER the window so it can never consume the second press first.
    if (self.awaitingSecondSelectPress && (now - self.lastSelectPressTimestamp) < 0.42) {
        self.awaitingSecondSelectPress = NO;
        self.lastSelectPressTimestamp = now;
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(handleDeferredSelectPressAction) object:nil];
        if (![self.host browserRemoteInputControllerTabOverviewVisible]) {
            // build-23: a mode switch is a deliberate change of how the arrows behave, so it also
            // drops any pin. Leaving it armed would make the arrows page a list in a mode where the
            // user expects them to page the document.
            [self clearScrollPin];
            [self setCursorModeEnabled:!self.cursorModeEnabled];
        }
        return;
    }

    self.awaitingSecondSelectPress = YES;
    self.lastSelectPressTimestamp = now;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(handleDeferredSelectPressAction) object:nil];
    [self performSelector:@selector(handleDeferredSelectPressAction) withObject:nil afterDelay:0.46];
}

- (void)handlePlayPauseDoubleTap:(UITapGestureRecognizer *)sender {
    if (sender.state != UIGestureRecognizerStateEnded) {
        return;
    }
    if ([self.host browserRemoteInputControllerTopBarFocusActive]) {
        return;
    }
    if ([self.host browserRemoteInputControllerTabOverviewVisible]) {
        [self.host browserRemoteInputControllerDismissTabOverview];
        return;
    }
    [self.host browserRemoteInputControllerHandleAdvancedMenuPress];
}

// Long press Play/Pause or Select (pseudo fullscreen) is detected in the UIApplication sendEvent:
// bridge: GCEventViewController hands those buttons to the GameController framework, so no
// UILongPressGestureRecognizer ever fires for them. The bridge posts
// BrowserGlobalLongPressNotification, routed to here.
// Select is accepted because remotes without a Play/Pause key (learning remotes) otherwise have no
// way to reach fullscreen at all; that was reported on device.
- (void)handleGlobalLongPressType:(UIPressType)type {
    if ([self.host browserRemoteInputControllerTopBarFocusActive]) {
        NSLog(@"[LongPress] ignored type=%@ (top bar focused)", BrowserPressTypeString(type));
        return;
    }
    if ([self.host browserRemoteInputControllerTabOverviewVisible]) {
        NSLog(@"[LongPress] ignored type=%@ (tab overview visible)", BrowserPressTypeString(type));
        return;
    }
    if ([self.host browserRemoteInputControllerPresentedViewController] != nil) {
        NSLog(@"[LongPress] ignored type=%@ (alert presented)", BrowserPressTypeString(type));
        return;
    }

    if (type == UIPressTypePlayPause || type == UIPressTypeSelect) {
        NSLog(@"[LongPress] %@ -> pseudo fullscreen", BrowserPressTypeString(type));
        if (type == UIPressTypePlayPause) {
            self.playPauseLongPressConsumed = YES;
        } else {
            self.selectLongPressConsumed = YES;
            self.lastSelectLongPressTimestamp = CACurrentMediaTime();
        }
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(clearLongPressConsumedFlags) object:nil];
        [self performSelector:@selector(clearLongPressConsumedFlags) withObject:nil afterDelay:2.5];
        [self.host browserRemoteInputControllerHandlePseudoFullscreenPress];
        return;
    }

    // No Menu branch here on purpose: long-pressing Menu is the tvOS home gesture, so the bridge
    // never posts it. Favorites lives in the top bar and opens on launch.
}

- (void)clearLongPressConsumedFlags {
    self.playPauseLongPressConsumed = NO;
    self.selectLongPressConsumed = NO;
}

- (void)handleManualScrollPan:(UIPanGestureRecognizer *)gestureRecognizer {
    if (self.cursorModeEnabled ||
        [self.host browserRemoteInputControllerTabOverviewVisible] ||
        [self.host browserRemoteInputControllerTopBarFocusActive]) {
        return;
    }

    if (gestureRecognizer.state == UIGestureRecognizerStateBegan) {
        [self stopManualScrollInertia];
    }

    CGPoint translation = [gestureRecognizer translationInView:self.rootView];
    if (!CGPointEqualToPoint(translation, CGPointZero)) {
        [self applyManualScrollDelta:CGPointMake(-translation.x, -translation.y) allowInnerScroll:NO];
        [gestureRecognizer setTranslation:CGPointZero inView:self.rootView];
        self.manualScrollLastMovementTimestamp = CACurrentMediaTime();
    }

    if (gestureRecognizer.state == UIGestureRecognizerStateEnded) {
        CFTimeInterval timeSinceLastMovement = CACurrentMediaTime() - self.manualScrollLastMovementTimestamp;
        CGPoint velocity = [gestureRecognizer velocityInView:self.rootView];
        if (timeSinceLastMovement < 0.08) {
            [self startManualScrollInertiaWithVelocity:CGPointMake(-velocity.x, -velocity.y)];
        } else {
            [self stopManualScrollInertia];
        }
        [self.host browserRemoteInputControllerPersistSession];
    } else if (gestureRecognizer.state == UIGestureRecognizerStateCancelled ||
               gestureRecognizer.state == UIGestureRecognizerStateFailed) {
        [self stopManualScrollInertia];
        [self.host browserRemoteInputControllerPersistSession];
    }
}

- (void)handlePressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    UIPress *press = presses.anyObject;
    if (press != nil && (press.type == UIPressTypeMenu || press.type == UIPressTypePlayPause || press.type == UIPressTypeSelect)) {
        NSLog(@"[InputTrace][Root] pressesBegan type=%@ phase=%@ presented=%@",
              BrowserPressTypeString(press.type),
              BrowserPressPhaseString(press.phase),
              [self.host browserRemoteInputControllerPresentedViewController] == nil ? @"(nil)" : NSStringFromClass([[self.host browserRemoteInputControllerPresentedViewController] class]));
    }
    if (press != nil && [self isArrowPressType:press.type]) {
        [self handleArrowPressBegan:press.type];
    }
    (void)event;
}

#pragma mark - Arrow-key cursor movement

// Single-tap precision matters most for tiny controls: a close "x" can be a 12-16 px glyph inside
// a div, so 8 pt still skipped over it.
//
// build-24: 4 pt was still reported as "单次移动的距离还是有点大". The number looked small next to a
// 1920-wide screen on paper, but the pointer is drawn at 64 pt and its origin is what moves, so the
// *visual* jump is the full step plus the cursor footprint -- and on a page that overflows
// horizontally the layout width is wider than the screen, which multiplies every step further.
// 2 pt also pairs better with the 14 px click-assist ring: the ring covers about seven arrow taps
// in every direction, so a deliberate row of taps still lands on a small control without the taps
// themselves having to be coarse. The ramp is untouched -- a hold still opens up immediately.
static CGFloat const kBrowserCursorArrowStep = 1.0;
// Holding an arrow ramps the step quickly: the old ramp needed 4 repeats (~0.24 s) for 20 pt and
// 12 (~0.72 s) for 48 pt, which felt like a crawl next to scroll mode's 44 pt.
// build-26: the single-tap step is now 1 pt, but the ramp must not open a gap that makes a held
// press feel like a different control. build-24's lesson still holds -- entry 0 has to track the
// tap step, otherwise the first repeat tick silently doubles it and every press slightly longer
// than a tap moves at the old, coarser rate. Entry 0 therefore follows kBrowserCursorArrowStep,
// and entry 1 drops from 24 to 16 so the jump from tap to hold is one gentle step, not 24x.
static CGFloat const kBrowserCursorArrowStepRamp[4] = {1.0, 16.0, 44.0, 88.0};
// build-23: repeat counter values at which each ramp entry above kicks in. The first entry must sit
// ABOVE 1, not at 1. The timer increments the counter before it looks the step up, so the very
// first tick is already repeatCount == 1 -- with a threshold of 1 the second tick jumped straight
// to the next ramp entry, and any press slightly longer than a tap moved many times further than a
// tap should. Users noticed exactly that: "单按时光标移动跨度变大了".
// build-27: the counter now counts REAL repeats, because the tick that used to duplicate the
// press-down move is swallowed. With that off-by-one gone the thresholds can be stated in plain
// terms: 1 = the first genuine repeat, so a hold stays at the tap step for the first beat and only
// then accelerates. Reaching the top entry takes ~0.28 s of holding.
static NSInteger const kBrowserCursorArrowRampThresholds[3] = {1, 6, 16};
static NSTimeInterval const kBrowserCursorArrowRepeatInterval = 0.055;
static NSInteger const kBrowserCursorArrowMaxRepeats = 120;
// Scroll mode reuses the same timer but measures travel in page content, so its steps are larger.
static CGFloat const kBrowserScrollArrowStep = 44.0;
static CGFloat const kBrowserScrollArrowStepRamp[4] = {44.0, 80.0, 140.0, 220.0};
// build-16: holding an arrow in cursor mode scrolls the page once the pointer reaches the screen
// edge, so paging down no longer depends on the (unreliable) double-Select mode switch.
// build-22: the steps were far too big. On a 1080-tall screen 160 pt is already 15% of the page and
// the ramp went to 700 pt -- most of a screenful per tick -- so the content flew past the point the
// user was tracking and nothing lined up any more ("翻得太多，接不上了"). Each tick now moves a
// small slice, and the ramp climbs gently: a slow approach can still read what went by, while a
// deliberate hold still covers ground.
static CGFloat const kBrowserEdgeScrollStep = 72.0;
static CGFloat const kBrowserEdgeScrollStepRamp[4] = {72.0, 120.0, 180.0, 240.0};
// build-22: after the page scrolls under a pinned pointer, the pointer is pulled back off the edge
// by this fraction of the distance the content travelled, so the two move together instead of the
// content sliding away underneath a stationary pointer. Below 1 so the pointer trails the content.
static CGFloat const kBrowserEdgeScrollCursorFollowRatio = 0.55;

- (BOOL)isArrowPressType:(UIPressType)type {
    return type == UIPressTypeUpArrow ||
           type == UIPressTypeDownArrow ||
           type == UIPressTypeLeftArrow ||
           type == UIPressTypeRightArrow;
}

- (BOOL)canUseArrowsForMovement {
    // Fullscreen arrows are playback controls. In scroll mode the same arrows scroll the page, so
    // cursorModeEnabled is deliberately NOT checked here: checking it used to make the arrows do
    // nothing at all after switching to scroll mode.
    if ([self.host browserRemoteInputControllerPseudoFullscreenActive]) {
        return NO;
    }
    if ([self.host browserRemoteInputControllerPresentedViewController] != nil) {
        return NO;
    }
    if ([self.host browserRemoteInputControllerTopBarFocusActive]) {
        return NO;
    }
    if ([self.host browserRemoteInputControllerTabOverviewVisible]) {
        return NO;
    }
    return YES;
}

- (BOOL)moveCursorWithPressType:(UIPressType)type {
    return [self moveCursorWithPressType:type step:kBrowserCursorArrowStep];
}

- (BOOL)moveCursorWithPressType:(UIPressType)type step:(CGFloat)step {
    CGRect bounds = self.rootView.bounds;
    CGRect rect = self.cursorView.frame;

    switch (type) {
        case UIPressTypeUpArrow:
            rect.origin.y -= step;
            break;
        case UIPressTypeDownArrow:
            rect.origin.y += step;
            break;
        case UIPressTypeLeftArrow:
            rect.origin.x -= step;
            break;
        case UIPressTypeRightArrow:
            rect.origin.x += step;
            break;
        default:
            return NO;
    }

    CGFloat maxX = MAX(0.0, CGRectGetWidth(bounds) - CGRectGetWidth(rect));
    CGFloat maxY = MAX(0.0, CGRectGetHeight(bounds) - CGRectGetHeight(rect));
    rect.origin.x = MIN(MAX(rect.origin.x, 0.0), maxX);
    rect.origin.y = MIN(MAX(rect.origin.y, 0.0), maxY);
    if (CGRectEqualToRect(rect, self.cursorView.frame)) {
        return NO;
    }
    self.cursorView.frame = rect;
    return YES;
}

- (CGPoint)scrollDeltaForPressType:(UIPressType)type step:(CGFloat)step {
    switch (type) {
        case UIPressTypeUpArrow:    return CGPointMake(0.0, -step);
        case UIPressTypeDownArrow:  return CGPointMake(0.0,  step);
        case UIPressTypeLeftArrow:  return CGPointMake(-step, 0.0);
        case UIPressTypeRightArrow: return CGPointMake( step, 0.0);
        default: return CGPointZero;
    }
}

- (CGFloat)edgeScrollStepForRepeatCount:(NSInteger)repeatCount {
    CGFloat step = kBrowserEdgeScrollStep;
    for (NSInteger i = 0; i < 3; i++) {
        if (repeatCount > kBrowserCursorArrowRampThresholds[i]) {
            step = kBrowserEdgeScrollStepRamp[i + 1];
        }
    }
    return step;
}

// build-16: cursor mode, long press only. Once the pointer is pinned at the screen edge, keep the
// same direction scrolling the page instead of doing nothing. A single tap never scrolls, so
// aiming at a control near the edge cannot be spoiled by an accidental page jump.
//
// build-22: "翻得太快，接不上" had a structural cause, not just large numbers. The pointer stops at
// the edge and stays there, so every subsequent tick scrolled the page again with the pointer
// pinned -- the content kept sliding out from under the thing being aimed at, and there was no
// way to follow it. After a page is scrolled, the pointer is pulled back from the edge by a
// fraction of the distance the content just travelled. The content and the pointer now move
// together, which is what makes the motion readable.
- (BOOL)scrollPageAtCursorEdgeForPressType:(UIPressType)type repeatCount:(NSInteger)repeatCount {
    if (![self isArrowPressType:type]) {
        return NO;
    }
    CGFloat step = [self edgeScrollStepForRepeatCount:repeatCount];
    BOOL didScroll = [self applyManualScrollDelta:[self scrollDeltaForPressType:type step:step]
                                  allowInnerScroll:YES];
    if (didScroll) {
        [self pullCursorBackFromEdgeForPressType:type step:step];
    }
    return didScroll;
}

// Moves the pointer back off the edge so it rides along with the content that just scrolled.
// The factor is below 1 on purpose: the pointer should trail the content slightly, not be dragged
// across the screen, or the user loses the aim they just established.
- (void)pullCursorBackFromEdgeForPressType:(UIPressType)type step:(CGFloat)step {
    CGFloat follow = step * kBrowserEdgeScrollCursorFollowRatio;
    CGRect bounds = self.rootView.bounds;
    CGRect rect = self.cursorView.frame;
    switch (type) {
        case UIPressTypeUpArrow:    rect.origin.y += follow; break;
        case UIPressTypeDownArrow:  rect.origin.y -= follow; break;
        case UIPressTypeLeftArrow:  rect.origin.x += follow; break;
        case UIPressTypeRightArrow: rect.origin.x -= follow; break;
        default: return;
    }
    CGFloat maxX = MAX(0.0, CGRectGetWidth(bounds) - CGRectGetWidth(rect));
    CGFloat maxY = MAX(0.0, CGRectGetHeight(bounds) - CGRectGetHeight(rect));
    rect.origin.x = MIN(MAX(rect.origin.x, 0.0), maxX);
    rect.origin.y = MIN(MAX(rect.origin.y, 0.0), maxY);
    self.cursorView.frame = rect;
}

- (void)updateCursorImageForCurrentPosition {
    self.cursorView.image = BrowserDefaultCursor();
    if ([self.host browserRemoteInputControllerTabOverviewVisible] &&
        [self.host browserRemoteInputControllerTabOverviewContainsPoint:self.cursorView.frame.origin]) {
        self.cursorView.image = BrowserPointerCursor();
        return;
    }

    NSString *hoverState = [self.host browserRemoteInputControllerHoverStateAtCursorPoint:self.cursorView.frame.origin];
    if ([hoverState isEqualToString:@"true"]) {
        self.cursorView.image = BrowserPointerCursor();
    }
}

- (void)beginCursorArrowRepeatWithPressType:(UIPressType)type {
    [self cancelCursorArrowRepeat];

    if (![self canUseArrowsForMovement]) {
        return;
    }

    self.cursorArrowRepeatPressType = type;
    if (self.cursorModeEnabled) {
        [self moveCursorWithPressType:type];
    } else {
        [self applyManualScrollDelta:[self scrollDeltaForPressType:type step:kBrowserScrollArrowStep] allowInnerScroll:YES];
    }

    // build-27: THE reason "缩小步长" never helped. This method already moves the cursor once, on the
    // press-down. The repeat timer then fires 55 ms later with repeatCount == 1 and moves AGAIN -- the
    // ramp only kicks in above threshold[0], so that second move is another full base step. A plain
    // tap therefore travelled exactly 2 x the step, which is why trimming the constant from 4 to 2 to
    // 1 pt never changed the felt distance: the user was always seeing two of them.
    //
    // `movedOnBegin` makes the first timer tick a no-op. From the second tick on, every tick is a real
    // repeat and the ramp applies. Short taps now cost one step; a hold still accelerates.
    __block BOOL movedOnBegin = YES;
    __block NSInteger repeatCount = 0;
    __weak typeof(self) weakSelf = self;
    self.cursorArrowRepeatTimer = [NSTimer scheduledTimerWithTimeInterval:kBrowserCursorArrowRepeatInterval
                                                                  repeats:YES
                                                                    block:^(NSTimer *timer) {
        (void)timer;
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        // build-22: these two conditions must NOT share one branch. The old code read
        //     if (!canUseArrowsForMovement || ++repeatCount > MAX) { cancel; return; }
        // and because || short-circuits, the counter was not even incremented when the first
        // condition was true -- but the timer was still cancelled and cursorArrowRepeatPressType
        // was still wiped. canUseArrowsForMovement flips to NO for a moment whenever an alert is
        // presented, the top bar takes focus, the tab overview opens, or pseudo fullscreen engages,
        // and a double-Select mode switch is exactly that kind of moment. The result was a dead
        // repeat timer for a button that was still physically held: from then on the arrow only
        // moved the cursor 4 pt per press, which is precisely the reported "very slow, only one
        // press at a time".
        //
        // Now a blocked tick simply does nothing and keeps the press alive; only the repeat ceiling
        // ends it. If the button is released while blocked, handleArrowPressEnded: still clears the
        // state, so nothing is left running.
        if (![strongSelf canUseArrowsForMovement]) {
            return;
        }
        // build-27: swallow the first tick -- beginCursorArrowRepeatWithPressType: already moved.
        if (movedOnBegin) {
            movedOnBegin = NO;
            return;
        }
        if (++repeatCount > kBrowserCursorArrowMaxRepeats) {
            [strongSelf cancelCursorArrowRepeat];
            return;
        }
        // Ramp the step up while held: precise at first, fast once it is clearly a hold.
        NSInteger i;
        if (strongSelf.cursorModeEnabled) {
            CGFloat step = kBrowserCursorArrowStep;
            for (i = 0; i < 3; i++) {
                if (repeatCount > kBrowserCursorArrowRampThresholds[i]) {
                    step = kBrowserCursorArrowStepRamp[i + 1];
                }
            }
            // build-23: a pinned episode list takes the arrows first. Without this the pointer had
            // to be walked onto the list for every single scroll, and paging a list therefore meant
            // switching to scroll mode by double Select -- which is what the user asked to avoid.
            // Only the vertical arrows are claimed by the pin: horizontal arrows still move the
            // cursor, because a list is paged top to bottom and the pointer must stay aimable.
            if (strongSelf.scrollPinActive &&
                (strongSelf.cursorArrowRepeatPressType == UIPressTypeDownArrow ||
                 strongSelf.cursorArrowRepeatPressType == UIPressTypeUpArrow)) {
                CGPoint pinnedDelta = [strongSelf scrollDeltaForPressType:strongSelf.cursorArrowRepeatPressType
                                                                    step:step];
                // Consume the press either way while the pin is armed. The first version fell
                // through to edge paging when the list could not move, so once the episode list
                // reached its end the whole document started paging under it -- the user reported
                // exactly that. A pinned list that has hit its end should simply stop; clicking
                // outside the list is what gives the arrows back to the page.
                [strongSelf.host browserRemoteInputControllerScrollPinnedRegionByDelta:pinnedDelta];
                return;
            }
            // build-20: page only once the pointer has actually reached an edge of the page (or of
            // the inner list under it) -- that is what moveCursor returns NO for. An earlier build
            // also started paging merely because the key had been held long enough, while the
            // pointer was still mid-screen; that made it impossible to aim at a target, because the
            // page scrolled out from under the cursor while you were moving it there. Holding the
            // key still only moves the cursor across the screen, and keeps moving it after paging
            // starts so the pointer rides along with the content.
            BOOL didMoveCursor = [strongSelf moveCursorWithPressType:strongSelf.cursorArrowRepeatPressType step:step];
            if (!didMoveCursor) {
                [strongSelf scrollPageAtCursorEdgeForPressType:strongSelf.cursorArrowRepeatPressType
                                                  repeatCount:repeatCount];
            }
        } else {
            CGFloat step = kBrowserScrollArrowStep;
            for (i = 0; i < 3; i++) {
                if (repeatCount > kBrowserCursorArrowRampThresholds[i]) {
                    step = kBrowserScrollArrowStepRamp[i + 1];
                }
            }
            [strongSelf applyManualScrollDelta:[strongSelf scrollDeltaForPressType:strongSelf.cursorArrowRepeatPressType
                                                                              step:step]
                             allowInnerScroll:YES];
        }
    }];
}

- (void)cancelCursorArrowRepeat {
    BOOL hadRepeatTimer = (self.cursorArrowRepeatTimer != nil);
    [self.cursorArrowRepeatTimer invalidate];
    self.cursorArrowRepeatTimer = nil;
    // build-22: the press type is NOT cleared here. Duplicate begins arrive on a later run loop
    // turn; if this method also wiped the type, the duplicate could not be told apart from a fresh
    // press and would restart the ramp. handleArrowPressEnded: clears it when the press really ends.
    if (hadRepeatTimer) {
        [self updateCursorImageForCurrentPosition];
        [self.host browserRemoteInputControllerPersistSession];
    }
}

#pragma mark - Scroll region pin (build-23)

// Drops the pin on both sides: the flag here and the marker in the page. Both must go, or the page
// keeps a stale marker that the next activation would have to clear anyway.
//
// build-25: the page side was never actually cleared -- the comment promised it and the code only
// flipped the flag. A stale marker matters because overscroll-behavior:contain is still applied to
// that element, so an abandoned pin keeps changing how the page scrolls even after the arrows have
// been given back.
- (void)clearScrollPin {
    if (!self.scrollPinActive) {
        return;
    }
    self.scrollPinActive = NO;
    [self.host browserRemoteInputControllerClearScrollPin];
    NSLog(@"[ScrollPin] cleared");
}

// Called once per Select press, before the press is turned into a page action. A press that lands
// in a scrollable region pins it; a press anywhere else clears the pin, which is exactly the
// "click outside the list and it stops responding to the arrows" behaviour that was asked for.
//
// build-25: three outcomes now, not two. The engine answers 'click' when the thing under the
// pointer is itself clickable (an episode tile, a play button). That must NOT pin: clicking episode
// 7 is a request to play episode 7, and the page navigates away immediately, leaving the pin
// pointing at a list the user has already left -- the reported "点了他，必须返回取消标记才能继续
// 移动光标". 'click' therefore means "hands off": keep whatever pin state exists, because the press
// is a navigation, not a statement about the arrows.
- (void)updateScrollPinForSelectPress {
    // Only meaningful in cursor mode. In scroll mode the arrows already page the document, so a
    // pin would change what the arrows do without the user having asked for it.
    if (!self.cursorModeEnabled) {
        return;
    }
    NSString *token = [self.host browserRemoteInputControllerActivateScrollRegionAtCursorPoint];
    if ([token isEqualToString:@"click"]) {
        NSLog(@"[ScrollPin] Select landed on a clickable target; pin left as it was");
        return;
    }
    self.scrollPinActive = (token.length > 0);
    if (self.scrollPinActive) {
        NSLog(@"[ScrollPin] armed by Select; arrows now page the list under the cursor");
    }
}

- (void)handleArrowPressBegan:(UIPressType)type {
    if (![self canUseArrowsForMovement]) {
        NSLog(@"[InputTrace][Root] arrow began type=%@ IGNORED (arrows not usable)",
              BrowserPressTypeString(type));
        return;
    }
    // build-22: this method is reached TWICE for one physical press -- once synchronously through
    // pressesBegan: and once asynchronously through the sendEvent: bridge, which republishes the
    // press on the next run loop turn. The old guard compared the repeat timer's press type, which
    // is not enough: beginCursorArrowRepeatWithPressType: starts by calling cancelCursorArrowRepeat,
    // and that resets the press type to -1. A late duplicate therefore never matched, cancelled the
    // timer the first call had just started, and started a fresh one -- so the repeat counter went
    // back to 0 and the ramp never advanced. The visible symptom was exactly what was reported: one
    // press moves the cursor a tiny bit, holding it barely moves at all, because the hold kept
    // being restarted (and, at release, degenerated into a single 4 pt step).
    //
    // A press token is what makes this idempotent: the token is set when a press begins and cleared
    // when it ends, so a duplicate begin for the same type is a no-op regardless of timer state.
    if (self.arrowPressActive && self.cursorArrowRepeatPressType == type) {
        NSLog(@"[InputTrace][Root] arrow began type=%@ IGNORED (duplicate of the active press)",
              BrowserPressTypeString(type));
        return;
    }
    // The bridge republishes on the next run loop turn, so a very short tap can deliver its Begin
    // AFTER its End. Starting a repeat timer at that point would move the cursor with no key held.
    // A begin that arrives within the duplicate-end window of the same type is that late Begin.
    if (self.lastArrowEndedType == type &&
        (CACurrentMediaTime() - self.lastArrowEndedTimestamp) < 0.05) {
        NSLog(@"[InputTrace][Root] arrow began type=%@ IGNORED (arrived after its own end)",
              BrowserPressTypeString(type));
        return;
    }
    self.arrowPressActive = YES;
    NSLog(@"[InputTrace][Root] arrow began type=%@ cursor=(%.0f,%.0f) mode=%@",
          BrowserPressTypeString(type),
          self.cursorView.frame.origin.x,
          self.cursorView.frame.origin.y,
          self.cursorModeEnabled ? @"cursor" : @"scroll");
    [self beginCursorArrowRepeatWithPressType:type];
}

// Entry point used by the UIApplication sendEvent: bridge. tvOS routes arrow presses to the
// focus engine first, so pressesBegan: alone is not a reliable source for them.
// In pseudo fullscreen the horizontal arrows become seek controls and vertical arrows reveal /
// hide the playback HUD, so the same remote drives playback instead of the cursor.
- (void)handleGlobalArrowPressType:(UIPressType)type began:(BOOL)began {
    if (![self isArrowPressType:type]) {
        return;
    }

    if ([self.host browserRemoteInputControllerPseudoFullscreenActive]) {
        [self handlePseudoFullscreenArrowPressType:type began:began];
        return;
    }

    if (began) {
        [self handleArrowPressBegan:type];
    } else {
        [self handleArrowPressEnded:type];
    }
}

- (void)handlePseudoFullscreenArrowPressType:(UIPressType)type began:(BOOL)began {
    switch (type) {
        case UIPressTypeLeftArrow:
            [self handleFullscreenSeekPressWithDirection:-1.0 began:began];
            return;
        case UIPressTypeRightArrow:
            [self handleFullscreenSeekPressWithDirection:1.0 began:began];
            return;
        case UIPressTypeUpArrow:
        case UIPressTypeDownArrow:
            // Show/hide the timecode HUD; only on press-down so a hold does not flicker.
            if (began) {
                NSLog(@"[InputTrace][Root] fullscreen %@ -> toggle playback HUD", BrowserPressTypeString(type));
                [self.host browserRemoteInputControllerTogglePlaybackHUD];
            }
            return;
        default:
            return;
    }
}

// Tiered seek, exactly as requested: 1 tap = 10 s, 2 taps = 1 min, 3 taps = 5 min.
// The step is applied on release and grows by the difference to the previous tier, so the first tap
// gives immediate feedback instead of waiting for the tap window to close:
//   tap 1 -> +10 s, tap 2 -> +50 s more (total 1 min), tap 3 -> +240 s more (total 5 min).
// Holding the key keeps the old continuous seek, which starts after kBrowserSeekHoldThreshold.
static double const kBrowserSeekTiers[4] = {0.0, 10.0, 60.0, 300.0};
static CFTimeInterval const kBrowserSeekTapWindow = 0.6;
static CFTimeInterval const kBrowserSeekHoldThreshold = 0.45;

- (void)handleFullscreenSeekPressWithDirection:(double)direction began:(BOOL)began {
    if (began) {
        // A press in the opposite direction starts a fresh series instead of extending it.
        if (self.seekTapDirection != 0.0 && self.seekTapDirection != direction) {
            [self resetSeekTapSeries];
        }
        self.seekTapDirection = direction;
        self.seekPressBeganTimestamp = CACurrentMediaTime();

        __weak typeof(self) weakSelf = self;
        CFTimeInterval beganAt = self.seekPressBeganTimestamp;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kBrowserSeekHoldThreshold * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }
            // Still down, same press, same direction: this is a hold, not a tap.
            if (beganAt <= 0.0 || strongSelf.seekPressBeganTimestamp != beganAt) {
                return;
            }
            if (strongSelf.seekTapDirection != direction) {
                return;
            }
            NSLog(@"[InputTrace][Root] fullscreen seek hold direction=%.0f", direction);
            strongSelf.seekHoldActive = YES;
            strongSelf.seekTapCount = 0;
            [strongSelf.host browserRemoteInputControllerSeekBySeconds:(direction * kBrowserSeekTiers[1])
                                                                 began:YES];
        });
        return;
    }

    if (self.seekPressBeganTimestamp <= 0.0) {
        return;
    }
    self.seekPressBeganTimestamp = 0.0;

    if (self.seekHoldActive) {
        self.seekHoldActive = NO;
        [self resetSeekTapSeries];
        [self.host browserRemoteInputControllerSeekBySeconds:0.0 began:NO];
        return;
    }

    self.seekTapCount += 1;
    if (self.seekTapCount > 3) {
        // A fourth quick tap starts a new series rather than silently capping at 5 minutes.
        self.seekTapCount = 1;
    }

    NSInteger count = self.seekTapCount;
    double cumulative = kBrowserSeekTiers[count];
    double previous = kBrowserSeekTiers[count - 1];
    double increment = cumulative - previous;

    NSLog(@"[InputTrace][Root] fullscreen seek taps=%ld increment=%.0f cumulative=%.0f",
          (long)count, increment, cumulative);
    [self.host browserRemoteInputControllerApplySeekDelta:(direction * increment)
                                         displayedSeconds:cumulative
                                                 tapCount:count];

    // Restart the window: another tap this soon extends the series, otherwise it ends here.
    [self.seekTapWindowTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.seekTapWindowTimer = [NSTimer scheduledTimerWithTimeInterval:kBrowserSeekTapWindow
                                                              repeats:NO
                                                                block:^(NSTimer *timer) {
        (void)timer;
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        [strongSelf resetSeekTapSeries];
    }];
}

- (void)resetSeekTapSeries {
    [self.seekTapWindowTimer invalidate];
    self.seekTapWindowTimer = nil;
    self.seekTapCount = 0;
    self.seekTapDirection = 0.0;
    self.seekPressBeganTimestamp = 0.0;
    self.seekHoldActive = NO;
}

- (void)resetPseudoFullscreenSeekState {
    [self resetSeekTapSeries];
}

- (BOOL)handleArrowPressEnded:(UIPressType)type {
    if (![self canUseArrowsForMovement]) {
        self.arrowPressActive = NO;
        [self cancelCursorArrowRepeat];
        return NO;
    }

    // Both the native press channel and the sendEvent: bridge report this; drop the duplicate.
    CFTimeInterval now = CACurrentMediaTime();
    if (self.lastArrowEndedType == type && (now - self.lastArrowEndedTimestamp) < 0.05) {
        NSLog(@"[InputTrace][Root] arrow ended type=%@ IGNORED (duplicate within 50 ms)",
              BrowserPressTypeString(type));
        return YES;
    }
    self.lastArrowEndedType = type;
    self.lastArrowEndedTimestamp = now;

    // build-22: the repeat timer is NOT a reliable "did the begin phase run" signal, because the
    // duplicate-begin path can leave the timer replaced or already fired. arrowPressActive is set
    // by handleArrowPressBegan: and only cleared here, so it answers that question directly.
    BOOL hadBeganPhase = self.arrowPressActive;
    self.arrowPressActive = NO;
    self.cursorArrowRepeatPressType = (UIPressType)-1;
    [self cancelCursorArrowRepeat];
    BOOL didMove = YES;
    if (!hadBeganPhase) {
        // Began phase never reached pressesBegan: treat this as a single tap step.
        if (self.cursorModeEnabled) {
            didMove = [self moveCursorWithPressType:type];
            [self updateCursorImageForCurrentPosition];
        } else {
            didMove = [self applyManualScrollDelta:[self scrollDeltaForPressType:type
                                                                            step:kBrowserScrollArrowStep]
                              allowInnerScroll:YES];
        }
        [self.host browserRemoteInputControllerPersistSession];
    }

    NSLog(@"[InputTrace][Root] arrow ended type=%@ cursor=(%.0f,%.0f) moved=%@ began=%@",
          BrowserPressTypeString(type),
          self.cursorView.frame.origin.x,
          self.cursorView.frame.origin.y,
          didMove ? @"YES" : @"NO",
          hadBeganPhase ? @"YES" : @"NO");

    // The cursor already sits at the top edge and Up cannot move it any further:
    // hand that edge case back to the top navigation bar so its old shortcut still works.
    if (type == UIPressTypeUpArrow &&
        !didMove &&
        CGRectGetMinY(self.cursorView.frame) <= 0.5 &&
        [self.host browserRemoteInputControllerCanActivateTopBarFocus]) {
        NSLog(@"[InputTrace][Root] Up at top edge -> activate top bar focus");
        [self.host browserRemoteInputControllerActivateTopBarFocus];
    }
    return YES;
}

- (BOOL)handlePressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    (void)event;
    UIPress *press = presses.anyObject;
    if (press == nil) {
        return NO;
    }

    // A long press already ran its action; the release must not also fire the single-tap action
    // (that would pop the alert we just presented, or open the URL entry sheet).
    if (press.type == UIPressTypePlayPause && self.playPauseLongPressConsumed) {
        self.playPauseLongPressConsumed = NO;
        NSLog(@"[InputTrace][Root] swallow PlayPause release after long press");
        return YES;
    }

    // Select held down = fullscreen. Swallowing the release is what stops the click from also
    // happening (and, in fullscreen, from immediately re-toggling the HUD).
    if (press.type == UIPressTypeSelect && self.selectLongPressConsumed) {
        self.selectLongPressConsumed = NO;
        NSLog(@"[InputTrace][Root] swallow Select release after long press");
        return YES;
    }

    if ([self isArrowPressType:press.type]) {
        if ([self.host browserRemoteInputControllerPseudoFullscreenActive]) {
            // Already handled through the sendEvent: bridge (seek / HUD). Do not move the cursor.
            return YES;
        }
        if ([self handleArrowPressEnded:press.type]) {
            return YES;
        }
    }

    if (press.type == UIPressTypeMenu || press.type == UIPressTypePlayPause || press.type == UIPressTypeSelect) {
        NSLog(@"[InputTrace][Root] pressesEnded type=%@ phase=%@ presented=%@ tabOverview=%@",
              BrowserPressTypeString(press.type),
              BrowserPressPhaseString(press.phase),
              [self.host browserRemoteInputControllerPresentedViewController] == nil ? @"(nil)" : NSStringFromClass([[self.host browserRemoteInputControllerPresentedViewController] class]),
              [self.host browserRemoteInputControllerTabOverviewVisible] ? @"YES" : @"NO");
    }

    if ([self.host browserRemoteInputControllerTopBarFocusActive]) {
        if (press.type == UIPressTypeMenu || press.type == UIPressTypeDownArrow) {
            [self.host browserRemoteInputControllerDeactivateTopBarFocus];
            return YES;
        }
        if (press.type == UIPressTypePlayPause) {
            return YES;
        }
        if (press.type == UIPressTypeSelect ||
            press.type == UIPressTypeLeftArrow ||
            press.type == UIPressTypeRightArrow ||
            press.type == UIPressTypeUpArrow) {
            return NO;
        }
    }

    UIViewController *presentedViewController = [self.host browserRemoteInputControllerPresentedViewController];
    if (presentedViewController != nil && ![presentedViewController isKindOfClass:[UIAlertController class]]) {
        if ([self.host browserRemoteInputControllerTabOverviewVisible]) {
            if (press.type == UIPressTypeMenu) {
                [self.host browserRemoteInputControllerDismissTabOverview];
                return YES;
            }
            if (press.type == UIPressTypePlayPause) {
                [self.host browserRemoteInputControllerHandleTabOverviewAlternateAction];
                return YES;
            }
            return NO;
        }
        if (press.type == UIPressTypeMenu) {
            [presentedViewController dismissViewControllerAnimated:YES completion:nil];
            return YES;
        }
        return YES;
    }

    if (press.type == UIPressTypeSelect) {
        self.lastDirectSelectPressTimestamp = CACurrentMediaTime();
        if ([self.host browserRemoteInputControllerPseudoFullscreenActive]) {
            // Fullscreen: Select plays/pauses. Up/Down still reveal the timecode HUD.
            NSLog(@"[InputTrace][Root] fullscreen Select -> toggle playback");
            [self.host browserRemoteInputControllerTogglePlaybackPlayState];
            return YES;
        }
        [self handleSelectPressEnded];
        return YES;
    }

    if ([self.host browserRemoteInputControllerTabOverviewVisible]) {
        if (press.type == UIPressTypeMenu || press.type == UIPressTypePlayPause) {
            [self.host browserRemoteInputControllerDismissTabOverview];
            return YES;
        }
        if (press.type == UIPressTypeSelect) {
            [self.host browserRemoteInputControllerHandleTabOverviewSelectionAtPoint:self.cursorView.frame.origin];
            return YES;
        }
    }

    if (press.type == UIPressTypeMenu) {
        // build-24: a pinned list is a *mode* of the arrow keys, so the key that means "back out of
        // the current mode" is the one that should drop it. Without this the only way to give the
        // arrows back to the page was to aim at some specific spot outside the list and click, which
        // is a hit-testing problem the user should not have to solve. Menu now releases the pin and
        // is consumed on that press -- the same press still performs its usual back/exit action on
        // the NEXT press, so nothing is lost and nothing happens twice.
        if (self.scrollPinActive) {
            [self clearScrollPin];
            NSLog(@"[ScrollPin] released by Menu; arrows control the page again");
            return YES;
        }
        [self.host browserRemoteInputControllerHandleMenuPress];
        return YES;
    }
    if (press.type == UIPressTypePlayPause) {
        // In fullscreen a single Play/Pause press controls playback instead of opening the URL sheet.
        if ([self.host browserRemoteInputControllerPseudoFullscreenActive]) {
            NSLog(@"[InputTrace][Root] fullscreen PlayPause -> toggle playback");
            [self.host browserRemoteInputControllerTogglePlaybackPlayState];
            return YES;
        }
        // A learning remote's dedicated Play key sends this same press type. WebKit lets pause()
        // through but rejects play() without a user activation, so native code drives the resume in
        // every frame. Resume is a no-op while a video is already playing, which leaves the Pause
        // key's existing behaviour untouched. The event flow stays exactly as before (swallowed).
        BOOL hasVideo = [self.host browserRemoteInputControllerHandleRemotePlayRequest];
        NSLog(@"[InputTrace][Root] PlayPause -> resume playback hasVideo=%@", hasVideo ? @"YES" : @"NO");
        if (hasVideo) {
            return YES;
        }
        [self.host browserRemoteInputControllerHandlePlayPausePress];
        return YES;
    }
    return NO;
}

- (BOOL)handleTouchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)touches;
    (void)event;
    if ([self.host browserRemoteInputControllerTopBarFocusActive]) {
        return NO;
    }
    if ([self.host browserRemoteInputControllerTabOverviewVisible]) {
        return NO;
    }
    if (!self.cursorModeEnabled) {
        return NO;
    }
    self.lastTouchLocation = CGPointMake(-1, -1);
    return YES;
}

- (BOOL)handleTouchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    if ([self.host browserRemoteInputControllerTopBarFocusActive]) {
        return NO;
    }
    if ([self.host browserRemoteInputControllerTabOverviewVisible]) {
        return NO;
    }
    if (!self.cursorModeEnabled) {
        return NO;
    }

    for (UITouch *touch in touches) {
        UIScrollView *activeScrollView = [self.host browserRemoteInputControllerActiveScrollView];
        UIView *targetView = activeScrollView ?: self.rootView;
        CGPoint location = [touch locationInView:targetView];

        if (self.lastTouchLocation.x == -1 && self.lastTouchLocation.y == -1) {
            self.lastTouchLocation = location;
        } else {
            CGFloat xDiff = location.x - self.lastTouchLocation.x;
            CGFloat yDiff = location.y - self.lastTouchLocation.y;
            CGRect rect = self.cursorView.frame;

            if (rect.origin.x + xDiff >= 0 && rect.origin.x + xDiff <= 1920) {
                rect.origin.x += xDiff;
            }
            if (rect.origin.y + yDiff >= 0 && rect.origin.y + yDiff <= 1080) {
                rect.origin.y += yDiff;
            }
            self.cursorView.frame = rect;
            self.lastTouchLocation = location;
        }

        self.cursorView.image = BrowserDefaultCursor();
        if ([self.host browserRemoteInputControllerTabOverviewVisible]) {
            if ([self.host browserRemoteInputControllerTabOverviewContainsPoint:self.cursorView.frame.origin]) {
                self.cursorView.image = BrowserPointerCursor();
            }
            break;
        }
        if (self.cursorModeEnabled) {
            NSString *containsLink = [self.host browserRemoteInputControllerHoverStateAtCursorPoint:self.cursorView.frame.origin];
            if ([containsLink isEqualToString:@"true"]) {
                self.cursorView.image = BrowserPointerCursor();
            }
        }
        break;
    }

    return YES;
}

- (void)handleTouchesEnded {
    self.lastTouchLocation = CGPointMake(-1, -1);
}

@end
