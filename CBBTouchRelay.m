//
//  CBBTouchRelay.m
//  CardboardOS
//
//  Loaded into apps, not into SpringBoard. It exists because of a hard line in
//  iOS: an app's windows belong to the app's process, and a touch has to name
//  the window context it is for. SpringBoard can only name its own, so a tap
//  aimed at an app cannot be delivered from there - not with a context ID, and
//  not by dispatching into the HID system either (measured: the event reaches
//  the HID system and no client ever receives it).
//
//  So the tap is built where the window is. This relay watches a queue file that
//  SpringBoard appends to, picks out the lines addressed to its own pid, and
//  delivers them with exactly the recipe that already works on this device:
//  tag the digitizer event with the receiving window's context ID and hand it to
//  UIApplication's _enqueueHIDEvent:. Apple's own synthetic-touch code
//  (_WKTouchEventGenerator in WebKit) does the same thing from inside a normal
//  app process.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <mach/mach_time.h>
#import <string.h>
#import <objc/message.h>
#import <sys/stat.h>
#import <unistd.h>

#import "CBBInjectionPort.h"

#pragma mark - IOKit

typedef struct __IOHIDEvent *CBBEventRef;

extern CBBEventRef IOHIDEventCreateDigitizerEvent(CFAllocatorRef allocator,
                                                  uint64_t timeStamp,
                                                  uint32_t transducerType,
                                                  uint32_t index,
                                                  uint32_t identity,
                                                  uint32_t eventMask,
                                                  uint32_t buttonMask,
                                                  double x, double y, double z,
                                                  double tipPressure,
                                                  double barrelPressure,
                                                  Boolean range,
                                                  Boolean touch,
                                                  uint32_t options);

extern CBBEventRef IOHIDEventCreateDigitizerFingerEvent(CFAllocatorRef allocator,
                                                        uint64_t timeStamp,
                                                        uint32_t index,
                                                        uint32_t identity,
                                                        uint32_t eventMask,
                                                        double x, double y, double z,
                                                        double tipPressure,
                                                        double twist,
                                                        Boolean range,
                                                        Boolean touch,
                                                        uint32_t options);

extern void IOHIDEventAppendEvent(CBBEventRef parent, CBBEventRef child, uint32_t options);
extern void IOHIDEventSetIntegerValue(CBBEventRef event, uint32_t field, int64_t value);
extern void IOHIDEventSetFloatValue(CBBEventRef event, uint32_t field, double value);

typedef void (*CBBSetIntegerOptionsFn)(CBBEventRef, uint32_t, int, uint32_t);
typedef void (*CBBSetDigitizerInfoFn)(CBBEventRef, uint32_t, uint8_t, uint8_t, CFStringRef, CFTimeInterval, float);
typedef void (*CBBRegisterNotifyFn)(const char *, int *, dispatch_queue_t, void (^)(int));

static CBBSetIntegerOptionsFn CBBRelaySetIntegerOptions = NULL;
static CBBSetDigitizerInfoFn CBBRelaySetDigitizerInfo = NULL;

enum {
    CBBRelayFieldDigitizerIsDisplayIntegrated = 0x000b0019,
    CBBRelayFieldDigitizerMajorRadius = 0x000b0014,
    CBBRelayFieldDigitizerMinorRadius = 0x000b0015,
    CBBRelayTransducerTypeHand = 3,
    CBBRelayEventTouch = 2,
    CBBRelayEventPosition = 4,
    CBBRelayEventAttribute = 8,
    CBBRelayEventIdentity = 32,
    CBBRelayFieldOptions = 0xF0000000u,
};

#pragma mark - Breadcrumbs

static void CBBRelayStage(NSString *stage) {
    if (!stage) return;
    static NSString *const path = @"/var/mobile/Library/Preferences/com.buffy.cardboardos.stages";
    NSString *line = [NSString stringWithFormat:@"%@ relay: %@\n", [NSDate date], stage];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    @synchronized(path) {
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        @try {
            if (handle) {
                [handle seekToEndOfFile];
                [handle writeData:data];
                [handle closeFile];
            } else {
                [data writeToFile:path atomically:YES];
            }
        } @catch (NSException *exception) {
            // Never let a breadcrumb be the reason an app misbehaves.
        }
    }
}

#pragma mark - Injection

static UIWindow *CBBRelayWindowAtPoint(CGPoint point) {
    UIWindow *best = nil;
    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        if (window.hidden || window.alpha < 0.01 || !window.userInteractionEnabled) continue;
        CGPoint local = point;
        if ([window respondsToSelector:@selector(convertPoint:fromCoordinateSpace:)]) {
            local = [window convertPoint:point fromCoordinateSpace:[UIScreen mainScreen].fixedCoordinateSpace];
        }
        if (!CGRectContainsPoint(window.bounds, local)) continue;
        if (!best || window.windowLevel > best.windowLevel) best = window;
    }
    return best ?: [UIApplication sharedApplication].keyWindow;
}

// Same event shape as the SpringBoard half, and the same tag: the receiving
// window's context ID is what makes it land on that window instead of being
// dropped for having no destination.
static void CBBRelayInject(double x, double y, int phase) {
    UIApplication *app = [UIApplication sharedApplication];
    if (!app) return;
    CGPoint point = CGPointMake(x, y);
    UIWindow *window = CBBRelayWindowAtPoint(point);
    if (!window) return;

    uint32_t contextId = 0;
    SEL contextSelector = NSSelectorFromString(@"_contextId");
    if ([window respondsToSelector:contextSelector]) {
        contextId = ((uint32_t (*)(id, SEL))objc_msgSend)(window, contextSelector);
    }

    BOOL touching = (phase != CBBInjectionPhaseUp);
    uint32_t mask;
    switch (phase) {
        case CBBInjectionPhaseDown:
            mask = CBBRelayEventTouch | CBBRelayEventIdentity;
            break;
        case CBBInjectionPhaseMove:
            mask = CBBRelayEventPosition | CBBRelayEventAttribute;
            break;
        default:
            mask = CBBRelayEventTouch | CBBRelayEventIdentity;
            break;
    }

    uint64_t timestamp = mach_absolute_time();
    CBBEventRef hand = IOHIDEventCreateDigitizerEvent(kCFAllocatorDefault, timestamp,
                                                      CBBRelayTransducerTypeHand,
                                                      0, 0, mask, 0,
                                                      0, 0, 0, 0, 0,
                                                      0, touching, 0);
    if (!hand) return;

    if (CBBRelaySetIntegerOptions) {
        CBBRelaySetIntegerOptions(hand, CBBRelayFieldDigitizerIsDisplayIntegrated, 1, CBBRelayFieldOptions);
    }
    IOHIDEventSetIntegerValue(hand, CBBRelayFieldDigitizerIsDisplayIntegrated, 1);

    CBBEventRef finger = IOHIDEventCreateDigitizerFingerEvent(kCFAllocatorDefault, timestamp,
                                                              2, 2, mask,
                                                              x, y, 0, 0, 0,
                                                              touching ? 1 : 0,
                                                              touching ? 1 : 0,
                                                              0);
    if (finger) {
        IOHIDEventSetFloatValue(finger, CBBRelayFieldDigitizerMajorRadius, 5.0);
        IOHIDEventSetFloatValue(finger, CBBRelayFieldDigitizerMinorRadius, 5.0);
        IOHIDEventAppendEvent(hand, finger, 0);
        CFRelease(finger);
    }

    if (contextId && CBBRelaySetDigitizerInfo) {
        CBBRelaySetDigitizerInfo(hand, contextId, 0, 0, NULL, 0, 0);
    }

    SEL enqueue = NSSelectorFromString(@"_enqueueHIDEvent:");
    BOOL canEnqueue = [app respondsToSelector:enqueue];
    // Said once, from inside the app: which window the tap was aimed at, whether
    // it had a context ID, and whether the hand-off exists at all. Without this
    // a silent failure here is indistinguishable from a tap that never arrived.
    static BOOL reported = NO;
    if (!reported) {
        reported = YES;
        CBBRelayStage([NSString stringWithFormat:@"inject: %@ context %u, enqueue %@, digitizer-info %@",
                       NSStringFromClass([window class]), contextId,
                       canEnqueue ? @"yes" : @"absent",
                       CBBRelaySetDigitizerInfo ? @"available" : @"absent"]);
    }
    if (canEnqueue) {
        ((void (*)(id, SEL, id))objc_msgSend)(app, enqueue, (__bridge id)hand);
    }
}

#pragma mark - The queue

static off_t CBBRelayOffset = 0;
static ino_t CBBRelayInode = 0;
static volatile int32_t CBBRelayInjected = 0;
// Who this process is, as the queue spells it. Set once at load, before the
// notification can fire.
static char CBBRelayBundleId[128];

static void CBBRelayDrain(void) {
    static char buffer[4096];
    int fd = open(CBB_RELAY_QUEUE_PATH, O_RDONLY);
    if (fd < 0) return;

    struct stat info;
    off_t offset = CBBRelayOffset;
    ssize_t got = -1;
    if (fstat(fd, &info) == 0) {
        if (info.st_ino != CBBRelayInode) {
            CBBRelayInode = info.st_ino;
            offset = 0;
        }
        if (info.st_size < offset) offset = 0;
        if (info.st_size > offset && lseek(fd, offset, SEEK_SET) == offset) {
            got = read(fd, buffer, sizeof(buffer) - 1);
        }
    }
    close(fd);

    if (got <= 0) {
        CBBRelayOffset = offset;
        return;
    }
    buffer[got] = '\0';

    off_t consumed = 0;
    char *cursor = buffer;
    char *newline = NULL;
    while ((newline = strchr(cursor, '\n')) != NULL) {
        *newline = '\0';
        char target[128] = {0};
        int phase = 0;
        double x = 0, y = 0;
        if (sscanf(cursor, "%127s %d %lf %lf", target, &phase, &x, &y) == 4 &&
            CBBRelayBundleId[0] && strcmp(target, CBBRelayBundleId) == 0) {
            // UIKit work on the main thread, like Apple's own generator.
            dispatch_async(dispatch_get_main_queue(), ^{
                @try {
                    CBBRelayInject(x, y, phase);
                } @catch (NSException *exception) {
                    CBBRelayStage([NSString stringWithFormat:@"injection threw %@: %@",
                                   exception.name, exception.reason]);
                }
            });
            if (__sync_add_and_fetch(&CBBRelayInjected, 1) == 1) {
                CBBRelayStage([NSString stringWithFormat:@"first tap taken at (%.0f,%.0f)", x, y]);
            }
        }
        consumed = (off_t)((newline + 1) - buffer);
        cursor = newline + 1;
    }
    CBBRelayOffset = offset + consumed;
}

#pragma mark - Load


__attribute__((constructor)) static void CBBTouchRelayLoad(void) {
    @autoreleasepool {
        // dyld runs constructors before UIKit is guaranteed to be up in some
        // processes, so anything that needs UIApplication waits for it.
        Class applicationClass = NSClassFromString(@"UIApplication");
        NSString *bundle = [NSBundle mainBundle].bundleIdentifier;
        if (!applicationClass || bundle.length == 0) return;

        CBBRelayStage([NSString stringWithFormat:@"loaded in %@ (pid %d)", bundle, (int)getpid()]);

        // SpringBoard already has its own funnel and must not take its own
        // queued taps through this path.
        if ([bundle isEqualToString:@"com.apple.springboard"]) return;

        strncpy(CBBRelayBundleId, bundle.UTF8String, sizeof(CBBRelayBundleId) - 1);

        CBBRelaySetIntegerOptions = (CBBSetIntegerOptionsFn)dlsym(RTLD_DEFAULT, "IOHIDEventSetIntegerValueWithOptions");
        CBBRelaySetDigitizerInfo = (CBBSetDigitizerInfoFn)dlsym(RTLD_DEFAULT, "BKSHIDEventSetDigitizerInfo");

        void *notify = dlopen("/usr/lib/libnotify.dylib", RTLD_LAZY);
        if (!notify) notify = dlopen("/usr/lib/system/libnotify.dylib", RTLD_LAZY);
        CBBRegisterNotifyFn registerNotify = (CBBRegisterNotifyFn)dlsym(notify ? notify : RTLD_DEFAULT,
                                                                        "notify_register_dispatch");
        if (!registerNotify) {
            CBBRelayStage(@"no libnotify: taps cannot arrive");
            return;
        }

        // A wake-up per event, not a poll: every app on the phone loads this
        // dylib, and none of them should be reading a file 100 times a second.
        static int token = 0;
        registerNotify(CBB_RELAY_NOTIFY_NAME, &token, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0),
                       ^(int tokenValue) {
                           (void)tokenValue;
                           CBBRelayDrain();
                       });
        // A tap can be written while the app is still launching, before the
        // notification has anywhere to land: read the queue once now so that tap
        // is not stranded.
        CBBRelayDrain();
        CBBRelayStage(@"listening for taps");
    }
}
