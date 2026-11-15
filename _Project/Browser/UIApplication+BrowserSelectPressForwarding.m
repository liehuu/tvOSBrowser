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

static UIViewController *BrowserFindViewControllerOfClass(UIViewController *viewController, Class targetClass) {
    if (viewController == nil || targetClass == Nil) {
        return nil;
    }

    if ([viewController isKindOfClass:targetClass]) {
        return viewController;
    }

    if (viewController.presentedViewController != nil) {
        UIViewController *match = BrowserFindViewControllerOfClass(viewController.presentedViewController, targetClass);
        if (match != nil) {
            return match;
        }
    }

    for (UIViewController *childViewController in viewController.childViewControllers) {
        UIViewController *match = BrowserFindViewControllerOfClass(childViewController, targetClass);
        if (match != nil) {
            return match;
        }
    }

    if ([viewController isKindOfClass:[UINavigationController class]]) {
        UINavigationController *navigationController = (UINavigationController *)viewController;
        UIViewController *match = BrowserFindViewControllerOfClass(navigationController.visibleViewController, targetClass);
        if (match != nil) {
            return match;
        }
    }

    if ([viewController isKindOfClass:[UITabBarController class]]) {
        UITabBarController *tabBarController = (UITabBarController *)viewController;
        UIViewController *match = BrowserFindViewControllerOfClass(tabBarController.selectedViewController, targetClass);
        if (match != nil) {
            return match;
        }
    }

    return nil;
}

static UIViewController *BrowserFindPresentedNativeVideoPlayerViewController(UIApplication *application, Class nativeVideoPlayerClass) {
    for (UIWindow *window in application.windows) {
        if (window.hidden || window.rootViewController == nil) {
            continue;
        }

        UIViewController *match = BrowserFindViewControllerOfClass(window.rootViewController, nativeVideoPlayerClass);
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
        if (nativeVideoPlayerClass != Nil &&
            BrowserFindPresentedNativeVideoPlayerViewController(application, nativeVideoPlayerClass) != nil) {
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
        Method originalMethod = class_getInstanceMethod(self, @selector(sendEvent:));
        Method replacementMethod = class_getInstanceMethod(self, @selector(browser_sendEvent:));
        if (originalMethod != NULL && replacementMethod != NULL) {
            method_exchangeImplementations(originalMethod, replacementMethod);
        }
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

        [self browser_sendEvent:event];
        return;
    }

    if (event.type != UIEventTypePresses) {
        [self browser_sendEvent:event];
        return;
    }

    SEL allPressesSelector = NSSelectorFromString(@"allPresses");
    if (![event respondsToSelector:allPressesSelector]) {
        [self browser_sendEvent:event];
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
                dispatch_async(dispatch_get_main_queue(), ^{
                    [nativeVideoPlayerViewController dismissViewControllerAnimated:YES completion:nil];
                });
                return;
            }
        }

        if (press.type == UIPressTypePlayPause && press.phase == UIPressPhaseEnded) {
            if (nativeVideoPlayerClass != Nil && nativeVideoPlayerViewController != nil) {
                SEL togglePlaybackSelector = NSSelectorFromString(@"togglePlayback");
                if ([nativeVideoPlayerViewController respondsToSelector:togglePlaybackSelector]) {
                    NSLog(@"[InputTrace][App] swallow PlayPause for native player");
                    dispatch_async(dispatch_get_main_queue(), ^{
                        ((void (*)(id, SEL))objc_msgSend)(nativeVideoPlayerViewController, togglePlaybackSelector);
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
                    dispatch_async(dispatch_get_main_queue(), ^{
                        ((void (*)(id, SEL))objc_msgSend)(nativeVideoPlayerViewController, togglePlaybackSelector);
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
                        dispatch_async(dispatch_get_main_queue(), ^{
                            ((void (*)(id, SEL, NSTimeInterval))objc_msgSend)(nativeVideoPlayerViewController, skipSelector, delta);
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

    [self browser_sendEvent:event];

    for (UIPress *press in presses) {
        if (press.type == UIPressTypeSelect && press.phase == UIPressPhaseEnded) {
            if (sBrowserSelectLongPressFired) {
                sBrowserSelectLongPressFired = NO;
                NSLog(@"[InputTrace][App] suppress Select-ended notification after hold");
                break;
            }
            NSLog(@"[InputTrace][App] post BrowserGlobalSelectPressEndedNotification");
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:BrowserGlobalSelectPressEndedNotification object:nil];
            });
            break;
        }
    }
}

@end
