#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// Synthesizes digitizer and consumer-control events from inside SpringBoard.
// All points are in fixed (native portrait) screen points.
@interface CBBTouchInjector : NSObject

+ (instancetype)sharedInjector;

@property (nonatomic, readonly) CGSize screenSize;   // fixed-space points
@property (nonatomic, readonly) BOOL available;

- (void)tapAtPoint:(CGPoint)point;
- (void)swipeFromPoint:(CGPoint)from toPoint:(CGPoint)to duration:(NSTimeInterval)duration;
- (void)pressHome;
- (void)pressHomeTwice;

@end
