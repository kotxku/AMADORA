#import <Foundation/Foundation.h>

// Makes Horizon's 26.3 files on the device, with no PC: downloads the pinned 26.3 files from
// Mojang into the shared game folder, then runs Horizon's own preparer (horizon_ios_prepare)
// inside AMADORA's Java, which HorizonPrepare.java starts. The app's IPA ships only Horizon's
// own code for it (the prepare root under horizon-prepare/), never Mojang's files.
@interface HorizonSetup : NSObject

// Whether this IPA carries the preparer's files.
+ (BOOL)available;
// Downloads what preparing needs (about 700 MB the first time; files already there are kept).
// Blocking: call off the main thread. Returns nil on success, else what went wrong.
+ (NSString *)downloadWithProgress:(void (^)(NSString *status))progress;
// Copies the preparer's files out of the app and writes the jar AMADORA runs to start it.
// Returns the jar's path, or nil with *error set.
+ (NSString *)prepareLaunchJar:(NSString **)error;

@end
