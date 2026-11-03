#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "PLSync.h"
#import "PLTheme.h"
#import "SyncingViewController.h"
#import "ios_uikit_bridge.h"
#import "utils.h"

typedef NS_ENUM(NSInteger, SyncSection) {
    kSyncComputer,
    kSyncFiles,
    kSyncFolders,
    kSyncMods
};

@interface SyncingViewController () <UIDocumentPickerDelegate>
@property(nonatomic) NSArray<NSArray<NSString *> *> *rows; // per section: folder or file names
@property(nonatomic) NSDictionary<NSString *, NSString *> *labels;
@property(nonatomic, copy) NSString *lastSync;
@property(nonatomic) BOOL busy;
@end

@implementation SyncingViewController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleGrouped];
    self.title = @"Syncing";
    return self;
}

- (NSString *)imageName {
    return @"arrow.triangle.2.circlepath";
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = PLTheme.background;
    // Pandora's sections; mod folders are labelled with the mod's name
    self.rows = @[
        @[],
        PLSync.defaultFiles,
        @[@"saves", @"config", @"screenshots", @"resourcepacks", @"shaderpacks", @"downloads"],
        @[@"flashback", @"Distant_Horizons_server_data", @".voxy", @"xaero", @"journeymap", @".bobby", @"schematics"]
    ];
    self.labels = @{@"flashback": @"Flashback", @"Distant_Horizons_server_data": @"Distant Horizons", @".voxy": @"Voxy",
        @"xaero": @"Xaero's Minimap", @"journeymap": @"JourneyMap", @".bobby": @"Bobby", @"schematics": @"Litematica"};
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

#pragma mark Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.rows.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @[@"Pandora on your computer", @"Files", @"Folders", @"Mods"][section];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == kSyncComputer) {
        return @"On the computer, share %APPDATA%\\PandoraLauncher\\synced (right-click > Properties > Sharing), then on this phone open Files > ... > Connect to Server and sign in. Or keep that folder in a cloud drive Files can open. Choose it here; AMADORA copies whichever side changed last before every launch. Each world moves as a whole, and nothing is deleted.";
    }
    if (section == kSyncFiles) return @"These options sync files and folders across instances, as in Pandora.";
    return nil;
}

- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
    UITableViewHeaderFooterView *header = (UITableViewHeaderFooterView *)view;
    header.textLabel.font = [PLTheme fontOfSize:17];
    header.textLabel.textColor = PLTheme.foreground;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == kSyncComputer ? 2 : self.rows[section].count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == kSyncComputer) return [self computerCellForRow:indexPath.row];

    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"target"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"target"];
    cell.backgroundColor = PLTheme.surface;
    cell.textLabel.numberOfLines = 0;
    NSString *name = self.rows[indexPath.section][indexPath.row];
    BOOL isFile = indexPath.section == kSyncFiles;
    BOOL enabled = isFile ? [PLSync isFileEnabled:name] : [PLSync isFolderEnabled:name];

    NSString *label = self.labels[name] ? [NSString stringWithFormat:@"Sync %@ (%@) folder", self.labels[name], name]
        : [NSString stringWithFormat:isFile ? @"Sync %@" : @"Sync %@ folder", name];
    NSMutableAttributedString *text = [[NSMutableAttributedString alloc] initWithString:label
        attributes:@{NSFontAttributeName: [PLTheme fontOfSize:16], NSForegroundColorAttributeName: PLTheme.foreground}];
    BOOL dimmed = NO;
    if (!isFile) {
        NSArray *blocked;
        NSUInteger total = 0;
        NSUInteger linked = [PLSync linkedCountForFolder:name blocked:&blocked total:&total];
        if (enabled) {
            UIColor *countColor = linked == total ? [UIColor colorWithRed:0.38 green:0.65 blue:0.98 alpha:1] : [UIColor colorWithRed:0.98 green:0.57 blue:0.24 alpha:1];
            [text appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"  (%lu/%lu folders synced)", (unsigned long)linked, (unsigned long)total]
                attributes:@{NSFontAttributeName: [PLTheme fontOfSize:14], NSForegroundColorAttributeName: countColor}]];
        } else if (blocked.count) {
            // Pandora greys these out; here a tap offers to merge them instead
            dimmed = YES;
        }
    }
    cell.textLabel.attributedText = text;
    cell.textLabel.alpha = dimmed ? 0.45 : 1;
    cell.imageView.image = [UIImage systemImageNamed:enabled ? @"checkmark.square.fill" : @"square"];
    cell.imageView.tintColor = PLTheme.foreground;
    cell.imageView.alpha = cell.textLabel.alpha;
    return cell;
}

- (UITableViewCell *)computerCellForRow:(NSInteger)row {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.backgroundColor = PLTheme.surface;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    if (row == 0) {
        NSURL *remote = PLSync.remoteFolder;
        cell.textLabel.font = [PLTheme fontOfSize:16];
        cell.textLabel.text = remote ? remote.lastPathComponent : @"Not set up";
        cell.detailTextLabel.font = [PLTheme fontOfSize:13];
        cell.detailTextLabel.textColor = PLTheme.muted;
        cell.detailTextLabel.numberOfLines = 0;
        cell.detailTextLabel.text = self.busy ? @"Syncing..." : (self.lastSync ?: (remote ? remote.path : @"Pick Pandora's synced folder from your computer."));
        cell.imageView.image = [UIImage systemImageNamed:@"desktopcomputer"];
        cell.imageView.tintColor = PLTheme.foreground;
        return cell;
    }
    UIButton *choose = [PLTheme buttonWithTitle:PLSync.remoteFolder ? @"Change folder" : @"Choose folder" systemImage:@"folder" kind:PLButtonKindInfo];
    [choose addTarget:self action:@selector(chooseRemote) forControlEvents:UIControlEventPrimaryActionTriggered];
    UIButton *sync = [PLTheme buttonWithTitle:@"Sync now" systemImage:@"arrow.triangle.2.circlepath" kind:PLButtonKindSuccess];
    [sync addTarget:self action:@selector(syncNow) forControlEvents:UIControlEventPrimaryActionTriggered];
    UIButton *stop = [PLTheme buttonWithTitle:@"Stop" systemImage:nil kind:PLButtonKindDanger];
    [stop addTarget:self action:@selector(stopRemote) forControlEvents:UIControlEventPrimaryActionTriggered];
    sync.enabled = stop.enabled = PLSync.remoteFolder && !self.busy;
    sync.alpha = stop.alpha = sync.enabled ? 1 : 0.5;
    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[choose, sync, stop]];
    buttons.spacing = 8;
    buttons.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:buttons];
    [NSLayoutConstraint activateConstraints:@[
        [buttons.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:8],
        [buttons.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-8],
        [buttons.leadingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.leadingAnchor],
        [buttons.trailingAnchor constraintLessThanOrEqualToAnchor:cell.contentView.layoutMarginsGuide.trailingAnchor]
    ]];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == kSyncComputer) return;
    NSString *name = self.rows[indexPath.section][indexPath.row];
    if (indexPath.section == kSyncFiles) {
        [PLSync setFile:name enabled:![PLSync isFileEnabled:name]];
        [tableView reloadData];
        return;
    }
    if ([PLSync isFolderEnabled:name]) {
        [PLSync disableFolder:name];
        [tableView reloadData];
        return;
    }
    NSString *problem = [PLSync enableFolder:name moveExisting:NO];
    if (!problem) {
        [tableView reloadData];
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Sync %@?", name]
        message:[problem stringByAppendingString:@"\n\nMove their content into the synced folder so every instance shares it? Files with the same name are kept side by side, named after their instance."]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Move and sync" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *error = [PLSync enableFolder:name moveExisting:YES];
        if (error) showDialog(@"Syncing", error);
        [tableView reloadData];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark Computer

- (void)chooseRemote {
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeFolder]];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    NSString *error = [PLSync setRemoteFolder:url];
    if (error) {
        showDialog(@"Couldn't use that folder", error);
        return;
    }
    self.lastSync = nil;
    [self.tableView reloadData];
    if (![url.lastPathComponent isEqualToString:@"synced"]) {
        showDialog(@"Is this Pandora's synced folder?", [NSString stringWithFormat:@"Pandora keeps it at %%APPDATA%%\\PandoraLauncher\\synced. You picked \"%@\"; AMADORA will sync with it anyway.", url.lastPathComponent]);
    }
}

- (void)syncNow {
    self.busy = YES;
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:kSyncComputer] withRowAnimation:UITableViewRowAnimationNone];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *summary = [PLSync syncWithRemote];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO;
            self.lastSync = summary;
            [self.tableView reloadData];
        });
    });
}

- (void)stopRemote {
    [PLSync setRemoteFolder:nil];
    self.lastSync = nil;
    [self.tableView reloadData];
}

@end
