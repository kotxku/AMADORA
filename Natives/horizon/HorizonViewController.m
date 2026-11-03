#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "horizon/HorizonGame.h"
#import "horizon/HorizonSetup.h"
#import "LauncherNavigationController.h"
#import "horizon/HorizonViewController.h"
#import "InstanceViewController.h"
#import "PLProfiles.h"
#import "PLTheme.h"
#import "ios_uikit_bridge.h"
#import "utils.h"

typedef NS_ENUM(NSInteger, HorizonSection) {
    kHorizonStatus,
    kHorizonFiles,
    kHorizonInstances
};

@interface HorizonViewController () <UIDocumentPickerDelegate>
@property(nonatomic, copy) NSString *importStatus;
@property(nonatomic) NSArray<NSString *> *instances;
@end

@implementation HorizonViewController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleGrouped];
    self.title = @"Horizon";
    return self;
}

- (NSString *)imageName {
    return @"bolt.horizontal";
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = PLTheme.background;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reload];
}

- (void)reload {
    [PLProfiles updateCurrent];
    self.instances = HorizonGame.instanceNames;
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 3;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @[@"Horizon: Minecraft 26.3 in Rust", @"Game files", @"Horizon instances"][section];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    switch (section) {
        case kHorizonStatus:
            return @"Horizon (playhorizon.dev) is a rewrite of Minecraft: Java Edition 26.3 in Rust, not made by Mojang. It runs natively, without Java, so Java mods don't run in it. Online-mode servers use your selected Microsoft account.";
        case kHorizonFiles:
            return @"Horizon needs files made from Minecraft 26.3, shared by every Horizon instance. Set up on this device downloads 26.3 from Mojang (about 700 MB) and builds them here with JIT on; AMADORA closes when it's done. Or, on a computer with the Horizon launcher, run export-horizon.ps1 and import its horizon-26.3.zip.";
        default:
            return @"A Horizon instance works like any other: select it and press Play, and add resource packs and shaders on its page from Modrinth, CurseForge or a file. You can also make one from Instances > + > Horizon.";
    }
}

- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
    UITableViewHeaderFooterView *header = (UITableViewHeaderFooterView *)view;
    header.textLabel.font = [PLTheme fontOfSize:17];
    header.textLabel.textColor = PLTheme.foreground;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case kHorizonStatus: return 2;
        case kHorizonFiles: return 2;
        default: return self.instances.count + 1;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.backgroundColor = PLTheme.surface;
    cell.textLabel.font = [PLTheme fontOfSize:16];
    cell.textLabel.textColor = PLTheme.foreground;
    cell.detailTextLabel.textColor = PLTheme.muted;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    if (indexPath.section == kHorizonStatus) {
        cell.textLabel.text = indexPath.row == 0 ? @"Engine" : @"Game files";
        cell.detailTextLabel.text = indexPath.row == 0
            ? (HorizonGame.engineAvailable ? @"Included" : @"Not in this build")
            : (HorizonGame.resourcesReady ? @"Ready" : @"Not imported");
    } else if (indexPath.section == kHorizonFiles) {
        BOOL setUp = indexPath.row == 0;
        NSString *title = setUp ? @"Set up on this device"
            : (HorizonGame.resourcesReady ? @"Replace from a zip (from a PC)…" : @"Import from a zip (from a PC)…");
        cell.textLabel.text = setUp ? (self.importStatus ?: title) : title;
        cell.textLabel.numberOfLines = 0;
        cell.textLabel.textColor = self.importStatus ? PLTheme.muted : PLTheme.accent;
        cell.imageView.image = [UIImage systemImageNamed:setUp ? @"arrow.down.circle" : @"square.and.arrow.down"];
        cell.imageView.tintColor = cell.textLabel.textColor;
        cell.selectionStyle = self.importStatus ? UITableViewCellSelectionStyleNone : UITableViewCellSelectionStyleDefault;
    } else if (indexPath.row < self.instances.count) {
        cell.textLabel.text = self.instances[indexPath.row];
        cell.imageView.image = [UIImage systemImageNamed:@"bolt.horizontal"];
        cell.imageView.tintColor = PLTheme.muted;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    } else {
        cell.textLabel.text = @"New Horizon instance…";
        cell.textLabel.textColor = PLTheme.accent;
        cell.imageView.image = [UIImage systemImageNamed:@"plus"];
        cell.imageView.tintColor = PLTheme.accent;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == kHorizonFiles && !self.importStatus && indexPath.row == 0) {
        [self confirmSetUp];
    } else if (indexPath.section == kHorizonFiles && !self.importStatus) {
        UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeZIP] asCopy:YES];
        picker.delegate = self;
        [self presentViewController:picker animated:YES completion:nil];
    } else if (indexPath.section == kHorizonInstances) {
        if (indexPath.row < self.instances.count) {
            [self openInstance:self.instances[indexPath.row]];
        } else {
            [HorizonViewController promptNewInstanceFrom:self then:^(NSString *name) {
                [self reload];
                [self openInstance:name];
            }];
        }
    }
}

- (void)confirmSetUp {
    if (!HorizonSetup.available) {
        showDialog(@"Can't set up here", @"This build of AMADORA doesn't carry Horizon's setup files. Import from a zip instead.");
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Set up Horizon on this device"
        message:@"AMADORA downloads Minecraft 26.3 from Mojang (about 700 MB on Wi-Fi), then builds Horizon's files with Horizon's own preparer in Java, which needs JIT and several minutes. AMADORA closes when it's done: open it again and press Play."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Set up" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self setUp];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)setUp {
    self.importStatus = @"Starting…";
    [self reload];
    // Keeps downloading with the screen locked, for a while
    __block UIBackgroundTaskIdentifier background = [UIApplication.sharedApplication beginBackgroundTaskWithExpirationHandler:^{
        [UIApplication.sharedApplication endBackgroundTask:background];
    }];
    UIApplication.sharedApplication.idleTimerDisabled = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *error = [HorizonSetup downloadWithProgress:^(NSString *status) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.importStatus = status;
                [self.tableView reloadData];
            });
        }];
        NSString *jar = error ? nil : [HorizonSetup prepareLaunchJar:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            [UIApplication.sharedApplication endBackgroundTask:background];
            UIApplication.sharedApplication.idleTimerDisabled = NO;
            self.importStatus = nil;
            [self reload];
            if (error) {
                showDialog(@"Couldn't set up Horizon", error);
                return;
            }
            // Packs and saves go to an instance: there is one when the game first opens
            [HorizonGame defaultInstanceName];
            [(LauncherNavigationController *)self.navigationController enterModInstallerWithPath:jar hitEnterAfterWindowShown:NO];
        });
    });
}

// Selects the instance, so the toolbar's Play starts it, and shows its page
- (void)openInstance:(NSString *)name {
    PLProfiles.current.selectedProfileName = name;
    [self.navigationController performSelector:@selector(reloadProfileList)];
    [self.navigationController pushViewController:[[InstanceViewController alloc] initWithProfileName:name] animated:YES];
}

+ (void)promptNewInstanceFrom:(UIViewController *)presenter then:(void (^)(NSString *name))created {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"New Horizon instance"
        message:@"Minecraft 26.3 in Rust, with its own saves and packs." preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"Name";
        field.text = HorizonGame.instanceNames.count ? @"" : @"Horizon";
        field.autocapitalizationType = UITextAutocapitalizationTypeWords;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Create" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *name = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSString *error = [HorizonGame createInstanceNamed:name];
        if (error) {
            showDialog(@"Couldn't make the instance", error);
        } else if (created) {
            created(name);
        }
    }]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSString *path = urls.firstObject.path;
    if (!path) return;
    // Packs in the zip go to the first Horizon instance, made now when there is none
    NSString *instance = HorizonGame.defaultInstanceName;
    NSString *packsGameDir = [PLProfiles gameDirForProfile:PLProfiles.current.profiles[instance]];
    self.importStatus = @"Importing…";
    [self reload];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *error = [HorizonGame importResourcesZip:path packsGameDir:packsGameDir progress:^(NSString *status) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.importStatus = status;
                [self.tableView reloadData];
            });
        }];
        [NSFileManager.defaultManager removeItemAtPath:path error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.importStatus = nil;
            [self reload];
            if (error) {
                showDialog(@"Couldn't import the game files", error);
            } else {
                showDialog(@"Horizon is ready", [NSString stringWithFormat:@"The 26.3 game files are imported, with any packs from the zip in the instance %@. Select it and press Play.", instance]);
            }
        });
    });
}

@end
