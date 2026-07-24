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

static NSArray<NSDictionary *> *TerminalProductRunbookSteps(
    NSString *command) {
    NSMutableArray<NSDictionary *> *steps = [NSMutableArray array];
    NSArray<NSString *> *lines =
        [command componentsSeparatedByCharactersInSet:
            NSCharacterSet.newlineCharacterSet];
    NSUInteger number = 1;
    for (NSString *line in lines) {
        NSString *trimmed = TerminalProductTrim(line);
        if (trimmed.length == 0 || [trimmed hasPrefix:@"#"]) continue;
        [steps addObject:@{
            @"id" : NSUUID.UUID.UUIDString,
            @"number" : @(number++),
            @"command" : trimmed,
            @"approval" : @"Review before execution",
        }];
    }
    if (steps.count == 0 && TerminalProductTrim(command).length > 0) {
        [steps addObject:@{
            @"id" : NSUUID.UUID.UUIDString,
            @"number" : @1,
            @"command" : TerminalProductTrim(command),
            @"approval" : @"Review before execution",
        }];
    }
    return steps;
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
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    NSMutableArray *monitors = [NSMutableArray array];
    for (NSUInteger index = 0;
         index < self.mutableMonitors.count; index++) {
        NSDictionary *monitor = self.mutableMonitors[index];
        if (![monitor[@"state"] isEqualToString:@"RUNNING"] ||
            now - [monitor[@"started_at"] doubleValue] < 180.0) {
            [monitors addObject:monitor];
            continue;
        }
        if (![monitor[@"stalled_notified"] boolValue]) {
            NSMutableDictionary *notified = [monitor mutableCopy];
            notified[@"stalled_notified"] = @YES;
            self.mutableMonitors[index] = notified;
            monitor = notified;
            BOOL notificationsEnabled =
                [NSUserDefaults.standardUserDefaults
                    objectForKey:
                        @"TerminalDBMonitorNotificationsEnabled"] == nil ||
                [NSUserDefaults.standardUserDefaults
                    boolForKey:
                        @"TerminalDBMonitorNotificationsEnabled"];
            if (notificationsEnabled) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                NSUserNotification *notification =
                    [[NSUserNotification alloc] init];
                notification.title = @"Command may be stalled";
                notification.subtitle =
                    monitor[@"environment"] ?: @"LOCAL";
                notification.informativeText =
                    monitor[@"command"] ?: @"Terminal command";
                notification.soundName =
                    NSUserNotificationDefaultSoundName;
                [NSUserNotificationCenter.defaultUserNotificationCenter
                    deliverNotification:notification];
#pragma clang diagnostic pop
            }
        }
        NSMutableDictionary *stalled = [monitor mutableCopy];
        stalled[@"state"] = @"STALLED";
        stalled[@"detail"] =
            @"No completion after 3 minutes · inspect output or take over";
        [monitors addObject:stalled];
    }
    return monitors;
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
    NSArray *steps = TerminalProductRunbookSteps(command);
    NSDictionary *runbook = @{
        @"id" : NSUUID.UUID.UUIDString,
        @"name" : TerminalProductTrim(name).length > 0
            ? TerminalProductTrim(name) : @"Untitled runbook",
        @"command" : TerminalProductTrim(command),
        @"steps" : steps,
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

- (void)updateRunbookWithIdentifier:(NSString *)identifier
                               name:(NSString *)name
                            command:(NSString *)command
                          directory:(NSString *)directory {
    NSUInteger index = [self.mutableRunbooks
        indexOfObjectPassingTest:
            ^BOOL(NSDictionary *item, NSUInteger candidate, BOOL *stop) {
        (void)candidate;
        (void)stop;
        return [item[@"id"] isEqualToString:identifier];
    }];
    if (index == NSNotFound) return;
    NSMutableDictionary *updated = [self.mutableRunbooks[index] mutableCopy];
    updated[@"name"] = TerminalProductTrim(name).length > 0
        ? TerminalProductTrim(name) : updated[@"name"] ?: @"Untitled runbook";
    updated[@"command"] = TerminalProductTrim(command);
    updated[@"directory"] = directory.length > 0 ? directory : @"~";
    updated[@"steps"] = TerminalProductRunbookSteps(command);
    updated[@"updated_at"] = @([NSDate date].timeIntervalSince1970);
    self.mutableRunbooks[index] = updated;
    [self persist];
}

- (void)markRunbookExecuted:(NSString *)identifier {
    NSUInteger index = [self.mutableRunbooks
        indexOfObjectPassingTest:
            ^BOOL(NSDictionary *item, NSUInteger candidate, BOOL *stop) {
        (void)candidate;
        (void)stop;
        return [item[@"id"] isEqualToString:identifier];
    }];
    if (index == NSNotFound) return;
    NSMutableDictionary *updated = [self.mutableRunbooks[index] mutableCopy];
    updated[@"last_run_at"] = @([NSDate date].timeIntervalSince1970);
    updated[@"run_count"] = @([updated[@"run_count"] integerValue] + 1);
    self.mutableRunbooks[index] = updated;
    [self persist];
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

- (NSDictionary *)saveWorkspaceNamed:(NSString *)name
                             snapshot:(NSDictionary *)snapshot {
    NSArray *tabs = [snapshot[@"tabs"] isKindOfClass:NSArray.class]
        ? snapshot[@"tabs"] : @[];
    NSDictionary *first = tabs.firstObject;
    NSMutableDictionary *workspace = [@{
        @"id" : NSUUID.UUID.UUIDString,
        @"name" : TerminalProductTrim(name).length > 0
            ? TerminalProductTrim(name) : @"Untitled workspace",
        @"directory" : first[@"directory"] ?: snapshot[@"directory"] ?: @"~",
        @"account" : first[@"account"] ?: snapshot[@"account"] ?:
            @"No Claude Code account",
        @"chat" : first[@"chat_title"] ?: snapshot[@"chat"] ?: @"New chat",
        @"tabs" : tabs,
        @"tab_count" : @(tabs.count),
        @"selected_tab" : snapshot[@"selected_tab"] ?: @0,
        @"splits" : snapshot[@"splits"] ?: @0,
        @"model" : snapshot[@"model"] ?: @"",
        @"created_at" : @([NSDate date].timeIntervalSince1970),
        @"last_opened_at" : @([NSDate date].timeIntervalSince1970),
    } mutableCopy];
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

- (void)renameWorkspaceWithIdentifier:(NSString *)identifier
                                  name:(NSString *)name {
    NSString *trimmed = TerminalProductTrim(name);
    if (identifier.length == 0 || trimmed.length == 0) return;
    NSUInteger index = [self.mutableWorkspaces
        indexOfObjectPassingTest:
            ^BOOL(NSDictionary *item, NSUInteger candidate, BOOL *stop) {
        (void)candidate;
        (void)stop;
        return [item[@"id"] isEqualToString:identifier];
    }];
    if (index == NSNotFound) return;
    NSMutableDictionary *updated =
        [self.mutableWorkspaces[index] mutableCopy];
    updated[@"name"] = trimmed;
    updated[@"updated_at"] = @([NSDate date].timeIntervalSince1970);
    self.mutableWorkspaces[index] = updated;
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
    NSTimeInterval duration =
        [updated[@"finished_at"] doubleValue] -
        [updated[@"started_at"] doubleValue];
    BOOL notificationsEnabled =
        [NSUserDefaults.standardUserDefaults
            objectForKey:@"TerminalDBMonitorNotificationsEnabled"] == nil ||
        [NSUserDefaults.standardUserDefaults
            boolForKey:@"TerminalDBMonitorNotificationsEnabled"];
    if (notificationsEnabled &&
        (duration >= 30.0 || exitCode != 0)) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        NSUserNotification *notification =
            [[NSUserNotification alloc] init];
        notification.title = exitCode == 0
            ? @"Command completed" : @"Command needs attention";
        notification.subtitle = updated[@"environment"] ?: @"LOCAL";
        notification.informativeText = [NSString stringWithFormat:
            @"%@ · %.0fs%@",
            updated[@"command"] ?: @"Terminal command",
            MAX(0, duration),
            exitCode == 0 ? @"" :
                [NSString stringWithFormat:@" · exit %ld", (long)exitCode]];
        notification.soundName =
            exitCode == 0 ? nil : NSUserNotificationDefaultSoundName;
        [NSUserNotificationCenter.defaultUserNotificationCenter
            deliverNotification:notification];
#pragma clang diagnostic pop
    }
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
        [self saveRunbookNamed:name
                       command:@"pwd\necho {name}"
                     directory:@"/tmp"];
    BOOL saved = [self.runbooks containsObject:runbook] &&
        [runbook[@"steps"] count] == 2;
    [self updateRunbookWithIdentifier:runbook[@"id"]
                                 name:[name stringByAppendingString:@"-edited"]
                              command:@"pwd\nwhoami"
                            directory:@"/var/tmp"];
    [self markRunbookExecuted:runbook[@"id"]];
    NSDictionary *updatedRunbook =
        [self.runbooks filteredArrayUsingPredicate:
            [NSPredicate predicateWithFormat:@"id == %@",
                runbook[@"id"]]].firstObject;
    saved = saved &&
        [updatedRunbook[@"name"] hasSuffix:@"-edited"] &&
        [updatedRunbook[@"run_count"] integerValue] == 1 &&
        [updatedRunbook[@"steps"] count] == 2;
    [self deleteRunbookWithIdentifier:runbook[@"id"]];
    NSString *monitor = [self beginMonitoringCommand:@"sleep 1"
                                           directory:@"/tmp"
                                         environment:@"LOCAL"];
    [self finishMonitorWithIdentifier:monitor exitCode:0 output:@"done"];
    NSDictionary *result = [self.monitors filteredArrayUsingPredicate:
        [NSPredicate predicateWithFormat:@"id == %@", monitor]].firstObject;
    BOOL monitored = [result[@"state"] isEqualToString:@"DONE"];
    [self removeMonitorWithIdentifier:monitor];
    NSDictionary *workspace = [self saveWorkspaceNamed:name snapshot:@{
        @"tabs" : @[
            @{@"directory":@"/tmp", @"account_label":@"QA",
              @"chat_messages":@[], @"assistant_open":@NO},
            @{@"directory":@"/var/tmp", @"account_label":@"QA",
              @"chat_messages":@[], @"assistant_open":@YES},
        ],
        @"selected_tab" : @1,
        @"splits" : @1,
        @"model" : @"qa-model",
    }];
    BOOL workspaces =
        [workspace[@"tab_count"] integerValue] == 2 &&
        [workspace[@"splits"] integerValue] == 1 &&
        [workspace[@"model"] isEqualToString:@"qa-model"];
    [self renameWorkspaceWithIdentifier:workspace[@"id"]
                                   name:[name stringByAppendingString:@"-renamed"]];
    NSDictionary *renamed =
        [self.workspaces filteredArrayUsingPredicate:
            [NSPredicate predicateWithFormat:@"id == %@",
                workspace[@"id"]]].firstObject;
    workspaces = workspaces &&
        [renamed[@"name"] hasSuffix:@"-renamed"];
    [self deleteWorkspaceWithIdentifier:workspace[@"id"]];
    return saved && monitored && workspaces;
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
@property(nonatomic, strong) NSButton *tertiaryButton;
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
    self.createButton.frame = NSMakeRect(388, 499, 132, 30);
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
    self.detailView = [[NSTextView alloc]
        initWithFrame:detailScroll.contentView.bounds];
    self.detailView.editable = NO;
    self.detailView.selectable = YES;
    self.detailView.verticallyResizable = YES;
    self.detailView.horizontallyResizable = NO;
    self.detailView.autoresizingMask = NSViewWidthSizable;
    self.detailView.minSize =
        NSMakeSize(0, detailScroll.contentView.bounds.size.height);
    self.detailView.maxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
    self.detailView.textContainer.widthTracksTextView = YES;
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
    self.tertiaryButton = [NSButton buttonWithTitle:@"More…"
                                             target:self
                                             action:@selector(tertiarySelected:)];
    self.tertiaryButton.frame = NSMakeRect(722, 62, 122, 32);
    self.tertiaryButton.autoresizingMask = NSViewMaxXMargin;
    [content addSubview:self.tertiaryButton];
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
    NSURL *root = [NSURL fileURLWithPath:self.directory isDirectory:YES];
    NSArray *keys = @[NSURLIsRegularFileKey, NSURLFileSizeKey];
    NSDirectoryEnumerator<NSURL *> *enumerator =
        [NSFileManager.defaultManager
            enumeratorAtURL:root
 includingPropertiesForKeys:keys
                    options:NSDirectoryEnumerationSkipsHiddenFiles |
                            NSDirectoryEnumerationSkipsPackageDescendants
               errorHandler:^BOOL(NSURL *url, NSError *error) {
        (void)url;
        (void)error;
        return YES;
    }];
    NSUInteger count = 0;
    for (NSURL *url in enumerator) {
        if (count >= 120) break;
        NSString *relative = url.path;
        if ([relative hasPrefix:self.directory]) {
            relative = [relative substringFromIndex:self.directory.length];
            if ([relative hasPrefix:@"/"]) {
                relative = [relative substringFromIndex:1];
            }
        }
        if ([relative componentsSeparatedByString:@"/"].count > 4) {
            [enumerator skipDescendants];
            continue;
        }
        NSNumber *regular = nil;
        NSNumber *size = nil;
        [url getResourceValue:&regular
                       forKey:NSURLIsRegularFileKey
                        error:nil];
        if (!regular.boolValue) continue;
        [url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        [items addObject:@{
            @"id" : [@"file:" stringByAppendingString:relative],
            @"name" : relative.length > 0 ? relative : url.lastPathComponent,
            @"detail" : [NSString stringWithFormat:
                @"Project file · %@", [NSByteCountFormatter
                    stringFromByteCount:size.longLongValue
                              countStyle:NSByteCountFormatterCountStyleFile]],
            @"path" : url.path,
            @"directory" : self.directory,
            @"kind" : @"file",
        }];
        count++;
    }
    return items;
}

- (NSArray<NSDictionary *> *)starterRunbooks {
    return @[
        @{@"id":@"starter-repo", @"name":@"/inspect-repository",
          @"detail":@"Branch, status, recent commits, and project size · read-only",
          @"command":@"git status --short --branch\ngit log -5 --oneline",
          @"directory":self.directory, @"builtin":@YES, @"tags":@[@"starter", @"read-only"]},
        @{@"id":@"starter-find", @"name":@"/find-by-extension",
          @"detail":@"Find files by extension · parameter: ext · read-only",
          @"command":@"find . -type f -iname '*.{ext}' | sort",
          @"directory":self.directory, @"builtin":@YES, @"tags":@[@"starter", @"files"]},
        @{@"id":@"starter-large", @"name":@"/largest-files",
          @"detail":@"Show the 20 largest local files · read-only",
          @"command":@"find . -type f -print0 | xargs -0 du -h | sort -hr | head -20",
          @"directory":self.directory, @"builtin":@YES, @"tags":@[@"starter", @"disk"]},
    ];
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
        @{@"id":@"general", @"name":@"General",
          @"detail":@"Startup, workspace restore, and default tab behavior"},
        @{@"id":@"appearance", @"name":@"Appearance",
          @"detail":@"Graphite Ledger, terminal type, contrast, and motion"},
        @{@"id":@"ai", @"name":@"AI & Models",
          @"detail":@"Anthropic API key, live model list, and selected model"},
        @{@"id":@"accounts", @"name":@"Claude Code Accounts",
          @"detail":self.accountLabel},
        @{@"id":@"permissions", @"name":@"Execution Permissions",
          @"detail":@"Review Paste, Run once, and read-only session approvals"},
        @{@"id":@"history", @"name":@"History & Retention",
          @"detail":@"Local database, saved searches, redaction, export, privacy"},
        @{@"id":@"shell", @"name":@"Shell Integration",
          @"detail":@"Command boundaries, paths, status, host, and duration"},
        @{@"id":@"environments", @"name":@"Environments",
          @"detail":@"Local, SSH, container, Kubernetes, and production policy"},
        @{@"id":@"integrations", @"name":@"Integrations · MCP",
          @"detail":@"External tools are disabled until explicitly configured"},
        @{@"id":@"notifications", @"name":@"Notifications",
          @"detail":@"Long-running command completion and stalled alerts"},
        @{@"id":@"keybindings", @"name":@"Keybindings",
          @"detail":@"Terminal, window, split, AI, history, and focus shortcuts"},
        @{@"id":@"advanced", @"name":@"Advanced · About",
          @"detail":@"Diagnostics, storage paths, version, and open-source license"},
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
            self.tertiaryButton.title = @"Ask AI";
            self.tertiaryButton.hidden = NO;
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
            self.tertiaryButton.title = @"Protection info";
            self.tertiaryButton.hidden = NO;
            self.deleteButton.hidden = YES;
            break;
        case TerminalProductSectionMonitor:
            self.eyebrowLabel.stringValue = @"LONG-RUNNING SUPERVISION";
            self.titleLabel.stringValue = @"Monitor center";
            self.subtitleLabel.stringValue =
                @"Watch active work, spot stalls, and inspect completed output.";
            self.items = self.store.monitors.count > 0
                ? self.store.monitors
                : @[@{@"id":@"empty-monitor",
                       @"name":@"No commands are being monitored",
                       @"detail":@"Long-running commands appear here automatically.",
                       @"state":@"IDLE"}];
            self.createButton.title = @"Refresh";
            self.primaryButton.title = @"Jump to tab";
            self.secondaryButton.title = @"Ask AI";
            self.tertiaryButton.title = @"Copy output";
            self.tertiaryButton.hidden = NO;
            self.deleteButton.hidden = NO;
            break;
        case TerminalProductSectionRunbooks:
            self.eyebrowLabel.stringValue = @"REUSABLE WORKFLOWS";
            self.titleLabel.stringValue = @"Runbooks";
            self.subtitleLabel.stringValue =
                @"Save successful commands as inspectable, reusable workflows.";
            self.items = self.store.runbooks.count > 0
                ? self.store.runbooks : [self starterRunbooks];
            self.createButton.title = @"New runbook";
            self.primaryButton.title = @"Run…";
            self.secondaryButton.title = @"Paste";
            self.tertiaryButton.title = @"Edit…";
            self.tertiaryButton.hidden = NO;
            self.deleteButton.hidden = NO;
            break;
        case TerminalProductSectionWorkspaces:
            self.eyebrowLabel.stringValue = @"RESTORABLE CONTEXT";
            self.titleLabel.stringValue = @"Workspaces";
            self.subtitleLabel.stringValue =
                @"Restore the path, account, and conversation purpose together.";
            self.items = self.store.workspaces.count > 0
                ? self.store.workspaces
                : @[@{@"id":@"empty-workspace",
                       @"name":@"Save this terminal as a workspace",
                       @"detail":@"Capture the current path, account, and chat purpose.",
                       @"directory":self.directory, @"empty":@YES}];
            self.createButton.title = @"Save current";
            self.primaryButton.title = @"Restore";
            self.secondaryButton.title = @"Copy path";
            self.tertiaryButton.title = @"Rename…";
            self.tertiaryButton.hidden = NO;
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
            self.tertiaryButton.title = @"Show details";
            self.tertiaryButton.hidden = NO;
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
            self.tertiaryButton.title = @"Back";
            self.tertiaryButton.hidden = NO;
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
        [self updateDetail];
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
    NSDictionary *item = [self selectedItem];
    if (self.section == TerminalProductSectionProject) {
        BOOL file = [item[@"kind"] isEqualToString:@"file"];
        self.primaryButton.title = file ? @"Ask AI" : @"Run…";
        self.secondaryButton.title = file ? @"Copy path" : @"Paste";
        self.tertiaryButton.title = file ? @"Reveal" : @"Ask AI";
    } else if (self.section == TerminalProductSectionEnvironments) {
        NSString *identifier = item[@"id"];
        if ([identifier isEqualToString:@"ssh"]) {
            self.primaryButton.title = @"Connect…";
            self.secondaryButton.title = @"Copy guidance";
        } else if ([identifier isEqualToString:@"containers"]) {
            self.primaryButton.title = @"Inspect contexts";
            self.secondaryButton.title = @"Paste kubectl";
        } else if ([identifier isEqualToString:@"production"]) {
            self.primaryButton.title = @"Protection info";
            self.secondaryButton.title = @"Copy policy";
        } else {
            self.primaryButton.title = @"Inspect local";
            self.secondaryButton.title = @"Copy context";
        }
    }
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
    if ([item[@"tabs"] isKindOfClass:NSArray.class]) {
        [detail appendFormat:@"LAYOUT\n%lu tabs · %@ splits · model %@\n\n",
            (unsigned long)[item[@"tabs"] count],
            item[@"splits"] ?: @0,
            [item[@"model"] length] > 0 ? item[@"model"] : @"saved default"];
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
    if ([item[@"kind"] isEqualToString:@"file"]) {
        NSString *path = item[@"path"];
        NSDictionary *attributes =
            [NSFileManager.defaultManager attributesOfItemAtPath:path
                                                           error:nil];
        unsigned long long size =
            [attributes[NSFileSize] unsignedLongLongValue];
        [detail appendFormat:@"FILE\n%@\n%@\n\n",
            path ?: @"",
            [NSByteCountFormatter
                stringFromByteCount:(long long)size
                          countStyle:NSByteCountFormatterCountStyleFile]];
        if (size <= 256 * 1024) {
            NSString *contents =
                [NSString stringWithContentsOfFile:path
                                          encoding:NSUTF8StringEncoding
                                             error:nil];
            if (contents.length > 0) {
                if (contents.length > 16000) {
                    contents = [[contents substringToIndex:16000]
                        stringByAppendingString:
                            @"\n\n… preview truncated; file is unchanged …"];
                }
                [detail appendFormat:@"PREVIEW\n%@\n", contents];
            } else {
                [detail appendString:@"PREVIEW\nBinary or non-UTF-8 file\n"];
            }
        } else {
            [detail appendString:
                @"PREVIEW\nFile is larger than 256 KB. Preview skipped.\n"];
        }
    }
    if ([item[@"steps"] isKindOfClass:NSArray.class]) {
        [detail appendString:@"STEPS\n"];
        for (NSDictionary *step in item[@"steps"]) {
            [detail appendFormat:@"%@. %@\n",
                step[@"number"] ?: @0, step[@"command"] ?: @""];
        }
        [detail appendString:
            @"\nEach execution still passes through the active permission "
             "policy.\n"];
    }
    self.detailView.string = detail;
}

- (NSArray<NSString *> *)promptRunbookWithTitle:(NSString *)title
                                            name:(NSString *)name
                                         command:(NSString *)command {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = title;
    alert.informativeText =
        @"Enter one command per line. {parameter} placeholders are requested "
         "when the runbook is pasted or run.";
    [alert addButtonWithTitle:@"Save"];
    [alert addButtonWithTitle:@"Cancel"];
    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 560, 260)];
    NSTextField *nameLabel = [NSTextField labelWithString:@"Name"];
    nameLabel.frame = NSMakeRect(0, 236, 560, 18);
    [container addSubview:nameLabel];
    NSTextField *nameField =
        [[NSTextField alloc] initWithFrame:NSMakeRect(0, 204, 560, 26)];
    nameField.stringValue = name ?: @"";
    [container addSubview:nameField];
    NSTextField *stepsLabel =
        [NSTextField labelWithString:@"Steps"];
    stepsLabel.frame = NSMakeRect(0, 180, 560, 18);
    [container addSubview:stepsLabel];
    NSScrollView *scroll =
        [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 560, 174)];
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;
    NSTextView *steps =
        [[NSTextView alloc] initWithFrame:scroll.bounds];
    steps.font = [NSFont monospacedSystemFontOfSize:12
                                             weight:NSFontWeightRegular];
    steps.string = command ?: @"";
    steps.textContainerInset = NSMakeSize(8, 8);
    scroll.documentView = steps;
    [container addSubview:scroll];
    alert.accessoryView = container;
    if ([alert runModal] != NSAlertFirstButtonReturn) return nil;
    return @[TerminalProductTrim(nameField.stringValue),
             TerminalProductTrim(steps.string)];
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
        NSArray *values =
            [self promptRunbookWithTitle:@"New runbook"
                                    name:@"New workflow"
                                 command:@""];
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
            NSDictionary *snapshot = self.workspaceSnapshotProvider
                ? self.workspaceSnapshotProvider() : nil;
            if (snapshot.count > 0) {
                [self.store saveWorkspaceNamed:values[0] snapshot:snapshot];
            } else {
                [self.store saveWorkspaceNamed:values[0]
                                     directory:self.directory
                                  accountLabel:self.accountLabel
                                     chatTitle:@"Current terminal task"];
            }
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
        if (self.section == TerminalProductSectionProject &&
            [item[@"kind"] isEqualToString:@"file"]) {
            NSString *contents =
                [NSString stringWithContentsOfFile:item[@"path"]
                                          encoding:NSUTF8StringEncoding
                                             error:nil] ?: @"";
            if (contents.length > 16000) {
                contents = [contents substringToIndex:16000];
            }
            if (self.askAIHandler) {
                NSMutableDictionary *context = [item mutableCopy];
                context[@"command"] =
                    [NSString stringWithFormat:@"Inspect file: %@",
                        item[@"name"] ?: @""];
                context[@"environment"] = @"LOCAL";
                context[@"state"] = @"FILE";
                context[@"output"] = contents;
                self.askAIHandler(context,
                    @"Review this file in the current project. Summarize its "
                     "purpose, flag likely issues, and propose a minimal diff "
                     "only if a change is warranted.");
            }
            return;
        }
        NSString *command = [self resolvedCommand:item[@"command"]];
        if (command.length > 0 && self.runCommandHandler) {
            if (self.section == TerminalProductSectionRunbooks) {
                NSAlert *preview = [[NSAlert alloc] init];
                preview.alertStyle = NSAlertStyleInformational;
                preview.messageText = [NSString stringWithFormat:
                    @"Run “%@”?", item[@"name"] ?: @"runbook"];
                preview.informativeText = [NSString stringWithFormat:
                    @"Directory: %@\n%lu step%@\n\nEvery step remains subject "
                     "to the active command permission policy.",
                    item[@"directory"] ?: self.directory,
                    (unsigned long)[item[@"steps"] count],
                    [item[@"steps"] count] == 1 ? @"" : @"s"];
                [preview addButtonWithTitle:@"Review & Run"];
                [preview addButtonWithTitle:@"Paste for Review"];
                [preview addButtonWithTitle:@"Cancel"];
                NSScrollView *scroll =
                    [[NSScrollView alloc] initWithFrame:
                        NSMakeRect(0, 0, 560, 190)];
                scroll.hasVerticalScroller = YES;
                scroll.borderType = NSBezelBorder;
                NSTextView *text =
                    [[NSTextView alloc] initWithFrame:scroll.bounds];
                text.editable = NO;
                text.selectable = YES;
                text.font = [NSFont monospacedSystemFontOfSize:11.5
                                                        weight:NSFontWeightRegular];
                text.string = command;
                text.textContainerInset = NSMakeSize(8, 8);
                scroll.documentView = text;
                preview.accessoryView = scroll;
                NSModalResponse response = [preview runModal];
                if (response == NSAlertSecondButtonReturn) {
                    if (self.pasteCommandHandler) {
                        self.pasteCommandHandler(command);
                    }
                    return;
                }
                if (response != NSAlertFirstButtonReturn) return;
                if (![item[@"builtin"] boolValue]) {
                    [self.store markRunbookExecuted:item[@"id"]];
                }
            }
            self.runCommandHandler(command);
        }
    } else if (self.section == TerminalProductSectionWorkspaces) {
        if (![item[@"empty"] boolValue] && self.restoreWorkspaceHandler) {
            self.restoreWorkspaceHandler(item);
        }
    } else if (self.section == TerminalProductSectionSettings &&
               [item[@"id"] isEqualToString:@"ai"]) {
        if (self.openAPISettingsHandler) self.openAPISettingsHandler();
    } else if (self.section == TerminalProductSectionSettings) {
        NSString *identifier = item[@"id"];
        if ([identifier isEqualToString:@"general"]) {
            NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
            BOOL restore =
                [defaults boolForKey:@"TerminalDBRestoreWorkspaceOnLaunch"];
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText = @"General";
            alert.informativeText =
                @"Choose whether TerminalDB should offer to restore the last "
                 "saved workspace at launch.";
            [alert addButtonWithTitle:restore
                ? @"Disable Workspace Restore"
                : @"Enable Workspace Restore"];
            [alert addButtonWithTitle:@"Cancel"];
            if ([alert runModal] == NSAlertFirstButtonReturn) {
                [defaults setBool:!restore
                           forKey:@"TerminalDBRestoreWorkspaceOnLaunch"];
            }
        } else if ([identifier isEqualToString:@"appearance"]) {
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText = @"Appearance";
            alert.informativeText =
                @"TerminalDB uses Graphite Ledger and JetBrains Mono. Text "
                 "size is available from View. Increased Contrast and Reduce "
                 "Motion follow macOS Accessibility settings.";
            [alert runModal];
        } else if ([identifier isEqualToString:@"accounts"]) {
            if (self.addClaudeAccountHandler) {
                self.addClaudeAccountHandler();
            }
        } else if ([identifier isEqualToString:@"history"]) {
            if (self.showHistoryHandler) self.showHistoryHandler();
        } else if ([identifier isEqualToString:@"permissions"]) {
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText = @"Execution permissions";
            alert.informativeText =
                @"Read-only approvals last for the current app session. "
                 "Writes, destructive commands, sudo, and production always "
                 "require a new review.";
            [alert runModal];
        } else if ([identifier isEqualToString:@"shell"]) {
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText = @"Shell integration is active";
            alert.informativeText =
                @"TerminalDB injects a private, per-window zsh configuration "
                 "that reports command boundaries, current directory, exit "
                 "status, title, and duration. It does not edit your shell "
                 "dotfiles.";
            [alert runModal];
        } else if ([identifier isEqualToString:@"environments"]) {
            self.section = TerminalProductSectionEnvironments;
            self.sectionControl.selectedSegment =
                TerminalProductSectionEnvironments;
            [self refresh];
        } else if ([identifier isEqualToString:@"integrations"]) {
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText = @"Integrations · MCP";
            alert.informativeText =
                @"No external integration receives terminal data by default. "
                 "A future connector must expose its permissions and visible "
                 "context before it can be enabled.";
            [alert runModal];
        } else if ([identifier isEqualToString:@"notifications"]) {
            NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
            BOOL enabled =
                [defaults objectForKey:
                    @"TerminalDBMonitorNotificationsEnabled"] == nil ||
                [defaults boolForKey:
                    @"TerminalDBMonitorNotificationsEnabled"];
            [defaults setBool:!enabled
                       forKey:@"TerminalDBMonitorNotificationsEnabled"];
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText = !enabled
                ? @"Monitor notifications enabled"
                : @"Monitor notifications disabled";
            alert.informativeText =
                @"TerminalDB notifies for failed commands and commands that "
                 "run for at least 30 seconds.";
            [alert runModal];
        } else if ([identifier isEqualToString:@"keybindings"]) {
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText = @"Keybindings";
            alert.informativeText =
                @"⌘T New Tab · ⌘D Split Right · ⇧⌘D Split Down\n"
                 "⇧⌘L AI Chat · ⌘Y History · ⇧⌘R Runbooks\n"
                 "⇧⌘F Focus Mode · F6 Cycle Terminal / AI";
            [alert runModal];
        } else if ([identifier isEqualToString:@"advanced"]) {
            [NSApp orderFrontStandardAboutPanel:nil];
        }
    } else if (self.section == TerminalProductSectionEnvironments) {
        NSString *identifier = item[@"id"];
        if ([identifier isEqualToString:@"ssh"]) {
            NSArray *values = [self promptWithTitle:@"Connect over SSH"
                                            labels:@[@"Host or user@host"]
                                          defaults:@[@""]];
            if (values.count == 1 && [values[0] length] > 0 &&
                self.pasteCommandHandler) {
                self.pasteCommandHandler([NSString stringWithFormat:
                    @"ssh %@", values[0]]);
                if (self.activateTerminalHandler) {
                    self.activateTerminalHandler();
                }
            }
        } else if ([identifier isEqualToString:@"containers"]) {
            if (self.runCommandHandler) {
                self.runCommandHandler(
                    @"docker context show 2>/dev/null; "
                     "kubectl config current-context 2>/dev/null");
            }
        } else if ([identifier isEqualToString:@"production"]) {
            [self tertiarySelected:nil];
        } else if (self.runCommandHandler) {
            self.runCommandHandler(@"pwd; hostname; id -un");
        }
    } else if (self.section == TerminalProductSectionMonitor) {
        if (![item[@"id"] isEqualToString:@"empty-monitor"] &&
            self.activateTerminalHandler) {
            self.activateTerminalHandler();
        }
    } else if (self.section == TerminalProductSectionOnboarding) {
        NSInteger step = MAX(0, self.tableView.selectedRow);
        if (step == 1) {
            NSAlert *history = [[NSAlert alloc] init];
            history.messageText = @"Choose a history default";
            history.informativeText =
                @"Local history enables search, bookmarks, and runbooks. "
                 "Private Session can still be enabled per tab.";
            [history addButtonWithTitle:@"Keep Local History"];
            [history addButtonWithTitle:@"Private by Default"];
            [history addButtonWithTitle:@"Cancel"];
            NSModalResponse response = [history runModal];
            if (response == NSAlertThirdButtonReturn) return;
            [NSUserDefaults.standardUserDefaults
                setBool:(response == NSAlertSecondButtonReturn)
                 forKey:@"TerminalDBPrivateSessionDefault"];
        } else if (step == 3 || step == 4) {
            if (self.openAPISettingsHandler) self.openAPISettingsHandler();
        } else if (step == 5) {
            if (self.addClaudeAccountHandler) {
                self.addClaudeAccountHandler();
            }
        } else if (step == 6) {
            NSAlert *permission = [[NSAlert alloc] init];
            permission.messageText = @"Default AI execution permission";
            permission.informativeText =
                @"Paste never executes. Ask Before Running is the safest "
                 "default; validated read-only commands can also be allowed "
                 "automatically for this app session.";
            [permission addButtonWithTitle:@"Ask Before Running"];
            [permission addButtonWithTitle:@"Auto-run Read-only"];
            [permission addButtonWithTitle:@"Paste Only"];
            NSModalResponse response = [permission runModal];
            NSString *mode = response == NSAlertSecondButtonReturn
                ? @"read-only"
                : (response == NSAlertThirdButtonReturn
                    ? @"paste-only" : @"ask");
            [NSUserDefaults.standardUserDefaults
                setObject:mode forKey:@"TerminalDBPermissionMode"];
        } else if (step == 7) {
            [NSUserDefaults.standardUserDefaults
                setBool:YES forKey:@"TerminalDBDidCompleteOnboarding"];
            [self.window close];
            return;
        }
        NSInteger next = MIN(step + 1,
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

- (NSString *)resolvedCommand:(NSString *)command {
    if (command.length == 0) return @"";
    NSRegularExpression *expression =
        [NSRegularExpression regularExpressionWithPattern:@"\\{([A-Za-z_][A-Za-z0-9_-]*)\\}"
                                                  options:0
                                                    error:nil];
    NSArray<NSTextCheckingResult *> *matches =
        [expression matchesInString:command
                            options:0
                              range:NSMakeRange(0, command.length)];
    NSMutableOrderedSet<NSString *> *names =
        [NSMutableOrderedSet orderedSet];
    for (NSTextCheckingResult *match in matches) {
        if (match.numberOfRanges < 2) continue;
        [names addObject:[command substringWithRange:[match rangeAtIndex:1]]];
    }
    if (names.count == 0) return command;
    NSArray<NSString *> *labels =
        [names.array valueForKey:@"capitalizedString"];
    NSArray<NSString *> *defaults = names.array;
    NSArray<NSString *> *values =
        [self promptWithTitle:@"Runbook parameters"
                       labels:labels
                     defaults:defaults];
    if (values == nil) return @"";
    NSString *resolved = command;
    for (NSUInteger index = 0; index < names.count; index++) {
        NSString *hole = [NSString stringWithFormat:@"{%@}", names[index]];
        NSString *value = index < values.count ? values[index] : @"";
        resolved = [resolved stringByReplacingOccurrencesOfString:hole
                                                        withString:value];
    }
    return resolved;
}

- (void)secondarySelected:(id)sender {
    (void)sender;
    NSDictionary *item = [self selectedItem];
    if (item == nil) return;
    if (self.section == TerminalProductSectionMonitor) {
        if ([item[@"id"] isEqualToString:@"empty-monitor"]) return;
        if (self.askAIHandler) {
            self.askAIHandler(item,
                [item[@"state"] isEqualToString:@"FAILED"]
                    ? @"Explain why this monitored command failed and propose "
                      "the safest next step."
                    : @"Summarize this monitored command and its output.");
        }
        return;
    }
    if (self.section == TerminalProductSectionEnvironments) {
        NSString *identifier = item[@"id"];
        NSString *value = item[@"detail"] ?: @"";
        if ([identifier isEqualToString:@"containers"]) {
            value = @"kubectl config get-contexts";
            if (self.pasteCommandHandler) {
                self.pasteCommandHandler(value);
                if (self.activateTerminalHandler) {
                    self.activateTerminalHandler();
                }
                return;
            }
        }
        if (value.length > 0) {
            [NSPasteboard.generalPasteboard clearContents];
            [NSPasteboard.generalPasteboard
                setString:value forType:NSPasteboardTypeString];
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
    NSString *value =
        item[@"command"] ?: item[@"path"] ?: item[@"directory"];
    if (self.section == TerminalProductSectionRunbooks) {
        value = [self resolvedCommand:value];
    }
    if (value.length > 0 && self.pasteCommandHandler) {
        self.pasteCommandHandler(value);
    } else if (value.length > 0) {
        [NSPasteboard.generalPasteboard clearContents];
        [NSPasteboard.generalPasteboard writeObjects:@[value]];
    }
}

- (void)tertiarySelected:(id)sender {
    (void)sender;
    NSDictionary *item = [self selectedItem];
    if (item == nil) return;
    if (self.section == TerminalProductSectionProject) {
        if ([item[@"kind"] isEqualToString:@"file"]) {
            NSString *path = item[@"path"];
            if (path.length > 0) {
                [NSWorkspace.sharedWorkspace
                    activateFileViewerSelectingURLs:
                        @[[NSURL fileURLWithPath:path]]];
            }
        } else if (self.askAIHandler) {
            self.askAIHandler(item,
                @"Inspect this project task and recommend the safest useful "
                 "next action. Use read-only inspection first.");
        }
    } else if (self.section == TerminalProductSectionEnvironments) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = item[@"name"] ?: @"Environment protection";
        alert.informativeText =
            [NSString stringWithFormat:
                @"%@\n\nTerminalDB always displays host, directory, and "
                 "environment before execution. Production commands require "
                 "typed target confirmation and cancel by default.",
                item[@"detail"] ?: @""];
        [alert runModal];
    } else if (self.section == TerminalProductSectionMonitor) {
        NSString *output = item[@"output"] ?: self.detailView.string;
        if (output.length > 0) {
            [NSPasteboard.generalPasteboard clearContents];
            [NSPasteboard.generalPasteboard
                setString:output forType:NSPasteboardTypeString];
        }
    } else if (self.section == TerminalProductSectionRunbooks) {
        if ([item[@"builtin"] boolValue]) {
            NSArray *values =
                [self promptRunbookWithTitle:@"Save starter as a runbook"
                                        name:item[@"name"] ?: @"Runbook"
                                     command:item[@"command"] ?: @""];
            if (values.count == 2 && [values[1] length] > 0) {
                [self.store saveRunbookNamed:values[0]
                                     command:values[1]
                                   directory:item[@"directory"] ?:
                                       self.directory];
            }
        } else {
            NSArray *values =
                [self promptRunbookWithTitle:@"Edit runbook"
                                        name:item[@"name"] ?: @""
                                     command:item[@"command"] ?: @""];
            if (values.count == 2 && [values[1] length] > 0) {
                [self.store updateRunbookWithIdentifier:item[@"id"]
                                                   name:values[0]
                                                command:values[1]
                                              directory:item[@"directory"] ?:
                                                  self.directory];
            }
        }
        [self refresh];
    } else if (self.section == TerminalProductSectionWorkspaces) {
        if ([item[@"empty"] boolValue]) return;
        NSArray *values = [self promptWithTitle:@"Rename workspace"
                                        labels:@[@"Workspace name"]
                                      defaults:@[item[@"name"] ?: @"Workspace"]];
        if (values.count == 1 && [values[0] length] > 0) {
            [self.store renameWorkspaceWithIdentifier:item[@"id"]
                                                 name:values[0]];
            [self refresh];
        }
    } else if (self.section == TerminalProductSectionSettings) {
        [self updateDetail];
    } else if (self.section == TerminalProductSectionOnboarding) {
        NSInteger previous = MAX(0, self.tableView.selectedRow - 1);
        [self.tableView selectRowIndexes:
            [NSIndexSet indexSetWithIndex:(NSUInteger)previous]
                            byExtendingSelection:NO];
    }
}

- (void)deleteSelected:(id)sender {
    (void)sender;
    NSDictionary *item = [self selectedItem];
    if (item == nil) return;
    if ([item[@"builtin"] boolValue] || [item[@"empty"] boolValue]) return;
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
