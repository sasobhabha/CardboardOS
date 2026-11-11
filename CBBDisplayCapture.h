#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <CoreGraphics/CoreGraphics.h>

// Grabs the composited main display into a rotating pool of IOSurfaces and
// exposes the newest one as a Metal texture. Triple buffered so the GPU can be
// reading frame N-1 while frame N is rendered.
@interface CBBDisplayCapture : NSObject

- (instancetype)initWithDevice:(id<MTLDevice>)device;

@property (nonatomic, readonly) BOOL valid;          // surfaces + texture cache ready
@property (nonatomic, readonly) BOOL hasFrame;
@property (nonatomic, readonly) CGSize pixelSize;
@property (nonatomic, readonly) id<MTLTexture> texture;
@property (nonatomic, readonly) uint64_t frameCount;   // surfaces successfully mapped

- (BOOL)captureFrame;

// Cheap sanity check: scans the newest surface for any non-black pixel. Used to
// detect a capture pipeline that is silently producing nothing, so the tweak
// can leave the phone in normal iOS instead of showing a black headset.
- (BOOL)latestFrameHasContent;

- (void)invalidate;

@end
