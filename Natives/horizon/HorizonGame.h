#import <UIKit/UIKit.h>

// Horizon (github.com/horizon-rust/horizon), Minecraft: Java Edition 26.3 rewritten in Rust, built
// for iOS as Frameworks/libhorizon_ios.dylib (tools/horizon). It runs in AMADORA's own process: its
// window joins the app's scene, and HorizonControls gives it touch, keyboard and mouse input.
@interface HorizonGame : NSObject

// AME_HOME/horizon: the game folder (saves, options, logs).
+ (NSString *)homePath;
// homePath/resources: the prepared 26.3 game files, with horizon-resources.json.
+ (NSString *)resourcesPath;
// The game's pack folders in homePath: "shaderpacks" (Iris/OptiFine-format shader packs, picked
// in Options > Horizon Settings > Shader Packs) and "resourcepacks" (picked in Options > Resource Packs).
+ (NSString *)packsPath:(NSString *)folder;
// The pack zips in a pack folder, by name.
+ (NSArray<NSString *> *)packsIn:(NSString *)folder;
// Copies a pack zip into its folder: a shader pack has shaders/ at its top, a resource pack
// pack.mcmeta. Returns nil on success, else what went wrong.
+ (NSString *)importPack:(NSString *)zipPath into:(NSString *)folder;
// Whether the IPA carries the Horizon engine.
+ (BOOL)engineAvailable;
// Whether the prepared game files are in place.
+ (BOOL)resourcesReady;
// Replaces the prepared game files with the folder holding horizon-resources.json in a zip;
// pack zips in its shaderpacks/ and resourcepacks/ folders (export-horizon.ps1 -ShaderPacks,
// -ResourcePacks) go to the game's pack folders.
// Blocking; call off the main thread. Returns nil on success, else what went wrong.
+ (NSString *)importResourcesZip:(NSString *)zipPath progress:(void (^)(NSString *status))progress;
// Starts the game with the selected account. Does not return while the game runs; returns an
// error message when it can't start.
+ (NSString *)start;

@end
