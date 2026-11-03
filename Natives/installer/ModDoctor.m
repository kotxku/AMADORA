#include <CommonCrypto/CommonDigest.h>

#import "LauncherPreferences.h"
#import "ModDoctor.h"
#import "UnzipKit.h"

@implementation ModDoctor

static id typed(id obj, Class cls) {
    return [obj isKindOfClass:cls] ? obj : nil;
}

+ (NSMutableURLRequest *)requestFor:(NSString *)url {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    // Modrinth asks clients to identify themselves
    [request setValue:@"kotxku/AMADORA" forHTTPHeaderField:@"User-Agent"];
    return request;
}

+ (NSData *)fetch:(NSString *)url {
    if (!url) return nil;
    __block NSData *result;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [[NSURLSession.sharedSession dataTaskWithRequest:[self requestFor:url]
    completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!error && [(NSHTTPURLResponse *)response statusCode] == 200) result = data;
        dispatch_semaphore_signal(done);
    }] resume];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    return result;
}

+ (NSString *)download:(NSString *)url toDirectory:(NSString *)dir {
    if (!url) return nil;
    __block NSString *saved;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [[NSURLSession.sharedSession downloadTaskWithRequest:[self requestFor:url]
    completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        // Server-supplied name is untrusted: keep only the last component
        NSString *name = response.suggestedFilename.lastPathComponent;
        if (!error && [(NSHTTPURLResponse *)response statusCode] == 200 && name.length && ![name hasPrefix:@"."]) {
            NSFileManager *fm = NSFileManager.defaultManager;
            NSString *dest = [dir stringByAppendingPathComponent:name];
            [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
            [fm removeItemAtPath:dest error:nil];
            if ([fm moveItemAtPath:location.path toPath:dest error:nil]) saved = name;
        }
        dispatch_semaphore_signal(done);
    }] resume];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    return saved;
}

+ (BOOL)download:(NSString *)url toFile:(NSString *)path sha1:(NSString *)sha1 {
    if (!url) return NO;
    __block BOOL saved = NO;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [[NSURLSession.sharedSession downloadTaskWithRequest:[self requestFor:url]
    completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        if (!error && [(NSHTTPURLResponse *)response statusCode] == 200 && (!sha1 || [[self sha1OfFile:location.path] isEqualToString:sha1.lowercaseString])) {
            NSFileManager *fm = NSFileManager.defaultManager;
            [fm createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
            [fm removeItemAtPath:path error:nil];
            saved = [fm moveItemAtPath:location.path toPath:path error:nil];
        }
        dispatch_semaphore_signal(done);
    }] resume];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    return saved;
}

+ (NSString *)sha1OfFile:(NSString *)path {
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    if (!data) return nil;
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString new];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

+ (NSDictionary *)modInfoForJar:(NSString *)jarPath {
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:jarPath error:nil];
    return typed([self parseJSON:[archive extractDataFromFile:@"fabric.mod.json" error:nil]], NSDictionary.class);
}

+ (id)parseJSON:(NSData *)data {
    if (!data) return nil;
    NSJSONReadingOptions options = kNilOptions;
    if (@available(iOS 15.0, *)) {
        // fabric.mod.json files often have comments or trailing commas, which Fabric itself accepts
        options = NSJSONReadingJSON5Allowed;
    }
    return [NSJSONSerialization JSONObjectWithData:data options:options error:nil];
}


// Adds the mod ids a jar provides and, per mod id, what it depends on, including mods bundled inside it (jar-in-jar).
+ (void)scanJar:(NSString *)jarPath provides:(NSMutableSet *)provides depends:(NSMutableDictionary<NSString *, NSMutableSet *> *)depends {
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:jarPath error:nil];
    NSDictionary *json = typed([self parseJSON:[archive extractDataFromFile:@"fabric.mod.json" error:nil]], NSDictionary.class);
    if (!json) return;

    NSString *modId = typed(json[@"id"], NSString.class);
    if (modId) [provides addObject:modId];
    for (id alias in typed(json[@"provides"], NSArray.class)) {
        if (typed(alias, NSString.class)) [provides addObject:alias];
    }
    NSString *owner = modId ?: jarPath;
    if (!depends[owner]) depends[owner] = [NSMutableSet new];
    [depends[owner] addObjectsFromArray:[typed(json[@"depends"], NSDictionary.class) allKeys] ?: @[]];

    for (NSDictionary *jar in typed(json[@"jars"], NSArray.class)) {
        NSString *inner = typed(typed(jar, NSDictionary.class)[@"file"], NSString.class);
        NSData *innerData = inner ? [archive extractDataFromFile:inner error:nil] : nil;
        if (!innerData) continue;
        // UnzipKit can only open archives from disk
        NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        [innerData writeToFile:tmp atomically:NO];
        [self scanJar:tmp provides:provides depends:depends];
        [NSFileManager.defaultManager removeItemAtPath:tmp error:nil];
    }
}

+ (NSString *)modrinthFileURLForProject:(NSString *)project minecraftVersion:(NSString *)mcVersion loaders:(NSString *)loaders {
    NSURLComponents *url = [NSURLComponents componentsWithString:[NSString stringWithFormat:@"https://api.modrinth.com/v2/project/%@/version",
        [project stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet]]];
    url.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"loaders" value:loaders],
        [NSURLQueryItem queryItemWithName:@"game_versions" value:[NSString stringWithFormat:@"[\"%@\"]", mcVersion]]
    ];
    NSDictionary *version = typed([typed([self parseJSON:[self fetch:url.URL.absoluteString]], NSArray.class) firstObject], NSDictionary.class);
    NSArray *files = typed(version[@"files"], NSArray.class);
    NSDictionary *file = files.firstObject;
    for (NSDictionary *candidate in files) {
        if ([typed(candidate, NSDictionary.class)[@"primary"] boolValue]) file = candidate;
    }
    return typed(typed(file, NSDictionary.class)[@"url"], NSString.class);
}

static NSString *normalized(NSString *name) {
    NSCharacterSet *separators = [NSCharacterSet characterSetWithCharactersInString:@"-_ "];
    return [[name.lowercaseString componentsSeparatedByCharactersInSet:separators] componentsJoinedByString:@""];
}

+ (NSString *)fileURLForModId:(NSString *)modId minecraftVersion:(NSString *)mcVersion loader:(NSString *)loader {
    NSString *loaders = [loader isEqualToString:@"quilt"] ? @"[\"quilt\",\"fabric\"]" : @"[\"fabric\"]";
    // "fabric" is the old id of Fabric API
    NSString *slug = [modId isEqualToString:@"fabric"] ? @"fabric-api" : modId;

    // Most mod ids are also their Modrinth slug
    NSOrderedSet *slugs = [NSOrderedSet orderedSetWithArray:@[slug, [slug stringByReplacingOccurrencesOfString:@"_" withString:@"-"]]];
    for (NSString *candidate in slugs) {
        NSString *url = [self modrinthFileURLForProject:candidate minecraftVersion:mcVersion loaders:loaders];
        if (url) return url;
    }

    // Otherwise search, but only accept a project whose slug or title matches the id, so we never install a lookalike
    NSURLComponents *search = [NSURLComponents componentsWithString:@"https://api.modrinth.com/v2/search"];
    search.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"query" value:modId],
        [NSURLQueryItem queryItemWithName:@"limit" value:@"10"],
        [NSURLQueryItem queryItemWithName:@"facets" value:[NSString stringWithFormat:@"[[\"project_type:mod\"],[\"versions:%@\"]]", mcVersion]]
    ];
    NSDictionary *response = typed([self parseJSON:[self fetch:search.URL.absoluteString]], NSDictionary.class);
    for (NSDictionary *hit in typed(response[@"hits"], NSArray.class)) {
        NSString *hitSlug = typed(typed(hit, NSDictionary.class)[@"slug"], NSString.class);
        NSString *title = typed(hit[@"title"], NSString.class);
        NSString *projectId = typed(hit[@"project_id"], NSString.class);
        if (!projectId || (![normalized(hitSlug) isEqualToString:normalized(slug)] && ![normalized(title) isEqualToString:normalized(slug)])) continue;
        NSString *url = [self modrinthFileURLForProject:projectId minecraftVersion:mcVersion loaders:loaders];
        if (url) return url;
    }
    return nil;
}

// Applies config/fabric_loader_dependencies.json the way Fabric Loader does; packs use it to drop dependencies they don't need
+ (void)applyDependencyOverridesIn:(NSString *)gameDir to:(NSMutableDictionary<NSString *, NSMutableSet *> *)depends {
    NSString *path = [gameDir stringByAppendingPathComponent:@"config/fabric_loader_dependencies.json"];
    NSDictionary *overrides = typed(typed([self parseJSON:[NSData dataWithContentsOfFile:path]], NSDictionary.class)[@"overrides"], NSDictionary.class);
    for (NSString *modId in overrides) {
        NSDictionary *rules = typed(overrides[modId], NSDictionary.class);
        if (!depends[modId] || !rules) continue;
        NSDictionary *replace = typed(rules[@"depends"], NSDictionary.class);
        if (replace) [depends[modId] setSet:[NSSet setWithArray:replace.allKeys]];
        [depends[modId] addObjectsFromArray:[typed(rules[@"+depends"], NSDictionary.class) allKeys] ?: @[]];
        [depends[modId] minusSet:[NSSet setWithArray:[typed(rules[@"-depends"], NSDictionary.class) allKeys] ?: @[]]];
    }
}

+ (NSString *)fixMissingModsInGameDir:(NSString *)gameDir minecraftVersion:(NSString *)mcVersion loader:(NSString *)loader {
    NSString *switchedOff = [self disableUnsupportedModsIn:[gameDir stringByAppendingPathComponent:@"mods"]];
    NSString *report = [self checkDependenciesInGameDir:gameDir minecraftVersion:mcVersion loader:loader];
    return switchedOff ? [NSString stringWithFormat:@"%@\n\n%@", switchedOff, report] : report;
}

// Mods whose native code has no iOS build, by mod id or file name prefix. Renamed to .jar.disabled instead of deleted,
// so the player can turn them back on.
static NSDictionary<NSString *, NSString *> *unsupportedMods(void) {
    return @{
        @"c2me": @"C2ME: its native code has no iOS build and crashes Minecraft",
        @"physicsmod": @"Physics Mod: needs NVIDIA PhysX, which has no iOS version",
        @"physics-mod": @"Physics Mod: needs NVIDIA PhysX, which has no iOS version",
        @"zfastnoise-ocl": @"Fast Noise OpenCL: needs OpenCL, which iOS doesn't have",
        // Only the SDL3 builds (4.6.x, Minecraft 26.3): they call SDL's raw nSDL_* entry points, which the bridge
        // doesn't emulate. The GLFW builds for 26.2 and older keep working.
        @"ixeris-4.6": @"Ixeris: moves SDL window calls to another thread; on iOS those go through AMADORA's SDL bridge, which it can't drive"
    };
}

+ (NSString *)disableUnsupportedModsIn:(NSString *)modsDir {
    return [self prepareModsIn:modsDir requiredJava:NULL requiredBy:NULL];
}

// Lowest Java major a Fabric version predicate allows: ">=21", ">17", "^21", "21", "*". Space-separated parts all apply.
static int minJavaForPredicate(NSString *predicate) {
    int result = 0;
    for (NSString *part in [predicate componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet]) {
        if ([part hasPrefix:@"<"]) continue; // an upper bound says nothing about the minimum
        NSScanner *scanner = [NSScanner scannerWithString:part];
        BOOL greater = [scanner scanString:@">" intoString:nil];
        BOOL orEqual = [scanner scanString:@"=" intoString:nil];
        [scanner scanCharactersFromSet:[NSCharacterSet characterSetWithCharactersInString:@"^~="] intoString:nil];
        int version;
        if (![scanner scanInt:&version]) continue;
        if (version == 1 && [scanner scanString:@"." intoString:nil]) [scanner scanInt:&version]; // "1.8"
        result = MAX(result, greater && !orEqual ? version + 1 : version);
    }
    return result;
}

// The Java major this jar (or a jar inside it) declares: Fabric/Quilt depends.java, or a "java" dependency in mods.toml
+ (void)scanJavaOfJar:(NSString *)jarPath fileName:(NSString *)fileName best:(int *)best mod:(NSString **)mod {
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:jarPath error:nil];
    NSDictionary *json = typed([self parseJSON:[archive extractDataFromFile:@"fabric.mod.json" error:nil]], NSDictionary.class);
    int required = 0;
    id java = typed(json[@"depends"], NSDictionary.class)[@"java"];
    if (typed(java, NSString.class)) {
        required = minJavaForPredicate(java);
    } else if (typed(java, NSArray.class)) {
        required = INT_MAX; // alternatives: the lowest one is enough
        for (id predicate in java) if (typed(predicate, NSString.class)) required = MIN(required, minJavaForPredicate(predicate));
        if (required == INT_MAX) required = 0;
    }
    // shortcut: assumes modId comes before versionRange in each [[dependencies]] block, as Forge's template writes it
    static NSRegularExpression *tomlJava;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        tomlJava = [NSRegularExpression regularExpressionWithPattern:@"modId\\s*=\\s*\"java\"[^\\]]*?versionRange\\s*=\\s*\"[\\[(]\\s*(?:1\\.)?(\\d+)" options:0 error:nil];
    });
    for (NSString *toml in @[@"META-INF/mods.toml", @"META-INF/neoforge.mods.toml"]) {
        NSData *data = [archive extractDataFromFile:toml error:nil];
        NSString *text = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        NSTextCheckingResult *match = text ? [tomlJava firstMatchInString:text options:0 range:NSMakeRange(0, text.length)] : nil;
        if (match) required = MAX(required, [text substringWithRange:[match rangeAtIndex:1]].intValue);
    }
    if (required > *best) {
        *best = required;
        *mod = [NSString stringWithFormat:@"%@ (%@)", typed(json[@"id"], NSString.class) ?: fileName, fileName];
    }

    for (NSDictionary *jar in typed(json[@"jars"], NSArray.class)) {
        NSString *inner = typed(typed(jar, NSDictionary.class)[@"file"], NSString.class);
        NSData *innerData = inner ? [archive extractDataFromFile:inner error:nil] : nil;
        if (!innerData) continue;
        // UnzipKit can only open archives from disk
        NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        [innerData writeToFile:tmp atomically:NO];
        [self scanJavaOfJar:tmp fileName:[NSString stringWithFormat:@"%@ in %@", inner.lastPathComponent, fileName] best:best mod:mod];
        [NSFileManager.defaultManager removeItemAtPath:tmp error:nil];
    }
}

// An unsupported mod bundled jar-in-jar (zfastnoise ships zfastnoise-ocl inside it) can't be renamed away, so the outer
// jar is rebuilt without it; the untouched original stays next to it as .jar.original. Returns a report line, or nil.
+ (NSString *)stripUnsupportedNestedJarsFrom:(NSString *)path fileName:(NSString *)file {
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:path error:nil];
    NSMutableDictionary *json = [typed([self parseJSON:[archive extractDataFromFile:@"fabric.mod.json" error:nil]], NSDictionary.class) mutableCopy];
    NSMutableArray *keptJars = [NSMutableArray new];
    NSMutableSet<NSString *> *dropped = [NSMutableSet new];
    NSMutableArray *reasons = [NSMutableArray new];
    for (NSDictionary *jar in typed(json[@"jars"], NSArray.class)) {
        NSString *inner = typed(typed(jar, NSDictionary.class)[@"file"], NSString.class);
        NSString *reason;
        for (NSString *key in unsupportedMods()) {
            if ([inner.lastPathComponent.lowercaseString hasPrefix:key]) reason = unsupportedMods()[key];
        }
        if (reason) {
            [dropped addObject:inner];
            [reasons addObject:[NSString stringWithFormat:@"%@ (%@ in %@)", reason, inner.lastPathComponent, file]];
        } else {
            [keptJars addObject:jar];
        }
    }
    if (!dropped.count) return nil;

    json[@"jars"] = keptJars;
    NSData *newJSON = [NSJSONSerialization dataWithJSONObject:json options:NSJSONWritingPrettyPrinted error:nil];
    NSString *tmp = [path stringByAppendingString:@".tmp"];
    [NSFileManager.defaultManager removeItemAtPath:tmp error:nil];
    UZKArchive *rebuilt = [[UZKArchive alloc] initWithPath:tmp error:nil];
    BOOL ok = newJSON && rebuilt;
    for (UZKFileInfo *info in ok ? [archive listFileInfo:nil] : @[]) {
        if (info.isDirectory || [dropped containsObject:info.filename]) continue;
        NSData *data = [info.filename isEqualToString:@"fabric.mod.json"] ? newJSON : [archive extractData:info error:nil];
        if (!data || ![rebuilt writeData:data filePath:info.filename error:nil]) {
            ok = NO;
            break;
        }
    }
    NSString *original = [path stringByAppendingString:@".original"];
    NSFileManager *files = NSFileManager.defaultManager;
    [files removeItemAtPath:original error:nil];
    if (!ok || ![files moveItemAtPath:path toPath:original error:nil] || ![files moveItemAtPath:tmp toPath:path error:nil]) {
        NSLog(@"[ModDoctor] Couldn't remove %@ from %@", [dropped.allObjects componentsJoinedByString:@", "], file);
        [files removeItemAtPath:tmp error:nil];
        if (![files fileExistsAtPath:path]) [files moveItemAtPath:original toPath:path error:nil];
        return nil;
    }
    NSLog(@"[ModDoctor] Switched off %@ (kept the rest of %@; original saved as %@)",
        [reasons componentsJoinedByString:@", "], file, original.lastPathComponent);
    return [reasons componentsJoinedByString:@"\n"];
}

+ (NSString *)prepareModsIn:(NSString *)modsDir requiredJava:(int *)requiredJava requiredBy:(NSString **)requiredBy {
    NSMutableArray *disabled = [NSMutableArray new];
    int best = 0;
    NSString *bestMod;
    for (NSString *file in [NSFileManager.defaultManager contentsOfDirectoryAtPath:modsDir error:nil]) {
        if (![file.pathExtension.lowercaseString isEqualToString:@"jar"]) continue;
        NSString *path = [modsDir stringByAppendingPathComponent:file];
        NSString *modId = [typed([self modInfoForJar:path][@"id"], NSString.class) lowercaseString];
        NSString *reason;
        for (NSString *key in unsupportedMods()) {
            if ([file.lowercaseString hasPrefix:key] || [modId hasPrefix:key]) reason = unsupportedMods()[key];
        }
        if (reason) {
            if ([NSFileManager.defaultManager moveItemAtPath:path toPath:[path stringByAppendingString:@".disabled"] error:nil]) {
                NSLog(@"[ModDoctor] Switched off %@: %@", file, reason);
                [disabled addObject:[NSString stringWithFormat:@"%@ (%@)", reason, file]];
            }
            continue;
        }
        NSString *stripped = [self stripUnsupportedNestedJarsFrom:path fileName:file];
        if (stripped) [disabled addObject:stripped];
        if (requiredJava) [self scanJavaOfJar:path fileName:file best:&best mod:&bestMod];
    }
    if (requiredJava) *requiredJava = best;
    if (requiredBy) *requiredBy = bestMod;
    return disabled.count ? [NSString stringWithFormat:@"Switched off mods that can't work on iOS:\n%@\n\nThey were renamed to .jar.disabled in mods/.",
        [disabled componentsJoinedByString:@"\n"]] : nil;
}

// A vanilla version JSON from Mojang's version manifest, or nil (unknown id, offline). Blocking.
+ (NSDictionary *)mojangVersionJSON:(NSString *)versionId {
    static NSArray *versions;
    if (!versions) {
        NSDictionary *manifest = typed([self parseJSON:[self fetch:@"https://piston-meta.mojang.com/mc/game/version_manifest_v2.json"]], NSDictionary.class);
        versions = typed(manifest[@"versions"], NSArray.class);
    }
    for (NSDictionary *version in versions) {
        if (![typed(version, NSDictionary.class)[@"id"] isEqual:versionId]) continue;
        NSString *url = typed(version[@"url"], NSString.class);
        NSDictionary *json = url ? typed([self parseJSON:[self fetch:url]], NSDictionary.class) : nil;
        NSLog(@"[JavaSelect] %@ isn't downloaded yet; read javaVersion %@ from Mojang's manifest", versionId, json[@"javaVersion"][@"majorVersion"] ?: @"(unavailable)");
        return json;
    }
    return nil;
}

// javaVersion.majorVersion of a version JSON, following inheritsFrom (a loader profile usually doesn't set its own)
+ (int)javaMajorInVersionJSON:(NSDictionary *)json versionId:(NSString *)versionId {
    if ([versionId hasPrefix:@"latest-"]) {
        versionId = typed(getPrefObject(@"internal.latest_version"), NSDictionary.class)[[versionId substringFromIndex:7]];
    }
    int major = 0;
    for (int depth = 0; depth < 5 && (json || versionId); depth++) {
        if (!json) {
            NSString *path = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json", getenv("GAME_DIR"), versionId];
            json = typed([self parseJSON:[NSData dataWithContentsOfFile:path]], NSDictionary.class);
            // Not downloaded yet (a freshly imported pack): read javaVersion from Mojang's copy instead of reporting 0
            if (!json) json = [self mojangVersionJSON:versionId];
            if (!json) break;
        }
        NSDictionary *java = typed(json[@"javaVersion"], NSDictionary.class);
        major = MAX(major, [java[@"majorVersion"] intValue] ?: [java[@"version"] intValue]);
        versionId = typed(json[@"inheritsFrom"], NSString.class);
        json = nil;
    }
    return major;
}

+ (int)selectJavaForProfile:(NSDictionary *)profile versionJSON:(NSDictionary *)json required:(int *)required javaHome:(NSString **)javaHome warning:(NSString **)warning {
    NSString *gameDir = [@(getenv("GAME_DIR")) stringByAppendingPathComponent:typed(profile[@"gameDir"], NSString.class) ?: @"."];
    NSString *versionId = typed(profile[@"lastVersionId"], NSString.class);
    int mcJava = [self javaMajorInVersionJSON:json versionId:versionId];
    int modJava = 0;
    NSString *mod;
    NSString *disabled = [self prepareModsIn:[gameDir stringByAppendingPathComponent:@"mods"] requiredJava:&modJava requiredBy:&mod];
    int need = MAX(mcJava, modJava);
    NSString *home;
    int selected = selectJavaRuntime(need, [profile[@"javaVersion"] intValue], &home);

    NSArray *installed = [installedJavaRuntimes().allKeys sortedArrayUsingSelector:@selector(compare:)];
    NSLog(@"[JavaSelect] %@: Minecraft %@ needs Java %@, mods need Java %d%@; installed: %@ -> %@",
        profile[@"name"] ?: versionId, versionId, mcJava ? @(mcJava).stringValue : @"(unknown: version JSON unavailable)", modJava,
        mod ? [NSString stringWithFormat:@" (highest: %@)", mod] : @"",
        [installed componentsJoinedByString:@", "],
        selected ? [NSString stringWithFormat:@"selected Java %d (%@)", selected, home]
                 : [NSString stringWithFormat:@"no installed runtime is Java %d or newer", need]);
    if (required) *required = need;
    if (javaHome) *javaHome = home;
    if (warning) *warning = disabled;
    return selected;
}

+ (NSString *)checkDependenciesInGameDir:(NSString *)gameDir minecraftVersion:(NSString *)mcVersion loader:(NSString *)loader {
    // shortcut: Forge/NeoForge mods.toml is not parsed, only fabric.mod.json; add a TOML reader if Forge packs need it
    if (![loader isEqualToString:@"fabric"] && ![loader isEqualToString:@"quilt"]) {
        return [NSString stringWithFormat:@"Mod Doctor can only check Fabric and Quilt mods. This profile uses %@.", loader];
    }
    if (mcVersion.length == 0) {
        return @"Mod Doctor needs to know the Minecraft version. Set one in this profile first.";
    }

    NSString *modsDir = [gameDir stringByAppendingPathComponent:@"mods"];
    NSSet *builtIn = [NSSet setWithArray:@[@"minecraft", @"java", @"fabricloader", @"fabric-loader", @"quilt_loader", @"forge", @"neoforge"]];
    NSMutableArray *installed = [NSMutableArray new];
    NSMutableArray *notFound = [NSMutableArray new];
    NSMutableSet *tried = [NSMutableSet new];

    // Newly downloaded mods can have dependencies of their own
    for (int pass = 0; pass < 5; pass++) {
        NSMutableSet *provides = [NSMutableSet new];
        NSMutableDictionary<NSString *, NSMutableSet *> *dependsByMod = [NSMutableDictionary new];
        for (NSString *file in [NSFileManager.defaultManager contentsOfDirectoryAtPath:modsDir error:nil]) {
            NSString *path = [modsDir stringByAppendingPathComponent:file];
            if ([file.pathExtension.lowercaseString isEqualToString:@"jar"]) {
                [self scanJar:path provides:provides depends:dependsByMod];
            } else if ([file.lowercaseString hasSuffix:@".jar.disabled"]) {
                // Mods the player turned off count as present, so we don't reinstall them behind their back
                [self scanJar:path provides:provides depends:[NSMutableDictionary new]];
            }
        }
        [self applyDependencyOverridesIn:gameDir to:dependsByMod];
        NSMutableSet *depends = [NSMutableSet new];
        for (NSSet *modDepends in dependsByMod.allValues) [depends unionSet:modDepends];
        [depends minusSet:provides];
        [depends minusSet:builtIn];
        [depends minusSet:tried];
        if (depends.count == 0) break;

        for (NSString *modId in depends) {
            [tried addObject:modId];
            NSString *saved = [self download:[self fileURLForModId:modId minecraftVersion:mcVersion loader:loader] toDirectory:modsDir];
            if (saved) {
                [installed addObject:[NSString stringWithFormat:@"%@ (%@)", modId, saved]];
            } else {
                [notFound addObject:modId];
            }
        }
    }

    if (installed.count == 0 && notFound.count == 0) {
        return @"No missing mods. Every dependency is installed.";
    }
    NSMutableString *report = [NSMutableString new];
    if (installed.count) {
        [report appendFormat:@"Downloaded %lu missing mod(s):\n%@", (unsigned long)installed.count, [installed componentsJoinedByString:@"\n"]];
    }
    if (notFound.count) {
        [report appendFormat:@"%@Couldn't find these on Modrinth for Minecraft %@, so add them yourself:\n%@",
            report.length ? @"\n\n" : @"", mcVersion, [notFound componentsJoinedByString:@"\n"]];
    }
    return report;
}

@end
