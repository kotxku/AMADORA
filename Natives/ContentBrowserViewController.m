#import "ContentBrowserViewController.h"
#import "installer/modpack/ModrinthAPI.h"
#import "installer/PandoraImport.h"
#import "horizon/HorizonGame.h"
#import "PLProfiles.h"
#import "PLTheme.h"
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
#import "UIKit+AFNetworking.h"
#pragma clang diagnostic pop
#import "ios_uikit_bridge.h"
#import "utils.h"

#pragma mark Result card

// One search result, laid out like Pandora's cards: icon, "Title by author", summary, tags; downloads and the
// Install/Open Page buttons sit under the text so the card fits a phone's width.
@interface ContentResultCell : UITableViewCell
@property(nonatomic) UIImageView *icon;
@property(nonatomic) UILabel *titleLabel, *summaryLabel, *tagsLabel, *downloadsLabel;
@property(nonatomic) UIButton *installButton, *openButton;
@property(nonatomic, copy) void (^onInstall)(UIButton *sender);
@property(nonatomic, copy) void (^onOpen)(void);
@end

@implementation ContentResultCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    self.backgroundColor = UIColor.clearColor;

    UIView *card = [UIView new];
    [PLTheme styleCard:card];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:card];

    self.icon = [UIImageView new];
    self.icon.contentMode = UIViewContentModeScaleAspectFit;
    self.icon.layer.cornerRadius = 6;
    self.icon.clipsToBounds = YES;
    [self.icon.widthAnchor constraintEqualToConstant:56].active = YES;
    [self.icon.heightAnchor constraintEqualToConstant:56].active = YES;

    self.titleLabel = [UILabel new];
    self.titleLabel.numberOfLines = 2;
    self.summaryLabel = [UILabel new];
    self.summaryLabel.numberOfLines = 3;
    self.summaryLabel.font = [PLTheme fontOfSize:14];
    self.summaryLabel.textColor = PLTheme.foreground;
    self.tagsLabel = [UILabel new];
    self.tagsLabel.font = [PLTheme fontOfSize:12];
    self.tagsLabel.textColor = PLTheme.muted;
    UIStackView *text = [[UIStackView alloc] initWithArrangedSubviews:@[self.titleLabel, self.summaryLabel, self.tagsLabel]];
    text.axis = UILayoutConstraintAxisVertical;
    text.spacing = 3;

    UIStackView *top = [[UIStackView alloc] initWithArrangedSubviews:@[self.icon, text]];
    top.spacing = 12;
    top.alignment = UIStackViewAlignmentTop;

    self.downloadsLabel = [UILabel new];
    self.downloadsLabel.font = [PLTheme fontOfSize:13];
    self.downloadsLabel.textColor = PLTheme.muted;
    self.installButton = [PLTheme buttonWithTitle:@"Install" systemImage:@"arrow.down.to.line" kind:PLButtonKindSuccess];
    [self.installButton addTarget:self action:@selector(install:) forControlEvents:UIControlEventPrimaryActionTriggered];
    self.openButton = [PLTheme buttonWithTitle:@"Open Page" systemImage:@"globe" kind:PLButtonKindInfo];
    [self.openButton addTarget:self action:@selector(open) forControlEvents:UIControlEventPrimaryActionTriggered];
    UIStackView *bottom = [[UIStackView alloc] initWithArrangedSubviews:@[self.downloadsLabel, [UIView new], self.openButton, self.installButton]];
    bottom.spacing = 8;
    bottom.alignment = UIStackViewAlignmentCenter;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[top, bottom]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 10;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [card.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:5],
        [card.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-5],
        [card.leadingAnchor constraintEqualToAnchor:self.contentView.layoutMarginsGuide.leadingAnchor],
        [card.trailingAnchor constraintEqualToAnchor:self.contentView.layoutMarginsGuide.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:card.topAnchor constant:12],
        [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-12],
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12]
    ]];
    return self;
}

- (void)install:(UIButton *)sender {
    if (self.onInstall) self.onInstall(sender);
}

- (void)open {
    if (self.onOpen) self.onOpen();
}

- (void)showProject:(NSDictionary *)project {
    NSMutableAttributedString *title = [[NSMutableAttributedString alloc] initWithString:project[@"title"]
        attributes:@{NSFontAttributeName: [PLTheme fontOfSize:17], NSForegroundColorAttributeName: PLTheme.foreground}];
    if ([project[@"author"] length]) {
        [title appendAttributedString:[[NSAttributedString alloc] initWithString:[@" by " stringByAppendingString:project[@"author"]]
            attributes:@{NSFontAttributeName: [PLTheme fontOfSize:13], NSForegroundColorAttributeName: PLTheme.muted}]];
    }
    self.titleLabel.attributedText = title;
    self.summaryLabel.text = project[@"summary"];
    self.tagsLabel.text = [project[@"tags"] componentsJoinedByString:@"   "];
    self.tagsLabel.hidden = [project[@"tags"] count] == 0;
    self.downloadsLabel.text = [NSString stringWithFormat:@"↓ %@", [ContentResultCell shortCount:project[@"downloads"]]];
    UIImage *placeholder = [UIImage systemImageNamed:@"shippingbox"];
    if ([project[@"iconUrl"] length]) {
        [self.icon setImageWithURL:[NSURL URLWithString:project[@"iconUrl"]] placeholderImage:placeholder];
    } else {
        self.icon.image = placeholder;
    }
}

// Pandora shows "110.97M Downloads"
+ (NSString *)shortCount:(NSNumber *)count {
    double value = count.doubleValue;
    if (value >= 1e9) return [NSString stringWithFormat:@"%.2fB", value / 1e9];
    if (value >= 1e6) return [NSString stringWithFormat:@"%.2fM", value / 1e6];
    if (value >= 1e3) return [NSString stringWithFormat:@"%.1fK", value / 1e3];
    return count.stringValue;
}

@end

#pragma mark Browser

@interface ContentBrowserViewController () <UISearchBarDelegate>
@property(nonatomic) PLContentSource source;
@property(nonatomic, copy) NSString *targetProfileName;
@property(nonatomic) UISegmentedControl *typeControl;
@property(nonatomic) UISearchBar *searchBar;
@property(nonatomic) NSMutableArray<NSDictionary *> *results;
@property(nonatomic, copy) NSString *message;
@property(nonatomic) BOOL loading, reachedEnd;
@property(nonatomic) NSUInteger generation;
@end

@implementation ContentBrowserViewController

- (instancetype)initWithSource:(PLContentSource)source targetProfileName:(NSString *)profileName {
    self = [super initWithStyle:UITableViewStylePlain];
    self.source = source;
    self.targetProfileName = profileName;
    NSString *name = source == PLContentSourceModrinth ? @"Modrinth" : @"CurseForge";
    self.title = profileName ? [@"Add from " stringByAppendingString:name] : name;
    self.results = [NSMutableArray new];
    return self;
}

- (instancetype)init {
    return [self initWithSource:PLContentSourceModrinth targetProfileName:nil];
}

- (NSString *)imageName {
    return self.source == PLContentSourceModrinth ? @"square.stack.3d.down.right" : @"flame";
}

- (NSArray<NSNumber *> *)types {
    // Horizon runs no Java mods: only packs go into its instances
    if (self.targetProfileName && [HorizonGame isHorizonVersion:PLProfiles.current.profiles[self.targetProfileName][@"lastVersionId"]]) {
        return @[@(PLContentTypeResourcePack), @(PLContentTypeShader)];
    }
    // CurseForge modpacks have no in-app installer; their zips go through Add Custom Modpack
    if (self.targetProfileName || self.source == PLContentSourceCurseForge) {
        return @[@(PLContentTypeMod), @(PLContentTypeResourcePack), @(PLContentTypeShader)];
    }
    return @[@(PLContentTypeMod), @(PLContentTypeModpack), @(PLContentTypeResourcePack), @(PLContentTypeShader)];
}

- (PLContentType)type {
    return (PLContentType)[self.types[MAX(self.typeControl.selectedSegmentIndex, 0)] integerValue];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = PLTheme.background;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 150;

    NSDictionary *names = @{@(PLContentTypeMod): @"Mods", @(PLContentTypeModpack): @"Modpacks",
        @(PLContentTypeResourcePack): @"Resource Packs", @(PLContentTypeShader): @"Shaders"};
    NSMutableArray *titles = [NSMutableArray new];
    for (NSNumber *type in self.types) [titles addObject:names[type]];
    self.typeControl = [[UISegmentedControl alloc] initWithItems:titles];
    self.typeControl.selectedSegmentIndex = 0;
    [self.typeControl addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];

    self.searchBar = [UISearchBar new];
    self.searchBar.searchBarStyle = UISearchBarStyleMinimal;
    self.searchBar.placeholder = @"Search...";
    self.searchBar.delegate = self;
    self.searchBar.searchTextField.font = [PLTheme fontOfSize:16];

    UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[self.typeControl, self.searchBar]];
    header.axis = UILayoutConstraintAxisVertical;
    header.spacing = 6;
    header.layoutMargins = UIEdgeInsetsMake(8, 16, 0, 16);
    header.layoutMarginsRelativeArrangement = YES;
    header.frame = CGRectMake(0, 0, self.view.bounds.size.width, 100);
    self.tableView.tableHeaderView = header;

    if (self.source == PLContentSourceCurseForge) {
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"key"]
            style:UIBarButtonItemStylePlain target:self action:@selector(askForCurseForgeKey)];
    }
    if (self.navigationController.viewControllers.firstObject == self && self.presentingViewController) {
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close)];
    }
    [self reload];
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

- (void)close {
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark Searching

- (NSDictionary *)targetProfile {
    return self.targetProfileName ? PLProfiles.current.profiles[self.targetProfileName] : nil;
}

- (void)reload {
    [self.results removeAllObjects];
    self.reachedEnd = NO;
    self.message = nil;
    self.generation++;
    self.loading = NO;
    [self.tableView reloadData];
    if (self.source == PLContentSourceCurseForge && !ContentInstaller.curseForgeAPIKey.length) {
        self.message = @"CurseForge only answers apps with an API key. Get a free one at console.curseforge.com, then tap the key button above.";
        [self.tableView reloadData];
        return;
    }
    [self loadMore];
}

- (void)loadMore {
    if (self.loading || self.reachedEnd) return;
    self.loading = YES;
    NSUInteger generation = self.generation;
    NSString *query = self.searchBar.text;
    PLContentSource source = self.source;
    PLContentType type = self.type;
    NSUInteger offset = self.results.count;
    NSDictionary *info = self.targetProfile ? [PandoraImport loaderInfoForVersionId:self.targetProfile[@"lastVersionId"]] : nil;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *error;
        NSArray *page = [ContentInstaller search:query source:source type:type mcVersion:info[@"mc"] loader:info[@"loader"] offset:offset error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.generation) return; // the search changed while this page loaded
            self.loading = NO;
            if (!page) {
                self.message = error ?: @"Couldn't reach the server.";
                self.reachedEnd = YES;
            } else {
                [self.results addObjectsFromArray:page];
                self.reachedEnd = page.count == 0;
                if (self.results.count == 0) self.message = @"Nothing found.";
            }
            [self.tableView reloadData];
        });
    });
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
    [self reload];
}

#pragma mark Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.results.count + (self.message || self.loading ? 1 : 0);
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row >= self.results.count) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"status"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"status"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.numberOfLines = 0;
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.font = [PLTheme fontOfSize:15];
        cell.textLabel.textColor = PLTheme.muted;
        cell.textLabel.text = self.message ?: @"Loading...";
        return cell;
    }
    if (indexPath.row >= self.results.count - 5) [self loadMore];

    ContentResultCell *cell = [tableView dequeueReusableCellWithIdentifier:@"result"] ?: [[ContentResultCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"result"];
    NSDictionary *project = self.results[indexPath.row];
    [cell showProject:project];
    __weak ContentBrowserViewController *weakSelf = self;
    cell.onOpen = ^{
        openLink(weakSelf, [NSURL URLWithString:project[@"pageUrl"]]);
    };
    cell.onInstall = ^(UIButton *sender) {
        [weakSelf installProject:project from:sender];
    };
    return cell;
}

#pragma mark Installing

- (void)installProject:(NSDictionary *)project from:(UIView *)sender {
    if (self.type == PLContentTypeModpack) {
        [self installModpack:project];
        return;
    }
    if (self.targetProfileName) {
        [self installProject:project intoProfile:self.targetProfileName];
        return;
    }
    // From the sidebar page: pick the instance, as Pandora's install dialog does
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Install %@ into", project[@"title"]]
        message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *names = [PLProfiles.current.profiles.allKeys sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    for (NSString *name in names) {
        NSString *version = PLProfiles.current.profiles[name][@"lastVersionId"];
        [sheet addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%@ (%@)", name, version] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self installProject:project intoProfile:name];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = sender;
    sheet.popoverPresentationController.sourceRect = sender.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)installProject:(NSDictionary *)project intoProfile:(NSString *)profileName {
    NSDictionary *profile = PLProfiles.current.profiles[profileName];
    if (!profile) return;
    NSDictionary *info = [PandoraImport loaderInfoForVersionId:profile[@"lastVersionId"]];
    NSString *gameDir = [PLProfiles gameDirForProfile:profile];
    PLContentSource source = self.source;
    PLContentType type = self.type;
    UIAlertController *busy = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Installing %@", project[@"title"]]
        message:@"Finding a compatible version" preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:busy animated:YES completion:^{
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSString *report = [ContentInstaller install:project source:source type:type gameDir:gameDir mcVersion:info[@"mc"] loader:info[@"loader"] progress:^(NSString *status) {
                dispatch_async(dispatch_get_main_queue(), ^{ busy.message = status; });
            }];
            dispatch_async(dispatch_get_main_queue(), ^{
                [busy dismissViewControllerAnimated:YES completion:^{
                    showDialog(profileName, report);
                }];
            });
        });
    }];
}

// Modpacks become new instances through the existing Modrinth modpack downloader and its progress bar
- (void)installModpack:(NSDictionary *)project {
    NSMutableDictionary *item = @{
        @"apiSource": @(1),
        @"isModpack": @(YES),
        @"id": project[@"id"],
        @"title": project[@"title"],
        @"description": project[@"summary"],
        @"imageUrl": project[@"iconUrl"]
    }.mutableCopy;
    UIAlertController *busy = [UIAlertController alertControllerWithTitle:project[@"title"] message:@"Finding the newest version" preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:busy animated:YES completion:^{
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            ModrinthAPI *api = [ModrinthAPI new];
            [api loadDetailsOfMod:item];
            // ModrinthAPI reads the new instance's icon from here
            NSData *icon = [project[@"iconUrl"] length] ? [NSData dataWithContentsOfURL:[NSURL URLWithString:project[@"iconUrl"]]] : nil;
            [icon writeToFile:[NSTemporaryDirectory() stringByAppendingPathComponent:@"icon.png"] atomically:YES];
            dispatch_async(dispatch_get_main_queue(), ^{
                [busy dismissViewControllerAnimated:YES completion:^{
                    if (![item[@"versionDetailsLoaded"] boolValue] || [item[@"versionNames"] count] == 0) {
                        showDialog(project[@"title"], api.lastError.localizedDescription ?: @"No versions found.");
                        return;
                    }
                    [self chooseModpackVersion:item api:api];
                }];
            });
        });
    }];
}

- (void)chooseModpackVersion:(NSDictionary *)item api:(ModrinthAPI *)api {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Install %@ as a new instance", item[@"title"]]
        message:@"Newest first" preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *names = item[@"versionNames"], *mcNames = item[@"mcVersionNames"];
    for (NSUInteger i = 0; i < MIN(names.count, 8); i++) {
        [sheet addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%@ (Minecraft %@)", names[i], mcNames[i]] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [api installModpackFromDetail:item atIndex:i];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);
    [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark CurseForge key

- (void)askForCurseForgeKey {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"CurseForge API key"
        message:@"CurseForge needs a key for apps. Sign in at console.curseforge.com, create a free API key and paste it here. It stays on this device."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = ContentInstaller.curseForgeAPIKey;
        field.placeholder = @"API key";
        field.secureTextEntry = YES;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Get a key" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        openLink(self, [NSURL URLWithString:@"https://console.curseforge.com/"]);
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        ContentInstaller.curseForgeAPIKey = alert.textFields.firstObject.text;
        [self reload];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
