#import <UIKit/UIKit.h>

// Horizon (github.com/horizon-rust/horizon), Minecraft: Java Edition 26.3 rewritten in Rust, built
// for iOS as Frameworks/libhorizon_ios.dylib (tools/horizon). It runs in AMADORA's own process: its
// window joins the app's scene, and HorizonControls gives it touch, keyboard and mouse input.
//
// A Horizon instance is an ordinary profile whose version is horizonVersionId: it keeps its saves,
// options and packs (resourcepacks/, shaderpacks/) in its own game folder, and Play starts Horizon
// there instead of Java Minecraft. The prepared 26.3 game files are shared by every Horizon instance.
@interface HorizonGame : NSObject

// The lastVersionId of a Horizon instance: "horizon-26.3".
@property(class, nonatomic, readonly) NSString *horizonVersionId;
// Whether a profile's lastVersionId is a Horizon one.
+ (BOOL)isHorizonVersion:(NSString *)versionId;
// AME_HOME/horizon: what all Horizon instances share.
+ (NSString *)homePath;
// homePath/resources: the prepared 26.3 game files, with horizon-resources.json.
+ (NSString *)resourcesPath;
// Whether the IPA carries the Horizon engine.
+ (BOOL)engineAvailable;
// Whether the prepared game files are in place.
+ (BOOL)resourcesReady;

// The Horizon instances, by name.
+ (NSArray<NSString *> *)instanceNames;
// Adds a Horizon instance with its own game folder and selects it. Main thread. Returns nil on
// success, else what went wrong.
+ (NSString *)createInstanceNamed:(NSString *)name;
// The first Horizon instance, made as "Horizon" when there is none. Main thread.
+ (NSString *)defaultInstanceName;

// Replaces the prepared game files with the folder holding horizon-resources.json in a zip; pack
// zips in its shaderpacks/ and resourcepacks/ folders (export-horizon.ps1 -ShaderPacks,
// -ResourcePacks) go to those folders of packsGameDir. Blocking; call off the main thread.
// Returns nil on success, else what went wrong.
+ (NSString *)importResourcesZip:(NSString *)zipPath packsGameDir:(NSString *)packsGameDir progress:(void (^)(NSString *status))progress;

// Unpacks a Horizon modpack zip (export-horizon-modpack.ps1: horizon-modpack.json, content-mods/,
// shaderpacks/, resourcepacks/, horizon-graphics.txt) into an instance's game folder. Each folder
// of content-mods/ with a horizon-mod.toml is a content mod (a Horizon port's carry folder) that
// Play loads with --dev-mod, in name order. The pack's graphics lines replace the same settings
// of the instance's. Blocking; call off the main thread. Returns nil on success, else what went wrong.
+ (NSString *)importModpackZip:(NSString *)zipPath gameDir:(NSString *)gameDir progress:(void (^)(NSString *status))progress;

// Starts the game in an instance's game folder with the selected account. Does not return while
// the game runs; returns an error message when it can't start. Call it from the run loop (a
// timer or performSelector:afterDelay:), not inside a touch's handling.
+ (NSString *)startInGameDir:(NSString *)gameDir;

@end
