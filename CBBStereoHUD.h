#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// One settings line. `step` is called with +1/-1 when the user taps twice or
// three times; `activate` runs on four taps. Everything is reachable with the
// viewer button alone, so the HUD has no touch handling at all.
@interface CBBHudRow : NSObject

@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString * (^valueText)(void);
@property (nonatomic, copy) void (^step)(NSInteger direction);
@property (nonatomic, copy) void (^activate)(void);

+ (instancetype)rowWithTitle:(NSString *)title
                   valueText:(NSString * (^)(void))valueText
                        step:(void (^)(NSInteger direction))step;

+ (instancetype)rowWithTitle:(NSString *)title
                   valueText:(NSString * (^)(void))valueText
                    activate:(void (^)(void))activate;

@end

// Draws the same settings panel into each eye half. This is deliberately not
// lens-warped: it sits on top of the stereo image as a flat, readable overlay.
@interface CBBStereoHUD : UIView

@property (nonatomic, copy) NSArray<CBBHudRow *> *rows;
@property (nonatomic) NSInteger selectedIndex;
@property (nonatomic, copy) NSString *statusText;
@property (nonatomic, copy) NSString *promptText;
@property (nonatomic) CGPoint buttonPoint;      // fixed-space points
@property (nonatomic) BOOL showButtonMarker;

// Forced landscape: the two halves are stacked along the panel's long axis and
// the panel text is rotated to match the stereo image.
@property (nonatomic) BOOL landscape;
@property (nonatomic) CGFloat rotationDegrees;

@end
