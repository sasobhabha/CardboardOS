#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

@class CBBClickRecognizer;

@protocol CBBClickRecognizerDelegate <NSObject>
- (void)clickRecognizer:(CBBClickRecognizer *)recognizer
    didRecognizeClicks:(NSInteger)clickCount
                 held:(BOOL)held;
@end

// Turns raw down/up events at the Cardboard button's screen location into
// click counts. A press that is released before `longPressInterval` counts as
// a tap; taps are coalesced until `multiTapInterval` expires. A press held past
// `longPressInterval` is delivered immediately with held == YES, which gives us
// a second family of gestures ("tap N times and hold").
@interface CBBClickRecognizer : NSObject

@property (nonatomic, weak) id<CBBClickRecognizerDelegate> delegate;
@property (nonatomic) NSTimeInterval multiTapInterval;   // default 0.45
@property (nonatomic) NSTimeInterval longPressInterval;  // default 0.60

- (void)touchDown;
- (void)touchUp;
- (void)cancel;

@end
