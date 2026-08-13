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
    NSArray<NSArray<NSString *> *> *rules = @[
        @[@"(?i)(sk-ant-[A-Za-z0-9_-]{8})[A-Za-z0-9_-]+",
          @"$1••••••"],
        @[@"(?i)(gh[pousr]_[A-Za-z0-9]{8})[A-Za-z0-9]+",
          @"$1••••••"],
        @[@"(?i)(xox[baprs]-[A-Za-z0-9-]{8})[A-Za-z0-9-]+",
          @"$1••••••"],
        @[@"(?i)((?:AKIA|ASIA)[A-Z0-9]{4})[A-Z0-9]{12}",
          @"$1••••••"],
        @[@"(?i)((?:api[_-]?key|access[_-]?key|token|password|secret)\\s*[=:]\\s*[\"']?)[^\\s\"']+([\"']?)",
          @"$1••••••$2"],
        @[@"(?i)((?:--password|--token|--api-key|--secret)(?:=|\\s+)[\"']?)[^\\s\"']+([\"']?)",
          @"$1••••••$2"],
        @[@"(?i)(authorization:\\s*(?:bearer|basic)\\s+)[A-Za-z0-9._~+/=-]+",
          @"$1••••••"],
    ];
    for (NSArray<NSString *> *rule in rules) {
        NSRegularExpression *expression =
            [NSRegularExpression regularExpressionWithPattern:rule[0]
                                                      options:0
                                                        error:nil];
        if (expression == nil) continue;
        [expression replaceMatchesInString:redacted
                                   options:0
                                     range:NSMakeRange(0, redacted.length)
                              withTemplate:rule[1]];
    }
    return redacted;
}

static NSString *TerminalLedgerTail(NSString *text, NSUInteger maximumLength) {
    if (text.length <= maximumLength) return text ?: @"";
    NSUInteger approximateStart = text.length - maximumLength;
    NSRange composed =
        [text rangeOfComposedCharacterSequenceAtIndex:approximateStart];
    return [text substringFromIndex:composed.location];
}

static NSDictionary *TerminalLedgerSanitizedRecord(id candidate) {
    if (![candidate isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *record = candidate;
    if (![record[@"id"] isKindOfClass:NSString.class] ||
        ![record[@"command"] isKindOfClass:NSString.class]) {
        return nil;
    }
    NSMutableDictionary *clean = [record mutableCopy];
    for (NSString *key in @[
            @"command", @"directory", @"output", @"environment", @"host",
            @"project",
        ]) {
        if (clean[key] != nil && ![clean[key] isKindOfClass:NSString.class]) {
            [clean removeObjectForKey:key];
        }
    }
    for (NSString *key in @[
            @"exit_code", @"duration", @"timestamp", @"bookmarked",
            @"truncated",
        ]) {
        if (clean[key] != nil && ![clean[key] isKindOfClass:NSNumber.class]) {
            [clean removeObjectForKey:key];
        }
    }
    // Keep legacy note data intact when reading existing history even though
    // the product no longer creates or displays notes.
    for (NSString *key in @[@"annotations", @"tags"]) {
        if (clean[key] != nil && ![clean[key] isKindOfClass:NSArray.class]) {
            [clean removeObjectForKey:key];
        }
    }
    if (clean[@"approval"] != nil &&
        ![clean[@"approval"] isKindOfClass:NSDictionary.class]) {
        [clean removeObjectForKey:@"approval"];
    }
    return clean;
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

static NSString *TerminalLedgerProject(NSString *directory) {
    NSString *candidate =
        directory.length > 0 ? directory.stringByStandardizingPath : @"";
    NSFileManager *files = NSFileManager.defaultManager;
    BOOL isDirectory = NO;
    while (candidate.length > 1) {
        NSString *gitPath = [candidate stringByAppendingPathComponent:@".git"];
        if ([files fileExistsAtPath:gitPath isDirectory:&isDirectory]) {
            return candidate.lastPathComponent.length > 0
                ? candidate.lastPathComponent
                : candidate;
        }
        NSString *parent = candidate.stringByDeletingLastPathComponent;
        if ([parent isEqualToString:candidate]) break;
        candidate = parent;
    }
    return directory.lastPathComponent.length > 0
        ? directory.lastPathComponent
        : @"Shell";
}

static NSString *TerminalLedgerCSVCell(id value) {
    NSString *text = [value isKindOfClass:NSString.class]
        ? value
        : [value description] ?: @"";
    text = [text stringByReplacingOccurrencesOfString:@"\""
                                           withString:@"\"\""];
    return [NSString stringWithFormat:@"\"%@\"", text];
}

@interface TerminalLedgerStore ()
@property(nonatomic, copy, readwrite) NSArray<NSDictionary *> *records;
@property(nonatomic) BOOL ephemeral;
@end

@class TerminalCommandInspectorController;

@interface TerminalCommandInspectorPanelView : NSView
@property(nonatomic, weak) TerminalCommandInspectorController *controller;
@end

@interface TerminalCommandInspectorController ()
@property(nonatomic, strong) TerminalLedgerStore *store;
@property(nonatomic, strong) TerminalTheme *theme;
@property(nonatomic, copy, nullable) NSDictionary *record;
@property(nonatomic, strong, readwrite) NSView *panelView;
@property(nonatomic, strong) NSTextField *titleLabel;
@property(nonatomic, strong) NSTextField *commandLabel;
@property(nonatomic, strong) NSTextField *statusLabel;
@property(nonatomic, strong) NSTextField *metadataLabel;
@property(nonatomic, strong) NSTextField *outputTitleLabel;
@property(nonatomic, strong) NSScrollView *outputScroll;
@property(nonatomic, strong) NSTextView *outputView;
@property(nonatomic, strong) NSButton *commandCopyButton;
@property(nonatomic, strong) NSButton *askButton;
@property(nonatomic, strong) NSButton *rerunButton;
@property(nonatomic, strong) NSButton *moreButton;
@property(nonatomic, strong) NSTextField *privacyLabel;
- (void)layoutPanel;
- (NSMenu *)moreActionsMenu;
@end

@implementation TerminalCommandInspectorPanelView

- (BOOL)isFlipped {
    return YES;
}

- (void)layout {
    [super layout];
    [self.controller layoutPanel];
}

@end

@implementation TerminalCommandInspectorController

- (instancetype)initWithStore:(TerminalLedgerStore *)store
                         theme:(TerminalTheme *)theme {
    self = [super init];
    if (self == nil) return nil;
    _store = store;
    _theme = theme;
    TerminalCommandInspectorPanelView *panel =
        [[TerminalCommandInspectorPanelView alloc]
            initWithFrame:NSMakeRect(0, 0, 620, 720)];
    panel.controller = self;
    panel.wantsLayer = YES;
    panel.layer.backgroundColor = theme.terminalBackground.CGColor;
    [panel setAccessibilityElement:YES];
    [panel setAccessibilityRole:NSAccessibilityGroupRole];
    [panel setAccessibilityLabel:@"Command details"];
    _panelView = panel;
    [self buildUI];
    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(storeChanged:)
               name:TerminalLedgerDidChangeNotification
             object:store];
    return self;
}

+ (BOOL)runInterfaceSelfTests {
    TerminalCommandInspectorController *controller =
        [[TerminalCommandInspectorController alloc]
            initWithStore:[TerminalLedgerStore ephemeralStoreForTesting]
                   theme:[TerminalTheme preferredTheme]];
    [controller presentRecord:@{
        @"id" : @"interface-test",
        @"command" : @"printf 'ready'",
        @"directory" : @"/tmp",
        @"host" : @"Test Mac",
        @"environment" : @"LOCAL",
        @"project" : @"test",
        @"output" : @"ready",
        @"exit_code" : @0,
        @"duration" : @0.01,
        @"timestamp" : @([NSDate date].timeIntervalSince1970),
        @"bookmarked" : @NO,
    }];
    controller.panelView.frame = NSMakeRect(0, 0, 520, 720);
    [controller.panelView layoutSubtreeIfNeeded];
    CGFloat firstGap = NSMinX(controller.rerunButton.frame) -
        NSMaxX(controller.askButton.frame);
    CGFloat secondGap = NSMinX(controller.moreButton.frame) -
        NSMaxX(controller.rerunButton.frame);
    NSArray<NSString *> *moreTitles =
        [controller.moreActionsMenu.itemArray valueForKey:@"title"];
    BOOL successState = [controller.titleLabel.stringValue
                isEqualToString:@"COMPLETED COMMAND"] &&
        [controller.askButton.title isEqualToString:@"Ask AI"] &&
        [controller.rerunButton.title isEqualToString:@"Run again"] &&
        [controller.moreButton.title isEqualToString:@"More…"] &&
        firstGap >= 12.0 && secondGap >= 12.0 &&
        NSHeight(controller.outputScroll.frame) >= 410.0 &&
        NSMaxY(controller.outputScroll.frame) <=
            NSMinY(controller.privacyLabel.frame) - 10.0 &&
        [controller.privacyLabel.stringValue
            isEqualToString:@"LOCAL ONLY · output stays on this Mac"] &&
        controller.panelView.window == nil &&
        [moreTitles containsObject:@"Copy Command"] &&
        [moreTitles containsObject:@"Copy Output"] &&
        [moreTitles containsObject:@"Paste Command for Review"] &&
        [moreTitles containsObject:@"Save as Playbook"] &&
        [moreTitles containsObject:@"Export Command Block…"];
    [controller presentRecord:@{
        @"id" : @"interface-failure-test",
        @"command" : @"false",
        @"output" : @"command failed",
        @"exit_code" : @1,
        @"timestamp" : @([NSDate date].timeIntervalSince1970),
    }];
    return successState &&
        [controller.askButton.title isEqualToString:@"Explain & fix"] &&
        [controller.statusLabel.stringValue isEqualToString:@"× EXIT 1"];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (NSTextField *)label:(NSString *)text
                 frame:(NSRect)frame
                  font:(NSFont *)font
                 color:(NSColor *)color {
    NSTextField *label = [NSTextField labelWithString:text ?: @""];
    label.frame = frame;
    label.font = font;
    label.textColor = color;
    label.lineBreakMode = NSLineBreakByTruncatingMiddle;
    return label;
}

- (NSButton *)button:(NSString *)title
               frame:(NSRect)frame
              action:(SEL)action {
    NSButton *button = [NSButton buttonWithTitle:title
                                          target:self
                                          action:action];
    button.frame = frame;
    button.bezelStyle = NSBezelStyleRounded;
    button.controlSize = NSControlSizeRegular;
    return button;
}

- (void)buildUI {
    NSView *content = self.panelView;
    NSFont *mono = [NSFont fontWithName:self.theme.fontName size:11.5]
        ?: [NSFont monospacedSystemFontOfSize:11.5
                                       weight:NSFontWeightRegular];
    self.titleLabel = [self label:@"COMPLETED COMMAND"
                            frame:NSZeroRect
                             font:[NSFont systemFontOfSize:10
                                                   weight:NSFontWeightSemibold]
                            color:self.theme.ansiColors[6]];
    [content addSubview:self.titleLabel];
    self.statusLabel = [self label:@""
                             frame:NSZeroRect
                              font:[NSFont monospacedSystemFontOfSize:10.5
                                                              weight:NSFontWeightSemibold]
                             color:self.theme.ansiColors[2]];
    self.statusLabel.alignment = NSTextAlignmentRight;
    [content addSubview:self.statusLabel];
    self.commandLabel = [NSTextField wrappingLabelWithString:@""];
    self.commandLabel.font = [NSFont fontWithName:self.theme.fontName size:14]
        ?: [NSFont monospacedSystemFontOfSize:14
                                       weight:NSFontWeightMedium];
    self.commandLabel.textColor = self.theme.terminalForeground;
    self.commandLabel.maximumNumberOfLines = 2;
    self.commandLabel.selectable = YES;
    [content addSubview:self.commandLabel];
    self.commandCopyButton = [self button:@"Copy"
                             frame:NSZeroRect
                            action:@selector(copyCommand:)];
    self.commandCopyButton.controlSize = NSControlSizeSmall;
    [content addSubview:self.commandCopyButton];
    self.metadataLabel = [NSTextField wrappingLabelWithString:@""];
    self.metadataLabel.font = [NSFont fontWithName:self.theme.fontName size:10.5]
        ?: [NSFont monospacedSystemFontOfSize:10.5
                                       weight:NSFontWeightRegular];
    self.metadataLabel.textColor = self.theme.statusBarActiveForeground;
    self.metadataLabel.maximumNumberOfLines = 2;
    [content addSubview:self.metadataLabel];

    self.askButton = [self button:@"Ask AI"
                            frame:NSZeroRect
                           action:@selector(askAI:)];
    self.askButton.contentTintColor = self.theme.ansiColors[6];
    [content addSubview:self.askButton];
    self.rerunButton = [self button:@"Run again"
                              frame:NSZeroRect
                             action:@selector(rerunCommand:)];
    [content addSubview:self.rerunButton];
    self.moreButton = [self button:@"More…"
                             frame:NSZeroRect
                            action:@selector(showMoreActions:)];
    [content addSubview:self.moreButton];

    self.outputTitleLabel = [self label:@"OUTPUT"
                                    frame:NSZeroRect
                                     font:[NSFont systemFontOfSize:10
                                                           weight:NSFontWeightSemibold]
                                    color:self.theme.ansiColors[3]];
    [content addSubview:self.outputTitleLabel];
    self.outputScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    self.outputScroll.hasVerticalScroller = YES;
    self.outputScroll.autohidesScrollers = YES;
    self.outputScroll.borderType = NSBezelBorder;
    self.outputView = [[NSTextView alloc]
        initWithFrame:self.outputScroll.bounds];
    self.outputView.editable = NO;
    self.outputView.selectable = YES;
    self.outputView.drawsBackground = YES;
    self.outputView.backgroundColor =
        [NSColor colorWithSRGBRed:0.055 green:0.063 blue:0.071 alpha:1];
    self.outputView.textColor = self.theme.terminalForeground;
    self.outputView.font = mono;
    self.outputView.textContainerInset = NSMakeSize(12, 12);
    self.outputView.verticallyResizable = YES;
    self.outputView.horizontallyResizable = NO;
    self.outputView.textContainer.widthTracksTextView = YES;
    self.outputView.autoresizingMask = NSViewWidthSizable;
    self.outputScroll.documentView = self.outputView;
    [content addSubview:self.outputScroll];

    self.privacyLabel = [self label:
        @"LOCAL ONLY · output stays on this Mac"
        frame:NSZeroRect
         font:[NSFont fontWithName:self.theme.fontName size:9.5] ?: mono
        color:self.theme.statusBarForeground];
    self.privacyLabel.alignment = NSTextAlignmentCenter;
    [content addSubview:self.privacyLabel];
    [self.panelView setNeedsLayout:YES];
}

- (void)layoutPanel {
    CGFloat width = NSWidth(self.panelView.bounds);
    CGFloat height = NSHeight(self.panelView.bounds);
    CGFloat inset = 20;
    CGFloat contentWidth = MAX(1, width - inset * 2);
    self.titleLabel.frame = NSMakeRect(inset, 18,
        MAX(1, contentWidth - 130), 18);
    self.statusLabel.frame = NSMakeRect(width - inset - 122, 16, 122, 20);
    self.commandCopyButton.frame =
        NSMakeRect(width - inset - 70, 50, 70, 30);
    self.commandLabel.frame = NSMakeRect(inset, 48,
        MAX(1, contentWidth - 82), 42);
    self.metadataLabel.frame = NSMakeRect(inset, 96, contentWidth, 34);
    self.askButton.frame = NSMakeRect(inset, 142, 142, 36);
    self.rerunButton.frame = NSMakeRect(inset + 154, 142, 122, 36);
    self.moreButton.frame = NSMakeRect(inset + 288, 142, 100, 36);
    self.outputTitleLabel.frame = NSMakeRect(inset, 194, contentWidth, 18);
    CGFloat privacyY = MAX(394, height - 64);
    self.outputScroll.frame = NSMakeRect(inset, 218, contentWidth,
        MAX(160, privacyY - 230));
    NSSize outputSize = self.outputScroll.contentSize;
    self.outputView.frame = NSMakeRect(0, 0, outputSize.width,
                                      MAX(1, outputSize.height));
    self.privacyLabel.frame = NSMakeRect(inset, privacyY, contentWidth, 18);
}

- (void)presentRecord:(NSDictionary *)record {
    self.record = record;
    [self refresh];
    [self.panelView setNeedsLayout:YES];
}

- (void)storeChanged:(NSNotification *)notification {
    (void)notification;
    NSString *identifier = self.record[@"id"];
    NSDictionary *updated = [self.store recordWithIdentifier:identifier];
    if (updated != nil) {
        self.record = updated;
        [self refresh];
    }
}

- (void)refresh {
    NSDictionary *record = self.record;
    if (record == nil) return;
    NSString *identifier = record[@"id"] ?: @"";
    self.titleLabel.stringValue = @"COMPLETED COMMAND";
    self.titleLabel.toolTip = identifier.length > 0
        ? [NSString stringWithFormat:@"Command block %@", identifier]
        : nil;
    self.commandLabel.stringValue =
        [NSString stringWithFormat:@"❯ %@", record[@"command"] ?: @""];
    NSInteger exitCode = [record[@"exit_code"] integerValue];
    self.statusLabel.stringValue = exitCode == 0
        ? @"✓ SUCCEEDED"
        : [NSString stringWithFormat:@"× EXIT %ld", (long)exitCode];
    self.statusLabel.textColor =
        exitCode == 0 ? self.theme.ansiColors[2] : self.theme.ansiColors[1];
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:
        [record[@"timestamp"] doubleValue]];
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateStyle = NSDateFormatterMediumStyle;
    formatter.timeStyle = NSDateFormatterMediumStyle;
    self.metadataLabel.stringValue = [NSString stringWithFormat:
        @"%@ · %@ · %@ · %@ · %.2fs · %@",
        record[@"directory"] ?: @"~",
        record[@"host"] ?: @"Mac",
        record[@"environment"] ?: @"LOCAL",
        record[@"project"] ?: @"Shell",
        [record[@"duration"] doubleValue],
        [formatter stringFromDate:date]];
    NSDictionary *approval =
        [record[@"approval"] isKindOfClass:NSDictionary.class]
            ? record[@"approval"] : nil;
    if (approval != nil) {
        self.metadataLabel.stringValue =
            [self.metadataLabel.stringValue stringByAppendingFormat:
                @" · approved %@ (%@)",
                approval[@"mode"] ?: @"once",
                approval[@"risk"] ?: @"reviewed"];
    }
    self.outputView.string = record[@"output"] ?: @"(no captured output)";
    self.askButton.title = exitCode == 0 ? @"Ask AI" : @"Explain & fix";
    [self.panelView setNeedsLayout:YES];
}

- (NSString *)command {
    return [self.record[@"command"] isKindOfClass:NSString.class]
        ? self.record[@"command"] : @"";
}

- (void)copyCommand:(id)sender {
    (void)sender;
    if (self.command.length == 0) return;
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:self.command
                                       forType:NSPasteboardTypeString];
}

- (void)copyOutput:(id)sender {
    (void)sender;
    NSString *output = [self.record[@"output"] isKindOfClass:NSString.class]
        ? self.record[@"output"] : @"";
    if (output.length == 0) return;
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:output
                                       forType:NSPasteboardTypeString];
}

- (NSMenuItem *)menuItem:(NSString *)title action:(SEL)action {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
                                                  action:action
                                           keyEquivalent:@""];
    item.target = self;
    return item;
}

- (NSMenu *)moreActionsMenu {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Command actions"];
    [menu addItem:[self menuItem:@"Copy Command" action:@selector(copyCommand:)]];
    [menu addItem:[self menuItem:@"Copy Output" action:@selector(copyOutput:)]];
    [menu addItem:[self menuItem:@"Paste Command for Review"
                               action:@selector(pasteCommand:)]];
    [menu addItem:NSMenuItem.separatorItem];
    NSString *bookmarkTitle = [self.record[@"bookmarked"] boolValue]
        ? @"Remove Bookmark" : @"Bookmark Command";
    [menu addItem:[self menuItem:bookmarkTitle
                               action:@selector(toggleBookmark:)]];
    [menu addItem:[self menuItem:@"Save as Playbook"
                               action:@selector(saveRunbook:)]];
    [menu addItem:[self menuItem:@"Export Command Block…"
                               action:@selector(exportBlock:)]];
    return menu;
}

- (void)showMoreActions:(NSButton *)sender {
    NSMenu *menu = [self moreActionsMenu];
    [menu popUpMenuPositioningItem:nil
                        atLocation:NSMakePoint(0, NSHeight(sender.bounds) + 4)
                            inView:sender];
}

- (void)pasteCommand:(id)sender {
    (void)sender;
    if (self.command.length > 0 && self.pasteHandler != nil) {
        self.pasteHandler(self.command);
    }
}

- (void)rerunCommand:(id)sender {
    (void)sender;
    if (self.command.length > 0 && self.rerunHandler != nil) {
        self.rerunHandler(self.command);
    }
}

- (void)askAI:(id)sender {
    (void)sender;
    if (self.record != nil && self.askHandler != nil) {
        self.askHandler(self.record);
    }
}

- (void)saveRunbook:(id)sender {
    (void)sender;
    if (self.record != nil && self.runbookHandler != nil) {
        self.runbookHandler(self.record);
    }
}

- (void)toggleBookmark:(id)sender {
    (void)sender;
    NSString *identifier = self.record[@"id"];
    if (identifier.length > 0) {
        [self.store toggleBookmarkForRecord:identifier];
    }
}

- (void)exportBlock:(id)sender {
    (void)sender;
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.title = @"Export Command Block";
    panel.nameFieldStringValue = @"terminaldb-command-block.json";
    [panel beginSheetModalForWindow:self.panelView.window
                 completionHandler:^(NSModalResponse response) {
        if (response != NSModalResponseOK || panel.URL == nil) return;
        NSError *error = nil;
        if (![self.store exportRecords:self.record != nil ? @[self.record] : @[]
                                 toURL:panel.URL
                                format:@"json"
                                 error:&error]) {
            [[NSAlert alertWithError:error ?: [NSError
                errorWithDomain:@"TerminalDB"
                           code:2
                       userInfo:@{
                           NSLocalizedDescriptionKey :
                               @"TerminalDB could not export this block."
                       }]] runModal];
        }
    }];
}

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

+ (instancetype)ephemeralStoreForTesting {
    TerminalLedgerStore *store = [[TerminalLedgerStore alloc] init];
    store.ephemeral = YES;
    store.records = @[];
    return store;
}

+ (BOOL)runPrivacyAndEnvironmentSelfTests {
    NSString *anthropic =
        TerminalLedgerRedact(@"export ANTHROPIC_API_KEY="
                              "sk-ant-example1234567890abcdef");
    NSString *generic =
        TerminalLedgerRedact(@"api_key=terminaldb-test-secret");
    NSString *quoted =
        TerminalLedgerRedact(@"password=\"terminaldb-password\"");
    NSString *github =
        TerminalLedgerRedact(@"token ghp_1234567890abcdefghijklmnop");
    NSString *flag =
        TerminalLedgerRedact(@"curl --token terminaldb-flag-secret");
    NSMutableString *unicodeSample = [NSMutableString stringWithString:
        @"prefix-"];
    for (NSUInteger index = 0; index < 20; index++) {
        [unicodeSample appendString:@"👨‍👩‍👧‍👦"];
    }
    NSString *unicodeTail = TerminalLedgerTail(unicodeSample, 24);
    BOOL secretsRedacted =
        ![anthropic containsString:@"7890abcdef"] &&
        [anthropic containsString:@"••••••"] &&
        ![generic containsString:@"terminaldb-test-secret"] &&
        ![quoted containsString:@"terminaldb-password"] &&
        [quoted hasSuffix:@"••••••\""] &&
        ![github containsString:@"1234567890abcdefghijklmnop"] &&
        ![flag containsString:@"terminaldb-flag-secret"] &&
        [unicodeTail canBeConvertedToEncoding:NSUTF8StringEncoding];
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
    NSMutableArray<NSDictionary *> *validRecords = [NSMutableArray array];
    if ([decoded isKindOfClass:NSArray.class]) {
        for (id candidate in decoded) {
            NSDictionary *record = TerminalLedgerSanitizedRecord(candidate);
            if (record != nil) [validRecords addObject:record];
        }
    }
    _records = validRecords;
    return self;
}

- (void)persist {
    if (self.ephemeral) return;
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

- (NSDictionary *)addCommand:(NSString *)command
                    directory:(NSString *)directory
                       output:(NSString *)output
                     exitCode:(NSInteger)exitCode
                     duration:(NSTimeInterval)duration {
    NSString *cleanCommand = TerminalLedgerRedact(
        [command stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet]);
    if (cleanCommand.length == 0) return @{};
    NSString *cleanOutput = TerminalLedgerRedact(output ?: @"");
    BOOL truncated = cleanOutput.length > 24000;
    if (cleanOutput.length > 24000) {
        cleanOutput = [NSString stringWithFormat:
            @"… output truncated …\n%@",
            TerminalLedgerTail(cleanOutput, 24000)];
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
        @"project" : TerminalLedgerProject(directory),
        @"bookmarked" : @NO,
        @"tags" : @[],
        @"truncated" : @(truncated),
    };
    NSMutableArray *updated = [self.records mutableCopy];
    [updated insertObject:record atIndex:0];
    NSInteger maximum = [NSUserDefaults.standardUserDefaults
        integerForKey:@"TerminalLedgerMaximumRecords"];
    if (maximum <= 0) maximum = 5000;
    maximum = MAX(100, MIN(50000, maximum));
    if (updated.count > (NSUInteger)maximum) {
        [updated removeObjectsInRange:
            NSMakeRange((NSUInteger)maximum,
                        updated.count - (NSUInteger)maximum)];
    }
    NSInteger retentionDays = [NSUserDefaults.standardUserDefaults
        integerForKey:@"TerminalLedgerRetentionDays"];
    if (retentionDays > 0) {
        NSTimeInterval cutoff =
            [NSDate date].timeIntervalSince1970 -
            (NSTimeInterval)retentionDays * 24.0 * 60.0 * 60.0;
        NSIndexSet *expired = [updated indexesOfObjectsPassingTest:
            ^BOOL(NSDictionary *candidate, NSUInteger index, BOOL *stop) {
                (void)index;
                (void)stop;
                return [candidate[@"timestamp"] doubleValue] < cutoff;
            }];
        if (expired.count > 0) [updated removeObjectsAtIndexes:expired];
    }
    self.records = updated;
    [self persist];
    [NSNotificationCenter.defaultCenter
        postNotificationName:TerminalLedgerDidChangeNotification
                      object:self];
    return record;
}

- (nullable NSDictionary *)recordWithIdentifier:(NSString *)identifier {
    if (identifier.length == 0) return nil;
    for (NSDictionary *record in self.records) {
        if ([record[@"id"] isEqualToString:identifier]) return record;
    }
    return nil;
}

- (void)updateRecord:(NSString *)identifier
              values:(NSDictionary *)values {
    if (identifier.length == 0 || values.count == 0) return;
    NSMutableArray *updated = [self.records mutableCopy];
    NSUInteger index = [updated indexOfObjectPassingTest:
        ^BOOL(NSDictionary *record, NSUInteger candidateIndex, BOOL *stop) {
            (void)candidateIndex;
            if ([record[@"id"] isEqualToString:identifier]) {
                *stop = YES;
                return YES;
            }
            return NO;
        }];
    if (index == NSNotFound) return;
    NSMutableDictionary *record = [updated[index] mutableCopy];
    [values enumerateKeysAndObjectsUsingBlock:
        ^(id key, id value, BOOL *stop) {
            (void)stop;
            if (key == nil) return;
            if (value == NSNull.null) {
                [record removeObjectForKey:key];
            } else {
                record[key] = value;
            }
        }];
    updated[index] = record;
    self.records = updated;
    [self persist];
    [NSNotificationCenter.defaultCenter
        postNotificationName:TerminalLedgerDidChangeNotification
                      object:self];
}

- (void)toggleBookmarkForRecord:(NSString *)identifier {
    NSDictionary *record = [self recordWithIdentifier:identifier];
    if (record == nil) return;
    [self updateRecord:identifier
                values:@{@"bookmarked" : @(![record[@"bookmarked"] boolValue])}];
}

- (NSArray<NSDictionary *> *)recordsMatching:(NSString *)query {
    return [self recordsMatching:query filters:nil];
}

- (NSArray<NSDictionary *> *)recordsMatching:(NSString *)query
                                      filters:(NSDictionary *)filters {
    NSString *rawNeedle =
        [[query ?: @"" stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
    NSMutableDictionary *effectiveFilters =
        filters != nil ? [filters mutableCopy] : [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *freeTerms = [NSMutableArray array];
    for (NSString *token in
            [rawNeedle componentsSeparatedByCharactersInSet:
                NSCharacterSet.whitespaceCharacterSet]) {
        if ([token hasPrefix:@"status:"]) {
            effectiveFilters[@"status"] =
                [token substringFromIndex:@"status:".length];
        } else if ([token hasPrefix:@"project:"]) {
            effectiveFilters[@"project"] =
                [token substringFromIndex:@"project:".length];
        } else if ([token hasPrefix:@"host:"]) {
            effectiveFilters[@"host"] =
                [token substringFromIndex:@"host:".length];
        } else if ([token hasPrefix:@"env:"] ||
                   [token hasPrefix:@"environment:"]) {
            NSRange colon = [token rangeOfString:@":"];
            effectiveFilters[@"environment"] =
                [[token substringFromIndex:NSMaxRange(colon)] uppercaseString];
        } else if ([token isEqualToString:@"is:bookmarked"] ||
                   [token isEqualToString:@"bookmarked:true"]) {
            effectiveFilters[@"bookmarked"] = @YES;
        } else if (token.length > 0) {
            [freeTerms addObject:token];
        }
    }
    NSMutableString *naturalNeedle =
        [[freeTerms componentsJoinedByString:@" "] mutableCopy];
    if ([naturalNeedle containsString:@"failed"] ||
        [naturalNeedle containsString:@"failure"] ||
        [naturalNeedle containsString:@"error commands"]) {
        effectiveFilters[@"status"] = @"failed";
        [naturalNeedle replaceOccurrencesOfString:@"error commands"
                                       withString:@""
                                          options:0
                                            range:NSMakeRange(
                                                0, naturalNeedle.length)];
        [naturalNeedle replaceOccurrencesOfString:@"failed"
                                       withString:@""
                                          options:0
                                            range:NSMakeRange(
                                                0, naturalNeedle.length)];
        [naturalNeedle replaceOccurrencesOfString:@"failure"
                                       withString:@""
                                          options:0
                                            range:NSMakeRange(
                                                0, naturalNeedle.length)];
    } else if ([naturalNeedle containsString:@"successful"] ||
               [naturalNeedle containsString:@"succeeded"]) {
        effectiveFilters[@"status"] = @"success";
        [naturalNeedle replaceOccurrencesOfString:@"successful"
                                       withString:@""
                                          options:0
                                            range:NSMakeRange(
                                                0, naturalNeedle.length)];
        [naturalNeedle replaceOccurrencesOfString:@"succeeded"
                                       withString:@""
                                          options:0
                                            range:NSMakeRange(
                                                0, naturalNeedle.length)];
    }
    if ([naturalNeedle containsString:@"bookmarked"] ||
        [naturalNeedle containsString:@"favorites"]) {
        effectiveFilters[@"bookmarked"] = @YES;
        [naturalNeedle replaceOccurrencesOfString:@"bookmarked"
                                       withString:@""
                                          options:0
                                            range:NSMakeRange(
                                                0, naturalNeedle.length)];
        [naturalNeedle replaceOccurrencesOfString:@"favorites"
                                       withString:@""
                                          options:0
                                            range:NSMakeRange(
                                                0, naturalNeedle.length)];
    }
    for (NSString *environment in @[@"production", @"staging", @"remote",
                                     @"local"]) {
        if ([naturalNeedle containsString:environment]) {
            effectiveFilters[@"environment"] = environment.uppercaseString;
            [naturalNeedle replaceOccurrencesOfString:environment
                                           withString:@""
                                              options:0
                                                range:NSMakeRange(
                                                    0, naturalNeedle.length)];
            break;
        }
    }
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if ([naturalNeedle containsString:@"today"]) {
        effectiveFilters[@"after"] = @(now - 24.0 * 60.0 * 60.0);
        [naturalNeedle replaceOccurrencesOfString:@"today"
                                       withString:@""
                                          options:0
                                            range:NSMakeRange(
                                                0, naturalNeedle.length)];
    } else if ([naturalNeedle containsString:@"last week"] ||
               [naturalNeedle containsString:@"past week"]) {
        effectiveFilters[@"after"] = @(now - 7.0 * 24.0 * 60.0 * 60.0);
        [naturalNeedle replaceOccurrencesOfString:@"last week"
                                       withString:@""
                                          options:0
                                            range:NSMakeRange(
                                                0, naturalNeedle.length)];
        [naturalNeedle replaceOccurrencesOfString:@"past week"
                                       withString:@""
                                          options:0
                                            range:NSMakeRange(
                                                0, naturalNeedle.length)];
    } else if ([naturalNeedle containsString:@"last month"] ||
               [naturalNeedle containsString:@"past month"]) {
        effectiveFilters[@"after"] = @(now - 31.0 * 24.0 * 60.0 * 60.0);
        [naturalNeedle replaceOccurrencesOfString:@"last month"
                                       withString:@""
                                          options:0
                                            range:NSMakeRange(
                                                0, naturalNeedle.length)];
        [naturalNeedle replaceOccurrencesOfString:@"past month"
                                       withString:@""
                                          options:0
                                            range:NSMakeRange(
                                                0, naturalNeedle.length)];
    }
    NSString *needle = [naturalNeedle
        stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSPredicate *predicate = [NSPredicate predicateWithBlock:
        ^BOOL(NSDictionary *record, NSDictionary *bindings) {
            (void)bindings;
            NSString *status = effectiveFilters[@"status"];
            if ([status isEqualToString:@"failed"] &&
                [record[@"exit_code"] integerValue] == 0) return NO;
            if ([status isEqualToString:@"success"] &&
                [record[@"exit_code"] integerValue] != 0) return NO;
            NSString *environment = effectiveFilters[@"environment"];
            if (environment.length > 0 &&
                ![[record[@"environment"] uppercaseString]
                    isEqualToString:environment.uppercaseString]) return NO;
            NSString *project = effectiveFilters[@"project"];
            if (project.length > 0 &&
                [[record[@"project"] lowercaseString]
                    rangeOfString:project.lowercaseString].location ==
                    NSNotFound) return NO;
            NSString *host = effectiveFilters[@"host"];
            if (host.length > 0 &&
                [[record[@"host"] lowercaseString]
                    rangeOfString:host.lowercaseString].location ==
                    NSNotFound) return NO;
            if ([effectiveFilters[@"bookmarked"] boolValue] &&
                ![record[@"bookmarked"] boolValue]) return NO;
            NSNumber *after = effectiveFilters[@"after"];
            if (after != nil &&
                [record[@"timestamp"] doubleValue] < after.doubleValue) {
                return NO;
            }
            NSNumber *before = effectiveFilters[@"before"];
            if (before != nil &&
                [record[@"timestamp"] doubleValue] > before.doubleValue) {
                return NO;
            }
            if (needle.length == 0) return YES;
            NSString *haystack = [NSString stringWithFormat:@"%@\n%@\n%@",
                record[@"command"] ?: @"",
                record[@"directory"] ?: @"",
                [NSString stringWithFormat:@"%@\n%@\n%@",
                    record[@"output"] ?: @"",
                    record[@"project"] ?: @"",
                    record[@"host"] ?: @""]].lowercaseString;
            return [haystack containsString:needle];
        }];
    return [self.records filteredArrayUsingPredicate:predicate];
}

- (BOOL)exportRecords:(NSArray<NSDictionary *> *)records
                toURL:(NSURL *)url
               format:(NSString *)format
                error:(NSError **)error {
    if (url == nil) return NO;
    NSData *data = nil;
    if ([format.lowercaseString isEqualToString:@"csv"]) {
        NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithObject:
            @"timestamp,command,directory,project,host,environment,exit_code,"
             "duration,bookmarked,output"];
        for (NSDictionary *record in records ?: @[]) {
            NSArray *cells = @[
                record[@"timestamp"] ?: @0,
                record[@"command"] ?: @"",
                record[@"directory"] ?: @"",
                record[@"project"] ?: @"",
                record[@"host"] ?: @"",
                record[@"environment"] ?: @"",
                record[@"exit_code"] ?: @(-1),
                record[@"duration"] ?: @0,
                record[@"bookmarked"] ?: @NO,
                record[@"output"] ?: @"",
            ];
            NSMutableArray *escaped = [NSMutableArray array];
            for (id cell in cells) [escaped addObject:TerminalLedgerCSVCell(cell)];
            [lines addObject:[escaped componentsJoinedByString:@","]];
        }
        data = [[lines componentsJoinedByString:@"\n"]
            dataUsingEncoding:NSUTF8StringEncoding];
    } else {
        data = [NSJSONSerialization dataWithJSONObject:records ?: @[]
                                               options:NSJSONWritingPrettyPrinted
                                                 error:error];
    }
    if (data == nil) return NO;
    BOOL wrote = [data writeToURL:url options:NSDataWritingAtomic error:error];
    if (wrote) {
        [NSFileManager.defaultManager
            setAttributes:@{NSFilePosixPermissions : @0600}
            ofItemAtPath:url.path
            error:nil];
    }
    return wrote;
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
@property(nonatomic, strong) NSTextField *outputLabel;
@property(nonatomic, strong) NSButton *askButton;
@property(nonatomic, strong) NSButton *pasteButton;
@property(nonatomic, strong) NSButton *historyButton;
@property(nonatomic, strong) NSButton *commandCopyButton;
@property(nonatomic, strong) NSButton *rerunButton;
@property(nonatomic, strong) NSButton *bookmarkButton;
@property(nonatomic, strong) NSButton *runbookButton;
@property(nonatomic, strong) NSButton *detailsButton;
@property(nonatomic, copy) NSString *command;
@property(nonatomic, copy, nullable) NSDictionary *record;
@end

@implementation TerminalLedgerBar

- (NSDictionary *)currentRecord {
    return self.record;
}

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
    _commandLabel.selectable = YES;
    [self addSubview:_commandLabel];

    _metadataLabel = [NSTextField labelWithString:@""];
    _metadataLabel.font =
        [NSFont fontWithName:theme.fontName size:9.5]
            ?: [NSFont monospacedSystemFontOfSize:9.5
                                           weight:NSFontWeightRegular];
    _metadataLabel.textColor = theme.statusBarForeground;
    _metadataLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [self addSubview:_metadataLabel];

    _outputLabel = [NSTextField wrappingLabelWithString:@""];
    _outputLabel.font =
        [NSFont fontWithName:theme.fontName size:10.5]
            ?: [NSFont monospacedSystemFontOfSize:10.5
                                           weight:NSFontWeightRegular];
    _outputLabel.textColor = theme.statusBarActiveForeground;
    _outputLabel.maximumNumberOfLines = 2;
    _outputLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _outputLabel.selectable = YES;
    [self addSubview:_outputLabel];
    [self setAccessibilityRole:NSAccessibilityGroupRole];
    [self setAccessibilityLabel:@"Command ledger block"];

    _historyButton = [self buttonWithTitle:@"History"
                                    action:@selector(showHistory:)];
    _askButton = [self buttonWithTitle:@"✦ Ask AI"
                                action:@selector(askAI:)];
    _pasteButton = [self buttonWithTitle:@"Paste"
                                  action:@selector(pasteCommand:)];
    _commandCopyButton = [self buttonWithTitle:@"Copy"
                                        action:@selector(copyCommand:)];
    _rerunButton = [self buttonWithTitle:@"↻ Rerun"
                                  action:@selector(rerunCommand:)];
    _bookmarkButton = [self buttonWithTitle:@"☆"
                                     action:@selector(toggleBookmark:)];
    _runbookButton = [self buttonWithTitle:@"▤ Playbook"
                                    action:@selector(saveAsRunbook:)];
    _detailsButton = [self buttonWithTitle:@"Details"
                                    action:@selector(showDetails:)];
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
    [[NSColor colorWithSRGBRed:0.106 green:0.106 blue:0.122 alpha:1.0]
        setFill];
    NSRectFill(self.bounds);
    NSColor *border = self.record != nil
        ? [self.theme.ansiColors[6] colorWithAlphaComponent:0.34]
        : self.theme.statusBarBorder;
    [border setStroke];
    NSBezierPath *block = [NSBezierPath
        bezierPathWithRoundedRect:NSInsetRect(self.bounds, 7, 7)
                          xRadius:6
                          yRadius:6];
    block.lineWidth = 1;
    [block stroke];
    [self.theme.statusBarBorder setFill];
    NSRectFill(NSMakeRect(0, NSHeight(self.bounds) - 1,
                          NSWidth(self.bounds), 1));
}

- (void)layout {
    [super layout];
    CGFloat width = NSWidth(self.bounds);
    CGFloat right = width - 13;
    NSArray<NSButton *> *buttons = @[
        self.detailsButton, self.runbookButton, self.rerunButton,
        self.askButton, self.commandCopyButton, self.pasteButton,
        self.bookmarkButton, self.historyButton
    ];
    NSSet<NSButton *> *visibleButtons = nil;
    if (width < 620) {
        visibleButtons = [NSSet setWithArray:@[
            self.detailsButton, self.askButton
        ]];
    } else {
        visibleButtons = [NSSet setWithArray:@[
            self.detailsButton, self.rerunButton,
            self.askButton, self.historyButton
        ]];
    }
    for (NSButton *button in buttons) {
        button.hidden = ![visibleButtons containsObject:button];
        if (button.hidden) continue;
        CGFloat buttonWidth = [button.title isEqualToString:@"☆"] ||
                              [button.title isEqualToString:@"★"]
            ? 30
            : MAX(46, button.intrinsicContentSize.width + 12);
        right -= buttonWidth;
        button.frame = NSMakeRect(right, NSHeight(self.bounds) - 38,
                                  buttonWidth, 24);
        right -= 8;
    }
    self.stateLabel.frame = NSMakeRect(14, 13, 78, 14);
    self.commandLabel.frame =
        NSMakeRect(14, 31, MAX(80, width - 28), 19);
    self.metadataLabel.frame =
        NSMakeRect(98, 12, MAX(40, width - 112), 15);
    self.outputLabel.frame =
        NSMakeRect(14, 55, MAX(80, width - 28),
                   MAX(18, NSHeight(self.bounds) - 101));
}

- (void)showReadyInDirectory:(NSString *)directory {
    self.record = nil;
    self.command = @"";
    self.stateLabel.stringValue = @"READY";
    self.stateLabel.textColor = self.theme.ansiColors[6];
    self.commandLabel.stringValue = @"❯  shell ready";
    self.metadataLabel.stringValue = [NSString stringWithFormat:
        @"%@  ·  LOCAL", directory.length > 0 ? directory : @"~"];
    self.outputLabel.stringValue =
        @"Completed commands become selectable ledger blocks here.";
    self.askButton.title = @"✦ Ask AI";
    self.askButton.enabled = NO;
    self.pasteButton.enabled = NO;
    self.commandCopyButton.enabled = NO;
    self.rerunButton.enabled = NO;
    self.bookmarkButton.enabled = NO;
    self.runbookButton.enabled = NO;
    self.detailsButton.enabled = NO;
    [self setNeedsLayout:YES];
    [self setNeedsDisplay:YES];
}

- (void)beginCommand:(NSString *)command directory:(NSString *)directory {
    self.record = nil;
    self.command = command ?: @"";
    self.stateLabel.stringValue = @"RUNNING";
    self.stateLabel.textColor = self.theme.ansiColors[3];
    self.commandLabel.stringValue = [NSString stringWithFormat:
        @"❯  %@", command.length > 0 ? command : @"command"];
    self.metadataLabel.stringValue = [NSString stringWithFormat:
        @"%@  ·  %@  ·  started now",
        directory.length > 0 ? directory : @"~",
        TerminalLedgerEnvironment(command)];
    self.outputLabel.stringValue =
        @"Live output continues in the terminal below. Stop with Control-C.";
    self.askButton.title = @"✦ Ask AI";
    self.askButton.enabled = command.length > 0;
    self.pasteButton.enabled = NO;
    self.commandCopyButton.enabled = command.length > 0;
    self.rerunButton.enabled = NO;
    self.bookmarkButton.enabled = NO;
    self.runbookButton.enabled = NO;
    self.detailsButton.enabled = NO;
    [self setNeedsLayout:YES];
    [self setNeedsDisplay:YES];
}

- (void)displayRecord:(NSDictionary *)record {
    if (record.count == 0) return;
    self.record = record;
    NSString *command =
        [record[@"command"] isKindOfClass:NSString.class]
            ? record[@"command"]
            : @"";
    self.command = command;
    NSInteger exitCode = [record[@"exit_code"] integerValue];
    self.stateLabel.stringValue = exitCode == 0
        ? @"EXIT 0"
        : [NSString stringWithFormat:@"EXIT %ld", (long)exitCode];
    self.stateLabel.textColor =
        exitCode == 0 ? self.theme.ansiColors[2] : self.theme.ansiColors[1];
    self.commandLabel.stringValue =
        [NSString stringWithFormat:@"❯  %@", command];
    self.metadataLabel.stringValue = [NSString stringWithFormat:
        @"%@  ·  %@  ·  %@  ·  %.2fs",
        record[@"directory"] ?: @"~",
        record[@"host"] ?: @"Mac",
        record[@"environment"] ?: @"LOCAL",
        [record[@"duration"] doubleValue]];
    NSString *output =
        [record[@"output"] isKindOfClass:NSString.class]
            ? record[@"output"]
            : @"";
    output = [output stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    self.outputLabel.stringValue = output.length > 0
        ? output
        : @"(command produced no captured output)";
    self.askButton.title =
        exitCode == 0 ? @"✦ Ask AI" : @"✦ Explain / Fix";
    self.askButton.enabled = command.length > 0;
    self.pasteButton.enabled = command.length > 0;
    self.commandCopyButton.enabled = command.length > 0;
    self.rerunButton.enabled = command.length > 0;
    self.bookmarkButton.enabled = YES;
    self.bookmarkButton.title =
        [record[@"bookmarked"] boolValue] ? @"★" : @"☆";
    self.runbookButton.enabled = command.length > 0;
    self.detailsButton.enabled = YES;
    [self setAccessibilityLabel:[NSString stringWithFormat:
        @"Command block: %@, %@, exit %ld, %.1f seconds. Actions available.",
        command,
        record[@"environment"] ?: @"local",
        (long)exitCode,
        [record[@"duration"] doubleValue]]];
    [self setNeedsLayout:YES];
    [self setNeedsDisplay:YES];
}

- (void)finishCommand:(NSString *)command
             directory:(NSString *)directory
              exitCode:(NSInteger)exitCode
              duration:(NSTimeInterval)duration {
    [self displayRecord:@{
        @"id" : @"live",
        @"command" : command ?: @"",
        @"directory" : directory ?: @"~",
        @"host" : NSHost.currentHost.localizedName ?: @"Mac",
        @"environment" : TerminalLedgerEnvironment(command),
        @"exit_code" : @(exitCode),
        @"duration" : @(duration),
        @"output" : @"",
        @"bookmarked" : @NO,
    }];
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

- (void)copyCommand:(id)sender {
    (void)sender;
    if (self.command.length == 0) return;
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:self.command
                                       forType:NSPasteboardTypeString];
}

- (void)rerunCommand:(id)sender {
    (void)sender;
    if (self.record != nil && self.rerunHandler != nil) {
        self.rerunHandler(self.record);
    }
}

- (void)toggleBookmark:(id)sender {
    (void)sender;
    if (self.record != nil && self.bookmarkHandler != nil) {
        self.bookmarkHandler(self.record);
    }
}

- (void)saveAsRunbook:(id)sender {
    (void)sender;
    if (self.record != nil && self.runbookHandler != nil) {
        self.runbookHandler(self.record);
    }
}

- (void)showDetails:(id)sender {
    (void)sender;
    if (self.record != nil && self.detailsHandler != nil) {
        self.detailsHandler(self.record);
    }
}

@end

@class TerminalHistoryController;

@interface TerminalLedgerPanelView : NSView
@property(nonatomic, weak) TerminalHistoryController *controller;
@end

@interface TerminalHistoryController ()
@property(nonatomic, strong) TerminalLedgerStore *store;
@property(nonatomic, strong) TerminalTheme *theme;
@property(nonatomic, strong, readwrite) NSView *panelView;
@property(nonatomic, strong) NSSearchField *searchField;
@property(nonatomic, strong) NSPopUpButton *scopeFilter;
@property(nonatomic, strong) NSTextField *resultCountLabel;
@property(nonatomic, strong) NSTableView *tableView;
@property(nonatomic, strong) NSTextView *detailView;
@property(nonatomic, strong) NSScrollView *tableScroll;
@property(nonatomic, strong) NSScrollView *detailScroll;
@property(nonatomic, strong) NSTextField *privacyLabel;
@property(nonatomic, strong) NSButton *pasteButton;
@property(nonatomic, strong) NSButton *rerunButton;
@property(nonatomic, strong) NSButton *playbookButton;
@property(nonatomic, strong) NSButton *moreButton;
@property(nonatomic, strong) NSTextField *actionHintLabel;
@property(nonatomic, copy) NSArray<NSDictionary *> *filteredRecords;
- (NSMenu *)moreActionsMenu;
- (void)layoutPanel;
@end

@implementation TerminalLedgerPanelView

- (void)layout {
    [super layout];
    [self.controller layoutPanel];
}

@end

@implementation TerminalHistoryController

- (instancetype)initWithStore:(TerminalLedgerStore *)store
                         theme:(TerminalTheme *)theme {
    self = [super init];
    if (self == nil) return nil;
    _store = store;
    _theme = theme;
    _filteredRecords = store.records;
    TerminalLedgerPanelView *panel = [[TerminalLedgerPanelView alloc]
        initWithFrame:NSMakeRect(0, 0, 1080, 340)];
    panel.controller = self;
    _panelView = panel;
    _panelView.wantsLayer = YES;
    _panelView.layer.backgroundColor = theme.terminalBackground.CGColor;
    [_panelView setAccessibilityElement:YES];
    [_panelView setAccessibilityRole:NSAccessibilityGroupRole];
    [_panelView setAccessibilityLabel:@"Command history"];
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

+ (BOOL)runInterfaceSelfTests {
    TerminalHistoryController *controller =
        [[TerminalHistoryController alloc]
            initWithStore:[TerminalLedgerStore ephemeralStoreForTesting]
                   theme:[TerminalTheme preferredTheme]];
    NSArray<NSString *> *scopeTitles =
        [controller.scopeFilter.itemArray valueForKey:@"title"];
    NSArray<NSString *> *moreTitles =
        [controller.moreActionsMenu.itemArray valueForKey:@"title"];
    CGFloat firstGap = NSMinX(controller.pasteButton.frame) -
        NSMaxX(controller.rerunButton.frame);
    CGFloat secondGap = NSMinX(controller.playbookButton.frame) -
        NSMaxX(controller.pasteButton.frame);
    return controller.panelView.window == nil &&
        [controller.panelView.accessibilityLabel
            isEqualToString:@"Command history"] &&
        [controller.rerunButton.title isEqualToString:@"Run again"] &&
        [controller.pasteButton.title isEqualToString:@"Paste to edit"] &&
        [controller.playbookButton.title
            isEqualToString:@"Save as Playbook"] &&
        firstGap >= 12.0 && secondGap >= 12.0 &&
        [scopeTitles isEqualToArray:
            @[@"All commands", @"Failed", @"Bookmarked"]] &&
        [moreTitles containsObject:@"Ask AI"] &&
        [moreTitles containsObject:@"Bookmark Command"] &&
        [moreTitles containsObject:@"Export Results…"] &&
        [moreTitles containsObject:@"Clear History…"];
}

- (void)buildUI {
    NSView *content = self.panelView;

    self.searchField =
        [[NSSearchField alloc] initWithFrame:NSMakeRect(18, 605, 600, 30)];
    self.searchField.placeholderString =
        @"Search commands, folders, or output";
    self.searchField.delegate = self;
    self.searchField.autoresizingMask =
        NSViewWidthSizable | NSViewMinYMargin;
    [self.searchField setAccessibilityLabel:@"Search command history"];
    [content addSubview:self.searchField];

    self.scopeFilter =
        [[NSPopUpButton alloc] initWithFrame:NSMakeRect(632, 605, 150, 30)
                                  pullsDown:NO];
    [self.scopeFilter addItemsWithTitles:
        @[@"All commands", @"Failed", @"Bookmarked"]];
    self.scopeFilter.target = self;
    self.scopeFilter.action = @selector(filterChanged:);
    self.scopeFilter.autoresizingMask =
        NSViewMinXMargin | NSViewMinYMargin;
    [self.scopeFilter setAccessibilityLabel:@"Filter command history"];
    [content addSubview:self.scopeFilter];

    self.resultCountLabel = [NSTextField labelWithString:@""];
    self.resultCountLabel.font =
        [NSFont fontWithName:self.theme.fontName size:9.5]
            ?: [NSFont monospacedSystemFontOfSize:9.5
                                           weight:NSFontWeightRegular];
    self.resultCountLabel.textColor = self.theme.statusBarForeground;
    self.resultCountLabel.alignment = NSTextAlignmentRight;
    self.resultCountLabel.frame = NSMakeRect(794, 611, 268, 18);
    self.resultCountLabel.autoresizingMask =
        NSViewMinXMargin | NSViewMinYMargin;
    [content addSubview:self.resultCountLabel];

    self.privacyLabel = [NSTextField labelWithString:
        @"LOCAL HISTORY · secrets redacted · stays on this Mac"];
    self.privacyLabel.font =
        [NSFont fontWithName:self.theme.fontName size:9.5]
            ?: [NSFont monospacedSystemFontOfSize:9.5
                                           weight:NSFontWeightRegular];
    self.privacyLabel.textColor = self.theme.ansiColors[6];
    self.privacyLabel.frame = NSMakeRect(560, 578, 502, 18);
    self.privacyLabel.alignment = NSTextAlignmentRight;
    [content addSubview:self.privacyLabel];
    self.tableScroll =
        [[NSScrollView alloc] initWithFrame:NSMakeRect(18, 96, 500, 474)];
    self.tableScroll.hasVerticalScroller = YES;
    self.tableScroll.borderType = NSBezelBorder;
    self.tableScroll.drawsBackground = YES;
    self.tableScroll.backgroundColor = self.theme.terminalBackground;
    self.tableView = [[NSTableView alloc]
        initWithFrame:self.tableScroll.bounds];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.usesAlternatingRowBackgroundColors = NO;
    self.tableView.backgroundColor = self.theme.terminalBackground;
    self.tableView.rowHeight = 27;
    NSArray *columns = @[
        @[@"bookmark", @"", @26],
        @[@"command", @"Command", @220],
        @[@"project", @"Folder", @100],
        @[@"status", @"", @46],
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
    self.tableScroll.documentView = self.tableView;
    [content addSubview:self.tableScroll];

    self.detailScroll =
        [[NSScrollView alloc] initWithFrame:NSMakeRect(532, 96, 530, 474)];
    self.detailScroll.hasVerticalScroller = YES;
    self.detailScroll.borderType = NSBezelBorder;
    self.detailView = [[NSTextView alloc]
        initWithFrame:self.detailScroll.bounds];
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
    self.detailScroll.documentView = self.detailView;
    [content addSubview:self.detailScroll];

    self.rerunButton = [NSButton buttonWithTitle:@"Run again"
                                           target:self
                                           action:@selector(rerunSelected:)];
    self.rerunButton.frame = NSMakeRect(18, 36, 120, 36);
    self.rerunButton.keyEquivalent = @"\r";
    [self.rerunButton setAccessibilityHelp:
        @"Runs the selected command after TerminalDB's normal safety check."];
    [content addSubview:self.rerunButton];
    self.pasteButton = [NSButton buttonWithTitle:@"Paste to edit"
                                           target:self
                                           action:@selector(pasteSelected:)];
    self.pasteButton.frame = NSMakeRect(150, 36, 120, 36);
    [content addSubview:self.pasteButton];
    self.playbookButton = [NSButton buttonWithTitle:@"Save as Playbook"
                                              target:self
                                              action:@selector(runbookSelected:)];
    self.playbookButton.frame = NSMakeRect(282, 36, 154, 36);
    [content addSubview:self.playbookButton];
    self.moreButton = [NSButton buttonWithTitle:@"More…"
                                          target:self
                                          action:@selector(showMoreActions:)];
    self.moreButton.frame = NSMakeRect(448, 36, 92, 36);
    [content addSubview:self.moreButton];

    self.actionHintLabel = [NSTextField labelWithString:
        @"Run it now, edit before running, or keep it as a Playbook."];
    self.actionHintLabel.font =
        [NSFont systemFontOfSize:10 weight:NSFontWeightRegular];
    self.actionHintLabel.textColor = self.theme.statusBarForeground;
    self.actionHintLabel.frame = NSMakeRect(558, 45, 504, 18);
    self.actionHintLabel.alignment = NSTextAlignmentRight;
    self.actionHintLabel.autoresizingMask = NSViewMinXMargin;
    [content addSubview:self.actionHintLabel];
    [self reload];
    [self.panelView setNeedsLayout:YES];
}

- (void)layoutPanel {
    CGFloat width = NSWidth(self.panelView.bounds);
    CGFloat height = NSHeight(self.panelView.bounds);
    CGFloat inset = 18;
    CGFloat gap = 12;
    CGFloat countWidth = 160;
    CGFloat filterWidth = 150;
    CGFloat searchWidth = MAX(210,
        width - inset * 2 - gap * 2 - countWidth - filterWidth);
    CGFloat topY = height - 45;
    self.searchField.frame =
        NSMakeRect(inset, topY, searchWidth, 30);
    self.scopeFilter.frame =
        NSMakeRect(NSMaxX(self.searchField.frame) + gap,
                   topY, filterWidth, 30);
    self.resultCountLabel.frame =
        NSMakeRect(width - inset - countWidth, topY + 6,
                   countWidth, 18);
    self.privacyLabel.frame =
        NSMakeRect(MAX(inset, width - inset - 502), height - 72,
                   MIN(502, width - inset * 2), 18);

    CGFloat contentBottom = 92;
    CGFloat contentTop = height - 82;
    CGFloat contentHeight = MAX(140, contentTop - contentBottom);
    if (width >= 900) {
        CGFloat available = width - inset * 2 - gap;
        CGFloat tableWidth = floor(available * 0.46);
        self.tableScroll.frame =
            NSMakeRect(inset, contentBottom, tableWidth, contentHeight);
        self.detailScroll.frame =
            NSMakeRect(NSMaxX(self.tableScroll.frame) + gap,
                       contentBottom, available - tableWidth, contentHeight);
    } else {
        CGFloat halfHeight = floor((contentHeight - gap) * 0.5);
        self.detailScroll.frame =
            NSMakeRect(inset, contentBottom,
                       width - inset * 2, halfHeight);
        self.tableScroll.frame =
            NSMakeRect(inset, NSMaxY(self.detailScroll.frame) + gap,
                       width - inset * 2,
                       contentHeight - halfHeight - gap);
    }
    self.actionHintLabel.hidden = width < 900;
    self.actionHintLabel.frame =
        NSMakeRect(558, 45, MAX(1, width - 576), 18);
}

- (void)historyChanged:(NSNotification *)notification {
    (void)notification;
    [self reload];
}

- (void)reload {
    NSMutableDictionary *filters = [NSMutableDictionary dictionary];
    NSString *scope = self.scopeFilter.titleOfSelectedItem;
    if ([scope isEqualToString:@"Failed"]) {
        filters[@"status"] = @"failed";
    } else if ([scope isEqualToString:@"Bookmarked"]) {
        filters[@"bookmarked"] = @YES;
    }
    self.filteredRecords =
        [self.store recordsMatching:self.searchField.stringValue
                            filters:filters];
    self.resultCountLabel.stringValue = [NSString stringWithFormat:
        @"%lu of %lu commands",
        (unsigned long)self.filteredRecords.count,
        (unsigned long)self.store.records.count];
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
    BOOL hasSelection = [self selectedRecord] != nil;
    self.rerunButton.enabled = hasSelection;
    self.pasteButton.enabled = hasSelection;
    self.playbookButton.enabled = hasSelection;
    self.moreButton.enabled = hasSelection || self.filteredRecords.count > 0;
}

- (void)filterChanged:(id)sender {
    (void)sender;
    [self reload];
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
    if ([identifier isEqualToString:@"bookmark"]) {
        field.stringValue = [record[@"bookmarked"] boolValue] ? @"★" : @"";
        field.textColor = self.theme.ansiColors[3];
        field.alignment = NSTextAlignmentCenter;
    } else if ([identifier isEqualToString:@"command"]) {
        field.stringValue = record[@"command"] ?: @"";
    } else if ([identifier isEqualToString:@"project"]) {
        field.stringValue = record[@"project"] ?: @"Shell";
        field.textColor = self.theme.statusBarActiveForeground;
    } else if ([identifier isEqualToString:@"environment"]) {
        field.stringValue = record[@"environment"] ?: @"LOCAL";
        NSString *environment = field.stringValue;
        field.textColor = [environment isEqualToString:@"PRODUCTION"]
            ? self.theme.ansiColors[1]
            : ([environment isEqualToString:@"STAGING"]
                ? self.theme.ansiColors[3]
                : self.theme.ansiColors[6]);
    } else if ([identifier isEqualToString:@"status"]) {
        NSInteger code = [record[@"exit_code"] integerValue];
        field.stringValue =
            code == 0 ? @"✓" : [NSString stringWithFormat:
                @"× %ld", (long)code];
        field.alignment = NSTextAlignmentCenter;
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
    BOOL hasSelection = [self selectedRecord] != nil;
    self.rerunButton.enabled = hasSelection;
    self.pasteButton.enabled = hasSelection;
    self.playbookButton.enabled = hasSelection;
    self.moreButton.enabled = hasSelection || self.filteredRecords.count > 0;
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
        @"%@  BLOCK %@\n\n❯ %@\n\n%@ · %@ · %@ · exit %@ · %.2fs\n"
         "%@\n\n%@",
        [record[@"bookmarked"] boolValue] ? @"★" : @"",
        record[@"id"] ?: @"",
        record[@"command"] ?: @"",
        record[@"directory"] ?: @"",
        record[@"host"] ?: @"Mac",
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

- (void)rerunSelected:(id)sender {
    (void)sender;
    NSString *command = [self selectedRecord][@"command"];
    if (command.length > 0 && self.rerunHandler != nil) {
        self.rerunHandler(command);
    }
}

- (void)bookmarkSelected:(id)sender {
    (void)sender;
    NSString *identifier = [self selectedRecord][@"id"];
    if (identifier.length == 0) return;
    [self.store toggleBookmarkForRecord:identifier];
}

- (void)runbookSelected:(id)sender {
    (void)sender;
    NSDictionary *record = [self selectedRecord];
    if (record != nil && self.runbookHandler != nil) {
        self.runbookHandler(record);
    }
}

- (NSMenuItem *)historyMenuItem:(NSString *)title action:(SEL)action {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
                                                  action:action
                                           keyEquivalent:@""];
    item.target = self;
    return item;
}

- (NSMenu *)moreActionsMenu {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"History actions"];
    [menu addItem:[self historyMenuItem:@"Ask AI"
                                 action:@selector(askSelected:)]];
    NSString *bookmarkTitle = [[self selectedRecord][@"bookmarked"] boolValue]
        ? @"Remove Bookmark" : @"Bookmark Command";
    [menu addItem:[self historyMenuItem:bookmarkTitle
                                 action:@selector(bookmarkSelected:)]];
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItem:[self historyMenuItem:@"Export Results…"
                                 action:@selector(exportHistory:)]];
    [menu addItem:[self historyMenuItem:@"Clear History…"
                                 action:@selector(clearHistory:)]];
    return menu;
}

- (void)showMoreActions:(NSButton *)sender {
    NSMenu *menu = [self moreActionsMenu];
    [menu popUpMenuPositioningItem:nil
                        atLocation:NSMakePoint(0, NSHeight(sender.bounds) + 4)
                            inView:sender];
}

- (void)exportHistory:(id)sender {
    (void)sender;
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.title = @"Export TerminalDB History";
    panel.nameFieldStringValue = @"terminaldb-history.json";
    [panel beginSheetModalForWindow:self.panelView.window
                 completionHandler:^(NSModalResponse response) {
        if (response != NSModalResponseOK || panel.URL == nil) return;
        NSString *format =
            [panel.URL.pathExtension.lowercaseString isEqualToString:@"csv"]
                ? @"csv" : @"json";
        NSError *error = nil;
        if (![self.store exportRecords:self.filteredRecords
                                 toURL:panel.URL
                                format:format
                                 error:&error]) {
            [[NSAlert alertWithError:error ?: [NSError
                errorWithDomain:@"TerminalDB"
                           code:1
                       userInfo:@{
                           NSLocalizedDescriptionKey :
                               @"TerminalDB could not export history."
                       }]] runModal];
        }
    }];
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
    NSWindow *window = self.panelView.window;
    if (window == nil) return;
    [alert beginSheetModalForWindow:window
                 completionHandler:^(NSModalResponse response) {
        if (response == NSAlertFirstButtonReturn) {
            [self.store clearHistory];
        }
    }];
}

@end
