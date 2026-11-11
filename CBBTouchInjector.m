#import "CBBTouchInjector.h"
#import "CBBCompat.h"
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
// It matters because an app's windows belong to the app's own process: an event
// tagged with a SpringBoard window's context ID is delivered to SpringBoard and
// stops there. On the home screen that route is exactly right; inside an app it
// can never reach the thing you are looking at, which is why taps registered on
// the home screen and nowhere else. Returns nil whenever SpringBoard itself
// owns the screen (home screen, lock screen, app switcher).
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
typedef IOHIDEventSystemClientRef (*CBBCreateSimpleClientFn)(CFAllocatorRef allocator);
typedef void (*CBBRegisterEventCallbackFn)(IOHIDEventSystemClientRef client,
                                           IOHIDEventSystemClientEventCallback callback,
                                           void *target, void *refcon);
typedef void (*CBBScheduleWithRunLoopFn)(IOHIDEventSystemClientRef client,
                                         CFRunLoopRef runloop, CFStringRef mode);
typedef void (*CBBSetDispatchQueueFn)(IOHIDEventSystemClientRef client, dispatch_queue_t queue);
typedef uint32_t (*CBBEventGetTypeFn)(IOHIDEventRef event);
typedef CFArrayRef (*CBBCopyServicesFn)(IOHIDEventSystemClientRef client);
typedef uint64_t (*CBBServiceRegistryIDFn)(IOHIDServiceClientRef service);
typedef CFTypeRef (*CBBServiceCopyPropertyFn)(IOHIDServiceClientRef service, CFStringRef key);

// Resolved at runtime so this dylib still loads if a symbol is ever absent: an
// unresolved import fails the whole dylib at load time, which is
// indistinguishable from "the tweak was never installed".
static CBBSetIntegerWithOptionsFn CBBSetIntegerWithOptions = NULL;
static CBBSetDigitizerInfoFn CBBSetDigitizerInfo = NULL;
static CBBCreateSimpleClientFn CBBCreateSimpleClient = NULL;
static CBBRegisterEventCallbackFn CBBRegisterEventCallback = NULL;
static CBBScheduleWithRunLoopFn CBBScheduleWithRunLoop = NULL;
static CBBSetDispatchQueueFn CBBSetDispatchQueue = NULL;
static CBBEventGetTypeFn CBBEventGetType = NULL;

// Digitizer events that came back through the HID system after we dispatched
// one. Zero here means the event never entered the system at all.
static volatile int32_t CBBLoopbackCount = 0;

// Touches that arrived at -[UIApplication sendEvent:] inside SpringBoard: the
// other end of the funnel. A non-zero delta over a tap window is the tap itself,
// because nothing else touches the screen during a hold-to-click.
static volatile int32_t CBBDeliveryCount = 0;

static void CBBLoopbackCallback(void *target, void *refcon,
                                IOHIDEventSystemClientRef sender, IOHIDEventRef event) {
    if (!event || !CBBEventGetType) return;
    if (CBBEventGetType(event) == CBBHIDEventTypeDigitizer) {
        __sync_fetch_and_add(&CBBLoopbackCount, 1);
    }
}

// backboardd stamps every event it forwards with the registry ID of the HID
// service that produced it, and an event without one is dropped on arrival
// (its log reads "BKSHID: event with no senderID"). That is why a dispatched
// synthetic touch never reached an app while the in-process funnel worked: the
// in-process route never has to satisfy that check. The panel digitizer's
// registry ID is allocated per boot, so it cannot be a constant; it is read
// once from the HID system's own service list.
static uint64_t CBBDigitizerSenderID(void) {
    static uint64_t senderID = 0;
    static BOOL resolved = NO;
    if (resolved) return senderID;
    resolved = YES;

    CBBCopyServicesFn copyServices = (CBBCopyServicesFn)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCopyServices");
    CBBServiceRegistryIDFn registryID = (CBBServiceRegistryIDFn)dlsym(RTLD_DEFAULT, "IOHIDServiceClientGetRegistryID");
    CBBServiceCopyPropertyFn copyProperty = (CBBServiceCopyPropertyFn)dlsym(RTLD_DEFAULT, "IOHIDServiceClientCopyProperty");
    IOHIDEventSystemClientRef client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!client || !copyServices || !registryID) {
        CBBMarkStage(@"injection: HID service list unavailable — dispatched touches cannot be stamped with a sender");
        return 0;
    }

    uint64_t firstID = 0;
    uint64_t panelID = 0;
    NSMutableString *seen = [NSMutableString string];
    CFArrayRef services = copyServices(client);
    if (services) {
        for (CFIndex i = 0; i < CFArrayGetCount(services); i++) {
            IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
            uint64_t serviceID = registryID(service);
            if (!serviceID) continue;
            if (!firstID) firstID = serviceID;

            int page = -1, usage = -1;
            if (copyProperty) {
                CFTypeRef pageRef = copyProperty(service, CFSTR("PrimaryUsagePage"));
                CFTypeRef usageRef = copyProperty(service, CFSTR("PrimaryUsage"));
                if (pageRef && CFGetTypeID(pageRef) == CFNumberGetTypeID()) {
                    CFNumberGetValue((CFNumberRef)pageRef, kCFNumberIntType, &page);
                }
                if (usageRef && CFGetTypeID(usageRef) == CFNumberGetTypeID()) {
                    CFNumberGetValue((CFNumberRef)usageRef, kCFNumberIntType, &usage);
                }
                if (pageRef) CFRelease(pageRef);
                if (usageRef) CFRelease(usageRef);
            }
            [seen appendFormat:@"0x%llx/%d.%d ", serviceID, page, usage];

            // kHIDPage_Digitizer / kHIDUsage_Dig_TouchScreen: the panel itself.
            if (page == 13 && usage == 4 && !panelID) panelID = serviceID;
        }
        CFRelease(services);
    }

    senderID = panelID ? panelID : firstID;
    CBBMarkStage([NSString stringWithFormat:@"injection: HID services %@→ dispatched touches use sender 0x%llx",
                  seen.length ? seen : @"(none) ", senderID]);
    return senderID;
}

static void CBBSetDigitizerField(IOHIDEventRef event, uint32_t field, int value) {
    IOHIDEventSetIntegerValue(event, field, value);
    if (CBBSetIntegerWithOptions) {
        CBBSetIntegerWithOptions(event, field, value, kCBBFieldOptions);
    }
}

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
    // Backboardd round trip, for the case where the in-process funnel is not
    // wired up on a given build.
    CBBInjectionFunnelDispatch = 1,
};

typedef NS_ENUM(NSInteger, CBBTouchPhase) {
    CBBTouchPhaseDown = 0,
    CBBTouchPhaseMove = 1,
    CBBTouchPhaseUp = 2,
};

@interface CBBTouchInjector () {
    IOHIDEventSystemClientRef _monitor;
    CBBInjectionFunnel _funnel;
    BOOL _funnelReported;
    BOOL _funnelSwitched;
    BOOL _contextIdWarned;
    BOOL _appFunnelReported;
    BOOL _dispatchReported;
}
@end

@implementation CBBTouchInjector {
    dispatch_queue_t _queue;
    IOHIDEventSystemClientRef _client;
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
        _funnel = CBBInjectionFunnelInProcess;
        CBBSetIntegerWithOptions = (CBBSetIntegerWithOptionsFn)dlsym(RTLD_DEFAULT,
                                                                     "IOHIDEventSetIntegerValueWithOptions");
        CBBSetDigitizerInfo = (CBBSetDigitizerInfoFn)dlsym(RTLD_DEFAULT,
                                                           "BKSHIDEventSetDigitizerInfo");
        CBBCreateSimpleClient = (CBBCreateSimpleClientFn)dlsym(RTLD_DEFAULT,
                                                               "IOHIDEventSystemClientCreateSimpleClient");
        CBBRegisterEventCallback = (CBBRegisterEventCallbackFn)dlsym(RTLD_DEFAULT,
                                                                     "IOHIDEventSystemClientRegisterEventCallback");
        CBBScheduleWithRunLoop = (CBBScheduleWithRunLoopFn)dlsym(RTLD_DEFAULT,
                                                                 "IOHIDEventSystemClientScheduleWithRunLoop");
        CBBSetDispatchQueue = (CBBSetDispatchQueueFn)dlsym(RTLD_DEFAULT,
                                                           "IOHIDEventSystemClientSetDispatchQueue");
        CBBEventGetType = (CBBEventGetTypeFn)dlsym(RTLD_DEFAULT, "IOHIDEventGetType");
        _available = YES;
        [self installDeliveryProbe];
        [self startLoopbackMonitor];
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

- (void)startLoopbackMonitor {
    if (!CBBCreateSimpleClient || !CBBRegisterEventCallback || !CBBScheduleWithRunLoop || !CBBEventGetType) {
        CBBMarkStage(@"injection loopback: monitor symbols absent on this build");
        return;
    }
    @try {
        _monitor = CBBCreateSimpleClient(kCFAllocatorDefault);
        if (!_monitor) {
            CBBMarkStage(@"injection loopback: no monitor client");
            return;
        }
        CBBRegisterEventCallback(_monitor, CBBLoopbackCallback, NULL, NULL);
        CBBScheduleWithRunLoop(_monitor, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    } @catch (NSException *exception) {
        _monitor = NULL;
        CBBMarkStage([NSString stringWithFormat:@"injection loopback unavailable: %@", exception.reason]);
    }
}

// The client that sends events has to exist *and* be attached to the HID system
// before anything it dispatches goes anywhere: dispatching on an unscheduled
// client is a silent no-op.
- (IOHIDEventSystemClientRef)dispatchClient {
    if (_client) return _client;
    _client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!_client) {
        CBBMarkStage(@"injection: no HID client, event dropped");
        return NULL;
    }
    if (CBBScheduleWithRunLoop) {
        CBBScheduleWithRunLoop(_client, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    }
    if (CBBSetDispatchQueue) {
        CBBSetDispatchQueue(_client, dispatch_get_main_queue());
    }
    CBBMarkStage([NSString stringWithFormat:@"injection: HID dispatch client ready (%@)",
                  CBBScheduleWithRunLoop ? @"scheduled on the main run loop" : @"NOT scheduled"]);
    return _client;
}

- (void)discardDispatchClient {
    if (!_client) return;
    CFRelease(_client);
    _client = NULL;
    CBBMarkStage(@"injection: dispatch client discarded, the next tap makes a fresh one");
}

- (CGSize)screenSize {
    return CBBNativeScreenSize();
}

- (BOOL)available {
    return _available;
}

#pragma mark - Delivery

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

// Chosen per tap, not once: the phone alternates between the home screen and
// apps, and the right answer is different in each.
- (CBBInjectionFunnel)currentFunnel {
    NSString *bundle = CBBForegroundAppBundleIdentifier();
    if (bundle) {
        if (!_appFunnelReported) {
            _appFunnelReported = YES;
            CBBMarkStage([NSString stringWithFormat:
                          @"injection: %@ is on screen, taps go through the HID system (an app's windows are in another process)",
                          bundle]);
        }
        return CBBInjectionFunnelDispatch;
    }
    return _funnel;
}

- (void)deliverEvent:(IOHIDEventRef)event atPoint:(CGPoint)point funnel:(CBBInjectionFunnel)funnel {
    @try {
        if (funnel == CBBInjectionFunnelDispatch) {
            IOHIDEventSystemClientRef client = [self dispatchClient];
            // Only touches carry the panel's sender: the Home button is
            // SpringBoard's own business and uses the in-process funnel, where
            // no sender is involved.
            if (client && CBBEventGetType && CBBEventGetType(event) == CBBHIDEventTypeDigitizer) {
                uint64_t sender = CBBDigitizerSenderID();
                if (sender) IOHIDEventSetSenderID(event, sender);
            }
            if (client) IOHIDEventSystemClientDispatchEvent(client, event);
        } else {
            [self enqueueInProcess:event atPoint:point];
        }
    } @catch (NSException *exception) {
        CBBMarkStage([NSString stringWithFormat:@"injection threw %@: %@",
                      exception.name, exception.reason]);
    }
}

// A tap through the in-process funnel is judged from the receiving end: did a
// touch actually reach SpringBoard's event pipeline. Nothing there means the
// in-process route is not wired up on this build, and the backboardd route is
// tried instead for SpringBoard-owned screens from then on.
- (void)evaluateAfterTapFrom:(int32_t)loopBefore delivered:(int32_t)deliveryBefore funnel:(CBBInjectionFunnel)funnel {
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), _queue, ^{
        CBBTouchInjector *strongSelf = weakSelf;
        if (!strongSelf) return;
        int32_t loopSeen = CBBLoopbackCount - loopBefore;
        int32_t delivered = CBBDeliveryCount - deliveryBefore;

        if (funnel == CBBInjectionFunnelDispatch) {
            // Dispatched into the HID system, which routes by the window server
            // rather than by a context ID: an app's touches never pass
            // SpringBoard's -sendEvent:, so a zero delivery count here is normal
            // and is not evidence that the tap was lost.
            if (strongSelf->_dispatchReported) return;
            strongSelf->_dispatchReported = YES;
            CBBMarkStage([NSString stringWithFormat:
                          @"injection: system funnel used (%d digitizer echo(es), %d SpringBoard touch event(s)) — backboardd picks the target",
                          (int)loopSeen, (int)delivered]);
            return;
        }

        if (strongSelf->_funnel == CBBInjectionFunnelInProcess) {
            if (delivered > 0) {
                if (!strongSelf->_funnelReported) {
                    strongSelf->_funnelReported = YES;
                    CBBMarkStage([NSString stringWithFormat:
                                  @"injection: in-process funnel delivers (%d touch event(s) reached SpringBoard)",
                                  (int)delivered]);
                }
                return;
            }
            if (!strongSelf->_funnelSwitched) {
                strongSelf->_funnelSwitched = YES;
                strongSelf->_funnel = CBBInjectionFunnelDispatch;
                CBBMarkStage(@"injection: in-process funnel delivered nothing, switched to the system HID funnel");
            } else if (!strongSelf->_funnelReported) {
                strongSelf->_funnelReported = YES;
                CBBMarkStage(@"injection: neither funnel delivered a touch — SpringBoard saw nothing at all");
            }
        }
    });
}

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

#pragma mark - Public gestures

- (void)tapAtPoint:(CGPoint)point {
    CGPoint target = CGPointMake(round(point.x), round(point.y));
    // Resolved before the gesture starts, on the caller's thread: the funnel must
    // not change halfway through a tap.
    CBBInjectionFunnel funnel = [self currentFunnel];
    dispatch_async(_queue, ^{
        @try {
            int32_t loopBefore = CBBLoopbackCount;
            int32_t deliveryBefore = CBBDeliveryCount;
            [self deliverEvent:[self newTouchEventAtPoint:target phase:CBBTouchPhaseDown] atPoint:target funnel:funnel];
            usleep(25 * 1000);
            // One position update between down and up: pipelines that classify a
            // tap by movement ignore a touch that never moved.
            [self deliverEvent:[self newTouchEventAtPoint:target phase:CBBTouchPhaseMove] atPoint:target funnel:funnel];
            usleep(25 * 1000);
            [self deliverEvent:[self newTouchEventAtPoint:target phase:CBBTouchPhaseUp] atPoint:target funnel:funnel];
            [self evaluateAfterTapFrom:loopBefore delivered:deliveryBefore funnel:funnel];
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

    dispatch_async(_queue, ^{
        @try {
            [self deliverEvent:[self newTouchEventAtPoint:from phase:CBBTouchPhaseDown] atPoint:from funnel:funnel];
            usleep((useconds_t)(stepDelay * 0.6 * 1e6));
            for (NSInteger i = 1; i <= steps; i++) {
                CGFloat t = (CGFloat)i / (CGFloat)steps;
                CGPoint p = CGPointMake(from.x + (to.x - from.x) * t,
                                        from.y + (to.y - from.y) * t);
                [self deliverEvent:[self newTouchEventAtPoint:p phase:CBBTouchPhaseMove] atPoint:p funnel:funnel];
                usleep((useconds_t)(stepDelay * 1e6));
            }
            usleep(20 * 1000);
            [self deliverEvent:[self newTouchEventAtPoint:to phase:CBBTouchPhaseUp] atPoint:to funnel:funnel];
        } @catch (NSException *exception) {
            CBBMarkStage([NSString stringWithFormat:@"swipe threw %@: %@",
                          exception.name, exception.reason]);
        }
    });
}

- (void)pressMenuWithFunnel:(CBBInjectionFunnel)funnel {
    @try {
        uint64_t timestamp = mach_absolute_time();
        // kHIDPage_Consumer / kHIDUsage_Csmr_Menu is the Home button.
        IOHIDEventRef down = IOHIDEventCreateKeyboardEvent(kCFAllocatorDefault, timestamp, 12, 0x40, YES, 0);
        [self deliverEvent:down atPoint:CGPointMake(self.screenSize.width * 0.5,
                                                    self.screenSize.height * 0.5)
                   funnel:funnel];
        if (down) CFRelease(down);
        usleep(35 * 1000);
        timestamp = mach_absolute_time();
        IOHIDEventRef up = IOHIDEventCreateKeyboardEvent(kCFAllocatorDefault, timestamp, 12, 0x40, NO, 0);
        [self deliverEvent:up atPoint:CGPointMake(self.screenSize.width * 0.5,
                                                  self.screenSize.height * 0.5)
                   funnel:funnel];
        if (up) CFRelease(up);
    } @catch (NSException *exception) {
        CBBMarkStage([NSString stringWithFormat:@"home press threw %@: %@",
                      exception.name, exception.reason]);
    }
}

// The Home button is never the app's: SpringBoard consumes it and switches
// away, so it always takes the in-process funnel even while an app is on
// screen. Dispatching it into the HID system would only introduce the sender-ID
// check the keyboard event does not satisfy.
- (void)pressHome {
    dispatch_async(_queue, ^{
        [self pressMenuWithFunnel:CBBInjectionFunnelInProcess];
    });
}

- (void)pressHomeTwice {
    dispatch_async(_queue, ^{
        [self pressMenuWithFunnel:CBBInjectionFunnelInProcess];
        usleep(90 * 1000);
        [self pressMenuWithFunnel:CBBInjectionFunnelInProcess];
    });
}

@end
