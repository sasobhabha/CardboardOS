#import "CBBPrefs.h"
#import "CBBCompat.h"

NSString * const CBBKeyEnabled      = @"enabled";
NSString * const CBBKeyZoom         = @"zoom";
NSString * const CBBKeyMode         = @"mode";
NSString * const CBBKeyRotation     = @"rotation";
NSString * const CBBKeyK1           = @"k1";
NSString * const CBBKeyK2           = @"k2";
NSString * const CBBKeyChroma       = @"chroma";
NSString * const CBBKeyCurvature    = @"curvature";
NSString * const CBBKeyParallax     = @"parallax";
NSString * const CBBKeyBrightness   = @"brightness";
NSString * const CBBKeyVignette     = @"vignette";
NSString * const CBBKeyCursorStep   = @"cursorStep";
NSString * const CBBKeyGridColumns  = @"gridColumns";
NSString * const CBBKeyAimSensitivity = @"aimSensitivity";
NSString * const CBBKeyHomeLandscape = @"homeLandscape";
NSString * const CBBKeyMirror        = @"mirror";
NSString * const CBBKeyTapRotation   = @"tapRotation";
NSString * const CBBKeyTapA          = @"tapA";
NSString * const CBBKeyTapB          = @"tapB";
NSString * const CBBKeyTapC          = @"tapC";
NSString * const CBBKeyTapD          = @"tapD";
NSString * const CBBKeyTapTX         = @"tapTX";
NSString * const CBBKeyTapTY         = @"tapTY";
NSString * const CBBKeyTapCalibrated = @"tapCalibrated";
NSString * const CBBKeyTapCalibrationOrientation = @"tapCalibrationOrientation";
NSString * const CBBKeyLandscapeArmed  = @"landscapeArmed";
NSString * const CBBKeyBootArmed       = @"bootArmed";
NSString * const CBBKeyBootFailures    = @"bootFailures";
NSString * const CBBKeyButtonX      = @"buttonX";
NSString * const CBBKeyButtonY      = @"buttonY";NSString * const CBBKeyCaptureFPS  = @"captureFPS";
NSString * const CBBKeyHideFromCapture = @"hideFromCapture";
NSString * const CBBKeyDwellClick = @"dwellClick";

NSString * const CBBModeFill   = @"fill";
NSString * const CBBModeNative = @"native";

static NSString * const kCBBDomain = @"com.buffy.cardboardos";

@implementation CBBPrefs {
    NSUserDefaults *_defaults;
    NSDictionary *_fallbacks;
}

+ (instancetype)sharedPrefs {
    static CBBPrefs *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[CBBPrefs alloc] init];
    });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _defaults = [[NSUserDefaults alloc] initWithSuiteName:kCBBDomain];
        _fallbacks = @{
            CBBKeyEnabled:     @YES,
            CBBKeyZoom:        @1.0,
            CBBKeyMode:        @0,       // 0 = fill, 1 = native 1:1 window
            CBBKeyRotation:    @90,      // degrees applied to the captured panel
            // Google Cardboard v2 / I/O 2015 viewer profile: k1 0.34, k2 0.55.
            CBBKeyK1:          @0.34,    // inverse barrel distortion, first term
            CBBKeyK2:          @0.55,    // second term
            CBBKeyChroma:      @0.50,
            CBBKeyCurvature:   @0.25,
            // That viewer's lenses are 64 mm apart, so on this panel (88.5 mm
            // along the eye axis) each lens axis sits 9.9 mm further out than
            // the centre of its half. The eye windows have to move out with it
            // or the picture sits toward the nose in both lenses. It is an
            // offset, not a depth effect; set it back to 0 to centre the view.
            CBBKeyParallax:    @0.11,
            CBBKeyBrightness:  @1.0,
            CBBKeyVignette:    @0.25,
            CBBKeyCursorStep:  @36.0,
            CBBKeyGridColumns: @6,
            CBBKeyAimSensitivity: @1.0,   // degrees of head turn per screen edge
            CBBKeyHomeLandscape: @0,      // 0 off, 1 follow the device, 2 left, 3 right
            CBBKeyTapRotation: @0,        // manual turn, used only until calibrated
            CBBKeyMirror: @0,             // bit 0 mirror u, bit 1 mirror v
            // Calibrated map from the point under the dot to the point that has
            // to be injected for a tap to arrive there: x' = a*x + b*y + tx,
            // y' = c*x + d*y + ty. Identity until the first calibration.
            CBBKeyTapA: @1, CBBKeyTapB: @0, CBBKeyTapC: @0, CBBKeyTapD: @1,
            CBBKeyTapTX: @0, CBBKeyTapTY: @0,
            CBBKeyTapCalibrated: @NO,
            CBBKeyTapCalibrationOrientation: @(-1),
            CBBKeyLandscapeArmed: @NO,    // set while forcing orientation, cleared when stable
            CBBKeyBootArmed: @NO,         // set while stereo runs, cleared once it is stable
            CBBKeyBootFailures: @0,       // consecutive launches that died young
            CBBKeyButtonX:     @0.05,    // normalized fixed-space coordinates:
            CBBKeyButtonY:     @0.50,    // the pad touches the middle of the left edge
            CBBKeyCaptureFPS:  @30,
            CBBKeyHideFromCapture: @YES,
            CBBKeyDwellClick: @YES,
        };
    }
    return self;
}

- (id)rawValueForKey:(NSString *)key {
    id value = [_defaults objectForKey:key];
    return value ?: _fallbacks[key];
}

- (double)doubleForKey:(NSString *)key {
    return [[self rawValueForKey:key] doubleValue];
}

- (NSInteger)integerForKey:(NSString *)key {
    return [[self rawValueForKey:key] integerValue];
}

- (BOOL)boolForKey:(NSString *)key {
    return [[self rawValueForKey:key] boolValue];
}

- (void)setDouble:(double)value forKey:(NSString *)key {
    [_defaults setDouble:value forKey:key];
}

- (void)setInteger:(NSInteger)value forKey:(NSString *)key {
    [_defaults setInteger:value forKey:key];
}

- (void)setBool:(BOOL)value forKey:(NSString *)key {
    [_defaults setBool:value forKey:key];
}

- (void)resetAll {
    for (NSString *key in _fallbacks) {
        [_defaults removeObjectForKey:key];
    }
    [_defaults synchronize];
}

- (void)synchronize {
    [_defaults synchronize];
}

@end
