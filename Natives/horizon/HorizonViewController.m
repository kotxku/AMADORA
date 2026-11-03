#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "horizon/HorizonGame.h"
#import "horizon/HorizonViewController.h"
#import "PLTheme.h"
#import "ios_uikit_bridge.h"
#import "utils.h"

typedef NS_ENUM(NSInteger, HorizonSection) {
    kHorizonPlay,
    kHorizonFiles,
    kHorizonShaders
};

@interface HorizonViewController () <UIDocumentPickerDelegate>
@property(nonatomic, copy) NSString *importStatus;
@property(nonatomic) BOOL pickingShader;
@property(nonatomic) NSArray<NSString *> *shaderPacks;
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
    self.shaderPacks = HorizonGame.shaderPacks;
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 3;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @[@"Horizon: Minecraft 26.3 in Rust", @"Game files", @"Shader packs"][section];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == kHorizonPlay) {
        return @"Horizon (playhorizon.dev) is a rewrite of Minecraft: Java Edition 26.3 in Rust. It is not made by Mojang. It runs natively, without Java. Joining online-mode servers uses your selected Microsoft account. Java mods don't run in Horizon.";
    }
    if (section == kHorizonShaders) {
        return @"Iris/OptiFine-format shader packs (a zip with shaders/ inside), such as Complementary with Euphoria Patches. Choose one in the game under Options > Horizon Settings > Shader Packs. Horizon translates them itself, so some effects may differ from Iris, and heavy packs can be slow on a phone. Swipe a pack to remove it.";
    }
    return @"Horizon needs files made from your own copy of Minecraft 26.3. On your computer: install the Horizon launcher from playhorizon.dev, sign in, and press Play once so it prepares 26.3. Then run export-horizon.ps1, which makes horizon-26.3.zip. Put the zip in Files (iCloud Drive, AirDrop or a share) and import it here.";
}

- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
    UITableViewHeaderFooterView *header = (UITableViewHeaderFooterView *)view;
    header.textLabel.font = [PLTheme fontOfSize:17];
    header.textLabel.textColor = PLTheme.foreground;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == kHorizonShaders) return self.shaderPacks.count + 1;
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
    } else if (indexPath.section == kHorizonShaders) {
        if (indexPath.row < self.shaderPacks.count) {
            cell.textLabel.text = self.shaderPacks[indexPath.row].stringByDeletingPathExtension;
            cell.textLabel.numberOfLines = 0;
            cell.imageView.image = [UIImage systemImageNamed:@"sparkles"];
            cell.imageView.tintColor = PLTheme.muted;
        } else {
            cell.textLabel.text = @"Add a shader pack (.zip)…";
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
               (indexPath.section == kHorizonShaders && indexPath.row == self.shaderPacks.count)) {
        self.pickingShader = indexPath.section == kHorizonShaders;
        UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeZIP] asCopy:YES];
        picker.delegate = self;
        [self presentViewController:picker animated:YES completion:nil];
    }
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == kHorizonShaders && indexPath.row < self.shaderPacks.count;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (style != UITableViewCellEditingStyleDelete) return;
    NSString *pack = [HorizonGame.shaderpacksPath stringByAppendingPathComponent:self.shaderPacks[indexPath.row]];
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
    if (self.pickingShader) {
        NSString *error = [HorizonGame importShaderPack:path];
        [NSFileManager.defaultManager removeItemAtPath:path error:nil];
        [self reload];
        if (error) showDialog(@"Couldn't add the shader pack", error);
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
