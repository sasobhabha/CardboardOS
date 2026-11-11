//
//  CBBTouchInjector.m
//  CardboardOS
//
//  Turns a point on the panel into a touch. Where that touch has to be created
//  depends on who owns the screen:
//
//  - On the home screen, lock screen or app switcher, SpringBoard's own windows
//    are the target. Apple's recipe for synthetic touches works there: tag the
//    event with the receiving window's context ID and hand it to UIApplication.
//    Verified on this device ("in-process funnel delivers (2 touch event(s))").
//
//  - Inside an app, that recipe cannot work at all: the app's windows belong to
//    the app's process and SpringBoard has no context ID for them. Posting the
//    event into the HID system from SpringBoard does not work either - the
//    dispatch is dropped before it becomes an event (the stage log shows
//    "0 digitizer echo(es)"). So the touch is built inside backboardd instead,
//    which owns the display and the touch pipeline; see CBBHIDDriver.m.
//

#import "CBBTouchInjector.h"
#import "CBBCompat.h"
#import "CBBInjectionPort.h"
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

// Contact slot 1 of the digitizer, the one Apple's own synthetic-touch code
// (WebKit's _WKTouchEventGenerator) uses: identifier 2, identity 2.
static const uint32_t kCBBFingerIdentifier = 2;

// The options mask SimulateTouch passes when it writes the built-in digitizer
// fields. The plain setter alone can leave backboardd seeing
// DisplayIntegrated: 0, and a touch that is not display-integrated is either
// dropped or read as an external device's coordinates.
static const uint32_t kCBBFieldOptions = 0xF0000000u;

#pragma mark - Which process owns the screen

// SpringBoard knows which app is on screen; nothing else in this process does.
// It decides which of the two injection routes a tap takes. Returns nil whenever
// SpringBoard itself owns the screen (home screen, lock screen, app switcher).
// The app's pid, for the log only: on this device it comes back 0 for a running
// app (SBApplication's -pid), which is why queued taps are addressed by bundle
// id instead. CBBForegroundAppBundleIdentifier answers *whether* SpringBoard owns
// the screen, not which process a touch has to be built in - the relay inside
// the app decides that for itself.
static pid_t CBBForegroundAppPID(void) {
    Class springBoardClass = NSClassFromString(@"SpringBoard");
    if (!springBoardClass) return 0;
    SEL frontmostSelector = NSSelectorFromString(@"_accessibilityFrontMostApplication");
    SEL pidSelector = NSSelectorFromString(@"pid");
    @try {
        id springBoard = ((id (*)(id, SEL))objc_msgSend)(springBoardClass, @selector(sharedApplication));
        if (!springBoard || ![springBoard respondsToSelector:frontmostSelector]) return 0;
        id app = ((id (*)(id, SEL))objc_msgSend)(springBoard, frontmostSelector);
        if (!app || ![app respondsToSelector:pidSelector]) return 0;
        return ((pid_t (*)(id, SEL))objc_msgSend)(app, pidSelector);
    } @catch (NSException *exception) {
        return 0;
    }
}

static NSString *CBBForegroundAppBundleIdentifier(void) {
    Class springBoardClass = NSClassFromString(@"SpringBoard");
    if (!springBoardClass) return nil;
    SEL frontmostSelector = NSSelectorFromString(@"_accessibilityFrontMostApplication");
    SEL bundleSelector = NSSelectorFromString(@"bundleIdentifier");
    @try {
        id springBoard = ((id (*)(id, SEL))objc_msgSend)(springBoardClass, @selector(sharedApplication));
        if (!springBoard || ![springBoard respondsToSelector:frontmostSelector]) return nil;
        id app = ((id (*)(id, SEL))objc_msgSend)(springBoard, frontmostSelector);
        if (!app || ![app respondsToSelector:bundleSelector]) return nil;
        id bundle = ((id (*)(id, SEL))objc_msgSend)(app, bundleSelector);
        if (![bundle isKindOfClass:[NSString class]] || [bundle length] == 0) return nil;
        // The lock screen answers with SpringBoard itself.
        if ([bundle isEqualToString:@"com.apple.springboard"]) return nil;
        return bundle;
    } @catch (NSException *exception) {
        return nil;
    }
}

typedef void (*CBBSetIntegerWithOptionsFn)(IOHIDEventRef event, uint32_t field, int value, uint32_t options);
typedef void (*CBBSetDigitizerInfoFn)(IOHIDEventRef event,
                                      uint32_t contextID,
                                      uint8_t systemGestureIsPossible,
                                      uint8_t isSystemGestureStateChangeEvent,
                                      CFStringRef displayUUID,
                                      CFTimeInterval initialTouchTimestamp,
                                      float maxForce);

// Resolved at runtime so this dylib still loads if a symbol is ever absent: an
// unresolved import fails the whole dylib at load time, which is
// indistinguishable from "the tweak was never installed".
static CBBSetIntegerWithOptionsFn CBBSetIntegerWithOptions = NULL;
static CBBSetDigitizerInfoFn CBBSetDigitizerInfo = NULL;

// Touches that arrived at -[UIApplication sendEvent:] inside SpringBoard: the
// other end of the in-process funnel. A non-zero delta over a tap window is the
// tap itself, because nothing else touches the screen during a hold-to-click.
static volatile int32_t CBBDeliveryCount = 0;

#pragma mark - Delivery probe

// Counts touches that make it into SpringBoard's own event pipeline. It is a
// pass-through: the event is handed to the original implementation untouched,
// so having this installed cannot change what a tap does, only tell us whether
// one arrived.
@interface UIApplication (CBBTouchDeliveryProbe)
- (void)cbb_deliveryProbeSendEvent:(UIEvent *)event;
@end

@implementation UIApplication (CBBTouchDeliveryProbe)

- (void)cbb_deliveryProbeSendEvent:(UIEvent *)event {
    // After the exchange below this selector *is* the original -sendEvent:.
    if (event.type == UIEventTypeTouches) {
        NSUInteger count = [event allTouches].count;
        if (count > 0) __sync_fetch_and_add(&CBBDeliveryCount, (int32_t)count);
    }
    [self cbb_deliveryProbeSendEvent:event];
}

@end

typedef NS_ENUM(NSInteger, CBBInjectionFunnel) {
    // SpringBoard's own pipeline, tagged with a window context ID. This is what
    // Apple's synthetic touches do and it needs no permission from the HID
    // system: it is the same funnel a remote-desktop click uses.
    CBBInjectionFunnelInProcess = 0,
    // The app's own process, because the target window is in another process
    // and has no context ID this one can name. A relay dylib inside the app does
    // the same context-tagged enqueue there; see CBBTouchRelay.m.
    CBBInjectionFunnelApp = 1,
};

typedef NS_ENUM(NSInteger, CBBTouchPhase) {
    CBBTouchPhaseDown = CBBInjectionPhaseDown,
    CBBTouchPhaseMove = CBBInjectionPhaseMove,
    CBBTouchPhaseUp = CBBInjectionPhaseUp,
};

@interface CBBTouchInjector () {
    BOOL _contextIdWarned;
    BOOL _appFunnelReported;
    BOOL _funnelReported;
    BOOL _relayReported;
    BOOL _relayMissingReported;
    pid_t _appPid;
    NSString *_appBundle;
}
@end

@implementation CBBTouchInjector {
    dispatch_queue_t _queue;
    BOOL _available;
}

+ (instancetype)sharedInjector {
    static CBBTouchInjector *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[CBBTouchInjector alloc] init];
    });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("com.buffy.cardboardos.hid", DISPATCH_QUEUE_SERIAL);
        CBBSetIntegerWithOptions = (CBBSetIntegerWithOptionsFn)dlsym(RTLD_DEFAULT,
                                                                     "IOHIDEventSetIntegerValueWithOptions");
        CBBSetDigitizerInfo = (CBBSetDigitizerInfoFn)dlsym(RTLD_DEFAULT,
                                                           "BKSHIDEventSetDigitizerInfo");
        _available = YES;
        [self installDeliveryProbe];
        CBBMarkStage([NSString stringWithFormat:
                      @"injection: ready (%@, %@)",
                      CBBSetDigitizerInfo ? @"context-ID delivery available" : @"context ID MISSING (BKSHIDEventSetDigitizerInfo not found)",
                      [UIApplication sharedApplication] &&
                      [[UIApplication sharedApplication] respondsToSelector:NSSelectorFromString(@"_enqueueHIDEvent:")]
                          ? @"_enqueueHIDEvent: present" : @"_enqueueHIDEvent: MISSING"]);
    }
    return self;
}

- (void)installDeliveryProbe {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @try {
            Method original = class_getInstanceMethod([UIApplication class], @selector(sendEvent:));
            Method probe = class_getInstanceMethod([UIApplication class],
                                                   @selector(cbb_deliveryProbeSendEvent:));
            if (original && probe) {
                method_exchangeImplementations(original, probe);
                CBBMarkStage(@"injection: watching SpringBoard's event pipeline for delivered touches");
            }
        } @catch (NSException *exception) {
            CBBMarkStage([NSString stringWithFormat:@"injection: delivery probe unavailable (%@)",
                          exception.reason]);
        }
    });
}

- (CGSize)screenSize {
    return CBBNativeScreenSize();
}

- (BOOL)available {
    return _available;
}

#pragma mark - SpringBoard's own funnel

// The window that should own a touch at this point, so the event carries a
// context ID SpringBoard will accept. Our own overlay is skipped: it is a
// passthrough window and is never the intended target.
- (UIWindow *)targetWindowForPoint:(CGPoint)point {
    UIApplication *app = [UIApplication sharedApplication];
    for (UIWindow *window in [app.windows reverseObjectEnumerator]) {
        if (window.windowLevel >= 10000000.0) continue;
        if (window.hidden || window.alpha < 0.01) continue;
        CGPoint local = point;
        if ([window respondsToSelector:@selector(convertPoint:fromCoordinateSpace:)]) {
            local = [window convertPoint:point fromCoordinateSpace:[UIScreen mainScreen].fixedCoordinateSpace];
        }
        if (!CGRectContainsPoint(window.bounds, local)) continue;
        return window;
    }
    return app.keyWindow;
}

- (uint32_t)contextIdForPoint:(CGPoint)point {
    UIWindow *window = [self targetWindowForPoint:point];
    if (!window) return 0;
    SEL selector = NSSelectorFromString(@"_contextId");
    if (![window respondsToSelector:selector]) return 0;
    @try {
        return ((uint32_t (*)(id, SEL))objc_msgSend)(window, selector);
    } @catch (NSException *exception) {
        return 0;
    }
}

// SpringBoard's own event pipeline, the funnel a VNC server uses: tag the
// digitizer event with the receiving window's context ID and hand it to
// UIApplication. BKSHIDEventSetDigitizerInfo is the step that makes the event
// acceptable; without it SpringBoard parses the event, finds no context and
// drops it, which looks exactly like "the click never happened".
- (void)enqueueInProcess:(IOHIDEventRef)event atPoint:(CGPoint)point {
    UIApplication *app = [UIApplication sharedApplication];
    SEL selector = NSSelectorFromString(@"_enqueueHIDEvent:");
    if (![app respondsToSelector:selector]) {
        CBBMarkStage(@"injection: SpringBoard has no _enqueueHIDEvent:, event dropped");
        return;
    }
    uint32_t contextId = CBBSetDigitizerInfo ? [self contextIdForPoint:point] : 0;
    if (contextId) {
        CBBSetDigitizerInfo(event, contextId, 0, 0, NULL, 0, 0);
    } else if (!_contextIdWarned) {
        _contextIdWarned = YES;
        CBBMarkStage([NSString stringWithFormat:
                      @"injection: no window context ID at (%.0f,%.0f), sending untagged",
                      point.x, point.y]);
    }
    static BOOL funnelNamed = NO;
    if (!funnelNamed) {
        funnelNamed = YES;
        CBBMarkStage(@"injection via SpringBoard's own event pipeline");
    }
    ((void (*)(id, SEL, id))objc_msgSend)(app, selector, (__bridge id)event);
}

#pragma mark - backboardd's funnel

// Chosen per tap, not once: the phone alternates between the home screen and
// apps, and the right answer is different in each.
- (CBBInjectionFunnel)currentFunnel {
    NSString *bundle = CBBForegroundAppBundleIdentifier();
    if (bundle) {
        _appBundle = bundle;
        _appPid = CBBForegroundAppPID();
        if (!_appFunnelReported) {
            _appFunnelReported = YES;
            CBBMarkStage([NSString stringWithFormat:
                          @"injection: %@ (pid %d) is on screen, taps are queued for the relay inside the app",
                          bundle, (int)_appPid]);
        }
        return CBBInjectionFunnelApp;
    }
    _appBundle = nil;
    _appPid = 0;
    return CBBInjectionFunnelInProcess;
}

static NSString *const CBBRelayQueuePath = @"/var/mobile/Library/Preferences/com.buffy.cardboardos.appinject";

// The relay in the app is asleep until something tells it to look: it is loaded
// into every app, and none of them should be polling a file in the background.
static void CBBRelayWake(void) {
    static int32_t (*post)(const char *) = NULL;
    static BOOL resolved = NO;
    if (!resolved) {
        resolved = YES;
        void *notify = dlopen("/usr/lib/libnotify.dylib", RTLD_LAZY);
        if (!notify) notify = dlopen("/usr/lib/system/libnotify.dylib", RTLD_LAZY);
        post = (int32_t (*)(const char *))dlsym(notify ? notify : RTLD_DEFAULT, "notify_post");
    }
    if (post) post(CBB_RELAY_NOTIFY_NAME);
}

// Truncated before each gesture so the queue never grows past one of them, and
// so a gesture that was interrupted cannot bleed into the next one. The relay
// notices because the file is then shorter than the offset it had read to.
- (void)beginAppGesture {
    [[NSData data] writeToFile:CBBRelayQueuePath atomically:YES];
}

// One line per digitizer event, addressed by bundle id, so down/move/up keep the
// timing this side chose and no other app acts on a tap meant for the app on
// screen. Returns whether the event reached the queue: a write that fails is the
// difference between "the tap was lost" and "the tap was never sent".
- (BOOL)postAppEventAtPoint:(CGPoint)point phase:(CBBTouchPhase)phase bundle:(NSString *)bundle {
    if (bundle.length == 0) return NO;
    NSData *data = [[NSString stringWithFormat:@"%@ %d %.2f %.2f\n", bundle, (int)phase, point.x, point.y]
                    dataUsingEncoding:NSUTF8StringEncoding];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:CBBRelayQueuePath];
    if (!handle) {
        [data writeToFile:CBBRelayQueuePath atomically:YES];
        handle = [NSFileHandle fileHandleForWritingAtPath:CBBRelayQueuePath];
    }
    if (!handle) {
        if (!_relayMissingReported) {
            _relayMissingReported = YES;
            CBBMarkStage([NSString stringWithFormat:
                          @"injection: cannot write %@ — app taps will do nothing",
                          CBBRelayQueuePath]);
        }
        return NO;
    }
    @try {
        [handle seekToEndOfFile];
        [handle writeData:data];
        [handle closeFile];
    } @catch (NSException *exception) {
        return NO;
    }
    CBBRelayWake();
    return YES;
}

#pragma mark - Delivery

- (void)deliverTouchAtPoint:(CGPoint)point phase:(CBBTouchPhase)phase funnel:(CBBInjectionFunnel)funnel {
    if (funnel == CBBInjectionFunnelApp) {
        [self postAppEventAtPoint:point phase:phase bundle:_appBundle];
        return;
    }
    @try {
        IOHIDEventRef event = [self newTouchEventAtPoint:point phase:phase];
        if (!event) return;
        [self enqueueInProcess:event atPoint:point];
    } @catch (NSException *exception) {
        CBBMarkStage([NSString stringWithFormat:@"injection threw %@: %@",
                      exception.name, exception.reason]);
    }
}

// A tap through the in-process funnel is judged from the receiving end: did a
// touch actually reach SpringBoard's event pipeline.
- (void)evaluateAfterTapFrom:(int32_t)deliveryBefore {
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), _queue, ^{
        CBBTouchInjector *strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_funnelReported) return;
        strongSelf->_funnelReported = YES;
        int32_t delivered = CBBDeliveryCount - deliveryBefore;
        if (delivered > 0) {
            CBBMarkStage([NSString stringWithFormat:
                          @"injection: in-process funnel delivers (%d touch event(s) reached SpringBoard)",
                          (int)delivered]);
        } else {
            CBBMarkStage(@"injection: in-process funnel delivered nothing — SpringBoard saw no touch");
        }
    });
}

static void CBBSetDigitizerField(IOHIDEventRef event, uint32_t field, int value);

#pragma mark - Event construction

// The event shape Apple uses for synthetic touches, and the only one verified to
// work on a device: a hand digitizer event carrying one finger, coordinates in
// panel points, DisplayIntegrated set, and range/touch only on the finger.
- (IOHIDEventRef)newTouchEventAtPoint:(CGPoint)point phase:(CBBTouchPhase)phase {
    BOOL touching = (phase != CBBTouchPhaseUp);
    uint32_t mask;
    switch (phase) {
        case CBBTouchPhaseDown:
            mask = CBBHIDDigitizerEventTouch | CBBHIDDigitizerEventIdentity;
            break;
        case CBBTouchPhaseMove:
            mask = CBBHIDDigitizerEventPosition | CBBHIDDigitizerEventAttribute;
            break;
        default:
            mask = CBBHIDDigitizerEventTouch | CBBHIDDigitizerEventIdentity;
            break;
    }

    uint64_t timestamp = mach_absolute_time();
    IOHIDEventRef hand = IOHIDEventCreateDigitizerEvent(kCFAllocatorDefault,
                                                        timestamp,
                                                        CBBHIDTransducerTypeHand,
                                                        0,      // index
                                                        0,      // identity
                                                        mask,
                                                        0,      // button mask
                                                        0, 0, 0,
                                                        0, 0,   // pressures
                                                        0,      // range: the finger carries it
                                                        touching,
                                                        0);
    if (!hand) return NULL;

    // The field that marks this as the panel's own digitizer rather than an
    // external device. Without it the touch is dropped or read in the wrong
    // coordinate space.
    CBBSetDigitizerField(hand, CBBHIDFieldDigitizerIsDisplayIntegrated, 1);

    IOHIDEventRef finger = IOHIDEventCreateDigitizerFingerEvent(kCFAllocatorDefault,
                                                                timestamp,
                                                                kCBBFingerIdentifier,
                                                                kCBBFingerIdentifier,
                                                                mask,
                                                                (double)point.x,
                                                                (double)point.y,
                                                                0.0,
                                                                0.0,    // tip pressure
                                                                0.0,    // twist
                                                                touching ? 1 : 0,   // range
                                                                touching ? 1 : 0,   // touch
                                                                0);
    if (!finger) {
        CFRelease(hand);
        return NULL;
    }

    // 5 mm is the default the finger constructor uses; written explicitly because
    // a zero radius reads as a hover.
    IOHIDEventSetFloatValue(finger, CBBHIDFieldDigitizerMajorRadius, 5.0);
    IOHIDEventSetFloatValue(finger, CBBHIDFieldDigitizerMinorRadius, 5.0);
    IOHIDEventAppendEvent(hand, finger, 0);
    CFRelease(finger);

    return hand;
}

static void CBBSetDigitizerField(IOHIDEventRef event, uint32_t field, int value) {
    IOHIDEventSetIntegerValue(event, field, value);
    if (CBBSetIntegerWithOptions) {
        CBBSetIntegerWithOptions(event, field, value, kCBBFieldOptions);
    }
}

#pragma mark - Public gestures

- (void)tapAtPoint:(CGPoint)point {
    CGPoint target = CGPointMake(round(point.x), round(point.y));
    // Resolved before the gesture starts, on the caller's thread: the funnel must
    // not change halfway through a tap.
    CBBInjectionFunnel funnel = [self currentFunnel];
    __weak typeof(self) weakSelf = self;
    dispatch_async(_queue, ^{
        CBBTouchInjector *strongSelf = weakSelf;
        if (!strongSelf) return;
        @try {
            if (funnel == CBBInjectionFunnelApp) {
                int sent = 0;
                NSString *bundle = strongSelf->_appBundle;
                [strongSelf beginAppGesture];
                if ([strongSelf postAppEventAtPoint:target phase:CBBTouchPhaseDown bundle:bundle]) sent++;
                usleep(25 * 1000);
                if ([strongSelf postAppEventAtPoint:target phase:CBBTouchPhaseMove bundle:bundle]) sent++;
                usleep(25 * 1000);
                if ([strongSelf postAppEventAtPoint:target phase:CBBTouchPhaseUp bundle:bundle]) sent++;
                if (!strongSelf->_relayReported) {
                    strongSelf->_relayReported = YES;
                    CBBMarkStage([NSString stringWithFormat:
                                  @"injection: queued %d/3 events for %@", sent, bundle]);
                }
                return;
            }

            int32_t deliveryBefore = CBBDeliveryCount;
            [strongSelf deliverTouchAtPoint:target phase:CBBTouchPhaseDown funnel:funnel];
            usleep(25 * 1000);
            // One position update between down and up: pipelines that classify a
            // tap by movement ignore a touch that never moved.
            [strongSelf deliverTouchAtPoint:target phase:CBBTouchPhaseMove funnel:funnel];
            usleep(25 * 1000);
            [strongSelf deliverTouchAtPoint:target phase:CBBTouchPhaseUp funnel:funnel];
            [strongSelf evaluateAfterTapFrom:deliveryBefore];
        } @catch (NSException *exception) {
            CBBMarkStage([NSString stringWithFormat:@"tap threw %@: %@",
                          exception.name, exception.reason]);
        }
    });
}

- (void)swipeFromPoint:(CGPoint)from toPoint:(CGPoint)to duration:(NSTimeInterval)duration {
    NSTimeInterval clamped = MIN(MAX(duration, 0.08), 1.0);
    const NSInteger steps = 14;
    NSTimeInterval stepDelay = clamped / (NSTimeInterval)steps;
    CBBInjectionFunnel funnel = [self currentFunnel];

    __weak typeof(self) weakSelf = self;
    dispatch_async(_queue, ^{
        CBBTouchInjector *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (funnel == CBBInjectionFunnelApp) [strongSelf beginAppGesture];
        @try {
            [strongSelf deliverTouchAtPoint:from phase:CBBTouchPhaseDown funnel:funnel];
            usleep((useconds_t)(stepDelay * 0.6 * 1e6));
            for (NSInteger i = 1; i <= steps; i++) {
                CGFloat t = (CGFloat)i / (CGFloat)steps;
                CGPoint p = CGPointMake(from.x + (to.x - from.x) * t,
                                        from.y + (to.y - from.y) * t);
                [strongSelf deliverTouchAtPoint:p phase:CBBTouchPhaseMove funnel:funnel];
                usleep((useconds_t)(stepDelay * 1e6));
            }
            usleep(20 * 1000);
            [strongSelf deliverTouchAtPoint:to phase:CBBTouchPhaseUp funnel:funnel];
        } @catch (NSException *exception) {
            CBBMarkStage([NSString stringWithFormat:@"swipe threw %@: %@",
                          exception.name, exception.reason]);
        }
    });
}

// The Home button is never the app's: SpringBoard consumes it and switches away,
// so it always takes the in-process funnel even while an app is on screen.
- (void)pressMenu {
    @try {
        CGPoint centre = CGPointMake(self.screenSize.width * 0.5, self.screenSize.height * 0.5);
        uint64_t timestamp = mach_absolute_time();
        // kHIDPage_Consumer / kHIDUsage_Csmr_Menu is the Home button.
        IOHIDEventRef down = IOHIDEventCreateKeyboardEvent(kCFAllocatorDefault, timestamp, 12, 0x40, YES, 0);
        if (down) [self enqueueInProcess:down atPoint:centre];
        usleep(35 * 1000);
        timestamp = mach_absolute_time();
        IOHIDEventRef up = IOHIDEventCreateKeyboardEvent(kCFAllocatorDefault, timestamp, 12, 0x40, NO, 0);
        if (up) [self enqueueInProcess:up atPoint:centre];
    } @catch (NSException *exception) {
        CBBMarkStage([NSString stringWithFormat:@"home press threw %@: %@",
                      exception.name, exception.reason]);
    }
}

- (void)pressHome {
    dispatch_async(_queue, ^{
        [self pressMenu];
    });
}

- (void)pressHomeTwice {
    dispatch_async(_queue, ^{
        [self pressMenu];
        usleep(90 * 1000);
        [self pressMenu];
    });
}

@end
