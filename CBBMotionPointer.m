#import "CBBMotionPointer.h"
#import "CBBCompat.h"
#import <CoreMotion/CoreMotion.h>
#import <simd/simd.h>
#import <math.h>

@implementation CBBMotionPointer {
    CMMotionManager *_manager;
    BOOL _running;
    BOOL _hasReference;

    // Recentred pose, as three orthonormal axes in the world frame.
    simd_float3 _forward;
    simd_float3 _right;
    simd_float3 _up;

    CGFloat _filteredYaw;
    CGFloat _filteredPitch;

    // Yaw is unwrapped across the ±pi seam so a head turn keeps going the way
    // the head goes instead of snapping the dot back across the screen.
    BOOL _hasRawYaw;
    CGFloat _lastRawYaw;
    CGFloat _wrappedYaw;
}

- (instancetype)init {
    if ((self = [super init])) {
        _manager = [[CMMotionManager alloc] init];
        _manager.deviceMotionUpdateInterval = 1.0 / 60.0;
    }
    return self;
}

- (BOOL)available {
    return _manager.deviceMotionAvailable;
}

- (BOOL)running {
    return _running;
}

#pragma mark - Lifecycle

- (void)start {
    if (_running || !_manager.deviceMotionAvailable) return;
    _running = YES;
    _hasReference = NO;

    // XArbitraryCorrectedZVertical keeps the horizon from drifting without
    // needing true north, which is all a pointer needs.
    __weak typeof(self) weakSelf = self;
    [_manager startDeviceMotionUpdatesUsingReferenceFrame:CMAttitudeReferenceFrameXArbitraryCorrectedZVertical
                                                 toQueue:[NSOperationQueue mainQueue]
                                             withHandler:^(CMDeviceMotion *motion, NSError *error) {
        if (!motion) return;
        CBBMotionPointer *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf handleMotion:motion];
    }];
}

- (void)stop {
    if (!_running) return;
    _running = NO;
    _hasReference = NO;
    [_manager stopDeviceMotionUpdates];
}

- (void)recenter {
    CMDeviceMotion *motion = _manager.deviceMotion;
    _hasReference = NO;
    _filteredYaw = 0.0;
    _filteredPitch = 0.0;
    _wrappedYaw = 0.0;
    _hasRawYaw = NO;
    if (!motion) return;
    [self captureReference:motion.attitude];
}

#pragma mark - Pose maths

// The gaze direction is the device's -Z axis: the screen faces the viewer, so
// they look out through the back of the phone.
static simd_float3 CBBGazeFromAttitude(CMAttitude *attitude) {
    CMRotationMatrix m = attitude.rotationMatrix;
    return simd_normalize(simd_make_float3(-(float)m.m13, -(float)m.m23, -(float)m.m33));
}

- (void)captureReference:(CMAttitude *)attitude {
    simd_float3 forward = CBBGazeFromAttitude(attitude);
    simd_float3 worldUp = simd_make_float3(0.0f, 0.0f, 1.0f);

    simd_float3 right = simd_cross(forward, worldUp);
    if (simd_length(right) < 0.001f) {
        // Pointing straight up or down: any horizontal axis will do.
        CMRotationMatrix m = attitude.rotationMatrix;
        right = simd_make_float3((float)m.m11, (float)m.m21, (float)m.m31);
    }
    right = simd_normalize(right);

    _forward = forward;
    _right = right;
    _up = simd_normalize(simd_cross(right, forward));
    _hasReference = YES;
}

- (void)handleMotion:(CMDeviceMotion *)motion {
    if (!_hasReference) {
        [self captureReference:motion.attitude];
        if (!_hasReference) return;
    }

    simd_float3 forward = CBBGazeFromAttitude(motion.attitude);
    CGFloat rawYaw = (CGFloat)atan2f(simd_dot(forward, _right), simd_dot(forward, _forward));
    CGFloat pitch = (CGFloat)asinf(MIN(MAX(simd_dot(forward, _up), -1.0f), 1.0f));

    // atan2 only reports the half turn either side of straight ahead; add the
    // step between samples instead so the reported angle covers the full 360.
    if (!_hasRawYaw) {
        _wrappedYaw = rawYaw;
        _hasRawYaw = YES;
    } else {
        CGFloat delta = rawYaw - _lastRawYaw;
        while (delta > (CGFloat)M_PI) delta -= (CGFloat)(2.0 * M_PI);
        while (delta < -(CGFloat)M_PI) delta += (CGFloat)(2.0 * M_PI);
        _wrappedYaw += delta;
    }
    _lastRawYaw = rawYaw;
    CGFloat yaw = _wrappedYaw;

    // Light smoothing: gyro noise at 60 Hz makes an unsteady reticle.
    _filteredYaw = _filteredYaw * 0.75 + yaw * 0.25;
    _filteredPitch = _filteredPitch * 0.75 + pitch * 0.25;

    if (self.onAim) self.onAim(CGPointMake(_filteredYaw, _filteredPitch));
}

@end
