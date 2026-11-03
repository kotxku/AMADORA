#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "horizon/HorizonGame.h"
#import "horizon/HorizonViewController.h"
#import "PLTheme.h"
#import "ios_uikit_bridge.h"
#import "utils.h"

typedef NS_ENUM(NSInteger, HorizonSection) {
    kHorizonPlay,
    kHorizonFiles,
    kHorizonResourcePacks,
    kHorizonShaders
};

// The pack folder each pack section shows
static NSString *packFolder(NSInteger section) {
    return section == kHorizonShaders ? @"shaderpacks" : @"resourcepacks";
}

@interface HorizonViewController () <UIDocumentPickerDelegate>
@property(nonatomic, copy) NSString *importStatus;
@property(nonatomic, copy) NSString *pickingPacksFor; // a pack folder, or nil for the game files
@property(nonatomic) NSDictionary<NSString *, NSArray<NSString *> *> *packs;
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
    self.packs = @{@"shaderpacks": [HorizonGame packsIn:@"shaderpacks"], @"resourcepacks": [HorizonGame packsIn:@"resourcepacks"]};
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 4;
}

- (BOOL)isPackSection:(NSInteger)section {
    return section == kHorizonResourcePacks || section == kHorizonShaders;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @[@"Horizon: Minecraft 26.3 in Rust", @"Game files", @"Resource packs", @"Shader packs"][section];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == kHorizonPlay) {
        return @"Horizon (playhorizon.dev) is a rewrite of Minecraft: Java Edition 26.3 in Rust. It is not made by Mojang. It runs natively, without Java. Joining online-mode servers uses your selected Microsoft account. Java mods don't run in Horizon.";
    }
    if (section == kHorizonShaders) {
        return @"Iris/OptiFine-format shader packs (a zip with shaders/ inside), such as Complementary with Euphoria Patches. Choose one in the game under Options > Horizon Settings > Shader Packs. Horizon translates them itself, so some effects may differ from Iris, and heavy packs can be slow on a phone. Swipe a pack to remove it.";
    }
    if (section == kHorizonResourcePacks) {
        return @"Resource packs for 26.3 (a zip with pack.mcmeta inside). Choose them in the game under Options > Resource Packs; a pack higher in the list wins. Swipe a pack to remove it.";
    }
    return @"Horizon needs files made from your own copy of Minecraft 26.3. On your computer: install the Horizon launcher from playhorizon.dev, sign in, and press Play once so it prepares 26.3. Then run export-horizon.ps1, which makes horizon-26.3.zip. Put the zip in Files (iCloud Drive, AirDrop or a share) and import it here.";
}

- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
    UITableViewHeaderFooterView *header = (UITableViewHeaderFooterView *)view;
    header.textLabel.font = [PLTheme fontOfSize:17];
    header.textLabel.textColor = PLTheme.foreground;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if ([self isPackSection:section]) return self.packs[packFolder(section)].count + 1;
    return section == kHorizonPlay ? 3 : 1;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.backgroundColor = PLTheme.background;
    cell.textLabel.font = [PLTheme fontOfSize:16];
    cell.textLabel.textColor = PLTheme.foreground;
    cell.detailTextLabel.textColor = PLTheme.muted;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    if (indexPath.section == kHorizonPlay) {
        switch (indexPath.row) {
            case 0:
                cell.textLabel.text = @"Engine";
                cell.detailTextLabel.text = HorizonGame.engineAvailable ? @"Included" : @"Not in this build";
                break;
            case 1:
                cell.textLabel.text = @"Game files";
                cell.detailTextLabel.text = HorizonGame.resourcesReady ? @"Ready" : @"Not imported";
                break;
            case 2: {
                BOOL ready = HorizonGame.engineAvailable && HorizonGame.resourcesReady;
                cell.textLabel.text = @"Play Horizon";
                cell.textLabel.textColor = ready ? PLTheme.accent : PLTheme.muted;
                cell.imageView.image = [UIImage systemImageNamed:@"play.fill"];
                cell.imageView.tintColor = cell.textLabel.textColor;
                cell.selectionStyle = UITableViewCellSelectionStyleDefault;
                break;
            }
        }
    } else if ([self isPackSection:indexPath.section]) {
        NSArray<NSString *> *packs = self.packs[packFolder(indexPath.section)];
        BOOL shaders = indexPath.section == kHorizonShaders;
        if (indexPath.row < packs.count) {
            cell.textLabel.text = packs[indexPath.row].stringByDeletingPathExtension;
            cell.textLabel.numberOfLines = 0;
            cell.imageView.image = [UIImage systemImageNamed:shaders ? @"sparkles" : @"photo.on.rectangle"];
            cell.imageView.tintColor = PLTheme.muted;
        } else {
            cell.textLabel.text = shaders ? @"Add a shader pack (.zip)…" : @"Add a resource pack (.zip)…";
            cell.textLabel.textColor = PLTheme.accent;
            cell.imageView.image = [UIImage systemImageNamed:@"plus"];
            cell.imageView.tintColor = PLTheme.accent;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        }
    } else {
        cell.textLabel.text = self.importStatus ?: (HorizonGame.resourcesReady ? @"Replace from a zip…" : @"Import from a zip…");
        cell.textLabel.textColor = self.importStatus ? PLTheme.muted : PLTheme.accent;
        cell.imageView.image = [UIImage systemImageNamed:@"square.and.arrow.down"];
        cell.imageView.tintColor = cell.textLabel.textColor;
        cell.selectionStyle = self.importStatus ? UITableViewCellSelectionStyleNone : UITableViewCellSelectionStyleDefault;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == kHorizonPlay && indexPath.row == 2) {
        // Started from the run loop rather than inside this touch's handling: the game keeps the
        // main run loop turning itself and never returns
        [self performSelector:@selector(play) withObject:nil afterDelay:0];
    } else if ((indexPath.section == kHorizonFiles && !self.importStatus) ||
               ([self isPackSection:indexPath.section] && indexPath.row == self.packs[packFolder(indexPath.section)].count)) {
        self.pickingPacksFor = indexPath.section == kHorizonFiles ? nil : packFolder(indexPath.section);
        UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeZIP] asCopy:YES];
        picker.delegate = self;
        [self presentViewController:picker animated:YES completion:nil];
    }
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return [self isPackSection:indexPath.section] && indexPath.row < self.packs[packFolder(indexPath.section)].count;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (style != UITableViewCellEditingStyleDelete) return;
    NSString *folder = packFolder(indexPath.section);
    NSString *pack = [[HorizonGame packsPath:folder] stringByAppendingPathComponent:self.packs[folder][indexPath.row]];
    [NSFileManager.defaultManager removeItemAtPath:pack error:nil];
    [self reload];
}

- (void)play {
    NSString *error = [HorizonGame start];
    if (error) showDialog(@"Can't start Horizon", error);
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSString *path = urls.firstObject.path;
    if (!path) return;
    if (self.pickingPacksFor) {
        NSString *error = [HorizonGame importPack:path into:self.pickingPacksFor];
        [NSFileManager.defaultManager removeItemAtPath:path error:nil];
        [self reload];
        if (error) showDialog(@"Couldn't add the pack", error);
        return;
    }
    self.importStatus = @"Importing…";
    [self.tableView reloadData];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *error = [HorizonGame importResourcesZip:path progress:^(NSString *status) {
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
                showDialog(@"Horizon is ready", @"The 26.3 game files are imported. Press Play Horizon.");
            }
        });
    });
}

@end
