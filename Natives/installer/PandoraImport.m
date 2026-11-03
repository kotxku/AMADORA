#import "installer/FabricUtils.h"
#import "installer/ModDoctor.h"
#import "installer/PandoraImport.h"
#import "PLProfiles.h"
#import "UnzipKit.h"

@implementation PandoraImport

static id typed(id obj, Class cls) {
    return [obj isKindOfClass:cls] ? obj : nil;
}

+ (NSDictionary<NSString *, NSString *> *)loaderInfoForVersionId:(NSString *)versionId {
    // shortcut: assumes the Minecraft version has no '-', so snapshot/pre-release ids are misread; store the version in the profile if that matters
    NSArray<NSString *> *parts = [versionId componentsSeparatedByString:@"-"];
    if ([versionId hasPrefix:@"horizon-"]) return @{@"loader": @"horizon", @"mc": [versionId substringFromIndex:8]};
    if ([versionId hasPrefix:@"fabric-loader-"]) return @{@"loader": @"fabric", @"mc": parts.lastObject};
    if ([versionId hasPrefix:@"quilt-loader-"]) return @{@"loader": @"quilt", @"mc": parts.lastObject};
    if ([versionId containsString:@"-forge-"]) return @{@"loader": @"forge", @"mc": parts.firstObject};
    if ([versionId hasPrefix:@"neoforge-"]) return @{@"loader": @"neoforge", @"mc": @""};
    return @{@"loader": @"vanilla", @"mc": versionId ?: @""};
}

// Zip entries are untrusted: only relative paths that stay inside the destination
static BOOL isSafeRelativePath(NSString *path) {
    return path.length && ![path hasPrefix:@"/"] && ![[path componentsSeparatedByString:@"/"] containsObject:@".."];
}

// Streams one entry to disk; whole-file extraction would run out of memory on multi-GB worlds
+ (BOOL)extract:(UZKFileInfo *)info from:(UZKArchive *)archive to:(NSString *)dest error:(NSError **)error {
    NSFileManager *fm = NSFileManager.defaultManager;
    if (info.isDirectory || [info.filename hasSuffix:@"/"]) {
        return [fm createDirectoryAtPath:dest withIntermediateDirectories:YES attributes:nil error:error];
    }
    [fm createDirectoryAtPath:dest.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createFileAtPath:dest contents:nil attributes:nil];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:dest];
    BOOL extracted = handle && [archive extractBufferedDataFromFile:info.filename error:error action:^(NSData *chunk, CGFloat percent) {
        [handle writeData:chunk];
    }];
    [handle closeFile];
    return extracted;
}

// Pandora keeps installed modpacks as .mrpack files inside mods/ and unpacks them at every launch.
// Unpack them once here, honouring mods the player switched off in Pandora. Returns notes for the report.
+ (NSArray<NSString *> *)expandPandoraModpacksIn:(NSString *)gameDir mcVersion:(NSString **)mcVersion loader:(NSString **)loader
    loaderVersion:(NSString **)loaderVersion progress:(void (^)(NSString *))progress {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *modsDir = [gameDir stringByAppendingPathComponent:@"mods"];
    NSArray<NSString *> *modFiles = [fm contentsOfDirectoryAtPath:modsDir error:nil];
    NSMutableArray<NSString *> *notes = [NSMutableArray new];

    // shortcut: disabled lists from every .aux.json apply to every pack (Pandora pairs them per pack); fine with one pack per instance
    NSMutableSet *disabledIds = [NSMutableSet new], *disabledNames = [NSMutableSet new], *disabledFiles = [NSMutableSet new];
    for (NSString *file in modFiles) {
        if (![file hasSuffix:@".aux.json"]) continue;
        NSDictionary *aux = typed([ModDoctor parseJSON:[NSData dataWithContentsOfFile:[modsDir stringByAppendingPathComponent:file]]], NSDictionary.class);
        NSDictionary *children = typed(aux[@"disabled_children"], NSDictionary.class);
        [disabledIds addObjectsFromArray:typed(children[@"disabled_ids"], NSArray.class) ?: @[]];
        [disabledNames addObjectsFromArray:typed(children[@"disabled_names"], NSArray.class) ?: @[]];
        [disabledFiles addObjectsFromArray:typed(children[@"disabled_filenames"], NSArray.class) ?: @[]];
    }

    for (NSString *file in modFiles) {
        if (![file.pathExtension.lowercaseString isEqualToString:@"mrpack"]) continue;
        NSString *packPath = [modsDir stringByAppendingPathComponent:file];
        UZKArchive *pack = [[UZKArchive alloc] initWithPath:packPath error:nil];
        NSDictionary *index = typed([ModDoctor parseJSON:[pack extractDataFromFile:@"modrinth.index.json" error:nil]], NSDictionary.class);
        if (!index) {
            [notes addObject:[NSString stringWithFormat:@"%@ isn't a valid Modrinth pack, so it was skipped.", file]];
            continue;
        }

        NSDictionary *deps = typed(index[@"dependencies"], NSDictionary.class);
        if (!*mcVersion) *mcVersion = typed(deps[@"minecraft"], NSString.class);
        for (NSString *key in @[@"fabric-loader", @"quilt-loader", @"forge", @"neoforge"]) {
            if (!typed(deps[key], NSString.class)) continue;
            if ([*loader isEqualToString:@"vanilla"]) *loader = [key componentsSeparatedByString:@"-"].firstObject;
            // The pack's own loader version is what it was tested with
            if (!*loaderVersion) *loaderVersion = deps[key];
            break;
        }

        NSArray *files = typed(index[@"files"], NSArray.class);
        __block NSUInteger finished = 0, failed = 0, skipped = 0;
        NSObject *lock = [NSObject new];
        dispatch_semaphore_t slots = dispatch_semaphore_create(8);
        dispatch_apply(files.count, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t i) {
            NSDictionary *entry = typed(files[i], NSDictionary.class);
            NSString *relPath = typed(entry[@"path"], NSString.class);
            NSString *url = typed([typed(entry[@"downloads"], NSArray.class) firstObject], NSString.class);
            NSString *sha1 = typed(typed(entry[@"hashes"], NSDictionary.class)[@"sha1"], NSString.class);
            BOOL serverOnly = [typed(entry[@"env"], NSDictionary.class)[@"client"] isEqual:@"unsupported"];
            BOOL ok = YES, skip = !url || serverOnly || !isSafeRelativePath(relPath) || [disabledFiles containsObject:relPath.lastPathComponent];
            if (!skip) {
                NSString *dest = [gameDir stringByAppendingPathComponent:relPath];
                if (![fm fileExistsAtPath:dest]) {
                    dispatch_semaphore_wait(slots, DISPATCH_TIME_FOREVER);
                    ok = [ModDoctor download:url toFile:dest sha1:sha1];
                    dispatch_semaphore_signal(slots);
                }
                NSDictionary *info = ok ? [ModDoctor modInfoForJar:dest] : nil;
                if ([disabledIds containsObject:info[@"id"] ?: @""] || [disabledNames containsObject:info[@"name"] ?: @""]) {
                    [fm moveItemAtPath:dest toPath:[dest stringByAppendingString:@".disabled"] error:nil];
                }
            }
            @synchronized (lock) {
                if (skip) skipped++; else if (ok) finished++; else failed++;
                if (progress) progress([NSString stringWithFormat:@"%@\nDownloading mods: %lu of %lu", file, (unsigned long)(finished + failed + skipped), (unsigned long)files.count]);
            }
        });

        // Overrides were applied on the PC already; only add files that are missing so the player's settings survive
        NSUInteger overrides = 0;
        for (UZKFileInfo *info in [pack listFileInfo:nil]) {
            for (NSString *prefix in @[@"overrides/", @"client-overrides/"]) {
                if (![info.filename hasPrefix:prefix]) continue;
                NSString *relative = [info.filename substringFromIndex:prefix.length];
                NSString *dest = [gameDir stringByAppendingPathComponent:relative];
                if (!isSafeRelativePath(relative) || [fm fileExistsAtPath:dest]) continue;
                if ([self extract:info from:pack to:dest error:nil] && !info.isDirectory) overrides++;
            }
        }

        // Keep the pack file for reference, but out of mods/
        NSString *keepDir = [gameDir stringByAppendingPathComponent:@"pandora-modpacks"];
        [fm createDirectoryAtPath:keepDir withIntermediateDirectories:YES attributes:nil error:nil];
        [fm moveItemAtPath:packPath toPath:[keepDir stringByAppendingPathComponent:file] error:nil];

        NSMutableString *note = [NSMutableString stringWithFormat:@"Unpacked %@: %lu files installed, %lu override files added.", file, (unsigned long)finished, (unsigned long)overrides];
        if (failed) [note appendFormat:@" %lu downloads failed, so Mod Doctor will try to fill the gaps. Re-import on a better connection if mods are still missing.", (unsigned long)failed];
        [notes addObject:note];
    }
    return notes;
}

+ (BOOL)entries:(NSDictionary *)entries haveDirectory:(NSString *)dir {
    NSString *prefix = [dir stringByAppendingString:@"/"];
    for (NSString *name in entries) {
        if ([name hasPrefix:prefix]) return YES;
    }
    return NO;
}

+ (NSString *)importArchiveAtPath:(NSString *)path progress:(void (^)(NSString *))progress {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSError *error;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:path error:&error];
    NSArray<UZKFileInfo *> *infos = [archive listFileInfo:&error];
    if (!infos) {
        return [NSString stringWithFormat:@"Couldn't open %@ as a zip: %@", path.lastPathComponent, error.localizedDescription];
    }

    // Windows tools write "./" prefixes and backslashes
    NSMutableDictionary<NSString *, UZKFileInfo *> *entries = [NSMutableDictionary new];
    for (UZKFileInfo *info in infos) {
        NSString *name = [info.filename stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
        while ([name hasPrefix:@"./"]) name = [name substringFromIndex:2];
        if (name.length) entries[name] = info;
    }

    // The metadata file closest to the archive root decides the format
    NSString *metaPath;
    for (NSString *name in entries) {
        if (![@[@"info_v1.json", @"manifest.json"] containsObject:name.lastPathComponent]) continue;
        if (!metaPath || name.pathComponents.count < metaPath.pathComponents.count) metaPath = name;
    }

    NSString *name = path.lastPathComponent.stringByDeletingPathExtension;
    NSString *mcVersion, *loader, *loaderVersion;
    NSArray *curseForgeFiles;
    NSString *baseDir = metaPath.stringByDeletingLastPathComponent ?: @"";
    NSDictionary *meta = metaPath ? typed([ModDoctor parseJSON:[archive extractData:entries[metaPath] error:nil]], NSDictionary.class) : nil;
    if ([metaPath.lastPathComponent isEqualToString:@"manifest.json"] && !typed(meta[@"minecraft"], NSDictionary.class)) {
        // Some mod's own manifest.json, not a CurseForge pack
        meta = nil;
        baseDir = @"";
    }
    if ([metaPath.lastPathComponent isEqualToString:@"info_v1.json"]) {
        // Pandora Launcher instance
        mcVersion = typed(meta[@"minecraft_version"], NSString.class);
        loader = typed(meta[@"loader"], NSString.class);
        if (baseDir.length) name = baseDir.lastPathComponent;
    } else if (meta) {
        // CurseForge modpack
        NSDictionary *minecraft = typed(meta[@"minecraft"], NSDictionary.class);
        mcVersion = typed(minecraft[@"version"], NSString.class);
        name = typed(meta[@"name"], NSString.class) ?: name;
        curseForgeFiles = typed(meta[@"files"], NSArray.class);
        // e.g. "fabric-0.15.11", "forge-47.2.0", "neoforge-21.1.77"
        NSString *loaderId = typed(typed([typed(minecraft[@"modLoaders"], NSArray.class) firstObject], NSDictionary.class)[@"id"], NSString.class);
        NSRange dash = [loaderId rangeOfString:@"-"];
        if (loaderId && dash.location != NSNotFound) {
            loader = [loaderId substringToIndex:dash.location];
            loaderVersion = [loaderId substringFromIndex:dash.location + 1];
        }
    }
    loader = loader.lowercaseString ?: @"vanilla";

    // Find the folder inside the archive that holds the game files
    NSString *root = baseDir;
    for (NSString *sub in @[@".minecraft", @"minecraft", @"overrides"]) {
        NSString *candidate = [baseDir stringByAppendingPathComponent:sub];
        if ([self entries:entries haveDirectory:candidate]) {
            root = candidate;
            break;
        }
    }
    if (!meta) {
        // Plain zip: the game folder is whichever holds mods/, saves/ or config/
        root = nil;
        NSUInteger rootDepth = NSUIntegerMax;
        for (NSString *entry in entries) {
            NSArray *components = [entry componentsSeparatedByString:@"/"];
            for (NSUInteger i = 0; i < components.count - 1 && i < rootDepth; i++) {
                if ([@[@"mods", @"saves", @"config"] containsObject:components[i]]) {
                    root = [[components subarrayWithRange:NSMakeRange(0, i)] componentsJoinedByString:@"/"];
                    rootDepth = i;
                    break;
                }
            }
        }
        if (!root) {
            return @"This archive has no mods, saves or config folder, so it doesn't look like a Minecraft instance or modpack.";
        }
        if (root.length) name = root.lastPathComponent;
    }

    // Pick a free folder name for the new instance
    NSString *safeName = [[name componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/\\:"]] componentsJoinedByString:@"_"];
    if (safeName.length == 0 || [safeName hasPrefix:@"."]) safeName = [@"Imported" stringByAppendingString:safeName];
    NSString *gameDirs = [NSString stringWithFormat:@"%s/custom_gamedir", getenv("GAME_DIR")];
    NSString *folderName = safeName;
    for (int i = 2; [fm fileExistsAtPath:[gameDirs stringByAppendingPathComponent:folderName]]; i++) {
        folderName = [NSString stringWithFormat:@"%@ (%d)", safeName, i];
    }
    NSString *destDir = [gameDirs stringByAppendingPathComponent:folderName];

    NSString *prefix = root.length ? [root stringByAppendingString:@"/"] : @"";
    NSUInteger extractedCount = 0;
    for (NSString *entry in entries) {
        if (![entry hasPrefix:prefix]) continue;
        NSString *relative = [entry substringFromIndex:prefix.length];
        if (!isSafeRelativePath(relative)) continue;
        if (![self extract:entries[entry] from:archive to:[destDir stringByAppendingPathComponent:relative] error:&error]) {
            return [NSString stringWithFormat:@"Failed to extract %@: %@\nPartly imported files are in custom_gamedir/%@.", relative, error.localizedDescription, folderName];
        }
        if (progress && ++extractedCount % 200 == 0) {
            progress([NSString stringWithFormat:@"Extracting files: %lu of %lu", (unsigned long)extractedCount, (unsigned long)entries.count]);
        }
    }

    NSMutableArray<NSString *> *notes = [NSMutableArray new];
    [notes addObjectsFromArray:[self expandPandoraModpacksIn:destDir mcVersion:&mcVersion loader:&loader loaderVersion:&loaderVersion progress:progress]];

    // CurseForge packs only list mod ids; the website's download endpoint needs no API key
    NSUInteger curseForgeFailed = 0;
    for (NSDictionary *file in curseForgeFiles) {
        id projectID = typed(file, NSDictionary.class)[@"projectID"], fileID = typed(file, NSDictionary.class)[@"fileID"];
        if (!typed(projectID, NSNumber.class) || !typed(fileID, NSNumber.class)) continue;
        // shortcut: everything goes to mods/, so resource packs listed in the manifest land there too
        NSString *url = [NSString stringWithFormat:@"https://www.curseforge.com/api/v1/mods/%@/files/%@/download", projectID, fileID];
        if (![ModDoctor download:url toDirectory:[destDir stringByAppendingPathComponent:@"mods"]]) curseForgeFailed++;
    }
    if (curseForgeFailed) {
        [notes addObject:[NSString stringWithFormat:@"%lu CurseForge file(s) couldn't be downloaded, usually because their authors block third-party downloads. Get them from curseforge.com and put them in mods/.", (unsigned long)curseForgeFailed]];
    }

    // Work out which version to launch, installing the loader profile when we can
    NSString *versionId = mcVersion ?: @"latest-release";
    if (!mcVersion) {
        [notes addObject:@"This zip doesn't say which Minecraft version it's for. Edit the profile and pick the right version."];
    } else if ([loader isEqualToString:@"fabric"] || [loader isEqualToString:@"quilt"]) {
        NSDictionary *endpoints = FabricUtils.endpoints[[loader isEqualToString:@"fabric"] ? @"Fabric" : @"Quilt"];
        if (!loaderVersion) {
            for (NSDictionary *candidate in typed([ModDoctor parseJSON:[ModDoctor fetch:endpoints[@"loader"]]], NSArray.class)) {
                if (!typed(candidate, NSDictionary.class) || (candidate[@"stable"] && ![candidate[@"stable"] boolValue])) continue;
                loaderVersion = typed(candidate[@"version"], NSString.class);
                if (loaderVersion) break;
            }
        }
        NSData *profileJSON = loaderVersion ? [ModDoctor fetch:[NSString stringWithFormat:endpoints[@"json"], mcVersion, loaderVersion]] : nil;
        if (profileJSON) {
            versionId = [NSString stringWithFormat:@"%@-loader-%@-%@", loader, loaderVersion, mcVersion];
            NSString *versionDir = [NSString stringWithFormat:@"%s/versions/%@", getenv("GAME_DIR"), versionId];
            [fm createDirectoryAtPath:versionDir withIntermediateDirectories:YES attributes:nil error:nil];
            [profileJSON writeToFile:[versionDir stringByAppendingFormat:@"/%@.json", versionId] atomically:YES];
        } else {
            [notes addObject:[NSString stringWithFormat:@"Couldn't download the %@ loader for Minecraft %@. Check your connection, or install it from + > Fabric/Quilt and select it in this profile.", loader, mcVersion]];
        }
    } else if ([loader isEqualToString:@"forge"]) {
        // Same id the Forge installer creates, so the profile works once Forge is installed
        if (loaderVersion) versionId = [NSString stringWithFormat:@"%@-forge-%@", mcVersion, loaderVersion];
        [notes addObject:[NSString stringWithFormat:@"Forge has to be installed separately: tap + > Forge, install it for Minecraft %@, then select it in this profile.", mcVersion]];
    } else if ([loader isEqualToString:@"neoforge"]) {
        if (loaderVersion) versionId = [NSString stringWithFormat:@"neoforge-%@", loaderVersion];
        [notes addObject:[NSString stringWithFormat:@"NeoForge has to be installed separately with its installer jar for Minecraft %@, then selected in this profile.", mcVersion]];
    }

    NSMutableDictionary *profile = @{
        @"name": folderName,
        @"gameDir": [@"./custom_gamedir" stringByAppendingPathComponent:folderName],
        @"lastVersionId": versionId
    }.mutableCopy;
    NSData *icon = entries[[baseDir stringByAppendingPathComponent:@"icon.png"]] ? [archive extractData:entries[[baseDir stringByAppendingPathComponent:@"icon.png"]] error:nil] : nil;
    if (icon) {
        profile[@"icon"] = [@"data:image/png;base64," stringByAppendingString:[icon base64EncodedStringWithOptions:0]];
    }
    dispatch_sync(dispatch_get_main_queue(), ^{
        PLProfiles.current.profiles[folderName] = profile;
        PLProfiles.current.selectedProfileName = folderName; // also saves
    });

    if (progress) progress(@"Mod Doctor: checking for missing mods");
    NSString *doctor = [ModDoctor fixMissingModsInGameDir:destDir minecraftVersion:mcVersion loader:loader];

    // Mod Doctor may have added mods, so pick Java last
    int requiredJava = 0;
    int java = [ModDoctor selectJavaForProfile:profile versionJSON:nil required:&requiredJava javaHome:nil warning:nil];
    if (java) {
        dispatch_sync(dispatch_get_main_queue(), ^{
            profile[@"javaVersion"] = @(java).stringValue;
            [PLProfiles.current save];
        });
        [notes addObject:[NSString stringWithFormat:@"Java: set to Java %d%@.", java,
            requiredJava ? [NSString stringWithFormat:@", the lowest installed version that meets this pack's Java %d requirement", requiredJava] : @""]];
    } else {
        [notes addObject:[NSString stringWithFormat:@"This pack needs Java %d, which isn't installed. Install an AMADORA build that includes Java %d before playing it.", requiredJava, requiredJava]];
    }
    return [NSString stringWithFormat:@"Imported \"%@\" (%@ %@).\n\n%@%@%@",
        folderName, loader, mcVersion ?: @"unknown version",
        notes.count ? [notes componentsJoinedByString:@"\n\n"] : @"",
        notes.count ? @"\n\n" : @"", doctor];
}

@end
