#import "CBBStereoHUD.h"
#import "CBBCompat.h"

@implementation CBBHudRow

+ (instancetype)rowWithTitle:(NSString *)title
                   valueText:(NSString * (^)(void))valueText
                        step:(void (^)(NSInteger))step {
    CBBHudRow *row = [[CBBHudRow alloc] init];
    row.title = title;
    row.valueText = valueText;
    row.step = step;
    return row;
}

+ (instancetype)rowWithTitle:(NSString *)title
                   valueText:(NSString * (^)(void))valueText
                    activate:(void (^)(void))activate {
    CBBHudRow *row = [[CBBHudRow alloc] init];
    row.title = title;
    row.valueText = valueText;
    row.activate = activate;
    return row;
}

@end

@implementation CBBStereoHUD

@synthesize rows = _rows;
@synthesize selectedIndex = _selectedIndex;
@synthesize statusText = _statusText;
@synthesize promptText = _promptText;
@synthesize buttonPoint = _buttonPoint;
@synthesize showButtonMarker = _showButtonMarker;

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        self.userInteractionEnabled = NO;
        self.contentMode = UIViewContentModeRedraw;
        self.multipleTouchEnabled = NO;
        _selectedIndex = 0;
    }
    return self;
}

- (void)setRows:(NSArray<CBBHudRow *> *)rows {
    _rows = [rows copy];
    [self setNeedsDisplay];
}

- (void)setSelectedIndex:(NSInteger)selectedIndex {
    _selectedIndex = selectedIndex;
    [self setNeedsDisplay];
}

- (void)setStatusText:(NSString *)statusText {
    _statusText = [statusText copy];
    [self setNeedsDisplay];
}

- (void)setPromptText:(NSString *)promptText {
    _promptText = [promptText copy];
    [self setNeedsDisplay];
}

- (void)setButtonPoint:(CGPoint)buttonPoint {
    _buttonPoint = buttonPoint;
    [self setNeedsDisplay];
}

- (void)setShowButtonMarker:(BOOL)showButtonMarker {
    _showButtonMarker = showButtonMarker;
    [self setNeedsDisplay];
}

- (void)setLandscape:(BOOL)landscape {
    if (_landscape == landscape) return;
    _landscape = landscape;
    [self setNeedsDisplay];
}

- (void)setRotationDegrees:(CGFloat)rotationDegrees {
    if (_rotationDegrees == rotationDegrees) return;
    _rotationDegrees = rotationDegrees;
    [self setNeedsDisplay];
}

#pragma mark - Drawing

static UIFont *CBBFont(CGFloat size, BOOL bold) {
    NSString *name = bold ? @"Menlo-Bold" : @"Menlo-Regular";
    UIFont *font = [UIFont fontWithName:name size:size];
    if (!font) {
        font = bold ? [UIFont boldSystemFontOfSize:size] : [UIFont systemFontOfSize:size];
    }
    return font;
}

- (void)drawRect:(CGRect)rect {
    CGContextRef context = UIGraphicsGetCurrentContext();
    if (!context) return;

    CGRect bounds = self.bounds;
    if (bounds.size.width < 2 || bounds.size.height < 2) return;

    if (self.landscape) {
        // Each eye half is rotated so the panel reads upright to someone
        // holding the phone sideways, which is the only way a Cardboard viewer
        // is used. The rotation follows the stereo image, so text and picture
        // never end up at odds.
        CGFloat radians = (CGFloat)(-self.rotationDegrees * M_PI / 180.0);
        for (NSInteger eye = 0; eye < 2; eye++) {
            CGRect eyeRect = CGRectMake(0,
                                        eye == 0 ? 0 : bounds.size.height * 0.5,
                                        bounds.size.width,
                                        bounds.size.height * 0.5);

            CGPoint marker = CGPointZero;
            BOOL hasMarker = NO;
            if (self.showButtonMarker) {
                CGPoint screenPoint = [self convertPoint:self.buttonPoint
                                      fromCoordinateSpace:[UIScreen mainScreen].fixedCoordinateSpace];
                CGPoint delta = CGPointMake(screenPoint.x - CGRectGetMidX(eyeRect),
                                            screenPoint.y - CGRectGetMidY(eyeRect));
                CGFloat cosine = cos(-radians);
                CGFloat sine = sin(-radians);
                marker = CGPointMake(delta.x * cosine - delta.y * sine,
                                     delta.x * sine + delta.y * cosine);
                hasMarker = YES;
            }

            CGContextSaveGState(context);
            CGContextTranslateCTM(context, CGRectGetMidX(eyeRect), CGRectGetMidY(eyeRect));
            CGContextRotateCTM(context, radians);
            CGRect panelSpace = CGRectMake(-eyeRect.size.height * 0.5,
                                           -eyeRect.size.width * 0.5,
                                           eyeRect.size.height,
                                           eyeRect.size.width);
            [self drawPanelInRect:panelSpace marker:marker hasMarker:hasMarker];
            CGContextRestoreGState(context);
        }
        return;
    }

    for (NSInteger eye = 0; eye < 2; eye++) {
        CGRect eyeRect = CGRectMake(eye == 0 ? 0 : bounds.size.width * 0.5,
                                    0,
                                    bounds.size.width * 0.5,
                                    bounds.size.height);

        CGPoint marker = CGPointZero;
        BOOL hasMarker = NO;
        if (self.showButtonMarker) {
            marker = [self convertPoint:self.buttonPoint
                   fromCoordinateSpace:[UIScreen mainScreen].fixedCoordinateSpace];
            hasMarker = YES;
        }
        [self drawPanelInRect:eyeRect marker:marker hasMarker:hasMarker];
    }
}

- (void)drawPanelInRect:(CGRect)eyeRect marker:(CGPoint)marker hasMarker:(BOOL)hasMarker {
    NSArray<CBBHudRow *> *rows = self.rows ?: @[];
    {
        CGFloat marginX = eyeRect.size.width * 0.06;
        CGFloat marginY = eyeRect.size.height * 0.07;
        CGRect panel = CGRectInset(eyeRect, marginX, marginY);

        UIBezierPath *panelPath = [UIBezierPath bezierPathWithRoundedRect:panel cornerRadius:14];
        [[UIColor colorWithWhite:0.0 alpha:0.72] setFill];
        [panelPath fill];

        CGFloat headerHeight = panel.size.height * 0.09;
        CGFloat footerHeight = panel.size.height * 0.17;
        CGFloat bodyHeight = MAX(panel.size.height - headerHeight - footerHeight, 1.0);
        CGFloat lineHeight = bodyHeight / MAX((CGFloat)rows.count, 1.0);
        CGFloat fontSize = MIN(MAX(lineHeight * 0.60, 5.5), 34.0);

        UIFont *titleFont = CBBFont(fontSize, NO);
        UIFont *valueFont = CBBFont(fontSize, YES);
        UIFont *headerFont = CBBFont(MIN(fontSize * 0.95, 20.0), YES);
        UIFont *footerFont = CBBFont(MIN(fontSize * 0.80, 17.0), NO);

        NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
        style.lineBreakMode = NSLineBreakByTruncatingTail;

        NSDictionary *titleAttrs = @{
            NSFontAttributeName: titleFont,
            NSForegroundColorAttributeName: [UIColor colorWithWhite:0.95 alpha:1.0],
            NSParagraphStyleAttributeName: style,
        };
        NSDictionary *selectedTitleAttrs = @{
            NSFontAttributeName: titleFont,
            NSForegroundColorAttributeName: [UIColor colorWithRed:1.0 green:0.86 blue:0.35 alpha:1.0],
            NSParagraphStyleAttributeName: style,
        };
        NSDictionary *valueAttrs = @{
            NSFontAttributeName: valueFont,
            NSForegroundColorAttributeName: [UIColor whiteColor],
            NSParagraphStyleAttributeName: style,
        };
        NSDictionary *headerAttrs = @{
            NSFontAttributeName: headerFont,
            NSForegroundColorAttributeName: [UIColor colorWithWhite:0.75 alpha:1.0],
            NSParagraphStyleAttributeName: style,
        };
        NSMutableParagraphStyle *footerStyle = [[NSMutableParagraphStyle alloc] init];
        footerStyle.lineBreakMode = NSLineBreakByWordWrapping;
        NSDictionary *footerAttrs = @{
            NSFontAttributeName: footerFont,
            NSForegroundColorAttributeName: [UIColor colorWithWhite:0.70 alpha:1.0],
            NSParagraphStyleAttributeName: footerStyle,
        };

        CGFloat textInset = panel.size.width * 0.035;
        CGFloat textWidth = panel.size.width - textInset * 2.0;

        NSString *header = @"CARDBOARDOS  ·  VIEWER MENU";
        [header drawInRect:CGRectMake(panel.origin.x + textInset,
                                      panel.origin.y + panel.size.height * 0.02,
                                      textWidth,
                                      headerHeight)
            withAttributes:headerAttrs];

        CGFloat rowTop = panel.origin.y + headerHeight + panel.size.height * 0.01;
        for (NSInteger i = 0; i < (NSInteger)rows.count; i++) {
            CGRect rowRect = CGRectMake(panel.origin.x + textInset * 0.5,
                                        rowTop + lineHeight * i,
                                        panel.size.width - textInset,
                                        lineHeight);
            if (i == self.selectedIndex) {
                UIBezierPath *highlight = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(rowRect, 0, lineHeight * 0.08)
                                                                         cornerRadius:lineHeight * 0.22];
                [[UIColor colorWithWhite:1.0 alpha:0.16] setFill];
                [highlight fill];
            }

            CBBHudRow *row = rows[i];
            NSString *title = row.title ?: @"";
            NSString *value = row.valueText ? row.valueText() : @"";
            NSDictionary *attrs = (i == self.selectedIndex) ? selectedTitleAttrs : titleAttrs;
            CGFloat valueWidth = [value sizeWithAttributes:valueAttrs].width;
            CGFloat titleWidth = MAX(textWidth - valueWidth - textInset, 1.0);

            [title drawInRect:CGRectMake(rowRect.origin.x + textInset * 0.5,
                                         rowRect.origin.y,
                                         titleWidth,
                                         lineHeight)
                withAttributes:attrs];
            [value drawInRect:CGRectMake(rowRect.origin.x + textWidth - valueWidth,
                                         rowRect.origin.y,
                                         valueWidth + 1.0,
                                         lineHeight)
                withAttributes:valueAttrs];
        }

        NSString *footer = self.statusText ?: @"";
        [footer drawInRect:CGRectMake(panel.origin.x + textInset,
                                      panel.origin.y + panel.size.height - footerHeight,
                                      textWidth,
                                      footerHeight)
            withAttributes:footerAttrs];

        if (self.promptText.length > 0) {
            NSDictionary *promptAttrs = @{
                NSFontAttributeName: CBBFont(MIN(fontSize * 1.1, 26.0), YES),
                NSForegroundColorAttributeName: [UIColor colorWithRed:1.0 green:0.86 blue:0.35 alpha:1.0],
                NSParagraphStyleAttributeName: style,
            };
            CGSize promptSize = [self.promptText sizeWithAttributes:promptAttrs];
            CGFloat width = MIN(promptSize.width + 24.0, eyeRect.size.width - marginX * 2.0);
            CGRect promptRect = CGRectMake(CGRectGetMidX(eyeRect) - width * 0.5,
                                           CGRectGetMidY(eyeRect) - 30.0,
                                           width,
                                           60.0);
            UIBezierPath *promptPath = [UIBezierPath bezierPathWithRoundedRect:promptRect cornerRadius:10];
            [[UIColor colorWithWhite:0.0 alpha:0.85] setFill];
            [promptPath fill];
            [self.promptText drawInRect:CGRectInset(promptRect, 8.0, 8.0) withAttributes:promptAttrs];
        }

        if (hasMarker && CGRectContainsPoint(eyeRect, marker)) {
            // Show the whole claimed disc, not just the centre, so its size and
            // position can be judged while learning.
            UIBezierPath *disc = [UIBezierPath bezierPathWithArcCenter:marker
                                                              radius:(CGFloat)CBB_BUTTON_CLAIM_RADIUS
                                                          startAngle:0
                                                            endAngle:(CGFloat)(M_PI * 2.0)
                                                           clockwise:YES];
            [[UIColor colorWithRed:1.0 green:0.45 blue:0.25 alpha:0.10] setFill];
            [disc fill];
            disc.lineWidth = 1.5;
            [[UIColor colorWithRed:1.0 green:0.45 blue:0.25 alpha:0.7] setStroke];
            [disc stroke];

            NSDictionary *markerAttrs = @{
                NSFontAttributeName: CBBFont(9.0, YES),
                NSForegroundColorAttributeName: [UIColor colorWithRed:1.0 green:0.55 blue:0.30 alpha:1.0],
            };
            [@"BUTTON" drawAtPoint:CGPointMake(marker.x + 6.0, marker.y + 6.0)
                    withAttributes:markerAttrs];
        }
    }
}

@end
