#import "ClaudeStatusBar.h"

#import "ClaudeProfile.h"
#import "TerminalTheme.h"
#import "TerminalDBTerminal-Swift.h"

#import <math.h>

static NSTimeInterval const ClaudeUsageRefreshInterval = 5.0 * 60.0;
static NSTimeInterval const ClaudeUsageFreshnessInterval = 10.0 * 60.0;
static NSTimeInterval const ClaudeAccountRefreshInterval = 5.0 * 60.0;
static NSTimeInterval const ClaudeUsageSnapshotInterval = 5.0;
static NSNotificationName const ClaudeUsageSnapshotDidChange = @"ClaudeUsageSnapshotDidChange";

// The main thread owns these snapshots. Disk reads and history updates run on
// a separate serial queue so all panes can share one result per profile.
static NSCache<NSString *, NSDictionary *> *ClaudeUsageSnapshots(void) {
    static NSCache<NSString *, NSDictionary *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [[NSCache alloc] init];
        cache.countLimit = 128;
    });
    return cache;
}

static dispatch_queue_t ClaudeUsageSnapshotQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dispatch_queue_attr_t attributes = dispatch_queue_attr_make_with_autorelease_frequency(
            DISPATCH_QUEUE_SERIAL, DISPATCH_AUTORELEASE_FREQUENCY_WORK_ITEM);
        queue = dispatch_queue_create("com.terminaldb.app.claude-usage-snapshots",
            dispatch_queue_attr_make_with_qos_class(attributes, QOS_CLASS_UTILITY, 0));
    });
    return queue;
}

static void ClaudeConfigureSharedTask(NSTask *task, NSString *executable, NSArray *arguments, NSDictionary *environment) {
    NSString *shared = environment[@"TERMINALDB_SHARED_ACCOUNT_ID"];
    if (shared.length == 0) return;
    task.executableURL = [NSURL fileURLWithPath:TDBSharedAccounts.launcherPath];
    task.arguments = [@[@"--claude-launch", shared, @"--", executable] arrayByAddingObjectsFromArray:arguments];
}

static dispatch_queue_t ClaudeUsageRefreshQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create(
            "com.terminaldb.app.claude-usage-refresh",
            DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}
static NSTimeInterval const ClaudeUsageForecastMinimumSpan = 15.0 * 60.0;
static NSTimeInterval const ClaudeUsageForecastLookback = 60.0 * 60.0;
static NSTimeInterval const ClaudeUsageHistoryRetention =
    8.0 * 24.0 * 60.0 * 60.0;
static NSUInteger const ClaudeUsageForecastMinimumSamples = 3;

static double ClaudeUsageClampedPercent(double percent) {
    if (!isfinite(percent)) return 0;
    return MIN(100.0, MAX(0.0, percent));
}

static BOOL ClaudeUsageViewContainsText(NSView *view, NSString *text) {
    if (view.hidden) return NO;
    NSString *value = nil;
    if ([view isKindOfClass:NSTextField.class]) {
        value = [(NSTextField *)view stringValue];
    } else if ([view isKindOfClass:NSButton.class]) {
        value = [(NSButton *)view title];
    }
    if (value != nil && [value rangeOfString:text].location != NSNotFound) return YES;
    for (NSView *subview in view.subviews) {
        if (ClaudeUsageViewContainsText(subview, text)) return YES;
    }
    return NO;
}

static NSButton *ClaudeUsageFindButton(NSView *view, NSString *title, NSString *identifier) {
    if ([view isKindOfClass:NSButton.class] && [[(NSButton *)view title] isEqual:title] && [view.identifier isEqual:identifier]) return (NSButton *)view;
    for (NSView *child in view.subviews) {
        NSButton *button = ClaudeUsageFindButton(child, title, identifier);
        if (button) return button;
    }
    return nil;
}

static BOOL ClaudeUsageViewContainsNestedScrollView(NSView *view) {
    for (NSView *subview in view.subviews) {
        if ([subview isKindOfClass:NSScrollView.class] ||
            ClaudeUsageViewContainsNestedScrollView(subview)) {
            return YES;
        }
    }
    return NO;
}

@interface ClaudeStatusBar (UsagePanelLayout)
- (void)usagePanelDidResize;
@end

@interface ClaudeUsageDocumentView : NSView
@property(nonatomic, weak) ClaudeStatusBar *statusBar;
@end

@implementation ClaudeUsageDocumentView
- (BOOL)isFlipped { return YES; }
- (void)layout {
    [super layout];
    [self.statusBar usagePanelDidResize];
}
@end

static NSStackView *ClaudeStack(NSArray<NSView *> *views, BOOL vertical, CGFloat spacing) {
    NSStackView *stack = [NSStackView stackViewWithViews:views];
    stack.orientation = vertical ? NSUserInterfaceLayoutOrientationVertical : NSUserInterfaceLayoutOrientationHorizontal;
    stack.alignment = vertical ? NSLayoutAttributeLeading : NSLayoutAttributeCenterY;
    stack.spacing = spacing;
    return stack;
}

static NSTextField *ClaudeAccountLabel(CGFloat size, NSFontWeight weight, NSColor *color) {
    NSTextField *label = [NSTextField wrappingLabelWithString:@""];
    label.font = [NSFont systemFontOfSize:size weight:weight];
    label.textColor = color;
    label.lineBreakMode = NSLineBreakByWordWrapping;
    [label setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    return label;
}

// Row objects and their action buttons survive account/usage publications.
// Only disclosure contents change when their rendered values actually change.
@interface ClaudeAccountRow : NSView
@property(nonatomic, strong) NSStackView *stack;
@property(nonatomic, strong) NSTextField *name;
@property(nonatomic, strong) NSTextField *identity;
@property(nonatomic, strong) NSTextField *availability;
@property(nonatomic, strong) NSTextField *summary;
@property(nonatomic, strong) NSTextField *selected;
@property(nonatomic, strong) NSButton *use;
@property(nonatomic, strong) NSButton *details;
@property(nonatomic, strong) NSView *primarySlot;
@property(nonatomic, strong) NSStackView *disclosure;
@property(nonatomic, strong) NSTextField *freshness;
@property(nonatomic, strong) NSTextField *usageDetails;
@property(nonatomic, strong) NSStackView *detailActions;
@property(nonatomic, strong) NSButton *share;
@property(nonatomic, strong) NSButton *remove;
@property(nonatomic, copy) NSArray *presentation;
@end

@implementation ClaudeAccountRow
- (instancetype)initWithTheme:(TerminalTheme *)theme target:(id)target identifier:(NSString *)identifier {
    self = [super initWithFrame:NSZeroRect];
    if (!self) return nil;
    self.identifier = identifier;
    _name = ClaudeAccountLabel(14, NSFontWeightSemibold, theme.terminalForeground);
    _name.maximumNumberOfLines = 1; _name.lineBreakMode = NSLineBreakByTruncatingTail;
    _identity = ClaudeAccountLabel(12, NSFontWeightRegular, theme.statusBarActiveForeground);
    _identity.maximumNumberOfLines = 1; _identity.lineBreakMode = NSLineBreakByTruncatingMiddle;
    _availability = ClaudeAccountLabel(12, NSFontWeightRegular, theme.statusBarActiveForeground);
    _summary = ClaudeAccountLabel(12, NSFontWeightRegular, theme.statusBarActiveForeground);
    _selected = ClaudeAccountLabel(12, NSFontWeightMedium, theme.statusBarActiveForeground);
    _selected.stringValue = @"Selected";
    _selected.alignment = NSTextAlignmentCenter;
    _use = [NSButton buttonWithTitle:@"Use" target:target action:@selector(selectProfileFromUsageCard:)];
    _use.identifier = identifier;
    _details = [NSButton buttonWithTitle:@"Details" target:target action:@selector(toggleUsageDetails:)];
    _details.identifier = identifier;
    NSStackView *identity = ClaudeStack(@[_name, _identity], YES, 4);
    [identity setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    for (NSView *view in identity.arrangedSubviews) [view.widthAnchor constraintEqualToAnchor:identity.widthAnchor].active = YES;
    NSView *heading = [[NSView alloc] initWithFrame:NSZeroRect];
    _primarySlot = [[NSView alloc] initWithFrame:NSZeroRect];
    [heading addSubview:identity]; [heading addSubview:_primarySlot]; [heading addSubview:_details];
    [_primarySlot addSubview:_selected]; [_primarySlot addSubview:_use];
    for (NSView *view in @[identity, _primarySlot, _details, _selected, _use]) view.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [heading.heightAnchor constraintGreaterThanOrEqualToConstant:36],
        [identity.leadingAnchor constraintEqualToAnchor:heading.leadingAnchor],
        [identity.trailingAnchor constraintEqualToAnchor:_primarySlot.leadingAnchor constant:-12],
        [identity.topAnchor constraintEqualToAnchor:heading.topAnchor],
        [identity.bottomAnchor constraintEqualToAnchor:heading.bottomAnchor],
        [_primarySlot.widthAnchor constraintEqualToConstant:96],
        [_primarySlot.heightAnchor constraintEqualToConstant:32],
        [_primarySlot.centerYAnchor constraintEqualToAnchor:heading.centerYAnchor],
        [_primarySlot.trailingAnchor constraintEqualToAnchor:_details.leadingAnchor constant:-12],
        [_details.trailingAnchor constraintEqualToAnchor:heading.trailingAnchor],
        [_details.widthAnchor constraintEqualToConstant:96],
        [_details.heightAnchor constraintEqualToConstant:32],
        [_details.centerYAnchor constraintEqualToAnchor:heading.centerYAnchor],
        [_use.leadingAnchor constraintEqualToAnchor:_primarySlot.leadingAnchor],
        [_use.trailingAnchor constraintEqualToAnchor:_primarySlot.trailingAnchor],
        [_use.topAnchor constraintEqualToAnchor:_primarySlot.topAnchor],
        [_use.bottomAnchor constraintEqualToAnchor:_primarySlot.bottomAnchor],
        [_selected.leadingAnchor constraintEqualToAnchor:_primarySlot.leadingAnchor],
        [_selected.trailingAnchor constraintEqualToAnchor:_primarySlot.trailingAnchor],
        [_selected.centerYAnchor constraintEqualToAnchor:_primarySlot.centerYAnchor],
    ]];
    _disclosure = ClaudeStack(@[], YES, 8);
    _freshness = ClaudeAccountLabel(12, NSFontWeightRegular, theme.statusBarActiveForeground);
    _usageDetails = ClaudeAccountLabel(12, NSFontWeightRegular, theme.terminalForeground);
    _share = [NSButton buttonWithTitle:@"Share Sign-In…" target:target action:@selector(shareSignInFromUsageCard:)];
    _share.identifier = identifier;
    _remove = [NSButton buttonWithTitle:@"Remove…" target:target action:@selector(removeProfileFromUsageCard:)];
    _remove.identifier = identifier;
    _detailActions = ClaudeStack(@[_share, _remove], NO, 12);
    for (NSView *view in @[_freshness, _usageDetails, _detailActions]) {
        [_disclosure addArrangedSubview:view];
        [view.widthAnchor constraintEqualToAnchor:_disclosure.widthAnchor].active = YES;
    }
    NSBox *separator = [[NSBox alloc] initWithFrame:NSZeroRect]; separator.boxType = NSBoxSeparator;
    _stack = ClaudeStack(@[heading, _availability, _summary, _disclosure, separator], YES, 8);
    _stack.edgeInsets = NSEdgeInsetsMake(16, 0, 16, 0);
    _stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_stack];
    [NSLayoutConstraint activateConstraints:@[
        [_stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_stack.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_stack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
    ]];
    for (NSView *view in _stack.arrangedSubviews) [view.widthAnchor constraintEqualToAnchor:_stack.widthAnchor].active = YES;
    [separator.heightAnchor constraintEqualToConstant:1].active = YES;
    return self;
}
@end

@interface ClaudeStatusBarInterfaceDelegate : NSObject <ClaudeStatusBarDelegate>
@property(nonatomic) NSUInteger claudeRequests;
@property(nonatomic) NSUInteger awsRequests;
@end

@implementation ClaudeStatusBarInterfaceDelegate
- (void)claudeStatusBar:(ClaudeStatusBar *)bar didSelectProfile:(ClaudeProfile *)profile { (void)bar; (void)profile; }
- (void)claudeStatusBarDidRequestAddProfile:(ClaudeStatusBar *)bar { (void)bar; }
- (void)claudeStatusBar:(ClaudeStatusBar *)bar didRequestLoginProfile:(ClaudeProfile *)profile { (void)bar; (void)profile; }
- (void)claudeStatusBar:(ClaudeStatusBar *)bar didRequestRemoveProfile:(ClaudeProfile *)profile { (void)bar; (void)profile; }
- (void)claudeStatusBarDidRequestUsagePanel:(ClaudeStatusBar *)bar { (void)bar; self.claudeRequests++; }
- (void)claudeStatusBarDidRequestAWSAccounts:(ClaudeStatusBar *)bar { (void)bar; self.awsRequests++; }
- (void)claudeStatusBar:(ClaudeStatusBar *)bar didRequestSharedSignIn:(ClaudeProfile *)profile { (void)bar; (void)profile; }
- (void)claudeStatusBarDidRequestAccountSync:(ClaudeStatusBar *)bar { (void)bar; }
@end

@interface ClaudeStatusBar ()
@property(nonatomic, copy, nullable) NSString *claudeExecutable;
@property(nonatomic, strong) ClaudeProfileManager *profileManager;
@property(nonatomic, strong) TerminalTheme *theme;
@property(nonatomic, strong, readwrite, nullable) ClaudeProfile *selectedProfile;
@property(nonatomic, strong) NSTextField *profileLabel;
@property(nonatomic, strong) NSTextField *awsLabel;
@property(nonatomic, strong) NSTextField *directoryLabel;
@property(nonatomic, strong) NSTextField *modelLabel;
@property(nonatomic, strong) NSTextField *environmentLabel;
@property(nonatomic, strong) NSTextField *usageLabel;
@property(nonatomic, strong) NSTextField *pasteReceiptLabel;
@property(nonatomic, strong) NSButton *profileButton;
@property(nonatomic, strong) NSButton *awsButton;
@property(nonatomic, strong) NSButton *usageButton;
@property(nonatomic, copy) NSDictionary *awsStatus;
@property(nonatomic) BOOL embeddedAccountsView;
@property(nonatomic, strong) NSButton *usageDoneButton;
@property(nonatomic) BOOL accountSelectionPending;
@property(nonatomic, copy) NSString *pendingProfileIdentifier;
@property(nonatomic, copy) void (^pendingUsagePanelDismissHandler)(void);
@property(nonatomic) NSUInteger pasteReceiptGeneration;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, strong, nullable) NSDate *lastAccountRefresh;
@property(nonatomic, strong, nullable) NSDate *lastUsageRefreshAttempt;
@property(nonatomic, strong, nullable) NSDate *lastUsageDashboardRefreshAttempt;
@property(nonatomic, copy, nullable) NSString *usageRefreshError;
@property(nonatomic) BOOL accountRefreshInFlight;
@property(nonatomic) BOOL usageRefreshInFlight;
@property(nonatomic, readwrite) BOOL accountIsLoggedIn;
@property(nonatomic, readwrite) BOOL accountStatusKnown;
@property(nonatomic, copy) NSArray<NSDictionary *> *currentUsageForecasts;
@property(nonatomic, strong, readwrite, nullable) NSView *usagePanelView;
@property(nonatomic, strong, nullable) ClaudeUsageDocumentView *usageWindowDocumentView;
@property(nonatomic) BOOL usageDashboardRefreshInFlight;
@property(nonatomic) NSUInteger usageDashboardRefreshCompletedCount;
@property(nonatomic) NSUInteger usageDashboardRefreshTotalCount;
@property(nonatomic, copy) NSDictionary<NSString *, NSDictionary *> *usageDashboardResults;
@property(nonatomic, copy) NSDictionary *peerUsageEntries;
@property(nonatomic) CGFloat usageDashboardViewportWidth;
@property(nonatomic) BOOL usageDashboardResizeScheduled;
@property(nonatomic, strong) NSMutableSet<NSString *> *expandedUsageAccounts;
@property(nonatomic, strong) NSStackView *usageColumn;
@property(nonatomic, strong) NSStackView *usageRows;
@property(nonatomic, strong) NSStackView *usageFooter;
@property(nonatomic, strong) NSStackView *usageFooterLeading;
@property(nonatomic, strong) NSStackView *usageFooterTrailing;
@property(nonatomic, strong) NSTextField *usageHeading;
@property(nonatomic, strong) NSTextField *usageScope;
@property(nonatomic, strong) NSTextField *usageCount;
@property(nonatomic, strong) NSTextField *usageProgress;
@property(nonatomic, strong) NSTextField *usageWarning;
@property(nonatomic, strong) NSTextField *usageEmpty;
@property(nonatomic, strong) NSButton *usageRefreshButton;
@property(nonatomic, strong) NSLayoutConstraint *usageColumnWidth;
@property(nonatomic, strong) NSLayoutConstraint *usageColumnTop;
@property(nonatomic, strong) NSMutableDictionary<NSString *, ClaudeAccountRow *> *usageAccountRows;
@property(nonatomic, copy) NSArray *usagePresentation;
+ (nullable NSNumber *)nextResetTimestamp:(nullable NSNumber *)timestamp
                                   period:(NSTimeInterval)period
                                   rolled:(BOOL *)rolled;
+ (nullable NSDictionary *)usageForecastForSamples:(NSArray *)samples
                                         windowKey:(NSString *)windowKey
                                     currentWindow:(NSDictionary *)currentWindow
                                               now:(NSTimeInterval)now;
+ (NSString *)compactDurationFromSeconds:(NSTimeInterval)seconds;
+ (NSArray<NSDictionary *> *)usageHistoryAtPath:(NSString *)path
                                 recordingStatus:(NSDictionary *)status
                                 sourceModifiedAt:(nullable NSDate *)sourceModifiedAt;
+ (NSArray<NSDictionary *> *)forecastsForStatus:(NSDictionary *)status
                                        history:(NSArray *)history
                                            now:(NSTimeInterval)now;
+ (nullable NSDictionary *)usageStatusAtPaths:(NSArray<NSString *> *)paths
                              sourceModifiedAt:(NSDate *_Nullable *_Nullable)sourceModifiedAt;
+ (nullable NSDictionary *)usageSnapshotForProfile:(ClaudeProfile *)profile reload:(BOOL)reload;
- (NSDictionary *)usageDashboardEntryForProfile:(ClaudeProfile *)profile;
+ (nullable NSString *)refreshUsageCacheWithExecutable:(NSString *)executable
                                            environment:(NSDictionary *)environment
                                         statusCachePath:(NSString *)statusCachePath;
+ (NSDictionary *)accountRefreshResultWithExecutable:(NSString *)executable
                                          environment:(NSDictionary *)environment;
@end

@implementation ClaudeStatusBar
@synthesize usagePanelDismissHandler = _usagePanelDismissHandler;
@synthesize accountWorkstationName = _accountWorkstationName;

- (void)setAccountWorkstationName:(NSString *)name {
    if ([_accountWorkstationName isEqualToString:name]) return;
    _accountWorkstationName = [name copy];
    [self updateProfileLabel];
    [self updateAWSLabel];
    [self refreshUsageWindowContents];
}

- (void)setUsagePanelDismissHandler:(void (^)(void))handler {
    _usagePanelDismissHandler = [handler copy];
    [self refreshUsageWindowContents];
}

- (instancetype)initWithFrame:(NSRect)frame
             claudeExecutable:(NSString *)claudeExecutable
               profileManager:(ClaudeProfileManager *)profileManager
              selectedProfile:(ClaudeProfile *)selectedProfile
                        theme:(TerminalTheme *)theme {
    self = [super initWithFrame:frame];
    if (self == nil) return nil;

    _claudeExecutable = [claudeExecutable copy];
    _profileManager = profileManager;
    _selectedProfile = selectedProfile;
    _theme = theme;
    _currentUsageForecasts = @[];
    _usageDashboardResults = @{};
    self.wantsLayer = YES;
    self.layer.backgroundColor = theme.statusBarBackground.CGColor;

    _profileLabel = [NSTextField labelWithString:@""];
    _profileLabel.textColor = theme.statusBarActiveForeground;
    _profileLabel.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    _profileLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _profileLabel.maximumNumberOfLines = 1;
    _profileLabel.selectable = NO;
    [self addSubview:_profileLabel];

    _awsLabel = [NSTextField labelWithString:@"AWS · Checking…"];
    _awsLabel.textColor = theme.statusBarActiveForeground;
    _awsLabel.font = _profileLabel.font;
    _awsLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _awsLabel.maximumNumberOfLines = 1;
    _awsLabel.selectable = NO;
    [self addSubview:_awsLabel];

    _directoryLabel = [NSTextField labelWithString:@"~"];
    _directoryLabel.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    _directoryLabel.textColor = theme.ansiColors[6];
    _directoryLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    _directoryLabel.maximumNumberOfLines = 1;
    _directoryLabel.selectable = NO;
    _directoryLabel.toolTip = NSHomeDirectory();
    [_directoryLabel setAccessibilityLabel:@"Working directory"];
    [self addSubview:_directoryLabel];

    _modelLabel = [NSTextField labelWithString:@""];
    _modelLabel.font = _profileLabel.font;
    _modelLabel.textColor = theme.ansiColors[5];
    _modelLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _modelLabel.maximumNumberOfLines = 1;
    _modelLabel.selectable = NO;
    _modelLabel.hidden = YES;
    [_modelLabel setAccessibilityLabel:@"Claude model"];
    [self addSubview:_modelLabel];

    _environmentLabel = [NSTextField labelWithString:@"LOCAL"];
    _environmentLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    _environmentLabel.textColor = theme.ansiColors[6];
    _environmentLabel.alignment = NSTextAlignmentRight;
    _environmentLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _environmentLabel.maximumNumberOfLines = 1;
    _environmentLabel.toolTip =
        @"Environment context. Remote and production sessions receive "
         "stronger safety prompts.";
    [_environmentLabel setAccessibilityLabel:@"Local environment"];
    [self addSubview:_environmentLabel];

    _usageLabel = [NSTextField labelWithString:@"Usage  Select an account"];
    _usageLabel.font = _profileLabel.font;
    _usageLabel.textColor = theme.statusBarForeground;
    _usageLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _usageLabel.maximumNumberOfLines = 1;
    _usageLabel.alignment = NSTextAlignmentRight;
    [self addSubview:_usageLabel];

    _pasteReceiptLabel = [NSTextField labelWithString:@""];
    _pasteReceiptLabel.font = _profileLabel.font;
    _pasteReceiptLabel.textColor = theme.ansiColors[2];
    _pasteReceiptLabel.alignment = NSTextAlignmentCenter;
    _pasteReceiptLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _pasteReceiptLabel.maximumNumberOfLines = 1;
    _pasteReceiptLabel.selectable = NO;
    _pasteReceiptLabel.hidden = YES;
    [_pasteReceiptLabel setAccessibilityLabel:@"Paste receipt"];
    [self addSubview:_pasteReceiptLabel];
    _profileButton = [NSButton buttonWithTitle:@"" target:self action:@selector(showUsageWindow:)];
    _profileButton.bordered = NO;
    _profileButton.identifier = @"accounts-claude";
    [_profileButton setAccessibilityIdentifier:@"accounts-claude"];
    [_profileButton setAccessibilityLabel:@"Open Claude accounts"];
    [self addSubview:_profileButton];
    _awsButton = [NSButton buttonWithTitle:@"" target:self action:@selector(showAWSAccounts:)];
    _awsButton.bordered = NO;
    _awsButton.identifier = @"accounts-aws";
    [_awsButton setAccessibilityIdentifier:@"accounts-aws"];
    [self addSubview:_awsButton];
    _usageButton = [NSButton buttonWithTitle:@"" target:self action:@selector(showUsageWindow:)];
    _usageButton.bordered = NO;
    [_usageButton setAccessibilityLabel:@"Open Claude usage and account settings"];
    [self addSubview:_usageButton];
    [_profileLabel setAccessibilityElement:NO];
    [_awsLabel setAccessibilityElement:NO];
    [_usageLabel setAccessibilityElement:NO];
    [self setAccessibilityElement:NO];

    [self updateProfileLabel];
    [self applyAWSStatus:@{@"state": @"loading"}];
    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(profilesDidChange:)
               name:ClaudeProfilesDidChangeNotification
             object:profileManager];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(usageSnapshotDidChange:) name:ClaudeUsageSnapshotDidChange object:nil];
    return self;
}

- (void)dealloc {
    [self.timer invalidate];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    [self.theme.statusBarBorder setFill];
    NSRectFill(NSMakeRect(0, NSHeight(self.bounds) - 1, NSWidth(self.bounds), 1));
}

- (void)resetCursorRects {
    [super resetCursorRects];
    [self addCursorRect:self.profileButton.frame cursor:NSCursor.pointingHandCursor];
    [self addCursorRect:self.awsButton.frame cursor:NSCursor.pointingHandCursor];
    if (!self.usageButton.hidden) [self addCursorRect:self.usageButton.frame cursor:NSCursor.pointingHandCursor];
}

- (void)showAccountPicker:(id)sender { (void)sender; [self presentAccountPicker]; }

- (void)showAWSAccounts:(id)sender {
    (void)sender;
    [self.delegate claudeStatusBarDidRequestAWSAccounts:self];
}

- (void)applyAWSStatus:(NSDictionary *)snapshot {
    self.awsStatus = [snapshot copy] ?: @{};
    [self updateAWSLabel];
}

- (void)updateAWSLabel {
    NSDictionary *summary = [self.awsStatus[@"summary"] isKindOfClass:NSDictionary.class]
        ? self.awsStatus[@"summary"] : @{};
    NSString *state = [self.awsStatus[@"state"] isKindOfClass:NSString.class]
        ? self.awsStatus[@"state"] : @"loading";
    NSString *summaryState = [summary[@"state"] isKindOfClass:NSString.class] ? summary[@"state"] : @"";
    NSString *title = [summary[@"title"] isKindOfClass:NSString.class] ? summary[@"title"] : @"";
    NSString *detail = [summary[@"detail"] isKindOfClass:NSString.class] ? summary[@"detail"] : @"";
    // A cache or connection override may provide its own honest status. An
    // old Ready summary paired with a non-current envelope must not survive.
    BOOL currentFallback = title.length > 0 && ([summaryState isEqualToString:state] || [summaryState isEqualToString:@"disconnected"]);
    if (!currentFallback && [state isEqualToString:@"loading"]) {
        title = @"AWS · Checking…";
        detail = @"Waiting for AWS profile status.";
    } else if (!currentFallback && [state isEqualToString:@"stale"]) {
        title = @"AWS · Updating…";
        detail = @"The previous AWS status is out of date. Waiting for a current update.";
    } else if (!currentFallback && ![state isEqualToString:@"ready"]) {
        title = @"AWS · Unavailable";
        if (detail.length == 0) detail = @"AWS profile status is unavailable.";
    }
    if (title.length == 0) title = @"AWS";
    if (![title hasPrefix:@"AWS"]) title = [@"AWS · " stringByAppendingString:title];
    self.awsLabel.stringValue = title;
    NSUInteger attention = [summary[@"attentionCount"] isKindOfClass:NSNumber.class] ? [summary[@"attentionCount"] unsignedIntegerValue] : 0;
    self.awsLabel.textColor = attention > 0 && [state isEqualToString:@"ready"]
        ? self.theme.ansiColors[3] : self.theme.statusBarActiveForeground;
    NSString *scope = self.accountWorkstationName.length > 0 ? self.accountWorkstationName : @"This Mac";
    NSString *tooltip = [NSString stringWithFormat:@"AWS profiles on %@. %@%@", scope, detail,
        detail.length > 0 ? @" Open AWS accounts to manage profiles." : @"Open AWS accounts to manage profiles."];
    self.awsLabel.toolTip = tooltip;
    self.awsButton.toolTip = tooltip;
    [self.awsButton setAccessibilityLabel:[NSString stringWithFormat:@"Open AWS profiles on %@", scope]];
    [self.awsButton setAccessibilityValue:title];
    [self setNeedsLayout:YES];
}

- (NSMenu *)accountPickerMenu {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Claude accounts"];
    menu.autoenablesItems = NO;
    NSMenuItem *scope = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"For this tab on %@", self.accountWorkstationName ?: @"This Mac"] action:NULL keyEquivalent:@""];
    scope.enabled = NO; [menu addItem:scope];
    for (ClaudeProfile *profile in self.profileManager.profiles) {
        BOOL shared = profile.sharedAccountIdentifier.length > 0;
        BOOL pending = shared && profile.catalogOnly;
        BOOL expired = shared && profile.sharedExpiresAt <= NSDate.date.timeIntervalSince1970;
        BOOL signIn = profile.email.length == 0;
        NSString *title = profile.label;
        NSUInteger matchingNames = 0;
        for (ClaudeProfile *other in self.profileManager.profiles) if ([other.label localizedCaseInsensitiveCompare:profile.label] == NSOrderedSame) matchingNames++;
        if (matchingNames > 1 && profile.email.length > 0) title = [title stringByAppendingFormat:@" · %@", profile.email];
        if (pending) title = [title stringByAppendingString:@" — Waiting for Sync"];
        else if (expired) title = [title stringByAppendingString:@" — Renew"];
        else if (profile.catalogOnly || signIn) title = [title stringByAppendingString:@" — Sign In"];
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:@selector(selectProfileFromMenu:) keyEquivalent:@""];
        item.target = self; item.representedObject = profile.identifier;
        item.state = [profile.identifier isEqual:self.selectedProfile.identifier] ? NSControlStateValueOn : NSControlStateValueOff;
        item.enabled = !pending && !self.accountSelectionPending;
        item.toolTip = [NSString stringWithFormat:@"For this tab on %@", self.accountWorkstationName ?: @"This Mac"];
        [menu addItem:item];
    }
    if (self.profileManager.profiles.count > 0) [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *manage = [[NSMenuItem alloc] initWithTitle:@"Manage Accounts…" action:@selector(showUsageWindow:) keyEquivalent:@""];
    manage.target = self; [menu addItem:manage];
    NSMenuItem *add = [[NSMenuItem alloc] initWithTitle:@"Add Claude Account…" action:@selector(addProfileFromStatusMenu:) keyEquivalent:@""];
    add.target = self; [menu addItem:add];
    return menu;
}

- (void)presentAccountPicker {
    [[self accountPickerMenu] popUpMenuPositioningItem:nil atLocation:NSMakePoint(NSMinX(self.profileButton.frame), NSMaxY(self.profileButton.frame)) inView:self];
}

- (void)selectProfileFromMenu:(NSMenuItem *)sender {
    ClaudeProfile *profile = [self.profileManager profileWithIdentifier:sender.representedObject];
    if (!profile || self.accountSelectionPending) return;
    BOOL shared = profile.sharedAccountIdentifier.length > 0;
    if (profile.catalogOnly || (shared && profile.sharedExpiresAt <= NSDate.date.timeIntervalSince1970)) {
        [self.delegate claudeStatusBar:self didRequestSharedSignIn:profile];
    } else if (profile.email.length == 0) {
        [self.delegate claudeStatusBar:self didRequestLoginProfile:profile];
    } else {
        self.accountSelectionPending = YES;
        self.pendingProfileIdentifier = profile.identifier;
        self.pendingUsagePanelDismissHandler = self.usagePanelDismissHandler;
        [self updateProfileLabel];
        [self refreshUsageWindowContents];
        [self.delegate claudeStatusBar:self didSelectProfile:profile];
    }
}

- (void)accountSelectionDidComplete:(BOOL)accepted {
    void (^pendingDismiss)(void) = self.pendingUsagePanelDismissHandler;
    self.accountSelectionPending = NO;
    self.pendingProfileIdentifier = nil;
    self.pendingUsagePanelDismissHandler = nil;
    [self updateProfileLabel];
    [self refreshUsageWindowContents];
    // A reply belongs to the presentation that initiated selection. Closing
    // and reopening Accounts (or selecting from a menu with no panel) must not
    // let an old reply dismiss a newer surface or steal its focus.
    if (accepted && pendingDismiss && pendingDismiss == self.usagePanelDismissHandler) [self dismissUsagePanel:nil];
}

- (NSTextField *)usageWindowLabel:(NSString *)text
                             size:(CGFloat)size
                           weight:(NSFontWeight)weight
                            color:(NSColor *)color
                            frame:(NSRect)frame {
    NSTextField *label = [NSTextField wrappingLabelWithString:text ?: @""];
    label.font = [NSFont systemFontOfSize:size weight:weight];
    label.textColor = color;
    label.frame = frame;
    label.autoresizingMask = NSViewWidthSizable;
    label.selectable = YES;
    return label;
}

- (void)showUsageWindow:(id)sender {
    (void)sender;
    [self.delegate claudeStatusBarDidRequestUsagePanel:self];
}

- (NSView *)prepareUsagePanel {
    return [self prepareAccountsViewEmbedded:NO];
}

- (NSView *)prepareEmbeddedAccountsView {
    return [self prepareAccountsViewEmbedded:YES];
}

- (NSView *)prepareAccountsViewEmbedded:(BOOL)embedded {
    self.embeddedAccountsView = embedded;
    if (self.usagePanelView == nil) {
        ClaudeUsageDocumentView *content = [[ClaudeUsageDocumentView alloc]
            initWithFrame:NSMakeRect(0, 0, MAX(320, NSWidth(self.bounds)), 620)];
        content.statusBar = self;
        content.wantsLayer = YES;
        content.layer.backgroundColor =
            self.theme.terminalBackground.CGColor;
        content.autoresizingMask = NSViewWidthSizable;
        self.usageWindowDocumentView = content;
        self.usagePanelView = content;
    }
    [self refreshUsageWindowContents];
    return self.usagePanelView;
}

- (void)usagePanelDidResize {
    if (self.usagePanelView == nil || self.usageDashboardResizeScheduled) return;
    CGFloat width = NSWidth(self.usagePanelView.bounds);
    if (width <= 0 || fabs(width - self.usageDashboardViewportWidth) < 2.0) {
        return;
    }
    self.usageDashboardResizeScheduled = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        ClaudeStatusBar *strongSelf = weakSelf;
        if (strongSelf == nil) return;
        strongSelf.usageDashboardResizeScheduled = NO;
        [strongSelf refreshUsageWindowContents];
    });
}

- (void)dismissUsagePanel:(id)sender {
    (void)sender;
    if (self.usagePanelDismissHandler != nil) {
        self.usagePanelDismissHandler();
    }
}

- (void)didDismissUsagePanel {
    self.usagePanelDismissHandler = nil;
}

- (void)presentUsageWindow {
    [self showUsageWindow:nil];
}

- (void)refreshUsageDashboard {
    if (self.peerMode) { if (self.peerRefreshHandler) self.peerRefreshHandler(); return; }
    [self refreshUsageWindow:nil];
}

- (void)refreshUsageWindow:(id)sender {
    (void)sender;
    if (self.usageDashboardRefreshInFlight ||
        self.claudeExecutable.length == 0) {
        [self refreshUsageWindowContents];
        return;
    }
    NSArray<ClaudeProfile *> *profiles =
        [self.profileManager.profiles copy];
    if (profiles.count == 0) return;
    self.usageDashboardRefreshInFlight = YES;
    self.usageDashboardRefreshCompletedCount = 0;
    self.usageDashboardRefreshTotalCount = profiles.count;
    NSMutableDictionary<NSString *, NSDictionary *> *pendingResults =
        [self.usageDashboardResults mutableCopy];
    for (ClaudeProfile *profile in profiles) {
        NSMutableDictionary *pending =
            [pendingResults[profile.identifier] mutableCopy]
                ?: [NSMutableDictionary dictionary];
        pending[@"refresh_state"] = @"waiting";
        pendingResults[profile.identifier] = [pending copy];
    }
    self.usageDashboardResults = [pendingResults copy];
    [self refreshUsageWindowContents];
    NSString *executable = self.claudeExecutable;
    NSMutableArray<NSDictionary *> *requests = [NSMutableArray array];
    for (ClaudeProfile *profile in profiles) {
        if (profile.catalogOnly) continue;
        [requests addObject:@{
            @"profile" : profile,
            @"environment" : [self environmentForProfile:profile],
        }];
    }
    __weak typeof(self) weakSelf = self;
    dispatch_async(ClaudeUsageRefreshQueue(), ^{
        NSMutableDictionary<NSString *, NSDictionary *> *results =
            [NSMutableDictionary dictionary];
        for (NSDictionary *request in requests) {
            ClaudeProfile *profile = request[@"profile"];
            NSDictionary *environment = request[@"environment"];
            dispatch_sync(dispatch_get_main_queue(), ^{
                ClaudeStatusBar *strongSelf = weakSelf;
                if (strongSelf == nil) return;
                NSMutableDictionary *dashboardResults =
                    [strongSelf.usageDashboardResults mutableCopy];
                NSMutableDictionary *refreshing =
                    [dashboardResults[profile.identifier] mutableCopy]
                        ?: [NSMutableDictionary dictionary];
                refreshing[@"refresh_state"] = @"refreshing";
                dashboardResults[profile.identifier] = [refreshing copy];
                strongSelf.usageDashboardResults = [dashboardResults copy];
                [strongSelf refreshUsageWindowContents];
            });
            NSMutableDictionary *result = [[ClaudeStatusBar
                accountRefreshResultWithExecutable:executable
                                       environment:environment] mutableCopy];
            NSString *state = result[@"account_state"];
            if (![state isEqualToString:@"signed_out"]) {
                NSString *refreshError = [ClaudeStatusBar
                    refreshUsageCacheWithExecutable:executable
                                         environment:environment
                                      statusCachePath:profile.statusCachePath];
                if (refreshError.length > 0) {
                    result[@"refresh_error"] = refreshError;
                } else {
                    result[@"account_state"] = @"signed_in";
                    [result removeObjectForKey:@"status_error"];
                }
            }
            result[@"refresh_state"] = @"complete";
            results[profile.identifier] = [result copy];
            dispatch_sync(dispatch_get_main_queue(), ^{
                ClaudeStatusBar *strongSelf = weakSelf;
                if (strongSelf == nil) return;
                NSMutableDictionary *dashboardResults =
                    [strongSelf.usageDashboardResults mutableCopy];
                dashboardResults[profile.identifier] = [result copy];
                strongSelf.usageDashboardResults = [dashboardResults copy];
                strongSelf.usageDashboardRefreshCompletedCount += 1;
                if ([result[@"account_state"] isEqual:@"signed_in"] && result[@"refresh_error"] == nil) {
                    [ClaudeStatusBar usageSnapshotForProfile:profile reload:YES];
                }
                if ([result[@"account_state"] isEqual:@"signed_in"] || [result[@"account_state"] isEqual:@"signed_out"]) {
                    [strongSelf.profileManager recordSignInState:[result[@"account_state"] isEqual:@"signed_in"] forProfile:profile];
                }
                if ([strongSelf.selectedProfile.identifier
                        isEqualToString:profile.identifier]) {
                    NSString *state = result[@"account_state"];
                    strongSelf.accountStatusKnown =
                        ![state isEqualToString:@"unknown"];
                    strongSelf.accountIsLoggedIn =
                        [state isEqualToString:@"signed_in"];
                    strongSelf.usageRefreshError = result[@"refresh_error"]
                        ?: result[@"status_error"];
                }
                [strongSelf refreshUsageWindowContents];
            });
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            ClaudeStatusBar *strongSelf = weakSelf;
            if (strongSelf == nil) return;
            strongSelf.usageDashboardRefreshInFlight = NO;
            strongSelf.usageDashboardRefreshCompletedCount = profiles.count;
            strongSelf.usageDashboardResults = [results copy];
            NSString *selectedIdentifier =
                strongSelf.selectedProfile.identifier;
            NSDictionary *selectedResult = selectedIdentifier.length > 0
                ? strongSelf.usageDashboardResults[selectedIdentifier] : nil;
            NSString *selectedState = selectedResult[@"account_state"];
            if ([selectedState isEqualToString:@"signed_out"]) {
                strongSelf.accountStatusKnown = YES;
                strongSelf.accountIsLoggedIn = NO;
                strongSelf.usageRefreshError = @"Sign in to refresh this account’s usage.";
            } else if ([selectedState isEqualToString:@"signed_in"]) {
                strongSelf.accountStatusKnown = YES;
                strongSelf.accountIsLoggedIn = YES;
                strongSelf.usageRefreshError = selectedResult[@"refresh_error"];
            } else if (selectedResult != nil) {
                strongSelf.accountStatusKnown = NO;
                strongSelf.accountIsLoggedIn = NO;
                strongSelf.usageRefreshError = selectedResult[@"status_error"]
                    ?: selectedResult[@"refresh_error"];
            }
            [strongSelf refreshUsage];
            [strongSelf refreshUsageWindowContents];
        });
    });
}

- (void)prepareUsageColumn {
    if (self.usageColumn) return;
    self.usageHeading = ClaudeAccountLabel(20, NSFontWeightSemibold, self.theme.terminalForeground);
    self.usageHeading.stringValue = @"Claude Accounts";
    self.usageScope = ClaudeAccountLabel(12, NSFontWeightRegular, self.theme.statusBarActiveForeground);
    self.usageCount = ClaudeAccountLabel(12, NSFontWeightRegular, self.theme.statusBarActiveForeground);
    self.usageProgress = ClaudeAccountLabel(12, NSFontWeightMedium, self.theme.ansiColors[6]);
    [self.usageProgress setAccessibilityLabel:@"Account refresh progress"];
    self.usageWarning = ClaudeAccountLabel(12, NSFontWeightMedium, self.theme.ansiColors[3]);
    self.usageEmpty = ClaudeAccountLabel(13, NSFontWeightRegular, self.theme.statusBarActiveForeground);
    self.usageEmpty.stringValue = @"No Claude accounts yet. Add an account when you want to use Claude Code.\nClaude is optional; your terminal is ready to use.";
    self.usageRows = ClaudeStack(@[], YES, 0);
    self.usageAccountRows = [NSMutableDictionary dictionary];
    self.usageRefreshButton = [NSButton buttonWithTitle:@"Refresh Usage" target:self action:@selector(refreshUsageWindow:)];
    NSButton *add = [NSButton buttonWithTitle:@"Add Claude Account…" target:self action:@selector(addProfileFromStatusMenu:)];
    NSButton *sync = [NSButton buttonWithTitle:@"Sharing…" target:self action:@selector(showAccountSync:)];
    self.usageDoneButton = [NSButton buttonWithTitle:@"Done" target:self action:@selector(dismissUsagePanel:)];
    self.usageDoneButton.keyEquivalent = @"\e"; self.usageDoneButton.keyEquivalentModifierMask = 0;
    self.usageFooterLeading = ClaudeStack(@[self.usageRefreshButton, add], NO, 12);
    self.usageFooterTrailing = ClaudeStack(@[sync, self.usageDoneButton], NO, 12);
    self.usageFooter = ClaudeStack(@[self.usageFooterLeading, self.usageFooterTrailing], NO, 24);
    self.usageColumn = ClaudeStack(@[self.usageHeading, self.usageScope, self.usageCount,
        self.usageProgress, self.usageWarning, self.usageEmpty, self.usageRows, self.usageFooter], YES, 12);
    self.usageColumn.identifier = @"TerminalDBUsageColumn";
    self.usageColumn.translatesAutoresizingMaskIntoConstraints = NO;
    [self.usageWindowDocumentView addSubview:self.usageColumn];
    self.usageColumnWidth = [self.usageColumn.widthAnchor constraintEqualToConstant:592];
    self.usageColumnTop = [self.usageColumn.topAnchor constraintEqualToAnchor:self.usageWindowDocumentView.topAnchor constant:24];
    [NSLayoutConstraint activateConstraints:@[
        self.usageColumnWidth,
        [self.usageColumn.centerXAnchor constraintEqualToAnchor:self.usageWindowDocumentView.centerXAnchor],
        self.usageColumnTop,
    ]];
    for (NSView *view in self.usageColumn.arrangedSubviews) [view.widthAnchor constraintEqualToAnchor:self.usageColumn.widthAnchor].active = YES;
}

- (NSString *)freshnessForUsageEntry:(NSDictionary *)entry {
    NSString *state = entry[@"account_state"];
    NSString *refresh = entry[@"refresh_state"];
    if (self.usageDashboardRefreshInFlight && [refresh isEqual:@"refreshing"]) return @"Refreshing account status and usage…";
    if (self.usageDashboardRefreshInFlight && [refresh isEqual:@"waiting"]) return @"Waiting to refresh…";
    if ([state isEqual:@"signed_out"]) return @"Signed out · cached usage hidden";
    if ([entry[@"source_stale"] boolValue]) return @"Usage is too old to trust · stale snapshot hidden. Refresh to update.";
    NSString *error = entry[@"refresh_error"] ?: entry[@"status_error"];
    if (error.length > 0) return error;
    NSDate *modified = [entry[@"modified_at"] isKindOfClass:NSDate.class] ? entry[@"modified_at"] : nil;
    if (modified) {
        NSTimeInterval age = MAX(0, -modified.timeIntervalSinceNow);
        if (age < 60) return @"Updated just now";
        if (age < 3600) return [NSString stringWithFormat:@"Updated %lum ago", (unsigned long)floor(age / 60)];
        return [NSString stringWithFormat:@"Updated %luh ago", (unsigned long)floor(age / 3600)];
    }
    return @"Usage appears after Claude Code reports its allowances.";
}

- (NSString *)detailsForUsageForecasts:(NSArray<NSDictionary *> *)forecasts {
    NSMutableArray *lines = [NSMutableArray array];
    for (NSDictionary *forecast in forecasts) {
        NSString *reset = [ClaudeStatusBar compactResetDateTimeFromTimestamp:forecast[@"reset_at"]] ?: @"Unknown";
        NSString *burn = @"Collecting";
        NSString *available = @"—";
        if ([forecast[@"stale"] boolValue]) burn = @"Stale";
        else if ([forecast[@"ready"] boolValue]) {
            burn = [NSString stringWithFormat:@"+%.1f%%/hr", [forecast[@"rate_per_hour"] doubleValue]];
            if ([forecast[@"sustainable_rate_per_hour"] isKindOfClass:NSNumber.class]) available = [NSString stringWithFormat:@"+%.1f%%/hr", [forecast[@"sustainable_rate_per_hour"] doubleValue]];
        }
        NSString *risk = @"";
        if ([forecast[@"warning"] boolValue] && ![forecast[@"stale"] boolValue]) {
            NSTimeInterval eta = [forecast[@"eta_seconds"] doubleValue];
            risk = eta <= 1 ? @" · Allowance reached" : [NSString stringWithFormat:@" · May reach limit in %@", [ClaudeStatusBar compactDurationFromSeconds:eta]];
        }
        [lines addObject:[NSString stringWithFormat:@"%@ · %.0f%% used · Reset %@%@\nBurn %@ · Available pace %@", forecast[@"detail_label"] ?: @"Allowance", [forecast[@"percent"] doubleValue], reset, risk, burn, available]];
    }
    return [lines componentsJoinedByString:@"\n\n"];
}

- (void)refreshUsageWindowContents {
    ClaudeUsageDocumentView *document = self.usageWindowDocumentView;
    if (!document) return;
    [self prepareUsageColumn];
    CGFloat viewportWidth = MAX(320, NSWidth(document.bounds));
    CGFloat columnWidth = self.embeddedAccountsView
        ? MAX(0, viewportWidth - 32)
        : MIN(1040, MAX(0, viewportWidth - 48));
    self.usageDashboardViewportWidth = NSWidth(document.bounds);
    self.usageColumnWidth.constant = columnWidth;
    self.usageColumnTop.constant = self.embeddedAccountsView ? 12 : 24;
    self.usageFooter.orientation = columnWidth < 520 ? NSUserInterfaceLayoutOrientationVertical : NSUserInterfaceLayoutOrientationHorizontal;
    self.usageFooter.alignment = columnWidth < 520 ? NSLayoutAttributeLeading : NSLayoutAttributeCenterY;
    NSArray<ClaudeProfile *> *profiles = self.profileManager.profiles;
    NSString *count = [NSString stringWithFormat:@"%lu %@ available", (unsigned long)profiles.count, profiles.count == 1 ? @"account" : @"accounts"];
    self.usageHeading.hidden = self.embeddedAccountsView || self.usagePanelDismissHandler != nil;
    self.usageDoneButton.hidden = self.embeddedAccountsView;
    self.usageScope.stringValue = self.embeddedAccountsView
        ? [NSString stringWithFormat:@"For this terminal tab · %@", count]
        : [NSString stringWithFormat:@"For this tab on %@ · %@", self.accountWorkstationName ?: @"This Mac", count];
    self.usageCount.hidden = YES;
    self.usageEmpty.hidden = profiles.count > 0;
    self.usageProgress.hidden = !self.usageDashboardRefreshInFlight;
    self.usageProgress.stringValue = self.usageDashboardRefreshCompletedCount == 0
        ? [NSString stringWithFormat:@"Checking %lu profiles…", (unsigned long)self.usageDashboardRefreshTotalCount]
        : [NSString stringWithFormat:@"Refreshing accounts… %lu of %lu complete", (unsigned long)self.usageDashboardRefreshCompletedCount, (unsigned long)self.usageDashboardRefreshTotalCount];
    self.usageRefreshButton.title = self.usageDashboardRefreshInFlight ? @"Refreshing…" : @"Refresh Usage";
    self.usageRefreshButton.enabled = !self.usageDashboardRefreshInFlight && profiles.count > 0 && (self.peerMode || self.claudeExecutable.length > 0);
    NSMutableSet *wanted = [NSMutableSet set];
    NSDictionary *mostUrgent = nil;
    ClaudeProfile *urgentProfile = nil;
    for (NSUInteger index = 0; index < profiles.count; index++) {
        ClaudeProfile *profile = profiles[index];
        [wanted addObject:profile.identifier];
        NSDictionary *entry = [self usageDashboardEntryForProfile:profile];
        NSArray *forecasts = entry[@"forecasts"] ?: @[];
        for (NSDictionary *forecast in forecasts) if ([forecast[@"warning"] boolValue] && ![forecast[@"stale"] boolValue] && (!mostUrgent || [forecast[@"eta_seconds"] doubleValue] < [mostUrgent[@"eta_seconds"] doubleValue])) { mostUrgent = forecast; urgentProfile = profile; }
        ClaudeAccountRow *row = self.usageAccountRows[profile.identifier];
        BOOL newRow = row == nil;
        if (!row) {
            row = [[ClaudeAccountRow alloc] initWithTheme:self.theme target:self identifier:profile.identifier];
            self.usageAccountRows[profile.identifier] = row;
        }
        if (index >= self.usageRows.arrangedSubviews.count || self.usageRows.arrangedSubviews[index] != row) {
            if ([self.usageRows.arrangedSubviews containsObject:row]) [self.usageRows removeArrangedSubview:row];
            [self.usageRows insertArrangedSubview:row atIndex:MIN(index, self.usageRows.arrangedSubviews.count)];
        }
        if (newRow) [row.widthAnchor constraintEqualToAnchor:self.usageRows.widthAnchor].active = YES;
        BOOL shared = profile.sharedAccountIdentifier.length > 0;
        BOOL expired = shared && profile.sharedExpiresAt <= NSDate.date.timeIntervalSince1970;
        BOOL pending = shared && profile.catalogOnly;
        BOOL signedIn = [entry[@"account_state"] isEqual:@"signed_in"];
        BOOL signIn = !signedIn && ([entry[@"account_state"] isEqual:@"signed_out"] || profile.email.length == 0);
        BOOL active = [profile.identifier isEqual:self.selectedProfile.identifier];
        BOOL expanded = [self.expandedUsageAccounts containsObject:profile.identifier];
        NSString *identity = profile.email ?: @"";
        if (profile.subscriptionType.length > 0) identity = [identity stringByAppendingFormat:@"%@%@", identity.length > 0 ? @" · " : @"", profile.subscriptionType.capitalizedString];
        NSString *availability = pending ? @"Waiting for account sync" : expired ? @"Sign-in expired · Renew to update your approved Macs" : profile.catalogOnly ? @"Available on another Mac · Sign in here to share access" : signIn ? @"Sign-in needed" : signedIn ? [NSString stringWithFormat:@"Ready on %@", self.accountWorkstationName ?: @"This Mac"] : self.usageDashboardRefreshInFlight ? @"Checking sign-in…" : @"Sign-in status unavailable";
        NSMutableArray *usage = [NSMutableArray array];
        for (NSDictionary *forecast in forecasts) if (![forecast[@"stale"] boolValue]) [usage addObject:[NSString stringWithFormat:@"%@ %.0f%%", forecast[@"detail_label"] ?: @"Usage", [forecast[@"percent"] doubleValue]]];
        NSString *summary = [usage componentsJoinedByString:@" · "];
        NSString *freshness = [self freshnessForUsageEntry:entry];
        NSString *details = [self detailsForUsageForecasts:forecasts];
        NSString *action = pending ? @"Sharing…" : expired ? @"Renew…" : profile.catalogOnly || signIn ? @"Sign In…" : @"Use";
        if ([self.pendingProfileIdentifier isEqual:profile.identifier]) action = @"Switching…";
        NSArray *presentation = @[profile.label ?: @"", identity, availability, summary, freshness, details, action, @(active), @(expanded), @(shared), @(pending), @(profile.catalogOnly), @(self.accountSelectionPending)];
        if (![presentation isEqual:row.presentation]) {
            row.presentation = presentation;
            row.name.stringValue = profile.label;
            row.name.toolTip = profile.label;
            row.identity.stringValue = identity; row.identity.hidden = identity.length == 0;
            row.identity.toolTip = identity;
            row.availability.stringValue = availability;
            row.summary.stringValue = summary; row.summary.hidden = summary.length == 0 || expanded;
            row.selected.hidden = !active || pending || expired || signIn;
            row.use.hidden = active && !pending && !expired && !signIn;
            row.use.title = action;
            row.use.action = pending ? @selector(showAccountSync:) : profile.catalogOnly || expired ? @selector(shareSignInFromUsageCard:) : signIn ? @selector(signInProfileFromUsageCard:) : @selector(selectProfileFromUsageCard:);
            row.use.enabled = !self.accountSelectionPending;
            row.details.title = expanded ? @"Hide Details" : @"Details";
            [row.details setAccessibilityLabel:[NSString stringWithFormat:@"%@ details for %@", expanded ? @"Hide" : @"Show", profile.label]];
            row.disclosure.hidden = !expanded;
            row.freshness.stringValue = freshness;
            row.usageDetails.stringValue = details;
            row.usageDetails.hidden = details.length == 0;
            row.share.title = shared ? @"Sharing…" : @"Share Sign-In…";
            row.share.action = shared ? @selector(showAccountSync:) : @selector(shareSignInFromUsageCard:);
            row.remove.title = shared ? @"Remove Shared Sign-In…" : @"Remove from This Mac…";
            row.remove.enabled = !profile.catalogOnly;
        }
        row.detailActions.orientation = columnWidth < 420 ? NSUserInterfaceLayoutOrientationVertical : NSUserInterfaceLayoutOrientationHorizontal;
        row.detailActions.alignment = columnWidth < 420 ? NSLayoutAttributeLeading : NSLayoutAttributeCenterY;
    }
    for (NSString *identifier in [self.usageAccountRows.allKeys copy]) if (![wanted containsObject:identifier]) {
        ClaudeAccountRow *row = self.usageAccountRows[identifier];
        [self.usageRows removeArrangedSubview:row]; [row removeFromSuperview]; [self.usageAccountRows removeObjectForKey:identifier];
    }
    self.usageWarning.hidden = !mostUrgent || self.usageDashboardRefreshInFlight;
    if (mostUrgent) {
        NSTimeInterval eta = [mostUrgent[@"eta_seconds"] doubleValue];
        self.usageWarning.stringValue = eta <= 1 ? [NSString stringWithFormat:@"%@ has reached its %@ allowance.", urgentProfile.label, mostUrgent[@"label"]] : [NSString stringWithFormat:@"%@ may reach its %@ allowance in %@ at the current pace.", urgentProfile.label, mostUrgent[@"label"], [ClaudeStatusBar compactDurationFromSeconds:eta]];
    }
    [document layoutSubtreeIfNeeded];
    CGFloat height = ceil(self.usageColumn.fittingSize.height) + (self.embeddedAccountsView ? 24 : 48);
    if (fabs(NSHeight(document.frame) - height) > 1) [document setFrameSize:NSMakeSize(viewportWidth, height)];
}

- (void)selectProfileFromUsageCard:(NSButton *)sender {
    NSString *identifier = sender.identifier;
    ClaudeProfile *profile =
        [self.profileManager profileWithIdentifier:identifier];
    if (profile != nil) {
        if (self.accountSelectionPending) return;
        self.accountSelectionPending = YES;
        self.pendingProfileIdentifier = profile.identifier;
        self.pendingUsagePanelDismissHandler = self.usagePanelDismissHandler;
        [self updateProfileLabel];
        [self refreshUsageWindowContents];
        [self.delegate claudeStatusBar:self didSelectProfile:profile];
    }
}

- (void)signInProfileFromUsageCard:(NSButton *)sender {
    ClaudeProfile *profile =
        [self.profileManager profileWithIdentifier:sender.identifier];
    if (profile != nil) {
        [self.delegate claudeStatusBar:self didRequestLoginProfile:profile];
    }
}

- (void)toggleUsageDetails:(NSButton *)sender {
    if (self.expandedUsageAccounts == nil) self.expandedUsageAccounts = [NSMutableSet set];
    if ([self.expandedUsageAccounts containsObject:sender.identifier]) [self.expandedUsageAccounts removeObject:sender.identifier];
    else [self.expandedUsageAccounts addObject:sender.identifier];
    [self refreshUsageWindowContents];
}

- (void)shareSignInFromUsageCard:(NSButton *)sender {
    ClaudeProfile *profile = [self.profileManager profileWithIdentifier:sender.identifier];
    if (profile) [self.delegate claudeStatusBar:self didRequestSharedSignIn:profile];
}

- (void)showAccountSync:(id)sender {
    (void)sender;
    [self.delegate claudeStatusBarDidRequestAccountSync:self];
}

- (void)removeProfileFromUsageCard:(NSButton *)sender {
    ClaudeProfile *profile =
        [self.profileManager profileWithIdentifier:sender.identifier];
    if (profile != nil) {
        [self.delegate claudeStatusBar:self didRequestRemoveProfile:profile];
    }
}

- (void)addProfileFromStatusMenu:(id)sender {
    (void)sender;
    [self.delegate claudeStatusBarDidRequestAddProfile:self];
}

- (void)layout {
    [super layout];
    CGFloat inset = 12, gap = 12;
    CGFloat width = MAX(0, NSWidth(self.bounds) - inset * 2);
    CGFloat height = MAX(0, NSHeight(self.bounds) - 8);
    // Keep both providers discoverable before allocating space to directory,
    // usage, and model details. Their text can truncate; the provider names stay.
    CGFloat providerMinimum = MIN(width, 148);
    CGFloat connectionWidth = self.environmentLabel.stringValue.length > 0
        ? MIN(self.environmentLabel.intrinsicContentSize.width + 6, MAX(0, width - providerMinimum - gap * 2)) : 0;
    CGFloat providerBudget = MAX(0, width - (connectionWidth > 0 ? connectionWidth + gap : 0));
    CGFloat profileWidth = MIN(MAX(72, self.profileLabel.intrinsicContentSize.width + 8), MIN(260, providerBudget * 0.40));
    CGFloat awsWidth = MIN(MAX(72, self.awsLabel.intrinsicContentSize.width + 8), MIN(220, MAX(0, providerBudget - profileWidth - gap)));
    if (providerBudget < 300) {
        profileWidth = MAX(0, (providerBudget - gap) * 0.55);
        awsWidth = MAX(0, providerBudget - profileWidth - gap);
    }
    self.profileLabel.frame = NSMakeRect(inset, 4, profileWidth, height);
    self.profileButton.frame = self.profileLabel.frame;
    self.awsLabel.frame = NSMakeRect(inset + profileWidth + gap, 4, awsWidth, height);
    self.awsButton.frame = self.awsLabel.frame;
    CGFloat left = NSMaxX(self.awsLabel.frame) + gap;
    CGFloat right = NSWidth(self.bounds) - inset;
    self.environmentLabel.hidden = connectionWidth <= 0;
    self.environmentLabel.frame = NSMakeRect(right - connectionWidth, 4, connectionWidth, height);
    if (connectionWidth > 0) right -= connectionWidth + gap;
    BOOL receipt = !self.pasteReceiptLabel.hidden;
    BOOL showUsage = !receipt && width >= 640;
    CGFloat usageWidth = showUsage ? (width < 880 ? 64 : MIN(300, self.usageLabel.intrinsicContentSize.width + 8)) : 0;
    usageWidth = MIN(usageWidth, MAX(0, right - left - 80));
    self.usageLabel.hidden = usageWidth == 0 || width < 880;
    self.usageButton.hidden = usageWidth == 0;
    self.usageButton.title = width < 880 ? @"Usage" : @"";
    self.usageButton.font = [NSFont systemFontOfSize:12];
    self.usageButton.toolTip = self.usageLabel.toolTip ?: @"Open Claude usage and account settings";
    self.usageLabel.frame = NSMakeRect(right - usageWidth, 4, usageWidth, height);
    self.usageButton.frame = self.usageLabel.frame;
    if (usageWidth > 0) right -= usageWidth + gap;
    BOOL showModel = !receipt && width >= 1100 && self.modelLabel.stringValue.length > 0;
    CGFloat modelWidth = showModel ? MIN(180, self.modelLabel.intrinsicContentSize.width + 8) : 0;
    self.modelLabel.hidden = !showModel;
    self.modelLabel.frame = NSMakeRect(right - modelWidth, 4, modelWidth, height);
    if (modelWidth > 0) right -= modelWidth + gap;
    CGFloat detailWidth = MAX(0, right - left);
    self.directoryLabel.hidden = receipt || detailWidth < 48;
    self.directoryLabel.frame = NSMakeRect(left, 4, detailWidth, height);
    self.pasteReceiptLabel.frame = NSMakeRect(left, 4, detailWidth, height);
}

- (void)showPasteReceiptWithByteCount:(NSUInteger)byteCount
                            lineCount:(NSUInteger)lineCount {
    if (byteCount == 0) return;
    NSNumberFormatter *formatter = [[NSNumberFormatter alloc] init];
    formatter.numberStyle = NSNumberFormatterDecimalStyle;
    NSString *bytes = [formatter stringFromNumber:@(byteCount)]
        ?: [NSString stringWithFormat:@"%lu", (unsigned long)byteCount];
    NSString *lines = [formatter stringFromNumber:@(lineCount)]
        ?: [NSString stringWithFormat:@"%lu", (unsigned long)lineCount];
    self.pasteReceiptLabel.stringValue = [NSString stringWithFormat:
        @"✓ Pasted %@ bytes · %@ %@", bytes, lines,
        lineCount == 1 ? @"line" : @"lines"];
    self.pasteReceiptLabel.toolTip = [NSString stringWithFormat:
        @"TerminalDB sent all %@ bytes. Full-screen apps may display only "
         "part of a long prompt in their transcript.", bytes];
    self.pasteReceiptLabel.hidden = NO;
    [self setNeedsLayout:YES];
    [self.pasteReceiptLabel setAccessibilityValue:
        self.pasteReceiptLabel.stringValue];
    NSAccessibilityPostNotificationWithUserInfo(
        self.pasteReceiptLabel,
        NSAccessibilityAnnouncementRequestedNotification,
        @{
            NSAccessibilityAnnouncementKey :
                self.pasteReceiptLabel.stringValue,
            NSAccessibilityPriorityKey : @(NSAccessibilityPriorityMedium),
        });

    NSUInteger generation = ++self.pasteReceiptGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            ClaudeStatusBar *strongSelf = weakSelf;
            if (strongSelf == nil ||
                strongSelf.pasteReceiptGeneration != generation) {
                return;
            }
            strongSelf.pasteReceiptLabel.hidden = YES;
            [strongSelf setNeedsLayout:YES];
        });
}

- (NSDictionary *)peerUsagePresentation {
    NSMutableDictionary *entries = [NSMutableDictionary dictionary];
    for (ClaudeProfile *profile in self.profileManager.profiles) {
        NSMutableDictionary *entry = [[self usageDashboardEntryForProfile:profile] mutableCopy];
        [entry removeObjectForKey:@"profile"];
        NSDate *date = entry[@"modified_at"];
        if ([date isKindOfClass:NSDate.class]) entry[@"modified_at"] = @(date.timeIntervalSince1970);
        entries[profile.catalogIdentifier] = entry;
    }
    return @{@"entries": entries, @"label": self.usageLabel.stringValue ?: @"",
        @"loggedIn": @(self.accountIsLoggedIn), @"known": @(self.accountStatusKnown)};
}
- (void)applyPeerState:(NSDictionary *)state {
    if (!self.peerMode) return;
    ClaudeProfile *selected = [self.profileManager profileWithIdentifier:state[@"accountId"] ?: @""];
    NSDictionary *usage = state[@"usageState"] ?: @{};
    NSDictionary *entries = usage[@"entries"] ?: @{};
    BOOL changed = ![self.peerUsageEntries isEqual:entries] || ![(self.selectedProfile.identifier ?: @"") isEqual:(selected.identifier ?: @"")];
    self.selectedProfile = selected;
    self.peerUsageEntries = entries;
    self.accountIsLoggedIn = [usage[@"loggedIn"] boolValue];
    self.accountStatusKnown = [usage[@"known"] boolValue];
    self.usageLabel.stringValue = usage[@"label"] ?: @"Usage  Waiting for workstation";
    [self updateProfileLabel];
    [self setNeedsLayout:YES];
    if (changed) [self refreshUsageWindowContents];
}

- (void)startMonitoring {
    if (self.peerMode) return;
    [self refreshAccountIfNeeded:YES];
    [self refreshUsage];
    [self refreshUsageIfNeeded:YES];
    __weak typeof(self) weakSelf = self;
    self.timer = [NSTimer scheduledTimerWithTimeInterval:5.0 repeats:YES block:^(NSTimer *timer) {
        [weakSelf timerFired:timer];
    }];
}

- (void)refreshNow {
    if (self.peerMode) { if (self.peerRefreshHandler) self.peerRefreshHandler(); return; }
    self.lastAccountRefresh = nil;
    self.lastUsageRefreshAttempt = nil;
    [self refreshAccountIfNeeded:YES];
    [self refreshUsage];
    [self refreshUsageIfNeeded:YES];
}

- (void)selectProfile:(ClaudeProfile *)profile {
    if ((self.selectedProfile == nil && profile == nil) ||
        [self.selectedProfile.identifier isEqualToString:profile.identifier]) {
        [self updateProfileLabel];
        return;
    }
    self.selectedProfile = profile;
    self.lastAccountRefresh = nil;
    self.lastUsageRefreshAttempt = nil;
    self.accountRefreshInFlight = NO;
    self.usageRefreshInFlight = NO;
    self.usageRefreshError = nil;
    self.accountIsLoggedIn = NO;
    self.accountStatusKnown = NO;
    [self updateProfileLabel];
    [self refreshAccountIfNeeded:YES];
    [self refreshUsage];
    [self refreshUsageWindowContents];
}

- (void)showEnvironment:(NSString *)environment
                   host:(NSString *)host
                 detail:(NSString *)detail {
    NSString *source = [environment stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    NSString *key = source.uppercaseString;
    NSString *value = [key isEqual:@"LOCAL"] || [key isEqual:@"THIS MAC"] ? @"" : source;
    self.environmentLabel.stringValue = value;
    if ([key isEqual:@"PRODUCTION"]) self.environmentLabel.textColor = self.theme.ansiColors[1];
    else if ([key isEqual:@"STAGING"] || [key isEqual:@"REMOTE"] || [key isEqual:@"RECONNECTING"] || [key isEqual:@"UNREACHABLE"]) self.environmentLabel.textColor = self.theme.ansiColors[3];
    else self.environmentLabel.textColor = self.theme.statusBarActiveForeground;
    self.environmentLabel.toolTip = [NSString stringWithFormat:@"%@%@%@", source ?: @"", host.length > 0 ? [@" · " stringByAppendingString:host] : @"", detail.length > 0 ? [@" · " stringByAppendingString:detail] : @""];
    [self.environmentLabel setAccessibilityLabel:@"Session connection or environment"];
    [self.environmentLabel setAccessibilityValue:value];
    [self setNeedsLayout:YES];
}

- (void)showDirectory:(NSString *)directory model:(NSString *)model {
    NSString *absolute = directory.length > 0 ? directory : NSHomeDirectory();
    NSString *home = NSHomeDirectory();
    NSString *display = absolute;
    if ([absolute isEqualToString:home]) {
        display = @"~";
    } else if ([absolute hasPrefix:[home stringByAppendingString:@"/"]]) {
        display = [@"~" stringByAppendingString:
            [absolute substringFromIndex:home.length]];
    }
    self.directoryLabel.stringValue = display;
    self.directoryLabel.toolTip = absolute;
    [self.directoryLabel setAccessibilityValue:absolute];

    NSString *modelName = [model stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    self.modelLabel.stringValue = modelName.length > 0
        ? [@"Claude  " stringByAppendingString:modelName]
        : @"";
    self.modelLabel.toolTip = modelName.length > 0
        ? [NSString stringWithFormat:@"Active Claude model: %@", modelName]
        : nil;
    self.modelLabel.hidden = modelName.length == 0;
    [self.modelLabel setAccessibilityValue:modelName ?: @""];
    [self setNeedsLayout:YES];
}

- (void)timerFired:(NSTimer *)timer {
    (void)timer;
    [self refreshAccountIfNeeded:NO];
    [self refreshUsage];
    [self refreshUsageIfNeeded:NO];
}

- (void)profilesDidChange:(NSNotification *)notification {
    (void)notification;
    if (self.selectedProfile != nil) {
        ClaudeProfile *updated = [self.profileManager
            profileWithIdentifier:self.selectedProfile.identifier];
        self.selectedProfile = updated;
    }
    [self updateProfileLabel];
    [self refreshUsageWindowContents];
}

- (NSString *)displayTitleForProfile:(ClaudeProfile *)profile {
    return [NSString stringWithFormat:@"Claude · %@ ▾", profile.label];
}

- (void)updateProfileLabel {
    self.profileLabel.stringValue = self.accountSelectionPending ? @"Claude · Switching…" : self.selectedProfile ? [self displayTitleForProfile:self.selectedProfile] : @"Claude · Choose Account ▾";
    self.profileLabel.toolTip = [NSString stringWithFormat:@"Open Claude accounts for this tab on %@. Right-click to switch accounts quickly.", self.accountWorkstationName ?: @"This Mac"];
    self.profileButton.toolTip = self.profileLabel.toolTip;
    self.profileButton.menu = [self accountPickerMenu];
    [self.profileButton setAccessibilityLabel:self.selectedProfile
        ? [NSString stringWithFormat:@"Open Claude accounts. Current account: %@. For this tab on %@", self.selectedProfile.label, self.accountWorkstationName ?: @"This Mac"]
        : [NSString stringWithFormat:@"Open Claude accounts for this tab on %@", self.accountWorkstationName ?: @"This Mac"]];
    [self setNeedsLayout:YES];
}

- (NSDictionary<NSString *, NSString *> *)environmentForProfile:
    (ClaudeProfile *)profile {
    NSMutableDictionary *environment =
        [NSProcessInfo.processInfo.environment mutableCopy];
    environment[@"CLAUDE_CONFIG_DIR"] = profile.configDirectory;
    environment[@"TERMINALDB_SHARED_ACCOUNT_ID"] = profile.sharedAccountIdentifier ?: @"";
    environment[@"CLAUDE_SECURESTORAGE_CONFIG_DIR"] =
        profile.configDirectory;
    environment[@"TERMINALDB_CLAUDE_STATUS_FILE"] =
        profile.statusLineCachePath;
    return environment;
}

- (void)refreshAccountIfNeeded:(BOOL)force {
    if (self.peerMode) return;
    ClaudeProfile *profile = self.selectedProfile;
    if (profile == nil) return;
    if (profile.catalogOnly) { self.accountStatusKnown = NO; self.accountIsLoggedIn = NO; return; }
    if (profile.sharedAccountIdentifier.length > 0) {
        self.accountStatusKnown = YES;
        self.accountIsLoggedIn = profile.sharedExpiresAt > NSDate.date.timeIntervalSince1970;
        [self updateProfileLabel]; [self refreshUsage];
        return;
    }
    if (self.claudeExecutable.length == 0) {
        self.profileLabel.toolTip = @"Claude Code is not installed";
        return;
    }
    if (self.accountRefreshInFlight) return;
    NSTimeInterval interval = self.accountIsLoggedIn
        ? ClaudeAccountRefreshInterval
        : 5.0;
    if (!force && self.lastAccountRefresh != nil &&
        -self.lastAccountRefresh.timeIntervalSinceNow < interval) {
        return;
    }

    self.accountRefreshInFlight = YES;
    self.lastAccountRefresh = [NSDate date];
    NSString *profileID = profile.identifier;
    NSString *executable = self.claudeExecutable;
    NSDictionary *environment = [self environmentForProfile:profile];
    __weak typeof(self) weakSelf = self;
    dispatch_async(ClaudeUsageRefreshQueue(), ^{
        NSString *temporaryPath = [NSTemporaryDirectory()
            stringByAppendingPathComponent:[NSString stringWithFormat:
                @"terminaldb-claude-auth-%@.json", NSUUID.UUID.UUIDString]];
        [[NSFileManager defaultManager]
            createFileAtPath:temporaryPath
                    contents:nil
                  attributes:@{NSFilePosixPermissions : @0600}];
        NSFileHandle *output =
            [NSFileHandle fileHandleForWritingAtPath:temporaryPath];

        NSTask *task = [[NSTask alloc] init];
        task.executableURL = [NSURL fileURLWithPath:executable];
        task.arguments = @[@"auth", @"status", @"--json"];
        task.environment = environment;
        task.standardOutput = output;
        task.standardError = [NSFileHandle fileHandleWithNullDevice];

        NSError *launchError = nil;
        BOOL launched = [task launchAndReturnError:&launchError];
        if (launched) [task waitUntilExit];
        [output closeFile];
        NSData *data = launched
            ? [NSData dataWithContentsOfFile:temporaryPath]
            : nil;
        [[NSFileManager defaultManager] removeItemAtPath:temporaryPath
                                                  error:nil];
        NSDictionary *status = data.length > 0
            ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil]
            : nil;

        dispatch_async(dispatch_get_main_queue(), ^{
            ClaudeStatusBar *strongSelf = weakSelf;
            if (strongSelf == nil ||
                ![strongSelf.selectedProfile.identifier
                    isEqualToString:profileID]) {
                return;
            }
            strongSelf.accountRefreshInFlight = NO;
            [strongSelf applyAccountStatus:status launchError:launchError];
        });
    });
}

- (void)applyAccountStatus:(NSDictionary *)status
               launchError:(NSError *)launchError {
    ClaudeProfile *profile = self.selectedProfile;
    if (profile == nil) return;
    if (launchError != nil || status == nil) {
        self.accountStatusKnown = NO;
        NSMutableDictionary *results =
            [self.usageDashboardResults mutableCopy];
        results[profile.identifier] = @{
            @"account_state" : @"unknown",
            @"status_error" : @"Claude account status is unavailable.",
        };
        self.usageDashboardResults = results;
        self.profileLabel.toolTip = @"Claude account status unavailable";
        [self refreshUsage];
        [self refreshUsageWindowContents];
        return;
    }
    self.accountStatusKnown = YES;
    self.accountIsLoggedIn = [status[@"loggedIn"] boolValue];
    [self.profileManager recordSignInState:self.accountIsLoggedIn forProfile:profile];
    NSMutableDictionary *results =
        [self.usageDashboardResults mutableCopy];
    results[profile.identifier] = @{
        @"account_state" : self.accountIsLoggedIn
            ? @"signed_in" : @"signed_out",
    };
    self.usageDashboardResults = results;
    if (!self.accountIsLoggedIn) {
        self.profileLabel.toolTip =
            @"Not signed in. Use the Claude menu to sign in.";
        [self refreshUsage];
        [self refreshUsageWindowContents];
        return;
    }

    [self.profileManager markProfileReadyForInteractiveClaude:profile];
    NSString *email = [status[@"email"] isKindOfClass:NSString.class]
        ? status[@"email"] : nil;
    NSString *plan = [status[@"subscriptionType"] isKindOfClass:NSString.class]
        ? status[@"subscriptionType"] : nil;
    [self.profileManager updateProfile:profile
                                 email:email
                      subscriptionType:plan];
    self.profileLabel.toolTip = [NSString stringWithFormat:
        @"%@ is active in this TerminalDB window\nAuthenticated through %@",
        email ?: profile.label,
        [status[@"authMethod"] isKindOfClass:NSString.class]
            ? status[@"authMethod"] : @"Claude"];
    [self updateProfileLabel];
    [self refreshUsageWindowContents];
    [self refreshUsageIfNeeded:self.lastUsageRefreshAttempt == nil];
}

+ (NSArray<NSDictionary *> *)usageHistoryAtPath:(NSString *)path {
    NSData *data = [NSData dataWithContentsOfFile:path];
    id document = data.length > 0
        ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil]
        : nil;
    NSArray *samples = [document isKindOfClass:NSDictionary.class] &&
        [document[@"samples"] isKindOfClass:NSArray.class]
        ? document[@"samples"] : @[];
    NSMutableArray<NSDictionary *> *valid = [NSMutableArray array];
    for (id sample in samples) {
        if ([sample isKindOfClass:NSDictionary.class] &&
            [sample[@"recorded_at"] isKindOfClass:NSNumber.class] &&
            [sample[@"rate_limits"] isKindOfClass:NSDictionary.class]) {
            [valid addObject:sample];
        }
    }
    return valid;
}

+ (NSArray<NSDictionary *> *)usageHistoryAtPath:(NSString *)path
                                 recordingStatus:(NSDictionary *)status
                                 sourceModifiedAt:(NSDate *)sourceModifiedAt {
    NSArray<NSDictionary *> *history = [self usageHistoryAtPath:path];
    NSDictionary *limits = [status[@"rate_limits"]
        isKindOfClass:NSDictionary.class] ? status[@"rate_limits"] : nil;
    if (limits == nil) return history;

    NSMutableDictionary *recordedLimits = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"five_hour", @"seven_day", @"fable_five"]) {
        NSDictionary *window = [limits[key] isKindOfClass:NSDictionary.class]
            ? limits[key] : nil;
        NSNumber *percent = [window[@"used_percentage"]
            isKindOfClass:NSNumber.class] ? window[@"used_percentage"] : nil;
        if (percent == nil) continue;
        NSMutableDictionary *recordedWindow = [@{
            @"used_percentage" :
                @(ClaudeUsageClampedPercent(percent.doubleValue)),
        } mutableCopy];
        NSNumber *reset = [window[@"resets_at"] isKindOfClass:NSNumber.class]
            ? window[@"resets_at"] : nil;
        if (reset != nil) recordedWindow[@"resets_at"] = reset;
        recordedLimits[key] = recordedWindow;
    }
    if (recordedLimits.count == 0) return history;

    NSDictionary *metadata = [status[@"terminaldb"]
        isKindOfClass:NSDictionary.class] ? status[@"terminaldb"] : nil;
    NSNumber *fetchedAt = [metadata[@"fetched_at"] isKindOfClass:NSNumber.class]
        ? metadata[@"fetched_at"] : nil;
    NSTimeInterval recordedAt = fetchedAt != nil
        ? fetchedAt.doubleValue
        : (sourceModifiedAt != nil
            ? sourceModifiedAt.timeIntervalSince1970
            : NSDate.date.timeIntervalSince1970);
    if (!isfinite(recordedAt) || recordedAt <= 0) return history;

    NSDictionary *sample = @{
        @"recorded_at" : @(recordedAt),
        @"rate_limits" : recordedLimits,
    };
    NSTimeInterval cutoff = NSDate.date.timeIntervalSince1970 -
        ClaudeUsageHistoryRetention;
    NSMutableArray<NSDictionary *> *samples = [NSMutableArray array];
    for (NSDictionary *existing in history) {
        NSNumber *timestamp = existing[@"recorded_at"];
        if (timestamp.doubleValue >= cutoff) [samples addObject:existing];
    }
    [samples sortUsingComparator:^NSComparisonResult(
        NSDictionary *left, NSDictionary *right) {
        return [left[@"recorded_at"] compare:right[@"recorded_at"]];
    }];
    NSDictionary *last = samples.lastObject;
    NSTimeInterval lastTime = [last[@"recorded_at"] doubleValue];
    if (last != nil && fabs(lastTime - recordedAt) < 1.0) {
        if ([last[@"rate_limits"] isEqual:recordedLimits]) return history;
        [samples removeLastObject];
    }
    [samples addObject:sample];
    if (samples.count > 4096) {
        [samples removeObjectsInRange:
            NSMakeRange(0, samples.count - 4096)];
    }
    NSData *historyData = [NSJSONSerialization dataWithJSONObject:@{
        @"version" : @1,
        @"samples" : samples,
    } options:0 error:nil];
    if ([historyData writeToFile:path atomically:YES]) {
        [NSFileManager.defaultManager
            setAttributes:@{NSFilePosixPermissions : @0600}
            ofItemAtPath:path
            error:nil];
        return samples;
    }
    return history;
}

+ (NSDictionary *)usageForecastForSamples:(NSArray *)samples
                                 windowKey:(NSString *)windowKey
                             currentWindow:(NSDictionary *)currentWindow
                                       now:(NSTimeInterval)now {
    NSNumber *currentValue = [currentWindow[@"used_percentage"]
        isKindOfClass:NSNumber.class]
        ? currentWindow[@"used_percentage"] : nil;
    if (currentValue == nil) return nil;
    double currentPercent =
        ClaudeUsageClampedPercent(currentValue.doubleValue);
    NSNumber *resetValue = [currentWindow[@"resets_at"]
        isKindOfClass:NSNumber.class] ? currentWindow[@"resets_at"] : nil;
    double currentReset = resetValue.doubleValue;

    NSMutableDictionary *result = [@{
        @"key" : windowKey,
        @"percent" : @(currentPercent),
        @"ready" : @NO,
        @"warning" : @NO,
        @"stale" : @NO,
    } mutableCopy];
    if (resetValue != nil) result[@"reset_at"] = resetValue;

    NSMutableArray<NSDictionary *> *points = [NSMutableArray array];
    for (NSDictionary *sample in samples) {
        NSNumber *timestamp = [sample[@"recorded_at"]
            isKindOfClass:NSNumber.class] ? sample[@"recorded_at"] : nil;
        NSDictionary *limits = [sample[@"rate_limits"]
            isKindOfClass:NSDictionary.class] ? sample[@"rate_limits"] : nil;
        NSDictionary *window = [limits[windowKey]
            isKindOfClass:NSDictionary.class] ? limits[windowKey] : nil;
        NSNumber *percent = [window[@"used_percentage"]
            isKindOfClass:NSNumber.class] ? window[@"used_percentage"] : nil;
        if (timestamp == nil || percent == nil ||
            timestamp.doubleValue < now - ClaudeUsageForecastLookback ||
            timestamp.doubleValue > now + 60.0) {
            continue;
        }
        NSNumber *sampleReset = [window[@"resets_at"]
            isKindOfClass:NSNumber.class] ? window[@"resets_at"] : nil;
        if (resetValue != nil &&
            (sampleReset == nil ||
             fabs(sampleReset.doubleValue - currentReset) > 120.0)) {
            continue;
        }
        [points addObject:@{
            @"time" : timestamp,
            @"percent" :
                @(ClaudeUsageClampedPercent(percent.doubleValue)),
        }];
    }
    [points sortUsingComparator:^NSComparisonResult(
        NSDictionary *left, NSDictionary *right) {
        return [left[@"time"] compare:right[@"time"]];
    }];

    NSUInteger cycleStart = 0;
    for (NSUInteger index = 1; index < points.count; index++) {
        if ([points[index][@"percent"] doubleValue] + 0.5 <
            [points[index - 1][@"percent"] doubleValue]) {
            cycleStart = index;
        }
    }
    if (cycleStart > 0) {
        [points removeObjectsInRange:NSMakeRange(0, cycleStart)];
    }
    if (points.count == 0) return result;

    NSTimeInterval latestTime = [points.lastObject[@"time"] doubleValue];
    result[@"sample_count"] = @(points.count);
    result[@"sample_span"] = @(
        latestTime - [points.firstObject[@"time"] doubleValue]);
    if (now - latestTime > ClaudeUsageRefreshInterval * 2.0) {
        result[@"stale"] = @YES;
        return result;
    }
    if (currentPercent >= 100.0) {
        result[@"ready"] = @YES;
        result[@"warning"] = @YES;
        result[@"severity"] = @"critical";
        result[@"eta_seconds"] = @0;
        result[@"projected_at"] = @(now);
        return result;
    }
    NSTimeInterval span = [result[@"sample_span"] doubleValue];
    if (points.count < ClaudeUsageForecastMinimumSamples ||
        span < ClaudeUsageForecastMinimumSpan) {
        return result;
    }

    double meanTime = 0;
    double meanPercent = 0;
    NSTimeInterval origin = [points.firstObject[@"time"] doubleValue];
    for (NSDictionary *point in points) {
        meanTime += ([point[@"time"] doubleValue] - origin) / 3600.0;
        meanPercent += [point[@"percent"] doubleValue];
    }
    meanTime /= points.count;
    meanPercent /= points.count;
    double covariance = 0;
    double variance = 0;
    for (NSDictionary *point in points) {
        double x = ([point[@"time"] doubleValue] - origin) / 3600.0;
        double y = [point[@"percent"] doubleValue];
        covariance += (x - meanTime) * (y - meanPercent);
        variance += (x - meanTime) * (x - meanTime);
    }
    double rate = variance > 0 ? covariance / variance : 0;
    double movement = [points.lastObject[@"percent"] doubleValue] -
        [points.firstObject[@"percent"] doubleValue];
    if (!isfinite(rate) || rate < 0 || movement < 0.5) rate = 0;
    result[@"ready"] = @YES;
    result[@"rate_per_hour"] = @(rate);

    double remaining = MAX(0, 100.0 - currentPercent);
    if (resetValue != nil && currentReset > now) {
        double hoursToReset = (currentReset - now) / 3600.0;
        double sustainableRate = hoursToReset > 0
            ? remaining / hoursToReset : 0;
        result[@"sustainable_rate_per_hour"] = @(sustainableRate);
        if (rate > 0) {
            NSTimeInterval eta = remaining / rate * 3600.0;
            NSTimeInterval projectedAt = now + eta;
            result[@"eta_seconds"] = @(eta);
            result[@"projected_at"] = @(projectedAt);
            if (sustainableRate > 0) {
                result[@"pace_multiple"] = @(rate / sustainableRate);
            }
            BOOL warning = projectedAt < currentReset - 60.0;
            result[@"warning"] = @(warning);
            if (warning) {
                result[@"severity"] = eta <= 30.0 * 60.0
                    ? @"critical" : @"warning";
            }
        }
    }
    return result;
}

+ (NSArray<NSDictionary *> *)forecastsForStatus:(NSDictionary *)status
                                        history:(NSArray *)history
                                            now:(NSTimeInterval)now {
    NSDictionary *limits = [status[@"rate_limits"]
        isKindOfClass:NSDictionary.class] ? status[@"rate_limits"] : @{};
    NSArray<NSDictionary *> *definitions = @[
        @{@"key" : @"five_hour", @"label" : @"5h",
          @"detail_label" : @"5-HOUR"},
        @{@"key" : @"seven_day", @"label" : @"7d",
          @"detail_label" : @"7-DAY"},
        @{@"key" : @"fable_five", @"label" : @"Fable",
          @"detail_label" : @"FABLE"},
    ];
    NSMutableArray<NSDictionary *> *forecasts = [NSMutableArray array];
    for (NSDictionary *definition in definitions) {
        NSDictionary *window = [limits[definition[@"key"]]
            isKindOfClass:NSDictionary.class]
            ? limits[definition[@"key"]] : nil;
        if (window == nil) continue;
        NSDictionary *forecast = [ClaudeStatusBar
            usageForecastForSamples:history
                           windowKey:definition[@"key"]
                       currentWindow:window
                                 now:now];
        if (forecast == nil) continue;
        NSMutableDictionary *decorated = [forecast mutableCopy];
        decorated[@"label"] = definition[@"label"];
        decorated[@"detail_label"] = definition[@"detail_label"];
        [forecasts addObject:decorated];
    }
    return forecasts;
}

+ (nullable NSDictionary *)usageStatusAtPaths:(NSArray<NSString *> *)paths
                              sourceModifiedAt:(NSDate **)sourceModifiedAt {
    NSMutableArray<NSDictionary *> *candidates = [NSMutableArray array];
    for (NSString *candidate in paths) {
        NSData *candidateData = [NSData dataWithContentsOfFile:candidate];
        id candidateStatus = candidateData.length > 0
            ? [NSJSONSerialization JSONObjectWithData:candidateData
                                               options:0
                                                 error:nil]
            : nil;
        if (![candidateStatus isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *candidateLimits =
            [candidateStatus[@"rate_limits"] isKindOfClass:NSDictionary.class]
                ? candidateStatus[@"rate_limits"] : nil;
        if (![candidateLimits[@"five_hour"]
                isKindOfClass:NSDictionary.class] &&
            ![candidateLimits[@"seven_day"]
                isKindOfClass:NSDictionary.class] &&
            ![candidateLimits[@"fable_five"]
                isKindOfClass:NSDictionary.class]) {
            continue;
        }
        NSDate *modifiedAt = [NSFileManager.defaultManager
            attributesOfItemAtPath:candidate error:nil][NSFileModificationDate];
        [candidates addObject:@{
            @"status" : candidateStatus,
            @"modified_at" : modifiedAt ?: NSNull.null,
        }];
    }

    [candidates sortUsingComparator:^NSComparisonResult(
        NSDictionary *left, NSDictionary *right) {
        NSDate *leftDate = [left[@"modified_at"] isKindOfClass:NSDate.class]
            ? left[@"modified_at"] : nil;
        NSDate *rightDate = [right[@"modified_at"] isKindOfClass:NSDate.class]
            ? right[@"modified_at"] : nil;
        if (leftDate == nil && rightDate == nil) return NSOrderedSame;
        if (leftDate == nil) return NSOrderedDescending;
        if (rightDate == nil) return NSOrderedAscending;
        return [rightDate compare:leftDate];
    }];

    NSDictionary *newest = candidates.firstObject;
    NSDictionary *newestStatus = [newest[@"status"]
        isKindOfClass:NSDictionary.class] ? newest[@"status"] : nil;
    NSDate *latestModifiedAt = [newest[@"modified_at"]
        isKindOfClass:NSDate.class] ? newest[@"modified_at"] : nil;
    NSMutableDictionary *status = [newestStatus mutableCopy];
    NSMutableDictionary *mergedLimits = [NSMutableDictionary dictionary];
    NSDate *now = [NSDate date];
    for (NSString *key in @[@"five_hour", @"seven_day", @"fable_five"]) {
        for (NSUInteger index = 0; index < candidates.count; index++) {
            NSDictionary *candidate = candidates[index];
            NSDate *modifiedAt = [candidate[@"modified_at"]
                isKindOfClass:NSDate.class] ? candidate[@"modified_at"] : nil;
            // A missing window may fall back to the other Claude cache only
            // while that cache is still fresh. This keeps a partial `/usage`
            // response from making 5h, 7d, or Fable disappear without reviving
            // old percentages from a signed-out or dormant profile.
            if (index > 0 &&
                (modifiedAt == nil ||
                 [now timeIntervalSinceDate:modifiedAt] >
                     ClaudeUsageFreshnessInterval)) {
                continue;
            }
            NSDictionary *candidateStatus = [candidate[@"status"]
                isKindOfClass:NSDictionary.class] ? candidate[@"status"] : nil;
            NSDictionary *candidateLimits = [candidateStatus[@"rate_limits"]
                isKindOfClass:NSDictionary.class]
                ? candidateStatus[@"rate_limits"] : nil;
            NSDictionary *window = [candidateLimits[key]
                isKindOfClass:NSDictionary.class] ? candidateLimits[key] : nil;
            if (![window[@"used_percentage"] isKindOfClass:NSNumber.class]) {
                continue;
            }
            mergedLimits[key] = window;
            break;
        }
    }
    if (status != nil && mergedLimits.count > 0) {
        status[@"rate_limits"] = mergedLimits;
    } else {
        status = nil;
    }
    if (sourceModifiedAt != NULL) *sourceModifiedAt = latestModifiedAt;
    return status;
}

+ (nullable NSDictionary *)usageSnapshotForProfile:(ClaudeProfile *)profile reload:(BOOL)reload {
    if (profile.catalogOnly) return nil;
    // All callers and completions are on the main thread. Keep one outstanding
    // read per profile, even when several terminal sessions publish together.
    static NSMutableDictionary<NSString *, NSNumber *> *inFlight;
    if (inFlight == nil) inFlight = [NSMutableDictionary dictionary];
    NSString *key = profile.usageHistoryPath;
    NSDictionary *cached = [ClaudeUsageSnapshots() objectForKey:key];
    if (inFlight[key] != nil) {
        if (reload) inFlight[key] = @YES;
    } else if (reload || cached == nil ||
               NSProcessInfo.processInfo.systemUptime - [cached[@"checked_at"] doubleValue] >= ClaudeUsageSnapshotInterval) {
        inFlight[key] = @NO;
        NSArray *paths = @[profile.statusCachePath, profile.statusLineCachePath];
        dispatch_async(ClaudeUsageSnapshotQueue(), ^{
            NSDate *modifiedAt = nil;
            NSDictionary *status = [self usageStatusAtPaths:paths sourceModifiedAt:&modifiedAt];
            NSArray *forecasts = @[];
            if (status != nil && modifiedAt != nil && -modifiedAt.timeIntervalSinceNow <= ClaudeUsageFreshnessInterval) {
                NSArray *history = [self usageHistoryAtPath:key recordingStatus:status sourceModifiedAt:modifiedAt];
                forecasts = [self forecastsForStatus:status history:history now:NSDate.date.timeIntervalSince1970];
            }
            NSMutableDictionary *result = [@{@"forecasts": forecasts} mutableCopy];
            if (status != nil) result[@"status"] = status;
            if (modifiedAt != nil) result[@"modified_at"] = modifiedAt;
            NSDictionary *snapshot = [result copy];
            dispatch_async(dispatch_get_main_queue(), ^{
                BOOL needsReload = [inFlight[key] boolValue];
                [inFlight removeObjectForKey:key];
                if (needsReload) {
                    // A CLI refresh finished after this read was queued.
                    [self usageSnapshotForProfile:profile reload:YES];
                    return;
                }
                NSDictionary *previous = [ClaudeUsageSnapshots() objectForKey:key][@"snapshot"];
                [ClaudeUsageSnapshots() setObject:@{
                    @"checked_at": @(NSProcessInfo.processInfo.systemUptime),
                    @"snapshot": snapshot,
                } forKey:key];
                if (![previous isEqual:snapshot]) {
                    [NSNotificationCenter.defaultCenter postNotificationName:ClaudeUsageSnapshotDidChange object:key];
                }
            });
        });
    }
    return cached[@"snapshot"];
}

- (void)usageSnapshotDidChange:(NSNotification *)notification {
    if (self.peerMode) return;
    if ([self.selectedProfile.usageHistoryPath isEqual:notification.object]) [self refreshUsage];
    if (self.usagePanelView.window != nil) [self refreshUsageWindowContents];
}

- (NSDictionary *)usageDashboardEntryForProfile:(ClaudeProfile *)profile {
    if (profile.catalogOnly) return @{@"profile": profile, @"forecasts": @[], @"account_state": @"available_elsewhere", @"suppress_metrics": @YES};
    if (self.peerMode) {
        NSMutableDictionary *entry = [self.peerUsageEntries[profile.identifier] mutableCopy] ?: [NSMutableDictionary dictionary];
        entry[@"profile"] = profile;
        if ([entry[@"modified_at"] isKindOfClass:NSNumber.class]) entry[@"modified_at"] = [NSDate dateWithTimeIntervalSince1970:[entry[@"modified_at"] doubleValue]];
        return entry;
    }
    NSDictionary *refreshResult =
        self.usageDashboardResults[profile.identifier];
    NSString *accountState = [refreshResult[@"account_state"]
        isKindOfClass:NSString.class] ? refreshResult[@"account_state"] : @"unknown";
    if (profile.sharedAccountIdentifier.length > 0) accountState = profile.sharedExpiresAt > NSDate.date.timeIntervalSince1970 ? @"signed_in" : @"signed_out";
    NSString *refreshError = [refreshResult[@"refresh_error"]
        isKindOfClass:NSString.class] ? refreshResult[@"refresh_error"] : nil;
    NSString *statusError = [refreshResult[@"status_error"]
        isKindOfClass:NSString.class] ? refreshResult[@"status_error"] : nil;
    BOOL signedOut = [accountState isEqualToString:@"signed_out"];
    BOOL accountCheckFailed = refreshResult != nil &&
        [accountState isEqualToString:@"unknown"] &&
        statusError.length > 0;
    NSDictionary *snapshot = signedOut || accountCheckFailed ? nil
        : [ClaudeStatusBar usageSnapshotForProfile:profile reload:NO];
    NSDate *modifiedAt = snapshot[@"modified_at"];
    BOOL sourceStale = snapshot[@"status"] != nil &&
        (modifiedAt == nil || -modifiedAt.timeIntervalSinceNow > ClaudeUsageFreshnessInterval);
    BOOL suppressMetrics = snapshot[@"status"] == nil || sourceStale;
    NSMutableDictionary *entry = [@{
        @"profile" : profile,
        @"forecasts" : suppressMetrics ? @[] : snapshot[@"forecasts"],
        @"account_state" : accountState,
        @"source_stale" : @(sourceStale),
        @"suppress_metrics" : @(suppressMetrics),
    } mutableCopy];
    if (refreshError.length > 0) entry[@"refresh_error"] = refreshError;
    if (statusError.length > 0) entry[@"status_error"] = statusError;
    if (modifiedAt != nil) entry[@"modified_at"] = modifiedAt;
    NSString *refreshState = [refreshResult[@"refresh_state"]
        isKindOfClass:NSString.class] ? refreshResult[@"refresh_state"] : nil;
    if (refreshState.length > 0) entry[@"refresh_state"] = refreshState;
    return entry;
}

- (void)refreshUsage {
    if (self.peerMode) return;
    ClaudeProfile *profile = self.selectedProfile;
    if (profile == nil) {
        self.currentUsageForecasts = @[];
        self.usageLabel.stringValue = @"Usage  Select or add an account";
        self.usageLabel.textColor = self.theme.statusBarForeground;
        return;
    }

    if (!self.accountStatusKnown) {
        self.currentUsageForecasts = @[];
        self.usageLabel.stringValue = self.accountRefreshInFlight
            ? @"Usage  Checking account…"
            : @"Usage  Account status unavailable";
        self.usageLabel.textColor = self.theme.statusBarForeground;
        self.usageLabel.toolTip = self.accountRefreshInFlight
            ? @"Checking whether this Claude account is signed in."
            : @"TerminalDB could not verify this Claude account, so cached percentages are hidden.";
        return;
    }

    if (!self.accountIsLoggedIn) {
        self.currentUsageForecasts = @[];
        self.usageLabel.stringValue = @"Usage  Sign in required";
        self.usageLabel.textColor = self.theme.statusBarForeground;
        self.usageLabel.toolTip =
            @"Sign in to this Claude account to refresh its usage. Cached percentages are hidden.";
        return;
    }
    NSDictionary *snapshot = [ClaudeStatusBar usageSnapshotForProfile:profile reload:NO];
    NSDate *sourceModifiedAt = snapshot[@"modified_at"];
    NSDictionary *status = snapshot[@"status"];
    BOOL sourceIsStale = sourceModifiedAt == nil ||
        -sourceModifiedAt.timeIntervalSinceNow > ClaudeUsageFreshnessInterval;
    if (status != nil && sourceIsStale) {
        self.currentUsageForecasts = @[];
        self.usageLabel.stringValue = self.usageRefreshInFlight
            ? @"Usage  Refreshing…" : @"Usage  Refresh required";
        self.usageLabel.textColor = self.theme.statusBarForeground;
        self.usageLabel.toolTip = self.usageRefreshError.length > 0
            ? [NSString stringWithFormat:
                @"%@\nThe last usage snapshot is too old to trust, so cached percentages are hidden.",
                self.usageRefreshError]
            : @"The last usage snapshot is too old to trust, so cached percentages are hidden.";
        return;
    }
    if (status == nil) {
        self.currentUsageForecasts = @[];
        self.usageLabel.stringValue = self.usageRefreshInFlight || (snapshot == nil && !profile.catalogOnly)
            ? @"Usage  Refreshing…" : @"Usage  Unavailable";
        self.usageLabel.textColor = self.theme.statusBarForeground;
        self.usageLabel.toolTip = self.usageRefreshError.length > 0
            ? self.usageRefreshError
            : @"Current Claude Code usage is not available yet.";
        return;
    }

    self.currentUsageForecasts = snapshot[@"forecasts"];

    NSDictionary *limits = [status[@"rate_limits"] isKindOfClass:NSDictionary.class]
        ? status[@"rate_limits"] : nil;
    NSDictionary *fiveHour = [limits[@"five_hour"] isKindOfClass:NSDictionary.class]
        ? limits[@"five_hour"] : nil;
    NSDictionary *sevenDay = [limits[@"seven_day"] isKindOfClass:NSDictionary.class]
        ? limits[@"seven_day"] : nil;
    NSDictionary *fableWeekly =
        [limits[@"fable_five"] isKindOfClass:NSDictionary.class]
            ? limits[@"fable_five"] : nil;
    NSNumber *fivePercent = [fiveHour[@"used_percentage"] isKindOfClass:NSNumber.class]
        ? fiveHour[@"used_percentage"] : nil;
    NSNumber *weekPercent = [sevenDay[@"used_percentage"] isKindOfClass:NSNumber.class]
        ? sevenDay[@"used_percentage"] : nil;
    NSNumber *fablePercent =
        [fableWeekly[@"used_percentage"] isKindOfClass:NSNumber.class]
            ? fableWeekly[@"used_percentage"] : nil;

    if (fivePercent == nil && weekPercent == nil && fablePercent == nil) {
        self.currentUsageForecasts = @[];
        self.usageLabel.stringValue = @"Usage  Waiting for Claude response";
        self.usageLabel.textColor = self.theme.statusBarForeground;
        return;
    }

    NSMutableAttributedString *styled = [[NSMutableAttributedString alloc] init];
    NSDictionary *muted = @{
        NSFontAttributeName : self.usageLabel.font,
        NSForegroundColorAttributeName : self.theme.statusBarActiveForeground,
    };
    [styled appendAttributedString:[[NSAttributedString alloc]
        initWithString:@"Usage  "
            attributes:muted]];
    if (fivePercent != nil) {
        [styled appendAttributedString:
            [self usageSegment:@"5h" percent:fivePercent.doubleValue]];
    }
    if (weekPercent != nil) {
        if (fivePercent != nil) {
            [styled appendAttributedString:[[NSAttributedString alloc]
                initWithString:@" · " attributes:muted]];
        }
        [styled appendAttributedString:
            [self usageSegment:@"7d" percent:weekPercent.doubleValue]];
    }
    if (fablePercent != nil) {
        if (fivePercent != nil || weekPercent != nil) {
            [styled appendAttributedString:[[NSAttributedString alloc]
                initWithString:@" · " attributes:muted]];
        }
        [styled appendAttributedString:[self usageSegment:@"Fable"
                                                 percent:fablePercent.doubleValue]];
    }
    NSDictionary *urgent = nil;
    for (NSDictionary *forecast in self.currentUsageForecasts) {
        if (![forecast[@"warning"] boolValue] ||
            [forecast[@"stale"] boolValue]) {
            continue;
        }
        if (urgent == nil ||
            [forecast[@"eta_seconds"] doubleValue] <
                [urgent[@"eta_seconds"] doubleValue]) {
            urgent = forecast;
        }
    }
    if (urgent != nil) {
        [styled appendAttributedString:[[NSAttributedString alloc]
            initWithString:@" · " attributes:muted]];
        BOOL critical = [urgent[@"severity"] isEqualToString:@"critical"];
        NSTimeInterval eta = [urgent[@"eta_seconds"] doubleValue];
        NSString *forecastText = eta <= 1.0
            ? [NSString stringWithFormat:@"⚠ %@ limit reached",
                urgent[@"label"]]
            : [NSString stringWithFormat:@"⚠ %@ ~%@",
                urgent[@"label"],
                [ClaudeStatusBar compactDurationFromSeconds:eta]];
        [styled appendAttributedString:[[NSAttributedString alloc]
            initWithString:forecastText
                attributes:@{
                    NSFontAttributeName : self.usageLabel.font,
                    NSForegroundColorAttributeName : critical
                        ? self.theme.ansiColors[1]
                        : self.theme.ansiColors[3],
                }]];
    }
    self.usageLabel.attributedStringValue = styled;
    [self setNeedsLayout:YES];

    NSMutableArray<NSString *> *details = [NSMutableArray array];
    [self appendResetDescription:@"5-hour" window:fiveHour to:details];
    [self appendResetDescription:@"7-day" window:sevenDay to:details];
    [self appendResetDescription:@"Fable 5 weekly"
                          window:fableWeekly
                              to:details];
    for (NSDictionary *forecast in self.currentUsageForecasts) {
        if (![forecast[@"warning"] boolValue] ||
            [forecast[@"stale"] boolValue]) {
            continue;
        }
        NSTimeInterval eta = [forecast[@"eta_seconds"] doubleValue];
        double rate = [forecast[@"rate_per_hour"] doubleValue];
        NSString *projected = [ClaudeStatusBar
            compactDateTimeFromTimestamp:forecast[@"projected_at"]];
        [details addObject:eta <= 1.0
            ? [NSString stringWithFormat:@"%@ allowance is exhausted",
                forecast[@"label"]]
            : [NSString stringWithFormat:
                @"%@ pace is +%.1f%%/hr; limit estimated in %@%@",
                forecast[@"label"], rate,
                [ClaudeStatusBar compactDurationFromSeconds:eta],
                projected.length > 0
                    ? [NSString stringWithFormat:@" (%@)", projected] : @""]];
    }
    NSDate *updated = sourceModifiedAt;
    if (updated != nil) {
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        formatter.timeStyle = NSDateFormatterShortStyle;
        formatter.dateStyle = NSDateFormatterNoStyle;
        [details addObject:[NSString stringWithFormat:@"Updated %@",
            [formatter stringFromDate:updated]]];
    }
    if (self.usageRefreshError.length > 0) {
        [details addObject:self.usageRefreshError];
    }
    [details addObject:@"Refreshes every 5 minutes"];
    self.usageLabel.toolTip = [details componentsJoinedByString:@"\n"];
}

+ (NSDictionary *)accountRefreshResultWithExecutable:(NSString *)executable
                                          environment:(NSDictionary *)environment {
    if ([environment[@"TERMINALDB_SHARED_ACCOUNT_ID"] length] > 0) {
        NSString *identifier = environment[@"TERMINALDB_SHARED_ACCOUNT_ID"];
        for (NSDictionary *item in [TDBSharedAccounts catalog]) {
            if ([item[@"id"] isEqual:identifier]) return @{@"account_state": [item[@"ready"] boolValue] ? @"signed_in" : @"signed_out"};
        }
        return @{@"account_state": @"signed_out"};
    }
    NSString *temporaryPath = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[NSString stringWithFormat:
            @"terminaldb-claude-auth-%@.json", NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager
        createFileAtPath:temporaryPath
                contents:nil
              attributes:@{NSFilePosixPermissions : @0600}];
    NSFileHandle *output =
        [NSFileHandle fileHandleForWritingAtPath:temporaryPath];
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:executable];
    task.arguments = @[@"auth", @"status", @"--json"];
    task.environment = environment;
    task.standardOutput = output;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];

    NSError *launchError = nil;
    BOOL launched = [task launchAndReturnError:&launchError];
    BOOL timedOut = NO;
    if (launched) {
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10.0];
        while (task.running && [deadline timeIntervalSinceNow] > 0) {
            [NSThread sleepForTimeInterval:0.05];
        }
        if (task.running) {
            timedOut = YES;
            [task terminate];
        }
        [task waitUntilExit];
    }
    [output closeFile];
    NSData *data = launched && !timedOut
        ? [NSData dataWithContentsOfFile:temporaryPath] : nil;
    [NSFileManager.defaultManager removeItemAtPath:temporaryPath error:nil];
    NSDictionary *status = data.length > 0
        ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil]
        : nil;
    if (launchError != nil || !launched) {
        return @{
            @"account_state" : @"unknown",
            @"status_error" : @"Claude Code could not be launched to check sign-in status.",
        };
    }
    if (timedOut) {
        return @{
            @"account_state" : @"unknown",
            @"status_error" : @"Claude account status check timed out.",
        };
    }
    if (![status isKindOfClass:NSDictionary.class]) {
        return @{
            @"account_state" : @"unknown",
            @"status_error" : @"Claude account status could not be read.",
        };
    }
    return @{
        @"account_state" : [status[@"loggedIn"] boolValue]
            ? @"signed_in" : @"signed_out",
    };
}

+ (nullable NSString *)refreshUsageCacheWithExecutable:(NSString *)executable
                                            environment:(NSDictionary *)environment
                                         statusCachePath:(NSString *)statusCachePath {
    NSString *temporaryPath = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[NSString stringWithFormat:
            @"terminaldb-claude-usage-%@.json", NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager
        createFileAtPath:temporaryPath
                contents:nil
              attributes:@{NSFilePosixPermissions : @0600}];
    NSFileHandle *output =
        [NSFileHandle fileHandleForWritingAtPath:temporaryPath];

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:executable];
    task.arguments = @[
        @"-p", @"/usage", @"--output-format", @"json", @"--max-turns", @"1",
    ];
    ClaudeConfigureSharedTask(task, executable, task.arguments, environment);
    NSMutableDictionary *taskEnvironment = [environment mutableCopy];
    taskEnvironment[@"LANG"] = @"en_US.UTF-8";
    taskEnvironment[@"LC_ALL"] = @"en_US.UTF-8";
    task.environment = taskEnvironment;
    task.standardOutput = output;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];

    NSError *launchError = nil;
    BOOL launched = [task launchAndReturnError:&launchError];
    BOOL timedOut = NO;
    if (launched) {
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:20.0];
        while (task.running && [deadline timeIntervalSinceNow] > 0) {
            [NSThread sleepForTimeInterval:0.05];
        }
        if (task.running) {
            timedOut = YES;
            [task terminate];
        }
        [task waitUntilExit];
    }
    [output closeFile];

    NSData *data = launched && !timedOut
        ? [NSData dataWithContentsOfFile:temporaryPath] : nil;
    [NSFileManager.defaultManager removeItemAtPath:temporaryPath error:nil];
    NSDictionary *envelope = data.length > 0
        ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSString *result = [envelope[@"result"] isKindOfClass:NSString.class]
        ? envelope[@"result"] : nil;
    NSDictionary *normalized =
        [ClaudeStatusBar normalizedStatusFromUsageCommandResult:result];
    BOOL wroteCache = NO;
    if (normalized != nil) {
        NSData *normalizedData = [NSJSONSerialization
            dataWithJSONObject:normalized options:0 error:nil];
        wroteCache = [normalizedData writeToFile:statusCachePath atomically:YES];
        if (wroteCache) {
            [NSFileManager.defaultManager
                setAttributes:@{NSFilePosixPermissions : @0600}
                ofItemAtPath:statusCachePath
                error:nil];
        }
    }
    if (launchError != nil || !launched) {
        return @"Claude Code could not be launched to refresh usage.";
    }
    if (timedOut) {
        return @"Claude Code usage refresh timed out.";
    }
    if (task.terminationStatus != 0 || !wroteCache) {
        return @"Claude Code did not return current usage.";
    }
    return nil;
}

- (void)refreshUsageIfNeeded:(BOOL)force {
    ClaudeProfile *profile = self.selectedProfile;
    if (profile == nil || !self.accountIsLoggedIn) return;
    if (self.claudeExecutable.length == 0) {
        self.usageRefreshError =
            @"Install Claude Code to refresh subscription usage.";
        [self refreshUsage];
        return;
    }
    if (self.usageRefreshInFlight) return;
    if (!force && self.lastUsageRefreshAttempt != nil &&
        -self.lastUsageRefreshAttempt.timeIntervalSinceNow <
            ClaudeUsageRefreshInterval) {
        return;
    }

    self.usageRefreshInFlight = YES;
    self.usageRefreshError = nil;
    self.lastUsageRefreshAttempt = [NSDate date];
    if (![[NSFileManager defaultManager]
            fileExistsAtPath:profile.statusCachePath]) {
        self.usageLabel.stringValue = @"Usage  Refreshing…";
        self.usageLabel.textColor = self.theme.statusBarForeground;
    }

    NSString *profileID = profile.identifier;
    NSString *statusCachePath = profile.statusCachePath;
    NSString *executable = self.claudeExecutable;
    NSDictionary *environment = [self environmentForProfile:profile];
    __weak typeof(self) weakSelf = self;
    dispatch_async(ClaudeUsageRefreshQueue(), ^{
        NSString *refreshError = [ClaudeStatusBar
            refreshUsageCacheWithExecutable:executable
                                 environment:environment
                              statusCachePath:statusCachePath];
        dispatch_async(dispatch_get_main_queue(), ^{
            ClaudeStatusBar *strongSelf = weakSelf;
            if (strongSelf == nil ||
                ![strongSelf.selectedProfile.identifier
                    isEqualToString:profileID]) {
                return;
            }
            strongSelf.usageRefreshInFlight = NO;
            strongSelf.usageRefreshError = refreshError;
            if (refreshError == nil) [ClaudeStatusBar usageSnapshotForProfile:profile reload:YES];
            [strongSelf refreshUsage];
            [strongSelf refreshUsageWindowContents];
        });
    });
}

+ (nullable NSDictionary *)normalizedStatusFromUsageCommandResult:
    (nullable NSString *)result {
    if (![result isKindOfClass:NSString.class] || result.length == 0) {
        return nil;
    }

    NSArray<NSDictionary<NSString *, NSString *> *> *windows = @[
        @{@"prefix" : @"Current session:",
          @"key" : @"five_hour"},
        @{@"prefix" : @"Current week (all models):",
          @"key" : @"seven_day"},
        @{@"prefix" : @"Current week (Fable):",
          @"key" : @"fable_five"},
    ];
    NSRegularExpression *percentExpression = [NSRegularExpression
        regularExpressionWithPattern:
            @"([0-9]+(?:\\.[0-9]+)?)%\\s+used"
                             options:NSRegularExpressionCaseInsensitive
                               error:nil];
    NSRegularExpression *resetExpression = [NSRegularExpression
        regularExpressionWithPattern:
            @"(?:·|-)\\s*resets\\s+(.+?)\\s+\\(([^)]+)\\)\\s*$"
                             options:NSRegularExpressionCaseInsensitive
                               error:nil];
    NSMutableDictionary *limits = [NSMutableDictionary dictionary];
    NSArray<NSString *> *lines =
        [result componentsSeparatedByCharactersInSet:
            NSCharacterSet.newlineCharacterSet];
    for (NSString *line in lines) {
        NSDictionary<NSString *, NSString *> *definition = nil;
        for (NSDictionary<NSString *, NSString *> *candidate in windows) {
            if ([line rangeOfString:candidate[@"prefix"]
                            options:NSCaseInsensitiveSearch].location !=
                NSNotFound) {
                definition = candidate;
                break;
            }
        }
        if (definition == nil) continue;

        NSTextCheckingResult *percentMatch =
            [percentExpression firstMatchInString:line
                                          options:0
                                            range:NSMakeRange(0, line.length)];
        if (percentMatch.numberOfRanges < 2) continue;
        double percent =
            [[line substringWithRange:[percentMatch rangeAtIndex:1]] doubleValue];
        NSMutableDictionary *window = [@{
            @"used_percentage" :
                @(ClaudeUsageClampedPercent(percent)),
        } mutableCopy];
        NSTextCheckingResult *resetMatch =
            [resetExpression firstMatchInString:line
                                        options:0
                                          range:NSMakeRange(0, line.length)];
        if (resetMatch.numberOfRanges >= 3) {
            NSString *dateText =
                [line substringWithRange:[resetMatch rangeAtIndex:1]];
            NSString *timeZoneName =
                [line substringWithRange:[resetMatch rangeAtIndex:2]];
            NSNumber *reset = [self
                timestampFromUsageCommandDate:dateText
                                 timeZoneName:timeZoneName];
            if (reset != nil) window[@"resets_at"] = reset;
        }
        if ([definition[@"key"] isEqualToString:@"fable_five"]) {
            window[@"display_name"] = @"Fable";
        }
        limits[definition[@"key"]] = window;
    }
    if (limits.count == 0) return nil;
    return @{
        @"rate_limits" : limits,
        @"terminaldb" : @{
            @"source" : @"claude_code_usage_command",
            @"fetched_at" : @([NSDate date].timeIntervalSince1970),
        },
    };
}

+ (nullable NSNumber *)timestampFromUsageCommandDate:(NSString *)dateText
                                        timeZoneName:(NSString *)timeZoneName {
    if (dateText.length == 0) return nil;
    NSTimeZone *timeZone = [NSTimeZone timeZoneWithName:timeZoneName]
        ?: NSTimeZone.localTimeZone;
    NSCalendar *calendar =
        [[NSCalendar alloc] initWithCalendarIdentifier:
            NSCalendarIdentifierGregorian];
    calendar.timeZone = timeZone;
    NSInteger currentYear =
        [calendar component:NSCalendarUnitYear fromDate:[NSDate date]];
    NSArray<NSString *> *formats = @[
        @"MMM d 'at' h:mma yyyy",
        @"MMM d 'at' ha yyyy",
    ];
    for (NSInteger yearOffset = 0; yearOffset <= 1; yearOffset++) {
        for (NSString *format in formats) {
            NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
            formatter.locale =
                [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
            formatter.timeZone = timeZone;
            formatter.dateFormat = format;
            NSDate *date = [formatter dateFromString:[NSString stringWithFormat:
                @"%@ %ld", dateText, (long)(currentYear + yearOffset)]];
            if (date != nil && date.timeIntervalSinceNow > -60.0) {
                return @(date.timeIntervalSince1970);
            }
        }
    }
    return nil;
}

+ (nullable NSDictionary *)normalizedStatusFromUsage:
    (nullable NSDictionary *)usage {
    if (![usage isKindOfClass:NSDictionary.class]) return nil;

    NSMutableDictionary *limits = [NSMutableDictionary dictionary];
    for (NSString *windowName in @[@"five_hour", @"seven_day"]) {
        NSDictionary *window =
            [usage[windowName] isKindOfClass:NSDictionary.class]
                ? usage[windowName]
                : nil;
        NSNumber *utilization =
            [window[@"utilization"] isKindOfClass:NSNumber.class]
                ? window[@"utilization"]
                : nil;
        if (utilization == nil) continue;

        NSMutableDictionary *normalizedWindow =
            [@{@"used_percentage" :
                @(ClaudeUsageClampedPercent(utilization.doubleValue))}
                mutableCopy];
        NSNumber *resetTimestamp =
            [self timestampFromUsageResetValue:window[@"resets_at"]];
        if (resetTimestamp != nil) {
            normalizedWindow[@"resets_at"] = resetTimestamp;
        }
        limits[windowName] = normalizedWindow;
    }
    NSArray *dynamicLimits =
        [usage[@"limits"] isKindOfClass:NSArray.class]
            ? usage[@"limits"]
            : @[];
    for (NSDictionary *limit in dynamicLimits) {
        if (![limit isKindOfClass:NSDictionary.class] ||
            ![limit[@"kind"] isEqualToString:@"weekly_scoped"]) {
            continue;
        }
        NSDictionary *scope =
            [limit[@"scope"] isKindOfClass:NSDictionary.class]
                ? limit[@"scope"] : nil;
        NSDictionary *model =
            [scope[@"model"] isKindOfClass:NSDictionary.class]
                ? scope[@"model"] : nil;
        NSString *displayName =
            [model[@"display_name"] isKindOfClass:NSString.class]
                ? model[@"display_name"] : nil;
        if ([displayName rangeOfString:@"fable"
                               options:NSCaseInsensitiveSearch].location ==
            NSNotFound) {
            continue;
        }
        NSNumber *percent =
            [limit[@"percent"] isKindOfClass:NSNumber.class]
                ? limit[@"percent"] : nil;
        if (percent == nil) continue;

        NSMutableDictionary *normalizedWindow =
            [@{@"used_percentage" :
                   @(ClaudeUsageClampedPercent(percent.doubleValue)),
               @"display_name" : @"Fable 5"} mutableCopy];
        NSNumber *resetTimestamp =
            [self timestampFromUsageResetValue:limit[@"resets_at"]];
        if (resetTimestamp != nil) {
            normalizedWindow[@"resets_at"] = resetTimestamp;
        }
        limits[@"fable_five"] = normalizedWindow;
        break;
    }
    if (limits.count == 0) return nil;
    return @{
        @"rate_limits" : limits,
        @"terminaldb" : @{
            @"source" : @"anthropic_oauth_usage",
            @"fetched_at" : @([NSDate date].timeIntervalSince1970),
        },
    };
}

+ (BOOL)runInterfaceSelfTests {
    ClaudeProfile *first = [[ClaudeProfile alloc] init];
    [first setValue:@"interface-first" forKey:@"identifier"];
    [first setValue:@"A very long account label that must not crowd out the connection" forKey:@"label"];
    [first setValue:@"first@example.invalid" forKey:@"email"];
    ClaudeProfile *second = [[ClaudeProfile alloc] init];
    [second setValue:@"interface-second" forKey:@"identifier"];
    [second setValue:@"Work" forKey:@"label"];
    [second setValue:@"work.with.a.long.alias@department.example.invalid" forKey:@"email"];
    ClaudeProfileManager *manager = [ClaudeProfileManager managerForPeerDisplay];
    [manager setValue:@[first, second] forKey:@"profiles"];
    ClaudeStatusBar *bar = [[ClaudeStatusBar alloc] initWithFrame:NSMakeRect(0, 0, 640, 30) claudeExecutable:nil profileManager:manager selectedProfile:first theme:TerminalTheme.preferredTheme];
    bar.peerMode = YES; bar.accountWorkstationName = @"Office Mac";
    NSDictionary *entries = @{first.identifier: @{@"account_state": @"signed_in", @"forecasts": @[]}, second.identifier: @{@"account_state": @"signed_in", @"forecasts": @[]}};
    NSDictionary *state = @{@"accountId": first.identifier, @"usageState": @{@"entries": entries, @"loggedIn": @YES, @"known": @YES, @"label": @"Usage  7d 34%"}};
    [bar applyPeerState:state];
    NSDictionary *aws = @{@"state": @"ready", @"updatedAt": @(NSDate.date.timeIntervalSince1970),
        @"summary": @{@"title": @"AWS · 12 ready", @"detail": @"Profiles are ready and renew automatically.",
                       @"state": @"ready", @"readyCount": @12, @"attentionCount": @0, @"configuredCount": @12}};
    [bar applyAWSStatus:aws];
    BOOL awsSummary = [bar.awsLabel.stringValue isEqual:@"AWS · 12 ready"] &&
        [bar.awsButton.toolTip containsString:@"Office Mac"] &&
        [bar.awsButton.accessibilityLabel containsString:@"Office Mac"] &&
        [bar.awsButton.accessibilityValue isEqual:bar.awsLabel.stringValue];
    ClaudeStatusBarInterfaceDelegate *delegate = [[ClaudeStatusBarInterfaceDelegate alloc] init];
    bar.delegate = delegate;
    [bar.profileButton performClick:nil]; [bar.awsButton performClick:nil];
    BOOL accountRouting = delegate.claudeRequests == 1 && delegate.awsRequests == 1 &&
        bar.profileButton.menu.itemArray.count == 6 &&
        [bar.profileButton.accessibilityLabel hasPrefix:@"Open Claude accounts"];
    bar.delegate = nil;
    [bar applyAWSStatus:@{@"state": @"loading", @"summary": aws[@"summary"]}];
    BOOL noStaleReady = [bar.awsLabel.stringValue isEqual:@"AWS · Checking…"];
    [bar applyAWSStatus:@{@"state": @"stale", @"summary": aws[@"summary"]}];
    noStaleReady &= [bar.awsLabel.stringValue isEqual:@"AWS · Updating…"];
    [bar applyAWSStatus:@{@"state": @"unavailable", @"summary": aws[@"summary"]}];
    noStaleReady &= [bar.awsLabel.stringValue isEqual:@"AWS · Unavailable"];
    [bar applyAWSStatus:@{@"state": @"unavailable", @"summary": @{@"title": @"AWS · Reconnecting", @"state": @"disconnected", @"detail": @"Waiting for the execution Mac."}}];
    noStaleReady &= [bar.awsLabel.stringValue isEqual:@"AWS · Reconnecting"] && [bar.awsButton.toolTip containsString:@"execution Mac"];
    [bar applyAWSStatus:aws];
    [bar showDirectory:@"/Projects/a/very/long/project/path" model:@"A long model name"];
    [bar showEnvironment:@"Reconnecting" host:@"Office Mac" detail:@"Check LAN or VPN"];
    BOOL geometry = YES;
    for (NSNumber *width in @[@320, @430, @640, @900, @1280]) {
        [bar setFrameSize:NSMakeSize(width.doubleValue, 30)]; [bar layoutSubtreeIfNeeded];
        NSArray *labels = @[bar.profileLabel, bar.awsLabel, bar.directoryLabel, bar.modelLabel, bar.environmentLabel, bar.usageLabel];
        for (NSUInteger i = 0; i < labels.count; i++) {
            NSView *a = labels[i]; if (a.hidden) continue;
            geometry &= NSMinX(a.frame) >= 0 && NSMaxX(a.frame) <= width.doubleValue && NSWidth(a.frame) >= 0;
            for (NSUInteger j = i + 1; j < labels.count; j++) {
                NSView *b = labels[j]; if (!b.hidden) geometry &= !NSIntersectsRect(a.frame, b.frame);
            }
        }
        geometry &= NSWidth(bar.environmentLabel.frame) >= bar.environmentLabel.intrinsicContentSize.width;
        geometry &= !bar.profileButton.hidden && !bar.awsButton.hidden && NSWidth(bar.profileButton.frame) >= 60 && NSWidth(bar.awsButton.frame) >= 48;
        geometry &= !NSIntersectsRect(bar.profileButton.frame, bar.awsButton.frame) &&
            !NSIntersectsRect(bar.awsButton.frame, bar.environmentLabel.frame);
    }
    [bar showPasteReceiptWithByteCount:8192 lineCount:12]; [bar layoutSubtreeIfNeeded];
    BOOL receipt = bar.directoryLabel.hidden && bar.modelLabel.hidden && bar.usageButton.hidden && !NSIntersectsRect(bar.pasteReceiptLabel.frame, bar.environmentLabel.frame);
    [bar showEnvironment:@"LOCAL" host:nil detail:nil]; [bar layoutSubtreeIfNeeded];
    BOOL noAmbiguousLocal = bar.environmentLabel.hidden;
    NSMenu *menu = [bar accountPickerMenu];
    BOOL scope = [menu.itemArray.firstObject.title containsString:@"Office Mac"] && menu.itemArray.count == 6;
    NSMenuItem *secondItem = menu.itemArray[2];
    [bar selectProfileFromMenu:secondItem];
    BOOL noOptimisticSelection = [bar.selectedProfile.identifier isEqual:first.identifier] && bar.accountSelectionPending;
    [bar accountSelectionDidComplete:NO];
    BOOL rejectedSelection = !bar.accountSelectionPending && [bar.selectedProfile.identifier isEqual:first.identifier];
    __block NSUInteger dismissed = 0;
    bar.usagePanelDismissHandler = ^{ dismissed++; };
    [bar selectProfileFromMenu:secondItem];
    [bar accountSelectionDidComplete:NO];
    [bar selectProfileFromMenu:secondItem];
    [bar accountSelectionDidComplete:YES];
    BOOL acceptedDismissalOnly = dismissed == 1;
    [bar selectProfileFromMenu:secondItem];
    [bar didDismissUsagePanel];
    __block NSUInteger reopenedDismissed = 0;
    bar.usagePanelDismissHandler = ^{ reopenedDismissed++; };
    [bar accountSelectionDidComplete:YES];
    BOOL preservesReopenedPanel = dismissed == 1 && reopenedDismissed == 0;
    [bar didDismissUsagePanel];
    [bar selectProfileFromMenu:secondItem];
    bar.usagePanelDismissHandler = ^{ reopenedDismissed++; };
    [bar accountSelectionDidComplete:YES];
    [bar accountSelectionDidComplete:YES];
    BOOL menuDoesNotDismissLaterPanel = reopenedDismissed == 0;
    [bar prepareUsagePanel];
    ClaudeAccountRow *row = bar.usageAccountRows[first.identifier];
    NSButton *button = row.use;
    [bar toggleUsageDetails:row.details];
    [bar applyPeerState:state];
    BOOL stableRows = bar.usageAccountRows[first.identifier] == row && row.use == button && !row.disclosure.hidden;
    BOOL accountColumns = YES;
    for (NSNumber *width in @[@640, @900, @1280]) {
        [bar.usagePanelView setFrameSize:NSMakeSize(width.doubleValue, 620)];
        [bar refreshUsageWindowContents];
        [bar.usagePanelView layoutSubtreeIfNeeded];
        CGFloat primaryX = NAN, detailsX = NAN;
        for (ClaudeProfile *profile in @[first, second]) {
            ClaudeAccountRow *accountRow = bar.usageAccountRows[profile.identifier];
            NSRect primary = [accountRow.primarySlot.superview convertRect:[accountRow.primarySlot alignmentRectForFrame:accountRow.primarySlot.frame] toView:bar.usagePanelView];
            NSRect details = [accountRow.details.superview convertRect:[accountRow.details alignmentRectForFrame:accountRow.details.frame] toView:bar.usagePanelView];
            NSRect name = [accountRow.name.superview convertRect:[accountRow.name alignmentRectForFrame:accountRow.name.frame] toView:bar.usagePanelView];
            NSRect identity = [accountRow.identity.superview convertRect:[accountRow.identity alignmentRectForFrame:accountRow.identity.frame] toView:bar.usagePanelView];
            accountColumns &= fabs(NSWidth(primary) - 96) < 1 && fabs(NSWidth(details) - 96) < 1;
            accountColumns &= NSWidth(name) >= 200 && NSWidth(identity) >= 200 && NSMaxX(name) <= NSMinX(primary) - 11 && NSMaxX(identity) <= NSMinX(primary) - 11;
            accountColumns &= NSMaxX(primary) <= NSMinX(details) - 11 && NSMaxX(details) <= width.doubleValue - 23;
            accountColumns &= [accountRow.use.identifier isEqual:profile.identifier] && [accountRow.details.identifier isEqual:profile.identifier];
            if (isfinite(primaryX)) accountColumns &= fabs(primary.origin.x - primaryX) < 1 && fabs(details.origin.x - detailsX) < 1;
            primaryX = primary.origin.x; detailsX = details.origin.x;
        }
        accountColumns &= row.use.hidden && !row.selected.hidden && !bar.usageAccountRows[second.identifier].use.hidden;
    }
    BOOL embeddedHeader = bar.usageHeading.hidden && bar.usageCount.hidden && [bar.usageScope.stringValue containsString:@"2 accounts available"];
    bar.usagePanelDismissHandler = nil;
    BOOL standaloneHeader = !bar.usageHeading.hidden;
    bar.usagePanelDismissHandler = ^{ reopenedDismissed++; };
    embeddedHeader &= bar.usageHeading.hidden;
    NSView *embeddedView = [bar prepareEmbeddedAccountsView];
    BOOL commonAccountsHeader = embeddedView == bar.usagePanelView && bar.usageHeading.hidden && bar.usageDoneButton.hidden &&
        [bar.usageScope.stringValue containsString:@"For this terminal tab"] &&
        [bar.usageScope.stringValue containsString:@"2 accounts available"] &&
        ![bar.usageScope.stringValue containsString:@"Office Mac"] && bar.usageAccountRows[first.identifier] == row;
    for (NSNumber *width in @[@520, @900]) {
        [embeddedView setFrameSize:NSMakeSize(width.doubleValue, 620)];
        [bar refreshUsageWindowContents]; [embeddedView layoutSubtreeIfNeeded];
        NSRect column = [bar.usageColumn convertRect:bar.usageColumn.bounds toView:embeddedView];
        commonAccountsHeader &= fabs(NSMinX(column) - 16) < 1 &&
            fabs(NSMaxX(column) - (width.doubleValue - 16)) < 1 && fabs(NSMinY(column) - 12) < 1;
    }
    [bar prepareUsagePanel];
    commonAccountsHeader &= !bar.usageDoneButton.hidden && [bar.usageScope.stringValue containsString:@"Office Mac"];
    [embeddedView layoutSubtreeIfNeeded];
    NSRect standaloneColumn = [bar.usageColumn convertRect:bar.usageColumn.bounds toView:embeddedView];
    commonAccountsHeader &= fabs(NSMinX(standaloneColumn) - 24) < 1 && fabs(NSMinY(standaloneColumn) - 24) < 1;
    NSMutableDictionary *updatedEntries = [entries mutableCopy];
    updatedEntries[first.identifier] = @{@"account_state": @"signed_out", @"forecasts": @[]};
    [bar applyPeerState:@{@"accountId":first.identifier, @"usageState":@{@"entries":updatedEntries}}];
    BOOL stableChangedRows = bar.usageAccountRows[first.identifier] == row && row.use == button && [row.use.title isEqual:@"Sign In…"];
    BOOL separateHitAreas = [bar.profileButton isDescendantOf:bar] && [bar.awsButton isDescendantOf:bar] && [bar.usageButton isDescendantOf:bar] && !bar.accessibilityElement;
    BOOL compactHeader = !ClaudeUsageViewContainsText(bar.usagePanelView, @"YOUR CLAUDE ACCOUNTS") && !ClaudeUsageViewContainsText(bar.usagePanelView, @"Active on This Tab");
    BOOL result = geometry && awsSummary && accountRouting && noStaleReady && commonAccountsHeader && receipt && noAmbiguousLocal && scope && noOptimisticSelection && rejectedSelection && acceptedDismissalOnly && preservesReopenedPanel && menuDoesNotDismissLaterPanel && stableRows && accountColumns && embeddedHeader && standaloneHeader && stableChangedRows && separateHitAreas && compactHeader;
    if (!result) fprintf(stderr, "FAIL account interface checks geometry=%d aws=%d routing=%d freshness=%d common=%d receipt=%d local=%d scope=%d pending=%d rejected=%d dismiss=%d reopened=%d menu=%d rows=%d columns=%d embedded=%d standalone=%d updates=%d hit=%d compact=%d\n", geometry, awsSummary, accountRouting, noStaleReady, commonAccountsHeader, receipt, noAmbiguousLocal, scope, noOptimisticSelection, rejectedSelection, acceptedDismissalOnly, preservesReopenedPanel, menuDoesNotDismissLaterPanel, stableRows, accountColumns, embeddedHeader, standaloneHeader, stableChangedRows, separateHitAreas, compactHeader);
    return result;
}

+ (BOOL)runUsageNormalizationSelfTests {
    NSISO8601DateFormatter *resetFormatter =
        [[NSISO8601DateFormatter alloc] init];
    resetFormatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    NSString *fiveHourResetString = [resetFormatter stringFromDate:
        [NSDate dateWithTimeIntervalSinceNow:60.0 * 60.0]];
    NSString *sevenDayResetString = [resetFormatter stringFromDate:
        [NSDate dateWithTimeIntervalSinceNow:7.0 * 24.0 * 60.0 * 60.0]];
    NSString *fableResetString = [resetFormatter stringFromDate:
        [NSDate dateWithTimeIntervalSinceNow:6.0 * 24.0 * 60.0 * 60.0]];
    NSDictionary *sample = @{
        @"five_hour" : @{
            @"utilization" : @12,
            @"resets_at" : fiveHourResetString,
        },
        @"seven_day" : @{
            @"utilization" : @34,
            @"resets_at" : sevenDayResetString,
        },
        @"limits" : @[
            @{
                @"kind" : @"weekly_scoped",
                @"percent" : @56,
                @"resets_at" : fableResetString,
                @"scope" : @{
                    @"model" : @{@"display_name" : @"Fable"},
                },
            },
        ],
    };
    NSDictionary *normalized = [self normalizedStatusFromUsage:sample];
    NSDictionary *limits = normalized[@"rate_limits"];
    NSString *commandResult =
        @"You are currently using your subscription to power your Claude "
         "Code usage\n\n"
         "Current session: 68% used · resets Jul 24 at 11:40am "
         "(America/Los_Angeles)\n"
         "Current week (all models): 48% used · resets Jul 25 at 2pm "
         "(America/Los_Angeles)\n"
         "Current week (Fable): 14% used · resets Jul 25 at 1:59pm "
         "(America/Los_Angeles)";
    NSDictionary *commandStatus =
        [self normalizedStatusFromUsageCommandResult:commandResult];
    NSDictionary *commandLimits = commandStatus[@"rate_limits"];
    NSDictionary *zeroSessionStatus =
        [self normalizedStatusFromUsageCommandResult:
            @"Current session: 0% used\n"
             "Current week (all models): 20% used · resets Dec 31 at 2pm "
             "(America/Los_Angeles)\n"
             "Current week (Fable): 14% used · resets Dec 31 at 1:59pm "
             "(America/Los_Angeles)"];
    NSDictionary *zeroSession =
        zeroSessionStatus[@"rate_limits"][@"five_hour"];
    NSNumber *fiveHourReset = limits[@"five_hour"][@"resets_at"];
    NSNumber *sevenDayReset = limits[@"seven_day"][@"resets_at"];
    NSNumber *pastReset =
        @([NSDate date].timeIntervalSince1970 - 60.0);
    BOOL rolled = NO;
    NSNumber *nextReset =
        [self nextResetTimestamp:pastReset
                         period:5.0 * 60.0 * 60.0
                         rolled:&rolled];
    NSDictionary *clamped = [self normalizedStatusFromUsage:@{
        @"five_hour" : @{@"utilization" : @140},
        @"seven_day" : @{@"utilization" : @(-5)},
    }];
    NSString *fixtureRoot = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[NSString stringWithFormat:
            @"terminaldb-usage-summary-%@", NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtPath:fixtureRoot
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
    ClaudeProfile *fixtureProfile = [[ClaudeProfile alloc] init];
    [fixtureProfile setValue:@"usage-summary" forKey:@"identifier"];
    [fixtureProfile setValue:@"Usage Summary" forKey:@"label"];
    [fixtureProfile setValue:@"first@example.com" forKey:@"email"];
    [fixtureProfile setValue:@"Max" forKey:@"subscriptionType"];
    [fixtureProfile setValue:fixtureRoot forKey:@"profileDirectory"];
    NSData *fixtureData = [NSJSONSerialization
        dataWithJSONObject:normalized options:0 error:nil];
    [fixtureData writeToFile:fixtureProfile.statusCachePath atomically:YES];
    ClaudeProfile *secondProfile = [[ClaudeProfile alloc] init];
    [secondProfile setValue:@"usage-second" forKey:@"identifier"];
    [secondProfile setValue:@"Second Subscription" forKey:@"label"];
    [secondProfile setValue:@"second@example.com" forKey:@"email"];
    [secondProfile setValue:@"Team" forKey:@"subscriptionType"];
    [secondProfile setValue:[fixtureRoot stringByAppendingPathComponent:@"second"]
                      forKey:@"profileDirectory"];
    ClaudeProfileManager *fixtureManager =
        [ClaudeProfileManager managerForTestingAtRoot:
            [fixtureRoot stringByAppendingPathComponent:@"manager"]];
    [fixtureManager setValue:@[fixtureProfile, secondProfile] forKey:@"profiles"];
    [fixtureManager setValue:fixtureProfile forKey:@"lastSelectedProfile"];
    ClaudeStatusBar *fixtureBar = [[ClaudeStatusBar alloc]
        initWithFrame:NSMakeRect(0, 0, 720, 28)
        claudeExecutable:@""
        profileManager:fixtureManager
        selectedProfile:fixtureProfile
        theme:[TerminalTheme preferredTheme]];
    [fixtureBar setValue:@YES forKey:@"accountStatusKnown"];
    [fixtureBar setValue:@YES forKey:@"accountIsLoggedIn"];
    [fixtureBar setValue:@{fixtureProfile.identifier: @{@"account_state": @"signed_in"}, secondProfile.identifier: @{@"account_state": @"signed_in"}} forKey:@"usageDashboardResults"];
    BOOL (^awaitUsageSnapshot)(BOOL) = ^BOOL(BOOL reload) {
        NSString *path = fixtureProfile.usageHistoryPath;
        NSDictionary *previous = [ClaudeUsageSnapshots() objectForKey:path];
        [self usageSnapshotForProfile:fixtureProfile reload:reload];
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
        while ([ClaudeUsageSnapshots() objectForKey:path] == previous && deadline.timeIntervalSinceNow > 0) {
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        }
        return [ClaudeUsageSnapshots() objectForKey:path] != previous;
    };
    ClaudeStatusBar *otherBar = [[ClaudeStatusBar alloc]
        initWithFrame:NSZeroRect claudeExecutable:nil profileManager:fixtureManager
        selectedProfile:nil theme:fixtureBar.theme];
    NSString *catalogID = fixtureProfile.catalogIdentifier;
    NSDictionary *firstRead = [fixtureBar peerUsagePresentation][@"entries"][catalogID];
    NSDictionary *parallelRead = [otherBar peerUsagePresentation][@"entries"][catalogID];
    BOOL snapshotLoaded = awaitUsageSnapshot(NO);
    NSArray *forecasts = [fixtureBar peerUsagePresentation][@"entries"][catalogID][@"forecasts"];
    BOOL sharesBackgroundSnapshot = [firstRead[@"suppress_metrics"] boolValue] &&
        [parallelRead[@"suppress_metrics"] boolValue] && snapshotLoaded && forecasts.count == 3 &&
        forecasts == [otherBar peerUsagePresentation][@"entries"][catalogID][@"forecasts"];
    [fixtureBar refreshUsage];
    NSString *compactSummary = fixtureBar.usageLabel.stringValue;
    BOOL showsEveryWindow =
        [compactSummary containsString:@"5h 12%"] &&
        [compactSummary containsString:@"7d 34%"] &&
        [compactSummary containsString:@"Fable 56%"] &&
        ![compactSummary containsString:@"⚠"];

    NSData *partialNewestData = [NSJSONSerialization dataWithJSONObject:@{
        @"rate_limits" : @{
            @"seven_day" : @{ @"used_percentage" : @52 },
        },
    } options:0 error:nil];
    NSData *completeFallbackData = [NSJSONSerialization dataWithJSONObject:@{
        @"rate_limits" : @{
            @"five_hour" : @{ @"used_percentage" : @7 },
            @"seven_day" : @{ @"used_percentage" : @51 },
            @"fable_five" : @{ @"used_percentage" : @9 },
        },
    } options:0 error:nil];
    [partialNewestData writeToFile:fixtureProfile.statusCachePath atomically:YES];
    [completeFallbackData writeToFile:fixtureProfile.statusLineCachePath
                            atomically:YES];
    NSDate *partialNow = [NSDate date];
    [NSFileManager.defaultManager setAttributes:@{
        NSFileModificationDate : partialNow,
    } ofItemAtPath:fixtureProfile.statusCachePath error:nil];
    [NSFileManager.defaultManager setAttributes:@{
        NSFileModificationDate :
            [partialNow dateByAddingTimeInterval:-5.0],
    } ofItemAtPath:fixtureProfile.statusLineCachePath error:nil];
    NSDictionary *mergedPartialStatus =
        [self usageStatusAtPaths:@[fixtureProfile.statusCachePath, fixtureProfile.statusLineCachePath]
                 sourceModifiedAt:nil];
    NSDictionary *mergedPartialLimits = mergedPartialStatus[@"rate_limits"];
    BOOL mergesFreshPartialWindows =
        [mergedPartialLimits[@"five_hour"][@"used_percentage"] isEqual:@7] &&
        [mergedPartialLimits[@"seven_day"][@"used_percentage"] isEqual:@52] &&
        [mergedPartialLimits[@"fable_five"][@"used_percentage"] isEqual:@9];

    [NSFileManager.defaultManager setAttributes:@{
        NSFileModificationDate : [partialNow dateByAddingTimeInterval:
            -(ClaudeUsageFreshnessInterval + 60.0)],
    } ofItemAtPath:fixtureProfile.statusLineCachePath error:nil];
    NSDictionary *withoutStaleFallback =
        [self usageStatusAtPaths:@[fixtureProfile.statusCachePath, fixtureProfile.statusLineCachePath]
                 sourceModifiedAt:nil];
    NSDictionary *withoutStaleLimits = withoutStaleFallback[@"rate_limits"];
    BOOL ignoresStalePartialFallback =
        withoutStaleLimits[@"five_hour"] == nil &&
        [withoutStaleLimits[@"seven_day"][@"used_percentage"] isEqual:@52] &&
        withoutStaleLimits[@"fable_five"] == nil;
    [fixtureData writeToFile:fixtureProfile.statusCachePath atomically:YES];
    [NSFileManager.defaultManager removeItemAtPath:fixtureProfile.statusLineCachePath
                                             error:nil];
    [NSFileManager.defaultManager setAttributes:@{
        NSFileModificationDate : [NSDate date],
    } ofItemAtPath:fixtureProfile.statusCachePath error:nil];

    NSTimeInterval forecastNow = NSDate.date.timeIntervalSince1970;
    NSNumber *forecastReset = @(forecastNow + 2.0 * 60.0 * 60.0);
    NSArray *fastHistory = @[
        @{@"recorded_at" : @(forecastNow - 20.0 * 60.0),
          @"rate_limits" : @{@"five_hour" : @{
              @"used_percentage" : @20, @"resets_at" : forecastReset}}},
        @{@"recorded_at" : @(forecastNow - 10.0 * 60.0),
          @"rate_limits" : @{@"five_hour" : @{
              @"used_percentage" : @30, @"resets_at" : forecastReset}}},
        @{@"recorded_at" : @(forecastNow),
          @"rate_limits" : @{@"five_hour" : @{
              @"used_percentage" : @40, @"resets_at" : forecastReset}}},
    ];
    NSDictionary *fastForecast = [self
        usageForecastForSamples:fastHistory
                       windowKey:@"five_hour"
                   currentWindow:@{@"used_percentage" : @40,
                                   @"resets_at" : forecastReset}
                             now:forecastNow];
    NSArray *safeHistory = @[
        @{@"recorded_at" : @(forecastNow - 20.0 * 60.0),
          @"rate_limits" : @{@"five_hour" : @{
              @"used_percentage" : @20, @"resets_at" : forecastReset}}},
        @{@"recorded_at" : @(forecastNow - 10.0 * 60.0),
          @"rate_limits" : @{@"five_hour" : @{
              @"used_percentage" : @21, @"resets_at" : forecastReset}}},
        @{@"recorded_at" : @(forecastNow),
          @"rate_limits" : @{@"five_hour" : @{
              @"used_percentage" : @22, @"resets_at" : forecastReset}}},
    ];
    NSDictionary *safeForecast = [self
        usageForecastForSamples:safeHistory
                       windowKey:@"five_hour"
                   currentWindow:@{@"used_percentage" : @22,
                                   @"resets_at" : forecastReset}
                             now:forecastNow];
    NSDictionary *learningForecast = [self
        usageForecastForSamples:[fastHistory subarrayWithRange:NSMakeRange(1, 2)]
                       windowKey:@"five_hour"
                   currentWindow:@{@"used_percentage" : @40,
                                   @"resets_at" : forecastReset}
                             now:forecastNow];
    NSDictionary *resetChangedForecast = [self
        usageForecastForSamples:fastHistory
                       windowKey:@"five_hour"
                   currentWindow:@{
                       @"used_percentage" : @3,
                       @"resets_at" : @(forecastReset.doubleValue + 3600.0),
                   }
                             now:forecastNow];
    NSDictionary *exhaustedForecast = [self
        usageForecastForSamples:@[
            @{@"recorded_at" : @(forecastNow),
              @"rate_limits" : @{@"five_hour" : @{
                  @"used_percentage" : @100,
                  @"resets_at" : forecastReset}}},
        ]
                       windowKey:@"five_hour"
                   currentWindow:@{@"used_percentage" : @100,
                                   @"resets_at" : forecastReset}
                             now:forecastNow];
    NSDictionary *staleForecast = [self
        usageForecastForSamples:@[
            @{@"recorded_at" : @(forecastNow - 40.0 * 60.0),
              @"rate_limits" : @{@"five_hour" : @{
                  @"used_percentage" : @20,
                  @"resets_at" : forecastReset}}},
            @{@"recorded_at" : @(forecastNow - 30.0 * 60.0),
              @"rate_limits" : @{@"five_hour" : @{
                  @"used_percentage" : @30,
                  @"resets_at" : forecastReset}}},
            @{@"recorded_at" : @(forecastNow - 20.0 * 60.0),
              @"rate_limits" : @{@"five_hour" : @{
                  @"used_percentage" : @40,
                  @"resets_at" : forecastReset}}},
        ]
                       windowKey:@"five_hour"
                   currentWindow:@{@"used_percentage" : @40,
                                   @"resets_at" : forecastReset}
                             now:forecastNow];

    NSNumber *fixtureFetchedAt = normalized[@"terminaldb"][@"fetched_at"];
    NSMutableArray *riskSamples = [NSMutableArray array];
    for (NSUInteger index = 0; index < 3; index++) {
        [riskSamples addObject:@{
            @"recorded_at" : @(fixtureFetchedAt.doubleValue -
                (2 - index) * 10.0 * 60.0),
            @"rate_limits" : @{
                @"five_hour" : @{
                    @"used_percentage" : @12,
                    @"resets_at" : fiveHourReset,
                },
                @"seven_day" : @{
                    @"used_percentage" : @34,
                    @"resets_at" : sevenDayReset,
                },
                @"fable_five" : @{
                    @"used_percentage" : @([@[@40, @48, @56][index]
                        doubleValue]),
                    @"resets_at" : limits[@"fable_five"][@"resets_at"],
                },
            },
        }];
    }
    NSData *riskData = [NSJSONSerialization dataWithJSONObject:@{
        @"version" : @1, @"samples" : riskSamples,
    } options:0 error:nil];
    [riskData writeToFile:fixtureProfile.usageHistoryPath atomically:YES];
    [NSFileManager.defaultManager
        setAttributes:@{NSFilePosixPermissions : @0600}
        ofItemAtPath:fixtureProfile.usageHistoryPath
        error:nil];
    BOOL riskSnapshotLoaded = awaitUsageSnapshot(YES);
    [fixtureBar refreshUsage];
    BOOL showsRiskOnlyWhenForecasted =
        riskSnapshotLoaded && [fixtureBar.usageLabel.stringValue containsString:@"⚠ Fable"];
    NSView *dashboard = [fixtureBar prepareUsagePanel];
    BOOL compactAccountPicker = !ClaudeUsageViewContainsText(dashboard, @"Burn") && ClaudeUsageViewContainsText(dashboard, @"Details");
    for (ClaudeProfile *profile in fixtureManager.profiles) {
        [ClaudeUsageFindButton(dashboard, @"Details", profile.identifier) performClick:nil];
    }
    dashboard = [fixtureBar prepareUsagePanel];
    BOOL dashboardShowsAllAccounts =
        ClaudeUsageViewContainsText(dashboard, @"2 accounts available") &&
        ClaudeUsageViewContainsText(dashboard, @"Claude Accounts") &&
        ClaudeUsageViewContainsText(dashboard, @"Second Subscription") &&
        ClaudeUsageViewContainsText(dashboard, @"first@example.com") &&
        ClaudeUsageViewContainsText(dashboard, @"Add Claude Account…") &&
        ClaudeUsageViewContainsText(dashboard, @"Burn") &&
        ClaudeUsageViewContainsText(dashboard, @"Available pace") &&
        ClaudeUsageViewContainsText(dashboard, @"Reset") &&
        ClaudeUsageViewContainsText(dashboard, @"Use");
    BOOL dashboardUsesHostScroller =
        NSHeight(dashboard.frame) > 0 && NSWidth(dashboard.frame) <= 720 &&
        !ClaudeUsageViewContainsNestedScrollView(dashboard);
    (void)[fixtureBar peerUsagePresentation];
    [fixtureBar setValue:@YES forKey:@"usageDashboardRefreshInFlight"];
    [fixtureBar setValue:@0 forKey:@"usageDashboardRefreshCompletedCount"];
    [fixtureBar setValue:@2 forKey:@"usageDashboardRefreshTotalCount"];
    [fixtureBar setValue:@{
        fixtureProfile.identifier : @{
            @"account_state" : @"signed_in",
            @"refresh_state" : @"refreshing",
        },
        secondProfile.identifier : @{
            @"account_state" : @"signed_in",
            @"refresh_state" : @"waiting",
        },
    } forKey:@"usageDashboardResults"];
    NSView *startingRefreshDashboard = [fixtureBar prepareUsagePanel];
    NSDictionary *peerStartingRefresh = [fixtureBar peerUsagePresentation];
    BOOL peerRefreshUpdatesImmediately =
        [peerStartingRefresh[@"entries"][fixtureProfile.catalogIdentifier][@"refresh_state"]
            isEqual:@"refreshing"] &&
        [peerStartingRefresh[@"entries"][secondProfile.catalogIdentifier][@"refresh_state"]
            isEqual:@"waiting"];
    BOOL dashboardShowsStartingRefresh =
        ClaudeUsageViewContainsText(startingRefreshDashboard,
            @"Checking 2 profiles…") &&
        ClaudeUsageViewContainsText(startingRefreshDashboard,
            @"Refreshing account status and usage…") &&
        ClaudeUsageViewContainsText(startingRefreshDashboard,
            @"Waiting to refresh…");
    [fixtureBar setValue:@1 forKey:@"usageDashboardRefreshCompletedCount"];
    [fixtureBar setValue:@{
        fixtureProfile.identifier : @{
            @"account_state" : @"signed_in",
            @"refresh_state" : @"complete",
        },
        secondProfile.identifier : @{
            @"account_state" : @"signed_in",
            @"refresh_state" : @"refreshing",
        },
    } forKey:@"usageDashboardResults"];
    NSView *progressRefreshDashboard = [fixtureBar prepareUsagePanel];
    BOOL dashboardShowsProgressiveRefresh =
        ClaudeUsageViewContainsText(progressRefreshDashboard,
            @"1 of 2 complete") &&
        ClaudeUsageViewContainsText(progressRefreshDashboard,
            @"Refreshing account status and usage…");
    [fixtureBar setValue:@NO forKey:@"usageDashboardRefreshInFlight"];
    [NSFileManager.defaultManager setAttributes:@{
        NSFileModificationDate :
            [NSDate dateWithTimeIntervalSinceNow:
                -(ClaudeUsageFreshnessInterval + 60.0)],
    } ofItemAtPath:fixtureProfile.statusCachePath error:nil];
    BOOL staleSnapshotLoaded = awaitUsageSnapshot(YES);
    [fixtureBar refreshUsage];
    NSView *staleDashboard = [fixtureBar prepareUsagePanel];
    BOOL hidesStaleUsage = staleSnapshotLoaded &&
        [fixtureBar.usageLabel.stringValue isEqualToString:
            @"Usage  Refresh required"] &&
        ClaudeUsageViewContainsText(staleDashboard,
            @"stale snapshot hidden") &&
        ClaudeUsageViewContainsText(staleDashboard,
            @"too old to trust");
    [fixtureBar setValue:@{
        fixtureProfile.identifier : @{
            @"account_state" : @"signed_out",
        },
    } forKey:@"usageDashboardResults"];
    [fixtureBar setValue:@YES forKey:@"accountStatusKnown"];
    [fixtureBar setValue:@NO forKey:@"accountIsLoggedIn"];
    [fixtureBar refreshUsage];
    NSView *signedOutDashboard = [fixtureBar prepareUsagePanel];
    NSDictionary *peerSignedOut = [fixtureBar peerUsagePresentation];
    BOOL peerSignOutUpdatesImmediately =
        ![peerSignedOut[@"loggedIn"] boolValue] &&
        [peerSignedOut[@"known"] boolValue] &&
        [peerSignedOut[@"entries"][fixtureProfile.catalogIdentifier][@"account_state"]
            isEqual:@"signed_out"] &&
        [peerSignedOut[@"entries"][fixtureProfile.catalogIdentifier][@"suppress_metrics"] boolValue];
    BOOL hidesSignedOutUsage =
        [fixtureBar.usageLabel.stringValue isEqualToString:
            @"Usage  Sign in required"] &&
        ClaudeUsageViewContainsText(signedOutDashboard,
            @"Signed out") &&
        ClaudeUsageViewContainsText(signedOutDashboard,
            @"Sign In…");
    NSNumber *historyPermissions = [NSFileManager.defaultManager
        attributesOfItemAtPath:fixtureProfile.usageHistoryPath error:nil]
        [NSFilePosixPermissions];
    [NSFileManager.defaultManager removeItemAtPath:fixtureRoot error:nil];
    if (!(compactAccountPicker && dashboardShowsAllAccounts && dashboardUsesHostScroller && dashboardShowsStartingRefresh && dashboardShowsProgressiveRefresh && peerRefreshUpdatesImmediately && peerSignOutUpdatesImmediately && hidesStaleUsage && hidesSignedOutUsage)) {
        fprintf(stderr, "FAIL account view checks compact=%d accounts=%d scroller=%d starting=%d progress=%d refresh=%d signout=%d stale=%d signedout=%d\n", compactAccountPicker, dashboardShowsAllAccounts, dashboardUsesHostScroller, dashboardShowsStartingRefresh, dashboardShowsProgressiveRefresh, peerRefreshUpdatesImmediately, peerSignOutUpdatesImmediately, hidesStaleUsage, hidesSignedOutUsage);
    }
    return [limits[@"five_hour"][@"used_percentage"] isEqual:@12] &&
        [fiveHourReset isKindOfClass:NSNumber.class] &&
        [limits[@"seven_day"][@"used_percentage"] isEqual:@34] &&
        [sevenDayReset isKindOfClass:NSNumber.class] &&
        [limits[@"fable_five"][@"used_percentage"] isEqual:@56] &&
        [limits[@"fable_five"][@"resets_at"] isKindOfClass:NSNumber.class] &&
        [commandLimits[@"five_hour"][@"used_percentage"] isEqual:@68] &&
        [commandLimits[@"seven_day"][@"used_percentage"] isEqual:@48] &&
        [commandLimits[@"fable_five"][@"used_percentage"] isEqual:@14] &&
        [commandLimits[@"five_hour"][@"resets_at"]
            isKindOfClass:NSNumber.class] &&
        [commandLimits[@"seven_day"][@"resets_at"]
            isKindOfClass:NSNumber.class] &&
        [commandLimits[@"fable_five"][@"resets_at"]
            isKindOfClass:NSNumber.class] &&
        [zeroSession[@"used_percentage"] isEqual:@0] &&
        zeroSession[@"resets_at"] == nil &&
        [self compactResetDateTimeFromTimestamp:fiveHourReset].length > 0 &&
        [self compactResetDateTimeFromTimestamp:sevenDayReset].length > 0 &&
        [self compactResetDateTimeFromTimestamp:pastReset] == nil &&
        [self compactDateTimeFromTimestamp:pastReset].length > 0 &&
        rolled &&
        [nextReset doubleValue] > [NSDate date].timeIntervalSince1970 &&
        [clamped[@"rate_limits"][@"five_hour"][@"used_percentage"]
            isEqual:@100] &&
        [clamped[@"rate_limits"][@"seven_day"][@"used_percentage"]
            isEqual:@0] &&
        showsEveryWindow &&
        sharesBackgroundSnapshot &&
        mergesFreshPartialWindows &&
        ignoresStalePartialFallback &&
        [fastForecast[@"ready"] boolValue] &&
        [fastForecast[@"warning"] boolValue] &&
        [fastForecast[@"rate_per_hour"] doubleValue] > 55.0 &&
        [safeForecast[@"ready"] boolValue] &&
        ![safeForecast[@"warning"] boolValue] &&
        ![learningForecast[@"ready"] boolValue] &&
        ![resetChangedForecast[@"ready"] boolValue] &&
        ![resetChangedForecast[@"warning"] boolValue] &&
        [exhaustedForecast[@"warning"] boolValue] &&
        [exhaustedForecast[@"severity"] isEqualToString:@"critical"] &&
        [staleForecast[@"stale"] boolValue] &&
        showsRiskOnlyWhenForecasted &&
        compactAccountPicker &&
        dashboardShowsAllAccounts &&
        dashboardUsesHostScroller &&
        dashboardShowsStartingRefresh &&
        dashboardShowsProgressiveRefresh &&
        peerRefreshUpdatesImmediately &&
        peerSignOutUpdatesImmediately &&
        hidesStaleUsage &&
        hidesSignedOutUsage &&
        historyPermissions.unsignedIntegerValue == 0600;
}

+ (nullable NSNumber *)timestampFromUsageResetValue:(id)value {
    if ([value isKindOfClass:NSNumber.class]) return value;
    if (![value isKindOfClass:NSString.class]) return nil;

    NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
    formatter.formatOptions =
        NSISO8601DateFormatWithInternetDateTime |
        NSISO8601DateFormatWithFractionalSeconds;
    NSDate *date = [formatter dateFromString:value];
    if (date == nil) {
        formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
        date = [formatter dateFromString:value];
    }
    return date != nil ? @(date.timeIntervalSince1970) : nil;
}

- (NSAttributedString *)usageSegment:(NSString *)label
                             percent:(double)percent {
    percent = ClaudeUsageClampedPercent(percent);
    NSColor *color = percent >= 80
        ? self.theme.ansiColors[1]
        : (percent >= 50
            ? self.theme.ansiColors[3]
            : self.theme.ansiColors[2]);
    return [[NSAttributedString alloc]
        initWithString:[NSString stringWithFormat:@"%@ %.0f%%", label, percent]
            attributes:@{
                NSFontAttributeName : self.usageLabel.font,
                NSForegroundColorAttributeName : color,
            }];
}

+ (nullable NSNumber *)nextResetTimestamp:(nullable NSNumber *)timestamp
                                   period:(NSTimeInterval)period
                                   rolled:(BOOL *)rolled {
    if (rolled != NULL) *rolled = NO;
    if (![timestamp isKindOfClass:NSNumber.class] || period <= 0) return nil;
    NSTimeInterval value = timestamp.doubleValue;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (!isfinite(value)) return nil;
    if (value <= now + 1.0) {
        NSTimeInterval intervals = floor((now - value) / period) + 1.0;
        value += MAX(1.0, intervals) * period;
        if (rolled != NULL) *rolled = YES;
    }
    return @(value);
}

+ (nullable NSString *)compactResetDateTimeFromTimestamp:
    (nullable NSNumber *)timestamp {
    if (![timestamp isKindOfClass:NSNumber.class]) return nil;
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:timestamp.doubleValue];
    if (date.timeIntervalSinceNow <= 1.0) return nil;
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setLocalizedDateFormatFromTemplate:@"Mdjmm"];
    return [formatter stringFromDate:date];
}

+ (nullable NSString *)compactDateTimeFromTimestamp:
    (nullable NSNumber *)timestamp {
    if (![timestamp isKindOfClass:NSNumber.class]) return nil;
    NSDate *date = [NSDate
        dateWithTimeIntervalSince1970:timestamp.doubleValue];
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setLocalizedDateFormatFromTemplate:@"Mdjmm"];
    return [formatter stringFromDate:date];
}

+ (NSString *)compactDurationFromSeconds:(NSTimeInterval)seconds {
    if (!isfinite(seconds) || seconds <= 60.0) return @"now";
    NSInteger totalMinutes = MAX(1, (NSInteger)llround(seconds / 60.0));
    if (totalMinutes < 60) {
        NSInteger rounded = MAX(1, (NSInteger)llround(totalMinutes / 5.0) * 5);
        return [NSString stringWithFormat:@"%ldm", (long)rounded];
    }
    NSInteger hours = totalMinutes / 60;
    NSInteger minutes = totalMinutes % 60;
    minutes = (NSInteger)llround(minutes / 5.0) * 5;
    if (minutes >= 60) {
        hours += 1;
        minutes = 0;
    }
    return minutes > 0
        ? [NSString stringWithFormat:@"%ldh %ldm",
            (long)hours, (long)minutes]
        : [NSString stringWithFormat:@"%ldh", (long)hours];
}

- (void)appendResetDescription:(NSString *)label
                        window:(NSDictionary *)window
                            to:(NSMutableArray<NSString *> *)descriptions {
    if (window == nil) return;
    NSNumber *timestamp = [window[@"resets_at"] isKindOfClass:NSNumber.class]
        ? window[@"resets_at"] : nil;
    if (timestamp == nil) {
        [descriptions addObject:[NSString stringWithFormat:
            @"%@ reset is not currently reported", label]];
        return;
    }
    NSTimeInterval period = [label hasPrefix:@"5-hour"]
        ? 5.0 * 60.0 * 60.0
        : 7.0 * 24.0 * 60.0 * 60.0;
    BOOL rolled = NO;
    NSNumber *effective =
        [ClaudeStatusBar nextResetTimestamp:timestamp
                                     period:period
                                     rolled:&rolled];
    NSString *dateTime =
        [ClaudeStatusBar compactResetDateTimeFromTimestamp:effective];
    [descriptions addObject:[NSString stringWithFormat:
        rolled
            ? @"%@ next reset is estimated at %@ from the last reported cycle"
            : @"%@ resets %@",
        label, dateTime ?: @"—"]];
}

@end
