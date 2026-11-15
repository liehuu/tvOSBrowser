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
    self.cursorView.hidden = !self.cursorModeEnabled ||
        [self.host browserRemoteInputControllerTabOverviewVisible] ||
        topBarFocusActive;
}

- (BOOL)applyManualScrollDelta:(CGPoint)delta {
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
    BOOL didMove = [self applyManualScrollDelta:step];

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

    [self.host browserRemoteInputControllerHandlePrimaryAction];
}

- (void)handleSelectPressEnded {
    CFTimeInterval now = CACurrentMediaTime();
    if (self.awaitingSecondSelectPress && (now - self.lastSelectPressTimestamp) < 0.35) {
        self.awaitingSecondSelectPress = NO;
        self.lastSelectPressTimestamp = now;
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(handleDeferredSelectPressAction) object:nil];
        if (![self.host browserRemoteInputControllerTabOverviewVisible]) {
            [self setCursorModeEnabled:!self.cursorModeEnabled];
        }
        return;
    }

    self.awaitingSecondSelectPress = YES;
    self.lastSelectPressTimestamp = now;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(handleDeferredSelectPressAction) object:nil];
    [self performSelector:@selector(handleDeferredSelectPressAction) withObject:nil afterDelay:0.3];
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
        [self applyManualScrollDelta:CGPointMake(-translation.x, -translation.y)];
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

// A tap must land on small targets, so the single-tap step is fine (was 48 pt on a 1920-wide
// screen: only 40 positions across, which made many links unreachable). Holding still has to cover
// the screen quickly, so the repeat step ramps up instead of the tap step being coarse.
static CGFloat const kBrowserCursorArrowStep = 16.0;
static CGFloat const kBrowserCursorArrowStepRamp[4] = {16.0, 28.0, 44.0, 64.0};
static NSInteger const kBrowserCursorArrowRampThresholds[3] = {10, 26, 48};
static NSTimeInterval const kBrowserCursorArrowRepeatInterval = 0.075;
static NSInteger const kBrowserCursorArrowMaxRepeats = 90;

- (BOOL)isArrowPressType:(UIPressType)type {
    return type == UIPressTypeUpArrow ||
           type == UIPressTypeDownArrow ||
           type == UIPressTypeLeftArrow ||
           type == UIPressTypeRightArrow;
}

- (BOOL)canMoveCursorWithArrows {
    if (!self.cursorModeEnabled) {
        return NO;
    }
    // In pseudo fullscreen the arrows are playback controls, not cursor controls.
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

    if (![self canMoveCursorWithArrows]) {
        return;
    }

    self.cursorArrowRepeatPressType = type;
    [self moveCursorWithPressType:type];

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
        if (![strongSelf canMoveCursorWithArrows] ||
            ++repeatCount > kBrowserCursorArrowMaxRepeats) {
            [strongSelf cancelCursorArrowRepeat];
            return;
        }
        // Ramp the step up while held: precise at first, fast once it is clearly a hold.
        CGFloat step = kBrowserCursorArrowStep;
        for (NSInteger i = 0; i < 3; i++) {
            if (repeatCount > kBrowserCursorArrowRampThresholds[i]) {
                step = kBrowserCursorArrowStepRamp[i + 1];
            }
        }
        [strongSelf moveCursorWithPressType:strongSelf.cursorArrowRepeatPressType step:step];
    }];
}

- (void)cancelCursorArrowRepeat {
    BOOL hadRepeatTimer = (self.cursorArrowRepeatTimer != nil);
    [self.cursorArrowRepeatTimer invalidate];
    self.cursorArrowRepeatTimer = nil;
    self.cursorArrowRepeatPressType = (UIPressType)-1;
    if (hadRepeatTimer) {
        [self updateCursorImageForCurrentPosition];
        [self.host browserRemoteInputControllerPersistSession];
    }
}

- (void)handleArrowPressBegan:(UIPressType)type {
    if (![self canMoveCursorWithArrows]) {
        return;
    }
    if (self.cursorArrowRepeatTimer != nil && self.cursorArrowRepeatPressType == type) {
        return;
    }
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
    if (![self canMoveCursorWithArrows]) {
        [self cancelCursorArrowRepeat];
        return NO;
    }

    // Both the native press channel and the sendEvent: bridge report this; drop the duplicate.
    CFTimeInterval now = CACurrentMediaTime();
    if (self.lastArrowEndedType == type && (now - self.lastArrowEndedTimestamp) < 0.05) {
        return YES;
    }
    self.lastArrowEndedType = type;
    self.lastArrowEndedTimestamp = now;

    BOOL hadRepeatTimer = (self.cursorArrowRepeatTimer != nil);
    [self cancelCursorArrowRepeat];
    BOOL didMove = YES;
    if (!hadRepeatTimer) {
        // Began phase never reached pressesBegan: treat this as a single tap step.
        didMove = [self moveCursorWithPressType:type];
        [self updateCursorImageForCurrentPosition];
        [self.host browserRemoteInputControllerPersistSession];
    }

    NSLog(@"[InputTrace][Root] arrow ended type=%@ cursor=(%.0f,%.0f) moved=%@",
          BrowserPressTypeString(type),
          self.cursorView.frame.origin.x,
          self.cursorView.frame.origin.y,
          didMove ? @"YES" : @"NO");

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
            // Fullscreen: a click reveals the playback HUD instead of clicking the page.
            NSLog(@"[InputTrace][Root] fullscreen Select -> toggle playback HUD");
            [self.host browserRemoteInputControllerTogglePlaybackHUD];
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
