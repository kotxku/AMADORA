#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "horizon/HorizonGame.h"
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
            return @"Horizon needs files made from your own copy of Minecraft 26.3, shared by every Horizon instance. On your computer: install the Horizon launcher from playhorizon.dev, sign in, and press Play once so it prepares 26.3. Then run export-horizon.ps1 (it can add your shader and resource packs too), put horizon-26.3.zip in Files and import it here.";
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
        case kHorizonFiles: return 1;
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
        cell.textLabel.text = self.importStatus ?: (HorizonGame.resourcesReady ? @"Replace from a zip…" : @"Import from a zip…");
        cell.textLabel.textColor = self.importStatus ? PLTheme.muted : PLTheme.accent;
        cell.imageView.image = [UIImage systemImageNamed:@"square.and.arrow.down"];
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
    if (indexPath.section == kHorizonFiles && !self.importStatus) {
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
