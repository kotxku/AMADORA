#import <UIKit/UIKit.h>

// Horizon (github.com/horizon-rust/horizon), Minecraft: Java Edition 26.3 rewritten in Rust, built
// for iOS as Frameworks/libhorizon_ios.dylib (tools/horizon). It runs in AMADORA's own process: its
// window joins the app's scene, and HorizonControls gives it touch, keyboard and mouse input.
@interface HorizonGame : NSObject

// AME_HOME/horizon: the game folder (saves, options, logs).
+ (NSString *)homePath;
// homePath/resources: the prepared 26.3 game files, with horizon-resources.json.
+ (NSString *)resourcesPath;
// homePath/shaderpacks: Iris/OptiFine-format shader packs, picked in the game's Options >
// Horizon Settings > Shader Packs.
+ (NSString *)shaderpacksPath;
// The shader pack zips in shaderpacksPath, by name.
+ (NSArray<NSString *> *)shaderPacks;
// Copies a shader pack zip (one with shaders/ inside) into shaderpacksPath. Returns nil on
// success, else what went wrong.
+ (NSString *)importShaderPack:(NSString *)zipPath;
// Whether the IPA carries the Horizon engine.
+ (BOOL)engineAvailable;
// Whether the prepared game files are in place.
+ (BOOL)resourcesReady;
// Replaces the prepared game files with the folder holding horizon-resources.json in a zip;
// shader pack zips in its shaderpacks/ folder (export-horizon.ps1 -ShaderPacks) go to shaderpacksPath.
// Blocking; call off the main thread. Returns nil on success, else what went wrong.
+ (NSString *)importResourcesZip:(NSString *)zipPath progress:(void (^)(NSString *status))progress;
// Starts the game with the selected account. Does not return while the game runs; returns an
// error message when it can't start.
+ (NSString *)start;

@end
