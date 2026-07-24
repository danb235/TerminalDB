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
@end

@interface TerminalCommandInspectorWindowController ()
@property(nonatomic, strong) TerminalLedgerStore *store;
@property(nonatomic, strong) TerminalTheme *theme;
@property(nonatomic, copy, nullable) NSDictionary *record;
@property(nonatomic, strong) NSTextField *titleLabel;
@property(nonatomic, strong) NSTextField *commandLabel;
@property(nonatomic, strong) NSTextField *statusLabel;
@property(nonatomic, strong) NSTextField *metadataLabel;
@property(nonatomic, strong) NSTextView *outputView;
@property(nonatomic, strong) NSTextView *annotationsView;
@property(nonatomic, strong) NSTextField *annotationField;
@property(nonatomic, strong) NSButton *bookmarkButton;
@end

@implementation TerminalCommandInspectorWindowController

- (instancetype)initWithStore:(TerminalLedgerStore *)store
                         theme:(TerminalTheme *)theme {
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 940, 620)
                  styleMask:NSWindowStyleMaskTitled |
                            NSWindowStyleMaskClosable |
                            NSWindowStyleMaskMiniaturizable |
                            NSWindowStyleMaskResizable
                    backing:NSBackingStoreBuffered
                      defer:NO];
    window.title = @"TerminalDB — Command Inspector";
    window.contentMinSize = NSMakeSize(760, 520);
    window.backgroundColor = theme.terminalBackground;
    self = [super initWithWindow:window];
    if (self == nil) return nil;
    _store = store;
    _theme = theme;
    [self buildUI];
    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(storeChanged:)
               name:TerminalLedgerDidChangeNotification
             object:store];
    return self;
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
    NSView *content = self.window.contentView;
    content.wantsLayer = YES;
    content.layer.backgroundColor = self.theme.terminalBackground.CGColor;
    NSFont *mono = [NSFont fontWithName:self.theme.fontName size:11.5]
        ?: [NSFont monospacedSystemFontOfSize:11.5
                                       weight:NSFontWeightRegular];
    self.titleLabel = [self label:@"COMMAND BLOCK"
                            frame:NSMakeRect(20, 584, 560, 18)
                             font:[NSFont systemFontOfSize:10
                                                   weight:NSFontWeightSemibold]
                            color:self.theme.ansiColors[6]];
    [content addSubview:self.titleLabel];
    self.statusLabel = [self label:@""
                             frame:NSMakeRect(760, 582, 160, 20)
                              font:[NSFont monospacedSystemFontOfSize:10.5
                                                              weight:NSFontWeightSemibold]
                             color:self.theme.ansiColors[2]];
    self.statusLabel.alignment = NSTextAlignmentRight;
    [content addSubview:self.statusLabel];
    self.commandLabel = [self label:@""
                              frame:NSMakeRect(20, 548, 900, 28)
                               font:[NSFont fontWithName:self.theme.fontName
                                                   size:15] ?: mono
                              color:self.theme.terminalForeground];
    [content addSubview:self.commandLabel];
    self.metadataLabel = [self label:@""
                               frame:NSMakeRect(20, 516, 900, 22)
                                font:mono
                               color:self.theme.statusBarActiveForeground];
    [content addSubview:self.metadataLabel];

    NSScrollView *outputScroll =
        [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 166, 610, 336)];
    outputScroll.hasVerticalScroller = YES;
    outputScroll.borderType = NSBezelBorder;
    self.outputView = [[NSTextView alloc] initWithFrame:outputScroll.bounds];
    self.outputView.editable = NO;
    self.outputView.selectable = YES;
    self.outputView.drawsBackground = YES;
    self.outputView.backgroundColor =
        [NSColor colorWithSRGBRed:0.055 green:0.063 blue:0.071 alpha:1];
    self.outputView.textColor = self.theme.terminalForeground;
    self.outputView.font = mono;
    self.outputView.textContainerInset = NSMakeSize(12, 12);
    outputScroll.documentView = self.outputView;
    [content addSubview:outputScroll];

    NSTextField *annotationsTitle = [self label:@"ANNOTATIONS"
        frame:NSMakeRect(650, 482, 270, 18)
         font:[NSFont systemFontOfSize:10 weight:NSFontWeightSemibold]
        color:self.theme.ansiColors[3]];
    [content addSubview:annotationsTitle];
    NSScrollView *annotationScroll =
        [[NSScrollView alloc] initWithFrame:NSMakeRect(650, 252, 270, 220)];
    annotationScroll.hasVerticalScroller = YES;
    annotationScroll.borderType = NSBezelBorder;
    self.annotationsView =
        [[NSTextView alloc] initWithFrame:annotationScroll.bounds];
    self.annotationsView.editable = NO;
    self.annotationsView.selectable = YES;
    self.annotationsView.drawsBackground = YES;
    self.annotationsView.backgroundColor =
        [NSColor colorWithSRGBRed:0.075 green:0.086 blue:0.098 alpha:1];
    self.annotationsView.textColor = self.theme.terminalForeground;
    self.annotationsView.font =
        [NSFont systemFontOfSize:11 weight:NSFontWeightRegular];
    self.annotationsView.textContainerInset = NSMakeSize(10, 10);
    annotationScroll.documentView = self.annotationsView;
    [content addSubview:annotationScroll];
    self.annotationField =
        [[NSTextField alloc] initWithFrame:NSMakeRect(650, 212, 192, 28)];
    self.annotationField.placeholderString = @"Add a private annotation";
    self.annotationField.target = self;
    self.annotationField.action = @selector(addAnnotation:);
    [content addSubview:self.annotationField];
    NSButton *addAnnotation =
        [self button:@"Add"
               frame:NSMakeRect(848, 210, 72, 32)
              action:@selector(addAnnotation:)];
    [content addSubview:addAnnotation];

    NSBox *separator = [[NSBox alloc] initWithFrame:NSMakeRect(20, 146, 900, 1)];
    separator.boxType = NSBoxSeparator;
    [content addSubview:separator];

    NSArray<NSArray *> *actions = @[
        @[@"Copy", NSStringFromSelector(@selector(copyCommand:)), @20],
        @[@"Paste", NSStringFromSelector(@selector(pasteCommand:)), @100],
        @[@"↻ Rerun", NSStringFromSelector(@selector(rerunCommand:)), @180],
        @[@"✦ Ask AI", NSStringFromSelector(@selector(askAI:)), @278],
        @[@"▤ Runbook", NSStringFromSelector(@selector(saveRunbook:)), @390],
        @[@"Export…", NSStringFromSelector(@selector(exportBlock:)), @506],
    ];
    for (NSArray *definition in actions) {
        NSButton *button = [self button:definition[0]
                                  frame:NSMakeRect([definition[2] doubleValue],
                                                   92, 96, 32)
                                 action:NSSelectorFromString(definition[1])];
        [content addSubview:button];
    }
    self.bookmarkButton =
        [self button:@"☆ Bookmark"
               frame:NSMakeRect(806, 92, 114, 32)
              action:@selector(toggleBookmark:)];
    [content addSubview:self.bookmarkButton];
    NSTextField *privacy = [self label:
        @"LOCAL BLOCK · output may contain sensitive data · exports stay local"
        frame:NSMakeRect(20, 44, 900, 20)
         font:[NSFont fontWithName:self.theme.fontName size:9.5] ?: mono
        color:self.theme.statusBarForeground];
    privacy.alignment = NSTextAlignmentCenter;
    [content addSubview:privacy];
}

- (void)presentRecord:(NSDictionary *)record
     relativeToWindow:(NSWindow *)parentWindow {
    self.record = record;
    [self refresh];
    if (parentWindow != nil) {
        NSRect parent = parentWindow.frame;
        NSRect frame = self.window.frame;
        frame.origin.x = NSMidX(parent) - frame.size.width / 2.0;
        frame.origin.y = NSMidY(parent) - frame.size.height / 2.0;
        [self.window setFrame:frame display:NO];
    } else {
        [self.window center];
    }
    [self showWindow:nil];
    [self.window makeKeyAndOrderFront:nil];
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
    self.titleLabel.stringValue = [NSString stringWithFormat:
        @"COMMAND BLOCK · %@", identifier.uppercaseString];
    self.commandLabel.stringValue =
        [NSString stringWithFormat:@"❯ %@", record[@"command"] ?: @""];
    NSInteger exitCode = [record[@"exit_code"] integerValue];
    self.statusLabel.stringValue = exitCode == 0
        ? @"✓ EXIT 0"
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
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (NSDictionary *annotation in
            [record[@"annotations"] isKindOfClass:NSArray.class]
                ? record[@"annotations"] : @[]) {
        NSString *text = annotation[@"text"];
        if (text.length > 0) [lines addObject:[@"• " stringByAppendingString:text]];
    }
    self.annotationsView.string = lines.count > 0
        ? [lines componentsJoinedByString:@"\n\n"]
        : @"No annotations yet.";
    self.bookmarkButton.title =
        [record[@"bookmarked"] boolValue] ? @"★ Bookmarked" : @"☆ Bookmark";
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

- (void)addAnnotation:(id)sender {
    (void)sender;
    NSString *annotation = self.annotationField.stringValue;
    NSString *identifier = self.record[@"id"];
    if (annotation.length == 0 || identifier.length == 0) return;
    [self.store addAnnotation:annotation toRecord:identifier];
    self.annotationField.stringValue = @"";
}

- (void)exportBlock:(id)sender {
    (void)sender;
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.title = @"Export Command Block";
    panel.nameFieldStringValue = @"terminaldb-command-block.json";
    [panel beginSheetModalForWindow:self.window
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
        @"project" : TerminalLedgerProject(directory),
        @"bookmarked" : @NO,
        @"annotations" : @[],
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

- (void)addAnnotation:(NSString *)annotation
             toRecord:(NSString *)identifier {
    NSString *trimmed = [annotation
        stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSDictionary *record = [self recordWithIdentifier:identifier];
    if (record == nil || trimmed.length == 0) return;
    NSMutableArray *annotations =
        [record[@"annotations"] isKindOfClass:NSArray.class]
            ? [record[@"annotations"] mutableCopy]
            : [NSMutableArray array];
    [annotations addObject:@{
        @"text" : TerminalLedgerRedact(trimmed),
        @"timestamp" : @([NSDate date].timeIntervalSince1970),
    }];
    [self updateRecord:identifier values:@{@"annotations" : annotations}];
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
    _runbookButton = [self buttonWithTitle:@"▤ Runbook"
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
            self.detailsButton, self.rerunButton, self.askButton
        ]];
    } else if (width < 820) {
        visibleButtons = [NSSet setWithArray:@[
            self.detailsButton, self.runbookButton, self.rerunButton,
            self.askButton, self.bookmarkButton
        ]];
    } else {
        visibleButtons = [NSSet setWithArray:buttons];
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
        right -= 5;
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

@interface TerminalLedgerWindowController ()
@property(nonatomic, strong) TerminalLedgerStore *store;
@property(nonatomic, strong) TerminalTheme *theme;
@property(nonatomic, strong) NSSearchField *searchField;
@property(nonatomic, strong) NSPopUpButton *statusFilter;
@property(nonatomic, strong) NSPopUpButton *environmentFilter;
@property(nonatomic, strong) NSButton *bookmarksOnlyButton;
@property(nonatomic, strong) NSPopUpButton *savedSearches;
@property(nonatomic, strong) NSButton *saveSearchButton;
@property(nonatomic, strong) NSTextField *resultCountLabel;
@property(nonatomic, strong) NSTableView *tableView;
@property(nonatomic, strong) NSTextView *detailView;
@property(nonatomic, copy) NSArray<NSDictionary *> *filteredRecords;
@end

@implementation TerminalLedgerWindowController

- (instancetype)initWithStore:(TerminalLedgerStore *)store
                         theme:(TerminalTheme *)theme {
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 1120, 650)
                  styleMask:NSWindowStyleMaskTitled |
                            NSWindowStyleMaskClosable |
                            NSWindowStyleMaskMiniaturizable |
                            NSWindowStyleMaskResizable
                    backing:NSBackingStoreBuffered
                      defer:NO];
    window.title = @"TerminalDB — History Database";
    window.contentMinSize = NSMakeSize(900, 520);
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
        [[NSSearchField alloc] initWithFrame:NSMakeRect(18, 605, 390, 28)];
    self.searchField.placeholderString =
        @"Search commands, paths, output, or ask naturally";
    self.searchField.delegate = self;
    [content addSubview:self.searchField];

    self.statusFilter =
        [[NSPopUpButton alloc] initWithFrame:NSMakeRect(420, 605, 112, 28)
                                  pullsDown:NO];
    [self.statusFilter addItemsWithTitles:
        @[@"All status", @"Succeeded", @"Failed"]];
    self.statusFilter.target = self;
    self.statusFilter.action = @selector(filterChanged:);
    [content addSubview:self.statusFilter];

    self.environmentFilter =
        [[NSPopUpButton alloc] initWithFrame:NSMakeRect(540, 605, 122, 28)
                                  pullsDown:NO];
    [self.environmentFilter addItemsWithTitles:
        @[@"All environments", @"Local", @"Remote", @"Staging",
          @"Production"]];
    self.environmentFilter.target = self;
    self.environmentFilter.action = @selector(filterChanged:);
    [content addSubview:self.environmentFilter];

    self.bookmarksOnlyButton =
        [NSButton checkboxWithTitle:@"Bookmarks"
                             target:self
                             action:@selector(filterChanged:)];
    self.bookmarksOnlyButton.frame = NSMakeRect(672, 607, 102, 24);
    [content addSubview:self.bookmarksOnlyButton];

    self.savedSearches =
        [[NSPopUpButton alloc] initWithFrame:NSMakeRect(780, 605, 150, 28)
                                  pullsDown:NO];
    self.savedSearches.target = self;
    self.savedSearches.action = @selector(selectSavedSearch:);
    [content addSubview:self.savedSearches];
    self.saveSearchButton =
        [NSButton buttonWithTitle:@"Save"
                           target:self
                           action:@selector(saveCurrentSearch:)];
    self.saveSearchButton.frame = NSMakeRect(936, 605, 66, 28);
    self.saveSearchButton.controlSize = NSControlSizeSmall;
    [content addSubview:self.saveSearchButton];

    self.resultCountLabel = [NSTextField labelWithString:@""];
    self.resultCountLabel.font =
        [NSFont fontWithName:self.theme.fontName size:9.5]
            ?: [NSFont monospacedSystemFontOfSize:9.5
                                           weight:NSFontWeightRegular];
    self.resultCountLabel.textColor = self.theme.statusBarForeground;
    self.resultCountLabel.alignment = NSTextAlignmentRight;
    self.resultCountLabel.frame = NSMakeRect(1008, 609, 94, 18);
    [content addSubview:self.resultCountLabel];

    NSTextField *privacy = [NSTextField labelWithString:
        @"LOCAL LEDGER · secrets redacted · stored only on this Mac"];
    privacy.font =
        [NSFont fontWithName:self.theme.fontName size:9.5]
            ?: [NSFont monospacedSystemFontOfSize:9.5
                                           weight:NSFontWeightRegular];
    privacy.textColor = self.theme.ansiColors[6];
    privacy.frame = NSMakeRect(600, 582, 502, 18);
    privacy.alignment = NSTextAlignmentRight;
    [content addSubview:privacy];
    [self reloadSavedSearches];

    NSScrollView *tableScroll =
        [[NSScrollView alloc] initWithFrame:NSMakeRect(18, 84, 580, 492)];
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
        @[@"bookmark", @"", @26],
        @[@"command", @"Command", @280],
        @[@"project", @"Project", @105],
        @[@"environment", @"Env", @78],
        @[@"status", @"Status", @72],
        @[@"duration", @"Time", @68],
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
        [[NSScrollView alloc] initWithFrame:NSMakeRect(612, 84, 490, 492)];
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
    paste.frame = NSMakeRect(18, 30, 142, 32);
    [content addSubview:paste];
    NSButton *ask = [NSButton buttonWithTitle:@"✦ Ask AI"
                                       target:self
                                       action:@selector(askSelected:)];
    ask.frame = NSMakeRect(168, 30, 104, 32);
    [content addSubview:ask];
    NSButton *rerun = [NSButton buttonWithTitle:@"↻ Rerun"
                                         target:self
                                         action:@selector(rerunSelected:)];
    rerun.frame = NSMakeRect(280, 30, 96, 32);
    [content addSubview:rerun];
    NSButton *bookmark = [NSButton buttonWithTitle:@"☆ Bookmark"
                                            target:self
                                            action:@selector(bookmarkSelected:)];
    bookmark.frame = NSMakeRect(384, 30, 116, 32);
    [content addSubview:bookmark];
    NSButton *runbook = [NSButton buttonWithTitle:@"▤ Save as Runbook"
                                           target:self
                                           action:@selector(runbookSelected:)];
    runbook.frame = NSMakeRect(508, 30, 150, 32);
    [content addSubview:runbook];
    NSButton *export = [NSButton buttonWithTitle:@"Export…"
                                          target:self
                                          action:@selector(exportHistory:)];
    export.frame = NSMakeRect(666, 30, 96, 32);
    [content addSubview:export];
    NSButton *clear = [NSButton buttonWithTitle:@"Clear History…"
                                         target:self
                                         action:@selector(clearHistory:)];
    clear.frame = NSMakeRect(970, 30, 132, 32);
    clear.contentTintColor = self.theme.ansiColors[1];
    [content addSubview:clear];
    [self reload];
}

- (NSArray<NSString *> *)savedSearchValues {
    NSArray *saved = [NSUserDefaults.standardUserDefaults
        arrayForKey:@"TerminalDBSavedHistorySearches"];
    NSMutableArray<NSString *> *values = [NSMutableArray array];
    for (id value in saved ?: @[]) {
        if ([value isKindOfClass:NSString.class] &&
            [value length] > 0) {
            [values addObject:value];
        }
    }
    return values;
}

- (void)reloadSavedSearches {
    [self.savedSearches removeAllItems];
    [self.savedSearches addItemWithTitle:@"Saved searches"];
    self.savedSearches.lastItem.enabled = NO;
    NSArray<NSString *> *values = [self savedSearchValues];
    for (NSString *query in values) {
        [self.savedSearches addItemWithTitle:query];
        self.savedSearches.lastItem.representedObject = query;
    }
    if (values.count == 0) {
        [self.savedSearches addItemWithTitle:@"No saved searches"];
        self.savedSearches.lastItem.enabled = NO;
    }
    [self.savedSearches selectItemAtIndex:0];
}

- (void)selectSavedSearch:(NSPopUpButton *)sender {
    NSString *query =
        [sender.selectedItem.representedObject isKindOfClass:NSString.class]
            ? sender.selectedItem.representedObject : @"";
    if (query.length == 0) return;
    self.searchField.stringValue = query;
    [self reload];
}

- (void)saveCurrentSearch:(id)sender {
    (void)sender;
    NSString *query = [self.searchField.stringValue
        stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (query.length == 0) {
        NSBeep();
        return;
    }
    NSMutableOrderedSet<NSString *> *saved =
        [NSMutableOrderedSet orderedSetWithArray:
            [self savedSearchValues]];
    [saved addObject:query];
    while (saved.count > 20) [saved removeObjectAtIndex:0];
    [NSUserDefaults.standardUserDefaults
        setObject:saved.array
           forKey:@"TerminalDBSavedHistorySearches"];
    [self reloadSavedSearches];
    [self.savedSearches selectItemWithTitle:query];
}

- (void)historyChanged:(NSNotification *)notification {
    (void)notification;
    [self reload];
}

- (void)reload {
    NSMutableDictionary *filters = [NSMutableDictionary dictionary];
    NSString *status = self.statusFilter.titleOfSelectedItem;
    if ([status isEqualToString:@"Succeeded"]) filters[@"status"] = @"success";
    if ([status isEqualToString:@"Failed"]) filters[@"status"] = @"failed";
    NSString *environment = self.environmentFilter.titleOfSelectedItem;
    if (![environment isEqualToString:@"All environments"] &&
        environment.length > 0) {
        filters[@"environment"] = environment.uppercaseString;
    }
    if (self.bookmarksOnlyButton.state == NSControlStateValueOn) {
        filters[@"bookmarked"] = @YES;
    }
    self.filteredRecords =
        [self.store recordsMatching:self.searchField.stringValue
                            filters:filters];
    self.resultCountLabel.stringValue = [NSString stringWithFormat:
        @"%lu of %lu blocks",
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
    NSMutableArray<NSString *> *annotations = [NSMutableArray array];
    for (NSDictionary *annotation in
            [record[@"annotations"] isKindOfClass:NSArray.class]
                ? record[@"annotations"] : @[]) {
        NSString *text = annotation[@"text"];
        if (text.length > 0) [annotations addObject:[@"• " stringByAppendingString:text]];
    }
    NSString *annotationText = annotations.count > 0
        ? [NSString stringWithFormat:@"\n\nANNOTATIONS\n%@",
            [annotations componentsJoinedByString:@"\n"]]
        : @"";
    self.detailView.string = [NSString stringWithFormat:
        @"%@  BLOCK %@\n\n❯ %@\n\n%@ · %@ · %@ · exit %@ · %.2fs\n"
         "%@\n\n%@%@",
        [record[@"bookmarked"] boolValue] ? @"★" : @"",
        record[@"id"] ?: @"",
        record[@"command"] ?: @"",
        record[@"directory"] ?: @"",
        record[@"host"] ?: @"Mac",
        record[@"environment"] ?: @"LOCAL",
        record[@"exit_code"] ?: @(-1),
        [record[@"duration"] doubleValue],
        [formatter stringFromDate:date],
        record[@"output"] ?: @"(no captured output)",
        annotationText];
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

- (void)exportHistory:(id)sender {
    (void)sender;
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.title = @"Export TerminalDB History";
    panel.nameFieldStringValue = @"terminaldb-history.json";
    [panel beginSheetModalForWindow:self.window
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
    if ([alert runModal] == NSAlertFirstButtonReturn) {
        [self.store clearHistory];
    }
}

@end
