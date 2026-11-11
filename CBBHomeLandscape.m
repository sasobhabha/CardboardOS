#import "CBBHomeLandscape.h"
#import "CBBCompat.h"

#import <objc/runtime.h>
#import <objc/message.h>

// SpringBoard's own orientation policy is what keeps the home screen portrait on
// iPhone. Three things stand between this tweak and a landscape home screen, and
// all three have to be dealt with or the masks are simply ignored:
//
//  1. SpringBoard asks supportedInterfaceOrientationsForWindow: — first its
//     delegate, then the application — for every window, including its own.
//  2. The home screen view controller answers supportedInterfaceOrientations
//     itself, which wins over the window-level answer for its own view.
//  3. The device rotation lock (Control Center) gates the home screen even when
//     an orientation is forced, unless the lock is released.
//
// The override is opt-in and every step is guarded: a build that lacks a method
// keeps its portrait home screen, and anything that throws leaves the state off.

static BOOL gLandscapeActive = NO;
static UIInterfaceOrientation gLandscapeOrientation = UIInterfaceOrientationLandscapeLeft;
static NSInteger gNudgeAttempts = 0;
static Class gHookedDelegateClass = Nil;
static BOOL gTriedUnlockingRotationLock = NO;

static IMP gOriginalAppOrientations = NULL;
static IMP gOriginalDelegateOrientations = NULL;
static IMP gOriginalHomeScreenOrientations = NULL;
static IMP gOriginalHomeScreenAutorotate = NULL;

// -[UIWindow _setRotatableViewOrientation:updateStatusBar:duration:force:]
typedef void (*CBBNudgeOrientationFn)(id, SEL, UIInterfaceOrientation, BOOL, double, BOOL);

// Enough to survive a reset (a rotation the UI performs for its own reasons, a
// status bar change) but not so many that a build which refuses landscape is
// nudged forever: SpringBoard posts notifications on every attempt.
static const NSInteger CBBMaxNudgeAttempts = 10;

static BOOL CBBLooksLikeHomeScreenObject(id object) {
    if (!object) return NO;
    NSString *name = NSStringFromClass([object class]);
    if (name.length == 0) return NO;
    return [name rangeOfString:@"HomeScreen" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

// Replaces the method if the class implements it itself, otherwise adds an
// override in front of the inherited one. Returns the implementation that was in
// front of ours, which may belong to a superclass. `addIfMissing` is NO for
// methods UIKit may not have at all: inventing one there would answer questions
// UIKit currently does not ask.
static IMP CBBHookMethod(Class cls, SEL selector, IMP replacement, BOOL addIfMissing) {
    if (!cls) return NULL;

    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return NULL;

    IMP original = method_getImplementation(method);
    const char *types = method_getTypeEncoding(method);

    BOOL owned = NO;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    if (methods) {
        for (unsigned int i = 0; i < count; i++) {
            if (method_getName(methods[i]) == selector) {
                owned = YES;
                break;
            }
        }
        free(methods);
    }

    if (owned) {
        method_setImplementation(method, replacement);
    } else if (!addIfMissing || !class_addMethod(cls, selector, replacement, types)) {
        return NULL;
    }
    return original;
}

// Every window while the override is active, not only ones whose class happens
// to contain "HomeScreen": SpringBoard's own windows are what is being asked
// about, and guessing their class names is how this failed before.
static NSUInteger CBBAppSupportedOrientations(id self, SEL _cmd, UIWindow *window) {
    if (gLandscapeActive) return UIInterfaceOrientationMaskLandscape;
    return gOriginalAppOrientations
        ? ((NSUInteger (*)(id, SEL, UIWindow *))gOriginalAppOrientations)(self, _cmd, window)
        : UIInterfaceOrientationMaskPortrait;
}

static NSUInteger CBBDelegateSupportedOrientations(id self, SEL _cmd, UIApplication *application, UIWindow *window) {
    if (gLandscapeActive) return UIInterfaceOrientationMaskLandscape;
    return gOriginalDelegateOrientations
        ? ((NSUInteger (*)(id, SEL, id, id))gOriginalDelegateOrientations)(self, _cmd, application, window)
        : UIInterfaceOrientationMaskPortrait;
}

static NSUInteger CBBHomeScreenSupportedOrientations(id self, SEL _cmd) {
    if (gLandscapeActive) return UIInterfaceOrientationMaskLandscape;
    return gOriginalHomeScreenOrientations
        ? ((NSUInteger (*)(id, SEL))gOriginalHomeScreenOrientations)(self, _cmd)
        : UIInterfaceOrientationMaskPortrait;
}

static BOOL CBBHomeScreenShouldAutorotate(id self, SEL _cmd) {
    if (gLandscapeActive) return YES;
    return gOriginalHomeScreenAutorotate
        ? ((BOOL (*)(id, SEL))gOriginalHomeScreenAutorotate)(self, _cmd)
        : NO;
}

// The device's physical landscape direction, mapped to the interface orientation
// UIKit names the other way round.
static UIInterfaceOrientation CBBDeviceLandscapeOrientation(void) {
    switch ([UIDevice currentDevice].orientation) {
        case UIDeviceOrientationLandscapeRight:
            return UIInterfaceOrientationLandscapeLeft;
        case UIDeviceOrientationLandscapeLeft:
            return UIInterfaceOrientationLandscapeRight;
        default:
            return UIInterfaceOrientationLandscapeLeft;
    }
}

@implementation CBBHomeLandscape {
    NSTimeInterval _lastNudgeTime;
}

+ (instancetype)sharedHelper {
    static CBBHomeLandscape *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[CBBHomeLandscape alloc] init];
    });
    return shared;
}

- (void)installHooksOnce {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @try {
            gOriginalAppOrientations = CBBHookMethod([UIApplication class],
                                                      @selector(supportedInterfaceOrientationsForWindow:),
                                                      (IMP)CBBAppSupportedOrientations,
                                                      NO);

            Class homeScreenClass = objc_getClass("SBHomeScreenViewController");
            if (homeScreenClass) {
                gOriginalHomeScreenOrientations = CBBHookMethod(homeScreenClass,
                                                                @selector(supportedInterfaceOrientations),
                                                                (IMP)CBBHomeScreenSupportedOrientations,
                                                                YES);
                gOriginalHomeScreenAutorotate = CBBHookMethod(homeScreenClass,
                                                              @selector(shouldAutorotate),
                                                              (IMP)CBBHomeScreenShouldAutorotate,
                                                              YES);
            }
            CBBLog(@"landscape hooks: app %d home screen %d (%@)",
                   gOriginalAppOrientations != NULL,
                   gOriginalHomeScreenOrientations != NULL,
                   homeScreenClass ? NSStringFromClass(homeScreenClass) : @"none");
        } @catch (NSException *exception) {
            CBBLog(@"landscape hooks threw %@", exception);
        }
        [self hookDelegateIfNeeded];
    });
}

// SpringBoard's delegate answers the same question before the application does,
// so ignoring it would make the other two hooks pointless. The delegate object
// does not exist yet when the tweak starts, hence this runs on every apply.
- (void)hookDelegateIfNeeded {
    @try {
        Class cls = [[UIApplication sharedApplication].delegate class];
        if (!cls || cls == gHookedDelegateClass) return;

        IMP original = CBBHookMethod(cls,
                                     @selector(application:supportedInterfaceOrientationsForWindow:),
                                     (IMP)CBBDelegateSupportedOrientations,
                                     NO);
        if (original) {
            gHookedDelegateClass = cls;
            gOriginalDelegateOrientations = original;
            CBBLog(@"landscape hooks: delegate %@", NSStringFromClass(cls));
        }
    } @catch (NSException *exception) {
        CBBLog(@"delegate orientation hook threw %@", exception);
    }
}

// Control Center's rotation lock gates the home screen even when an orientation
// is forced. Releasing it is what the lock button itself does, and it is a no-op
// when the lock is not on.
- (void)releaseRotationLockIfPossible {
    if (gTriedUnlockingRotationLock) return;
    gTriedUnlockingRotationLock = YES;

    @try {
        Class managerClass = objc_getClass("SBOrientationLockManager");
        SEL sharedSelector = NSSelectorFromString(@"sharedInstance");
        if (!managerClass || ![managerClass respondsToSelector:sharedSelector]) return;

        id manager = ((id (*)(id, SEL))objc_msgSend)(managerClass, sharedSelector);
        SEL unlockSelector = NSSelectorFromString(@"unlock");
        if ([manager respondsToSelector:unlockSelector]) {
            ((void (*)(id, SEL))objc_msgSend)(manager, unlockSelector);
            CBBLog(@"released SpringBoard's rotation lock");
        }
    } @catch (NSException *exception) {
        CBBLog(@"rotation lock release threw %@", exception);
    }
}

- (UIWindow *)homeScreenWindow {
    UIApplication *application = [UIApplication sharedApplication];
    for (UIWindow *window in application.windows) {
        if (CBBLooksLikeHomeScreenObject(window)) return window;
    }
    return application.keyWindow;
}

- (void)nudgeOrientation:(UIInterfaceOrientation)orientation {
    // Nudging makes UIKit post orientation notifications, which come straight
    // back into the controller. Without a throttle that becomes a feedback loop
    // that SpringBoard eventually dies on, so at most one attempt per second.
    NSTimeInterval now = CACurrentMediaTime();
    if (now - _lastNudgeTime < 1.0) return;
    _lastNudgeTime = now;

    if ([UIApplication sharedApplication].statusBarOrientation == orientation) {
        gNudgeAttempts = 0;
        return;
    }
    if (gNudgeAttempts >= CBBMaxNudgeAttempts) return;

    UIWindow *window = [self homeScreenWindow];
    SEL selector = NSSelectorFromString(@"_setRotatableViewOrientation:updateStatusBar:duration:force:");
    if (!window || ![window respondsToSelector:selector]) {
        CBBLog(@"home screen window does not take an orientation; relying on the masks alone");
        gNudgeAttempts = CBBMaxNudgeAttempts;
        return;
    }

    gNudgeAttempts++;
    @try {
        ((CBBNudgeOrientationFn)objc_msgSend)(window, selector, orientation, NO, 0.35, YES);
        CBBLog(@"asked the home screen for interface orientation %ld (attempt %ld/%ld)",
               (long)orientation, (long)gNudgeAttempts, (long)CBBMaxNudgeAttempts);
    } @catch (NSException *exception) {
        gLandscapeActive = NO;
        gNudgeAttempts = CBBMaxNudgeAttempts;
        CBBLog(@"home screen orientation nudge threw %@; giving up on it", exception);
    }
}

- (void)applyMode:(CBBHomeLandscapeMode)mode {
    if (mode == CBBHomeLandscapeOff) {
        if (!gLandscapeActive) return;
        gLandscapeActive = NO;
        gNudgeAttempts = 0;
        _lastNudgeTime = 0;
        [self nudgeOrientation:UIInterfaceOrientationPortrait];
        return;
    }

    // Hooks are only installed when the feature is actually wanted, so the
    // default (off) build never touches SpringBoard's orientation policy at all.
    // The mark below is the only breadcrumb this path leaves: a run that ends
    // right after it died inside the hooks or the nudge, not in stereo code.
    CBBMarkStage(@"landscape forcing on");
    [self installHooksOnce];
    [self hookDelegateIfNeeded];
    [self releaseRotationLockIfPossible];

    UIInterfaceOrientation wanted;
    switch (mode) {
        case CBBHomeLandscapeLeft:
            wanted = UIInterfaceOrientationLandscapeLeft;
            break;
        case CBBHomeLandscapeRight:
            wanted = UIInterfaceOrientationLandscapeRight;
            break;
        default:
            wanted = CBBDeviceLandscapeOrientation();
            break;
    }

    if (wanted != gLandscapeOrientation) {
        gLandscapeOrientation = wanted;
        gNudgeAttempts = 0;
        _lastNudgeTime = 0;
    }

    gLandscapeActive = YES;
    [self nudgeOrientation:gLandscapeOrientation];
}

- (BOOL)wantsMoreAttempts {
    return gLandscapeActive && gNudgeAttempts < CBBMaxNudgeAttempts;
}

@end
