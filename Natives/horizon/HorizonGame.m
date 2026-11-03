#import <GameController/GameController.h>
#import "authenticator/BaseAuthenticator.h"
#import "installer/PandoraImport.h"
#import "horizon/HorizonGame.h"
#import "UnzipKit.h"

#include <dlfcn.h>
#include <stdbool.h>
#include <unistd.h>

// libhorizon_ios.dylib's exports (tools/horizon/horizon-ios.patch, crates/horizon-ios)
static int (*h_main)(int argc, const char **argv);
static void (*h_key)(uint32_t hid, bool pressed);
static void (*h_text)(const char *text);
static void (*h_mouse_button)(uint32_t button, bool pressed);
static void (*h_cursor)(double x, double y);
static void (*h_mouse_motion)(double dx, double dy);
static void (*h_scroll)(double dx, double dy);
static bool (*h_cursor_grabbed)(void);
static bool (*h_has_window)(void);

// USB HID usages (UIKeyboardHIDUsage), what the game's key bridge takes
enum {
    kHidA = 4, kHidD = 7, kHidE = 8, kHidQ = 20, kHidS = 22, kHidT = 23, kHidW = 26,
    kHidEnter = 40, kHidEscape = 41, kHidBackspace = 42, kHidSpace = 44, kHidF5 = 62,
    kHidLeftControl = 224, kHidLeftShift = 225
};

static NSString *engineLibraryPath(void) {
    return [NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:@"libhorizon_ios.dylib"];
}

#pragma mark - Controls

// A button of the on-screen controls: sends its key (or mouse button) while held, or toggles it.
@interface HorizonControlButton : UIButton
@property(nonatomic) uint32_t hid;     // 0: a mouse button instead
@property(nonatomic) int mouseButton;  // with hid 0
@property(nonatomic) BOOL toggles;
@property(nonatomic) BOOL on;
@property(nonatomic) BOOL playingOnly; // hidden in menus
@property(nonatomic, copy) void (^tapped)(void);
@end

@implementation HorizonControlButton

+ (instancetype)title:(NSString *)title hid:(uint32_t)hid {
    HorizonControlButton *button = [self buttonWithType:UIButtonTypeCustom];
    button.hid = hid;
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    button.titleLabel.adjustsFontSizeToFitWidth = YES;
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.layer.cornerRadius = 10;
    button.layer.borderWidth = 1;
    button.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.35].CGColor;
    button.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
    [button addTarget:button action:@selector(down) forControlEvents:UIControlEventTouchDown];
    [button addTarget:button action:@selector(up) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    return button;
}

- (void)send:(BOOL)pressed {
    if (self.hid) {
        h_key(self.hid, pressed);
    } else {
        h_mouse_button(self.mouseButton, pressed);
    }
}

- (void)setOn:(BOOL)on {
    _on = on;
    self.backgroundColor = on ? [UIColor colorWithWhite:1 alpha:0.35] : [UIColor colorWithWhite:0 alpha:0.35];
}

- (void)down {
    if (self.tapped) return;
    if (self.toggles) {
        self.on = !self.on;
        [self send:self.on];
    } else {
        self.on = YES;
        [self send:YES];
    }
}

- (void)up {
    if (self.tapped) {
        self.tapped();
        return;
    }
    if (!self.toggles) {
        self.on = NO;
        [self send:NO];
    }
}

// Lets go of a held or toggled key, when the game leaves play for a menu
- (void)releaseIfHeld {
    if (self.on && !self.tapped) {
        self.on = NO;
        [self send:NO];
    }
}

@end

// The on-screen controls over the game's window. Playing (the game holds the pointer): a movement
// pad on the left, look by dragging elsewhere, tap to attack, hold to mine, and buttons. In menus,
// a touch is the pointer and a two-finger drag scrolls.
@interface HorizonControlsView : UIView <UIKeyInput>
@property(nonatomic) NSMutableArray<HorizonControlButton *> *buttons;
@property(nonatomic) UITouch *padTouch, *lookTouch, *pointerTouch;
@property(nonatomic) CGPoint padOrigin, lookLast, lookStart;
@property(nonatomic) NSTimeInterval lookStartTime;
@property(nonatomic) BOOL lookMoved, mining;
@property(nonatomic) NSMutableSet<NSNumber *> *padKeys;
@property(nonatomic) UIView *padRing, *padKnob;
@property(nonatomic) BOOL playing;
@property(nonatomic) CGFloat pixelScale;
@property(nonatomic) NSTimer *mineTimer;
@property(nonatomic) UIPanGestureRecognizer *scrollPan;
@property(nonatomic) CGFloat scrollLast;
@end

@implementation HorizonControlsView

- (instancetype)initWithFrame:(CGRect)frame pixelScale:(CGFloat)scale {
    self = [super initWithFrame:frame];
    self.pixelScale = scale;
    self.multipleTouchEnabled = YES;
    self.backgroundColor = UIColor.clearColor;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.padKeys = [NSMutableSet new];
    self.buttons = [NSMutableArray new];

    self.padRing = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 130, 130)];
    self.padRing.layer.cornerRadius = 65;
    self.padRing.layer.borderWidth = 2;
    self.padRing.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.3].CGColor;
    self.padRing.userInteractionEnabled = NO;
    self.padKnob = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 54, 54)];
    self.padKnob.layer.cornerRadius = 27;
    self.padKnob.backgroundColor = [UIColor colorWithWhite:1 alpha:0.3];
    self.padKnob.userInteractionEnabled = NO;
    [self addSubview:self.padRing];
    [self addSubview:self.padKnob];

    __weak HorizonControlsView *weakSelf = self;
    HorizonControlButton *keyboard = [HorizonControlButton title:@"⌨︎" hid:0];
    keyboard.tapped = ^{ [weakSelf toggleKeyboard]; };
    HorizonControlButton *chat = [HorizonControlButton title:@"Chat" hid:kHidT];
    chat.playingOnly = YES;
    chat.tapped = ^{
        h_key(kHidT, true);
        h_key(kHidT, false);
        [weakSelf becomeFirstResponder];
    };
    NSArray *top = @[
        [HorizonControlButton title:@"Esc" hid:kHidEscape], keyboard, chat,
        [HorizonControlButton title:@"Inv" hid:kHidE], [HorizonControlButton title:@"Drop" hid:kHidQ],
        [HorizonControlButton title:@"View" hid:kHidF5],
        [HorizonControlButton title:@"◀︎" hid:0], [HorizonControlButton title:@"▶︎" hid:0]
    ];
    HorizonControlButton *prev = top[6], *next = top[7];
    prev.tapped = ^{ h_scroll(0, 1); };
    next.tapped = ^{ h_scroll(0, -1); };
    for (HorizonControlButton *b in top) {
        b.playingOnly = b.hid != kHidEscape && b != keyboard;
        [self.buttons addObject:b];
    }
    HorizonControlButton *jump = [HorizonControlButton title:@"Jump" hid:kHidSpace];
    HorizonControlButton *sneak = [HorizonControlButton title:@"Sneak" hid:kHidLeftShift];
    sneak.toggles = YES;
    HorizonControlButton *sprint = [HorizonControlButton title:@"Sprint" hid:kHidLeftControl];
    sprint.toggles = YES;
    HorizonControlButton *attack = [HorizonControlButton title:@"Attack" hid:0];
    attack.mouseButton = 0;
    HorizonControlButton *use = [HorizonControlButton title:@"Use" hid:0];
    use.mouseButton = 1;
    for (HorizonControlButton *b in @[jump, sneak, sprint, attack, use]) {
        b.playingOnly = YES;
        [self.buttons addObject:b];
    }
    for (HorizonControlButton *b in self.buttons) {
        b.exclusiveTouch = NO;
        [self addSubview:b];
    }

    // Two fingers scroll in menus (lists, the creative inventory)
    self.scrollPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(scrollPanned:)];
    self.scrollPan.minimumNumberOfTouches = 2;
    self.scrollPan.cancelsTouchesInView = NO;
    [self addGestureRecognizer:self.scrollPan];
    // A mouse or trackpad pointer on iPad moves the game's pointer in menus
    [self addGestureRecognizer:[[UIHoverGestureRecognizer alloc] initWithTarget:self action:@selector(hovered:)]];

    [self setPlaying:NO force:YES];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    UIEdgeInsets safe = self.safeAreaInsets;
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    CGFloat left = MAX(safe.left, 12), right = w - MAX(safe.right, 12), top = MAX(safe.top, 8), bottom = h - MAX(safe.bottom, 10);
    // Top row: Esc, keyboard, chat, inventory, drop, view, hotbar
    CGFloat x = left;
    for (NSUInteger i = 0; i < 8; i++) {
        CGFloat bw = i >= 6 ? 40 : 52;
        self.buttons[i].frame = CGRectMake(x, top, bw, 36);
        x += bw + 6;
    }
    // Right side: jump big at the bottom, sneak and sprint beside it, attack and use above
    HorizonControlButton *jump = self.buttons[8], *sneak = self.buttons[9], *sprint = self.buttons[10],
        *attack = self.buttons[11], *use = self.buttons[12];
    jump.frame = CGRectMake(right - 84, bottom - 84, 84, 84);
    jump.layer.cornerRadius = 42;
    sneak.frame = CGRectMake(right - 84 - 74, bottom - 64, 64, 64);
    sneak.layer.cornerRadius = 32;
    sprint.frame = CGRectMake(right - 84 - 74, bottom - 64 - 74, 64, 64);
    sprint.layer.cornerRadius = 32;
    attack.frame = CGRectMake(right - 64, bottom - 84 - 84, 64, 64);
    attack.layer.cornerRadius = 32;
    use.frame = CGRectMake(right - 64, bottom - 84 - 84 - 74, 64, 64);
    use.layer.cornerRadius = 32;
    if (!self.padTouch) {
        self.padOrigin = CGPointMake(left + 90, bottom - 80);
        self.padRing.center = self.padKnob.center = self.padOrigin;
    }
}

- (void)setPlaying:(BOOL)playing force:(BOOL)force {
    if (playing == self.playing && !force) return;
    self.playing = playing;
    [self releaseAll];
    for (HorizonControlButton *b in self.buttons) {
        b.hidden = b.playingOnly && !playing;
    }
    self.padRing.hidden = self.padKnob.hidden = !playing;
}

// Lets go of every key and button: the game changed between play and a menu
- (void)releaseAll {
    for (HorizonControlButton *b in self.buttons) [b releaseIfHeld];
    [self pressPadKeys:[NSSet set]];
    if (self.mining) {
        h_mouse_button(0, false);
        self.mining = NO;
    }
    [self.mineTimer invalidate];
    if (self.pointerTouch) h_mouse_button(0, false);
    self.padTouch = self.lookTouch = self.pointerTouch = nil;
    self.padRing.center = self.padKnob.center = self.padOrigin;
}

- (CGPoint)pixels:(CGPoint)p {
    return CGPointMake(p.x * self.pixelScale, p.y * self.pixelScale);
}

// A mouse or trackpad on iPad sends its clicks through GCMouse; skip them as touches
- (BOOL)ignoresTouch:(UITouch *)touch {
    if (@available(iOS 14.0, *)) {
        return touch.type == UITouchTypeIndirectPointer && GCMouse.current != nil;
    }
    return NO;
}

#pragma mark Movement pad

- (void)pressPadKeys:(NSSet<NSNumber *> *)keys {
    for (NSNumber *k in self.padKeys.copy) {
        if (![keys containsObject:k]) {
            h_key(k.unsignedIntValue, false);
            [self.padKeys removeObject:k];
        }
    }
    for (NSNumber *k in keys) {
        if (![self.padKeys containsObject:k]) {
            h_key(k.unsignedIntValue, true);
            [self.padKeys addObject:k];
        }
    }
}

- (void)movePad:(CGPoint)p {
    CGFloat dx = p.x - self.padOrigin.x, dy = p.y - self.padOrigin.y, len = hypot(dx, dy), max = 50;
    CGPoint knob = len > max ? CGPointMake(self.padOrigin.x + dx / len * max, self.padOrigin.y + dy / len * max) : p;
    self.padKnob.center = knob;
    NSMutableSet *keys = [NSMutableSet new];
    if (len > 14) {
        // Eight directions: a key for each axis past 22.5 degrees of it
        CGFloat ux = dx / len, uy = dy / len;
        if (uy < -0.38) [keys addObject:@(kHidW)];
        if (uy > 0.38) [keys addObject:@(kHidS)];
        if (ux < -0.38) [keys addObject:@(kHidA)];
        if (ux > 0.38) [keys addObject:@(kHidD)];
    }
    [self pressPadKeys:keys];
}

#pragma mark Touches

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    for (UITouch *touch in touches) {
        if ([self ignoresTouch:touch]) continue;
        CGPoint p = [touch locationInView:self];
        if (!self.playing) {
            if (self.pointerTouch || event.allTouches.count > 1) continue;
            self.pointerTouch = touch;
            CGPoint px = [self pixels:p];
            h_cursor(px.x, px.y);
            h_mouse_button(0, true);
        } else if (!self.padTouch && p.x < self.bounds.size.width * 0.4 && p.y > self.bounds.size.height * 0.35) {
            self.padTouch = touch;
            self.padOrigin = p;
            self.padRing.center = p;
            [self movePad:p];
        } else if (!self.lookTouch) {
            self.lookTouch = touch;
            self.lookLast = self.lookStart = p;
            self.lookStartTime = touch.timestamp;
            self.lookMoved = NO;
            // Holding still mines (holds attack); a quick tap attacks once
            [self.mineTimer invalidate];
            self.mineTimer = [NSTimer scheduledTimerWithTimeInterval:0.35 repeats:NO block:^(NSTimer *t) {
                if (self.lookTouch && !self.lookMoved) {
                    self.mining = YES;
                    h_mouse_button(0, true);
                }
            }];
        }
    }
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    for (UITouch *touch in touches) {
        CGPoint p = [touch locationInView:self];
        if (touch == self.pointerTouch) {
            CGPoint px = [self pixels:p];
            h_cursor(px.x, px.y);
        } else if (touch == self.padTouch) {
            [self movePad:p];
        } else if (touch == self.lookTouch) {
            CGFloat dx = p.x - self.lookLast.x, dy = p.y - self.lookLast.y;
            self.lookLast = p;
            if (hypot(p.x - self.lookStart.x, p.y - self.lookStart.y) > 10) self.lookMoved = YES;
            // Points to mouse counts: about a vanilla 100% sensitivity turn for a thumb's swipe
            h_mouse_motion(dx * 2.2, dy * 2.2);
        }
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    for (UITouch *touch in touches) {
        if (touch == self.pointerTouch) {
            CGPoint px = [self pixels:[touch locationInView:self]];
            h_cursor(px.x, px.y);
            h_mouse_button(0, false);
            self.pointerTouch = nil;
        } else if (touch == self.padTouch) {
            self.padTouch = nil;
            [self pressPadKeys:[NSSet set]];
            [self setNeedsLayout];
        } else if (touch == self.lookTouch) {
            [self.mineTimer invalidate];
            if (self.mining) {
                h_mouse_button(0, false);
                self.mining = NO;
            } else if (!self.lookMoved && touch.timestamp - self.lookStartTime < 0.3) {
                h_mouse_button(0, true);
                h_mouse_button(0, false);
            }
            self.lookTouch = nil;
        }
    }
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self touchesEnded:touches withEvent:event];
}

- (void)scrollPanned:(UIPanGestureRecognizer *)pan {
    if (self.playing) return;
    CGFloat y = [pan translationInView:self].y;
    if (pan.state == UIGestureRecognizerStateBegan) {
        self.scrollLast = 0;
        // The second finger turns a click into a scroll
        if (self.pointerTouch) {
            h_mouse_button(0, false);
            self.pointerTouch = nil;
        }
    }
    CGFloat lines = (y - self.scrollLast) / 24;
    if (fabs(lines) >= 1) {
        h_scroll(0, (int)lines);
        self.scrollLast += (int)lines * 24;
    }
}

- (void)hovered:(UIHoverGestureRecognizer *)hover {
    if (self.playing) return;
    CGPoint px = [self pixels:[hover locationInView:self]];
    h_cursor(px.x, px.y);
}

#pragma mark On-screen keyboard (chat, signs, text fields)

- (BOOL)canBecomeFirstResponder {
    return YES;
}

- (void)toggleKeyboard {
    if (self.isFirstResponder) {
        [self resignFirstResponder];
    } else {
        [self becomeFirstResponder];
    }
}

- (BOOL)hasText {
    return YES;
}

- (UITextAutocorrectionType)autocorrectionType {
    return UITextAutocorrectionTypeNo;
}

- (UITextAutocapitalizationType)autocapitalizationType {
    return UITextAutocapitalizationTypeNone;
}

- (void)insertText:(NSString *)text {
    // A hardware keyboard already types through GCKeyboard
    if (@available(iOS 14.0, *)) {
        if (GCKeyboard.coalescedKeyboard) return;
    }
    if ([text isEqualToString:@"\n"]) {
        h_key(kHidEnter, true);
        h_key(kHidEnter, false);
        [self resignFirstResponder];
        return;
    }
    h_text(text.UTF8String);
}

- (void)deleteBackward {
    h_key(kHidBackspace, true);
    h_key(kHidBackspace, false);
}

@end

#pragma mark - Game

@implementation HorizonGame

static HorizonControlsView *controls;

+ (NSString *)homePath {
    return [@(getenv("AME_HOME")) stringByAppendingPathComponent:@"horizon"];
}

+ (NSString *)resourcesPath {
    return [self.homePath stringByAppendingPathComponent:@"resources"];
}

+ (NSString *)shaderpacksPath {
    return [self.homePath stringByAppendingPathComponent:@"shaderpacks"];
}

+ (NSArray<NSString *> *)shaderPacks {
    NSArray *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:self.shaderpacksPath error:nil];
    return [[names filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"self ENDSWITH[c] '.zip'"]]
        sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}

+ (NSString *)importShaderPack:(NSString *)zipPath {
    NSError *error;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:zipPath error:&error];
    NSArray<NSString *> *names = [archive listFilenames:&error];
    if (!names) {
        return [NSString stringWithFormat:@"Couldn't open %@ as a zip: %@", zipPath.lastPathComponent, error.localizedDescription];
    }
    BOOL isPack = NO;
    for (NSString *name in names) {
        if ([[name stringByReplacingOccurrencesOfString:@"\\" withString:@"/"] hasPrefix:@"shaders/"]) isPack = YES;
    }
    if (!isPack) {
        return @"That zip isn't a shader pack: it has no shaders/ folder at its top. Horizon takes Iris/OptiFine-format packs.";
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:self.shaderpacksPath withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *dest = [self.shaderpacksPath stringByAppendingPathComponent:zipPath.lastPathComponent];
    [fm removeItemAtPath:dest error:nil];
    if (![fm copyItemAtPath:zipPath toPath:dest error:&error]) {
        return [NSString stringWithFormat:@"Couldn't add the shader pack: %@", error.localizedDescription];
    }
    return nil;
}

+ (BOOL)engineAvailable {
    return [NSFileManager.defaultManager fileExistsAtPath:engineLibraryPath()];
}

+ (BOOL)resourcesReady {
    return [NSFileManager.defaultManager fileExistsAtPath:[self.resourcesPath stringByAppendingPathComponent:@"horizon-resources.json"]];
}

+ (NSString *)importResourcesZip:(NSString *)zipPath progress:(void (^)(NSString *))progress {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSError *error;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:zipPath error:&error];
    NSArray<UZKFileInfo *> *infos = [archive listFileInfo:&error];
    if (!infos) {
        return [NSString stringWithFormat:@"Couldn't open %@ as a zip: %@", zipPath.lastPathComponent, error.localizedDescription];
    }
    // The folder holding horizon-resources.json, wherever it sits in the zip
    NSString *prefix;
    for (UZKFileInfo *info in infos) {
        NSString *name = [info.filename stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
        if ([name.lastPathComponent isEqualToString:@"horizon-resources.json"] &&
            (!prefix || name.length < prefix.length + 22)) {
            prefix = [name substringToIndex:name.length - @"horizon-resources.json".length];
        }
    }
    if (!prefix) {
        return @"That zip has no horizon-resources.json. Make it on your computer with export-horizon.ps1, after the Horizon launcher has prepared 26.3.";
    }
    NSString *staging = [self.homePath stringByAppendingPathComponent:@"resources.importing"];
    [fm removeItemAtPath:staging error:nil];
    NSUInteger done = 0;
    for (UZKFileInfo *info in infos) {
        NSString *name = [info.filename stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
        // Shader packs the export carried along (export-horizon.ps1 -ShaderPacks)
        if ([name hasPrefix:@"shaderpacks/"] && [name.pathExtension.lowercaseString isEqualToString:@"zip"] &&
            name.pathComponents.count == 2) {
            NSString *pack = [self.shaderpacksPath stringByAppendingPathComponent:name.lastPathComponent];
            [fm removeItemAtPath:pack error:nil];
            if (![PandoraImport extract:info from:archive to:pack error:&error]) {
                return [NSString stringWithFormat:@"Couldn't extract the shader pack %@: %@", name.lastPathComponent, error.localizedDescription];
            }
            continue;
        }
        if (![name hasPrefix:prefix]) continue;
        if (!prefix.length && [name hasPrefix:@"shaderpacks/"]) continue;
        NSString *relative = [name substringFromIndex:prefix.length];
        if (!relative.length || [relative hasPrefix:@"/"] || [[relative componentsSeparatedByString:@"/"] containsObject:@".."]) continue;
        if (![PandoraImport extract:info from:archive to:[staging stringByAppendingPathComponent:relative] error:&error]) {
            [fm removeItemAtPath:staging error:nil];
            return [NSString stringWithFormat:@"Couldn't extract %@: %@", relative, error.localizedDescription];
        }
        if (++done % 200 == 0 && progress) {
            progress([NSString stringWithFormat:@"Extracted %lu of %lu files", (unsigned long)done, (unsigned long)infos.count]);
        }
    }
    [fm removeItemAtPath:self.resourcesPath error:nil];
    if (![fm moveItemAtPath:staging toPath:self.resourcesPath error:&error]) {
        return [NSString stringWithFormat:@"Couldn't put the game files in place: %@", error.localizedDescription];
    }
    return nil;
}

static BOOL loadEngine(NSString **message) {
    if (h_main) return YES;
    void *lib = dlopen(engineLibraryPath().UTF8String, RTLD_NOW | RTLD_LOCAL);
    if (!lib) {
        *message = [NSString stringWithFormat:@"Couldn't load the Horizon engine: %s", dlerror()];
        return NO;
    }
#define LOAD(var, name) var = dlsym(lib, name); if (!var) { *message = @"The Horizon engine lacks " @name; return NO; }
    LOAD(h_key, "horizon_ios_key");
    LOAD(h_text, "horizon_ios_text");
    LOAD(h_mouse_button, "horizon_ios_mouse_button");
    LOAD(h_cursor, "horizon_ios_cursor");
    LOAD(h_mouse_motion, "horizon_ios_mouse_motion");
    LOAD(h_scroll, "horizon_ios_scroll");
    LOAD(h_cursor_grabbed, "horizon_ios_cursor_grabbed");
    LOAD(h_has_window, "horizon_ios_has_window");
    LOAD(h_main, "horizon_ios_main");
#undef LOAD
    return YES;
}

// The Microsoft account's session for online-mode servers, in the file the game reads
// (--session-file); nil for a local account, which plays offline under its name.
static NSString *writeSession(NSString *home) {
    NSDictionary *auth = BaseAuthenticator.current.authData;
    NSString *token = auth[@"accessToken"], *uuid = auth[@"profileId"], *name = auth[@"username"];
    if (![BaseAuthenticator.current isKindOfClass:MicrosoftAuthenticator.class] || !token.length || !uuid.length || !name.length) {
        return nil;
    }
    NSMutableDictionary *session = @{@"name": name, @"uuid": uuid, @"access_token": token, @"user_type": @"msa"}.mutableCopy;
    if ([auth[@"xuid"] isKindOfClass:NSString.class]) session[@"xuid"] = auth[@"xuid"];
    NSString *path = [home stringByAppendingPathComponent:@"session.json"];
    NSData *json = [NSJSONSerialization dataWithJSONObject:session options:0 error:nil];
    if (![json writeToFile:path options:NSDataWritingAtomic | NSDataWritingFileProtectionComplete error:nil]) return nil;
    return path;
}

// Hardware keyboard and mouse, through GameController: UIKit gives the game's own window none
static void connectKeyboardAndMouse(void) {
    if (@available(iOS 14.0, *)) {
        void (^keyboard)(GCKeyboard *) = ^(GCKeyboard *kb) {
            kb.keyboardInput.keyChangedHandler = ^(GCKeyboardInput *input, GCControllerButtonInput *key, GCKeyCode code, BOOL pressed) {
                h_key((uint32_t)code, pressed);
            };
        };
        void (^mouse)(GCMouse *) = ^(GCMouse *m) {
            GCMouseInput *input = m.mouseInput;
            input.mouseMovedHandler = ^(GCMouseInput *mi, float dx, float dy) {
                if (h_cursor_grabbed()) h_mouse_motion(dx, -dy);
            };
            input.leftButton.pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL pressed) { h_mouse_button(0, pressed); };
            input.rightButton.pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL pressed) { h_mouse_button(1, pressed); };
            input.middleButton.pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL pressed) { h_mouse_button(2, pressed); };
            input.scroll.valueChangedHandler = ^(GCControllerDirectionPad *pad, float x, float y) {
                if (x != 0 || y != 0) h_scroll(x, y);
            };
        };
        if (GCKeyboard.coalescedKeyboard) keyboard(GCKeyboard.coalescedKeyboard);
        for (GCMouse *m in GCMouse.mice) mouse(m);
        [NSNotificationCenter.defaultCenter addObserverForName:GCKeyboardDidConnectNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
            keyboard(n.object);
        }];
        [NSNotificationCenter.defaultCenter addObserverForName:GCMouseDidConnectNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
            mouse(n.object);
        }];
    }
}

// Puts the controls on the game's window once it opens, then follows play and menus
static void watchGameWindow(void) {
    NSTimer *timer = [NSTimer timerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *t) {
        if (!controls) {
            if (!h_has_window()) return;
            UIWindow *gameWindow;
            for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                if (![scene isKindOfClass:UIWindowScene.class]) continue;
                for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                    if ([NSStringFromClass(w.class) isEqualToString:@"WinitUIWindow"]) gameWindow = w;
                }
            }
            if (!gameWindow) return;
            UIView *gameView = gameWindow.rootViewController.view;
            CGFloat scale = gameView.contentScaleFactor ?: gameWindow.screen.nativeScale;
            controls = [[HorizonControlsView alloc] initWithFrame:gameWindow.bounds pixelScale:scale];
            [gameWindow addSubview:controls];
        }
        [controls.superview bringSubviewToFront:controls];
        [controls setPlaying:h_cursor_grabbed() force:NO];
    }];
    [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
}

+ (NSString *)start {
    NSString *message;
    if (!self.engineAvailable) return @"This build of AMADORA doesn't include the Horizon engine.";
    if (!self.resourcesReady) return @"Import Horizon's game files first.";
    if (!loadEngine(&message)) return message;

    NSString *home = self.homePath;
    [NSFileManager.defaultManager createDirectoryAtPath:home withIntermediateDirectories:YES attributes:nil error:nil];
    // The game keeps servers.dat and the like in its working folder
    chdir(home.fileSystemRepresentation);
    setenv("HORIZON_HOME", home.fileSystemRepresentation, 1);

    NSMutableArray<NSString *> *args = @[@"--home", home, @"--game-dir", home, @"--resources", self.resourcesPath].mutableCopy;
    NSString *session = writeSession(home);
    if (session) {
        [args addObjectsFromArray:@[@"--session-file", session]];
    } else {
        NSString *name = BaseAuthenticator.current.authData[@"username"];
        if (name.length) [args addObjectsFromArray:@[@"--name", name]];
    }

    connectKeyboardAndMouse();
    watchGameWindow();
    NSLog(@"[Horizon] Starting: %@", [args componentsJoinedByString:@" "]);
    const char **argv = calloc(args.count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < args.count; i++) argv[i] = strdup(args[i].UTF8String);
    // Runs the game on this (the main) thread; returns only if it ends
    h_main((int)args.count, argv);
    exit(0);
}

@end
