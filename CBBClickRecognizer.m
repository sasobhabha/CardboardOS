#import "CBBClickRecognizer.h"
#import "CBBCompat.h"

@implementation CBBClickRecognizer {
    NSInteger _clickCount;
    NSTimeInterval _downTime;
    NSTimeInterval _lastUpTime;
    NSTimer *_pendingTimer;
    BOOL _down;
}

- (instancetype)init {
    if ((self = [super init])) {
        // The pad is a stiff dome: a press is only a hold once it has been down
        // for well over a second, otherwise an ordinary click is swallowed as a
        // Home press. Multi-tap has to stay short so a single click confirms
        // almost at once.
        _multiTapInterval = 0.35;
        _longPressInterval = 1.20;
        _lastUpTime = -10.0;
    }
    return self;
}

- (void)dealloc {
    [_pendingTimer invalidate];
}

- (void)touchDown {
    NSTimeInterval now = CACurrentMediaTime();
    if (_pendingTimer) {
        [_pendingTimer invalidate];
        _pendingTimer = nil;
    }
    if (now - _lastUpTime > self.multiTapInterval) {
        _clickCount = 0;
    }
    _clickCount += 1;
    _downTime = now;
    _down = YES;
}

- (void)touchUp {
    if (!_down) return;
    _down = NO;

    NSTimeInterval now = CACurrentMediaTime();
    _lastUpTime = now;

    BOOL held = (now - _downTime) >= self.longPressInterval;
    if (held) {
        [self deliverClicks:_clickCount held:YES];
        return;
    }

    [_pendingTimer invalidate];
    _pendingTimer = [NSTimer timerWithTimeInterval:self.multiTapInterval
                                            target:self
                                          selector:@selector(flushPending)
                                          userInfo:nil
                                           repeats:NO];
    // Common modes so the flush still happens while a touch is being tracked.
    [[NSRunLoop mainRunLoop] addTimer:_pendingTimer forMode:NSRunLoopCommonModes];
}

- (void)flushPending {
    _pendingTimer = nil;
    [self deliverClicks:_clickCount held:NO];
}

- (void)deliverClicks:(NSInteger)count held:(BOOL)held {
    NSInteger delivered = MAX(count, (NSInteger)1);
    _clickCount = 0;
    _lastUpTime = CACurrentMediaTime();
    [_pendingTimer invalidate];
    _pendingTimer = nil;

    id<CBBClickRecognizerDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:@selector(clickRecognizer:didRecognizeClicks:held:)]) {
        [delegate clickRecognizer:self didRecognizeClicks:delivered held:held];
    }
}

- (void)cancel {
    [_pendingTimer invalidate];
    _pendingTimer = nil;
    _clickCount = 0;
    _down = NO;
}

@end
