#import <CoreText/CoreText.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "PLTheme.h"
#import "UIKit+hook.h"

static NSString *interName;
static const NSInteger kGlassTag = 0x504c47;
static char kShownAtKey, kRevealedKey;

static UIColor *hex(uint32_t rgb) {
    return [UIColor colorWithRed:((rgb >> 16) & 0xff) / 255.0 green:((rgb >> 8) & 0xff) / 255.0 blue:(rgb & 0xff) / 255.0 alpha:1];
}

static BOOL liquidGlass(void) {
    return _UISolariumEnabled && _UISolariumEnabled() && NSClassFromString(@"UIGlassEffect");
}

// Liquid Glass on iOS 26 and later (looked up at run time, so older SDKs build it), else a dark blur
static UIVisualEffect *glassEffect(void) {
    if (liquidGlass()) {
        return ((UIVisualEffect *(*)(id, SEL, NSInteger))objc_msgSend)(NSClassFromString(@"UIGlassEffect"), @selector(effectWithStyle:), 0);
    }
    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
}

// Swaps in a method even when the class only inherits the original (didMoveToWindow comes from UIView)
static void hook(Class cls, SEL original, SEL replacement) {
    Method o = class_getInstanceMethod(cls, original), r = class_getInstanceMethod(cls, replacement);
    if (class_addMethod(cls, original, method_getImplementation(r), method_getTypeEncoding(r))) {
        class_replaceMethod(cls, replacement, method_getImplementation(o), method_getTypeEncoding(o));
    } else {
        method_exchangeImplementations(o, r);
    }
}

// Slowly drifting purple and teal glows behind the launcher's lists: the logo's gem and sparkles
@interface PLGlowView : UIView
@end

@implementation PLGlowView {
    CAGradientLayer *_blobs[2];
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    self.backgroundColor = PLTheme.background;
    self.userInteractionEnabled = NO;
    uint32_t colors[2] = {0x7b3fe4, 0x5ee6d0};
    CGFloat alphas[2] = {0.45, 0.2};
    for (int i = 0; i < 2; i++) {
        CAGradientLayer *blob = [CAGradientLayer layer];
        blob.type = kCAGradientLayerRadial;
        blob.colors = @[(id)[hex(colors[i]) colorWithAlphaComponent:alphas[i]].CGColor, (id)[hex(colors[i]) colorWithAlphaComponent:0].CGColor];
        blob.startPoint = CGPointMake(0.5, 0.5);
        blob.endPoint = CGPointMake(1, 1);
        [self.layer addSublayer:blob];
        _blobs[i] = blob;
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGSize s = self.bounds.size;
    CGFloat d = MAX(s.width, s.height) * 0.85;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _blobs[0].frame = CGRectMake(-d * 0.35, -d * 0.3, d, d);
    _blobs[1].frame = CGRectMake(s.width - d * 0.55, s.height - d * 0.5, d * 0.9, d * 0.9);
    [CATransaction commit];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window || UIAccessibilityIsReduceMotionEnabled()) return;
    for (int i = 0; i < 2; i++) {
        CABasicAnimation *drift = [CABasicAnimation animationWithKeyPath:@"transform"];
        drift.toValue = [NSValue valueWithCATransform3D:CATransform3DScale(CATransform3DMakeTranslation(i ? -60 : 70, i ? -40 : 50, 0), 1.12, 1.12, 1)];
        drift.duration = i ? 17 : 13;
        drift.autoreverses = YES;
        drift.repeatCount = HUGE_VALF;
        drift.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [_blobs[i] addAnimation:drift forKey:@"drift"];
    }
}

@end

@implementation UITableView (PLTheme)

- (void)pl_didMoveToWindow {
    [self pl_didMoveToWindow];
    if (!self.window) return;
    objc_setAssociatedObject(self, &kShownAtKey, @(CACurrentMediaTime()), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!self.backgroundView && [self.backgroundColor isEqual:PLTheme.background]) {
        self.backgroundView = [PLGlowView new];
    }
}

@end

@implementation UITableViewCell (PLTheme)

// Rows rise in, staggered, when a launcher list appears, and one by one as scrolling brings new ones
- (void)pl_cellDidMoveToWindow {
    [self pl_cellDidMoveToWindow];
    if (!self.window || UIAccessibilityIsReduceMotionEnabled() || objc_getAssociatedObject(self, &kRevealedKey)) return;
    UIView *view = self.superview;
    while (view && ![view isKindOfClass:UITableView.class]) view = view.superview;
    UITableView *table = (UITableView *)view;
    if (![table.backgroundView isKindOfClass:PLGlowView.class]) return;
    BOOL justShown = CACurrentMediaTime() - [objc_getAssociatedObject(table, &kShownAtKey) doubleValue] < 0.8;
    // Not on a reload of a list already on screen
    if (!justShown && !table.isDragging && !table.isDecelerating) return;
    objc_setAssociatedObject(self, &kRevealedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    static CFTimeInterval batchStart;
    static NSInteger index;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - batchStart > 0.3) {
        batchStart = now;
        index = 0;
    }
    NSTimeInterval delay = justShown ? MIN(index++, 10) * 0.045 : 0;
    self.alpha = 0;
    self.transform = CGAffineTransformMakeTranslation(0, 28);
    [UIView animateWithDuration:0.75 delay:delay usingSpringWithDamping:0.86 initialSpringVelocity:0.2
        options:UIViewAnimationOptionAllowUserInteraction animations:^{
        self.alpha = 1;
        self.transform = CGAffineTransformIdentity;
    } completion:nil];
}

@end

@implementation PLTheme

// The AMADORA logo's palette (docs/branding): night background, gem purples, lilac highlight, teal sparkles
+ (UIColor *)background { return hex(0x170b2c); }
+ (UIColor *)border { return hex(0x3b1a8f); }
+ (UIColor *)foreground { return hex(0xf1e8ff); }
+ (UIColor *)muted { return hex(0xb98cff); }
+ (UIColor *)accent { return hex(0x5ee6d0); }
+ (UIColor *)surface { return [hex(0x3b1a8f) colorWithAlphaComponent:0.22]; }

+ (UIColor *)colorForKind:(PLButtonKind)kind {
    switch (kind) {
        case PLButtonKindSuccess: return hex(0x7b3fe4);
        case PLButtonKindInfo: return hex(0x3b1a8f);
        case PLButtonKindDanger: return hex(0x9b1c3c);
        case PLButtonKindPlain: return UIColor.clearColor;
    }
}

// A rounded pill with a sideways gradient, sliced so it stretches to any button without losing either
+ (UIImage *)pillForKind:(PLButtonKind)kind {
    static NSMutableDictionary<NSNumber *, UIImage *> *cache;
    if (!cache) cache = [NSMutableDictionary new];
    if (cache[@(kind)]) return cache[@(kind)];
    NSArray *stops = kind == PLButtonKindSuccess ? @[hex(0x9257f0), hex(0x7b3fe4), hex(0x4f25b5)]
        : kind == PLButtonKindDanger ? @[hex(0xc0284f), hex(0x9b1c3c), hex(0x6e1230)]
        : @[hex(0x4a24a8), hex(0x3b1a8f), hex(0x281066)];
    CGRect rect = CGRectMake(0, 0, 80, 40);
    UIImage *image = [[[UIGraphicsImageRenderer alloc] initWithSize:rect.size] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [[UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:12] addClip];
        CAGradientLayer *gradient = [CAGradientLayer layer];
        gradient.frame = rect;
        gradient.colors = [stops valueForKey:@"CGColor"];
        gradient.startPoint = CGPointMake(0, 0.5);
        gradient.endPoint = CGPointMake(1, 0.5);
        [gradient renderInContext:context.CGContext];
    }];
    cache[@(kind)] = image;
    return image;
}

+ (UIFont *)fontOfSize:(CGFloat)size {
    UIFont *font = interName ? [UIFont fontWithName:interName size:size] : nil;
    return font ?: [UIFont systemFontOfSize:size];
}

+ (void)registerInter {
    NSURL *url = [NSBundle.mainBundle URLForResource:@"Inter-Regular" withExtension:@"ttf"];
    if (!url) return;
    CTFontManagerRegisterFontsForURL((__bridge CFURLRef)url, kCTFontManagerScopeProcess, NULL);
    NSArray *descriptors = CFBridgingRelease(CTFontManagerCreateFontDescriptorsFromURL((__bridge CFURLRef)url));
    if (descriptors.count) {
        interName = CFBridgingRelease(CTFontDescriptorCopyAttribute((__bridge CTFontDescriptorRef)descriptors.firstObject, kCTFontNameAttribute));
    }
}

+ (void)apply {
    [self registerInter];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        hook(UITableView.class, @selector(didMoveToWindow), @selector(pl_didMoveToWindow));
        hook(UITableViewCell.class, @selector(didMoveToWindow), @selector(pl_cellDidMoveToWindow));
    });

    // Glass bars: the system's Liquid Glass where there is one, else a tinted blur over the content
    BOOL glass = liquidGlass();
    UIColor *barTint = glass ? nil : [self.background colorWithAlphaComponent:0.55];
    UIBlurEffect *barBlur = glass ? nil : [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];

    UINavigationBarAppearance *nav = [UINavigationBarAppearance new];
    [nav configureWithDefaultBackground];
    nav.backgroundColor = barTint;
    nav.backgroundEffect = barBlur;
    nav.shadowColor = UIColor.clearColor;
    nav.titleTextAttributes = @{NSForegroundColorAttributeName: self.foreground, NSFontAttributeName: [self fontOfSize:18]};
    nav.largeTitleTextAttributes = @{NSForegroundColorAttributeName: self.foreground, NSFontAttributeName: [self fontOfSize:30]};
    UINavigationBar.appearance.standardAppearance = nav;
    UINavigationBar.appearance.compactAppearance = nav;
    UINavigationBar.appearance.scrollEdgeAppearance = nav;

    UIToolbarAppearance *toolbar = [UIToolbarAppearance new];
    [toolbar configureWithDefaultBackground];
    toolbar.backgroundColor = barTint;
    toolbar.backgroundEffect = barBlur;
    toolbar.shadowColor = UIColor.clearColor;
    UIToolbar.appearance.standardAppearance = toolbar;
    UIToolbar.appearance.compactAppearance = toolbar;
    if (@available(iOS 15.0, *)) {
        UIToolbar.appearance.scrollEdgeAppearance = toolbar;
    }

    UITableView.appearance.backgroundColor = self.background;
    UITableView.appearance.separatorColor = [UIColor colorWithWhite:1 alpha:0.08];
    UITableViewCell.appearance.backgroundColor = self.surface;
    UICollectionView.appearance.backgroundColor = self.background;

    UISegmentedControl.appearance.selectedSegmentTintColor = hex(0x7b3fe4);
    [UISegmentedControl.appearance setTitleTextAttributes:@{NSForegroundColorAttributeName: self.foreground, NSFontAttributeName: [self fontOfSize:14]} forState:UIControlStateNormal];
    UISwitch.appearance.onTintColor = self.accent;
    UISwitch.appearance.thumbTintColor = self.foreground;
    UIProgressView.appearance.progressTintColor = self.accent;
}

+ (void)applyToWindow:(UIWindow *)window {
    window.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    window.tintColor = self.accent;
    window.backgroundColor = self.background;
}

+ (UIButton *)buttonWithTitle:(NSString *)title systemImage:(NSString *)image kind:(PLButtonKind)kind {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    if (image) {
        [button setImage:[UIImage systemImageNamed:image withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:13]] forState:UIControlStateNormal];
    }
    [self styleButton:button kind:kind];
    return button;
}

+ (void)styleButton:(UIButton *)button kind:(PLButtonKind)kind {
    BOOL plain = kind == PLButtonKindPlain;
    button.backgroundColor = plain ? [UIColor colorWithWhite:1 alpha:0.04] : UIColor.clearColor;
    // The pill is the layer's own picture, stretched by its middle; UIButton draws nothing there itself
    button.layer.contents = plain ? nil : (id)[self pillForKind:kind].CGImage;
    button.layer.contentsScale = UIScreen.mainScreen.scale;
    button.layer.contentsGravity = kCAGravityResize;
    button.layer.contentsCenter = CGRectMake(13 / 80.0, 13 / 40.0, 54 / 80.0, 14 / 40.0);
    button.tintColor = self.foreground;
    [button setTitleColor:self.foreground forState:UIControlStateNormal];
    [button setTitleColor:self.muted forState:UIControlStateDisabled];
    button.titleLabel.font = [self fontOfSize:15];
    button.layer.cornerRadius = 12;
    button.layer.cornerCurve = kCACornerCurveContinuous;
    button.layer.borderWidth = plain ? 1 : 0;
    button.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.14].CGColor;
    // The main actions glow
    button.layer.shadowColor = [self colorForKind:kind].CGColor;
    button.layer.shadowOpacity = kind == PLButtonKindSuccess ? 0.55 : 0;
    button.layer.shadowRadius = 12;
    button.layer.shadowOffset = CGSizeMake(0, 6);
    button.contentEdgeInsets = UIEdgeInsetsMake(8, 14, 8, 14);
    if (button.currentImage) {
        button.imageEdgeInsets = UIEdgeInsetsMake(0, -4, 0, 4);
        button.contentEdgeInsets = UIEdgeInsetsMake(8, 18, 8, 14);
    }
    [button removeTarget:self action:NULL forControlEvents:UIControlEventAllEvents];
    [button addTarget:self action:@selector(pressDown:) forControlEvents:UIControlEventTouchDown | UIControlEventTouchDragEnter];
    [button addTarget:self action:@selector(pressDrag:event:) forControlEvents:UIControlEventTouchDragInside];
    [button addTarget:self action:@selector(pressUp:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel | UIControlEventTouchDragExit];
}

// Pressed buttons sink, lean a little toward the finger, and spring back
+ (void)pressDown:(UIButton *)button {
    if (UIAccessibilityIsReduceMotionEnabled()) return;
    [UIView animateWithDuration:0.25 delay:0 usingSpringWithDamping:0.7 initialSpringVelocity:0
        options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState animations:^{
        button.transform = CGAffineTransformMakeScale(0.94, 0.94);
    } completion:nil];
}

+ (void)pressDrag:(UIButton *)button event:(UIEvent *)event {
    if (UIAccessibilityIsReduceMotionEnabled()) return;
    CGPoint p = [event.allTouches.anyObject locationInView:button];
    CGFloat dx = MAX(-8, MIN(8, (p.x - CGRectGetMidX(button.bounds)) * 0.12));
    CGFloat dy = MAX(-6, MIN(6, (p.y - CGRectGetMidY(button.bounds)) * 0.2));
    [UIView animateWithDuration:0.3 delay:0
        options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseOut animations:^{
        button.transform = CGAffineTransformScale(CGAffineTransformMakeTranslation(dx, dy), 0.94, 0.94);
    } completion:nil];
}

+ (void)pressUp:(UIButton *)button {
    [UIView animateWithDuration:0.7 delay:0 usingSpringWithDamping:0.45 initialSpringVelocity:0.8
        options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState animations:^{
        button.transform = CGAffineTransformIdentity;
    } completion:nil];
}

+ (UILabel *)sectionHeaderLabel:(NSString *)text {
    UILabel *label = [UILabel new];
    label.text = text;
    label.font = [self fontOfSize:13];
    label.textColor = self.muted;
    return label;
}

+ (void)styleCard:(UIView *)view {
    view.backgroundColor = self.surface;
    view.layer.cornerRadius = 18;
    view.layer.cornerCurve = kCACornerCurveContinuous;
    view.layer.borderWidth = 1;
    view.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.1].CGColor;
    if ([view viewWithTag:kGlassTag] || [view isKindOfClass:UIStackView.class] || [view isKindOfClass:UIVisualEffectView.class]) return;
    UIVisualEffectView *glass = [[UIVisualEffectView alloc] initWithEffect:glassEffect()];
    glass.tag = kGlassTag;
    glass.frame = view.bounds;
    glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    glass.userInteractionEnabled = NO;
    glass.layer.cornerRadius = 18;
    glass.layer.cornerCurve = kCACornerCurveContinuous;
    glass.clipsToBounds = YES;
    [view insertSubview:glass atIndex:0];
    if (liquidGlass()) view.backgroundColor = UIColor.clearColor;
}

@end
