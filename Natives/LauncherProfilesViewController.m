#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "LauncherMenuViewController.h"
#import "LauncherNavigationController.h"
#import "LauncherPreferences.h"
#import "LauncherPrefGameDirViewController.h"
#import "LauncherPrefManageJREViewController.h"
#import "LauncherProfileEditorViewController.h"
#import "LauncherProfilesViewController.h"
#import "InstanceViewController.h"
//#import "NSFileManager+NRFileManager.h"
#import "PLProfiles.h"
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
#import "UIKit+AFNetworking.h"
#pragma clang diagnostic pop
#import "UIKit+hook.h"
#import "installer/FabricInstallViewController.h"
#import "installer/ForgeInstallViewController.h"
#import "horizon/HorizonViewController.h"
#import "installer/ModDoctor.h"
#import "installer/ModpackInstallViewController.h"
#import "installer/PandoraImport.h"
#import "ios_uikit_bridge.h"
#import "utils.h"

typedef NS_ENUM(NSUInteger, LauncherProfilesTableSection) {
    kInstances,
    kProfiles
};

@interface LauncherProfilesViewController () <UIDocumentPickerDelegate>

@property(nonatomic) UIBarButtonItem *createButtonItem;
@end

@implementation LauncherProfilesViewController

- (id)init {
    self = [super init];
    self.title = @"Instances";
    return self;
}

- (NSString *)imageName {
    return @"MenuProfiles";
}

- (void)viewDidLoad
{
    [super viewDidLoad];

    UIMenu *createMenu = [UIMenu menuWithTitle:localize(@"profile.title.create", nil) image:nil identifier:nil
    options:UIMenuOptionsDisplayInline
    children:@[
        [UIAction
            actionWithTitle:@"Vanilla" image:nil
            identifier:@"vanilla" handler:^(UIAction *action) {
                [self actionEditProfile:@{
                    @"name": @"",
                    @"lastVersionId": @"latest-release"}];
            }],
#if 0 // TODO
        [UIAction
            actionWithTitle:@"OptiFine" image:nil
            identifier:@"optifine" handler:createHandler],
#endif
        [UIAction
            actionWithTitle:@"Fabric/Quilt" image:nil
            identifier:@"fabric_or_quilt" handler:^(UIAction *action) {
                [self actionCreateFabricProfile];
            }],
        [UIAction
            actionWithTitle:@"Forge" image:nil
            identifier:@"forge" handler:^(UIAction *action) {
                [self actionCreateForgeProfile];
            }],
        [UIAction
            actionWithTitle:@"Horizon (26.3 in Rust)" image:nil
            identifier:@"horizon" handler:^(UIAction *action) {
                [HorizonViewController promptNewInstanceFrom:self then:^(NSString *name) {
                    [self.tableView reloadData];
                    [self.navigationController performSelector:@selector(reloadProfileList)];
                }];
            }],
        [UIAction
            actionWithTitle:@"Modpack" image:nil
            identifier:@"modpack" handler:^(UIAction *action) {
                [self actionCreateModpackProfile];
            }]
    ]];
    self.createButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd menu:createMenu];
    if(@available(iOS 19.0, *)) {
        self.createButtonItem.sharesBackground = NO;
    }

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];

    // Put navigation buttons back in place
    self.navigationItem.rightBarButtonItems = @[[sidebarViewController drawAccountButton], self.createButtonItem];

    // Pickup changes made in the profile editor and switching instance
    [PLProfiles updateCurrent];
    [self.tableView reloadData];
    [self.navigationController performSelector:@selector(reloadProfileList)];
}

- (void)actionTogglePrefIsolation:(UISwitch *)sender {
    if (!sender.isOn) {
        setPrefBool(@"internal.isolated", NO);
    }
    toggleIsolatedPref(sender.isOn);
}

- (void)actionCreateFabricProfile {
    FabricInstallViewController *vc = [FabricInstallViewController new];
    [self presentNavigatedViewController:vc];
}

- (void)actionCreateForgeProfile {
    ForgeInstallViewController *vc = [ForgeInstallViewController new];
    [self presentNavigatedViewController:vc];
}

- (void)actionCreateModpackProfile {
    ModpackInstallViewController *vc = [ModpackInstallViewController new];
    [self presentNavigatedViewController:vc];
}

- (void)actionImportCustomModpack {
    // Any file: .mrpack and .forge have no system type, so the extension is checked after picking
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeItem] asCopy:YES];
    picker.delegate = self;
    picker.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSString *path = urls.firstObject.path;
    NSString *extension = path.pathExtension.lowercaseString;
    if ([extension isEqualToString:@"mrpack"]) {
        // Modrinth packs go through the existing modpack downloader and its progress bar
        [NSNotificationCenter.defaultCenter postNotificationName:@"InstallModpack" object:nil userInfo:@{@"localPackage": path}];
        return;
    }
    if (![@[@"zip", @"forge"] containsObject:extension]) {
        showDialog(@"Unsupported file", @"Pick a .zip, .mrpack or .forge modpack or instance.");
        return;
    }
    [self runInBackground:@"Importing modpack" work:^NSString *(void (^status)(NSString *)) {
        NSString *report = [PandoraImport importArchiveAtPath:path progress:status];
        [NSFileManager.defaultManager removeItemAtPath:path error:nil];
        return report;
    }];
}

- (void)actionFixMissingModsForProfile:(NSDictionary *)profile {
    NSDictionary *info = [PandoraImport loaderInfoForVersionId:profile[@"lastVersionId"]];
    NSString *gameDir = [@(getenv("GAME_DIR")) stringByAppendingPathComponent:profile[@"gameDir"] ?: @"."].stringByStandardizingPath;
    [self runInBackground:@"Mod Doctor" work:^NSString *(void (^status)(NSString *)) {
        return [ModDoctor fixMissingModsInGameDir:gameDir minecraftVersion:info[@"mc"] loader:info[@"loader"]];
    }];
}

// Shows a blocking alert while work runs off the main thread, then shows its report.
- (void)runInBackground:(NSString *)title work:(NSString *(^)(void (^status)(NSString *)))work {
    UIAlertController *busy = [UIAlertController alertControllerWithTitle:title
        message:@"Big packs can take a few minutes. Keep the app open." preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:busy animated:YES completion:^{
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSString *report = work(^(NSString *message) {
                dispatch_async(dispatch_get_main_queue(), ^{ busy.message = message; });
            });
            dispatch_async(dispatch_get_main_queue(), ^{
                [busy dismissViewControllerAnimated:YES completion:^{
                    [PLProfiles updateCurrent];
                    [self.tableView reloadData];
                    [self.navigationController performSelector:@selector(reloadProfileList)];
                    showDialog(title, report);
                }];
            });
        });
    }];
}

- (void)actionEditProfile:(NSDictionary *)profile {
    LauncherProfileEditorViewController *vc = [LauncherProfileEditorViewController new];
    vc.profile = profile.mutableCopy;
    [self presentNavigatedViewController:vc];
}

- (void)presentNavigatedViewController:(UIViewController *)vc {
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    //nav.navigationBar.prefersLargeTitles = YES;
    [self presentViewController:nav animated:YES completion:nil];
}

#pragma mark Table view

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case 0: return localize(@"profile.section.instance", nil);
        case 1: return localize(@"profile.section.profiles", nil);
    }
    return nil;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case 0: return 3;
        case 1: return [PLProfiles.current.profiles count];
    }
    return 0;
}

- (void)setupInstanceCell:(UITableViewCell *) cell atRow:(NSInteger)row {
    cell.userInteractionEnabled = !getenv("DEMO_LOCK");
    if (row == 0) {
        cell.imageView.image = [UIImage systemImageNamed:@"folder"];
        cell.textLabel.text = localize(@"preference.title.game_directory", nil);
        cell.detailTextLabel.text = getenv("DEMO_LOCK") ? @".demo" : getPrefObject(@"general.game_directory");
    } else if (row == 2) {
        cell.imageView.image = [UIImage systemImageNamed:@"plus.rectangle.on.folder"];
        cell.textLabel.text = @"Add Custom Modpack";
        cell.detailTextLabel.text = @".zip, .mrpack or .forge. Missing mods are downloaded for you.";
    } else {
        NSString *imageName;
        if (@available(iOS 15.0, *)) {
            imageName = @"folder.badge.gearshape";
        } else {
            imageName = @"folder.badge.gear";
        }
        cell.imageView.image = [UIImage systemImageNamed:imageName];
        cell.textLabel.text = localize(@"profile.title.separate_preference", nil);
        cell.detailTextLabel.text = localize(@"profile.detail.separate_preference", nil);
        UISwitch *view = [UISwitch new];
        [view setOn:getPrefBool(@"internal.isolated") animated:NO];
        [view addTarget:self action:@selector(actionTogglePrefIsolation:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = view;
    }
}

- (void)setupProfileCell:(UITableViewCell *) cell atRow:(NSInteger)row {
    NSMutableDictionary *profile = PLProfiles.current.profiles.allValues[row];

    cell.textLabel.text = profile[@"name"];
    cell.detailTextLabel.text = profile[@"lastVersionId"];
    cell.imageView.layer.magnificationFilter = kCAFilterNearest;

    UIImage *fallbackImage = [[UIImage imageNamed:@"DefaultProfile"] _imageWithSize:CGSizeMake(40, 40)];
    [cell.imageView setImageWithURL:[NSURL URLWithString:profile[@"icon"]] placeholderImage:fallbackImage];
}

- (UITableViewCell *)tableView:(nonnull UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSString *cellID = indexPath.section == kInstances ? @"InstanceCell" : @"ProfileCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellID];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.detailTextLabel.numberOfLines = 0;
        cell.detailTextLabel.lineBreakMode = NSLineBreakByWordWrapping;
        if (indexPath.section == kProfiles) {
            cell.imageView.frame = CGRectMake(0, 0, 40, 40);
            cell.imageView.isSizeFixed = YES;
        }
    } else {
        cell.imageView.image = nil;
        cell.userInteractionEnabled = YES;
        cell.accessoryView = nil;
    }

    if (indexPath.section == kInstances) {
        [self setupInstanceCell:cell atRow:indexPath.row];
    } else {
        [self setupProfileCell:cell atRow:indexPath.row];
    }

    cell.textLabel.enabled = cell.detailTextLabel.enabled = cell.userInteractionEnabled;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:NO];

    if (indexPath.section == kInstances) {
        if (indexPath.row == 0) {
            [self.navigationController pushViewController:[LauncherPrefGameDirViewController new] animated:YES];
        } else if (indexPath.row == 2) {
            [self actionImportCustomModpack];
        }
        return;
    }

    // Pandora opens the instance page; its gear button (and the long-press menu) edits the profile
    NSString *name = PLProfiles.current.profiles.allKeys[indexPath.row];
    [self.navigationController pushViewController:[[InstanceViewController alloc] initWithProfileName:name] animated:YES];
}

#pragma mark Context Menu configuration

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point {
    if (indexPath.section != kProfiles) return nil;
    NSDictionary *profile = PLProfiles.current.profiles.allValues[indexPath.row];
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) {
        return [UIMenu menuWithTitle:@"" children:@[
            [UIAction actionWithTitle:@"Edit" image:[UIImage systemImageNamed:@"gearshape"] identifier:nil handler:^(UIAction *action) {
                [self actionEditProfile:profile];
            }],
            [UIAction actionWithTitle:@"Find & Download Missing Mods" image:[UIImage systemImageNamed:@"stethoscope"] identifier:nil handler:^(UIAction *action) {
                [self actionFixMissingModsForProfile:profile];
            }]
        ]];
    }];
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (editingStyle != UITableViewCellEditingStyleDelete) return;

    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
    NSString *title = localize(@"preference.title.confirm", nil);
    // reusing the delete runtime message
    NSString *message = [NSString stringWithFormat:localize(@"preference.title.confirm.delete_runtime", nil), cell.textLabel.text];
    UIAlertController *confirmAlert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleActionSheet];
    confirmAlert.popoverPresentationController.sourceView = cell;
    confirmAlert.popoverPresentationController.sourceRect = cell.bounds;
    UIAlertAction *ok = [UIAlertAction actionWithTitle:localize(@"OK", nil) style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        [PLProfiles.current.profiles removeObjectForKey:cell.textLabel.text];
        if ([PLProfiles.current.selectedProfileName isEqualToString:cell.textLabel.text]) {
            // The one being deleted is the selected one, switch to the random one now
            PLProfiles.current.selectedProfileName = PLProfiles.current.profiles.allKeys[0];
            [self.navigationController performSelector:@selector(reloadProfileList)];
        } else {
            [PLProfiles.current save];
        }
        [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
    }];
    UIAlertAction *cancel = [UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil];
    [confirmAlert addAction:cancel];
    [confirmAlert addAction:ok];
    [self presentViewController:confirmAlert animated:YES completion:nil];
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (indexPath.section == kInstances || PLProfiles.current.profiles.count==1) {
        return UITableViewCellEditingStyleNone;
    }
    return UITableViewCellEditingStyleDelete;
}

@end
