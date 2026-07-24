#import "TerminalLedger.h"

#import "TerminalTheme.h"

NSNotificationName const TerminalLedgerDidChangeNotification =
    @"TerminalLedgerDidChangeNotification";

static NSString *TerminalLedgerHistoryPath(void) {
    NSString *directory = [NSHomeDirectory()
        stringByAppendingPathComponent:
            @"Library/Application Support/TerminalDB"];
    [NSFileManager.defaultManager
        createDirectoryAtPath:directory
  withIntermediateDirectories:YES
                   attributes:@{NSFilePosixPermissions : @0700}
                        error:nil];
    return [directory stringByAppendingPathComponent:@"command-history.json"];
}

static NSString *TerminalLedgerRedact(NSString *text) {
    if (text.length == 0) return @"";
    NSMutableString *redacted = [text mutableCopy];
    NSArray<NSString *> *patterns = @[
        @"(?i)(sk-ant-[A-Za-z0-9_-]{12})[A-Za-z0-9_-]+",
        @"(?i)(api[_-]?key\\s*[=:]\\s*)[^\\s\"']+",
        @"(?i)(authorization:\\s*bearer\\s+)[A-Za-z0-9._-]+",
        @"(?i)(password\\s*[=:]\\s*)[^\\s\"']+",
    ];
    for (NSString *pattern in patterns) {
        NSRegularExpression *expression =
            [NSRegularExpression regularExpressionWithPattern:pattern
                                                      options:0
                                                        error:nil];
        if (expression == nil) continue;
        [expression replaceMatchesInString:redacted
                                   options:0
                                     range:NSMakeRange(0, redacted.length)
                              withTemplate:@"$1••••••"];
    }
    return redacted;
}

static NSString *TerminalLedgerEnvironment(NSString *command) {
    NSString *lower = command.lowercaseString ?: @"";
    if ([lower containsString:@"production"] ||
        [lower containsString:@"--env prod"] ||
        [lower containsString:@"@prod"] ||
        [lower containsString:@"context prod"]) {
        return @"PRODUCTION";
    }
    if ([lower hasPrefix:@"ssh "] ||
        [lower containsString:@" kubectl "] ||
        [lower hasPrefix:@"kubectl "] ||
        [lower hasPrefix:@"docker "] ||
        [lower hasPrefix:@"docker-compose "]) {
        return @"REMOTE";
    }
    return @"LOCAL";
}

@interface TerminalLedgerStore ()
@property(nonatomic, copy, readwrite) NSArray<NSDictionary *> *records;
@end

@implementation TerminalLedgerStore

+ (instancetype)sharedStore {
    static TerminalLedgerStore *store;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        store = [[TerminalLedgerStore alloc] init];
    });
    return store;
}

+ (BOOL)runPrivacyAndEnvironmentSelfTests {
    NSString *anthropic =
        TerminalLedgerRedact(@"export ANTHROPIC_API_KEY="
                              "sk-ant-example1234567890abcdef");
    NSString *generic =
        TerminalLedgerRedact(@"api_key=terminaldb-test-secret");
    BOOL secretsRedacted =
        ![anthropic containsString:@"7890abcdef"] &&
        [anthropic containsString:@"••••••"] &&
        ![generic containsString:@"terminaldb-test-secret"];
    BOOL environments =
        [TerminalLedgerEnvironment(@"ls -la") isEqualToString:@"LOCAL"] &&
        [TerminalLedgerEnvironment(@"ssh example.test")
            isEqualToString:@"REMOTE"] &&
        [TerminalLedgerEnvironment(@"deploy --env production")
            isEqualToString:@"PRODUCTION"];
    return secretsRedacted && environments;
}

- (instancetype)init {
    self = [super init];
    if (self == nil) return nil;
    NSData *data = [NSData dataWithContentsOfFile:TerminalLedgerHistoryPath()];
    id decoded = data.length > 0
        ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil]
        : nil;
    _records = [decoded isKindOfClass:NSArray.class] ? decoded : @[];
    return self;
}

- (void)persist {
    NSData *data =
        [NSJSONSerialization dataWithJSONObject:self.records
                                         options:0
                                           error:nil];
    if (data == nil) return;
    [data writeToFile:TerminalLedgerHistoryPath()
              options:NSDataWritingAtomic
                error:nil];
    [NSFileManager.defaultManager
        setAttributes:@{NSFilePosixPermissions : @0600}
        ofItemAtPath:TerminalLedgerHistoryPath()
        error:nil];
}

- (void)addCommand:(NSString *)command
          directory:(NSString *)directory
             output:(NSString *)output
           exitCode:(NSInteger)exitCode
           duration:(NSTimeInterval)duration {
    NSString *cleanCommand = TerminalLedgerRedact(
        [command stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet]);
    if (cleanCommand.length == 0) return;
    NSString *cleanOutput = TerminalLedgerRedact(output ?: @"");
    if (cleanOutput.length > 24000) {
        cleanOutput = [NSString stringWithFormat:
            @"… output truncated …\n%@",
            [cleanOutput substringFromIndex:cleanOutput.length - 24000]];
    }
    NSDictionary *record = @{
        @"id" : NSUUID.UUID.UUIDString.lowercaseString,
        @"command" : cleanCommand,
        @"directory" : directory.length > 0 ? directory : NSHomeDirectory(),
        @"output" : cleanOutput,
        @"exit_code" : @(exitCode),
        @"duration" : @(MAX(0, duration)),
        @"timestamp" : @([NSDate date].timeIntervalSince1970),
        @"environment" : TerminalLedgerEnvironment(cleanCommand),
        @"host" : NSHost.currentHost.localizedName ?: @"Mac",
        @"bookmarked" : @NO,
    };
    NSMutableArray *updated = [self.records mutableCopy];
    [updated insertObject:record atIndex:0];
    if (updated.count > 5000) {
        [updated removeObjectsInRange:
            NSMakeRange(5000, updated.count - 5000)];
    }
    self.records = updated;
    [self persist];
    [NSNotificationCenter.defaultCenter
        postNotificationName:TerminalLedgerDidChangeNotification
                      object:self];
}

- (NSArray<NSDictionary *> *)recordsMatching:(NSString *)query {
    NSString *needle =
        [[query ?: @"" stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
    if (needle.length == 0) return self.records;
    NSPredicate *predicate = [NSPredicate predicateWithBlock:
        ^BOOL(NSDictionary *record, NSDictionary *bindings) {
            (void)bindings;
            NSString *haystack = [NSString stringWithFormat:@"%@\n%@\n%@",
                record[@"command"] ?: @"",
                record[@"directory"] ?: @"",
                record[@"output"] ?: @""].lowercaseString;
            return [haystack containsString:needle];
        }];
    return [self.records filteredArrayUsingPredicate:predicate];
}

- (void)clearHistory {
    self.records = @[];
    [self persist];
    [NSNotificationCenter.defaultCenter
        postNotificationName:TerminalLedgerDidChangeNotification
                      object:self];
}

@end

@interface TerminalLedgerBar ()
@property(nonatomic, strong) TerminalTheme *theme;
@property(nonatomic, strong) NSTextField *stateLabel;
@property(nonatomic, strong) NSTextField *commandLabel;
@property(nonatomic, strong) NSTextField *metadataLabel;
@property(nonatomic, strong) NSButton *askButton;
@property(nonatomic, strong) NSButton *pasteButton;
@property(nonatomic, strong) NSButton *historyButton;
@property(nonatomic, copy) NSString *command;
@end

@implementation TerminalLedgerBar

- (instancetype)initWithFrame:(NSRect)frame theme:(TerminalTheme *)theme {
    self = [super initWithFrame:frame];
    if (self == nil) return nil;
    _theme = theme;
    self.wantsLayer = YES;

    _stateLabel = [NSTextField labelWithString:@"READY"];
    _stateLabel.font =
        [NSFont fontWithName:theme.fontName size:9.5]
            ?: [NSFont monospacedSystemFontOfSize:9.5
                                           weight:NSFontWeightSemibold];
    _stateLabel.textColor = theme.ansiColors[6];
    [self addSubview:_stateLabel];

    _commandLabel = [NSTextField labelWithString:@"❯"];
    _commandLabel.font =
        [NSFont fontWithName:theme.fontName size:12.5]
            ?: [NSFont monospacedSystemFontOfSize:12.5
                                           weight:NSFontWeightMedium];
    _commandLabel.textColor = theme.terminalForeground;
    _commandLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [self addSubview:_commandLabel];

    _metadataLabel = [NSTextField labelWithString:@""];
    _metadataLabel.font =
        [NSFont fontWithName:theme.fontName size:9.5]
            ?: [NSFont monospacedSystemFontOfSize:9.5
                                           weight:NSFontWeightRegular];
    _metadataLabel.textColor = theme.statusBarForeground;
    _metadataLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [self addSubview:_metadataLabel];

    _historyButton = [self buttonWithTitle:@"History"
                                    action:@selector(showHistory:)];
    _askButton = [self buttonWithTitle:@"✦ Ask AI"
                                action:@selector(askAI:)];
    _pasteButton = [self buttonWithTitle:@"Paste"
                                  action:@selector(pasteCommand:)];
    [self showReadyInDirectory:NSHomeDirectory()];
    return self;
}

- (BOOL)isFlipped {
    return YES;
}

- (NSButton *)buttonWithTitle:(NSString *)title action:(SEL)action {
    NSButton *button = [[NSButton alloc] initWithFrame:NSZeroRect];
    button.title = title;
    button.bezelStyle = NSBezelStyleAccessoryBarAction;
    button.controlSize = NSControlSizeSmall;
    button.font = [NSFont systemFontOfSize:10 weight:NSFontWeightMedium];
    button.contentTintColor = self.theme.statusBarActiveForeground;
    button.target = self;
    button.action = action;
    [self addSubview:button];
    return button;
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    [[NSColor colorWithSRGBRed:0.071 green:0.082 blue:0.094 alpha:1.0]
        setFill];
    NSRectFill(self.bounds);
    [self.theme.statusBarBorder setFill];
    NSRectFill(NSMakeRect(0, NSHeight(self.bounds) - 1,
                          NSWidth(self.bounds), 1));
}

- (void)layout {
    [super layout];
    CGFloat width = NSWidth(self.bounds);
    CGFloat right = width - 10;
    NSArray<NSButton *> *buttons =
        @[self.historyButton, self.pasteButton, self.askButton];
    for (NSButton *button in buttons) {
        CGFloat buttonWidth =
            MAX(52, button.intrinsicContentSize.width + 14);
        right -= buttonWidth;
        button.frame = NSMakeRect(right, 15, buttonWidth, 26);
        right -= 6;
    }
    self.stateLabel.frame = NSMakeRect(12, 9, 76, 14);
    self.commandLabel.frame =
        NSMakeRect(12, 25, MAX(80, right - 22), 19);
    self.metadataLabel.frame =
        NSMakeRect(96, 8, MAX(40, right - 106), 15);
}

- (void)showReadyInDirectory:(NSString *)directory {
    self.command = @"";
    self.stateLabel.stringValue = @"READY";
    self.stateLabel.textColor = self.theme.ansiColors[6];
    self.commandLabel.stringValue = @"❯  shell ready";
    self.metadataLabel.stringValue = [NSString stringWithFormat:
        @"%@  ·  LOCAL", directory.length > 0 ? directory : @"~"];
    self.askButton.title = @"✦ Ask AI";
    self.askButton.enabled = NO;
    self.pasteButton.enabled = NO;
    [self setNeedsLayout:YES];
}

- (void)beginCommand:(NSString *)command directory:(NSString *)directory {
    self.command = command ?: @"";
    self.stateLabel.stringValue = @"RUNNING";
    self.stateLabel.textColor = self.theme.ansiColors[3];
    self.commandLabel.stringValue = [NSString stringWithFormat:
        @"❯  %@", command.length > 0 ? command : @"command"];
    self.metadataLabel.stringValue = [NSString stringWithFormat:
        @"%@  ·  %@  ·  started now",
        directory.length > 0 ? directory : @"~",
        TerminalLedgerEnvironment(command)];
    self.askButton.title = @"✦ Ask AI";
    self.askButton.enabled = command.length > 0;
    self.pasteButton.enabled = NO;
    [self setNeedsLayout:YES];
}

- (void)finishCommand:(NSString *)command
             directory:(NSString *)directory
              exitCode:(NSInteger)exitCode
              duration:(NSTimeInterval)duration {
    self.command = command ?: @"";
    self.stateLabel.stringValue =
        exitCode == 0 ? @"EXIT 0" : [NSString stringWithFormat:
            @"EXIT %ld", (long)exitCode];
    self.stateLabel.textColor =
        exitCode == 0 ? self.theme.ansiColors[2] : self.theme.ansiColors[1];
    self.commandLabel.stringValue = [NSString stringWithFormat:
        @"❯  %@", command.length > 0 ? command : @"command"];
    self.metadataLabel.stringValue = [NSString stringWithFormat:
        @"%@  ·  %@  ·  %.2fs",
        directory.length > 0 ? directory : @"~",
        TerminalLedgerEnvironment(command), duration];
    self.askButton.title =
        exitCode == 0 ? @"✦ Ask AI" : @"✦ Explain / Fix";
    self.askButton.enabled = command.length > 0;
    self.pasteButton.enabled = command.length > 0;
    [self setNeedsLayout:YES];
}

- (void)askAI:(id)sender {
    (void)sender;
    if (self.command.length > 0 && self.askHandler != nil) {
        self.askHandler(self.command);
    }
}

- (void)pasteCommand:(id)sender {
    (void)sender;
    if (self.command.length > 0 && self.pasteHandler != nil) {
        self.pasteHandler(self.command);
    }
}

- (void)showHistory:(id)sender {
    (void)sender;
    if (self.historyHandler != nil) self.historyHandler();
}

@end

@interface TerminalLedgerWindowController ()
@property(nonatomic, strong) TerminalLedgerStore *store;
@property(nonatomic, strong) TerminalTheme *theme;
@property(nonatomic, strong) NSSearchField *searchField;
@property(nonatomic, strong) NSTableView *tableView;
@property(nonatomic, strong) NSTextView *detailView;
@property(nonatomic, copy) NSArray<NSDictionary *> *filteredRecords;
@end

@implementation TerminalLedgerWindowController

- (instancetype)initWithStore:(TerminalLedgerStore *)store
                         theme:(TerminalTheme *)theme {
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 940, 580)
                  styleMask:NSWindowStyleMaskTitled |
                            NSWindowStyleMaskClosable |
                            NSWindowStyleMaskMiniaturizable |
                            NSWindowStyleMaskResizable
                    backing:NSBackingStoreBuffered
                      defer:NO];
    window.title = @"TerminalDB — Command History";
    window.contentMinSize = NSMakeSize(720, 440);
    window.backgroundColor = theme.terminalBackground;
    self = [super initWithWindow:window];
    if (self == nil) return nil;
    _store = store;
    _theme = theme;
    _filteredRecords = store.records;
    [self buildUI];
    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(historyChanged:)
               name:TerminalLedgerDidChangeNotification
             object:store];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)buildUI {
    NSView *content = self.window.contentView;
    content.wantsLayer = YES;
    content.layer.backgroundColor = self.theme.terminalBackground.CGColor;

    self.searchField =
        [[NSSearchField alloc] initWithFrame:NSMakeRect(18, 535, 440, 28)];
    self.searchField.placeholderString =
        @"Search commands, paths, or output";
    self.searchField.delegate = self;
    [content addSubview:self.searchField];

    NSTextField *privacy = [NSTextField labelWithString:
        @"LOCAL LEDGER · secrets redacted · stored only on this Mac"];
    privacy.font =
        [NSFont fontWithName:self.theme.fontName size:9.5]
            ?: [NSFont monospacedSystemFontOfSize:9.5
                                           weight:NSFontWeightRegular];
    privacy.textColor = self.theme.ansiColors[6];
    privacy.frame = NSMakeRect(480, 540, 430, 18);
    privacy.alignment = NSTextAlignmentRight;
    [content addSubview:privacy];

    NSScrollView *tableScroll =
        [[NSScrollView alloc] initWithFrame:NSMakeRect(18, 84, 470, 438)];
    tableScroll.hasVerticalScroller = YES;
    tableScroll.borderType = NSBezelBorder;
    tableScroll.drawsBackground = YES;
    tableScroll.backgroundColor = self.theme.terminalBackground;
    self.tableView = [[NSTableView alloc] initWithFrame:tableScroll.bounds];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.usesAlternatingRowBackgroundColors = NO;
    self.tableView.backgroundColor = self.theme.terminalBackground;
    self.tableView.rowHeight = 27;
    NSArray *columns = @[
        @[@"command", @"Command", @285],
        @[@"status", @"Status", @72],
        @[@"duration", @"Time", @82],
    ];
    for (NSArray *definition in columns) {
        NSTableColumn *column =
            [[NSTableColumn alloc] initWithIdentifier:definition[0]];
        column.title = definition[1];
        column.width = [definition[2] doubleValue];
        [self.tableView addTableColumn:column];
    }
    self.tableView.headerView =
        [[NSTableHeaderView alloc] initWithFrame:NSMakeRect(0, 0, 0, 24)];
    tableScroll.documentView = self.tableView;
    [content addSubview:tableScroll];

    NSScrollView *detailScroll =
        [[NSScrollView alloc] initWithFrame:NSMakeRect(502, 84, 420, 438)];
    detailScroll.hasVerticalScroller = YES;
    detailScroll.borderType = NSBezelBorder;
    self.detailView = [[NSTextView alloc] initWithFrame:detailScroll.bounds];
    self.detailView.editable = NO;
    self.detailView.selectable = YES;
    self.detailView.drawsBackground = YES;
    self.detailView.backgroundColor =
        [NSColor colorWithSRGBRed:0.071 green:0.082 blue:0.094 alpha:1.0];
    self.detailView.textColor = self.theme.terminalForeground;
    self.detailView.font =
        [NSFont fontWithName:self.theme.fontName size:11.5]
            ?: [NSFont monospacedSystemFontOfSize:11.5
                                           weight:NSFontWeightRegular];
    self.detailView.textContainerInset = NSMakeSize(12, 12);
    detailScroll.documentView = self.detailView;
    [content addSubview:detailScroll];

    NSButton *paste = [NSButton buttonWithTitle:@"Paste into Terminal"
                                         target:self
                                         action:@selector(pasteSelected:)];
    paste.frame = NSMakeRect(502, 30, 142, 32);
    [content addSubview:paste];
    NSButton *ask = [NSButton buttonWithTitle:@"✦ Ask AI"
                                       target:self
                                       action:@selector(askSelected:)];
    ask.frame = NSMakeRect(654, 30, 110, 32);
    [content addSubview:ask];
    NSButton *clear = [NSButton buttonWithTitle:@"Clear History…"
                                         target:self
                                         action:@selector(clearHistory:)];
    clear.frame = NSMakeRect(790, 30, 132, 32);
    clear.contentTintColor = self.theme.ansiColors[1];
    [content addSubview:clear];
    [self reload];
}

- (void)historyChanged:(NSNotification *)notification {
    (void)notification;
    [self reload];
}

- (void)reload {
    self.filteredRecords =
        [self.store recordsMatching:self.searchField.stringValue];
    [self.tableView reloadData];
    if (self.filteredRecords.count > 0) {
        [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0]
                   byExtendingSelection:NO];
        [self updateDetail];
    } else {
        self.detailView.string =
            @"No matching commands.\n\nRun a command in TerminalDB and it "
             "will appear here after the shell prompt returns.";
    }
}

- (void)controlTextDidChange:(NSNotification *)notification {
    if (notification.object == self.searchField) [self reload];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    (void)tableView;
    return (NSInteger)self.filteredRecords.count;
}

- (nullable NSView *)tableView:(NSTableView *)tableView
            viewForTableColumn:(NSTableColumn *)tableColumn
                           row:(NSInteger)row {
    (void)tableView;
    if (row < 0 || (NSUInteger)row >= self.filteredRecords.count) return nil;
    NSDictionary *record = self.filteredRecords[(NSUInteger)row];
    NSTextField *field = [NSTextField labelWithString:@""];
    field.font =
        [NSFont fontWithName:self.theme.fontName size:10.5]
            ?: [NSFont monospacedSystemFontOfSize:10.5
                                           weight:NSFontWeightRegular];
    field.textColor = self.theme.terminalForeground;
    field.lineBreakMode = NSLineBreakByTruncatingMiddle;
    NSString *identifier = tableColumn.identifier;
    if ([identifier isEqualToString:@"command"]) {
        field.stringValue = record[@"command"] ?: @"";
    } else if ([identifier isEqualToString:@"status"]) {
        NSInteger code = [record[@"exit_code"] integerValue];
        field.stringValue =
            code == 0 ? @"✓ exit 0" : [NSString stringWithFormat:
                @"× exit %ld", (long)code];
        field.textColor =
            code == 0 ? self.theme.ansiColors[2] : self.theme.ansiColors[1];
    } else {
        field.stringValue = [NSString stringWithFormat:@"%.2fs",
            [record[@"duration"] doubleValue]];
        field.textColor = self.theme.statusBarActiveForeground;
    }
    return field;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    (void)notification;
    [self updateDetail];
}

- (nullable NSDictionary *)selectedRecord {
    NSInteger row = self.tableView.selectedRow;
    return row >= 0 && (NSUInteger)row < self.filteredRecords.count
        ? self.filteredRecords[(NSUInteger)row]
        : nil;
}

- (void)updateDetail {
    NSDictionary *record = [self selectedRecord];
    if (record == nil) return;
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:
        [record[@"timestamp"] doubleValue]];
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateStyle = NSDateFormatterMediumStyle;
    formatter.timeStyle = NSDateFormatterMediumStyle;
    self.detailView.string = [NSString stringWithFormat:
        @"❯ %@\n\n%@ · %@ · exit %@ · %.2fs\n%@\n\n%@",
        record[@"command"] ?: @"",
        record[@"directory"] ?: @"",
        record[@"environment"] ?: @"LOCAL",
        record[@"exit_code"] ?: @(-1),
        [record[@"duration"] doubleValue],
        [formatter stringFromDate:date],
        record[@"output"] ?: @"(no captured output)"];
}

- (void)pasteSelected:(id)sender {
    (void)sender;
    NSString *command = [self selectedRecord][@"command"];
    if (command.length > 0 && self.pasteHandler != nil) {
        self.pasteHandler(command);
    }
}

- (void)askSelected:(id)sender {
    (void)sender;
    NSString *command = [self selectedRecord][@"command"];
    if (command.length > 0 && self.askHandler != nil) {
        self.askHandler(command);
    }
}

- (void)clearHistory:(id)sender {
    (void)sender;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Clear local command history?";
    alert.informativeText =
        @"This permanently removes TerminalDB’s local command ledger. "
         "Your shell history is not changed.";
    [alert addButtonWithTitle:@"Clear History"];
    [alert addButtonWithTitle:@"Cancel"];
    alert.alertStyle = NSAlertStyleWarning;
    if ([alert runModal] == NSAlertFirstButtonReturn) {
        [self.store clearHistory];
    }
}

@end
