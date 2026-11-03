#import <UIKit/UIKit.h>

// Pandora Launcher's layout in the AMADORA logo's colours (docs/branding), shared by every launcher screen.
typedef NS_ENUM(NSInteger, PLButtonKind) {
    PLButtonKindSuccess, // green: Install, Add, Play
    PLButtonKindInfo,    // blue: Open Page, secondary actions
    PLButtonKindDanger,  // red: Delete, Kill
    PLButtonKindPlain    // bordered, no fill: segment-like choices
};

@interface PLTheme : NSObject

@property(class, nonatomic, readonly) UIColor *background; // #170b2c
@property(class, nonatomic, readonly) UIColor *border;     // #3b1a8f, also the selected-row pill
@property(class, nonatomic, readonly) UIColor *foreground; // #f1e8ff
@property(class, nonatomic, readonly) UIColor *muted;      // #b98cff
@property(class, nonatomic, readonly) UIColor *accent;     // #5ee6d0: links, switches, progress
@property(class, nonatomic, readonly) UIColor *surface;    // translucent #3b1a8f: rows and cards over the glow

+ (UIColor *)colorForKind:(PLButtonKind)kind;
// Inter Regular (bundled; Pandora ships only that weight) at the given size; the system font if it failed to load
+ (UIFont *)fontOfSize:(CGFloat)size;

// Registers Inter and sets UIAppearance defaults. Call once before the first window appears.
+ (void)apply;
// Forces dark mode on a window, since Pandora has no light theme
+ (void)applyToWindow:(UIWindow *)window;

+ (UIButton *)buttonWithTitle:(NSString *)title systemImage:(NSString *)image kind:(PLButtonKind)kind;
+ (void)styleButton:(UIButton *)button kind:(PLButtonKind)kind;
// Pandora's small grey section headers ("Library", "Content", ...)
+ (UILabel *)sectionHeaderLabel:(NSString *)text;
// A rounded glass card: Liquid Glass on iOS 26 and later, else a dark blur
+ (void)styleCard:(UIView *)view;

@end
