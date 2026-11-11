//
//  CBBMotionPointer.h
//  CardboardOS
//
//  Turns the phone's orientation into an aim direction, so the reticle sits
//  where the viewer is pointing instead of on a fixed grid.
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

@interface CBBMotionPointer : NSObject

// Delivered on the main queue. x is yaw (+ to the right) and y is pitch
// (+ up), both relative to the pose captured by -recenter, in radians.
@property (nonatomic, copy) void (^onAim)(CGPoint aim);

@property (nonatomic, readonly) BOOL available;
@property (nonatomic, readonly) BOOL running;

- (void)start;
- (void)stop;

// Makes the current head pose the centre of the view. Call it whenever the
// phone is put into the viewer or the drift gets annoying.
- (void)recenter;

@end
