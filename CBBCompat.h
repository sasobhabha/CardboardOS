//
//  CBBCompat.h
//  CardboardOS
//
//  Private API declarations and small helpers shared by every component.
//  iOS 12 only. Nothing in here is App Store safe; this is a jailbreak tweak.
//

#ifndef CBBCompat_h
#define CBBCompat_h

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <mach/mach.h>
#import <mach/mach_time.h>
#import <CoreVideo/CoreVideo.h>

// IOSurface headers are incomplete in some SDKs: the iPhoneOS 16.5 SDK ships
// IOSurfaceTypes.h but neither <IOSurface/IOSurface.h> nor
// <IOSurface/IOSurfaceAPI.h>, so the types exist while the functions and
// property keys are undeclared. The framework still exports everything at link
// time, so pull the types from wherever they live and declare the small API
// subset used by the capture path.
#if __has_include(<IOSurface/IOSurface.h>)
#import <IOSurface/IOSurface.h>
#elif __has_include(<IOSurface/IOSurfaceAPI.h>)
#import <IOSurface/IOSurfaceAPI.h>
#else

// CoreVideo (imported above) may already have pulled this in; the header guard
// makes the second import a no-op either way.
#if __has_include(<IOSurface/IOSurfaceTypes.h>)
#import <IOSurface/IOSurfaceTypes.h>
#else
typedef struct __IOSurface *IOSurfaceRef;
enum { kIOSurfaceLockReadOnly = 0x00000001 };
#endif

#ifdef __cplusplus
extern "C" {
#endif

extern IOSurfaceRef IOSurfaceCreate(CFDictionaryRef properties);
extern void *IOSurfaceGetBaseAddress(IOSurfaceRef surface);
extern size_t IOSurfaceGetWidth(IOSurfaceRef surface);
extern size_t IOSurfaceGetHeight(IOSurfaceRef surface);
extern size_t IOSurfaceGetBytesPerRow(IOSurfaceRef surface);
extern kern_return_t IOSurfaceLock(IOSurfaceRef surface, uint32_t options, uint32_t *seed);
extern kern_return_t IOSurfaceUnlock(IOSurfaceRef surface, uint32_t options, uint32_t *seed);

extern const CFStringRef kIOSurfaceWidth;
extern const CFStringRef kIOSurfaceHeight;
extern const CFStringRef kIOSurfaceBytesPerElement;
extern const CFStringRef kIOSurfaceBytesPerRow;
extern const CFStringRef kIOSurfaceAllocSize;
extern const CFStringRef kIOSurfacePixelFormat;

// CoreVideo only declares this when it can see the IOSurface headers, so it is
// missing from the same SDKs that need the block above. Same signature.
extern CVReturn CVPixelBufferCreateWithIOSurface(CFAllocatorRef allocator,
                                                 IOSurfaceRef surface,
                                                 CFDictionaryRef pixelBufferAttributes,
                                                 CVPixelBufferRef *pixelBufferOut);

#ifdef __cplusplus
}
#endif
#endif

#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <simd/simd.h>
#import <objc/runtime.h>
#import <stdlib.h>
#import <math.h>
#import <unistd.h>

#define CBBLog(fmt, ...) NSLog(@"[CardboardOS] " fmt, ##__VA_ARGS__)

// Boot breadcrumbs. NSLog goes to /var/log/syslog, and a Jailbreak without
// syslogd (iOS 12 here) never writes one, so "the tweak loaded and did nothing"
// and "the tweak never loaded" look identical from a shell. These lines go to a
// plain file that survives the respring and is printed by `make doctor`.
//
// `make deploy` clears the file just before respringing, so whatever is in it
// afterwards belongs to the run you are looking at.
static inline void CBBMarkStage(NSString *stage) {
    if (!stage) return;
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], stage];
    NSString *path = @"/var/mobile/Library/Preferences/com.buffy.cardboardos.stages";
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (handle) {
        @try {
            [handle seekToEndOfFile];
            [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [handle closeFile];
        } @catch (NSException *exception) {
            // A breadcrumb is never allowed to be the reason something fails.
        }
        return;
    }
    [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

#pragma mark - CoreAnimation display capture SPI

// Renders the current contents of the named display ("LCD" = main panel) into
// an IOSurface. Surface must be at least the native panel size. This is the
// same entry point used by jailbreak screen recorders such as TrollVNC.
extern void CARenderServerRenderDisplay(mach_port_t server,
                                        CFStringRef display,
                                        IOSurfaceRef surface,
                                        int x,
                                        int y);

#pragma mark - IOKit HID injection SPI

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;

// Signatures match the private IOHIDEvent.h used by SimulateTouch / Veency.
// `options` is IOOptionBits (a UInt32 alias); spelled uint32_t here so the
// declarations do not depend on the IOKit headers being in the search path.
extern IOHIDEventRef IOHIDEventCreateDigitizerEvent(CFAllocatorRef allocator,
                                                    uint64_t timeStamp,
                                                    uint32_t transducerType,
                                                    uint32_t index,
                                                    uint32_t identity,
                                                    uint32_t eventMask,
                                                    uint32_t buttonMask,
                                                    double x,
                                                    double y,
                                                    double z,
                                                    double tipPressure,
                                                    double barrelPressure,
                                                    Boolean range,
                                                    Boolean touch,
                                                    uint32_t options);

// Without the quality parameters. Apple's own synthetic-touch code uses this one
// and writes the radii afterwards through IOHIDEventSetFloatValue.
extern IOHIDEventRef IOHIDEventCreateDigitizerFingerEvent(CFAllocatorRef allocator,
                                                          uint64_t timeStamp,
                                                          uint32_t index,
                                                          uint32_t identity,
                                                          uint32_t eventMask,
                                                          double x,
                                                          double y,
                                                          double z,
                                                          double tipPressure,
                                                          double twist,
                                                          Boolean range,
                                                          Boolean touch,
                                                          uint32_t options);

extern IOHIDEventRef IOHIDEventCreateDigitizerFingerEventWithQuality(CFAllocatorRef allocator,
                                                                     uint64_t timeStamp,
                                                                     uint32_t index,
                                                                     uint32_t identity,
                                                                     uint32_t eventMask,
                                                                     double x,
                                                                     double y,
                                                                     double z,
                                                                     double tipPressure,
                                                                     double twist,
                                                                     double minorRadius,
                                                                     double majorRadius,
                                                                     double quality,
                                                                     double density,
                                                                     double irregularity,
                                                                     Boolean range,
                                                                     Boolean touch,
                                                                     uint32_t options);

extern IOHIDEventRef IOHIDEventCreateKeyboardEvent(CFAllocatorRef allocator,
                                                   uint64_t timeStamp,
                                                   uint32_t usagePage,
                                                   uint32_t usage,
                                                   Boolean down,
                                                   uint32_t options);

extern void IOHIDEventAppendEvent(IOHIDEventRef parent, IOHIDEventRef child, uint32_t options);
extern void IOHIDEventSetIntegerValue(IOHIDEventRef event, uint32_t field, int64_t value);
extern void IOHIDEventSetFloatValue(IOHIDEventRef event, uint32_t field, double value);
extern void IOHIDEventSetSenderID(IOHIDEventRef event, uint64_t senderID);
extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern void IOHIDEventSystemClientDispatchEvent(IOHIDEventSystemClientRef client, IOHIDEventRef event);

// Options-taking setter. The digitizer fields that mark a synthetic event as the
// built-in panel have to be written through this one with options 0xF0000000
// (see CBBTouchInjector); the plain setter leaves backboardd seeing
// DisplayIntegrated: 0 and the touch is never treated as a finger.
extern void IOHIDEventSetIntegerValueWithOptions(IOHIDEventRef event, uint32_t field, int value, uint32_t options);

// Receive side. Only used to count our own injected events coming back through
// the HID system, which is how a device with no syslog answers "did the tap even
// leave the process". Deliberately declared as a typedef, not as externs: these
// are private IOKit exports, and a symbol the device does not have would fail
// the whole dylib at load time instead of failing one diagnostic. CBBTouchInjector
// resolves them with dlsym and does without them if they are missing.
typedef void (*IOHIDEventSystemClientEventCallback)(void *target, void *refcon,
                                                   IOHIDEventSystemClientRef sender, IOHIDEventRef event);

#pragma mark - Digitizer constants

// Values from IOHIDEventTypes.h.
enum {
    CBBHIDDigitizerEventRange     = 1,
    CBBHIDDigitizerEventTouch     = 2,
    CBBHIDDigitizerEventPosition  = 4,
    CBBHIDDigitizerEventAttribute = 8,
    CBBHIDDigitizerEventIdentity  = 32,
    CBBHIDEventTypeDigitizer      = 11,
};

// kIOHIDDigitizerTransducerTypeHand is 3 on iOS 7 and later (it was 35 on iOS 6).
enum {
    CBBHIDTransducerTypeHand = 3,
};

// Literal event fields used by the working Veency/SimulateTouch injection
// recipe. They mark the parent digitizer event as built-in/display-integrated
// so SpringBoard treats it as a real panel touch rather than an external one.
enum {
    // Per HID spec, "built-in" as a plain field number, separate from the
    // digitizer option-flag field below it.
    CBBHIDFieldBuiltIn                      = 0x00000004,
    CBBHIDFieldDigitizerEventMask           = 0x000b0007,
    CBBHIDFieldDigitizerRange               = 0x000b0008,
    CBBHIDFieldDigitizerTouch               = 0x000b0009,
    CBBHIDFieldDigitizerMajorRadius         = 0x000b0014,
    CBBHIDFieldDigitizerMinorRadius         = 0x000b0015,
    // Declaring the event as coming from the panel's own digitizer. Without it a
    // synthetic touch is treated as an external device and never arrives.
    CBBHIDFieldDigitizerIsDisplayIntegrated = 0x000b0019,
};

#pragma mark - Screen geometry

static inline CGSize CBBNativeScreenSize(void) {
    UIScreen *screen = [UIScreen mainScreen];
    if ([screen respondsToSelector:@selector(fixedCoordinateSpace)]) {
        CGSize s = screen.fixedCoordinateSpace.bounds.size;
        if (s.width > 0 && s.height > 0) return s;
    }
    CGSize s = screen.bounds.size;
    return CGSizeMake(MIN(s.width, s.height), MAX(s.width, s.height));
}

// Size of the screen in the current interface orientation (the space window
// frames live in), derived from the fixed portrait size and the interface
// orientation SpringBoard is currently using.
static inline CGSize CBBCurrentScreenSize(void) {
    CGSize native = CBBNativeScreenSize();
    CGFloat shortSide = MIN(native.width, native.height);
    CGFloat longSide = MAX(native.width, native.height);
    UIInterfaceOrientation orientation = [UIApplication sharedApplication].statusBarOrientation;
    if (orientation == UIInterfaceOrientationUnknown) {
        CGSize current = [UIScreen mainScreen].coordinateSpace.bounds.size;
        if (current.width > 0 && current.height > 0) return current;
    }
    if (UIInterfaceOrientationIsLandscape(orientation)) {
        return CGSizeMake(longSide, shortSide);
    }
    return CGSizeMake(shortSide, longSide);
}

// Stamped into the stages file at startup. "Did my build actually reach the
// phone" has cost several rounds already; the stages file now answers it.
#define CBB_BUILD_TAG "2026-11-10f one-second dwell and taps inside apps"

// Radius, in fixed-space points, of the disc the overlay claims as the viewer's
// button while stereo is *off*. With stereo on the overlay claims the whole
// screen instead (a press that is not claimed goes to SpringBoard as a normal
// tap and opens whatever is under the pad), so this only keeps the four-tap
// escape hatch reachable on a dormant tweak.
#define CBB_BUTTON_CLAIM_RADIUS 72.0

static inline CGFloat CBBDistance(CGPoint a, CGPoint b) {
    CGFloat dx = a.x - b.x;
    CGFloat dy = a.y - b.y;
    return sqrt(dx * dx + dy * dy);
}

// Converts a point in a view's coordinate space into the fixed (native,
// portrait) screen space used by the HID digitizer and the capture surface.
static inline CGPoint CBBPointInFixedSpace(UIView *view, CGPoint point) {
    if ([view respondsToSelector:@selector(convertPoint:toCoordinateSpace:)]) {
        return [view convertPoint:point toCoordinateSpace:[UIScreen mainScreen].fixedCoordinateSpace];
    }
    return point;
}

#pragma mark - Capture exclusion

// CALayer's private `disableUpdateMask` bitmask is what apps (and the system's
// own secure text fields) use to stay visible on the panel while being left out
// of screenshots and recordings. Setting bits 1<<1 | 1<<4 keeps our stereo
// window out of CARenderServerRenderDisplay, which is what prevents the mirror
// from recursively capturing itself.
static inline void CBBSetLayerCaptureHidden(CALayer *layer, BOOL hidden) {
    if (!layer) return;
    @try {
        [layer setValue:@(hidden ? 0x12 : 0) forKey:@"disableUpdateMask"];
    } @catch (NSException *exception) {
        static BOOL warned = NO;
        if (!warned) {
            warned = YES;
            CBBLog(@"disableUpdateMask unavailable; the mirror may capture itself");
        }
    }
}

static inline void CBBSetViewTreeCaptureHidden(UIView *view, BOOL hidden) {
    if (!view) return;
    CBBSetLayerCaptureHidden(view.layer, hidden);
    for (UIView *subview in view.subviews) {
        CBBSetViewTreeCaptureHidden(subview, hidden);
    }
}

#endif /* CBBCompat_h */
