#import "ContentInstaller.h"
#import "ModDoctor.h"

static NSString *const kModrinth = @"https://api.modrinth.com/v2";
static NSString *const kCurseForge = @"https://api.curseforge.com/v1";
static NSString *const kIndexName = @".amadora_content.json";
static NSString *const kCurseForgeKeyDefault = @"AMADORA.curseforge_api_key";

static id typed(id obj, Class cls) {
    return [obj isKindOfClass:cls] ? obj : nil;
}

@implementation ContentInstaller

+ (NSString *)curseForgeAPIKey {
    return [NSUserDefaults.standardUserDefaults stringForKey:kCurseForgeKeyDefault];
}

+ (void)setCurseForgeAPIKey:(NSString *)key {
    key = [key stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    [NSUserDefaults.standardUserDefaults setObject:key.length ? key : nil forKey:kCurseForgeKeyDefault];
}

+ (NSString *)folderForType:(PLContentType)type {
    switch (type) {
        case PLContentTypeMod: return @"mods";
        case PLContentTypeResourcePack: return @"resourcepacks";
        case PLContentTypeShader: return @"shaderpacks";
        case PLContentTypeModpack: return nil;
    }
}

#pragma mark Networking

+ (id)getJSON:(NSString *)url query:(NSArray<NSURLQueryItem *> *)query source:(PLContentSource)source error:(NSString **)error {
    NSURLComponents *components = [NSURLComponents componentsWithString:url];
    components.queryItems = query.count ? query : nil;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:components.URL];
    [request setValue:@"kotxku/AMADORA" forHTTPHeaderField:@"User-Agent"];
    if (source == PLContentSourceCurseForge) {
        [request setValue:self.curseForgeAPIKey forHTTPHeaderField:@"x-api-key"];
    }
    __block id result;
    __block NSString *failure;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *err) {
        NSInteger status = [(NSHTTPURLResponse *)response statusCode];
        if (err) {
            failure = err.localizedDescription;
        } else if (status == 401 || status == 403) {
            failure = source == PLContentSourceCurseForge ? @"CurseForge rejected the API key. Check it in the CurseForge tab." : @"Access denied.";
        } else if (status != 200) {
            failure = [NSString stringWithFormat:@"The server answered %ld.", (long)status];
        } else {
            result = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (!result) failure = @"The server sent something that isn't JSON.";
        }
        dispatch_semaphore_signal(done);
    }] resume];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    if (error) *error = failure;
    return result;
}

static NSString *jsonArray(NSArray *values) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:values options:0 error:nil];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

// Quilt loads Fabric mods, so Quilt instances also accept Fabric builds (as Pandora does)
static NSArray<NSString *> *modrinthLoaders(NSString *loader) {
    if ([loader isEqualToString:@"quilt"]) return @[@"quilt", @"fabric"];
    if (loader.length && ![loader isEqualToString:@"vanilla"]) return @[loader];
    return nil;
}

static NSNumber *curseForgeLoader(NSString *loader) {
    NSDictionary *ids = @{@"forge": @1, @"fabric": @4, @"quilt": @5, @"neoforge": @6};
    return ids[loader];
}

static NSNumber *curseForgeClass(PLContentType type) {
    switch (type) {
        case PLContentTypeMod: return @6;
        case PLContentTypeModpack: return @4471;
        case PLContentTypeResourcePack: return @12;
        case PLContentTypeShader: return @6552;
    }
}

#pragma mark Search

+ (NSArray<NSDictionary *> *)search:(NSString *)query source:(PLContentSource)source type:(PLContentType)type
    mcVersion:(NSString *)mcVersion loader:(NSString *)loader offset:(NSUInteger)offset error:(NSString **)error {
    if (source == PLContentSourceCurseForge) {
        return [self searchCurseForge:query type:type mcVersion:mcVersion loader:loader offset:offset error:error];
    }
    NSArray *projectTypes = @[@"mod", @"modpack", @"resourcepack", @"shader"];
    NSMutableArray *facets = [NSMutableArray arrayWithObject:@[[@"project_type:" stringByAppendingString:projectTypes[type]]]];
    if (mcVersion.length) [facets addObject:@[[@"versions:" stringByAppendingString:mcVersion]]];
    if (type == PLContentTypeMod) {
        NSMutableArray *categories = [NSMutableArray new];
        for (NSString *name in modrinthLoaders(loader)) [categories addObject:[@"categories:" stringByAppendingString:name]];
        if (categories.count) [facets addObject:categories];
    }
    NSDictionary *response = typed([self getJSON:[kModrinth stringByAppendingString:@"/search"] query:@[
        [NSURLQueryItem queryItemWithName:@"query" value:query ?: @""],
        [NSURLQueryItem queryItemWithName:@"facets" value:jsonArray(facets)],
        [NSURLQueryItem queryItemWithName:@"index" value:query.length ? @"relevance" : @"downloads"],
        [NSURLQueryItem queryItemWithName:@"limit" value:@"20"],
        [NSURLQueryItem queryItemWithName:@"offset" value:@(offset).stringValue]
    ] source:source error:error], NSDictionary.class);
    NSMutableArray *results = [NSMutableArray new];
    for (NSDictionary *hit in typed(response[@"hits"], NSArray.class)) {
        if (!typed(hit, NSDictionary.class) || !typed(hit[@"project_id"], NSString.class)) continue;
        NSString *slug = typed(hit[@"slug"], NSString.class) ?: hit[@"project_id"];
        [results addObject:@{
            @"id": hit[@"project_id"],
            @"slug": slug,
            @"title": typed(hit[@"title"], NSString.class) ?: slug,
            @"author": typed(hit[@"author"], NSString.class) ?: @"",
            @"summary": typed(hit[@"description"], NSString.class) ?: @"",
            @"iconUrl": typed(hit[@"icon_url"], NSString.class) ?: @"",
            @"downloads": typed(hit[@"downloads"], NSNumber.class) ?: @0,
            @"pageUrl": [NSString stringWithFormat:@"https://modrinth.com/%@/%@", projectTypes[type], slug],
            @"tags": typed(hit[@"display_categories"], NSArray.class) ?: @[]
        }];
    }
    return response ? results : nil;
}

+ (NSArray<NSDictionary *> *)searchCurseForge:(NSString *)query type:(PLContentType)type
    mcVersion:(NSString *)mcVersion loader:(NSString *)loader offset:(NSUInteger)offset error:(NSString **)error {
    if (!self.curseForgeAPIKey.length) {
        if (error) *error = @"Add your CurseForge API key first.";
        return nil;
    }
    NSMutableArray *items = [NSMutableArray arrayWithArray:@[
        [NSURLQueryItem queryItemWithName:@"gameId" value:@"432"],
        [NSURLQueryItem queryItemWithName:@"classId" value:curseForgeClass(type).stringValue],
        [NSURLQueryItem queryItemWithName:@"searchFilter" value:query ?: @""],
        [NSURLQueryItem queryItemWithName:@"sortField" value:@"2"], // popularity
        [NSURLQueryItem queryItemWithName:@"sortOrder" value:@"desc"],
        [NSURLQueryItem queryItemWithName:@"index" value:@(offset).stringValue],
        [NSURLQueryItem queryItemWithName:@"pageSize" value:@"20"]
    ]];
    if (mcVersion.length) [items addObject:[NSURLQueryItem queryItemWithName:@"gameVersion" value:mcVersion]];
    if (type == PLContentTypeMod && curseForgeLoader(loader)) {
        [items addObject:[NSURLQueryItem queryItemWithName:@"modLoaderType" value:curseForgeLoader(loader).stringValue]];
    }
    NSDictionary *response = typed([self getJSON:[kCurseForge stringByAppendingString:@"/mods/search"] query:items source:PLContentSourceCurseForge error:error], NSDictionary.class);
    NSMutableArray *results = [NSMutableArray new];
    for (NSDictionary *mod in typed(response[@"data"], NSArray.class)) {
        if (!typed(mod, NSDictionary.class) || !typed(mod[@"id"], NSNumber.class)) continue;
        NSMutableArray *tags = [NSMutableArray new];
        for (NSDictionary *category in typed(mod[@"categories"], NSArray.class)) {
            NSString *name = typed(typed(category, NSDictionary.class)[@"name"], NSString.class);
            if (name) [tags addObject:name];
        }
        NSDictionary *author = typed([typed(mod[@"authors"], NSArray.class) firstObject], NSDictionary.class);
        [results addObject:@{
            @"id": [mod[@"id"] stringValue],
            @"slug": typed(mod[@"slug"], NSString.class) ?: @"",
            @"title": typed(mod[@"name"], NSString.class) ?: @"",
            @"author": typed(author[@"name"], NSString.class) ?: @"",
            @"summary": typed(mod[@"summary"], NSString.class) ?: @"",
            @"iconUrl": typed(typed(mod[@"logo"], NSDictionary.class)[@"thumbnailUrl"], NSString.class) ?: @"",
            @"downloads": typed(mod[@"downloadCount"], NSNumber.class) ?: @0,
            @"pageUrl": typed(typed(mod[@"links"], NSDictionary.class)[@"websiteUrl"], NSString.class) ?: @"https://www.curseforge.com/minecraft",
            @"tags": tags
        }];
    }
    return response ? results : nil;
}

#pragma mark Install index

+ (NSString *)indexPathInGameDir:(NSString *)gameDir {
    return [gameDir stringByAppendingPathComponent:kIndexName];
}

+ (NSDictionary<NSString *, NSDictionary *> *)installedContentInGameDir:(NSString *)gameDir {
    NSData *data = [NSData dataWithContentsOfFile:[self indexPathInGameDir:gameDir]];
    return typed(data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil, NSDictionary.class) ?: @{};
}

+ (void)saveIndex:(NSDictionary *)index inGameDir:(NSString *)gameDir {
    NSData *data = [NSJSONSerialization dataWithJSONObject:index options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToFile:[self indexPathInGameDir:gameDir] atomically:YES];
}

+ (void)forgetFile:(NSString *)fileName inGameDir:(NSString *)gameDir {
    NSMutableDictionary *index = [self installedContentInGameDir:gameDir].mutableCopy;
    [index removeObjectForKey:[fileName stringByReplacingOccurrencesOfString:@".disabled" withString:@""]];
    [self saveIndex:index inGameDir:gameDir];
}

// A project counts as installed when the index has it and its file (or the .disabled copy) is still there
+ (BOOL)hasProject:(NSString *)projectId inGameDir:(NSString *)gameDir {
    NSDictionary *index = [self installedContentInGameDir:gameDir];
    for (NSString *file in index) {
        NSDictionary *entry = index[file];
        if (![entry[@"projectId"] isEqual:projectId]) continue;
        NSString *path = [[gameDir stringByAppendingPathComponent:entry[@"folder"] ?: @"mods"] stringByAppendingPathComponent:file];
        NSFileManager *fm = NSFileManager.defaultManager;
        if ([fm fileExistsAtPath:path] || [fm fileExistsAtPath:[path stringByAppendingString:@".disabled"]]) return YES;
    }
    return NO;
}

// File names come from the API: keep only a plain last component
static NSString *safeFileName(NSString *name) {
    name = name.lastPathComponent;
    return name.length && ![name hasPrefix:@"."] ? name : nil;
}

#pragma mark Install

+ (NSString *)install:(NSDictionary *)project source:(PLContentSource)source type:(PLContentType)type
    gameDir:(NSString *)gameDir mcVersion:(NSString *)mcVersion loader:(NSString *)loader progress:(void (^)(NSString *))progress {
    NSString *folder = [self folderForType:type];
    if (!folder) return @"Modpacks are installed as new instances.";
    NSMutableArray<NSString *> *installed = [NSMutableArray new], *problems = [NSMutableArray new];
    NSMutableSet<NSString *> *visited = [NSMutableSet new];
    [self installProject:project[@"id"] title:project[@"title"] iconUrl:project[@"iconUrl"] source:source folder:folder
        dependencies:type == PLContentTypeMod gameDir:gameDir mcVersion:mcVersion loader:loader
        visited:visited installed:installed problems:problems progress:progress isDependency:NO];
    NSMutableString *report = [NSMutableString new];
    if (installed.count) [report appendFormat:@"Installed into %@/:\n%@", folder, [installed componentsJoinedByString:@"\n"]];
    if (problems.count) [report appendFormat:@"%@%@", report.length ? @"\n\n" : @"", [problems componentsJoinedByString:@"\n"]];
    return report.length ? report : [NSString stringWithFormat:@"%@ is already installed.", project[@"title"]];
}

+ (void)installProject:(NSString *)projectId title:(NSString *)title iconUrl:(NSString *)iconUrl source:(PLContentSource)source
    folder:(NSString *)folder dependencies:(BOOL)dependencies gameDir:(NSString *)gameDir mcVersion:(NSString *)mcVersion
    loader:(NSString *)loader visited:(NSMutableSet *)visited installed:(NSMutableArray *)installed problems:(NSMutableArray *)problems
    progress:(void (^)(NSString *))progress isDependency:(BOOL)isDependency {
    if (!projectId || [visited containsObject:projectId]) return;
    [visited addObject:projectId];
    if (isDependency && [self hasProject:projectId inGameDir:gameDir]) return;
    if (progress) progress([NSString stringWithFormat:@"Finding a version of %@", title ?: projectId]);

    NSString *error;
    // Only mods are tied to a loader; resource packs and shaders match on the Minecraft version alone
    NSString *fileLoader = [folder isEqualToString:@"mods"] ? loader : nil;
    NSDictionary *file = source == PLContentSourceModrinth
        ? [self modrinthFileForProject:projectId mcVersion:mcVersion loader:fileLoader error:&error]
        : [self curseForgeFileForProject:projectId mcVersion:mcVersion loader:fileLoader error:&error];
    NSString *label = file[@"title"] ?: title ?: projectId;
    if (!file) {
        [problems addObject:[NSString stringWithFormat:@"%@: %@", label, error ?: [NSString stringWithFormat:@"no version for Minecraft %@%@", mcVersion.length ? mcVersion : @"(unknown)", loader.length ? [@" " stringByAppendingString:loader] : @""]]];
        return;
    }
    NSString *name = safeFileName(file[@"fileName"]);
    if (!file[@"url"] || !name) {
        // CurseForge authors can opt out of third-party downloads; Pandora sends you to the page for those too
        [problems addObject:[NSString stringWithFormat:@"%@: the author only allows downloads from the CurseForge website. Download it there and use Add from file.", label]];
        return;
    }

    if (progress) progress([NSString stringWithFormat:@"Downloading %@", name]);
    NSString *path = [[gameDir stringByAppendingPathComponent:folder] stringByAppendingPathComponent:name];
    if (![ModDoctor download:file[@"url"] toFile:path sha1:file[@"sha1"]]) {
        [problems addObject:[NSString stringWithFormat:@"%@: download failed or didn't match its checksum.", label]];
        return;
    }
    // A .disabled copy of the same file would load nothing but confuse the Mods list
    [NSFileManager.defaultManager removeItemAtPath:[path stringByAppendingString:@".disabled"] error:nil];
    NSMutableDictionary *index = [self installedContentInGameDir:gameDir].mutableCopy;
    index[name] = @{
        @"title": title ?: label,
        @"version": file[@"version"] ?: @"",
        @"iconUrl": iconUrl ?: file[@"iconUrl"] ?: @"",
        @"source": source == PLContentSourceModrinth ? @"modrinth" : @"curseforge",
        @"projectId": projectId,
        @"folder": folder
    };
    [self saveIndex:index inGameDir:gameDir];
    [installed addObject:isDependency ? [NSString stringWithFormat:@"%@ (required by another mod)", name] : name];

    if (!dependencies) return;
    for (NSString *dependency in file[@"dependencies"]) {
        [self installProject:dependency title:nil iconUrl:nil source:source folder:folder dependencies:YES gameDir:gameDir
            mcVersion:mcVersion loader:loader visited:visited installed:installed problems:problems progress:progress isDependency:YES];
    }
}

// The newest version for this Minecraft version and loader, preferring releases over betas.
// Returns url, fileName, sha1, version, title, iconUrl and dependencies (required project ids).
+ (NSDictionary *)modrinthFileForProject:(NSString *)projectId mcVersion:(NSString *)mcVersion loader:(NSString *)loader error:(NSString **)error {
    NSMutableArray *query = [NSMutableArray new];
    if (mcVersion.length) [query addObject:[NSURLQueryItem queryItemWithName:@"game_versions" value:jsonArray(@[mcVersion])]];
    if (modrinthLoaders(loader)) [query addObject:[NSURLQueryItem queryItemWithName:@"loaders" value:jsonArray(modrinthLoaders(loader))]];
    NSString *encoded = [projectId stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
    NSArray *versions = typed([self getJSON:[NSString stringWithFormat:@"%@/project/%@/version", kModrinth, encoded] query:query source:PLContentSourceModrinth error:error], NSArray.class);
    NSDictionary *chosen;
    for (NSDictionary *version in versions) {
        if (!typed(version, NSDictionary.class)) continue;
        if (!chosen) chosen = version;
        if ([version[@"version_type"] isEqual:@"release"]) { chosen = version; break; }
    }
    if (!chosen) return nil;
    NSArray *files = typed(chosen[@"files"], NSArray.class);
    NSDictionary *file = files.firstObject;
    for (NSDictionary *candidate in files) {
        if ([typed(candidate, NSDictionary.class)[@"primary"] boolValue]) { file = candidate; break; }
    }
    NSMutableArray *dependencies = [NSMutableArray new];
    for (NSDictionary *dependency in typed(chosen[@"dependencies"], NSArray.class)) {
        if ([typed(dependency, NSDictionary.class)[@"dependency_type"] isEqual:@"required"] && typed(dependency[@"project_id"], NSString.class)) {
            [dependencies addObject:dependency[@"project_id"]];
        }
    }
    NSMutableDictionary *result = [NSMutableDictionary new];
    result[@"url"] = typed(file[@"url"], NSString.class);
    result[@"fileName"] = typed(file[@"filename"], NSString.class);
    result[@"sha1"] = typed(typed(file[@"hashes"], NSDictionary.class)[@"sha1"], NSString.class);
    result[@"version"] = typed(chosen[@"version_number"], NSString.class);
    result[@"dependencies"] = dependencies;
    // Dependencies arrive as bare ids: look up the name and icon for the Mods list
    NSDictionary *info = typed([self getJSON:[NSString stringWithFormat:@"%@/project/%@", kModrinth, encoded] query:nil source:PLContentSourceModrinth error:nil], NSDictionary.class);
    result[@"title"] = typed(info[@"title"], NSString.class);
    result[@"iconUrl"] = typed(info[@"icon_url"], NSString.class);
    return result;
}

+ (NSDictionary *)curseForgeFileForProject:(NSString *)projectId mcVersion:(NSString *)mcVersion loader:(NSString *)loader error:(NSString **)error {
    NSMutableArray *query = [NSMutableArray arrayWithObject:[NSURLQueryItem queryItemWithName:@"pageSize" value:@"50"]];
    if (mcVersion.length) [query addObject:[NSURLQueryItem queryItemWithName:@"gameVersion" value:mcVersion]];
    if (curseForgeLoader(loader)) [query addObject:[NSURLQueryItem queryItemWithName:@"modLoaderType" value:curseForgeLoader(loader).stringValue]];
    NSDictionary *response = typed([self getJSON:[NSString stringWithFormat:@"%@/mods/%@/files", kCurseForge, projectId] query:query source:PLContentSourceCurseForge error:error], NSDictionary.class);
    NSDictionary *chosen;
    for (NSDictionary *file in typed(response[@"data"], NSArray.class)) {
        if (!typed(file, NSDictionary.class)) continue;
        if (!chosen) chosen = file;
        if ([file[@"releaseType"] intValue] == 1) { chosen = file; break; }
    }
    if (!chosen) return nil;
    NSMutableDictionary *result = [NSMutableDictionary new];
    result[@"url"] = typed(chosen[@"downloadUrl"], NSString.class);
    result[@"fileName"] = typed(chosen[@"fileName"], NSString.class);
    result[@"version"] = typed(chosen[@"displayName"], NSString.class);
    for (NSDictionary *hash in typed(chosen[@"hashes"], NSArray.class)) {
        if ([typed(hash, NSDictionary.class)[@"algo"] intValue] == 1) result[@"sha1"] = typed(hash[@"value"], NSString.class);
    }
    NSMutableArray *dependencies = [NSMutableArray new];
    for (NSDictionary *dependency in typed(chosen[@"dependencies"], NSArray.class)) {
        if ([typed(dependency, NSDictionary.class)[@"relationType"] intValue] == 3 && typed(dependency[@"modId"], NSNumber.class)) {
            [dependencies addObject:[dependency[@"modId"] stringValue]];
        }
    }
    result[@"dependencies"] = dependencies;
    NSDictionary *mod = typed(typed([self getJSON:[NSString stringWithFormat:@"%@/mods/%@", kCurseForge, projectId] query:nil source:PLContentSourceCurseForge error:nil], NSDictionary.class)[@"data"], NSDictionary.class);
    result[@"title"] = typed(mod[@"name"], NSString.class);
    result[@"iconUrl"] = typed(typed(mod[@"logo"], NSDictionary.class)[@"thumbnailUrl"], NSString.class);
    return result;
}

@end
