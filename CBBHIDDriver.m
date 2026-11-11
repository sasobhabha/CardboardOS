//
//  CBBHIDDriver.m
//  CardboardOS
//
//  The half of the tweak that runs inside backboardd.
//
//  On the home screen a tap is injected from SpringBoard, tagged with the
//  receiving window's context ID. That recipe cannot reach an app: an app's
//  windows belong to the app's own process and SpringBoard holds no context ID
//  for them. Handing the event to the HID system from SpringBoard does not work
//  either - the dispatched event arrives with no sender and the stage log shows
//  "0 digitizer echo(es)", meaning it never entered the system at all.
//
//  backboardd is where the display and the touch pipeline actually live, so
//  that is where a synthetic touch has to be born. This dylib reads the queue
//  SpringBoard writes, builds the same hand + finger event Apple's own
//  synthetic-touch code builds, and feeds it to the HID system from inside the
//  process that owns it. From there it should be routed exactly like a finger on
//  the glass: to whichever app is in front, with no context ID to work out.
//
//  Whether it actually is routed depends on details that cannot be read out of a
//  header: which kind of IOHIDEventSystemClient may send, and what sender ID
//  backboardd demands. So both are selectable, auto-tried in turn, and can be
//  forced from the queue line (see CBBInjectionPort.h) while diagnosing from the
//  device itself.
//
//  Foundation-only on purpose. No UIKit, no Metal, no graphics of any kind: this
//  loads into a daemon the whole phone depends on, and the whole point is to add
//  nothing to it but an event source.
//

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <mach/mach_time.h>
#import <sys/stat.h>
#import <unistd.h>

#import "CBBInjectionPort.h"

#pragma mark - Private IOKit surface

typedef struct __IOHIDEvent *CBBEventRef;
typedef struct __IOHIDEventSystemClient *CBBSystemClientRef;
typedef struct __IOHIDServiceClient *CBBServiceRef;

typedef CBBEventRef (*CBBCreateDigitizerEventFn)(CFAllocatorRef, uint64_t, uint32_t, uint32_t,
                                                 uint32_t, uint32_t, uint32_t, double, double,
                                                 double, double, double, Boolean, Boolean, uint32_t);
typedef CBBEventRef (*CBBCreateFingerEventFn)(CFAllocatorRef, uint64_t, uint32_t, uint32_t,
                                              uint32_t, double, double, double, double, double,
                                              Boolean, Boolean, uint32_t);
typedef void (*CBBAppendEventFn)(CBBEventRef, CBBEventRef, uint32_t);
typedef void (*CBBSetIntegerFn)(CBBEventRef, uint32_t, int64_t);
typedef void (*CBBSetIntegerOptionsFn)(CBBEventRef, uint32_t, int, uint32_t);
typedef void (*CBBSetFloatFn)(CBBEventRef, uint32_t, double);
typedef void (*CBBSetSenderFn)(CBBEventRef, uint64_t);
typedef CBBSystemClientRef (*CBBCreateClientFn)(CFAllocatorRef);
typedef CBBSystemClientRef (*CBBCreateClientWithTypeFn)(CFAllocatorRef, int, CFDictionaryRef);
typedef CBBSystemClientRef (*CBBCreateSimpleClientFn)(CFAllocatorRef);
typedef void (*CBBDispatchEventFn)(CBBSystemClientRef, CBBEventRef);
typedef CFArrayRef (*CBBCopyServicesFn)(CBBSystemClientRef);
typedef uint64_t (*CBBRegistryIDFn)(CBBServiceRef);
typedef CFTypeRef (*CBBCopyPropertyFn)(CBBServiceRef, CFStringRef);
typedef void (*CBBRegisterCallbackFn)(CBBSystemClientRef, void *, void *, void *);
typedef void (*CBBScheduleWithRunLoopFn)(CBBSystemClientRef, CFRunLoopRef, CFStringRef);
typedef uint32_t (*CBBEventGetTypeFn)(CBBEventRef);

static CBBCreateDigitizerEventFn CBBDriverCreateDigitizer = NULL;
static CBBCreateFingerEventFn CBBDriverCreateFinger = NULL;
static CBBAppendEventFn CBBDriverAppend = NULL;
static CBBSetIntegerFn CBBDriverSetInteger = NULL;
static CBBSetIntegerOptionsFn CBBDriverSetIntegerOptions = NULL;
static CBBSetFloatFn CBBDriverSetFloat = NULL;
static CBBSetSenderFn CBBDriverSetSender = NULL;
static CBBCreateClientFn CBBDriverCreateClient = NULL;
static CBBCreateClientWithTypeFn CBBDriverCreateClientWithType = NULL;
static CBBCreateSimpleClientFn CBBDriverCreateSimpleClient = NULL;
static CBBDispatchEventFn CBBDriverDispatch = NULL;
static CBBCopyServicesFn CBBDriverCopyServices = NULL;
static CBBRegistryIDFn CBBDriverRegistryID = NULL;
static CBBCopyPropertyFn CBBDriverCopyProperty = NULL;
static CBBRegisterCallbackFn CBBDriverRegisterCallback = NULL;
static CBBScheduleWithRunLoopFn CBBDriverSchedule = NULL;
static CBBEventGetTypeFn CBBDriverEventGetType = NULL;

// Same fields as the SpringBoard side. kIOHIDEventFieldDigitizerIsDisplayIntegrated
// marks the event as the panel's own digitizer rather than an external device;
// without it the touch is dropped or read in the wrong coordinate space.
enum {
    CBBDriverDigitizerIsDisplayIntegrated = 0x000b0019,
    CBBDriverDigitizerMajorRadius = 0x000b0014,
    CBBDriverDigitizerMinorRadius = 0x000b0015,
    CBBDriverTransducerTypeHand = 3,
    CBBDriverDigitizerEventTouch = 2,
    CBBDriverDigitizerEventPosition = 4,
    CBBDriverDigitizerEventAttribute = 8,
    CBBDriverDigitizerEventIdentity = 32,
    CBBDriverEventTypeDigitizer = 11,
    CBBDriverFieldOptions = 0xF0000000u,
};

// Client kinds worth trying as the sender. 0 is the default client, 2 the
// administrator client (the one with permission to inject), 1 a monitor (it
// sees everything, which makes it both a candidate sender and the measuring
// instrument), 3 a simple client (what a service consumer gets).
enum {
    CBBDriverClientDefault = 0,
    CBBDriverClientMonitor = 1,
    CBBDriverClientAdministrator = 2,
    CBBDriverClientSimple = 3,
    CBBDriverClientTypes = 4,
};

enum {
    CBBDriverSenderPanel = 0,        // the panel digitizer's own registry ID
    CBBDriverSenderPublished = 1,    // 0x8000000812345678, as published by ios-autotouch
    CBBDriverSenderNone = 2,         // no sender at all
    CBBDriverSenderStrategies = 3,
};

static CBBSystemClientRef CBBDriverClients[CBBDriverClientTypes];
static CBBSystemClientRef CBBDriverMonitors[CBBDriverClientTypes];
static volatile int32_t CBBDriverMonitorCounts[CBBDriverClientTypes];

#pragma mark - Breadcrumbs

static NSLock *CBBDriverStageLock = nil;

// Same file as CBBMarkStage, written here rather than shared so this dylib does
// not have to compile against CBBCompat.h and its UIKit declarations.
static void CBBDriverStage(NSString *stage) {
    if (!stage) return;
    static NSString *const path = @"/var/mobile/Library/Preferences/com.buffy.cardboardos.stages";
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], stage];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    [CBBDriverStageLock lock];
    @try {
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        if (handle) {
            [handle seekToEndOfFile];
            [handle writeData:data];
            [handle closeFile];
        } else {
            [data writeToFile:path atomically:YES];
        }
    } @catch (NSException *exception) {
        // A breadcrumb must never be the reason a daemon falls over.
    } @finally {
        [CBBDriverStageLock unlock];
    }
}

#pragma mark - State

static uint64_t CBBDriverSenderID = 0;
static volatile int32_t CBBDriverLoopback = 0;
static volatile int32_t CBBDriverInjected = 0;
static volatile int32_t CBBDriverReported = 0;
static off_t CBBDriverOffset = 0;
// Which file the offset refers to. SpringBoard writes the queue atomically, so
// a new file has a new inode even when its first bytes look like the old one's;
// without this, a same-length gesture would look like "nothing new" and be
// silently skipped.
static ino_t CBBDriverQueueInode = 0;

// Everything that passes through the HID system arrives here. That echo is the
// measurement that matters: a real digitizer event comes back through this
// callback, so an injected one that does not was dropped on the way in. The
// target pointer carries which monitor client fired.
static void CBBDriverLoopbackCallback(void *target, void *refcon, CBBSystemClientRef sender, CBBEventRef event) {
    (void)refcon;
    (void)sender;
    if (!event || !CBBDriverEventGetType) return;
    if (CBBDriverEventGetType(event) != CBBDriverEventTypeDigitizer) return;
    int index = (int)(intptr_t)target;
    if (index >= 0 && index < CBBDriverClientTypes) {
        __sync_fetch_and_add(&CBBDriverMonitorCounts[index], 1);
    }
    __sync_fetch_and_add(&CBBDriverLoopback, 1);
}

static CBBSystemClientRef CBBDriverClientForType(int type) {
    if (type < 0 || type >= CBBDriverClientTypes) type = CBBDriverClientDefault;
    if (CBBDriverClients[type]) return CBBDriverClients[type];

    CBBSystemClientRef client = NULL;
    switch (type) {
        case CBBDriverClientSimple:
            client = CBBDriverCreateSimpleClient ? CBBDriverCreateSimpleClient(kCFAllocatorDefault) : NULL;
            break;
        case CBBDriverClientDefault:
            client = CBBDriverCreateClient ? CBBDriverCreateClient(kCFAllocatorDefault) : NULL;
            break;
        default:
            client = CBBDriverCreateClientWithType ? CBBDriverCreateClientWithType(kCFAllocatorDefault, type, NULL) : NULL;
            break;
    }
    if (!client) return NULL;
    if (CBBDriverSchedule) {
        CBBDriverSchedule(client, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    }
    CBBDriverClients[type] = client;
    return client;
}

// Registry ID of the panel's own digitizer service. backboardd stamps every
// event it forwards with the sender it came from, and the panel's ID is
// allocated at boot, so it cannot be a constant.
static uint64_t CBBDriverResolveSender(void) {
    if (CBBDriverSenderID) return CBBDriverSenderID;
    uint64_t panel = 0;
    uint64_t first = 0;
    CFIndex count = 0;
    CBBSystemClientRef client = CBBDriverClientForType(CBBDriverClientDefault);
    if (client && CBBDriverCopyServices && CBBDriverRegistryID) {
        CFArrayRef services = CBBDriverCopyServices(client);
        if (services) {
            count = CFArrayGetCount(services);
            for (CFIndex i = 0; i < count; i++) {
                CBBServiceRef service = (CBBServiceRef)CFArrayGetValueAtIndex(services, i);
                uint64_t registry = CBBDriverRegistryID(service);
                if (!registry) continue;
                if (!first) first = registry;
                int page = -1, usage = -1;
                if (CBBDriverCopyProperty) {
                    CFTypeRef pageRef = CBBDriverCopyProperty(service, CFSTR("PrimaryUsagePage"));
                    CFTypeRef usageRef = CBBDriverCopyProperty(service, CFSTR("PrimaryUsage"));
                    if (pageRef && CFGetTypeID(pageRef) == CFNumberGetTypeID()) {
                        CFNumberGetValue((CFNumberRef)pageRef, kCFNumberIntType, &page);
                    }
                    if (usageRef && CFGetTypeID(usageRef) == CFNumberGetTypeID()) {
                        CFNumberGetValue((CFNumberRef)usageRef, kCFNumberIntType, &usage);
                    }
                    if (pageRef) CFRelease(pageRef);
                    if (usageRef) CFRelease(usageRef);
                }
                // kHIDPage_Digitizer / kHIDUsage_Dig_TouchScreen: the glass.
                if (page == 13 && usage == 4 && !panel) {
                    panel = registry;
                    break;
                }
            }
            CFRelease(services);
        }
    }
    CBBDriverSenderID = panel ? panel : (first ? first : 0x8000000812345678ULL);
    CBBDriverStage([NSString stringWithFormat:@"driver: %ld HID service(s), panel sender 0x%llx%@",
                    (long)count, CBBDriverSenderID,
                    panel ? @"" : @" (no 13.4 service)"]);
    return CBBDriverSenderID;
}

static uint64_t CBBDriverSenderForStrategy(int strategy) {
    switch (strategy) {
        case CBBDriverSenderPublished:
            return 0x8000000812345678ULL;
        case CBBDriverSenderNone:
            return 0;
        default:
            return CBBDriverResolveSender();
    }
}

#pragma mark - The event itself

static void CBBDriverInject(double x, double y, int phase, int clientType, int senderStrategy) {
    if (!CBBDriverCreateDigitizer || !CBBDriverCreateFinger || !CBBDriverAppend) return;
    CBBSystemClientRef client = CBBDriverClientForType(clientType);
    if (!client || !CBBDriverDispatch) return;

    BOOL touching = (phase != CBBInjectionPhaseUp);
    uint32_t mask;
    switch (phase) {
        case CBBInjectionPhaseDown:
            mask = CBBDriverDigitizerEventTouch | CBBDriverDigitizerEventIdentity;
            break;
        case CBBInjectionPhaseMove:
            mask = CBBDriverDigitizerEventPosition | CBBDriverDigitizerEventAttribute;
            break;
        default:
            mask = CBBDriverDigitizerEventTouch | CBBDriverDigitizerEventIdentity;
            break;
    }

    uint64_t timestamp = mach_absolute_time();
    CBBEventRef hand = CBBDriverCreateDigitizer(kCFAllocatorDefault, timestamp,
                                                CBBDriverTransducerTypeHand,
                                                0, 0, mask, 0,
                                                0, 0, 0, 0, 0,
                                                0,          // range: the finger carries it
                                                touching,
                                                0);
    if (!hand) return;

    if (CBBDriverSetIntegerOptions) {
        CBBDriverSetIntegerOptions(hand, CBBDriverDigitizerIsDisplayIntegrated, 1, CBBDriverFieldOptions);
    }
    if (CBBDriverSetInteger) {
        CBBDriverSetInteger(hand, CBBDriverDigitizerIsDisplayIntegrated, 1);
    }

    CBBEventRef finger = CBBDriverCreateFinger(kCFAllocatorDefault, timestamp,
                                               2, 2, mask,
                                               x, y, 0,
                                               0, 0,
                                               touching ? 1 : 0,   // range
                                               touching ? 1 : 0,   // touch
                                               0);
    if (finger) {
        if (CBBDriverSetFloat) {
            CBBDriverSetFloat(finger, CBBDriverDigitizerMajorRadius, 5.0);
            CBBDriverSetFloat(finger, CBBDriverDigitizerMinorRadius, 5.0);
        }
        CBBDriverAppend(hand, finger, 0);
        CFRelease(finger);
    }

    if (CBBDriverSetSender) CBBDriverSetSender(hand, CBBDriverSenderForStrategy(senderStrategy));
    CBBDriverDispatch(client, hand);
    CFRelease(hand);

    int32_t injected = __sync_add_and_fetch(&CBBDriverInjected, 1);
    if (phase == CBBInjectionPhaseUp) {
        // The monitor counts are the evidence: they only move for events that
        // came back through the HID system, so a tap that leaves them alone was
        // dropped on the way in rather than routed somewhere unexpected.
        CBBDriverStage([NSString stringWithFormat:
                        @"driver: tap #%d (%.0f,%.0f) client %d sender %d, monitors %d/%d/%d/%d",
                        (int)(injected / 2), x, y, clientType, senderStrategy,
                        (int)CBBDriverMonitorCounts[0], (int)CBBDriverMonitorCounts[1],
                        (int)CBBDriverMonitorCounts[2], (int)CBBDriverMonitorCounts[3]]);
    }
}

#pragma mark - The queue

// SpringBoard appends one line per event and this reads whatever is new. The
// byte offset is the whole protocol: a missed tick costs nothing, because the
// next one still starts where the last one stopped. A file shorter than the
// offset means SpringBoard truncated it for a new gesture.
//
// "<phase> <x> <y> [client type] [sender strategy]" - the last two are optional
// and exist so a diagnosis can force a combination from a shell on the device
// instead of needing a rebuild for each guess.
static void CBBDriverDrain(void) {
    static char buffer[8192];
    int fd = open(CBB_DRIVER_QUEUE_PATH, O_RDONLY);
    if (fd < 0) return;

    struct stat info;
    off_t offset = CBBDriverOffset;
    ssize_t got = -1;
    if (fstat(fd, &info) == 0) {
        if (info.st_ino != CBBDriverQueueInode) {
            CBBDriverQueueInode = info.st_ino;
            offset = 0;
        }
        if (info.st_size < offset) offset = 0;
        if (info.st_size > offset && lseek(fd, offset, SEEK_SET) == offset) {
            got = read(fd, buffer, sizeof(buffer) - 1);
        }
    }
    close(fd);

    if (got <= 0) {
        CBBDriverOffset = offset;
        return;
    }
    buffer[got] = '\0';

    // Only whole lines: a half-written one is read again on the next tick.
    off_t consumed = 0;
    char *cursor = buffer;
    char *newline = NULL;
    while ((newline = strchr(cursor, '\n')) != NULL) {
        *newline = '\0';
        int phase = 0;
        int clientType = CBBDriverClientDefault;
        int senderStrategy = CBBDriverSenderPanel;
        double x = 0, y = 0;
        int fields = sscanf(cursor, "%d %lf %lf %d %d", &phase, &x, &y, &clientType, &senderStrategy);
        if (fields >= 3) {
            if (fields < 5) clientType = CBBDriverClientDefault;
            if (fields < 5) senderStrategy = CBBDriverSenderPanel;
            @try {
                CBBDriverInject(x, y, phase, clientType, senderStrategy);
            } @catch (NSException *exception) {
                CBBDriverStage([NSString stringWithFormat:@"driver: injection threw %@: %@",
                                exception.name, exception.reason]);
            }
            if (!CBBDriverReported) {
                CBBDriverReported = 1;
                CBBDriverStage([NSString stringWithFormat:@"driver: first tap from SpringBoard (%.0f,%.0f)",
                                x, y]);
            }
        }
        consumed = (off_t)((newline + 1) - buffer);
        cursor = newline + 1;
    }
    CBBDriverOffset = offset + consumed;
}

static void CBBDriverTimerCallback(CFRunLoopTimerRef timer, void *info) {
    (void)timer;
    (void)info;
    CBBDriverDrain();
}

#pragma mark - Service thread

static void CBBDriverServe(void) {
    @autoreleasepool {
        CBBDriverStage(@"driver: service thread started");

        // One monitor of every kind that could be, so a zero echo count can be
        // told apart from a monitor that simply cannot see anything.
        for (int type = 0; type < CBBDriverClientTypes; type++) {
            if (type == CBBDriverClientDefault) continue;
            CBBSystemClientRef monitor = CBBDriverClientForType(type);
            if (!monitor || !CBBDriverRegisterCallback) continue;
            CBBDriverRegisterCallback(monitor, (void *)CBBDriverLoopbackCallback,
                                      (void *)(intptr_t)type, NULL);
            CBBDriverMonitors[type] = monitor;
        }

        // 10 ms: fast enough that a tap's down/move/up keep the spacing
        // SpringBoard chose, cheap enough that a stat() 100 times a second does
        // not matter.
        CFRunLoopTimerRef timer = CFRunLoopTimerCreate(kCFAllocatorDefault,
                                                       CFAbsoluteTimeGetCurrent(),
                                                       0.01, 0, 0,
                                                       CBBDriverTimerCallback, NULL);
        if (timer) {
            CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, kCFRunLoopDefaultMode);
            CFRelease(timer);
        }

        CBBDriverStage([NSString stringWithFormat:@"driver: watching %s (monitors %d/%d/%d)",
                        CBB_DRIVER_QUEUE_PATH,
                        CBBDriverMonitors[1] ? 1 : 0,
                        CBBDriverMonitors[2] ? 1 : 0,
                        CBBDriverMonitors[3] ? 1 : 0]);
        CFRunLoopRun();
    }
}

#pragma mark - Load

static void *CBBDriverSymbol(const char *name) {
    return dlsym(RTLD_DEFAULT, name);
}

__attribute__((constructor)) static void CBBDriverLoad(void) {
    @autoreleasepool {
        CBBDriverStageLock = [[NSLock alloc] init];
        CBBDriverStage([NSString stringWithFormat:@"driver: loaded in %@ (pid %d)",
                        [[NSProcessInfo processInfo] processName], (int)getpid()]);

        CBBDriverCreateDigitizer = (CBBCreateDigitizerEventFn)CBBDriverSymbol("IOHIDEventCreateDigitizerEvent");
        CBBDriverCreateFinger = (CBBCreateFingerEventFn)CBBDriverSymbol("IOHIDEventCreateDigitizerFingerEvent");
        CBBDriverAppend = (CBBAppendEventFn)CBBDriverSymbol("IOHIDEventAppendEvent");
        CBBDriverSetInteger = (CBBSetIntegerFn)CBBDriverSymbol("IOHIDEventSetIntegerValue");
        CBBDriverSetIntegerOptions = (CBBSetIntegerOptionsFn)CBBDriverSymbol("IOHIDEventSetIntegerValueWithOptions");
        CBBDriverSetFloat = (CBBSetFloatFn)CBBDriverSymbol("IOHIDEventSetFloatValue");
        CBBDriverSetSender = (CBBSetSenderFn)CBBDriverSymbol("IOHIDEventSetSenderID");
        CBBDriverCreateClient = (CBBCreateClientFn)CBBDriverSymbol("IOHIDEventSystemClientCreate");
        CBBDriverCreateClientWithType = (CBBCreateClientWithTypeFn)CBBDriverSymbol("IOHIDEventSystemClientCreateWithType");
        CBBDriverCreateSimpleClient = (CBBCreateSimpleClientFn)CBBDriverSymbol("IOHIDEventSystemClientCreateSimpleClient");
        CBBDriverDispatch = (CBBDispatchEventFn)CBBDriverSymbol("IOHIDEventSystemClientDispatchEvent");
        CBBDriverCopyServices = (CBBCopyServicesFn)CBBDriverSymbol("IOHIDEventSystemClientCopyServices");
        CBBDriverRegistryID = (CBBRegistryIDFn)CBBDriverSymbol("IOHIDServiceClientGetRegistryID");
        CBBDriverCopyProperty = (CBBCopyPropertyFn)CBBDriverSymbol("IOHIDServiceClientCopyProperty");
        CBBDriverRegisterCallback = (CBBRegisterCallbackFn)CBBDriverSymbol("IOHIDEventSystemClientRegisterEventCallback");
        CBBDriverSchedule = (CBBScheduleWithRunLoopFn)CBBDriverSymbol("IOHIDEventSystemClientScheduleWithRunLoop");
        CBBDriverEventGetType = (CBBEventGetTypeFn)CBBDriverSymbol("IOHIDEventGetType");

        if (!CBBDriverCreateClient || !CBBDriverDispatch) {
            CBBDriverStage(@"driver: IOHIDEventSystemClient / dispatch missing on this build; nothing to do");
            return;
        }

        // Its own thread, so a slow or blocked HID dispatch can never hold up
        // backboardd's own main loop.
        NSThread *thread = [[NSThread alloc] initWithBlock:^{
            CBBDriverServe();
        }];
        thread.name = @"com.buffy.cardboardos.driver";
        thread.qualityOfService = NSQualityOfServiceUserInteractive;
        [thread start];

        CBBDriverStage([NSString stringWithFormat:@"driver: queue %s", CBB_DRIVER_QUEUE_PATH]);
    }
}
