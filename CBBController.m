#import "CBBController.h"
#import "CBBCompat.h"
#import "CBBPrefs.h"
#import "CBBClickRecognizer.h"
#import "CBBTouchInjector.h"
#import "CBBStereoRenderer.h"
#import "CBBDisplayCapture.h"
#import "CBBStereoHUD.h"
#import "CBBMotionPointer.h"
#import "CBBHomeLandscape.h"
#import <dlfcn.h>

// How far the dot may wander, in fixed-space points, before a hold-to-click
// restarts. This used to be 14 pt, which sounds generous until it is converted:
// the aim maps 0.30 rad onto half the panel, so 14 pt of a 568 pt panel is
// about 0.85 degrees of head rotation. A head in a viewer moves more than that
// in a second just from breathing and pulse, so the hold was being reset
// before it could ever finish and the dot appeared simply not to click.
static const CGFloat CBBDwellRadius = 36.0;
static const NSTimeInterval CBBDwellHoldSeconds = 1.0;

// Holding still in a viewer is idle to iOS, and while an app is on screen its own
// idle timer wins over SpringBoard's, so the backlight would time out in exactly
// the case the stereo view is for. A power assertion is device-wide and outlives
// the app swap, so the display stays up on the home screen and inside apps alike.
typedef int32_t (*CBBPMAssertionCreateWithNameFn)(CFStringRef assertionType,
                                                  uint32_t level,
                                                  CFStringRef assertionName,
                                                  uint32_t *assertionID);
typedef int32_t (*CBBPMAssertionReleaseFn)(uint32_t assertionID);
static uint32_t CBBDisplaySleepAssertion = 0;

static void CBBSetDisplaySleepBlocked(BOOL blocked) {
    static CBBPMAssertionCreateWithNameFn createFn = NULL;
    static CBBPMAssertionReleaseFn releaseFn = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        createFn = (CBBPMAssertionCreateWithNameFn)dlsym(RTLD_DEFAULT, "IOPMAssertionCreateWithName");
        releaseFn = (CBBPMAssertionReleaseFn)dlsym(RTLD_DEFAULT, "IOPMAssertionRelease");
        if (!createFn || !releaseFn) {
            CBBMarkStage(@"display sleep assertion unavailable on this build");
        }
    });
    if (blocked) {
        if (CBBDisplaySleepAssertion || !createFn) return;
        uint32_t assertion = 0;
        // Level 255 is kIOPMAssertionLevelOn; 0 is kIOReturnSuccess.
        int32_t result = createFn(CFSTR("com.buffy.cardboardos.stereo"), 255,
                                  CFSTR("CardboardOS stereo display"), &assertion);
        if (result == 0) {
            CBBDisplaySleepAssertion = assertion;
            CBBMarkStage(@"display sleep blocked (home screen and apps)");
        } else {
            CBBMarkStage([NSString stringWithFormat:@"display sleep assertion refused (%d)", (int)result]);
        }
        return;
    }
    if (CBBDisplaySleepAssertion && releaseFn) {
        releaseFn(CBBDisplaySleepAssertion);
        CBBDisplaySleepAssertion = 0;
        CBBMarkStage(@"display sleep assertion released");
    }
}

static CGPoint CBBCardboardRotate(CGPoint vector, CGFloat radians) {
    CGFloat cosine = cos(radians);
    CGFloat sine = sin(radians);
    return CGPointMake(vector.x * cosine - vector.y * sine,
                       vector.x * sine + vector.y * cosine);
}

@class CBBController;

#pragma mark - Overlay root view

// Transparent full-screen view that turns the viewer's button presses into
// clicks. While stereo is on it claims every touch: a pad is hand-built and
// presses wherever it presses, and a press that is not claimed is delivered to
// SpringBoard as an ordinary tap, which opens whatever icon sits under the pad
// instead of clicking the dot. Once stereo is off it claims nothing, and plain
// finger use of iOS is untouched. During synthetic tap injection it also claims
// nothing, so the injected tap reaches the app underneath.
@interface CBBOverlayRootView : UIView

@property (nonatomic) CGPoint buttonPoint;      // fixed-space points
@property (nonatomic) BOOL learning;
@property (nonatomic) BOOL claimsEverything;    // set while stereo is enabled
@property (nonatomic) BOOL injectionPassthrough;

@property (nonatomic, copy) void (^onTouchBegan)(CGPoint fixedPoint);
@property (nonatomic, copy) void (^onTouchEnded)(CGPoint fixedPoint);
@property (nonatomic, copy) void (^onTouchCancelled)(void);

@end

@implementation CBBOverlayRootView

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.injectionPassthrough) return nil;
    if (self.learning || self.claimsEverything) return self;

    CGPoint fixed = [self convertPoint:point toCoordinateSpace:[UIScreen mainScreen].fixedCoordinateSpace];
    if (CBBDistance(fixed, self.buttonPoint) <= CBB_BUTTON_CLAIM_RADIUS) return self;
    return nil;
}

- (CGPoint)fixedPointForTouch:(UITouch *)touch {
    CGPoint point = [touch locationInView:self];
    return [self convertPoint:point toCoordinateSpace:[UIScreen mainScreen].fixedCoordinateSpace];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *touch = touches.anyObject;
    if (!touch) return;
    if (self.onTouchBegan) self.onTouchBegan([self fixedPointForTouch:touch]);
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *touch = touches.anyObject;
    if (!touch) return;
    if (self.onTouchEnded) self.onTouchEnded([self fixedPointForTouch:touch]);
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (self.onTouchCancelled) self.onTouchCancelled();
}

@end

#pragma mark - Overlay window

// A UIWindow's -hitTest: returns the window itself when no subview claims the
// point. Returning nil instead lets the event fall through to the app below,
// which is what keeps both fingers and injected taps working through a
// full-screen overlay.
@interface CBBOverlayWindow : UIWindow
@end

@implementation CBBOverlayWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return (hit == self) ? nil : hit;
}

@end

#pragma mark - Controller

@interface CBBController () <CBBClickRecognizerDelegate>

@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) CBBOverlayRootView *rootView;
@property (nonatomic, strong) CBBStereoRenderer *renderer;
@property (nonatomic, strong) CBBStereoHUD *hud;
@property (nonatomic, strong) CBBPrefs *prefs;
@property (nonatomic, strong) CBBClickRecognizer *recognizer;
@property (nonatomic, strong) CBBTouchInjector *injector;

@property (nonatomic, copy) NSArray<CBBHudRow *> *rows;
@property (nonatomic) NSInteger hudSelection;
@property (nonatomic) CGPoint cursorPosition;      // fixed-space points
@property (nonatomic, strong) CBBMotionPointer *motionPointer;
@property (nonatomic) BOOL hudOpen;
@property (nonatomic) BOOL learning;
@property (nonatomic) BOOL started;
@property (nonatomic) CGPoint clickLatch;        // cursor at the moment the button went down
@property (nonatomic) BOOL tapCalibrating;
@property (nonatomic) NSInteger tapProbeIndex;
@property (nonatomic, strong) NSTimer *tapCalibrationTimer;
@property (nonatomic) NSTimeInterval tapProbeSentTime;
@property (nonatomic) NSTimeInterval aimOutOfRangeSince;
@property (nonatomic, strong) NSTimer *landscapeTimer;
@property (nonatomic) NSInteger lastDeviceOrientation;
@property (nonatomic) CGPoint dwellAnchor;
@property (nonatomic) NSTimeInterval dwellAnchorTime;
@property (nonatomic) BOOL dwellFired;
@property (nonatomic, strong) NSTimer *dwellTimer;
@property (nonatomic, strong) NSTimer *supervisorTimer;

// Declared here because the touch handlers and the menu rows call them from
// further up the file than their definitions.
- (void)resetDwellAnchor;
- (void)startDwellTimer;
- (void)stopDwellTimer;
- (void)dwellTick;
- (void)dwellClickAtPoint:(CGPoint)point;
- (void)scheduleTapCalibration;
- (void)startTapCalibration;
- (void)sendTapProbe;
- (void)recordTapProbeAtFixedPoint:(CGPoint)point;
- (void)finishTapCalibration;
- (NSInteger)currentInterfaceOrientation;

@end

@implementation CBBController {
    // Tap calibration: three asked-for panel points and where each one arrived.
    CGPoint _tapExpected[3];
    CGPoint _tapObserved[3];
}

+ (instancetype)sharedController {
    static CBBController *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[CBBController alloc] init];
    });
    return shared;
}

#pragma mark - Lifecycle

- (void)start {
    if (self.started) return;
    self.started = YES;
    CBBMarkStage([NSString stringWithFormat:@"start entered (%s)", CBB_BUILD_TAG]);

    self.prefs = [CBBPrefs sharedPrefs];
    [self checkBootGuard];
    // Armed before any window, capture or shader work, so a crash anywhere in
    // setup also leaves the flag behind and the next launch comes up dormant.
    [self armBootGuard];
    self.injector = [CBBTouchInjector sharedInjector];
    self.recognizer = [[CBBClickRecognizer alloc] init];
    self.recognizer.delegate = self;

    // Forced landscape: the overlay always covers the panel and lays the eyes
    // out along its long axis, whatever orientation the UI thinks it is in.
    CGRect screenBounds = [UIScreen mainScreen].bounds;
    CGSize nativeSize = CBBNativeScreenSize();
    self.cursorPosition = CGPointMake(nativeSize.width * 0.5, nativeSize.height * 0.5);

    self.window = [[CBBOverlayWindow alloc] initWithFrame:screenBounds];
    self.window.windowLevel = 10000001.0;
    self.window.backgroundColor = [UIColor clearColor];
    self.window.opaque = NO;
    self.window.hidden = NO;

    self.rootView = [[CBBOverlayRootView alloc] initWithFrame:screenBounds];
    self.rootView.backgroundColor = [UIColor clearColor];
    self.rootView.opaque = NO;
    self.rootView.multipleTouchEnabled = NO;
    [self.window addSubview:self.rootView];
    CBBMarkStage([NSString stringWithFormat:@"window created (%@)",
                  NSStringFromCGRect(screenBounds)]);

    self.renderer = [[CBBStereoRenderer alloc] initWithFrame:self.rootView.bounds];
    if (self.renderer) {
        self.renderer.prefs = self.prefs;
        [self.rootView addSubview:self.renderer.view];
    } else {
        // Keep going so the failure is recorded rather than turning into a
        // silent no-op: the window exists, the stage file says why it is empty.
        CBBLog(@"Metal renderer unavailable (no Metal device, or both shaders failed)");
        CBBMarkStage(@"renderer nil: no Metal device or both shaders failed");
    }
    if (self.renderer) {
        CBBMarkStage([NSString stringWithFormat:@"renderer ready (capture %d, %@, %@)",
                      self.renderer.capture.valid,
                      self.renderer.usingSimpleShader ? @"simple shader" : @"lens shader",
                      NSStringFromCGSize(self.renderer.capture.pixelSize)]);
    }

    self.hud = [[CBBStereoHUD alloc] initWithFrame:self.rootView.bounds];
    self.hud.hidden = YES;
    self.hud.landscape = YES;
    self.hud.rotationDegrees = (CGFloat)[self.prefs integerForKey:CBBKeyRotation];
    [self.rootView addSubview:self.hud];

    __weak typeof(self) weakSelf = self;
    self.rootView.onTouchBegan = ^(CGPoint point) { [weakSelf handleTouchBeganAtFixedPoint:point]; };
    self.rootView.onTouchEnded = ^(CGPoint point) { [weakSelf handleTouchEndedAtFixedPoint:point]; };
    self.rootView.onTouchCancelled = ^{ [weakSelf.recognizer cancel]; };

    self.motionPointer = [[CBBMotionPointer alloc] init];
    self.motionPointer.onAim = ^(CGPoint aim) { [weakSelf applyAim:aim]; };
    if (!self.motionPointer.available) {
        CBBLog(@"device motion unavailable; the reticle stays where it is");
    }

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(orientationChanged:)
                                                 name:UIApplicationDidChangeStatusBarOrientationNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(orientationChanged:)
                                                 name:UIDeviceOrientationDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(orientationChanged:)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];

    [self rebuildRows];
    [self layoutOverlay];
    [self checkLandscapeCrashGuard];

    if (!self.renderer.capture.valid) {
        // Logged, not persisted: writing enabled = NO here made one bad launch
        // (say, capture probed before the display was up) disable the tweak for
        // every launch after it, with no obvious way back.
        CBBLog(@"display capture is unavailable on this device");
    }

    [self applyEnabledState];
    [self startOverlaySupervisor];
    CBBMarkStage([NSString stringWithFormat:@"state applied (stereo %d, capture %d)",
                  [self.prefs boolForKey:CBBKeyEnabled] && self.renderer.capture.valid,
                  self.renderer.capture.valid]);

    // Every "the press still opens the app under the pad" report comes down to
    // one question: did this window own the touch, or did SpringBoard get it as
    // an ordinary tap? Ask UIKit directly, once, and write down the answer.
    UIView *probe = [self.window hitTest:CGPointMake(CGRectGetMidX(self.window.bounds),
                                                     CGRectGetMidY(self.window.bounds))
                               withEvent:nil];
    CBBMarkStage([NSString stringWithFormat:@"hit test at centre -> %@ (level %.0f, hidden %d, claims %d, root %.0fx%.0f, window %.0fx%.0f)",
                  probe ? NSStringFromClass([probe class]) : @"nil",
                  self.window.windowLevel,
                  self.window.hidden,
                  self.rootView.claimsEverything,
                  self.rootView.bounds.size.width, self.rootView.bounds.size.height,
                  self.window.bounds.size.width, self.window.bounds.size.height]);
    CBBLog(@"started at %@", NSStringFromCGSize(screenBounds.size));

    // Safety net: if the capture pipeline yields nothing, do not leave the user
    // staring at a black headset with no idea why.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        CBBController *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (![strongSelf.prefs boolForKey:CBBKeyEnabled]) return;
        CBBDisplayCapture *capture = strongSelf.renderer.capture;
        if (capture.hasFrame && ![capture latestFrameHasContent]) {
            // Report it, do not hide it: switching stereo off here looks exactly
            // like "the tweak did nothing" and throws away the only clue about
            // which part of the capture path failed.
            CBBLog(@"captured frames are black: CARenderServerRenderDisplay returned no pixels for %@",
                   NSStringFromCGSize(capture.pixelSize));
            strongSelf.hud.promptText = @"CAPTURE IS BLACK";
            CBBMarkStage([NSString stringWithFormat:@"capture black after %llu frames",
                          capture.frameCount]);
        } else if (capture.hasFrame) {
            CBBMarkStage([NSString stringWithFormat:@"capture live after %llu frames",
                          capture.frameCount]);
            CBBLog(@"capture is live: %@, %llu frames in, %ld fps requested",
                   NSStringFromCGSize(capture.pixelSize),
                   capture.frameCount,
                   (long)[strongSelf.prefs integerForKey:CBBKeyCaptureFPS]);
        } else {
            CBBMarkStage(@"no frames captured at all");
        }
    });
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)orientationChanged:(NSNotification *)notification {
    UIDeviceOrientation orientation = [UIDevice currentDevice].orientation;
    BOOL usable = (orientation == UIDeviceOrientationPortrait ||
                   orientation == UIDeviceOrientationPortraitUpsideDown ||
                   orientation == UIDeviceOrientationLandscapeLeft ||
                   orientation == UIDeviceOrientationLandscapeRight);
    BOOL wasLyingDown = (self.lastDeviceOrientation == UIDeviceOrientationFaceUp ||
                         self.lastDeviceOrientation == UIDeviceOrientationFaceDown ||
                         self.lastDeviceOrientation == UIDeviceOrientationUnknown);
    self.lastDeviceOrientation = orientation;

    // The aim reference is captured when the tweak starts, which usually happens
    // with the phone lying on a desk. That frame is meaningless once the phone is
    // on your face: the aim sits far outside its range and the dot stops
    // answering on one axis. Picking the phone up is the signal to start again.
    if (usable && wasLyingDown && [self.prefs boolForKey:CBBKeyEnabled]) {
        [self resetCursor];
    }

    [self applyHomeLandscape];
    [self layoutOverlay];
    [self scheduleTapCalibration];
}

- (void)layoutOverlay {
    CGRect frame = [UIScreen mainScreen].bounds;
    self.window.frame = frame;
    self.rootView.frame = self.window.bounds;
    self.renderer.view.frame = self.rootView.bounds;
    self.hud.frame = self.rootView.bounds;
    self.renderer.screenSize = CBBNativeScreenSize();
    self.hud.landscape = YES;
    self.hud.rotationDegrees = (CGFloat)[self.prefs integerForKey:CBBKeyRotation];
    self.hud.buttonPoint = [self buttonPointInFixedSpace];
    self.hud.showButtonMarker = self.hudOpen;
    self.hud.statusText = [self statusText];
    [self updateCursorPoint];
    [self.hud setNeedsDisplay];
}

- (void)applyCaptureExclusion:(BOOL)hidden {
    CBBSetViewTreeCaptureHidden(self.renderer.view, hidden);
    CBBSetViewTreeCaptureHidden(self.hud, hidden);
}

// The home screen, its icons, folders and alerts all live in SpringBoard's own
// windows. While stereo is on they must not act on the pad's press: if the
// overlay ever fails to claim one, the press is then dropped instead of being
// delivered as an ordinary finger tap that opens whatever icon sits under the
// pad. That failure — one stray tap on the home screen — is what "every click
// opens Calculator" was. Restored the moment stereo goes off.
- (void)setSpringBoardWindowsInteractive:(BOOL)interactive {
    NSInteger touched = 0;
    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        if (window == self.window) continue;
        if (window.userInteractionEnabled == interactive) continue;
        window.userInteractionEnabled = interactive;
        touched++;
    }
    if (!interactive && touched > 0) {
        CBBMarkStage([NSString stringWithFormat:@"%ld SpringBoard window(s) made inert for touches", (long)touched]);
    }
}

// A synthetic tap is delivered to SpringBoard like a real finger, so the windows
// that were made inert have to accept touches again for the length of the
// gesture, then go inert once it is over.
- (void)beginInjectionWindow {
    self.rootView.injectionPassthrough = YES;
    [self setSpringBoardWindowsInteractive:YES];

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        CBBController *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.rootView.injectionPassthrough = NO;
        BOOL enabled = [strongSelf.prefs boolForKey:CBBKeyEnabled] && strongSelf.renderer.capture.valid;
        [strongSelf setSpringBoardWindowsInteractive:!enabled];
    });
}

#pragma mark - Enabled state

- (void)applyEnabledState {
    BOOL enabled = [self.prefs boolForKey:CBBKeyEnabled] && self.renderer.capture.valid;
    self.renderer.rendering = enabled;
    self.renderer.view.hidden = !enabled;
    self.hud.hidden = !(enabled && self.hudOpen);
    self.rootView.injectionPassthrough = NO;
    self.rootView.claimsEverything = enabled;
    self.rootView.buttonPoint = [self buttonPointInFixedSpace];
    [self setSpringBoardWindowsInteractive:!enabled];
    if (enabled) [self scheduleTapCalibration];

    [self applyCaptureExclusion:[self.prefs boolForKey:CBBKeyHideFromCapture]];

    // The gyro only runs while the stereo view is on, so a disabled tweak costs
    // nothing in battery.
    if (enabled) {
        [self.motionPointer start];
        [self.motionPointer recenter];
    } else {
        [self.motionPointer stop];
    }

    if (enabled) {
        [self resetDwellAnchor];
        [self startDwellTimer];
    } else {
        [self stopDwellTimer];
    }

    // Auto-lock is the reason stereo "quits after a while": holding still in a
    // viewer is indistinguishable from an idle phone, and a minute later the
    // backlight goes off and the overlay is gone. Held off for as long as stereo
    // is on, restored when it goes off.
    @try {
        [UIApplication sharedApplication].idleTimerDisabled = enabled;
    } @catch (NSException *exception) {
        CBBMarkStage([NSString stringWithFormat:@"idle timer unavailable: %@", exception.reason]);
    }
    CBBSetDisplaySleepBlocked(enabled);

    [self applyHomeLandscape];
}

#pragma mark - Overlay supervision

// The other half of "it quits after some time": whatever removed the overlay, it
// has to come back by itself. Every two seconds while stereo is on, the window
// has to still be visible, still in SpringBoard's window list, still carrying the
// renderer, still claiming presses, with the dwell loop and the renderer alive.
// Anything that is not is put back, and the reason is written down.
- (void)startOverlaySupervisor {
    if (self.supervisorTimer) return;
    __weak typeof(self) weakSelf = self;
    self.supervisorTimer = [NSTimer timerWithTimeInterval:2.0
                                                  repeats:YES
                                                    block:^(NSTimer *timer) {
        [weakSelf superviseOverlay];
    }];
    [[NSRunLoop mainRunLoop] addTimer:self.supervisorTimer forMode:NSRunLoopCommonModes];
}

- (void)superviseOverlay {
    BOOL enabled = [self.prefs boolForKey:CBBKeyEnabled] && self.renderer.capture.valid;
    if (!enabled) return;

    NSMutableArray<NSString *> *problems = [NSMutableArray array];
    UIApplication *app = [UIApplication sharedApplication];

    if (self.window.hidden) {
        self.window.hidden = NO;
        [problems addObject:@"window hidden"];
    }
    if (![app.windows containsObject:self.window]) {
        [problems addObject:@"window left the window list"];
    }
    if (self.rootView.superview != self.window) {
        [self.window addSubview:self.rootView];
        [problems addObject:@"root view detached"];
    }
    if (self.renderer.view.superview != self.rootView) {
        [self.rootView insertSubview:self.renderer.view atIndex:0];
        [problems addObject:@"renderer view detached"];
    }
    if (!self.rootView.claimsEverything) {
        self.rootView.claimsEverything = YES;
        [problems addObject:@"presses were not claimed"];
    }
    if (!self.dwellTimer) {
        [self startDwellTimer];
        [problems addObject:@"dwell loop gone"];
    }
    if (!self.renderer.rendering) {
        self.renderer.rendering = YES;
        [problems addObject:@"renderer stopped"];
    }
    // Re-asserted every tick, not only when stereo is applied: an app launch or
    // an alert can reset it.
    app.idleTimerDisabled = YES;

    if (problems.count > 0) {
        CBBMarkStage([NSString stringWithFormat:@"overlay repaired: %@",
                      [problems componentsJoinedByString:@", "]]);
    }
}

// SpringBoard crashing with the tweak running would otherwise keep SpringBoard
// in a respring loop, because the tweak starts itself on every launch. The flag
// below marks "stereo is running and has not proven itself yet". If it is still
// set at the next start, the previous run died young and stereo comes up off, so
// the phone is usable and four button taps can bring stereo back deliberately.
- (void)armBootGuard {
    // Nothing risky runs while stereo is off, so a respring in that state is not
    // this tweak's fault and must not be counted as a failure.
    if (![self.prefs boolForKey:CBBKeyEnabled]) return;

    if (![self.prefs boolForKey:CBBKeyBootArmed]) {
        [self.prefs setBool:YES forKey:CBBKeyBootArmed];
        [self.prefs synchronize];
    }

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(25.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        CBBController *strongSelf = weakSelf;
        if (!strongSelf) return;
        // Only a run with stereo on has proven anything. A dormant run must keep
        // its failure count, otherwise the guard forgets and retries forever.
        if ([strongSelf.prefs boolForKey:CBBKeyEnabled]) [strongSelf disarmBootGuard];
    });
}

- (void)disarmBootGuard {
    BOOL armed = [self.prefs boolForKey:CBBKeyBootArmed];
    BOOL failed = [self.prefs integerForKey:CBBKeyBootFailures] != 0;
    if (!armed && !failed) return;

    [self.prefs setBool:NO forKey:CBBKeyBootArmed];
    [self.prefs setInteger:0 forKey:CBBKeyBootFailures];
    [self.prefs synchronize];
}

// One bad launch is not enough to give up: the risky extra (SB landscape) is
// dropped and stereo is tried again, so a single crash does not look like "the
// tweak did not load". Two in a row switches stereo off and leaves the tweak
// dormant, which is what stops a respring loop.
- (void)checkBootGuard {
    if (![self.prefs boolForKey:CBBKeyBootArmed]) return;

    [self.prefs setBool:NO forKey:CBBKeyBootArmed];

    // Same reason as in armBootGuard: off on purpose, not a crash.
    if (![self.prefs boolForKey:CBBKeyEnabled]) {
        [self.prefs synchronize];
        return;
    }

    NSInteger failures = [self.prefs integerForKey:CBBKeyBootFailures] + 1;
    [self.prefs setInteger:failures forKey:CBBKeyBootFailures];
    [self.prefs setInteger:CBBHomeLandscapeOff forKey:CBBKeyHomeLandscape];
    if (failures >= 2) {
        [self.prefs setBool:NO forKey:CBBKeyEnabled];
        // One unattended retry, so a bad pair of launches does not leave the
        // tweak dormant until someone finds an SSH prompt. A third failure is
        // taken as "this build cannot run here" and it stays off.
        if (failures == 2) {
            __weak typeof(self) weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                CBBController *strongSelf = weakSelf;
                if (!strongSelf) return;
                CBBLog(@"retrying stereo after the dormant launch");
                [strongSelf setStereoEnabled:YES];
            });
        }
    }
    [self.prefs synchronize];

    CBBLog(@"previous run died early (%ld in a row): SB landscape off, stereo %@",
           (long)failures,
           failures >= 2 ? (failures == 2 ? @"off, one retry in 30s" : @"off until you tap the button 4 times")
                         : @"retried");
}

// SpringBoard lays the home screen out portrait on iPhone unless it is told
// otherwise; CBBHomeLandscape relaxes that policy while stereo is on so the home
// screen fills the landscape eye views instead of appearing sideways.
- (void)applyHomeLandscape {
    BOOL enabled = [self.prefs boolForKey:CBBKeyEnabled] && self.renderer.capture.valid;
    NSInteger stored = [self.prefs integerForKey:CBBKeyHomeLandscape];
    stored = MIN(MAX(stored, (NSInteger)CBBHomeLandscapeOff), (NSInteger)CBBHomeLandscapeRight);
    BOOL forcing = enabled && stored != CBBHomeLandscapeOff;

    // Arm a flag before touching SpringBoard's orientation policy. Twenty secure
    // seconds later it is cleared; if it is still set at startup, the last run
    // died while forcing the orientation and this build must not do it again.
    if (forcing) {
        if (![self.prefs boolForKey:CBBKeyLandscapeArmed]) {
            [self.prefs setBool:YES forKey:CBBKeyLandscapeArmed];
            [self.prefs synchronize];
            __weak typeof(self) weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                CBBController *strongSelf = weakSelf;
                if (!strongSelf) return;
                [strongSelf.prefs setBool:NO forKey:CBBKeyLandscapeArmed];
                [strongSelf.prefs synchronize];
            });
        }
    } else if ([self.prefs boolForKey:CBBKeyLandscapeArmed]) {
        [self.prefs setBool:NO forKey:CBBKeyLandscapeArmed];
        [self.prefs synchronize];
    }

    [[CBBHomeLandscape sharedHelper] applyMode:forcing ? (CBBHomeLandscapeMode)stored : CBBHomeLandscapeOff];

    // UIKit resets the orientation for its own reasons (alerts, the status bar,
    // an app launch), so one request is not enough: keep asking once a second
    // until it takes or the helper has used up its attempts.
    if (forcing && !self.landscapeTimer) {
        __weak typeof(self) weakSelf = self;
        self.landscapeTimer = [NSTimer timerWithTimeInterval:1.0
                                                     repeats:YES
                                                       block:^(NSTimer *timer) {
            CBBController *strongSelf = weakSelf;
            if (!strongSelf) {
                [timer invalidate];
                return;
            }
            [strongSelf landscapeHeartbeat];
        }];
        [[NSRunLoop mainRunLoop] addTimer:self.landscapeTimer forMode:NSRunLoopCommonModes];
    } else if (!forcing && self.landscapeTimer) {
        [self.landscapeTimer invalidate];
        self.landscapeTimer = nil;
    }
}

- (void)landscapeHeartbeat {
    if (![[CBBHomeLandscape sharedHelper] wantsMoreAttempts]) {
        [self.landscapeTimer invalidate];
        self.landscapeTimer = nil;
        return;
    }
    [self applyHomeLandscape];
}

- (void)checkLandscapeCrashGuard {
    if (![self.prefs boolForKey:CBBKeyLandscapeArmed]) return;

    [self.prefs setBool:NO forKey:CBBKeyLandscapeArmed];
    [self.prefs setInteger:CBBHomeLandscapeOff forKey:CBBKeyHomeLandscape];
    [self.prefs synchronize];

    self.hud.promptText = @"SB LANDSCAPE OFF";
    CBBLog(@"last run died while forcing the home screen orientation; SB landscape disabled");
}

- (void)setStereoEnabled:(BOOL)enabled {
    if (enabled && !self.renderer.capture.valid) {
        self.hud.promptText = @"NO CAPTURE SOURCE";
        [self.hud setNeedsDisplay];
        return;
    }
    [self.prefs setBool:enabled forKey:CBBKeyEnabled];
    [self.prefs synchronize];
    // Arming here too, not only at start: re-enabling from the button or from
    // the unattended retry has to be covered by the same crash guard. Turning it
    // off on purpose is not a failure, so it clears the count instead.
    if (enabled) [self armBootGuard];
    else [self disarmBootGuard];
    if (!enabled) {
        self.hudOpen = NO;
        self.hud.hidden = YES;
        self.learning = NO;
        self.rootView.learning = NO;
        self.hud.promptText = nil;
    }
    [self.recognizer cancel];
    [self applyEnabledState];
    [self resetDwellAnchor];
    self.hud.statusText = [self statusText];
    [self.hud setNeedsDisplay];
}

#pragma mark - Button point

- (CGPoint)buttonPointInFixedSpace {
    CGSize size = CBBNativeScreenSize();
    CGFloat x = MIN(MAX([self.prefs doubleForKey:CBBKeyButtonX], 0.0), 1.0);
    CGFloat y = MIN(MAX([self.prefs doubleForKey:CBBKeyButtonY], 0.0), 1.0);

    // Older builds defaulted to the right edge, then to the top centre, and a
    // stored value is indistinguishable from a learned pad. Treat those exact
    // defaults as "never learned" so the current one applies.
    if ((fabs(x - 0.94) < 0.001 && fabs(y - 0.32) < 0.001) ||
        (fabs(x - 0.50) < 0.001 && fabs(y - 0.05) < 0.001)) {
        x = 0.05;
        y = 0.50;
    }

    return CGPointMake(x * size.width, y * size.height);
}

- (void)touchBeganLearningAtPoint:(CGPoint)point {
    CGSize size = CBBNativeScreenSize();
    if (size.width <= 0 || size.height <= 0) return;

    [self.prefs setDouble:point.x / size.width forKey:CBBKeyButtonX];
    [self.prefs setDouble:point.y / size.height forKey:CBBKeyButtonY];
    [self.prefs synchronize];

    self.learning = NO;
    self.rootView.learning = NO;
    self.hud.promptText = nil;
    self.hud.buttonPoint = [self buttonPointInFixedSpace];
    self.rootView.buttonPoint = self.hud.buttonPoint;
    self.hud.statusText = [self statusText];
    [self.hud setNeedsDisplay];

    CBBLog(@"viewer button learned at (%.0f, %.0f)", point.x, point.y);
}

#pragma mark - Raw touches

- (void)handleTouchBeganAtFixedPoint:(CGPoint)point {
    // Written down, not just logged: whether a touch that was injected inside
    // backboardd lands here or on the app underneath is the whole question when
    // an in-app tap does nothing, and UIKit's answer is invisible from a shell
    // otherwise. Five is enough to see a pattern without filling the file.
    static NSInteger touchLogs = 0;
    if (touchLogs < 5) {
        touchLogs++;
        CBBMarkStage([NSString stringWithFormat:
                      @"overlay received a touch at (%.0f,%.0f)%@",
                      point.x, point.y,
                      self.rootView.injectionPassthrough ? @" while injecting" : @""]);
    }

    if (self.tapCalibrating) {
        [self recordTapProbeAtFixedPoint:point];
        return;
    }
    if (self.learning) {
        [self touchBeganLearningAtPoint:point];
        return;
    }
    // A press that reaches this line was claimed by the overlay. If the pad
    // opens the app beneath it and this line is missing from the stages file,
    // the touch went to SpringBoard instead and the claim is what to fix.
    CBBMarkStage([NSString stringWithFormat:@"touch down at (%.0f,%.0f), dot (%.0f,%.0f)",
                  point.x, point.y, self.cursorPosition.x, self.cursorPosition.y]);
    // The click is delivered a fraction of a second after release, and the aim
    // keeps moving in between. Remember where the dot was when the button went
    // down so the tap lands on what the user actually pressed on.
    self.clickLatch = self.cursorPosition;
    [self.recognizer touchDown];
}

- (void)handleTouchEndedAtFixedPoint:(CGPoint)point {
    if (self.tapCalibrating) return;
    if (self.learning) return;
    [self.recognizer touchUp];
}

#pragma mark - Gesture mapping

- (void)clickRecognizer:(CBBClickRecognizer *)recognizer
    didRecognizeClicks:(NSInteger)clickCount
                 held:(BOOL)held {
    CBBMarkStage([NSString stringWithFormat:@"click %ld%@ (hud %d)",
                  (long)clickCount, held ? @" held" : @"", self.hudOpen]);
    if (![self.prefs boolForKey:CBBKeyEnabled]) {
        if (!held && clickCount >= 4) {
            [self setStereoEnabled:YES];
        }
        return;
    }

    if (self.hudOpen) {
        [self handleHudClicks:clickCount held:held];
        return;
    }

    if (held) {
        switch (clickCount) {
            case 1:
                [self.injector pressHome];
                break;
            case 2:
                [self.injector pressHomeTwice];
                break;
            case 3:
                [self setMenuOpen:YES];
                break;
            default:
                // Escape hatch: any 4+ tap hold returns the phone to normal.
                [self setStereoEnabled:NO];
                break;
        }
        return;
    }

    switch (clickCount) {
        case 1:
            [self activateCursor];
            break;
        case 2:
            [self scroll:YES];
            break;
        case 3:
            [self scroll:NO];
            break;
        default:
            [self resetCursor];
            break;
    }
}

#pragma mark - Cursor

- (void)setCursorPosition:(CGPoint)position {
    CGSize size = CBBNativeScreenSize();
    CGFloat margin = 6.0;
    CGPoint clamped = CGPointMake(MIN(MAX(position.x, margin), MAX(size.width - margin, margin)),
                                  MIN(MAX(position.y, margin), MAX(size.height - margin, margin)));
    if (CBBDistance(clamped, _cursorPosition) > CBBDwellRadius) {
        _cursorPosition = clamped;
        [self resetDwellAnchor];
    } else {
        _cursorPosition = clamped;
    }
    self.renderer.cursor = _cursorPosition;
}

- (void)updateCursorPoint {
    self.renderer.cursor = self.cursorPosition;
}

// aim.x is yaw and aim.y is pitch in radians, both relative to the recentred
// pose. Looking further than the configured range simply pins the dot to the
// edge of the panel.
- (void)applyAim:(CGPoint)aim {
    if (self.hudOpen || self.learning) return;
    if (![self.prefs boolForKey:CBBKeyEnabled]) return;

    // One angular range for both axes, so a head movement in any direction moves
    // the dot the same way and diagonals do not favour one axis. Yaw is unwrapped
    // by CBBMotionPointer and clamped here, so the circle of head positions maps
    // onto the whole panel instead of stopping at a seam.
    CGFloat sensitivity = MIN(MAX([self.prefs doubleForKey:CBBKeyAimSensitivity], 0.2), 3.0);
    CGFloat maxAngle = 0.30 / sensitivity;

    // A reference captured in a different pose (flat on a desk, then worn) leaves
    // the aim several times outside its range, which shows up as a dot that will
    // not travel on one axis. Re-capture instead of waiting for the user to
    // remember the 4-tap recentre. Aiming at a real corner stays at 1x, well
    // below this threshold, so normal pointing never re-centres itself.
    CGFloat offRange = MAX(fabs(aim.x), fabs(aim.y)) / maxAngle;
    if (offRange > 2.0) {
        NSTimeInterval now = CACurrentMediaTime();
        if (self.aimOutOfRangeSince <= 0.0) {
            self.aimOutOfRangeSince = now;
        } else if (now - self.aimOutOfRangeSince > 0.4) {
            self.aimOutOfRangeSince = 0.0;
            [self resetCursor];
            return;
        }
    } else {
        self.aimOutOfRangeSince = 0.0;
    }

    CGFloat ax = MIN(MAX(aim.x / maxAngle, -1.0), 1.0);
    CGFloat ay = MIN(MAX(aim.y / maxAngle, -1.0), 1.0);

    CGSize size = CBBNativeScreenSize();
    CGFloat radians = (CGFloat)[self.prefs integerForKey:CBBKeyRotation] * (CGFloat)M_PI / 180.0;

    // The eyes sit on the panel's long axis and the picture is rotated by the
    // rotation setting, so the picture's own right and down are rotated too.
    CGPoint up = CBBCardboardRotate(CGPointMake(0.0, -1.0), -radians);
    CGPoint right = CBBCardboardRotate(up, (CGFloat)M_PI_2);
    // Down is the opposite of up, not a quarter turn from it: rotating up by -90
    // degrees gives -right, which collapsed yaw and pitch onto the same line and
    // left the dot unable to travel on one axis at all.
    CGPoint down = CGPointMake(-up.x, -up.y);

    // A mirrored capture reverses the picture, so the head has to drive the
    // picture's axes backwards to keep "look right" moving the dot right. Which
    // aim axis a panel axis carries depends on the quarter turn.
    NSInteger mirror = [self.prefs integerForKey:CBBKeyMirror];
    if (mirror != 0) {
        BOOL pictureHorizontalIsPanelX = fabs(right.x) > fabs(right.y);
        if (mirror & 1) {
            if (pictureHorizontalIsPanelX) ax = -ax;
            else ay = -ay;
        }
        if (mirror & 2) {
            if (pictureHorizontalIsPanelX) ay = -ay;
            else ax = -ax;
        }
    }

    // The picture is turned on its side, so its two axes cover different amounts
    // of the panel: project each one onto the panel's own extent. Without this a
    // quarter turn makes one axis overshoot an edge almost at once while the
    // other can never reach the far one, and the dot is stuck on a line.
    CGPoint center = CGPointMake(size.width * 0.5, size.height * 0.5);
    CGFloat extentRight = (fabs(right.x) * size.width + fabs(right.y) * size.height) * 0.5;
    CGFloat extentDown = (fabs(down.x) * size.width + fabs(down.y) * size.height) * 0.5;
    CGFloat alongRight = ax * extentRight;
    CGFloat alongDown = -ay * extentDown;
    self.cursorPosition = CGPointMake(center.x + right.x * alongRight + down.x * alongDown,
                                      center.y + right.y * alongRight + down.y * alongDown);

    // The dwell loop has to exist whenever the stereo view runs. It is started
    // from -applyEnabledState, which runs once: if the display capture was not
    // valid at that instant the timer was never created and nothing ever
    // restarted it, which looks exactly like a dot that will not click.
    if (!self.dwellTimer && self.renderer.rendering) [self startDwellTimer];
}

- (void)resetCursor {
    CGSize size = CBBNativeScreenSize();
    [self.motionPointer recenter];
    self.cursorPosition = CGPointMake(size.width * 0.5, size.height * 0.5);
    [self resetDwellAnchor];
}

#pragma mark - Dwell to click

// Hold-to-click: if the dot rests inside a small disc for 1 s, it clicks
// there with no button press. The dot lives in VR space (the lens-warped
// stereo picture), which is not where SpringBoard thinks things are, so the
// click goes through the same dot -> injector map as the button clicks
// (-injectionPointForPoint:, measured by tap calibration). The dwell point is
// the VR dot; the injected point is the mapped SB point.
- (void)resetDwellAnchor {
    self.dwellAnchor = self.cursorPosition;
    self.dwellAnchorTime = CACurrentMediaTime();
    self.dwellFired = NO;
    self.renderer.dwellProgress = 0.0;
}

- (void)startDwellTimer {
    if (self.dwellTimer) return;
    __weak typeof(self) weakSelf = self;
    self.dwellTimer = [NSTimer timerWithTimeInterval:0.1
                                             repeats:YES
                                               block:^(NSTimer *timer) {
        [weakSelf dwellTick];
    }];
    [[NSRunLoop mainRunLoop] addTimer:self.dwellTimer forMode:NSRunLoopCommonModes];
    [self resetDwellAnchor];
    CBBMarkStage([NSString stringWithFormat:@"dwell loop started (radius %.0f pt, hold %.1f s)",
                  CBBDwellRadius, CBBDwellHoldSeconds]);
}

- (void)stopDwellTimer {
    [self.dwellTimer invalidate];
    self.dwellTimer = nil;
    self.renderer.dwellProgress = 0.0;
}

- (void)dwellTick {
    if (![self.prefs boolForKey:CBBKeyEnabled] ||
        ![self.prefs boolForKey:CBBKeyDwellClick] ||
        !self.renderer.rendering ||
        self.hudOpen || self.learning || self.tapCalibrating ||
        self.rootView.injectionPassthrough) {
        self.renderer.dwellProgress = 0.0;
        self.dwellAnchor = self.cursorPosition;
        self.dwellAnchorTime = CACurrentMediaTime();
        self.dwellFired = NO;
        return;
    }
    NSTimeInterval now = CACurrentMediaTime();
    CGFloat drift = CBBDistance(self.cursorPosition, self.dwellAnchor);
    if (drift > CBBDwellRadius) {
        self.dwellAnchor = self.cursorPosition;
        self.dwellAnchorTime = now;
        self.dwellFired = NO;
        self.renderer.dwellProgress = 0.0;
        return;
    }
    if (!self.dwellFired && drift > CBBDwellRadius * 0.5) {
        // Walk the anchor a fraction of the way toward the dot. Slow drift (the
        // pulse in a thumb, a head settling) then never accumulates into the
        // reset above, while a deliberate glance still leaves the radius and
        // restarts the hold. The click itself always uses the live dot.
        self.dwellAnchor = CGPointMake(self.dwellAnchor.x + (self.cursorPosition.x - self.dwellAnchor.x) * 0.25,
                                       self.dwellAnchor.y + (self.cursorPosition.y - self.dwellAnchor.y) * 0.25);
    }
    if (self.dwellFired) {
        self.renderer.dwellProgress = 0.0;
        return;
    }
    double held = now - self.dwellAnchorTime;
    double progress = held / CBBDwellHoldSeconds;
    self.renderer.dwellProgress = (CGFloat)MIN(MAX(progress, 0.0), 1.0);
    if (held >= CBBDwellHoldSeconds) {
        self.dwellFired = YES;
        self.renderer.dwellProgress = 0.0;
        [self dwellClickAtPoint:self.cursorPosition];
    }
}

- (void)dwellClickAtPoint:(CGPoint)point {
    CGPoint injected = [self injectionPointForPoint:point];
    CBBMarkStage([NSString stringWithFormat:@"dwell tap dot (%.0f,%.0f) -> inject (%.0f,%.0f)",
                  point.x, point.y, injected.x, injected.y]);
    [self beginInjectionWindow];
    @try {
        [self.injector tapAtPoint:injected];
    } @catch (NSException *exception) {
        CBBMarkStage([NSString stringWithFormat:@"dwell tap threw %@: %@",
                      exception.name, exception.reason]);
    }
    [self resetDwellAnchor];
}

// A tap leaves here as panel points and reaches the system as normalised HID
// coordinates, and this build turns those into a delivered point with a mapping
// nothing documents: the interface is forced landscape while the digitizer is
// portrait, so "x" means three different things along the way. Instead of
// guessing (the old Tap rotate knob did exactly that), the mapping is measured —
// see -startTapCalibration — and stored inverted, as the affine that takes the
// point under the dot to the point that has to be injected:
// x' = a*x + b*y + tx, y' = c*x + d*y + ty.
static CGPoint CBBApplyCalibratedTap(CBBPrefs *prefs, CGPoint point) {
    double a = [prefs doubleForKey:CBBKeyTapA];
    double b = [prefs doubleForKey:CBBKeyTapB];
    double c = [prefs doubleForKey:CBBKeyTapC];
    double d = [prefs doubleForKey:CBBKeyTapD];
    double tx = [prefs doubleForKey:CBBKeyTapTX];
    double ty = [prefs doubleForKey:CBBKeyTapTY];
    return CGPointMake(a * point.x + b * point.y + tx,
                       c * point.x + d * point.y + ty);
}

- (CGPoint)injectionPointForPoint:(CGPoint)point {
    CGSize size = CBBNativeScreenSize();
    CGPoint result = point;

    if ([self.prefs boolForKey:CBBKeyTapCalibrated]) {
        // Stored inverted by -finishTapCalibration: dot point in, injector point
        // out, so the tap arrives under the dot.
        result = CBBApplyCalibratedTap(self.prefs, point);
    } else {
        // Until the first measurement lands, the manual quarter-turn knob is all
        // there is. Once calibrated, this is ignored.
        NSInteger degrees = ((NSInteger)[self.prefs integerForKey:CBBKeyTapRotation] % 360 + 360) % 360;
        if (degrees != 0) {
            CGPoint center = CGPointMake(size.width * 0.5, size.height * 0.5);
            CGPoint relative = CGPointMake(point.x - center.x, point.y - center.y);
            CGPoint turned = CBBCardboardRotate(relative, (CGFloat)degrees * (CGFloat)M_PI / 180.0);
            result = CGPointMake(center.x + turned.x, center.y + turned.y);
        }
    }

    // A measured map can place a corner just outside the panel; the unit
    // coordinate derived from it has to stay inside.
    return CGPointMake(MIN(MAX(result.x, 0.0), size.width),
                       MIN(MAX(result.y, 0.0), size.height));
}

#pragma mark - Tap calibration

- (NSInteger)currentInterfaceOrientation {
    return (NSInteger)[UIApplication sharedApplication].statusBarOrientation;
}

// The measured map depends on the interface the taps are delivered into, which
// is exactly what the forced landscape changes. Run once the picture has had a
// few seconds to settle, and again whenever that orientation really changes.
- (void)scheduleTapCalibration {
    if (![self.prefs boolForKey:CBBKeyEnabled] || !self.renderer.capture.valid) return;

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        CBBController *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (strongSelf.tapCalibrating) return;
        if (![strongSelf.prefs boolForKey:CBBKeyEnabled]) return;
        NSInteger orientation = [strongSelf currentInterfaceOrientation];
        if ([strongSelf.prefs boolForKey:CBBKeyTapCalibrated] &&
            [strongSelf.prefs integerForKey:CBBKeyTapCalibrationOrientation] == orientation) {
            return;
        }
        [strongSelf startTapCalibration];
    });
}

- (void)startTapCalibration {
    if (self.tapCalibrating) return;
    if (![self.prefs boolForKey:CBBKeyEnabled] || !self.renderer.rendering) return;

    CGSize size = CBBNativeScreenSize();
    if (size.width <= 0 || size.height <= 0) return;

    // Three spread out, non-collinear points: an affine map has six unknowns and
    // three point pairs give exactly six equations.
    _tapExpected[0] = CGPointMake(size.width * 0.22, size.height * 0.26);
    _tapExpected[1] = CGPointMake(size.width * 0.74, size.height * 0.33);
    _tapExpected[2] = CGPointMake(size.width * 0.38, size.height * 0.74);

    self.tapCalibrating = YES;
    self.tapProbeIndex = 0;
    CBBMarkStage(@"tap calibration started");
    [self sendTapProbe];
}

// Each probe is a real injected touch, and it is deliberately *not* passed
// through: the overlay claims it so the arrival point can be read. SpringBoard's
// windows are inert while stereo is on, so a probe that escaped could not open
// anything either way.
- (void)sendTapProbe {
    if (!self.tapCalibrating || self.tapProbeIndex >= 3) return;

    self.tapProbeSentTime = CACurrentMediaTime();
    [self.injector tapAtPoint:_tapExpected[self.tapProbeIndex]];

    [self.tapCalibrationTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.tapCalibrationTimer = [NSTimer timerWithTimeInterval:1.5
                                                     repeats:NO
                                                       block:^(NSTimer *timer) {
        CBBController *strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.tapCalibrating) return;
        strongSelf.tapCalibrating = NO;
        strongSelf.tapCalibrationTimer = nil;
        // Nothing came back, so the overlay is not owning touches at all. That
        // is a different fault from a wrong transform: report it and keep any
        // working calibration instead of writing one from no data.
        CBBMarkStage([NSString stringWithFormat:
                      @"tap calibration gave up at probe %ld: the overlay never received the touch",
                      (long)strongSelf.tapProbeIndex + 1]);
    }];
    [[NSRunLoop mainRunLoop] addTimer:self.tapCalibrationTimer forMode:NSRunLoopCommonModes];
}

- (void)recordTapProbeAtFixedPoint:(CGPoint)point {
    if (!self.tapCalibrating || self.tapProbeIndex >= 3) return;

    // Only the injected probe comes back this quickly. A press arriving later
    // than that is the user's own thumb, and using it as a measurement would
    // poison the map; ignore it and keep waiting for the real probe.
    if (CACurrentMediaTime() - self.tapProbeSentTime > 0.6) return;

    _tapObserved[self.tapProbeIndex] = point;
    CBBMarkStage([NSString stringWithFormat:@"tap probe %ld: asked (%.0f,%.0f), got (%.0f,%.0f)",
                  (long)self.tapProbeIndex + 1,
                  _tapExpected[self.tapProbeIndex].x, _tapExpected[self.tapProbeIndex].y,
                  point.x, point.y]);

    self.tapProbeIndex += 1;
    [self.tapCalibrationTimer invalidate];
    self.tapCalibrationTimer = nil;

    if (self.tapProbeIndex >= 3) {
        [self finishTapCalibration];
        return;
    }

    // Let the previous probe be released and the system settle: two probes close
    // enough together arrive as a multi-touch and measure nothing.
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf sendTapProbe];
    });
}

- (void)finishTapCalibration {
    self.tapCalibrating = NO;
    [self.tapCalibrationTimer invalidate];
    self.tapCalibrationTimer = nil;

    CGPoint p1 = _tapExpected[0], p2 = _tapExpected[1], p3 = _tapExpected[2];
    CGPoint q1 = _tapObserved[0], q2 = _tapObserved[1], q3 = _tapObserved[2];

    // A = V * U^-1, with U the probe offsets and V the measured offsets.
    double ux2 = p2.x - p1.x, uy2 = p2.y - p1.y;
    double ux3 = p3.x - p1.x, uy3 = p3.y - p1.y;
    double det = ux2 * uy3 - ux3 * uy2;
    if (fabs(det) < 1.0) {
        CBBMarkStage(@"tap calibration abandoned: the probes are collinear");
        return;
    }

    double vx2 = q2.x - q1.x, vy2 = q2.y - q1.y;
    double vx3 = q3.x - q1.x, vy3 = q3.y - q1.y;

    double i00 = uy3 / det, i01 = -ux3 / det;
    double i10 = -uy2 / det, i11 = ux2 / det;

    double a = vx2 * i00 + vx3 * i10;
    double b = vx2 * i01 + vx3 * i11;
    double c = vy2 * i00 + vy3 * i10;
    double d = vy2 * i01 + vy3 * i11;
    double tx = q1.x - (a * p1.x + b * p1.y);
    double ty = q1.y - (c * p1.x + d * p1.y);

    // A map that would fling taps off the panel, or one that collapses the
    // panel to a line, is a bad measurement and not an optics fact; keep the
    // previous calibration instead. NaN fails every comparison below, so it is
    // rejected by the same test.
    double det2 = a * d - b * c;
    if (!(fabs(a) < 100.0 && fabs(b) < 100.0 && fabs(c) < 100.0 && fabs(d) < 100.0 &&
          fabs(tx) < 10000.0 && fabs(ty) < 10000.0) ||
        fabs(det2) < 0.05) {
        CBBMarkStage(@"tap calibration rejected: the measured map is degenerate");
        return;
    }

    // The measurement gives asked -> arrived. A click needs the opposite: given
    // the point the dot is on, what has to be injected for it to arrive there.
    // So the inverse is what gets stored.
    double ia = d / det2, ib = -b / det2;
    double ic = -c / det2, id = a / det2;
    double itx = -(ia * tx + ib * ty);
    double ity = -(ic * tx + id * ty);

    [self.prefs setDouble:ia forKey:CBBKeyTapA];
    [self.prefs setDouble:ib forKey:CBBKeyTapB];
    [self.prefs setDouble:ic forKey:CBBKeyTapC];
    [self.prefs setDouble:id forKey:CBBKeyTapD];
    [self.prefs setDouble:itx forKey:CBBKeyTapTX];
    [self.prefs setDouble:ity forKey:CBBKeyTapTY];
    [self.prefs setBool:YES forKey:CBBKeyTapCalibrated];
    [self.prefs setInteger:[self currentInterfaceOrientation] forKey:CBBKeyTapCalibrationOrientation];
    [self.prefs synchronize];

    CBBMarkStage([NSString stringWithFormat:
                  @"tap calibration stored (asked -> arrived a %.3f b %.3f c %.3f d %.3f t (%.0f,%.0f)); clicks use its inverse",
                  a, b, c, d, tx, ty]);
}

- (void)activateCursor {
    [self resetDwellAnchor];
    CGPoint point = self.clickLatch;
    if (point.x == 0.0 && point.y == 0.0) point = self.cursorPosition;
    CGPoint injected = [self injectionPointForPoint:point];
    // The dot is drawn from the same point the tap is sent to, so a click that
    // opens something other than what the dot covers means the two diverged.
    // Recording both makes that visible in the stages file instead of guesswork.
    CBBMarkStage([NSString stringWithFormat:@"tap dot (%.0f,%.0f) -> inject (%.0f,%.0f)",
                  point.x, point.y, injected.x, injected.y]);
    [self beginInjectionWindow];
    [self.injector tapAtPoint:injected];
}

- (void)scroll:(BOOL)downward {
    CGSize size = CBBNativeScreenSize();
    // Landscape: the picture is turned on its side, so a page runs along the
    // panel's long axis.
    CGFloat near = 0.62, far = 0.38;
    CGPoint from = CGPointMake(size.width * near, size.height * 0.5);
    CGPoint to = CGPointMake(size.width * far, size.height * 0.5);
    if (!downward) {
        CGPoint swap = from;
        from = to;
        to = swap;
    }

    [self beginInjectionWindow];
    [self.injector swipeFromPoint:[self injectionPointForPoint:from]
                         toPoint:[self injectionPointForPoint:to]
                        duration:0.32];
}

#pragma mark - HUD

- (void)setMenuOpen:(BOOL)open {
    [self resetDwellAnchor];
    if (!open && self.learning) {
        self.learning = NO;
        self.rootView.learning = NO;
        self.hud.promptText = nil;
    }
    self.hudOpen = open;
    self.hud.hidden = !(open && self.renderer.rendering);
    self.hud.selectedIndex = self.hudSelection;
    self.hud.statusText = [self statusText];
    self.hud.showButtonMarker = open;
    self.hud.buttonPoint = [self buttonPointInFixedSpace];
    [self.hud setNeedsDisplay];
}

- (CBBHudRow *)selectedRow {
    if (self.rows.count == 0) return nil;
    NSInteger index = MAX((NSInteger)0, MIN(self.hudSelection, (NSInteger)self.rows.count - 1));
    return self.rows[(NSUInteger)index];
}

- (void)handleHudClicks:(NSInteger)clickCount held:(BOOL)held {
    CBBHudRow *row = [self selectedRow];

    if (held) {
        if (clickCount <= 1) {
            [self setMenuOpen:NO];
            return;
        }
        if (row.step) row.step(clickCount == 2 ? 10 : -10);
        [self.hud setNeedsDisplay];
        return;
    }

    switch (clickCount) {
        case 1: {
            NSInteger count = (NSInteger)self.rows.count;
            if (count > 0) self.hudSelection = (self.hudSelection + 1) % count;
            self.hud.selectedIndex = self.hudSelection;
            break;
        }
        case 2:
            if (row.step) row.step(1);
            break;
        case 3:
            if (row.step) row.step(-1);
            break;
        default:
            if (row.activate) row.activate();
            break;
    }
    [self.hud setNeedsDisplay];
}

- (void)beginLearning {
    self.learning = YES;
    self.rootView.learning = YES;
    self.hud.promptText = @"PRESS THE VIEWER BUTTON";
    self.hud.statusText = @"Listening for the next screen touch. The whole screen is armed.";
    [self.hud setNeedsDisplay];
}

- (void)adjustDouble:(NSString *)key min:(double)minimum max:(double)maximum step:(double)step direction:(NSInteger)direction {
    double value = [self.prefs doubleForKey:key];
    value += step * (double)direction;
    value = MIN(MAX(value, minimum), maximum);
    [self.prefs setDouble:value forKey:key];
    [self.prefs synchronize];
    [self.hud setNeedsDisplay];
}

- (void)rebuildRows {
    __weak typeof(self) weakSelf = self;
    CBBPrefs *prefs = self.prefs;
    NSMutableArray<CBBHudRow *> *rows = [NSMutableArray array];

    [rows addObject:[CBBHudRow rowWithTitle:@"Stereo"
                                  valueText:^NSString * { return [prefs boolForKey:CBBKeyEnabled] ? @"ON" : @"OFF"; }
                                       step:^(NSInteger direction) {
                                           [weakSelf setStereoEnabled:![prefs boolForKey:CBBKeyEnabled]];
                                       }]];

    [rows addObject:[CBBHudRow rowWithTitle:@"View"
                                  valueText:^NSString * { return [prefs integerForKey:CBBKeyMode] == 1 ? @"1:1" : @"FILL"; }
                                       step:^(NSInteger direction) {
                                           NSInteger mode = [prefs integerForKey:CBBKeyMode];
                                           mode = (mode + (direction > 0 ? 1 : -1) + 2) % 2;
                                           [prefs setInteger:mode forKey:CBBKeyMode];
                                           [prefs synchronize];
                                           [weakSelf.hud setNeedsDisplay];
                                       }]];

    [rows addObject:[CBBHudRow rowWithTitle:@"Zoom"
                                  valueText:^NSString * { return [NSString stringWithFormat:@"%.1fx", [prefs doubleForKey:CBBKeyZoom]]; }
                                       step:^(NSInteger direction) {
                                           [weakSelf adjustDouble:CBBKeyZoom min:0.6 max:3.0 step:0.1 direction:direction];
                                       }]];

    [rows addObject:[CBBHudRow rowWithTitle:@"Rotation"
                                  valueText:^NSString * { return [NSString stringWithFormat:@"%ld", (long)[prefs integerForKey:CBBKeyRotation]]; }
                                       step:^(NSInteger direction) {
                                           NSInteger rotation = [prefs integerForKey:CBBKeyRotation];
                                           rotation = (rotation + (direction > 0 ? 90 : -90) + 360) % 360;
                                           [prefs setInteger:rotation forKey:CBBKeyRotation];
                                           [prefs synchronize];
                                           [weakSelf.hud setRotationDegrees:(CGFloat)rotation];
                                       }]];

    [rows addObject:[CBBHudRow rowWithTitle:@"Lens k1"
                                  valueText:^NSString * { return [NSString stringWithFormat:@"%.2f", [prefs doubleForKey:CBBKeyK1]]; }
                                       step:^(NSInteger direction) {
                                           [weakSelf adjustDouble:CBBKeyK1 min:0.0 max:0.60 step:0.02 direction:direction];
                                       }]];

    [rows addObject:[CBBHudRow rowWithTitle:@"Lens k2"
                                  valueText:^NSString * { return [NSString stringWithFormat:@"%.2f", [prefs doubleForKey:CBBKeyK2]]; }
                                       step:^(NSInteger direction) {
                                           [weakSelf adjustDouble:CBBKeyK2 min:0.0 max:0.80 step:0.02 direction:direction];
                                       }]];

    [rows addObject:[CBBHudRow rowWithTitle:@"Chroma"
                                  valueText:^NSString * { return [NSString stringWithFormat:@"%.2f", [prefs doubleForKey:CBBKeyChroma]]; }
                                       step:^(NSInteger direction) {
                                           [weakSelf adjustDouble:CBBKeyChroma min:0.0 max:1.0 step:0.05 direction:direction];
                                       }]];

    [rows addObject:[CBBHudRow rowWithTitle:@"Curvature"
                                  valueText:^NSString * { return [NSString stringWithFormat:@"%.2f", [prefs doubleForKey:CBBKeyCurvature]]; }
                                       step:^(NSInteger direction) {
                                           [weakSelf adjustDouble:CBBKeyCurvature min:0.0 max:1.0 step:0.05 direction:direction];
                                       }]];

    [rows addObject:[CBBHudRow rowWithTitle:@"Parallax"
                                  valueText:^NSString * { return [NSString stringWithFormat:@"%.3f", [prefs doubleForKey:CBBKeyParallax]]; }
                                       step:^(NSInteger direction) {
                                           // The Cardboard v2 lens offset is 0.11 on this panel, so the
                                           // range has to reach past it and go both ways.
                                           [weakSelf adjustDouble:CBBKeyParallax min:-0.20 max:0.20 step:0.005 direction:direction];
                                       }]];

    [rows addObject:[CBBHudRow rowWithTitle:@"Brightness"
                                  valueText:^NSString * { return [NSString stringWithFormat:@"%.2f", [prefs doubleForKey:CBBKeyBrightness]]; }
                                       step:^(NSInteger direction) {
                                           [weakSelf adjustDouble:CBBKeyBrightness min:0.3 max:1.5 step:0.05 direction:direction];
                                       }]];

    [rows addObject:[CBBHudRow rowWithTitle:@"Vignette"
                                  valueText:^NSString * { return [NSString stringWithFormat:@"%.2f", [prefs doubleForKey:CBBKeyVignette]]; }
                                       step:^(NSInteger direction) {
                                           [weakSelf adjustDouble:CBBKeyVignette min:0.0 max:0.8 step:0.05 direction:direction];
                                       }]];

    [rows addObject:[CBBHudRow rowWithTitle:@"Hide overlay"
                                  valueText:^NSString * { return [prefs boolForKey:CBBKeyHideFromCapture] ? @"ON" : @"OFF"; }
                                       step:^(NSInteger direction) {
                                           [prefs setBool:![prefs boolForKey:CBBKeyHideFromCapture] forKey:CBBKeyHideFromCapture];
                                           [prefs synchronize];
                                           [weakSelf applyEnabledState];
                                       }]];

    [rows addObject:[CBBHudRow rowWithTitle:@"Aim sensitivity"
                                  valueText:^NSString * { return [NSString stringWithFormat:@"%.1fx", [prefs doubleForKey:CBBKeyAimSensitivity]]; }
                                       step:^(NSInteger direction) {
                                           [weakSelf adjustDouble:CBBKeyAimSensitivity min:0.3 max:3.0 step:0.1 direction:direction];
                                       }]];

    [rows addObject:[CBBHudRow rowWithTitle:@"Dwell click"
                                  valueText:^NSString * { return [prefs boolForKey:CBBKeyDwellClick] ? @"3s ON" : @"OFF"; }
                                       step:^(NSInteger direction) {
                                           [prefs setBool:![prefs boolForKey:CBBKeyDwellClick] forKey:CBBKeyDwellClick];
                                           [prefs synchronize];
                                           [weakSelf resetDwellAnchor];
                                           [weakSelf.hud setNeedsDisplay];
                                       }]];

    [rows addObject:[CBBHudRow rowWithTitle:@"Calibrate taps"
                                  valueText:^NSString * {
                                      return [prefs boolForKey:CBBKeyTapCalibrated] ? @"AUTO" : @"›";
                                  }
                                    activate:^{
                                        [weakSelf startTapCalibration];
                                    }]];

    [rows addObject:[CBBHudRow rowWithTitle:@"Mirror"
                                  valueText:^NSString * {
                                      switch ([prefs integerForKey:CBBKeyMirror] & 3) {
                                          case 1: return @"U";
                                          case 2: return @"V";
                                          case 3: return @"U+V";
                                          default: return @"NONE";
                                      }
                                  }
                                       step:^(NSInteger direction) {
                                           NSInteger mirror = ([prefs integerForKey:CBBKeyMirror] + (direction > 0 ? 1 : 3)) & 3;
                                           [prefs setInteger:mirror forKey:CBBKeyMirror];
                                           [prefs synchronize];
                                           [weakSelf.hud setNeedsDisplay];
                                       }]];

    [rows addObject:[CBBHudRow rowWithTitle:@"SB landscape"
                                  valueText:^NSString * {
                                      switch ([prefs integerForKey:CBBKeyHomeLandscape]) {
                                          case CBBHomeLandscapeOff: return @"OFF";
                                          case CBBHomeLandscapeLeft: return @"LEFT";
                                          case CBBHomeLandscapeRight: return @"RIGHT";
                                          default: return @"AUTO";
                                      }
                                  }
                                       step:^(NSInteger direction) {
                                           NSInteger mode = [prefs integerForKey:CBBKeyHomeLandscape];
                                           mode = (mode + (direction > 0 ? 1 : 3)) % 4;
                                           [prefs setInteger:mode forKey:CBBKeyHomeLandscape];
                                           [prefs synchronize];
                                           [weakSelf applyHomeLandscape];
                                           [weakSelf.hud setNeedsDisplay];
                                       }]];

    [rows addObject:[CBBHudRow rowWithTitle:@"Capture FPS"
                                  valueText:^NSString * { return [NSString stringWithFormat:@"%ld", (long)[prefs integerForKey:CBBKeyCaptureFPS]]; }
                                       step:^(NSInteger direction) {
                                           NSInteger fps = [prefs integerForKey:CBBKeyCaptureFPS];
                                           NSInteger options[3] = {15, 30, 60};
                                           NSInteger closest = 1;
                                           for (NSInteger i = 0; i < 3; i++) {
                                               if (labs((long)(options[i] - fps)) < labs((long)(options[closest] - fps))) closest = i;
                                           }
                                           closest = (closest + (direction > 0 ? 1 : 2)) % 3;
                                           [prefs setInteger:options[closest] forKey:CBBKeyCaptureFPS];
                                           [prefs synchronize];
                                           [weakSelf.hud setNeedsDisplay];
                                       }]];

    [rows addObject:[CBBHudRow rowWithTitle:@"Learn button"
                                  valueText:^NSString * { return @"›"; }
                                    activate:^{
                                        [weakSelf beginLearning];
                                    }]];

    [rows addObject:[CBBHudRow rowWithTitle:@"Recenter aim"
                                  valueText:^NSString * { return @"›"; }
                                    activate:^{
                                        [weakSelf resetCursor];
                                    }]];

    [rows addObject:[CBBHudRow rowWithTitle:@"Reset settings"
                                  valueText:^NSString * { return @"›"; }
                                    activate:^{
                                        [prefs resetAll];
                                        [weakSelf rebuildRows];
                                        [weakSelf layoutOverlay];
                                        [weakSelf applyEnabledState];
                                    }]];

    [rows addObject:[CBBHudRow rowWithTitle:@"Close menu"
                                  valueText:^NSString * { return @"›"; }
                                    activate:^{
                                        [weakSelf setMenuOpen:NO];
                                    }]];

    self.rows = rows;
    self.hud.rows = rows;
    self.hudSelection = MIN(self.hudSelection, MAX((NSInteger)rows.count - 1, (NSInteger)0));
    self.hud.selectedIndex = self.hudSelection;
}

- (NSString *)statusText {
    CGPoint button = [self buttonPointInFixedSpace];
    NSString *header = [NSString stringWithFormat:@"btn (%.0f,%.0f)  zoom %.1fx  %ldfps  %@",
                        button.x, button.y,
                        [self.prefs doubleForKey:CBBKeyZoom],
                        (long)[self.prefs integerForKey:CBBKeyCaptureFPS],
                        [self.prefs integerForKey:CBBKeyMode] == 1 ? @"1:1" : @"fill"];

    if (![self.prefs boolForKey:CBBKeyEnabled]) {
        return [header stringByAppendingString:@"\nStereo is OFF. Tap the viewer button 4 times to return."];
    }
    if (self.hudOpen) {
        return [header stringByAppendingString:@"\n1 next row · 2 +1 · 3 −1 · 4 activate · press-and-hold: close"];
    }
    NSString *dwell = [self.prefs boolForKey:CBBKeyDwellClick] ? @"rest 3s clicks · " : @"";
    return [header stringByAppendingString:[NSString stringWithFormat:@"\nAim with your head · %@1 click · 2 scroll down · 3 scroll up · 4 recentre\nhold 1 home · 2 switcher · 3 menu · 4 stereo off", dwell]];
}

@end
