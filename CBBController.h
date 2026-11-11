#import <Foundation/Foundation.h>

@interface CBBController : NSObject

+ (instancetype)sharedController;

// Idempotent. Builds the overlay window, starts the capture/render loop and
// begins listening for Cardboard button patterns.
- (void)start;

@end
