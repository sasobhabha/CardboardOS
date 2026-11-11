//
//  Tweak.x
//  CardboardOS
//
//  The tweak lives entirely inside SpringBoard: its overlay window sits above
//  every app, captures the composited display and re-presents it as two
//  lens-corrected eye views.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "CBBController.h"
#import "CBBCompat.h"

static void CBBStartWhenReady(void) {
    @autoreleasepool {
        // Proof that dyld loaded this dylib into this process, before any of the
        // setup below can fail or silently return.
        CBBMarkStage(@"ctor");
        // The build tag is referenced here, so the compiler has to keep its
        // bytes in the binary: `make deploy` greps the on-disk dylib for it
        // and `make doctor` prints it back from the stages file. An unused
        // #define is compiled out, which made the fingerprint report NOT FOUND
        // on a perfectly fresh build.
        CBBMarkStage([NSString stringWithUTF8String:CBB_BUILD_TAG]);
        CBBLog(@"build %@", [NSString stringWithUTF8String:CBB_BUILD_TAG]);

        // The MobileSubstrate filter already limits this dylib to SpringBoard, so
        // an unreadable identifier here means "the bundle was not ready this
        // early", not "wrong process". Treating it as the wrong process made the
        // tweak silently do nothing, which is indistinguishable from a bad
        // install.
        NSString *bundleIdentifier = [NSBundle mainBundle].bundleIdentifier;
        if (bundleIdentifier && ![bundleIdentifier isEqualToString:@"com.apple.springboard"]) {
            CBBMarkStage([NSString stringWithFormat:@"ctor: not springboard (%@)", bundleIdentifier]);
            return;
        }
        CBBMarkStage(@"ctor: springboard");

        // SpringBoard needs its window server connection and first scene before
        // an overlay can be attached reliably.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            // A throw during setup must not take SpringBoard with it: the tweak is
            // optional, the home screen is not.
            @try {
                CBBMarkStage(@"calling start");
                [[CBBController sharedController] start];
                CBBMarkStage(@"start returned");
            } @catch (NSException *exception) {
                CBBLog(@"startup threw %@: %@", exception.name, exception.reason);
                CBBMarkStage([NSString stringWithFormat:@"start threw %@: %@",
                              exception.name, exception.reason]);
            }
        });
    }
}

%ctor {
    CBBStartWhenReady();
}
