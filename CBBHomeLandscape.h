#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// SpringBoard only draws a landscape home screen if it is told the home screen
// supports landscape orientation. On iPhone it normally claims portrait only, so
// the stereo view would show portrait icons. These swizzles make the home screen
// window advertise landscape while stereo is on, and put it back afterwards.
typedef NS_ENUM(NSInteger, CBBHomeLandscapeMode) {
    CBBHomeLandscapeOff = 0,
    CBBHomeLandscapeAuto = 1,     // follow the device, like a normal app
    CBBHomeLandscapeLeft = 2,
    CBBHomeLandscapeRight = 3,
};

@interface CBBHomeLandscape : NSObject

+ (instancetype)sharedHelper;

// Installs the swizzles the first time it is called, then forces (or releases)
// the home screen orientation. Safe to call repeatedly.
- (void)applyMode:(CBBHomeLandscapeMode)mode;

// YES while landscape is active but has not been achieved yet, so a caller can
// keep re-asserting it (the UI resets the orientation for its own reasons, e.g.
// when the status bar or an alert appears).
- (BOOL)wantsMoreAttempts;

@end
