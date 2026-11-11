#import "CBBStereoRenderer.h"
#import "CBBDisplayCapture.h"
#import "CBBPrefs.h"
#import "CBBShaders.h"
#import "CBBCompat.h"

typedef struct {
    simd_float4 uvPan;
    simd_float4 cursor;
    simd_float4 lens;
    simd_float4 look;
    simd_float4 axis;    // x: eyes stacked along view y, yz: mirror u/v
} CBBUniforms;

@implementation CBBStereoRenderer {
    BOOL _rendering;
    id<MTLDevice> _device;
    id<MTLCommandQueue> _commandQueue;
    id<MTLRenderPipelineState> _pipeline;
    id<MTLSamplerState> _sampler;
    CBBDisplayCapture *_capture;
    NSTimeInterval _lastCaptureTime;
    BOOL _usingSimpleShader;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super init])) {
        _device = MTLCreateSystemDefaultDevice();
        if (!_device) {
            CBBLog(@"no Metal device");
            return nil;
        }

        _commandQueue = [_device newCommandQueue];

        NSError *error = nil;
        id<MTLLibrary> library = [_device newLibraryWithSource:kCBBStereoShaderSource
                                                       options:nil
                                                         error:&error];
        if (!library) {
            // A runtime-compiled string is the one part of this tweak that can
            // break without a build error, and failing here used to mean no
            // window at all: indistinguishable from the tweak not loading.
            CBBLog(@"stereo shader failed to compile: %@", error);
            library = [_device newLibraryWithSource:kCBBSimpleShaderSource
                                            options:nil
                                              error:&error];
            _usingSimpleShader = YES;
            if (!library) {
                CBBLog(@"simple shader failed to compile too: %@", error);
                return nil;
            }
            CBBLog(@"using the simple shader: stereo without lens correction");
        }

        MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
        descriptor.vertexFunction = [library newFunctionWithName:@"cbb_vertex"];
        descriptor.fragmentFunction = [library newFunctionWithName:@"cbb_fragment"];
        descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        _pipeline = [_device newRenderPipelineStateWithDescriptor:descriptor error:&error];
        if (!_pipeline) {
            CBBLog(@"stereo pipeline failed: %@", error);
            return nil;
        }

        MTLSamplerDescriptor *samplerDescriptor = [MTLSamplerDescriptor new];
        samplerDescriptor.minFilter = MTLSamplerMinMagFilterLinear;
        samplerDescriptor.magFilter = MTLSamplerMinMagFilterLinear;
        samplerDescriptor.sAddressMode = MTLSamplerAddressModeClampToEdge;
        samplerDescriptor.tAddressMode = MTLSamplerAddressModeClampToEdge;
        _sampler = [_device newSamplerStateWithDescriptor:samplerDescriptor];

        _capture = [[CBBDisplayCapture alloc] initWithDevice:_device];

        _view = [[MTKView alloc] initWithFrame:frame device:_device];
        _view.delegate = self;
        _view.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
        _view.framebufferOnly = YES;
        _view.opaque = YES;
        _view.backgroundColor = [UIColor blackColor];
        _view.clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
        _view.autoResizeDrawable = YES;
        _view.enableSetNeedsDisplay = NO;
        _view.preferredFramesPerSecond = 60;
        _view.paused = YES;
        _view.userInteractionEnabled = NO;

        _reticleVisible = YES;
        _dwellProgress = 0.0;
        _prefs = [CBBPrefs sharedPrefs];
    }
    return self;
}

- (CBBDisplayCapture *)capture {
    return _capture;
}

- (BOOL)usingSimpleShader {
    return _usingSimpleShader;
}

- (BOOL)rendering {
    return _rendering;
}

- (void)setRendering:(BOOL)rendering {
    _rendering = rendering;
    _view.paused = !rendering;
    if (rendering) {
        _lastCaptureTime = 0;
    }
}

#pragma mark - MTKViewDelegate

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    // Nothing to do: layout is recomputed from drawableSize every frame.
}

- (void)drawInMTKView:(MTKView *)view {
    if (!self.rendering || !self.prefs || ![self.prefs boolForKey:CBBKeyEnabled]) {
        [self clearView:view];
        return;
    }

    NSTimeInterval now = CACurrentMediaTime();
    NSInteger fps = MAX(1, [self.prefs integerForKey:CBBKeyCaptureFPS]);
    NSTimeInterval interval = 1.0 / (NSTimeInterval)fps;
    if (!_capture.hasFrame || (now - _lastCaptureTime) >= interval) {
        _lastCaptureTime = now;
        [_capture captureFrame];
    }

    id<MTLTexture> texture = _capture.texture;
    if (!texture) {
        [self clearView:view];
        return;
    }

    CGSize drawable = view.drawableSize;
    if (drawable.width < 2.0 || drawable.height < 2.0) return;

    NSInteger rotationDegrees = [self.prefs integerForKey:CBBKeyRotation];
    NSInteger rotation = ((rotationDegrees % 360) + 360) % 360;
    BOOL quarterTurn = (rotation == 90 || rotation == 270);
    CGFloat radians = (CGFloat)rotation * (CGFloat)M_PI / 180.0;

    CGSize bufferPoints = self.screenSize;
    CGSize bufferPixels = _capture.pixelSize;
    if (bufferPixels.width < 1 || bufferPixels.height < 1) return;

    // Eyes sit along the long axis of the drawable, half of it each, so a
    // landscape 1136x640 panel gives two 568x640 eye windows. The shader
    // assumes exactly that split: lens centres at 0.25 and 0.75 of that axis.
    BOOL stacked = drawable.height >= drawable.width;
    CGFloat eyeExtentX = stacked ? drawable.height * 0.5 : drawable.width * 0.5;
    CGFloat eyeExtentY = stacked ? drawable.width : drawable.height;
    double zoom = MAX(0.4, [self.prefs doubleForKey:CBBKeyZoom]);
    NSInteger mode = [self.prefs integerForKey:CBBKeyMode];

    // Source uv half-span per eye axis. The panel is portrait-shaped while the
    // eye is not, so the spans have to be derived from the eye's aspect and the
    // panel's pixel size; scaling both axes by the same .5 stretches the picture
    // (a portrait screen in a landscape eye is off by more than 2:1).
    //
    // Fill fits the whole panel into the eye without distorting it, which leaves
    // black bars on two sides; native shows a 1:1 pixel window so text is sharp.
    CGFloat contentWidth = quarterTurn ? bufferPixels.height : bufferPixels.width;
    CGFloat contentHeight = quarterTurn ? bufferPixels.width : bufferPixels.height;
    CGFloat eyeScale = (mode == 1) ? zoom
                                   : MIN(eyeExtentX / contentWidth, eyeExtentY / contentHeight) * zoom;
    eyeScale = MAX(eyeScale, 0.0001);

    CGFloat regionX = eyeExtentX / eyeScale;    // source pixels across the eye
    CGFloat regionY = eyeExtentY / eyeScale;
    CGFloat spanX = quarterTurn ? regionX / (2.0 * bufferPixels.height) : regionX / (2.0 * bufferPixels.width);
    CGFloat spanY = quarterTurn ? regionY / (2.0 * bufferPixels.width) : regionY / (2.0 * bufferPixels.height);
    spanX = MIN(spanX, 4.0);
    spanY = MIN(spanY, 4.0);

    // The eye geometry is derived, so "what size is the stereo picture" has one
    // answer on the device instead of an argument about the code. Printed once,
    // on the first frame after the drawable size is known.
    static BOOL geometryReported = NO;
    if (!geometryReported) {
        geometryReported = YES;
        CBBMarkStage([NSString stringWithFormat:
                      @"stereo: drawable %.0fx%.0f px, eye %.0fx%.0f px (%@), panel %.0fx%.0f px, scale %.3f, span %.3fx%.3f",
                      drawable.width, drawable.height,
                      eyeExtentX, eyeExtentY, stacked ? @"stacked" : @"side by side",
                      bufferPixels.width, bufferPixels.height, eyeScale, spanX, spanY]);
    }

    // Pan is in source uv, and the spans are per eye axis, so the extent along
    // each source axis is the other axis's span once the panel is turned.
    CGFloat uvHalfX = quarterTurn ? spanY : spanX;
    CGFloat uvHalfY = quarterTurn ? spanX : spanY;

    CGPoint cursorUnit = CGPointMake(0.5, 0.5);
    if (bufferPoints.width > 0 && bufferPoints.height > 0) {
        cursorUnit = CGPointMake(self.cursor.x / bufferPoints.width,
                                 self.cursor.y / bufferPoints.height);
    }

    // Magnified views follow the reticle so the user can always read what the
    // button is aiming at. A view wider than the panel stays centred instead.
    CGFloat panX = 0.5, panY = 0.5;
    if (uvHalfX < 0.5) panX = MIN(MAX(cursorUnit.x, uvHalfX), 1.0 - uvHalfX);
    if (uvHalfY < 0.5) panY = MIN(MAX(cursorUnit.y, uvHalfY), 1.0 - uvHalfY);

    NSInteger mirror = [self.prefs integerForKey:CBBKeyMirror];

    CBBUniforms uniforms;
    float dwell = (float)MIN(MAX(self.dwellProgress, 0.0), 1.0);
    uniforms.axis = simd_make_float4(stacked ? 1.0f : 0.0f,
                                     (mirror & 1) ? 1.0f : 0.0f,
                                     (mirror & 2) ? 1.0f : 0.0f,
                                     dwell);
    uniforms.uvPan = simd_make_float4((float)spanX, (float)spanY, (float)panX, (float)panY);
    uniforms.cursor = simd_make_float4((float)cursorUnit.x,
                                       (float)cursorUnit.y,
                                       self.reticleVisible ? 1.0f : 0.0f,
                                       (float)radians);
    uniforms.lens = simd_make_float4((float)[self.prefs doubleForKey:CBBKeyK1],
                                     (float)[self.prefs doubleForKey:CBBKeyK2],
                                     (float)[self.prefs doubleForKey:CBBKeyChroma],
                                     (float)[self.prefs doubleForKey:CBBKeyCurvature]);
    uniforms.look = simd_make_float4((float)[self.prefs doubleForKey:CBBKeyBrightness],
                                     (float)[self.prefs doubleForKey:CBBKeyVignette],
                                     (float)[self.prefs doubleForKey:CBBKeyParallax],
                                     (float)(bufferPixels.width / bufferPixels.height));

    MTLRenderPassDescriptor *pass = view.currentRenderPassDescriptor;
    id<CAMetalDrawable> drawableTexture = view.currentDrawable;
    if (!pass || !drawableTexture) return;

    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;

    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    [encoder setRenderPipelineState:_pipeline];
    [encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
    [encoder setFragmentTexture:texture atIndex:0];
    [encoder setFragmentSamplerState:_sampler atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [encoder endEncoding];
    [commandBuffer presentDrawable:drawableTexture];
    [commandBuffer commit];
}

- (void)clearView:(MTKView *)view {
    MTLRenderPassDescriptor *pass = view.currentRenderPassDescriptor;
    id<CAMetalDrawable> drawableTexture = view.currentDrawable;
    if (!pass || !drawableTexture) return;

    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);

    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    [encoder endEncoding];
    [commandBuffer presentDrawable:drawableTexture];
    [commandBuffer commit];
}

@end
