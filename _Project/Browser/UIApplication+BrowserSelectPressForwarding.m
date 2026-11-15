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
NSString * const BrowserGlobalLongPressSourceKey = @"source";
NSString * const BrowserGlobalLongPressSourceHold = @"hold";
NSString * const BrowserGlobalLongPressSourceAuxKey = @"aux";
static BOOL sBrowserNativeScrubTracking = NO;
static CGFloat sBrowserNativePendingScrubPixels = 0.0;
static CGPoint sBrowserNativeLastTouchLocation = {0, 0};
static CFTimeInterval sBrowserNativeLastArrowPressTimestamp = 0.0;
static UIPressType sBrowserNativeLastArrowPressType = (UIPressType)-1;
static CGFloat const kBrowserNativeScrubPixelStep = 18.0;
static CFTimeInterval const kBrowserNativeArrowDoubleTapInterval = 0.35;
static CFTimeInterval const kBrowserLongPressMinimumDuration = 0.55;
static CFTimeInterval sBrowserPlayPauseBeganTimestamp = 0.0;
static CFTimeInterval sBrowserMenuBeganTimestamp = 0.0;
static BOOL sBrowserPlayPauseLongPressFired = NO;
static BOOL sBrowserMenuLongPressFired = NO;
static NSUInteger sBrowserPlayPauseLongPressGeneration = 0;
static NSUInteger sBrowserMenuLongPressGeneration = 0;

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

// GCEventViewController hands Menu/PlayPause to the GameController framework before UIKit, so
// UILongPressGestureRecognizer with allowedPressTypes never recognises them. This bridge sees every
// press, so the hold is measured here: timestamp on Began, fire once the threshold passes while the
// button is still down, and suppress the release action via the flags in the input controller.
// Menu is tracked again: tvOS only reserves the *system* home gesture after its own delay, and a
// 0.55 s hold is reported to the app before that. Select is deliberately excluded - it is the
// ordinary click and long-pressing it must keep working as before.
static BOOL BrowserLongPressIsTrackingType(UIPressType type) {
    return type == UIPressTypePlayPause || type == UIPressTypeMenu;
}

static CFTimeInterval BrowserLongPressBeganTimestamp(UIPressType type) {
    return (type == UIPressTypePlayPause) ? sBrowserPlayPauseBeganTimestamp : sBrowserMenuBeganTimestamp;
}

static void BrowserLongPressSetBeganTimestamp(UIPressType type, CFTimeInterval value) {
    if (type == UIPressTypePlayPause) {
        sBrowserPlayPauseBeganTimestamp = value;
    } else if (type == UIPressTypeMenu) {
        sBrowserMenuBeganTimestamp = value;
    }
}

static void BrowserLongPressSetFired(UIPressType type, BOOL fired) {
    if (type == UIPressTypePlayPause) {
        sBrowserPlayPauseLongPressFired = fired;
    } else if (type == UIPressTypeMenu) {
        sBrowserMenuLongPressFired = fired;
    }
}

static NSUInteger BrowserLongPressBumpGeneration(UIPressType type) {
    if (type == UIPressTypePlayPause) {
        return ++sBrowserPlayPauseLongPressGeneration;
    }
    return ++sBrowserMenuLongPressGeneration;
}

static NSUInteger BrowserLongPressCurrentGeneration(UIPressType type) {
    return (type == UIPressTypePlayPause) ? sBrowserPlayPauseLongPressGeneration
                                          : sBrowserMenuLongPressGeneration;
}

// Keys that tvOS itself delivers as a press but UIKit gives no UIPressType constant for. Third
// party remotes send these (a Stop button, for instance). The favorites menu is bound to them so
// such remotes always have a way in, in addition to long-press Menu.
static BOOL BrowserIsUnmappedAuxPressType(UIPressType type) {
    switch (type) {
        case UIPressTypeUpArrow:
        case UIPressTypeDownArrow:
        case UIPressTypeLeftArrow:
        case UIPressTypeRightArrow:
        case UIPressTypeSelect:
        case UIPressTypeMenu:
        case UIPressTypePlayPause:
            return NO;
        default:
            return YES;
    }
}

// A remote key that tvOS delivers but UIKit has no UIPressType constant for (a Stop button on a
// third-party remote, for instance). It opens favorites directly. The notification carries an
// explicit "aux" source so the receiver does not set the Menu long-press suppression flag - that
// flag belongs to Menu only, and setting it here would eat the next Menu press (no more Go Back).
static void BrowserPublishFavoritesShortcut(void) {
    NSLog(@"[InputTrace][App] aux press -> favorites");
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:BrowserGlobalLongPressNotification
                                                            object:nil
                                                          userInfo:@{BrowserGlobalLongPressTypeKey: @(UIPressTypeMenu),
                                                                     BrowserGlobalLongPressSourceKey: BrowserGlobalLongPressSourceAuxKey}];
    });
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

    BrowserLongPressSetBeganTimestamp(type, CACurrentMediaTime());
    BrowserLongPressSetFired(type, NO);
    NSUInteger generation = BrowserLongPressBumpGeneration(type);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kBrowserLongPressMinimumDuration * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (BrowserLongPressCurrentGeneration(type) != generation) {
            return;
        }
        CFTimeInterval began = BrowserLongPressBeganTimestamp(type);
        if (began <= 0.0) {
            return;
        }
        CFTimeInterval held = CACurrentMediaTime() - began;
        if (held + 0.02 < kBrowserLongPressMinimumDuration) {
            return;
        }
        if (nativeVideoPlayerClass != Nil &&
            BrowserFindPresentedNativeVideoPlayerViewController(application, nativeVideoPlayerClass) != nil) {
            return;
        }

        BrowserLongPressSetFired(type, YES);
        NSLog(@"[InputTrace][App] long press %@ fired (held %.2fs)", BrowserPressTypeString(type), held);
        [[NSNotificationCenter defaultCenter] postNotificationName:BrowserGlobalLongPressNotification
                                                            object:nil
                                                          userInfo:@{BrowserGlobalLongPressTypeKey: @(type),
                                                                     BrowserGlobalLongPressSourceKey: BrowserGlobalLongPressSourceHold}];
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
    BrowserLongPressSetFired(type, NO);
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

        // Long press detection (PlayPause => fullscreen, Menu => favorites). Began starts the clock;
        // the threshold fires from a timer so the action happens while the button is still held.
        // The event itself is NOT swallowed here: dropping it would leave UIKit gesture recognizers
        // mid-gesture. The single-tap action is suppressed on release instead, by the flags in
        // BrowserRemoteInputController.
        if (BrowserLongPressIsTrackingType(press.type)) {
            if (press.phase == UIPressPhaseBegan) {
                BrowserLongPressBeginTracking(self, press.type);
            } else if (press.phase == UIPressPhaseEnded || press.phase == UIPressPhaseCancelled) {
                BrowserLongPressEndTracking(press.type);
            }
        }

        // Any key UIKit has no constant for (third-party remote buttons such as Stop) opens favorites
        // directly, on press-down only, and never while the native player is on screen.
        if (BrowserIsUnmappedAuxPressType(press.type) &&
            press.phase == UIPressPhaseBegan &&
            nativeVideoPlayerViewController == nil) {
            BrowserPublishFavoritesShortcut();
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
            NSLog(@"[InputTrace][App] post BrowserGlobalSelectPressEndedNotification");
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:BrowserGlobalSelectPressEndedNotification object:nil];
            });
            break;
        }
    }
}

@end
