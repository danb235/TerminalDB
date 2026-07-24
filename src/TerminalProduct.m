#import "TerminalProduct.h"

#import "TerminalTheme.h"

static NSString *TerminalProductSupportDirectory(void) {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(
        NSApplicationSupportDirectory, NSUserDomainMask, YES);
    NSString *base = paths.firstObject ?: NSTemporaryDirectory();
    return [base stringByAppendingPathComponent:@"TerminalDB"];
}

static NSString *TerminalProductTrim(NSString *value) {
    return [value ?: @"" stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSString *TerminalProductDisplayDate(NSNumber *timestamp) {
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:
        timestamp.doubleValue];
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateStyle = NSDateFormatterMediumStyle;
    formatter.timeStyle = NSDateFormatterShortStyle;
    return [formatter stringFromDate:date] ?: @"";
}

@interface TerminalProductStore ()
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *mutableRunbooks;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *mutableWorkspaces;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *mutableMonitors;
@property(nonatomic, copy) NSString *storagePath;
@end

@implementation TerminalProductStore

+ (instancetype)sharedStore {
    static TerminalProductStore *store;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        store = [[TerminalProductStore alloc] init];
    });
    return store;
}

- (instancetype)init {
    self = [super init];
    if (self == nil) return nil;
    _mutableRunbooks = [NSMutableArray array];
    _mutableWorkspaces = [NSMutableArray array];
    _mutableMonitors = [NSMutableArray array];
    NSString *directory = TerminalProductSupportDirectory();
    [NSFileManager.defaultManager createDirectoryAtPath:directory
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
    _storagePath = [directory stringByAppendingPathComponent:
        @"product-state.json"];
    NSData *data = [NSData dataWithContentsOfFile:_storagePath];
    NSDictionary *state = data.length > 0
        ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil]
        : nil;
    if ([state[@"runbooks"] isKindOfClass:NSArray.class]) {
        [_mutableRunbooks addObjectsFromArray:state[@"runbooks"]];
    }
    if ([state[@"workspaces"] isKindOfClass:NSArray.class]) {
        [_mutableWorkspaces addObjectsFromArray:state[@"workspaces"]];
    }
    return self;
}

- (NSArray<NSDictionary *> *)runbooks {
    return [self.mutableRunbooks copy];
}

- (NSArray<NSDictionary *> *)workspaces {
    return [self.mutableWorkspaces copy];
}

- (NSArray<NSDictionary *> *)monitors {
    return [self.mutableMonitors copy];
}

- (void)persist {
    NSDictionary *state = @{
        @"version" : @1,
        @"runbooks" : self.mutableRunbooks,
        @"workspaces" : self.mutableWorkspaces,
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:state
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:nil];
    [data writeToFile:self.storagePath atomically:YES];
}

- (NSDictionary *)saveRunbookNamed:(NSString *)name
                           command:(NSString *)command
                         directory:(NSString *)directory {
    NSDictionary *runbook = @{
        @"id" : NSUUID.UUID.UUIDString,
        @"name" : TerminalProductTrim(name).length > 0
            ? TerminalProductTrim(name) : @"Untitled runbook",
        @"command" : TerminalProductTrim(command),
        @"directory" : directory.length > 0 ? directory : @"~",
        @"created_at" : @([NSDate date].timeIntervalSince1970),
        @"last_run_at" : @0,
        @"run_count" : @0,
        @"tags" : @[@"local"],
    };
    [self.mutableRunbooks insertObject:runbook atIndex:0];
    [self persist];
    return runbook;
}

- (void)deleteRunbookWithIdentifier:(NSString *)identifier {
    NSIndexSet *matches = [self.mutableRunbooks
        indexesOfObjectsPassingTest:
            ^BOOL(NSDictionary *item, NSUInteger index, BOOL *stop) {
        (void)index;
        (void)stop;
        return [item[@"id"] isEqualToString:identifier];
    }];
    [self.mutableRunbooks removeObjectsAtIndexes:matches];
    [self persist];
}

- (NSDictionary *)saveWorkspaceNamed:(NSString *)name
                           directory:(NSString *)directory
                        accountLabel:(NSString *)accountLabel
                           chatTitle:(NSString *)chatTitle {
    NSDictionary *workspace = @{
        @"id" : NSUUID.UUID.UUIDString,
        @"name" : TerminalProductTrim(name).length > 0
            ? TerminalProductTrim(name) : @"Untitled workspace",
        @"directory" : directory.length > 0 ? directory : @"~",
        @"account" : accountLabel ?: @"No Claude Code account",
        @"chat" : chatTitle ?: @"New chat",
        @"tabs" : @1,
        @"splits" : @0,
        @"created_at" : @([NSDate date].timeIntervalSince1970),
        @"last_opened_at" : @([NSDate date].timeIntervalSince1970),
    };
    [self.mutableWorkspaces insertObject:workspace atIndex:0];
    [self persist];
    return workspace;
}

- (void)deleteWorkspaceWithIdentifier:(NSString *)identifier {
    NSIndexSet *matches = [self.mutableWorkspaces
        indexesOfObjectsPassingTest:
            ^BOOL(NSDictionary *item, NSUInteger index, BOOL *stop) {
        (void)index;
        (void)stop;
        return [item[@"id"] isEqualToString:identifier];
    }];
    [self.mutableWorkspaces removeObjectsAtIndexes:matches];
    [self persist];
}

- (NSString *)beginMonitoringCommand:(NSString *)command
                           directory:(NSString *)directory
                         environment:(NSString *)environment {
    NSString *identifier = NSUUID.UUID.UUIDString;
    NSDictionary *monitor = @{
        @"id" : identifier,
        @"command" : command ?: @"",
        @"directory" : directory ?: @"~",
        @"environment" : environment ?: @"LOCAL",
        @"state" : @"RUNNING",
        @"started_at" : @([NSDate date].timeIntervalSince1970),
        @"finished_at" : @0,
        @"exit_code" : @(-1),
        @"output" : @"",
        @"notify" : @YES,
    };
    [self.mutableMonitors insertObject:monitor atIndex:0];
    return identifier;
}

- (void)finishMonitorWithIdentifier:(NSString *)identifier
                           exitCode:(NSInteger)exitCode
                             output:(NSString *)output {
    NSUInteger index = [self.mutableMonitors
        indexOfObjectPassingTest:
            ^BOOL(NSDictionary *item, NSUInteger candidate, BOOL *stop) {
        (void)candidate;
        (void)stop;
        return [item[@"id"] isEqualToString:identifier];
    }];
    if (index == NSNotFound) return;
    NSMutableDictionary *updated =
        [self.mutableMonitors[index] mutableCopy];
    updated[@"state"] = exitCode == 0 ? @"DONE" : @"FAILED";
    updated[@"finished_at"] = @([NSDate date].timeIntervalSince1970);
    updated[@"exit_code"] = @(exitCode);
    updated[@"output"] = output.length > 8000
        ? [output substringFromIndex:output.length - 8000]
        : output ?: @"";
    self.mutableMonitors[index] = updated;
}

- (void)removeMonitorWithIdentifier:(NSString *)identifier {
    NSIndexSet *matches = [self.mutableMonitors
        indexesOfObjectsPassingTest:
            ^BOOL(NSDictionary *item, NSUInteger index, BOOL *stop) {
        (void)index;
        (void)stop;
        return [item[@"id"] isEqualToString:identifier];
    }];
    [self.mutableMonitors removeObjectsAtIndexes:matches];
}

- (BOOL)runSelfTests {
    NSString *name = [NSString stringWithFormat:@"QA-%@",
        NSUUID.UUID.UUIDString];
    NSDictionary *runbook =
        [self saveRunbookNamed:name command:@"pwd" directory:@"/tmp"];
    BOOL saved = [self.runbooks containsObject:runbook];
    [self deleteRunbookWithIdentifier:runbook[@"id"]];
    NSString *monitor = [self beginMonitoringCommand:@"sleep 1"
                                           directory:@"/tmp"
                                         environment:@"LOCAL"];
    [self finishMonitorWithIdentifier:monitor exitCode:0 output:@"done"];
    NSDictionary *result = [self.monitors filteredArrayUsingPredicate:
        [NSPredicate predicateWithFormat:@"id == %@", monitor]].firstObject;
    BOOL monitored = [result[@"state"] isEqualToString:@"DONE"];
    [self removeMonitorWithIdentifier:monitor];
    return saved && monitored;
}

@end

@interface TerminalProductWindowController () <
    NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate>
@property(nonatomic, strong) TerminalTheme *theme;
@property(nonatomic, strong) TerminalProductStore *store;
@property(nonatomic) TerminalProductSection section;
@property(nonatomic, copy) NSString *directory;
@property(nonatomic, copy) NSString *accountLabel;
@property(nonatomic, strong) NSSegmentedControl *sectionControl;
@property(nonatomic, strong) NSSearchField *searchField;
@property(nonatomic, strong) NSTableView *tableView;
@property(nonatomic, strong) NSTextView *detailView;
@property(nonatomic, strong) NSTextField *eyebrowLabel;
@property(nonatomic, strong) NSTextField *titleLabel;
@property(nonatomic, strong) NSTextField *subtitleLabel;
@property(nonatomic, strong) NSButton *createButton;
@property(nonatomic, strong) NSButton *primaryButton;
@property(nonatomic, strong) NSButton *secondaryButton;
@property(nonatomic, strong) NSButton *deleteButton;
@property(nonatomic, copy) NSArray<NSDictionary *> *items;
@property(nonatomic, strong) NSTimer *refreshTimer;
@end

@implementation TerminalProductWindowController

- (instancetype)initWithTheme:(TerminalTheme *)theme
                         store:(TerminalProductStore *)store {
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 1120, 690)
                  styleMask:NSWindowStyleMaskTitled |
                            NSWindowStyleMaskClosable |
                            NSWindowStyleMaskResizable |
                            NSWindowStyleMaskMiniaturizable
                    backing:NSBackingStoreBuffered
                      defer:NO];
    window.title = @"TerminalDB";
    window.minSize = NSMakeSize(850, 560);
    window.backgroundColor = theme.terminalBackground;
    self = [super initWithWindow:window];
    if (self == nil) return nil;
    _theme = theme;
    _store = store;
    _directory = NSHomeDirectory();
    _accountLabel = @"No Claude Code account";
    [self buildInterface];
    _refreshTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                     target:self
                                                   selector:@selector(timerFired:)
                                                   userInfo:nil
                                                    repeats:YES];
    return self;
}

- (void)dealloc {
    [self.refreshTimer invalidate];
}

- (NSTextField *)labelWithSize:(CGFloat)size
                        weight:(NSFontWeight)weight
                         color:(NSColor *)color {
    NSTextField *label = [[NSTextField alloc] initWithFrame:NSZeroRect];
    label.editable = NO;
    label.selectable = NO;
    label.bezeled = NO;
    label.drawsBackground = NO;
    label.font = [NSFont systemFontOfSize:size weight:weight];
    label.textColor = color;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    return label;
}

- (void)buildInterface {
    NSView *content = self.window.contentView;
    content.wantsLayer = YES;
    content.layer.backgroundColor = self.theme.terminalBackground.CGColor;

    self.sectionControl = [[NSSegmentedControl alloc]
        initWithFrame:NSMakeRect(22, 632, 1076, 30)];
    self.sectionControl.segmentCount = 6;
    NSArray *labels =
        @[@"Project", @"Environments", @"Monitor", @"Runbooks",
          @"Workspaces", @"Settings"];
    for (NSInteger i = 0; i < self.sectionControl.segmentCount; i++) {
        [self.sectionControl setLabel:labels[i] forSegment:i];
        [self.sectionControl setWidth:140 forSegment:i];
    }
    self.sectionControl.segmentStyle = NSSegmentStyleTexturedRounded;
    self.sectionControl.target = self;
    self.sectionControl.action = @selector(sectionChanged:);
    self.sectionControl.autoresizingMask =
        NSViewWidthSizable | NSViewMinYMargin;
    [content addSubview:self.sectionControl];

    self.eyebrowLabel = [self labelWithSize:10
                                    weight:NSFontWeightSemibold
                                     color:self.theme.ansiColors[6]];
    self.eyebrowLabel.frame = NSMakeRect(28, 594, 500, 16);
    self.eyebrowLabel.autoresizingMask = NSViewMinYMargin;
    [content addSubview:self.eyebrowLabel];

    self.titleLabel = [self labelWithSize:22
                                  weight:NSFontWeightSemibold
                                   color:self.theme.terminalForeground];
    self.titleLabel.frame = NSMakeRect(26, 562, 600, 30);
    self.titleLabel.autoresizingMask = NSViewMinYMargin;
    [content addSubview:self.titleLabel];

    self.subtitleLabel = [self labelWithSize:12
                                     weight:NSFontWeightRegular
                                      color:self.theme.statusBarActiveForeground];
    self.subtitleLabel.frame = NSMakeRect(28, 538, 900, 19);
    self.subtitleLabel.autoresizingMask =
        NSViewWidthSizable | NSViewMinYMargin;
    [content addSubview:self.subtitleLabel];

    self.searchField =
        [[NSSearchField alloc] initWithFrame:NSMakeRect(24, 500, 350, 28)];
    self.searchField.placeholderString =
        @"Search names, commands, paths, tags, and status";
    self.searchField.delegate = self;
    self.searchField.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    [content addSubview:self.searchField];

    self.createButton = [NSButton buttonWithTitle:@"New"
                                           target:self
                                           action:@selector(newSelected:)];
    self.createButton.frame = NSMakeRect(388, 499, 84, 30);
    self.createButton.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    [content addSubview:self.createButton];

    NSScrollView *listScroll =
        [[NSScrollView alloc] initWithFrame:NSMakeRect(24, 62, 420, 426)];
    listScroll.hasVerticalScroller = YES;
    listScroll.borderType = NSBezelBorder;
    listScroll.drawsBackground = YES;
    listScroll.backgroundColor = self.theme.statusBarBackground;
    listScroll.autoresizingMask = NSViewHeightSizable;
    self.tableView = [[NSTableView alloc] initWithFrame:NSZeroRect];
    self.tableView.headerView = nil;
    self.tableView.rowHeight = 50;
    self.tableView.backgroundColor = self.theme.statusBarBackground;
    self.tableView.selectionHighlightStyle =
        NSTableViewSelectionHighlightStyleRegular;
    NSTableColumn *column =
        [[NSTableColumn alloc] initWithIdentifier:@"item"];
    column.width = 410;
    [self.tableView addTableColumn:column];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    listScroll.documentView = self.tableView;
    [content addSubview:listScroll];

    NSScrollView *detailScroll =
        [[NSScrollView alloc] initWithFrame:NSMakeRect(462, 106, 636, 382)];
    detailScroll.hasVerticalScroller = YES;
    detailScroll.borderType = NSBezelBorder;
    detailScroll.drawsBackground = YES;
    detailScroll.backgroundColor =
        [NSColor colorWithSRGBRed:0.07 green:0.076 blue:0.087 alpha:1.0];
    detailScroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.detailView = [[NSTextView alloc] initWithFrame:NSZeroRect];
    self.detailView.editable = NO;
    self.detailView.selectable = YES;
    self.detailView.drawsBackground = NO;
    self.detailView.textColor = self.theme.terminalForeground;
    self.detailView.font = [NSFont fontWithName:self.theme.fontName size:12]
        ?: [NSFont monospacedSystemFontOfSize:12
                                      weight:NSFontWeightRegular];
    self.detailView.textContainerInset = NSMakeSize(14, 14);
    detailScroll.documentView = self.detailView;
    [content addSubview:detailScroll];

    self.primaryButton = [NSButton buttonWithTitle:@"Open"
                                            target:self
                                            action:@selector(primarySelected:)];
    self.primaryButton.frame = NSMakeRect(462, 62, 122, 32);
    self.primaryButton.autoresizingMask = NSViewMaxXMargin;
    [content addSubview:self.primaryButton];
    self.secondaryButton = [NSButton buttonWithTitle:@"Paste"
                                              target:self
                                              action:@selector(secondarySelected:)];
    self.secondaryButton.frame = NSMakeRect(592, 62, 122, 32);
    self.secondaryButton.autoresizingMask = NSViewMaxXMargin;
    [content addSubview:self.secondaryButton];
    self.deleteButton = [NSButton buttonWithTitle:@"Delete…"
                                           target:self
                                           action:@selector(deleteSelected:)];
    self.deleteButton.frame = NSMakeRect(976, 62, 122, 32);
    self.deleteButton.autoresizingMask = NSViewMinXMargin;
    [content addSubview:self.deleteButton];
}

- (void)showSection:(TerminalProductSection)section
          directory:(NSString *)directory
       accountLabel:(NSString *)accountLabel {
    self.section = section;
    self.directory = directory.length > 0 ? directory : NSHomeDirectory();
    self.accountLabel =
        accountLabel.length > 0 ? accountLabel : @"No Claude Code account";
    if (section <= TerminalProductSectionSettings) {
        self.sectionControl.selectedSegment = section;
    }
    [self refresh];
    [self showWindow:nil];
    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
}

- (void)sectionChanged:(NSSegmentedControl *)sender {
    self.section = sender.selectedSegment;
    [self refresh];
}

- (void)controlTextDidChange:(NSNotification *)notification {
    if (notification.object == self.searchField) [self refresh];
}

- (void)timerFired:(NSTimer *)timer {
    (void)timer;
    if (self.window.visible && self.section == TerminalProductSectionMonitor) {
        [self refresh];
    }
}

- (NSArray<NSDictionary *> *)projectItems {
    NSMutableArray<NSDictionary *> *items = [NSMutableArray arrayWithArray:@[
        @{@"id" : @"git", @"name" : @"Git status",
          @"detail" : @"Branch, staged changes, working tree, and untracked files",
          @"command" : @"git status --short --branch"},
        @{@"id" : @"diff", @"name" : @"Review working diff",
          @"detail" : @"Inspect changes before asking AI or running tests",
          @"command" : @"git diff --stat && git diff"},
        @{@"id" : @"tests", @"name" : @"Run project tests",
          @"detail" : @"Uses the project’s Makefile when available",
          @"command" : @"make test"},
        @{@"id" : @"files", @"name" : @"Project files",
          @"detail" : @"List tracked and local files without changing them",
          @"command" : @"find . -maxdepth 3 -type f | sort | head -300"},
    ]];
    return items;
}

- (NSArray<NSDictionary *> *)environmentItems {
    NSString *host = NSHost.currentHost.localizedName ?: @"This Mac";
    return @[
        @{@"id" : @"local", @"name" : @"LOCAL",
          @"detail" : [NSString stringWithFormat:@"%@ · %@", host,
              self.directory],
          @"badge" : @"SAFE"},
        @{@"id" : @"ssh", @"name" : @"SSH hosts",
          @"detail" : @"Detected automatically from running ssh commands",
          @"badge" : @"REMOTE"},
        @{@"id" : @"containers", @"name" : @"Containers & Kubernetes",
          @"detail" : @"Docker and kubectl contexts are included in approvals",
          @"badge" : @"CONTEXT"},
        @{@"id" : @"production", @"name" : @"PRODUCTION protection",
          @"detail" : @"Typed acknowledgement and cancel-by-default execution",
          @"badge" : @"GUARDED"},
    ];
}

- (NSArray<NSDictionary *> *)settingsItems {
    return @[
        @{@"id":@"ai", @"name":@"AI & Models",
          @"detail":@"Anthropic API key, live model list, and selected model"},
        @{@"id":@"accounts", @"name":@"Claude Code Accounts",
          @"detail":self.accountLabel},
        @{@"id":@"permissions", @"name":@"Execution Permissions",
          @"detail":@"Review Paste, Run once, and read-only session approvals"},
        @{@"id":@"history", @"name":@"History & Retention",
          @"detail":@"Local command database, retention, export, and private mode"},
        @{@"id":@"privacy", @"name":@"Privacy & Redaction",
          @"detail":@"Secret redaction and visible AI context controls"},
        @{@"id":@"appearance", @"name":@"Appearance",
          @"detail":@"Graphite Ledger · JetBrains Mono · system accessibility"},
        @{@"id":@"shell", @"name":@"Shell Integration",
          @"detail":@"Command boundaries, paths, status, host, and duration"},
        @{@"id":@"notifications", @"name":@"Notifications",
          @"detail":@"Long-running command completion and stalled alerts"},
        @{@"id":@"runbooks", @"name":@"Runbooks",
          @"detail":@"Local and project workflows in .terminaldb/runbooks"},
        @{@"id":@"workspaces", @"name":@"Workspaces",
          @"detail":@"Restore paths, tabs, accounts, and chat context"},
        @{@"id":@"accessibility", @"name":@"Accessibility",
          @"detail":@"Keyboard navigation, contrast, labels, and reduced motion"},
        @{@"id":@"updates", @"name":@"Updates & About",
          @"detail":@"Open-source TerminalDB build information"},
    ];
}

- (NSArray<NSDictionary *> *)onboardingItems {
    return @[
        @{@"id":@"welcome", @"name":@"1  Welcome",
          @"detail":@"A terminal that remembers command work as local blocks."},
        @{@"id":@"integration", @"name":@"2  Shell integration",
          @"detail":@"Command, path, host, status, duration, and output stay together."},
        @{@"id":@"blocks", @"name":@"3  Command blocks",
          @"detail":@"Copy, inspect, rerun, bookmark, ask AI, or save a runbook."},
        @{@"id":@"assistant", @"name":@"4  AI context",
          @"detail":@"Only visible chips and the current terminal snapshot are sent."},
        @{@"id":@"permissions", @"name":@"5  Execution safety",
          @"detail":@"Paste, Run once, or allow validated read-only patterns."},
        @{@"id":@"history", @"name":@"6  Searchable history",
          @"detail":@"Find prior fixes by command, project, environment, date, or status."},
        @{@"id":@"workflows", @"name":@"7  Workflows",
          @"detail":@"Monitor work, save runbooks, and restore workspaces."},
        @{@"id":@"ready", @"name":@"8  You’re ready",
          @"detail":@"Start in the terminal; use the sidebar icon whenever AI helps."},
    ];
}

- (void)refresh {
    switch (self.section) {
        case TerminalProductSectionProject:
            self.eyebrowLabel.stringValue = @"PROJECT-AWARE TOOLS";
            self.titleLabel.stringValue = self.directory.lastPathComponent;
            self.subtitleLabel.stringValue =
                @"Inspect files, review Git changes, run tests, and keep every "
                 "action permission-controlled.";
            self.items = [self projectItems];
            self.createButton.title = @"New chat";
            self.primaryButton.title = @"Run…";
            self.secondaryButton.title = @"Paste";
            self.deleteButton.hidden = YES;
            break;
        case TerminalProductSectionEnvironments:
            self.eyebrowLabel.stringValue = @"ENVIRONMENT AWARENESS";
            self.titleLabel.stringValue = @"Execution context";
            self.subtitleLabel.stringValue =
                @"Host, directory, containers, and production risk remain "
                 "visible before commands run.";
            self.items = [self environmentItems];
            self.createButton.title = @"Refresh";
            self.primaryButton.title = @"Copy context";
            self.secondaryButton.title = @"Open shell";
            self.deleteButton.hidden = YES;
            break;
        case TerminalProductSectionMonitor:
            self.eyebrowLabel.stringValue = @"LONG-RUNNING SUPERVISION";
            self.titleLabel.stringValue = @"Monitor center";
            self.subtitleLabel.stringValue =
                @"Watch active work, spot stalls, and inspect completed output.";
            self.items = self.store.monitors;
            self.createButton.title = @"Refresh";
            self.primaryButton.title = @"Jump to tab";
            self.secondaryButton.title = @"Ask AI";
            self.deleteButton.hidden = NO;
            break;
        case TerminalProductSectionRunbooks:
            self.eyebrowLabel.stringValue = @"REUSABLE WORKFLOWS";
            self.titleLabel.stringValue = @"Runbooks";
            self.subtitleLabel.stringValue =
                @"Save successful commands as inspectable, reusable workflows.";
            self.items = self.store.runbooks;
            self.createButton.title = @"New runbook";
            self.primaryButton.title = @"Run…";
            self.secondaryButton.title = @"Paste";
            self.deleteButton.hidden = NO;
            break;
        case TerminalProductSectionWorkspaces:
            self.eyebrowLabel.stringValue = @"RESTORABLE CONTEXT";
            self.titleLabel.stringValue = @"Workspaces";
            self.subtitleLabel.stringValue =
                @"Restore the path, account, and conversation purpose together.";
            self.items = self.store.workspaces;
            self.createButton.title = @"Save current";
            self.primaryButton.title = @"Restore";
            self.secondaryButton.title = @"Copy path";
            self.deleteButton.hidden = NO;
            break;
        case TerminalProductSectionSettings:
            self.eyebrowLabel.stringValue = @"TERMINALDB";
            self.titleLabel.stringValue = @"Settings";
            self.subtitleLabel.stringValue =
                @"Terminal intelligence stays explicit, local-first, and under "
                 "your control.";
            self.items = [self settingsItems];
            self.createButton.title = @"API settings";
            self.primaryButton.title = @"Open";
            self.secondaryButton.title = @"Reset tips";
            self.deleteButton.hidden = YES;
            break;
        case TerminalProductSectionOnboarding:
            self.eyebrowLabel.stringValue = @"GETTING STARTED · 8 STEPS";
            self.titleLabel.stringValue =
                @"Welcome to command work with memory";
            self.subtitleLabel.stringValue =
                @"Learn the model once, then stay in the flow.";
            self.items = [self onboardingItems];
            self.createButton.title = @"API settings";
            self.primaryButton.title = @"Next";
            self.secondaryButton.title = @"Finish";
            self.deleteButton.hidden = YES;
            break;
    }
    NSString *query = TerminalProductTrim(self.searchField.stringValue);
    if (query.length > 0) {
        NSPredicate *predicate = [NSPredicate predicateWithBlock:
            ^BOOL(NSDictionary *item, NSDictionary *bindings) {
            (void)bindings;
            NSString *haystack = [NSString stringWithFormat:@"%@ %@ %@ %@",
                item[@"name"] ?: @"", item[@"detail"] ?: @"",
                item[@"command"] ?: @"", item[@"directory"] ?: @""];
            return [haystack rangeOfString:query
                                  options:NSCaseInsensitiveSearch].location
                != NSNotFound;
        }];
        self.items = [self.items filteredArrayUsingPredicate:predicate];
    }
    [self.tableView reloadData];
    if (self.items.count > 0) {
        NSInteger row = MIN(MAX(self.tableView.selectedRow, 0),
                            (NSInteger)self.items.count - 1);
        [self.tableView selectRowIndexes:
            [NSIndexSet indexSetWithIndex:(NSUInteger)row]
                            byExtendingSelection:NO];
    } else {
        self.detailView.string =
            @"Nothing here yet.\n\nCreate an item or clear the search field.";
    }
    self.window.title = self.titleLabel.stringValue;
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    (void)tableView;
    return self.items.count;
}

- (NSView *)tableView:(NSTableView *)tableView
   viewForTableColumn:(NSTableColumn *)tableColumn
                  row:(NSInteger)row {
    (void)tableColumn;
    NSString *identifier = @"TerminalProductCell";
    NSTableCellView *cell =
        [tableView makeViewWithIdentifier:identifier owner:self];
    if (cell == nil) {
        cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, 410, 50)];
        cell.identifier = identifier;
        NSTextField *text = [self labelWithSize:12
                                        weight:NSFontWeightMedium
                                         color:self.theme.terminalForeground];
        text.tag = 1;
        text.frame = NSMakeRect(10, 6, 380, 18);
        text.autoresizingMask = NSViewWidthSizable;
        [cell addSubview:text];
        NSTextField *detail = [self labelWithSize:10
                                          weight:NSFontWeightRegular
                                           color:self.theme.statusBarActiveForeground];
        detail.tag = 2;
        detail.frame = NSMakeRect(10, 27, 380, 16);
        detail.autoresizingMask = NSViewWidthSizable;
        [cell addSubview:detail];
    }
    NSDictionary *item = self.items[(NSUInteger)row];
    NSTextField *text = [cell viewWithTag:1];
    NSTextField *detail = [cell viewWithTag:2];
    text.stringValue = item[@"name"] ?: item[@"command"] ?: @"Untitled";
    detail.stringValue = item[@"detail"] ?: item[@"directory"] ?:
        item[@"state"] ?: @"";
    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    (void)notification;
    [self updateDetail];
}

- (NSDictionary *)selectedItem {
    NSInteger row = self.tableView.selectedRow;
    return row >= 0 && row < (NSInteger)self.items.count
        ? self.items[(NSUInteger)row] : nil;
}

- (void)updateDetail {
    NSDictionary *item = [self selectedItem];
    if (item == nil) return;
    NSMutableString *detail = [NSMutableString string];
    NSString *name = item[@"name"] ?: item[@"command"] ?: @"Item";
    [detail appendFormat:@"%@\n%@\n\n", name,
        [@"" stringByPaddingToLength:MIN((NSUInteger)72, name.length + 12)
                         withString:@"─"
                    startingAtIndex:0]];
    NSArray *keys = @[@"detail", @"command", @"directory", @"environment",
                      @"state", @"account", @"chat", @"badge"];
    NSDictionary *labels = @{@"detail":@"SUMMARY", @"command":@"COMMAND",
        @"directory":@"DIRECTORY", @"environment":@"ENVIRONMENT",
        @"state":@"STATE", @"account":@"CLAUDE ACCOUNT",
        @"chat":@"AI CHAT", @"badge":@"PROTECTION"};
    for (NSString *key in keys) {
        id value = item[key];
        if (value == nil || [[value description] length] == 0) continue;
        [detail appendFormat:@"%@\n%@\n\n", labels[key], value];
    }
    if ([item[@"created_at"] doubleValue] > 0) {
        [detail appendFormat:@"SAVED\n%@\n\n",
            TerminalProductDisplayDate(item[@"created_at"])];
    }
    if ([item[@"started_at"] doubleValue] > 0) {
        NSDate *started = [NSDate dateWithTimeIntervalSince1970:
            [item[@"started_at"] doubleValue]];
        NSTimeInterval duration = [item[@"finished_at"] doubleValue] > 0
            ? [item[@"finished_at"] doubleValue] -
                [item[@"started_at"] doubleValue]
            : -started.timeIntervalSinceNow;
        [detail appendFormat:@"DURATION\n%.1fs\n\n", MAX(0, duration)];
    }
    if ([item[@"output"] length] > 0) {
        [detail appendFormat:@"OUTPUT\n%@\n", item[@"output"]];
    }
    self.detailView.string = detail;
}

- (NSArray<NSString *> *)promptWithTitle:(NSString *)title
                                  labels:(NSArray<NSString *> *)labels
                                defaults:(NSArray<NSString *> *)defaults {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = title;
    [alert addButtonWithTitle:@"Save"];
    [alert addButtonWithTitle:@"Cancel"];
    NSStackView *stack = [[NSStackView alloc]
        initWithFrame:NSMakeRect(0, 0, 520, labels.count * 58)];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.spacing = 6;
    NSMutableArray<NSTextField *> *fields = [NSMutableArray array];
    for (NSUInteger i = 0; i < labels.count; i++) {
        NSTextField *label = [NSTextField labelWithString:labels[i]];
        NSTextField *field =
            [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 520, 24)];
        field.stringValue = i < defaults.count ? defaults[i] : @"";
        [stack addArrangedSubview:label];
        [stack addArrangedSubview:field];
        [fields addObject:field];
    }
    alert.accessoryView = stack;
    if ([alert runModal] != NSAlertFirstButtonReturn) return nil;
    NSMutableArray *values = [NSMutableArray array];
    for (NSTextField *field in fields) {
        [values addObject:TerminalProductTrim(field.stringValue)];
    }
    return values;
}

- (void)newSelected:(id)sender {
    (void)sender;
    if (self.section == TerminalProductSectionRunbooks) {
        NSArray *values = [self promptWithTitle:@"New runbook"
                                        labels:@[@"Name", @"Command"]
                                      defaults:@[@"New workflow", @""]];
        if (values.count == 2 && [values[1] length] > 0) {
            [self.store saveRunbookNamed:values[0]
                                 command:values[1]
                               directory:self.directory];
        }
    } else if (self.section == TerminalProductSectionWorkspaces) {
        NSArray *values = [self promptWithTitle:@"Save current workspace"
                                        labels:@[@"Workspace name"]
                                      defaults:@[
            self.directory.lastPathComponent ?: @"Workspace"
        ]];
        if (values.count == 1) {
            [self.store saveWorkspaceNamed:values[0]
                                 directory:self.directory
                              accountLabel:self.accountLabel
                                 chatTitle:@"Current terminal task"];
        }
    } else if (self.section == TerminalProductSectionProject) {
        if (self.newAIChatHandler) self.newAIChatHandler();
    } else if (self.section == TerminalProductSectionSettings ||
               self.section == TerminalProductSectionOnboarding) {
        if (self.openAPISettingsHandler) self.openAPISettingsHandler();
    }
    [self refresh];
}

- (void)primarySelected:(id)sender {
    (void)sender;
    NSDictionary *item = [self selectedItem];
    if (item == nil) return;
    if (self.section == TerminalProductSectionProject ||
        self.section == TerminalProductSectionRunbooks) {
        NSString *command = item[@"command"];
        if (command.length > 0 && self.runCommandHandler) {
            self.runCommandHandler(command);
        }
    } else if (self.section == TerminalProductSectionWorkspaces) {
        if (self.restoreWorkspaceHandler) {
            self.restoreWorkspaceHandler(item);
        }
    } else if (self.section == TerminalProductSectionSettings &&
               [item[@"id"] isEqualToString:@"ai"]) {
        if (self.openAPISettingsHandler) self.openAPISettingsHandler();
    } else if (self.section == TerminalProductSectionSettings) {
        NSString *identifier = item[@"id"];
        if ([identifier isEqualToString:@"history"]) {
            if (self.showHistoryHandler) self.showHistoryHandler();
        } else if ([identifier isEqualToString:@"runbooks"]) {
            self.section = TerminalProductSectionRunbooks;
            self.sectionControl.selectedSegment = TerminalProductSectionRunbooks;
            [self refresh];
        } else if ([identifier isEqualToString:@"workspaces"]) {
            self.section = TerminalProductSectionWorkspaces;
            self.sectionControl.selectedSegment = TerminalProductSectionWorkspaces;
            [self refresh];
        } else if ([identifier isEqualToString:@"permissions"]) {
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText = @"Execution permissions";
            alert.informativeText =
                @"Read-only approvals last for the current app session. "
                 "Writes, destructive commands, sudo, and production always "
                 "require a new review.";
            [alert runModal];
        } else if ([identifier isEqualToString:@"privacy"]) {
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText = @"Privacy controls";
            alert.informativeText =
                @"Secrets are redacted before command blocks are stored. "
                 "Use Shell → Private Session to stop history persistence for "
                 "a tab. Attached AI context is always visible as chips.";
            [alert runModal];
        }
    } else if (self.section == TerminalProductSectionOnboarding) {
        NSInteger next = MIN(self.tableView.selectedRow + 1,
                             (NSInteger)self.items.count - 1);
        [self.tableView selectRowIndexes:
            [NSIndexSet indexSetWithIndex:(NSUInteger)MAX(0, next)]
                            byExtendingSelection:NO];
    } else {
        [NSPasteboard.generalPasteboard clearContents];
        [NSPasteboard.generalPasteboard writeObjects:@[
            self.detailView.string ?: @""
        ]];
    }
}

- (void)secondarySelected:(id)sender {
    (void)sender;
    NSDictionary *item = [self selectedItem];
    if (item == nil) return;
    if (self.section == TerminalProductSectionMonitor) {
        if (self.askAIHandler) {
            self.askAIHandler(item,
                [item[@"state"] isEqualToString:@"FAILED"]
                    ? @"Explain why this monitored command failed and propose "
                      "the safest next step."
                    : @"Summarize this monitored command and its output.");
        }
        return;
    }
    if (self.section == TerminalProductSectionSettings) {
        [NSUserDefaults.standardUserDefaults
            removeObjectForKey:@"TerminalDBDidCompleteOnboarding"];
        self.section = TerminalProductSectionOnboarding;
        [self refresh];
        return;
    }
    if (self.section == TerminalProductSectionOnboarding) {
        [NSUserDefaults.standardUserDefaults
            setBool:YES forKey:@"TerminalDBDidCompleteOnboarding"];
        [self.window close];
        return;
    }
    NSString *value = item[@"command"] ?: item[@"directory"];
    if (value.length > 0 && self.pasteCommandHandler) {
        self.pasteCommandHandler(value);
    } else if (value.length > 0) {
        [NSPasteboard.generalPasteboard clearContents];
        [NSPasteboard.generalPasteboard writeObjects:@[value]];
    }
}

- (void)deleteSelected:(id)sender {
    (void)sender;
    NSDictionary *item = [self selectedItem];
    if (item == nil) return;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Delete this item?";
    alert.informativeText =
        @"This removes it from TerminalDB. This action cannot be undone.";
    [alert addButtonWithTitle:@"Delete"];
    [alert addButtonWithTitle:@"Cancel"];
    alert.alertStyle = NSAlertStyleWarning;
    if ([alert runModal] != NSAlertFirstButtonReturn) return;
    if (self.section == TerminalProductSectionRunbooks) {
        [self.store deleteRunbookWithIdentifier:item[@"id"]];
    } else if (self.section == TerminalProductSectionWorkspaces) {
        [self.store deleteWorkspaceWithIdentifier:item[@"id"]];
    } else if (self.section == TerminalProductSectionMonitor) {
        [self.store removeMonitorWithIdentifier:item[@"id"]];
    }
    [self refresh];
}

@end
