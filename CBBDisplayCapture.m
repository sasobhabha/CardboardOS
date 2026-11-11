#import "CBBDisplayCapture.h"
#import "CBBCompat.h"

static IOSurfaceRef CBBCreateSurface(CGSize pixelSize) {
    size_t width = (size_t)pixelSize.width;
    size_t height = (size_t)pixelSize.height;
    if (width == 0 || height == 0) return NULL;

    // 64-byte row alignment keeps IOSurfaceAccelerator and the GPU happy.
    size_t bytesPerRow = ((width * 4) + 63) & ~(size_t)63;

    NSDictionary *properties = @{
        (id)kIOSurfaceWidth: @(width),
        (id)kIOSurfaceHeight: @(height),
        (id)kIOSurfaceBytesPerElement: @4,
        (id)kIOSurfaceBytesPerRow: @(bytesPerRow),
        (id)kIOSurfaceAllocSize: @(bytesPerRow * height),
        (id)kIOSurfacePixelFormat: @(kCVPixelFormatType_32BGRA),
    };
    return IOSurfaceCreate((__bridge CFDictionaryRef)properties);
}

@implementation CBBDisplayCapture {
    id<MTLDevice> _device;
    CVMetalTextureCacheRef _cache;
    IOSurfaceRef _surfaces[3];
    CVMetalTextureRef _metalTextures[3];
    id<MTLTexture> _textures[3];
    NSUInteger _nextIndex;
    NSInteger _latestIndex;
    BOOL _valid;
    BOOL _hasFrame;
    uint64_t _frameCount;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device {
    if ((self = [super init])) {
        _device = device;

        CGSize native = [UIScreen mainScreen].nativeBounds.size;
        _pixelSize = CGSizeMake(MIN(native.width, native.height), MAX(native.width, native.height));
        if (_pixelSize.width <= 0 || _pixelSize.height <= 0) {
            CGSize fallback = CBBNativeScreenSize();
            CGFloat scale = [UIScreen mainScreen].scale;
            _pixelSize = CGSizeMake(fallback.width * scale, fallback.height * scale);
        }
        _latestIndex = -1;

        if (CVMetalTextureCacheCreate(kCFAllocatorDefault, NULL, device, NULL, &_cache) != kCVReturnSuccess) {
            CBBLog(@"CVMetalTextureCacheCreate failed");
            return self;
        }

        BOOL ok = YES;
        for (int i = 0; i < 3; i++) {
            _surfaces[i] = CBBCreateSurface(_pixelSize);
            if (!_surfaces[i]) ok = NO;
        }
        _valid = ok;
        if (!ok) {
            CBBLog(@"IOSurface allocation failed for %@", NSStringFromCGSize(_pixelSize));
        }
    }
    return self;
}

- (BOOL)valid {
    return _valid;
}

- (BOOL)hasFrame {
    return _hasFrame;
}

- (uint64_t)frameCount {
    return _frameCount;
}

- (id<MTLTexture>)texture {
    if (_latestIndex < 0 || _latestIndex > 2) return nil;
    return _textures[_latestIndex];
}

- (BOOL)captureFrame {
    if (!_valid) return NO;

    NSUInteger index = _nextIndex;
    _nextIndex = (_nextIndex + 1) % 3;

    IOSurfaceRef surface = _surfaces[index];
    if (!surface) return NO;

    // Do not lock the surface across the render call: the render server writes
    // into it from another process, and a surface held locked for writing comes
    // back unchanged (black frames). Read it back with kIOSurfaceLockReadOnly
    // afterwards instead, which is what latestFrameHasContent does.
    CARenderServerRenderDisplay(0, CFSTR("LCD"), surface, 0, 0);

    if (_metalTextures[index]) {
        CFRelease(_metalTextures[index]);
        _metalTextures[index] = NULL;
    }
    _textures[index] = nil;

    CVPixelBufferRef pixelBuffer = NULL;
    CVReturn result = CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, surface, NULL, &pixelBuffer);
    if (result != kCVReturnSuccess || !pixelBuffer) {
        return NO;
    }

    CVMetalTextureRef metalTexture = NULL;
    size_t width = IOSurfaceGetWidth(surface);
    size_t height = IOSurfaceGetHeight(surface);
    result = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                       _cache,
                                                       pixelBuffer,
                                                       NULL,
                                                       MTLPixelFormatBGRA8Unorm,
                                                       width,
                                                       height,
                                                       0,
                                                       &metalTexture);
    CFRelease(pixelBuffer);

    if (result != kCVReturnSuccess || !metalTexture) {
        return NO;
    }

    _metalTextures[index] = metalTexture;
    _textures[index] = CVMetalTextureGetTexture(metalTexture);
    if (!_textures[index]) return NO;

    _latestIndex = (NSInteger)index;
    _hasFrame = YES;
    _frameCount++;
    return YES;
}

- (BOOL)latestFrameHasContent {
    if (!_valid || _latestIndex < 0 || _latestIndex > 2) return NO;
    IOSurfaceRef surface = _surfaces[_latestIndex];
    if (!surface) return NO;

    BOOL content = NO;
    IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);
    uint8_t *base = (uint8_t *)IOSurfaceGetBaseAddress(surface);
    size_t bytesPerRow = IOSurfaceGetBytesPerRow(surface);
    size_t width = IOSurfaceGetWidth(surface);
    size_t height = IOSurfaceGetHeight(surface);
    if (base && bytesPerRow > 0 && width > 0 && height > 0) {
        size_t stepX = MAX(width / 16, (size_t)1);
        size_t stepY = MAX(height / 16, (size_t)1);
        for (size_t y = 0; y < height && !content; y += stepY) {
            uint8_t *row = base + y * bytesPerRow;
            for (size_t x = 0; x < width; x += stepX) {
                uint8_t *pixel = row + x * 4;
                if (pixel[0] || pixel[1] || pixel[2]) {
                    content = YES;
                    break;
                }
            }
        }
    }
    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
    return content;
}

- (void)invalidate {
    _valid = NO;
    _hasFrame = NO;
    for (NSInteger i = 0; i < 3; i++) {
        if (_metalTextures[i]) {
            CFRelease(_metalTextures[i]);
            _metalTextures[i] = NULL;
        }
        _textures[i] = nil;
        if (_surfaces[i]) {
            CFRelease(_surfaces[i]);
            _surfaces[i] = NULL;
        }
    }
    if (_cache) {
        CVMetalTextureCacheFlush(_cache, 0);
        CFRelease(_cache);
        _cache = NULL;
    }
}

- (void)dealloc {
    [self invalidate];
}

@end
