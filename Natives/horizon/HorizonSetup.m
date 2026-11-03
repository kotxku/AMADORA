#include <dlfcn.h>
#include "jni.h"
#import "horizon/HorizonGame.h"
#import "horizon/HorizonSetup.h"
#import "UnzipKit.h"

static NSString *bundledRoot(void) {
    return [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"horizon-prepare"];
}

static NSString *rootPath(void) {
    return [HorizonGame.homePath stringByAppendingPathComponent:@"prepare"];
}

static NSString *gameDir(void) {
    return @(getenv("GAME_DIR"));
}

// The pinned version, and its version JSON's SHA-1, from the shipped research-lock.json
static NSDictionary *pins(void) {
    NSData *data = [NSData dataWithContentsOfFile:[bundledRoot() stringByAppendingPathComponent:@"research-lock.json"]];
    NSDictionary *lock = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [lock isKindOfClass:NSDictionary.class] ? lock[@"minecraft"] : nil;
}

static NSString *versionJsonPath(NSString *version) {
    return [HorizonGame.homePath stringByAppendingFormat:@"/%@.json", version];
}

static NSString *serverJarPath(NSString *version) {
    return [HorizonGame.homePath stringByAppendingFormat:@"/server-%@.jar", version];
}

static NSString *clientJarPath(NSString *version) {
    return [gameDir() stringByAppendingFormat:@"/versions/%1$@/%1$@.jar", version];
}

// Downloads url to path unless a file of that size is there. Returns nil, or the error.
static NSString *download(NSURLSession *session, NSString *url, NSString *path, long long size) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSNumber *existing = [fm attributesOfItemAtPath:path error:nil][NSFileSize];
    if (existing && (size <= 0 || existing.longLongValue == size)) return nil;
    __block NSString *error;
    for (int attempt = 0; attempt < 3; attempt++) {
        error = nil;
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        [[session downloadTaskWithURL:[NSURL URLWithString:url] completionHandler:^(NSURL *location, NSURLResponse *response, NSError *failure) {
            NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
            if (failure || status != 200) {
                error = [NSString stringWithFormat:@"%@: %@", url.lastPathComponent, failure.localizedDescription ?: [NSString stringWithFormat:@"HTTP %ld", (long)status]];
            } else {
                NSError *moveError;
                [fm createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
                [fm removeItemAtPath:path error:nil];
                if (![fm moveItemAtURL:location toURL:[NSURL fileURLWithPath:path] error:&moveError]) {
                    error = moveError.localizedDescription;
                }
            }
            dispatch_semaphore_signal(done);
        }] resume];
        dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
        if (!error) break;
    }
    return error;
}

@implementation HorizonSetup

+ (BOOL)available {
    return HorizonGame.engineAvailable && pins() != nil;
}

+ (NSString *)downloadWithProgress:(void (^)(NSString *))progress {
    NSDictionary *pin = pins();
    NSString *version = pin[@"version"], *manifestSha1 = pin[@"manifest_sha1"];
    if (!version || !manifestSha1) return @"This build doesn't carry Horizon's setup files.";
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.defaultSessionConfiguration;
    config.HTTPMaximumConnectionsPerHost = 16;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];

    // The version JSON Horizon is pinned to (Mojang republishes others), kept beside Horizon's files
    progress(@"Downloading Minecraft 26.3's file list…");
    NSString *jsonPath = versionJsonPath(version);
    [NSFileManager.defaultManager removeItemAtPath:jsonPath error:nil];
    NSString *error = download(session, [NSString stringWithFormat:@"https://piston-meta.mojang.com/v1/packages/%@/%@.json", manifestSha1, version], jsonPath, 0);
    if (error) return error;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:jsonPath] options:0 error:nil];
    if (![json isKindOfClass:NSDictionary.class]) return @"Mojang's version file couldn't be read.";

    // url, path, size: the client and server jars, every library jar (each OS's natives too: the
    // preparer picks), the asset index and then its objects
    NSMutableArray<NSArray *> *files = [NSMutableArray new];
    NSDictionary *client = json[@"downloads"][@"client"], *server = json[@"downloads"][@"server"];
    [files addObject:@[client[@"url"], clientJarPath(version), client[@"size"]]];
    [files addObject:@[server[@"url"], serverJarPath(version), server[@"size"]]];
    for (NSDictionary *library in json[@"libraries"]) {
        NSDictionary *artifact = library[@"downloads"][@"artifact"];
        if (!artifact[@"url"] || !artifact[@"path"] || [artifact[@"path"] containsString:@".."]) continue;
        [files addObject:@[artifact[@"url"], [gameDir() stringByAppendingFormat:@"/libraries/%@", artifact[@"path"]], artifact[@"size"] ?: @0]];
    }
    NSDictionary *index = json[@"assetIndex"];
    NSString *indexPath = [gameDir() stringByAppendingFormat:@"/assets/indexes/%@.json", index[@"id"]];
    error = download(session, index[@"url"], indexPath, [index[@"size"] longLongValue]);
    if (error) return error;
    NSDictionary *objects = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:indexPath] options:0 error:nil][@"objects"];
    for (NSDictionary *object in objects.allValues) {
        NSString *hash = object[@"hash"];
        if (hash.length < 2) continue;
        NSString *relative = [NSString stringWithFormat:@"%@/%@", [hash substringToIndex:2], hash];
        [files addObject:@[[@"https://resources.download.minecraft.net/" stringByAppendingString:relative],
            [gameDir() stringByAppendingFormat:@"/assets/objects/%@", relative], object[@"size"] ?: @0]];
    }

    __block NSString *failure;
    __block NSUInteger done = 0;
    NSUInteger total = files.count;
    dispatch_semaphore_t slots = dispatch_semaphore_create(16);
    dispatch_group_t group = dispatch_group_create();
    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    for (NSArray *file in files) {
        dispatch_semaphore_wait(slots, DISPATCH_TIME_FOREVER);
        BOOL failed;
        @synchronized (files) {
            failed = failure != nil;
        }
        if (failed) {
            dispatch_semaphore_signal(slots);
            break;
        }
        dispatch_group_async(group, queue, ^{
            NSString *fileError = download(session, file[0], file[1], [file[2] longLongValue]);
            @synchronized (files) {
                if (fileError && !failure) failure = fileError;
                if (++done % 50 == 0 || done == total) {
                    progress([NSString stringWithFormat:@"Downloading Minecraft 26.3: %lu of %lu files", (unsigned long)done, (unsigned long)total]);
                }
            }
            dispatch_semaphore_signal(slots);
        });
    }
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    [session finishTasksAndInvalidate];
    return failure;
}

+ (NSString *)prepareLaunchJar:(NSString **)error {
    NSFileManager *fm = NSFileManager.defaultManager;
    // The shipped files are replaced each time; .local (the imports and the exporters' scratch) stays
    NSString *root = rootPath();
    [fm createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
    for (NSString *item in [fm contentsOfDirectoryAtPath:bundledRoot() error:nil]) {
        NSString *target = [root stringByAppendingPathComponent:item];
        [fm removeItemAtPath:target error:nil];
        NSError *copyError;
        if ([item isEqualToString:@"exporters.zip"]) {
            // Shipped zipped (build_prepare_root.sh): loose .class files break on-device signers
            [fm removeItemAtPath:[root stringByAppendingPathComponent:@"exporters"] error:nil];
            UZKArchive *exporters = [[UZKArchive alloc] initWithPath:[bundledRoot() stringByAppendingPathComponent:item] error:&copyError];
            if (!exporters || ![exporters extractFilesTo:root overwrite:YES error:&copyError]) {
                *error = copyError.localizedDescription ?: @"Couldn't unpack Horizon's setup files.";
                return nil;
            }
            continue;
        }
        if (![fm copyItemAtPath:[bundledRoot() stringByAppendingPathComponent:item] toPath:target error:&copyError]) {
            *error = copyError.localizedDescription;
            return nil;
        }
    }
    // The preparer is in the launcher's own classes: this jar only names it and the Java it needs
    NSString *jar = [HorizonGame.homePath stringByAppendingPathComponent:@"horizon-prepare.jar"];
    [fm removeItemAtPath:jar error:nil];
    NSString *manifest = @"Manifest-Version: 1.0\r\nMain-Class: net.kdt.pojavlaunch.HorizonPrepare\r\nJava-Version: 25\r\n\r\n";
    NSError *zipError;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:jar error:&zipError];
    if (!archive || ![archive writeData:[manifest dataUsingEncoding:NSUTF8StringEncoding] filePath:@"META-INF/MANIFEST.MF" error:&zipError]) {
        *error = zipError.localizedDescription ?: @"Couldn't write the setup's jar.";
        return nil;
    }
    return jar;
}

@end

#pragma mark - In AMADORA's Java (HorizonPrepare.java)

typedef int (*TaskFunc)(int, const char **, char *, size_t);
typedef void (*LogFunc)(const char *, float);
typedef int (*PrepareFunc)(const char *, const char *, const char *, const char *, const char *, const char *, const char *, const char *, TaskFunc, LogFunc);

static JavaVM *prepareVM;
static jclass driver;
static jmethodID driverTask;

// A Java task from the preparer's thread: HorizonPrepare.task(String[])
static int runTask(int argc, const char **argv, char *error, size_t length) {
    JNIEnv *env;
    if ((*prepareVM)->GetEnv(prepareVM, (void **)&env, JNI_VERSION_1_6) != JNI_OK &&
        (*prepareVM)->AttachCurrentThread(prepareVM, (void **)&env, NULL) != JNI_OK) {
        snprintf(error, length, "Couldn't reach Java");
        return 1;
    }
    (*env)->PushLocalFrame(env, argc + 8);
    jobjectArray args = (*env)->NewObjectArray(env, argc, (*env)->FindClass(env, "java/lang/String"), NULL);
    for (int i = 0; i < argc; i++) {
        (*env)->SetObjectArrayElement(env, args, i, (*env)->NewStringUTF(env, argv[i]));
    }
    jstring result = (*env)->CallStaticObjectMethod(env, driver, driverTask, args);
    int status = 0;
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionDescribe(env);
        (*env)->ExceptionClear(env);
        snprintf(error, length, "The Java task threw");
        status = 1;
    } else if (result) {
        const char *text = (*env)->GetStringUTFChars(env, result, NULL);
        if (text && text[0]) {
            snprintf(error, length, "%s", text);
            status = 1;
        }
        if (text) (*env)->ReleaseStringUTFChars(env, result, text);
    }
    (*env)->PopLocalFrame(env, NULL);
    return status;
}

static void logLine(const char *line, float fraction) {
    if (line[0]) {
        fprintf(stderr, "[Horizon] %s\n", line);
    } else if (fraction >= 0) {
        fprintf(stderr, "[Horizon] %d%%\n", (int)(fraction * 100));
    }
}

JNIEXPORT jint JNICALL Java_net_kdt_pojavlaunch_HorizonPrepare_run(JNIEnv *env, jclass clazz) {
    (*env)->GetJavaVM(env, &prepareVM);
    driver = (*env)->NewGlobalRef(env, clazz);
    driverTask = (*env)->GetStaticMethodID(env, clazz, "task", "([Ljava/lang/String;)Ljava/lang/String;");
    void *lib = dlopen([NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:@"libhorizon_ios.dylib"].UTF8String, RTLD_NOW | RTLD_LOCAL);
    PrepareFunc prepare = lib ? (PrepareFunc)dlsym(lib, "horizon_ios_prepare") : NULL;
    if (!prepare || !driverTask) {
        fprintf(stderr, "[Horizon] This build can't prepare Horizon: %s\n", lib ? "no horizon_ios_prepare" : dlerror());
        return 1;
    }
    NSString *version = pins()[@"version"];
    NSString *resources = HorizonGame.resourcesPath;
    [NSFileManager.defaultManager createDirectoryAtPath:resources withIntermediateDirectories:YES attributes:nil error:nil];
    fprintf(stderr, "[Horizon] Preparing Minecraft %s for Horizon in %s\n", version.UTF8String, resources.UTF8String);
    return prepare(rootPath().UTF8String, gameDir().UTF8String, versionJsonPath(version).UTF8String,
        clientJarPath(version).UTF8String, [gameDir() stringByAppendingPathComponent:@"libraries"].UTF8String,
        [gameDir() stringByAppendingPathComponent:@"assets"].UTF8String, serverJarPath(version).UTF8String,
        resources.UTF8String, runTask, logLine);
}
