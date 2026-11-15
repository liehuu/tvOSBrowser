#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>

NSString * const BrowserGlobalSelectPressEndedNotification = @"BrowserGlobalSelectPressEndedNotification";
NSString * const BrowserGlobalArrowPressNotification = @"BrowserGlobalArrowPressNotification";
NSString * const BrowserGlobalArrowPressTypeKey = @"type";
NSString * const BrowserGlobalArrowPressBeganKey = @"began";
NSString * const BrowserGlobalLongPressNotification = @"BrowserGlobalLongPressNotification";
NSString * const BrowserGlobalLongPressTypeKey = @"type";
static BOOL sBrowserNativeScrubTracking = NO;
static CGFloat sBrowserNativePendingScrubPixels = 0.0;
static CGPoint sBrowserNativeLastTouchLocation = {0, 0};
static CFTimeInterval sBrowserNativeLastArrowPressTimestamp = 0.0;
static UIPressType sBrowserNativeLastArrowPressType = (UIPressType)-1;
static CGFloat const kBrowserNativeScrubPixelStep = 18.0;
static CFTimeInterval const kBrowserNativeArrowDoubleTapInterval = 0.35;
static CFTimeInterval const kBrowserLongPressMinimumDuration = 0.55;
// Select is the ordinary click, so its hold threshold is longer: a slightly slow click on a link
// must not turn into fullscreen.
static CFTimeInterval const kBrowserSelectLongPressMinimumDuration = 0.85;

// Two slots: Play/Pause and Select. The Play/Pause button does toggle pseudo fullscreen, but many
// third-party and learning remotes have no Play/Pause key at all, so holding the clickpad (Select)
// is the universal shortcut. Both are measured here, in the only channel that sees these presses.
typedef NS_ENUM(NSInteger, BrowserLongPressSlot) {
    BrowserLongPressSlotPlayPause = 0,
    BrowserLongPressSlotSelect = 1,
    BrowserLongPressSlotCount = 2
};

static CFTimeInterval sBrowserLongPressBeganTimestamps[BrowserLongPressSlotCount] = {0.0, 0.0};
static NSUInteger sBrowserLongPressGenerations[BrowserLongPressSlotCount] = {0, 0};
// Set when a Select hold already acted. The Select-ended notification is then suppressed, so the
// click that follows the hold does not also run.
static BOOL sBrowserSelectLongPressFired = NO;

static NSInteger BrowserLongPressSlotForType(UIPressType type) {
    switch (type) {
        case UIPressTypePlayPause: return BrowserLongPressSlotPlayPause;
        case UIPressTypeSelect: return BrowserLongPressSlotSelect;
        default: return -1;
    }
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

// build-22 crash fix. The log the user captured showed:
//   exception: NSInvalidArgumentException
//   reason: -[ViewController (null selector)]: unrecognized selector sent to instance 0x80f019800
//   ... -[UIApplication(BrowserSelectPressForwarding) browser_sendEvent:] + 2276
// i.e. a message with a NULL selector reached an object UIKit still called a ViewController. That
// shape comes from walking the presented/child view-controller graph while UIKit is tearing it
// down: the crashed run was "in a player page, went back to the site home page", so an alert or the
// native player was being dismissed exactly as the next press arrived. Two things make that walk
// unsafe and both are fixed here:
//   1. depth was unbounded -- a presented/child cycle (or a very deep hierarchy) recursed until the
//      stack or an object gave out;
//   2. every hop re-read four properties off a controller that may already be deallocating.
// A depth cap plus nil/target checks turns "walk until something breaks" into "give up and report
// no player", which is the correct answer anyway: if the graph is mid-teardown there is no player
// to hand arrow presses to.
static NSUInteger const kBrowserViewControllerSearchMaxDepth = 16;

// build-25: above the crash fix there is a second, broader rule, and it is the one that actually
// explains why this crash keeps coming back at the same address.
//
// The crash is always inside THIS method, at a message send performed by our own code:
//   reason: -[ViewController (null selector)]: unrecognized selector sent to instance 0xb10020a00
//   ... -[UIApplication(BrowserSelectPressForwarding) browser_sendEvent:] + 2460 / + 2276
// The receiver is a controller; the selector is NULL. A NULL _cmd does not come from a typo -- it
// comes from objc_msgSend being handed a sel that was read out of a category's method frame. The
// `browser_sendEvent:` in this frame is dispatched as `$s30BrowserSelectPressForwarding...`, i.e.
// resolved through the CATEGORY name, not through UIApplication. Once the swizzle is torn down
// (a re-entrant +load, or the original IMP being exchanged twice) that lookup yields a NULL
// selector instead of an IMP, and every press crashes.
//
// Two independent consequences, both applied below:
//   1. the swizzle is installed defensively -- exchange only the entries we resolved by name, never
//      a method the runtime is still resolving, and record the original IMP explicitly so the
//      forwarding call can never go through a category lookup at all (`sendEventIMP`);
//   2. nothing in this file may keep a view controller or a window beyond the call that found it.
//      Every deferred block below captures only weak references and re-checks them, because the
//      whole point of deferring is that UIKit is free to tear the receiver down in between.
typedef void (*BrowserSendEventIMP)(id, SEL, UIEvent *);
static BrowserSendEventIMP sBrowserOriginalSendEventIMP = NULL;
static BOOL sBrowserSwizzleInstalled = NO;

// Called instead of [self browser_sendEvent:event]. Going through the original IMP removes the
// category lookup from the hot path entirely, which is where the NULL selector came from.
static void BrowserForwardSendEvent(UIApplication *self, UIEvent *event) {
    if (sBrowserOriginalSendEventIMP != NULL) {
        sBrowserOriginalSendEventIMP(self, @selector(sendEvent:), event);
        return;
    }
    // Only reachable if the exchange was refused; losing one event is better than crashing.
    NSLog(@"[InputTrace][App] original sendEvent: IMP missing; event dropped");
}

static UIViewController *BrowserFindViewControllerOfClassAtDepth(UIViewController *viewController,
                                                                Class targetClass,
                                                                NSUInteger depth) {
    if (viewController == nil || targetClass == Nil || depth > kBrowserViewControllerSearchMaxDepth) {
        return nil;
    }

    if ([viewController isKindOfClass:targetClass]) {
        return viewController;
    }

    // Take the child list once, on a controller already proven to be alive by the isKindOfClass:
    // message above, and never re-read a property that a later hop could have invalidated.
    NSArray<UIViewController *> *children = viewController.childViewControllers;
    UIViewController *presented = viewController.presentedViewController;

    if (presented != nil && presented != viewController) {
        UIViewController *match = BrowserFindViewControllerOfClassAtDepth(presented, targetClass, depth + 1);
        if (match != nil) {
            return match;
        }
    }

    for (UIViewController *childViewController in children) {
        if (childViewController == nil || childViewController == viewController) {
            continue;
        }
        UIViewController *match = BrowserFindViewControllerOfClassAtDepth(childViewController, targetClass, depth + 1);
        if (match != nil) {
            return match;
        }
    }

    if ([viewController isKindOfClass:[UINavigationController class]]) {
        UINavigationController *navigationController = (UINavigationController *)viewController;
        UIViewController *match = BrowserFindViewControllerOfClassAtDepth(navigationController.visibleViewController,
                                                                         targetClass,
                                                                         depth + 1);
        if (match != nil) {
            return match;
        }
    }

    if ([viewController isKindOfClass:[UITabBarController class]]) {
        UITabBarController *tabBarController = (UITabBarController *)viewController;
        UIViewController *match = BrowserFindViewControllerOfClassAtDepth(tabBarController.selectedViewController,
                                                                         targetClass,
                                                                         depth + 1);
        if (match != nil) {
            return match;
        }
    }

    return nil;
}

static UIViewController *BrowserFindViewControllerOfClass(UIViewController *viewController, Class targetClass) {
    return BrowserFindViewControllerOfClassAtDepth(viewController, targetClass, 0);
}

static UIViewController *BrowserFindPresentedNativeVideoPlayerViewController(UIApplication *application, Class nativeVideoPlayerClass) {
    if (application == nil || nativeVideoPlayerClass == Nil) {
        return nil;
    }
    // connectedScenes is the supported route on tvOS 13+; `windows` still works but can include
    // windows from a scene that is being disconnected, which is one more way to touch a dying
    // controller. Collect root controllers first so the walk below starts from stable anchors.
    NSMutableArray<UIViewController *> *roots = [NSMutableArray array];
    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (windowScene.activationState == UISceneActivationStateUnattached) {
            continue;
        }
        for (UIWindow *window in windowScene.windows) {
            if (window.hidden || window.rootViewController == nil) {
                continue;
            }
            [roots addObject:window.rootViewController];
        }
    }
    if (roots.count == 0) {
        // Fall back for older tvOS builds where connectedScenes is empty at this point.
        for (UIWindow *window in application.windows) {
            if (window.hidden || window.rootViewController == nil) {
                continue;
            }
            [roots addObject:window.rootViewController];
        }
    }

    for (UIViewController *root in roots) {
        UIViewController *match = BrowserFindViewControllerOfClass(root, nativeVideoPlayerClass);
        if (match != nil) {
            return match;
        }
    }
    return nil;
}

@interface UIApplication (BrowserSelectPressForwarding)

- (void)browser_sendEvent:(UIEvent *)event;

@end

#pragma mark - Arrow press forwarding

// Arrow presses are consumed by the tvOS focus engine before they ever reach
// -pressesBegan:, so they are observed here and republished as a notification.
static BOOL BrowserIsArrowPressType(UIPressType type) {
    return type == UIPressTypeUpArrow ||
           type == UIPressTypeDownArrow ||
           type == UIPressTypeLeftArrow ||
           type == UIPressTypeRightArrow;
}

static void BrowserPublishArrowPress(UIPressType type, BOOL began) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:BrowserGlobalArrowPressNotification
                                                            object:nil
                                                          userInfo:@{BrowserGlobalArrowPressTypeKey: @(type),
                                                                     BrowserGlobalArrowPressBeganKey: @(began)}];
    });
}

#pragma mark - Long press forwarding

// GCEventViewController hands PlayPause to the GameController framework before UIKit, so
// UILongPressGestureRecognizer with allowedPressTypes never recognises it. This bridge sees every
// press, so the hold is measured here: timestamp on Began, fire once the threshold passes while the
// button is still down, and suppress the release action via the flag in the input controller.
// Tracked buttons: PlayPause and Select. PlayPause is the documented shortcut, but remotes without
// a Play/Pause key (learning remotes, older Siri Remotes) can hold the clickpad instead.
// Menu is out because long-pressing Menu is the tvOS home gesture.
static BOOL BrowserLongPressIsTrackingType(UIPressType type) {
    return BrowserLongPressSlotForType(type) >= 0;
}

static CFTimeInterval BrowserLongPressBeganTimestamp(UIPressType type) {
    NSInteger slot = BrowserLongPressSlotForType(type);
    return slot >= 0 ? sBrowserLongPressBeganTimestamps[slot] : 0.0;
}

static void BrowserLongPressSetBeganTimestamp(UIPressType type, CFTimeInterval value) {
    NSInteger slot = BrowserLongPressSlotForType(type);
    if (slot >= 0) {
        sBrowserLongPressBeganTimestamps[slot] = value;
    }
}

static NSUInteger BrowserLongPressBumpGeneration(UIPressType type) {
    NSInteger slot = BrowserLongPressSlotForType(type);
    if (slot < 0) {
        return 0;
    }
    return ++sBrowserLongPressGenerations[slot];
}

static NSUInteger BrowserLongPressCurrentGeneration(UIPressType type) {
    NSInteger slot = BrowserLongPressSlotForType(type);
    return slot >= 0 ? sBrowserLongPressGenerations[slot] : 0;
}


static CFTimeInterval BrowserLongPressMinimumDurationForType(UIPressType type) {
    return (type == UIPressTypeSelect) ? kBrowserSelectLongPressMinimumDuration
                                       : kBrowserLongPressMinimumDuration;
}

static void BrowserLongPressBeginTracking(UIApplication *application, UIPressType type) {
    if (!BrowserLongPressIsTrackingType(type)) {
        return;
    }

    Class nativeVideoPlayerClass = NSClassFromString(@"BrowserNativeVideoPlayerViewController");
    if (nativeVideoPlayerClass != Nil &&
        BrowserFindPresentedNativeVideoPlayerViewController(application, nativeVideoPlayerClass) != nil) {
        return;
    }

    CFTimeInterval threshold = BrowserLongPressMinimumDurationForType(type);
    BrowserLongPressSetBeganTimestamp(type, CACurrentMediaTime());
    NSUInteger generation = BrowserLongPressBumpGeneration(type);
    // build-25: UIApplication is a singleton, so the strong capture here is not the crash source
    // itself -- but the block also re-walks the controller graph through it, and that walk is only
    // safe while the app is alive and the press is still current. Held weakly and re-checked, a
    // late timer after teardown becomes a no-op instead of a message into a dead hierarchy.
    __weak UIApplication *weakApplication = application;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(threshold * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        // A release (or a new press of the same button) bumps the generation and cancels this check,
        // so a short tap can never be mistaken for a hold.
        if (BrowserLongPressCurrentGeneration(type) != generation) {
            return;
        }
        CFTimeInterval began = BrowserLongPressBeganTimestamp(type);
        if (began <= 0.0) {
            return;
        }
        CFTimeInterval held = CACurrentMediaTime() - began;
        if (held + 0.02 < threshold) {
            return;
        }
        UIApplication *app = weakApplication;
        if (app == nil) {
            return;
        }
        if (nativeVideoPlayerClass != Nil &&
            BrowserFindPresentedNativeVideoPlayerViewController(app, nativeVideoPlayerClass) != nil) {
            return;
        }

        NSLog(@"[InputTrace][App] long press %@ fired (held %.2fs)", BrowserPressTypeString(type), held);
        if (type == UIPressTypeSelect) {
            // Suppress the Select-ended notification: the hold already acted.
            sBrowserSelectLongPressFired = YES;
        }
        [[NSNotificationCenter defaultCenter] postNotificationName:BrowserGlobalLongPressNotification
                                                            object:nil
                                                          userInfo:@{BrowserGlobalLongPressTypeKey: @(type)}];
    });
}

// Clears the hold state on release. The suppression of the short-press action is handled by the
// flags in BrowserRemoteInputController, which the notification already set.
static void BrowserLongPressEndTracking(UIPressType type) {
    if (!BrowserLongPressIsTrackingType(type)) {
        return;
    }
    BrowserLongPressBumpGeneration(type);           // cancel the pending threshold check
    BrowserLongPressSetBeganTimestamp(type, 0.0);
}

@implementation UIApplication (BrowserSelectPressForwarding)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // build-25: guard the swizzle instead of trusting it. `method_exchangeImplementations` is
        // idempotent-hostile: if this ever runs twice the two entries swap back, and then the
        // `browser_sendEvent:` send inside the body resolves through the category's own name to a
        // NULL selector -- exactly the reason string in the crash log. A one-shot flag plus a
        // captured original IMP makes a second run a no-op instead of a re-swap.
        if (sBrowserSwizzleInstalled) {
            return;
        }
        Class applicationClass = [UIApplication class];
        SEL originalSelector = @selector(sendEvent:);
        SEL replacementSelector = @selector(browser_sendEvent:);
        Method originalMethod = class_getInstanceMethod(applicationClass, originalSelector);
        Method replacementMethod = class_getInstanceMethod(applicationClass, replacementSelector);
        if (originalMethod == NULL || replacementMethod == NULL) {
            NSLog(@"[InputTrace][App] swizzle skipped (method missing original=%d replacement=%d)",
                  originalMethod != NULL, replacementMethod != NULL);
            return;
        }
        // Captured BEFORE the swap: afterwards method_getImplementation(original) returns our own
        // replacement, and the forwarding call would recurse until the stack ends.
        IMP originalIMP = method_getImplementation(originalMethod);
        IMP replacementIMP = method_getImplementation(replacementMethod);
        if (originalIMP == NULL || replacementIMP == NULL) {
            NSLog(@"[InputTrace][App] swizzle skipped (no IMP)");
            return;
        }
        sBrowserOriginalSendEventIMP = (BrowserSendEventIMP)originalIMP;
        // One exchange, in one direction, recorded by the flag above. Kept as an exchange rather
        // than add+replace so `browser_sendEvent:` keeps working as the forwarder that UIKit can
        // call by its own name if anything else in the app ever refers to it.
        method_exchangeImplementations(originalMethod, replacementMethod);
        sBrowserSwizzleInstalled = YES;
        NSLog(@"[InputTrace][App] sendEvent: swizzle installed original=%p", (void *)sBrowserOriginalSendEventIMP);
    });
}

- (void)browser_sendEvent:(UIEvent *)event {
    Class nativeVideoPlayerClass = NSClassFromString(@"BrowserNativeVideoPlayerViewController");
    UIViewController *nativeVideoPlayerViewController = BrowserFindPresentedNativeVideoPlayerViewController(self, nativeVideoPlayerClass);

    if (event.type == UIEventTypeTouches) {
        SEL allTouchesSelector = NSSelectorFromString(@"allTouches");
        if ([event respondsToSelector:allTouchesSelector]) {
            NSSet<UITouch *> *touches = ((id (*)(id, SEL))objc_msgSend)(event, allTouchesSelector);
            for (UITouch *touch in touches) {
                if (touch.type != UITouchTypeIndirect) {
                    continue;
                }

                CGPoint location = [touch locationInView:nil];
                if (touch.phase == UITouchPhaseBegan) {
                    sBrowserNativeScrubTracking = (nativeVideoPlayerClass != Nil && nativeVideoPlayerViewController != nil);
                    sBrowserNativePendingScrubPixels = 0.0;
                    sBrowserNativeLastTouchLocation = location;
                    continue;
                }

                if (!sBrowserNativeScrubTracking || nativeVideoPlayerViewController == nil) {
                    continue;
                }

                if (touch.phase == UITouchPhaseMoved) {
                    CGFloat deltaX = location.x - sBrowserNativeLastTouchLocation.x;
                    sBrowserNativeLastTouchLocation = location;
                    sBrowserNativePendingScrubPixels += deltaX;

                    SEL scrubSelector = NSSelectorFromString(@"scrubByHorizontalDelta:");
                    if ([nativeVideoPlayerViewController respondsToSelector:scrubSelector]) {
                        while (fabs(sBrowserNativePendingScrubPixels) >= kBrowserNativeScrubPixelStep) {
                            CGFloat step = sBrowserNativePendingScrubPixels > 0.0 ? kBrowserNativeScrubPixelStep : -kBrowserNativeScrubPixelStep;
                            ((void (*)(id, SEL, CGFloat))objc_msgSend)(nativeVideoPlayerViewController, scrubSelector, step);
                            sBrowserNativePendingScrubPixels -= step;
                            NSLog(@"[InputTrace][App] scrub step delta=%.2f", step);
                        }
                    }
                }

                if (touch.phase == UITouchPhaseEnded || touch.phase == UITouchPhaseCancelled) {
                    sBrowserNativeScrubTracking = NO;
                    sBrowserNativePendingScrubPixels = 0.0;
                }
            }
        }

        BrowserForwardSendEvent(self, event);
        return;
    }

    if (event.type != UIEventTypePresses) {
        BrowserForwardSendEvent(self, event);
        return;
    }

    SEL allPressesSelector = NSSelectorFromString(@"allPresses");
    if (![event respondsToSelector:allPressesSelector]) {
        BrowserForwardSendEvent(self, event);
        return;
    }

    NSSet<UIPress *> *presses = ((id (*)(id, SEL))objc_msgSend)(event, allPressesSelector);
    for (UIPress *press in presses) {
        nativeVideoPlayerViewController = BrowserFindPresentedNativeVideoPlayerViewController(self, nativeVideoPlayerClass);
        if ((press.type == UIPressTypeMenu || press.type == UIPressTypePlayPause || press.type == UIPressTypeSelect) && press.phase == UIPressPhaseBegan) {
            NSLog(@"[InputTrace][App] press=%@ phase=%@ top=%@",
                  BrowserPressTypeString(press.type),
                  BrowserPressPhaseString(press.phase),
                  nativeVideoPlayerViewController == nil ? @"(nil)" : NSStringFromClass([nativeVideoPlayerViewController class]));
        }

        // Republish arrow presses so the cursor can move; skip while the native player is up
        // because there the arrows drive scrubbing.
        if (BrowserIsArrowPressType(press.type) &&
            nativeVideoPlayerViewController == nil &&
            (press.phase == UIPressPhaseBegan || press.phase == UIPressPhaseEnded || press.phase == UIPressPhaseCancelled)) {
            NSLog(@"[InputTrace][App] arrow press=%@ phase=%@", BrowserPressTypeString(press.type), BrowserPressPhaseString(press.phase));
            BrowserPublishArrowPress(press.type, press.phase == UIPressPhaseBegan);
        }

        // Long press detection (PlayPause => fullscreen). Began starts the clock; the threshold fires
        // from a timer so the action happens while the button is still held. The event itself is NOT
        // swallowed here: dropping it would leave UIKit gesture recognizers mid-gesture. The
        // single-tap action is suppressed on release instead, by the flag in BrowserRemoteInputController.
        if (BrowserLongPressIsTrackingType(press.type)) {
            if (press.phase == UIPressPhaseBegan) {
                BrowserLongPressBeginTracking(self, press.type);
            } else if (press.phase == UIPressPhaseEnded || press.phase == UIPressPhaseCancelled) {
                BrowserLongPressEndTracking(press.type);
            }
        }

        if (press.type == UIPressTypeMenu && press.phase == UIPressPhaseBegan) {
            if (nativeVideoPlayerClass != Nil && nativeVideoPlayerViewController != nil) {
                NSLog(@"[InputTrace][App] swallow Menu for native player");
                // build-25: weak, and re-checked inside the block. Deferring to the main queue is
                // exactly the window in which the controller can be dismissed and released; a
                // strong capture here kept a dead controller alive and then messaged it, which is
                // the crash the user keeps hitting.
                __weak UIViewController *weakPlayer = nativeVideoPlayerViewController;
                dispatch_async(dispatch_get_main_queue(), ^{
                    UIViewController *player = weakPlayer;
                    if (player == nil) {
                        return;
                    }
                    [player dismissViewControllerAnimated:YES completion:nil];
                });
                return;
            }
        }

        if (press.type == UIPressTypePlayPause && press.phase == UIPressPhaseEnded) {
            if (nativeVideoPlayerClass != Nil && nativeVideoPlayerViewController != nil) {
                SEL togglePlaybackSelector = NSSelectorFromString(@"togglePlayback");
                if ([nativeVideoPlayerViewController respondsToSelector:togglePlaybackSelector]) {
                    NSLog(@"[InputTrace][App] swallow PlayPause for native player");
                    __weak UIViewController *weakPlayer = nativeVideoPlayerViewController;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        UIViewController *player = weakPlayer;
                        if (player == nil || ![player respondsToSelector:togglePlaybackSelector]) {
                            return;
                        }
                        ((void (*)(id, SEL))objc_msgSend)(player, togglePlaybackSelector);
                    });
                    return;
                }
            }
        }

        if (press.type == UIPressTypeSelect && press.phase == UIPressPhaseEnded) {
            if (nativeVideoPlayerClass != Nil && nativeVideoPlayerViewController != nil) {
                SEL togglePlaybackSelector = NSSelectorFromString(@"togglePlayback");
                if ([nativeVideoPlayerViewController respondsToSelector:togglePlaybackSelector]) {
                    NSLog(@"[InputTrace][App] swallow Select for native player");
                    __weak UIViewController *weakPlayer = nativeVideoPlayerViewController;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        UIViewController *player = weakPlayer;
                        if (player == nil || ![player respondsToSelector:togglePlaybackSelector]) {
                            return;
                        }
                        ((void (*)(id, SEL))objc_msgSend)(player, togglePlaybackSelector);
                    });
                    return;
                }
            }
        }

        if ((press.type == UIPressTypeLeftArrow || press.type == UIPressTypeRightArrow) && press.phase == UIPressPhaseEnded) {
            if (nativeVideoPlayerClass != Nil && nativeVideoPlayerViewController != nil) {
                SEL skipSelector = NSSelectorFromString(@"skipByInterval:");
                if ([nativeVideoPlayerViewController respondsToSelector:skipSelector]) {
                    CFTimeInterval now = CACurrentMediaTime();
                    BOOL isDoubleTap = (sBrowserNativeLastArrowPressType == press.type) &&
                                       ((now - sBrowserNativeLastArrowPressTimestamp) <= kBrowserNativeArrowDoubleTapInterval);
                    sBrowserNativeLastArrowPressType = press.type;
                    sBrowserNativeLastArrowPressTimestamp = now;

                    if (isDoubleTap) {
                        NSTimeInterval delta = (press.type == UIPressTypeRightArrow) ? 5.0 : -5.0;
                        NSLog(@"[InputTrace][App] swallow %@ double tap for native player (delta=%0.1f)",
                              BrowserPressTypeString(press.type), delta);
                        __weak UIViewController *weakPlayer = nativeVideoPlayerViewController;
                        dispatch_async(dispatch_get_main_queue(), ^{
                            UIViewController *player = weakPlayer;
                            if (player == nil || ![player respondsToSelector:skipSelector]) {
                                return;
                            }
                            ((void (*)(id, SEL, NSTimeInterval))objc_msgSend)(player, skipSelector, delta);
                        });
                        sBrowserNativeLastArrowPressType = (UIPressType)-1;
                        sBrowserNativeLastArrowPressTimestamp = 0.0;
                    } else {
                        NSLog(@"[InputTrace][App] swallow %@ single tap for native player (waiting for double tap)",
                              BrowserPressTypeString(press.type));
                    }
                    return;
                }
            }
        }
    }

    // build-22: snapshot the Select-ended flags BEFORE forwarding. The old order ran
    // [self browser_sendEvent:event] first and then walked `presses` again -- but `presses` is the
    // event's own live set, and forwarding is what lets UIKit consume the event, dismiss a
    // controller, and (possibly) release it. Reading it afterwards is a use-after-free of precisely
    // the kind the crash log shows. Deciding before forwarding costs nothing: the decision only
    // depends on the press types in this event.
    BOOL shouldPostSelectEndedNotification = NO;
    for (UIPress *press in presses) {
        if (press.type == UIPressTypeSelect && press.phase == UIPressPhaseEnded) {
            if (sBrowserSelectLongPressFired) {
                // Clear the flag at decision time so a duplicated End cannot suppress twice.
                sBrowserSelectLongPressFired = NO;
                NSLog(@"[InputTrace][App] suppress Select-ended notification after hold");
            } else {
                NSLog(@"[InputTrace][App] post BrowserGlobalSelectPressEndedNotification");
                shouldPostSelectEndedNotification = YES;
            }
            break;
        }
    }

    BrowserForwardSendEvent(self, event);

    if (shouldPostSelectEndedNotification) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:BrowserGlobalSelectPressEndedNotification object:nil];
        });
    }
}

@end
