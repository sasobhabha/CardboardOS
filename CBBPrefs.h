#import <Foundation/Foundation.h>

extern NSString * const CBBKeyEnabled;
extern NSString * const CBBKeyZoom;
extern NSString * const CBBKeyMode;
extern NSString * const CBBKeyRotation;
extern NSString * const CBBKeyK1;
extern NSString * const CBBKeyK2;
extern NSString * const CBBKeyChroma;
extern NSString * const CBBKeyCurvature;
extern NSString * const CBBKeyParallax;
extern NSString * const CBBKeyBrightness;
extern NSString * const CBBKeyVignette;
extern NSString * const CBBKeyCursorStep;
extern NSString * const CBBKeyGridColumns;
extern NSString * const CBBKeyAimSensitivity;
extern NSString * const CBBKeyHomeLandscape;
extern NSString * const CBBKeyMirror;
extern NSString * const CBBKeyTapRotation;
extern NSString * const CBBKeyTapA;
extern NSString * const CBBKeyTapB;
extern NSString * const CBBKeyTapC;
extern NSString * const CBBKeyTapD;
extern NSString * const CBBKeyTapTX;
extern NSString * const CBBKeyTapTY;
extern NSString * const CBBKeyTapCalibrated;
extern NSString * const CBBKeyTapCalibrationOrientation;
extern NSString * const CBBKeyLandscapeArmed;
extern NSString * const CBBKeyBootArmed;
extern NSString * const CBBKeyBootFailures;
extern NSString * const CBBKeyButtonX;
extern NSString * const CBBKeyButtonY;
extern NSString * const CBBKeyCaptureFPS;
extern NSString * const CBBKeyHideFromCapture;
extern NSString * const CBBKeyDwellClick;

// String constants for the two view modes.
extern NSString * const CBBModeFill;
extern NSString * const CBBModeNative;

// All values live in /var/mobile/Library/Preferences/com.buffy.cardboardos.plist
// so they survive resprings and can be edited from a shell with `defaults`.
@interface CBBPrefs : NSObject

+ (instancetype)sharedPrefs;

- (double)doubleForKey:(NSString *)key;
- (NSInteger)integerForKey:(NSString *)key;
- (BOOL)boolForKey:(NSString *)key;

- (void)setDouble:(double)value forKey:(NSString *)key;
- (void)setInteger:(NSInteger)value forKey:(NSString *)key;
- (void)setBool:(BOOL)value forKey:(NSString *)key;

- (void)resetAll;
- (void)synchronize;

@end
