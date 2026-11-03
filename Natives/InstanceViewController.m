#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "ContentBrowserViewController.h"
#import "InstanceViewController.h"
#import "LauncherProfileEditorViewController.h"
#import "PLProfiles.h"
#import "PLTheme.h"
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
#import "UIKit+AFNetworking.h"
#pragma clang diagnostic pop
#import "installer/ContentInstaller.h"
#import "installer/PandoraImport.h"
#import "installer/RocketCraftInstaller.h"
#import "horizon/HorizonGame.h"
#import "ios_uikit_bridge.h"
#import "utils.h"

#pragma mark Row

// Pandora's mod row: switch, icon, name over version, file name, red delete button
@interface InstalledContentCell : UITableViewCell
@property(nonatomic) UISwitch *toggle;
@property(nonatomic) UIImageView *icon;
@property(nonatomic) UILabel *nameLabel, *detailLabel;
@property(nonatomic) UIButton *deleteButton;
@property(nonatomic, copy) void (^onToggle)(BOOL on);
@property(nonatomic, copy) void (^onDelete)(UIButton *sender);
@end

@implementation InstalledContentCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    self.backgroundColor = UIColor.clearColor;

    self.toggle = [UISwitch new];
    [self.toggle addTarget:self action:@selector(toggled) forControlEvents:UIControlEventValueChanged];
    self.icon = [UIImageView new];
    self.icon.contentMode = UIViewContentModeScaleAspectFit;
    self.icon.layer.cornerRadius = 4;
    self.icon.clipsToBounds = YES;
    // Mod icons are mostly pixel art
    self.icon.layer.magnificationFilter = kCAFilterNearest;
    [self.icon.widthAnchor constraintEqualToConstant:48].active = YES;
    [self.icon.heightAnchor constraintEqualToConstant:48].active = YES;

    self.nameLabel = [UILabel new];
    self.nameLabel.font = [PLTheme fontOfSize:16];
    self.nameLabel.textColor = PLTheme.foreground;
    self.detailLabel = [UILabel new];
    self.detailLabel.font = [PLTheme fontOfSize:13];
    self.detailLabel.textColor = PLTheme.muted;
    self.detailLabel.numberOfLines = 2;
    self.detailLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    UIStackView *text = [[UIStackView alloc] initWithArrangedSubviews:@[self.nameLabel, self.detailLabel]];
    text.axis = UILayoutConstraintAxisVertical;
    text.spacing = 2;

    self.deleteButton = [PLTheme buttonWithTitle:nil systemImage:@"trash" kind:PLButtonKindDanger];
    self.deleteButton.contentEdgeInsets = UIEdgeInsetsMake(8, 9, 8, 9);
    self.deleteButton.imageEdgeInsets = UIEdgeInsetsZero;
    [self.deleteButton addTarget:self action:@selector(deleteTapped:) forControlEvents:UIControlEventPrimaryActionTriggered];

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[self.toggle, self.icon, text, self.deleteButton]];
    row.spacing = 10;
    row.alignment = UIStackViewAlignmentCenter;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [text setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [self.contentView addSubview:row];
    [NSLayoutConstraint activateConstraints:@[
        [row.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:8],
        [row.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-8],
        [row.leadingAnchor constraintEqualToAnchor:self.contentView.layoutMarginsGuide.leadingAnchor],
        [row.trailingAnchor constraintEqualToAnchor:self.contentView.layoutMarginsGuide.trailingAnchor]
    ]];
    return self;
}

- (void)toggled {
    if (self.onToggle) self.onToggle(self.toggle.on);
}

- (void)deleteTapped:(UIButton *)sender {
    if (self.onDelete) self.onDelete(sender);
}

@end

#pragma mark Page

@interface InstanceViewController () <UIDocumentPickerDelegate, UISearchBarDelegate>
@property(nonatomic, copy) NSString *profileName;
@property(nonatomic) UISegmentedControl *folderControl;
@property(nonatomic) UISearchBar *searchBar;
@property(nonatomic) NSArray<NSString *> *files;
@property(nonatomic) NSDictionary<NSString *, NSDictionary *> *installed;
@end

@implementation InstanceViewController

- (instancetype)initWithProfileName:(NSString *)profileName {
    self = [super initWithStyle:UITableViewStylePlain];
    self.profileName = profileName;
    self.title = profileName;
    return self;
}

- (NSDictionary *)profile {
    return PLProfiles.current.profiles[self.profileName];
}

- (NSString *)gameDir {
    return [PLProfiles gameDirForProfile:self.profile];
}

// Horizon runs no Java mods: its instances have only packs
- (BOOL)isHorizon {
    return [HorizonGame isHorizonVersion:self.profile[@"lastVersionId"]];
}

- (PLContentType)type {
    NSArray<NSNumber *> *types = self.isHorizon ? @[@(PLContentTypeResourcePack), @(PLContentTypeShader)]
        : @[@(PLContentTypeMod), @(PLContentTypeResourcePack), @(PLContentTypeShader)];
    return (PLContentType)types[self.folderControl.selectedSegmentIndex].integerValue;
}

- (NSString *)folderPath {
    return [self.gameDir stringByAppendingPathComponent:[ContentInstaller folderForType:self.type]];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = PLTheme.background;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 64;

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"gearshape"]
        style:UIBarButtonItemStylePlain target:self action:@selector(openSettings)];

    self.folderControl = [[UISegmentedControl alloc] initWithItems:self.isHorizon ? @[@"Resource Packs", @"Shaders"] : @[@"Mods", @"Resource Packs", @"Shaders"]];
    self.folderControl.selectedSegmentIndex = 0;
    [self.folderControl addTarget:self action:@selector(reloadFiles) forControlEvents:UIControlEventValueChanged];

    UIButton *modrinth = [PLTheme buttonWithTitle:@"Modrinth" systemImage:@"plus" kind:PLButtonKindSuccess];
    [modrinth addTarget:self action:@selector(addFromModrinth) forControlEvents:UIControlEventPrimaryActionTriggered];
    UIButton *curseForge = [PLTheme buttonWithTitle:@"CurseForge" systemImage:@"plus" kind:PLButtonKindSuccess];
    [curseForge addTarget:self action:@selector(addFromCurseForge) forControlEvents:UIControlEventPrimaryActionTriggered];
    UIButton *file = [PLTheme buttonWithTitle:@"File" systemImage:@"plus" kind:PLButtonKindSuccess];
    [file addTarget:self action:@selector(addFromFile) forControlEvents:UIControlEventPrimaryActionTriggered];
    UIButton *rocketCraft = [PLTheme buttonWithTitle:@"Rocket Craft" systemImage:@"car.fill" kind:PLButtonKindInfo];
    [rocketCraft addTarget:self action:@selector(addRocketCraft) forControlEvents:UIControlEventPrimaryActionTriggered];
    UIStackView *addButtons = [[UIStackView alloc] initWithArrangedSubviews:@[modrinth, curseForge, file]];
    addButtons.spacing = 8;
    addButtons.distribution = UIStackViewDistributionFillProportionally;
    // Rocket Craft is a Fabric modpack
    rocketCraft.hidden = self.isHorizon;
    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[addButtons, rocketCraft]];
    buttons.axis = UILayoutConstraintAxisVertical;
    buttons.alignment = UIStackViewAlignmentLeading;
    buttons.spacing = 8;

    self.searchBar = [UISearchBar new];
    self.searchBar.searchBarStyle = UISearchBarStyleMinimal;
    self.searchBar.placeholder = @"Search...";
    self.searchBar.delegate = self;

    UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[self.folderControl, buttons, self.searchBar]];
    header.axis = UILayoutConstraintAxisVertical;
    header.spacing = 8;
    header.layoutMargins = UIEdgeInsetsMake(8, 16, 0, 16);
    header.layoutMarginsRelativeArrangement = YES;
    header.frame = CGRectMake(0, 0, self.view.bounds.size.width, 140);
    self.tableView.tableHeaderView = header;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadFiles];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UIView *header = self.tableView.tableHeaderView;
    CGFloat height = [header systemLayoutSizeFittingSize:CGSizeMake(self.tableView.bounds.size.width, UILayoutFittingCompressedSize.height)].height;
    if (header.frame.size.width != self.tableView.bounds.size.width || header.frame.size.height != height) {
        header.frame = CGRectMake(0, 0, self.tableView.bounds.size.width, height);
        self.tableView.tableHeaderView = header;
    }
}

- (void)reloadFiles {
    if (!self.profile) {
        // Deleted or renamed in the editor
        [self.navigationController popViewControllerAnimated:YES];
        return;
    }
    self.installed = [ContentInstaller installedContentInGameDir:self.gameDir];
    NSArray *extensions = self.type == PLContentTypeMod ? @[@"jar"] : @[@"zip"];
    NSString *filter = self.searchBar.text.lowercaseString;
    NSMutableArray *files = [NSMutableArray new];
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *name in [fm contentsOfDirectoryAtPath:self.folderPath error:nil]) {
        if ([name hasPrefix:@"."]) continue;
        NSString *base = [self enabledNameOf:name];
        BOOL isDir = NO;
        [fm fileExistsAtPath:[self.folderPath stringByAppendingPathComponent:name] isDirectory:&isDir];
        // Packs can also be plain folders; mods are always jars
        if (!isDir && ![extensions containsObject:base.pathExtension.lowercaseString]) continue;
        if (isDir && self.type == PLContentTypeMod) continue;
        if (filter.length && ![[self titleOf:name].lowercaseString containsString:filter] && ![name.lowercaseString containsString:filter]) continue;
        [files addObject:name];
    }
    self.files = [files sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [[self titleOf:a] localizedCaseInsensitiveCompare:[self titleOf:b]];
    }];
    [self.tableView reloadData];
}

- (NSString *)enabledNameOf:(NSString *)name {
    return [name hasSuffix:@".disabled"] ? name.stringByDeletingPathExtension : name;
}

- (NSString *)titleOf:(NSString *)name {
    NSString *title = self.installed[[self enabledNameOf:name]][@"title"];
    return title.length ? title : [self enabledNameOf:name].stringByDeletingPathExtension;
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    [self reloadFiles];
}

#pragma mark Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return MAX(self.files.count, 1);
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.files.count == 0) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"empty"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"empty"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.numberOfLines = 0;
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.font = [PLTheme fontOfSize:15];
        cell.textLabel.textColor = PLTheme.muted;
        cell.textLabel.text = self.searchBar.text.length ? @"Nothing matches." : @"Nothing installed yet. Add some from Modrinth, CurseForge or a file.";
        return cell;
    }
    InstalledContentCell *cell = [tableView dequeueReusableCellWithIdentifier:@"content"] ?: [[InstalledContentCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"content"];
    NSString *name = self.files[indexPath.row];
    NSString *path = [self.folderPath stringByAppendingPathComponent:name];
    NSDictionary *info = self.installed[[self enabledNameOf:name]];
    BOOL isDir = NO;
    [NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDir];

    cell.nameLabel.text = [self titleOf:name];
    NSString *version = info[@"version"];
    cell.detailLabel.text = version.length ? [NSString stringWithFormat:@"%@\n%@", version, [self enabledNameOf:name]] : [self enabledNameOf:name];
    cell.toggle.on = ![name hasSuffix:@".disabled"];
    // Minecraft lists pack folders whatever they're called, so renaming can't switch them off
    cell.toggle.hidden = isDir;
    UIImage *placeholder = [UIImage systemImageNamed:self.type == PLContentTypeMod ? @"shippingbox" : @"photo"];
    if ([info[@"iconUrl"] length]) {
        [cell.icon setImageWithURL:[NSURL URLWithString:info[@"iconUrl"]] placeholderImage:placeholder];
    } else {
        cell.icon.image = placeholder;
    }
    cell.icon.tintColor = PLTheme.muted;

    __weak InstanceViewController *weakSelf = self;
    cell.onToggle = ^(BOOL on) {
        [weakSelf setFile:name enabled:on];
    };
    cell.onDelete = ^(UIButton *sender) {
        [weakSelf confirmDelete:name from:sender];
    };
    return cell;
}

#pragma mark Actions

- (void)setFile:(NSString *)name enabled:(BOOL)enabled {
    NSString *base = [self enabledNameOf:name];
    NSString *from = [self.folderPath stringByAppendingPathComponent:name];
    NSString *to = [self.folderPath stringByAppendingPathComponent:enabled ? base : [base stringByAppendingString:@".disabled"]];
    NSError *error;
    if (![from isEqualToString:to] && ![NSFileManager.defaultManager moveItemAtPath:from toPath:to error:&error]) {
        showDialog(@"Couldn't change it", error.localizedDescription);
    }
    [self reloadFiles];
}

- (void)confirmDelete:(NSString *)name from:(UIView *)sender {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Delete %@?", [self titleOf:name]]
        message:[self enabledNameOf:name] preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        NSError *error;
        if (![NSFileManager.defaultManager removeItemAtPath:[self.folderPath stringByAppendingPathComponent:name] error:&error]) {
            showDialog(@"Couldn't delete it", error.localizedDescription);
        } else {
            [ContentInstaller forgetFile:name inGameDir:self.gameDir];
        }
        [self reloadFiles];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = sender;
    sheet.popoverPresentationController.sourceRect = sender.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)addFromModrinth {
    [self.navigationController pushViewController:[[ContentBrowserViewController alloc] initWithSource:PLContentSourceModrinth targetProfileName:self.profileName] animated:YES];
}

- (void)addFromCurseForge {
    [self.navigationController pushViewController:[[ContentBrowserViewController alloc] initWithSource:PLContentSourceCurseForge targetProfileName:self.profileName] animated:YES];
}

- (void)addFromFile {
    NSArray *types = self.type == PLContentTypeMod
        ? @[[UTType typeWithFilenameExtension:@"jar"] ?: UTTypeData]
        : @[UTTypeZIP];
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
    picker.allowsMultipleSelection = YES;
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:self.folderPath withIntermediateDirectories:YES attributes:nil error:nil];
    NSMutableArray *failed = [NSMutableArray new];
    for (NSURL *url in urls) {
        NSString *dest = [self.folderPath stringByAppendingPathComponent:url.lastPathComponent];
        [fm removeItemAtPath:dest error:nil];
        if (![fm moveItemAtPath:url.path toPath:dest error:nil]) [failed addObject:url.lastPathComponent];
    }
    if (failed.count) showDialog(@"Some files weren't added", [failed componentsJoinedByString:@"\n"]);
    [self reloadFiles];
}

#pragma mark Rocket Craft

- (void)addRocketCraft {
    NSDictionary *info = [PandoraImport loaderInfoForVersionId:self.profile[@"lastVersionId"]];
    NSString *message = @"Downloads the Rocket Craft kit (about 1.8 GB) and adds its mods, the RL Assets, RL Pack and Music Pack resource packs, and its config to this instance. Keep AMADORA open until it finishes.";
    if (![info[@"loader"] isEqualToString:@"fabric"] || ![info[@"mc"] isEqualToString:@"26.3"]) {
        message = [NSString stringWithFormat:@"Rocket Craft needs a Minecraft 26.3 Fabric instance (loader 0.19.5 or newer); this one is %@.\n\n%@", self.profile[@"lastVersionId"], message];
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Install Rocket Craft?" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Install" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self installRocketCraft];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)installRocketCraft {
    NSString *gameDir = self.gameDir;
    UIAlertController *busy = [UIAlertController alertControllerWithTitle:@"Installing Rocket Craft" message:@"Starting the download" preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:busy animated:YES completion:^{
        // A 1.8 GB download takes a while; don't let the screen lock suspend it
        UIApplication.sharedApplication.idleTimerDisabled = YES;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSString *report = [RocketCraftInstaller installIntoGameDir:gameDir progress:^(NSString *status) {
                dispatch_async(dispatch_get_main_queue(), ^{ busy.message = status; });
            }];
            dispatch_async(dispatch_get_main_queue(), ^{
                UIApplication.sharedApplication.idleTimerDisabled = NO;
                [busy dismissViewControllerAnimated:YES completion:^{
                    showDialog(@"Rocket Craft", report);
                    [self reloadFiles];
                }];
            });
        });
    }];
}

- (void)openSettings {
    LauncherProfileEditorViewController *vc = [LauncherProfileEditorViewController new];
    vc.profile = self.profile.mutableCopy;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    [self presentViewController:nav animated:YES completion:nil];
}

@end
