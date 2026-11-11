#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <MetalKit/MetalKit.h>

@class CBBPrefs;
@class CBBDisplayCapture;

// Owns the MTKView that covers the display and draws the two lens-corrected eye
// views from the captured framebuffer.
@interface CBBStereoRenderer : NSObject <MTKViewDelegate>

- (instancetype)initWithFrame:(CGRect)frame;

@property (nonatomic, strong, readonly) MTKView *view;
@property (nonatomic, strong, readonly) CBBDisplayCapture *capture;
@property (nonatomic, strong) CBBPrefs *prefs;

@property (nonatomic) CGPoint cursor;      // fixed-space points
@property (nonatomic) CGFloat dwellProgress; // 0..1 hold-to-click fill, 0 = no ring
@property (nonatomic) CGSize screenSize;   // fixed-space points
@property (nonatomic) BOOL reticleVisible;
@property (nonatomic) BOOL rendering;      // when NO the view is paused and cleared

// YES when the full shader did not compile and the pass-through fallback is in
// use: stereo still shows, without lens correction.
@property (nonatomic, readonly) BOOL usingSimpleShader;

@end
