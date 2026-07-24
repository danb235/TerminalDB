#import "ClaudeAssistantView.h"

#import "TerminalTheme.h"

@interface ClaudeCommandButton : NSButton
@property(nonatomic, copy) NSString *command;
@property(nonatomic, copy) NSString *actionKind;
@end

@implementation ClaudeCommandButton
@end

@interface ClaudeContextButton : NSButton
@property(nonatomic, copy) NSString *contextIdentifier;
@property(nonatomic) BOOL removable;
@end

@implementation ClaudeContextButton
@end

@interface ClaudePassthroughTextField : NSTextField
@end

@implementation ClaudePassthroughTextField

- (nullable NSView *)hitTest:(NSPoint)point {
    (void)point;
    return nil;
}

@end

@interface ClaudePromptTextView : NSTextView
@property(nonatomic, copy, nullable) void (^submitHandler)(void);
@end

@implementation ClaudePromptTextView

- (void)keyDown:(NSEvent *)event {
    NSEventModifierFlags modifiers =
        event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    NSString *characters = event.characters;
    if (characters.length > 0 &&
        ([characters characterAtIndex:0] == NSCarriageReturnCharacter ||
         [characters characterAtIndex:0] == NSNewlineCharacter) &&
        (modifiers & NSEventModifierFlagShift) == 0) {
        if (self.submitHandler != nil) self.submitHandler();
        return;
    }
    [super keyDown:event];
}

@end

@interface ClaudeAssistantView () <NSTextViewDelegate>
@property(nonatomic, strong) TerminalTheme *theme;
@property(nonatomic, strong) NSTextField *titleLabel;
@property(nonatomic, strong) NSTextField *statusLabel;
@property(nonatomic, strong) NSProgressIndicator *progress;
@property(nonatomic, strong) NSButton *startConversationButton;
@property(nonatomic, strong) NSButton *headerSettingsButton;
@property(nonatomic, strong) NSButton *settingsButton;
@property(nonatomic, strong) NSScrollView *responseScrollView;
@property(nonatomic, strong) NSTextView *responseTextView;
@property(nonatomic, strong) NSBox *composerBox;
@property(nonatomic, strong) NSScrollView *composerScrollView;
@property(nonatomic, strong) ClaudePromptTextView *followUpField;
@property(nonatomic, strong) NSTextField *composerPlaceholder;
@property(nonatomic, strong) NSTextField *contextLabel;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *mutableContextItems;
@property(nonatomic, copy) NSArray<ClaudeContextButton *> *contextButtons;
@property(nonatomic, strong) NSButton *sendButton;
@property(nonatomic, copy) NSArray<NSDictionary *> *conversationMessages;
@property(nonatomic, copy) NSString *response;
@property(nonatomic, copy) NSString *modelName;
@property(nonatomic, copy) NSArray<NSButton *> *commandButtons;
@property(nonatomic, strong)
    NSMutableArray<NSDictionary *> *inlineCommandMarkers;
@property(nonatomic) BOOL working;
- (void)installInlineCommandButtons;
- (void)positionInlineCommandButtons;
- (void)rebuildContextButtons;
@end

@implementation ClaudeAssistantView

- (instancetype)initWithFrame:(NSRect)frame theme:(TerminalTheme *)theme {
    self = [super initWithFrame:frame];
    if (self == nil) return nil;
    _theme = theme;
    _conversationMessages = @[];
    _response = @"";
    _modelName = @"Claude";
    _commandButtons = @[];
    _inlineCommandMarkers = [NSMutableArray array];
    _mutableContextItems = [NSMutableArray arrayWithArray:@[
        @{
            @"id" : @"terminal-output",
            @"label" : @"Output",
            @"icon" : @"▣",
            @"removable" : @NO,
        },
        @{
            @"id" : @"current-directory",
            @"label" : @"Directory",
            @"icon" : @"⌂",
            @"removable" : @NO,
        },
    ]];
    _contextButtons = @[];
    self.wantsLayer = YES;

    _titleLabel = [self labelWithFont:
        [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold]];
    _titleLabel.stringValue = @"AI";
    _titleLabel.textColor = theme.terminalForeground;
    [self addSubview:_titleLabel];

    _statusLabel = [self labelWithFont:
        [NSFont systemFontOfSize:11 weight:NSFontWeightRegular]];
    _statusLabel.textColor = theme.statusBarActiveForeground;
    [self addSubview:_statusLabel];

    _progress = [[NSProgressIndicator alloc]
        initWithFrame:NSMakeRect(0, 0, 14, 14)];
    _progress.style = NSProgressIndicatorStyleSpinning;
    _progress.controlSize = NSControlSizeSmall;
    _progress.displayedWhenStopped = NO;
    [self addSubview:_progress];

    _startConversationButton =
        [self headerButtonWithTitle:@"New chat"
                           toolTip:@"Clear this tab’s AI context and start fresh"
                             action:@selector(newConversationSelected:)];
    _startConversationButton.font =
        [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];

    _headerSettingsButton =
        [self headerButtonWithTitle:@""
                           toolTip:@"Claude API key and model settings"
                             action:@selector(settingsSelected:)];
    NSImage *settingsImage =
        [NSImage imageWithSystemSymbolName:@"gearshape"
                  accessibilityDescription:@"Claude API Settings"];
    settingsImage = [settingsImage imageWithSymbolConfiguration:
        [NSImageSymbolConfiguration configurationWithPointSize:13
                                                        weight:NSFontWeightMedium]];
    _headerSettingsButton.image = settingsImage;
    _headerSettingsButton.imagePosition = NSImageOnly;
    [_headerSettingsButton setAccessibilityLabel:@"Claude API Settings"];

    _settingsButton = [[NSButton alloc] initWithFrame:NSZeroRect];
    _settingsButton.title = @"Open API Settings";
    _settingsButton.bezelStyle = NSBezelStyleRounded;
    _settingsButton.controlSize = NSControlSizeSmall;
    _settingsButton.target = self;
    _settingsButton.action = @selector(settingsSelected:);
    _settingsButton.hidden = YES;
    [self addSubview:_settingsButton];

    _responseScrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _responseScrollView.hasVerticalScroller = YES;
    _responseScrollView.drawsBackground = NO;
    _responseScrollView.borderType = NSNoBorder;
    _responseScrollView.scrollerStyle = NSScrollerStyleOverlay;

    _responseTextView = [[NSTextView alloc] initWithFrame:NSZeroRect];
    _responseTextView.editable = NO;
    _responseTextView.selectable = YES;
    _responseTextView.drawsBackground = NO;
    _responseTextView.textContainerInset = NSMakeSize(4, 10);
    _responseTextView.textContainer.widthTracksTextView = YES;
    _responseTextView.horizontallyResizable = NO;
    _responseTextView.verticallyResizable = YES;
    _responseTextView.autoresizingMask = NSViewWidthSizable;
    _responseTextView.linkTextAttributes = @{
        NSForegroundColorAttributeName : theme.ansiColors[6],
        NSUnderlineStyleAttributeName : @(NSUnderlineStyleSingle),
    };
    _responseScrollView.documentView = _responseTextView;
    [self addSubview:_responseScrollView];

    _composerBox = [[NSBox alloc] initWithFrame:NSZeroRect];
    _composerBox.boxType = NSBoxCustom;
    _composerBox.fillColor =
        [NSColor colorWithSRGBRed:0.125 green:0.125 blue:0.145 alpha:1.0];
    _composerBox.borderColor = theme.statusBarBorder;
    _composerBox.borderWidth = 1.0;
    _composerBox.cornerRadius = 6.0;
    [self addSubview:_composerBox];

    _composerScrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _composerScrollView.hasVerticalScroller = YES;
    _composerScrollView.autohidesScrollers = YES;
    _composerScrollView.drawsBackground = NO;
    _composerScrollView.borderType = NSNoBorder;

    _followUpField = [[ClaudePromptTextView alloc] initWithFrame:NSZeroRect];
    _followUpField.delegate = self;
    _followUpField.drawsBackground = NO;
    _followUpField.richText = NO;
    _followUpField.font =
        [NSFont systemFontOfSize:13 weight:NSFontWeightRegular];
    _followUpField.textColor = theme.terminalForeground;
    _followUpField.insertionPointColor = theme.cursorColor;
    _followUpField.textContainerInset = NSMakeSize(2, 4);
    _followUpField.textContainer.widthTracksTextView = YES;
    _followUpField.horizontallyResizable = NO;
    _followUpField.verticallyResizable = YES;
    _followUpField.autoresizingMask = NSViewWidthSizable;
    _followUpField.minSize = NSMakeSize(0, 44);
    _followUpField.maxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
    __weak typeof(self) weakSelf = self;
    _followUpField.submitHandler = ^{
        [weakSelf submitFollowUp:nil];
    };
    _composerScrollView.documentView = _followUpField;
    [self addSubview:_composerScrollView];

    _composerPlaceholder =
        [[ClaudePassthroughTextField alloc] initWithFrame:NSZeroRect];
    _composerPlaceholder.editable = NO;
    _composerPlaceholder.selectable = NO;
    _composerPlaceholder.bezeled = NO;
    _composerPlaceholder.drawsBackground = NO;
    _composerPlaceholder.font =
        [NSFont systemFontOfSize:13 weight:NSFontWeightRegular];
    _composerPlaceholder.stringValue =
        @"Ask about this terminal, or describe what you want…";
    _composerPlaceholder.textColor = theme.statusBarForeground;
    _composerPlaceholder.lineBreakMode = NSLineBreakByTruncatingTail;
    [self addSubview:_composerPlaceholder];

    _contextLabel = [self labelWithFont:
        [NSFont systemFontOfSize:10 weight:NSFontWeightRegular]];
    _contextLabel.stringValue = @"Context";
    _contextLabel.textColor = theme.ansiColors[6];
    _contextLabel.toolTip =
        @"Each message includes this tab’s current directory and visible "
         "terminal output.";
    [self addSubview:_contextLabel];
    [self rebuildContextButtons];

    _sendButton = [[NSButton alloc] initWithFrame:NSZeroRect];
    _sendButton.title = @"↑";
    _sendButton.bezelStyle = NSBezelStyleCircular;
    _sendButton.font =
        [NSFont systemFontOfSize:16 weight:NSFontWeightSemibold];
    _sendButton.contentTintColor = theme.terminalForeground;
    _sendButton.target = self;
    _sendButton.action = @selector(submitFollowUp:);
    _sendButton.toolTip = @"Send (Return). Use Shift-Return for a new line.";
    [self addSubview:_sendButton];
    return self;
}

- (NSTextField *)labelWithFont:(NSFont *)font {
    NSTextField *label = [[NSTextField alloc] initWithFrame:NSZeroRect];
    label.editable = NO;
    label.selectable = NO;
    label.bezeled = NO;
    label.drawsBackground = NO;
    label.font = font;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    return label;
}

- (NSButton *)headerButtonWithTitle:(NSString *)title
                            toolTip:(NSString *)toolTip
                              action:(SEL)action {
    NSButton *button = [[NSButton alloc] initWithFrame:NSZeroRect];
    button.title = title;
    button.bordered = NO;
    button.contentTintColor = self.theme.statusBarActiveForeground;
    button.target = self;
    button.action = action;
    button.toolTip = toolTip;
    [self addSubview:button];
    return button;
}

- (BOOL)isFlipped {
    return YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    [[NSColor colorWithSRGBRed:0.106 green:0.106 blue:0.122 alpha:1.0]
        setFill];
    NSRectFill(self.bounds);
    [self.theme.statusBarBorder setFill];
    NSRectFill(NSMakeRect(0, 0, 1, self.bounds.size.height));
    NSRectFill(NSMakeRect(0, 49, self.bounds.size.width, 1));
}

- (void)layout {
    [super layout];
    const CGFloat padding = 14;
    const CGFloat headerHeight = 50;
    const CGFloat composerHeight = 118;
    CGFloat width = self.bounds.size.width;
    CGFloat height = self.bounds.size.height;

    self.titleLabel.frame = NSMakeRect(padding, 7, MAX(80, width - 150), 18);
    self.progress.frame = NSMakeRect(padding, 29, 14, 14);
    CGFloat statusX = self.working ? padding + 20 : padding;
    self.statusLabel.frame =
        NSMakeRect(statusX, 27, MAX(80, width - statusX - 14), 17);
    self.startConversationButton.frame =
        NSMakeRect(width - 118, 6, 76, 26);
    self.headerSettingsButton.frame =
        NSMakeRect(width - 40, 6, 26, 26);

    CGFloat commandHeight = 0;
    if (!self.settingsButton.hidden) commandHeight += 36;

    CGFloat composerY = height - padding - composerHeight;
    CGFloat commandsY = composerY - commandHeight - 8;
    self.responseScrollView.frame =
        NSMakeRect(padding,
                   headerHeight + 5,
                   MAX(40, width - padding * 2),
                   MAX(40, commandsY - headerHeight - 5));

    if (!self.settingsButton.hidden) {
        self.settingsButton.frame =
            NSMakeRect(padding, commandsY,
                       MAX(80, width - padding * 2), 30);
    }

    self.composerBox.frame =
        NSMakeRect(padding, composerY, MAX(80, width - padding * 2),
                   composerHeight);
    self.composerScrollView.frame =
        NSMakeRect(padding + 10, composerY + 8,
                   MAX(40, width - padding * 2 - 20), 67);
    NSSize composerViewport = self.composerScrollView.contentSize;
    self.followUpField.frame =
        NSMakeRect(0, 0, composerViewport.width,
                   MAX(56, composerViewport.height));
    self.composerPlaceholder.frame =
        NSMakeRect(padding + 14, composerY + 12,
                   MAX(20, width - padding * 2 - 28), 20);
    self.contextLabel.frame =
        NSMakeRect(padding + 12, composerY + 88, 42, 16);
    CGFloat contextX = padding + 56;
    CGFloat contextMaxX = width - padding - 48;
    for (ClaudeContextButton *button in self.contextButtons) {
        CGFloat buttonWidth =
            MIN(170, MAX(62, [button.title sizeWithAttributes:@{
                NSFontAttributeName : button.font
            }].width + 20));
        if (contextX + buttonWidth > contextMaxX) {
            button.hidden = YES;
            continue;
        }
        button.hidden = NO;
        button.frame =
            NSMakeRect(contextX, composerY + 84, buttonWidth, 24);
        contextX += buttonWidth + 6;
    }
    self.sendButton.frame =
        NSMakeRect(width - padding - 40, composerY + 79, 30, 30);
    [self positionInlineCommandButtons];
}

- (void)beginWithModelName:(NSString *)modelName
                  messages:(NSArray<NSDictionary *> *)messages {
    self.modelName = modelName.length > 0 ? modelName : @"Claude";
    self.conversationMessages = [messages copy] ?: @[];
    self.response = @"";
    self.statusLabel.stringValue =
        [NSString stringWithFormat:@"%@ · Working…", self.modelName];
    self.statusLabel.textColor = self.theme.statusBarActiveForeground;
    self.settingsButton.hidden = YES;
    self.followUpField.editable = NO;
    self.sendButton.enabled = NO;
    self.working = YES;
    [self removeCommandButtons];
    [self.progress startAnimation:nil];
    [self renderResponse];
    [self setNeedsLayout:YES];
}

- (void)resetConversationWithModelName:(NSString *)modelName {
    self.modelName = modelName.length > 0 ? modelName : @"Claude";
    self.conversationMessages = @[];
    self.response = @"";
    self.statusLabel.stringValue =
        [NSString stringWithFormat:@"%@ · New chat", self.modelName];
    self.statusLabel.textColor = self.theme.statusBarActiveForeground;
    self.settingsButton.hidden = YES;
    self.followUpField.string = @"";
    self.followUpField.editable = YES;
    self.composerPlaceholder.stringValue =
        @"Ask about this terminal, or describe what you want…";
    self.sendButton.enabled = YES;
    self.working = NO;
    [self setContextItems:@[
        @{
            @"id" : @"terminal-output",
            @"label" : @"Output",
            @"icon" : @"▣",
            @"removable" : @NO,
        },
        @{
            @"id" : @"current-directory",
            @"label" : @"Directory",
            @"icon" : @"⌂",
            @"removable" : @NO,
        },
    ]];
    [self.progress stopAnimation:nil];
    [self removeCommandButtons];
    [self updateComposerPlaceholder];
    [self renderResponse];
    [self setNeedsLayout:YES];
    [self focusComposer];
}

- (void)showConfigurationRequired:(NSString *)message {
    [self.progress stopAnimation:nil];
    self.modelName = @"Claude";
    self.response =
        message.length > 0
            ? message
            : @"Add an Anthropic API key and choose a model to use AI chat.";
    self.statusLabel.stringValue = @"Claude · Setup required";
    self.statusLabel.textColor = self.theme.ansiColors[3];
    self.settingsButton.hidden = NO;
    self.followUpField.string = @"";
    self.followUpField.editable = NO;
    self.composerPlaceholder.stringValue =
        @"Add an API key and choose a model to start chatting…";
    self.composerPlaceholder.hidden = NO;
    self.sendButton.enabled = NO;
    self.working = NO;
    [self removeCommandButtons];
    [self renderResponse];
    [self setNeedsLayout:YES];
}

- (void)appendResponseText:(NSString *)text {
    if (text.length == 0) return;
    self.response = [self.response stringByAppendingString:text];
    self.statusLabel.stringValue =
        [NSString stringWithFormat:@"%@ · Streaming…", self.modelName];
    [self renderResponse];
}

- (void)showToolStatus:(NSString *)status {
    self.statusLabel.stringValue =
        [NSString stringWithFormat:@"%@ · %@",
            self.modelName,
            status.length > 0 ? status : @"Inspecting terminal…"];
    self.statusLabel.textColor = self.theme.statusBarActiveForeground;
    self.working = YES;
    [self.progress startAnimation:nil];
}

- (void)finish {
    [self.progress stopAnimation:nil];
    self.working = NO;
    self.statusLabel.stringValue =
        [NSString stringWithFormat:@"%@ · Ready", self.modelName];
    self.followUpField.editable = YES;
    self.sendButton.enabled = YES;
    [self renderResponse];
    [self setNeedsLayout:YES];
    [self focusComposer];
}

- (void)showError:(NSString *)message
 settingsAvailable:(BOOL)settingsAvailable {
    [self.progress stopAnimation:nil];
    self.working = NO;
    self.response = message ?: @"Claude request failed.";
    self.statusLabel.stringValue =
        [NSString stringWithFormat:@"%@ · Request failed", self.modelName];
    self.statusLabel.textColor = self.theme.ansiColors[1];
    self.settingsButton.hidden = !settingsAvailable;
    self.followUpField.editable = YES;
    self.sendButton.enabled = YES;
    [self removeCommandButtons];
    [self renderResponse];
    [self setNeedsLayout:YES];
}

- (void)setDraftPrompt:(NSString *)prompt {
    self.followUpField.string = prompt ?: @"";
    [self updateComposerPlaceholder];
    [self focusComposer];
}

- (NSArray<NSDictionary *> *)contextItems {
    return [self.mutableContextItems copy];
}

- (void)setContextItems:(NSArray<NSDictionary *> *)items {
    [self.mutableContextItems removeAllObjects];
    for (NSDictionary *item in items) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSString *identifier = item[@"id"];
        if (identifier.length == 0) continue;
        [self.mutableContextItems addObject:[item copy]];
    }
    [self rebuildContextButtons];
}

- (void)addContextItem:(NSDictionary *)item {
    NSString *identifier = item[@"id"];
    if (identifier.length == 0) return;
    NSIndexSet *matches = [self.mutableContextItems
        indexesOfObjectsPassingTest:
            ^BOOL(NSDictionary *candidate, NSUInteger index, BOOL *stop) {
        (void)index;
        (void)stop;
        return [candidate[@"id"] isEqualToString:identifier];
    }];
    if (matches.count > 0) {
        [self.mutableContextItems removeObjectsAtIndexes:matches];
    }
    [self.mutableContextItems addObject:[item copy]];
    [self rebuildContextButtons];
}

- (NSString *)attachedContextForPrompt {
    NSMutableArray<NSString *> *sections = [NSMutableArray array];
    for (NSDictionary *item in self.mutableContextItems) {
        NSString *payload = item[@"payload"];
        if (payload.length == 0) continue;
        NSString *label = item[@"label"] ?: @"Attached context";
        [sections addObject:[NSString stringWithFormat:
            @"[%@]\n%@", label, payload]];
    }
    return [sections componentsJoinedByString:@"\n\n"];
}

- (void)rebuildContextButtons {
    for (ClaudeContextButton *button in self.contextButtons) {
        [button removeFromSuperview];
    }
    NSMutableArray<ClaudeContextButton *> *buttons =
        [NSMutableArray array];
    for (NSDictionary *item in self.mutableContextItems) {
        ClaudeContextButton *button =
            [[ClaudeContextButton alloc] initWithFrame:NSZeroRect];
        button.contextIdentifier = item[@"id"] ?: @"";
        button.removable = [item[@"removable"] boolValue];
        NSString *icon = item[@"icon"] ?: @"●";
        NSString *label = item[@"label"] ?: @"Context";
        button.title = button.removable
            ? [NSString stringWithFormat:@"%@ %@  ×", icon, label]
            : [NSString stringWithFormat:@"%@ %@", icon, label];
        button.font =
            [NSFont systemFontOfSize:10 weight:NSFontWeightMedium];
        button.bezelStyle = NSBezelStyleInline;
        button.controlSize = NSControlSizeSmall;
        button.contentTintColor = self.theme.ansiColors[6];
        button.toolTip = item[@"detail"] ?: label;
        button.target = self;
        button.action = @selector(contextButtonSelected:);
        [button setAccessibilityLabel:
            button.removable
                ? [NSString stringWithFormat:@"Remove context: %@", label]
                : [NSString stringWithFormat:@"Included context: %@", label]];
        [self addSubview:button];
        [buttons addObject:button];
    }
    self.contextButtons = buttons;
    [self setNeedsLayout:YES];
}

- (void)contextButtonSelected:(ClaudeContextButton *)sender {
    if (!sender.removable) return;
    NSIndexSet *matches = [self.mutableContextItems
        indexesOfObjectsPassingTest:
            ^BOOL(NSDictionary *candidate, NSUInteger index, BOOL *stop) {
        (void)index;
        (void)stop;
        return [candidate[@"id"]
            isEqualToString:sender.contextIdentifier];
    }];
    if (matches.count > 0) {
        [self.mutableContextItems removeObjectsAtIndexes:matches];
        [self rebuildContextButtons];
    }
}

- (void)focusComposer {
    if (self.hidden || self.window == nil) return;
    __weak typeof(self) weakSelf = self;
    void (^focus)(void) = ^{
        ClaudeAssistantView *strongSelf = weakSelf;
        if (strongSelf == nil || strongSelf.hidden) return;
        [strongSelf.window makeFirstResponder:strongSelf.followUpField];
    };
    dispatch_async(dispatch_get_main_queue(), focus);
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), focus);
}

- (NSString *)commandFromFenceLines:(NSArray<NSString *> *)lines
                           language:(NSString *)language {
    NSSet<NSString *> *shellLanguages = [NSSet setWithArray:
        @[@"", @"sh", @"bash", @"zsh", @"shell", @"terminal", @"console"]];
    if (![shellLanguages containsObject:language.lowercaseString]) return nil;
    NSMutableArray<NSString *> *cleanLines = [NSMutableArray array];
    for (NSString *line in lines) {
        [cleanLines addObject:[line hasPrefix:@"$ "]
            ? [line substringFromIndex:2]
            : line];
    }
    NSString *command = [[cleanLines componentsJoinedByString:@"\n"]
        stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return command.length > 0 && command.length <= 8000 ? command : nil;
}

- (void)appendCommandButtonPlaceholder:(NSString *)command
                                    to:(NSMutableAttributedString *)rendered {
    if (command.length == 0) return;
    NSTextAttachment *attachment = [[NSTextAttachment alloc] init];
    attachment.image = [[NSImage alloc] initWithSize:NSMakeSize(132, 22)];
    attachment.bounds = NSMakeRect(0, -5, 132, 22);
    NSUInteger location = rendered.length;
    [rendered appendAttributedString:
        [NSAttributedString attributedStringWithAttachment:attachment]];
    [self.inlineCommandMarkers addObject:@{
        @"location" : @(location),
        @"command" : command,
        @"kind" : @"command",
    }];
}

- (void)appendPatchButtonPlaceholder:(NSString *)patch
                                  to:(NSMutableAttributedString *)rendered {
    if (patch.length == 0) return;
    NSTextAttachment *attachment = [[NSTextAttachment alloc] init];
    attachment.image = [[NSImage alloc] initWithSize:NSMakeSize(146, 22)];
    attachment.bounds = NSMakeRect(0, -5, 146, 22);
    NSUInteger location = rendered.length;
    [rendered appendAttributedString:
        [NSAttributedString attributedStringWithAttachment:attachment]];
    [self.inlineCommandMarkers addObject:@{
        @"location" : @(location),
        @"command" : patch,
        @"kind" : @"patch",
    }];
}

- (void)appendContent:(NSString *)content
                 role:(NSString *)role
                   to:(NSMutableAttributedString *)rendered {
    NSMutableParagraphStyle *bodyStyle =
        [[NSMutableParagraphStyle alloc] init];
    bodyStyle.lineSpacing = 2;
    bodyStyle.paragraphSpacing = 5;
    NSDictionary *base = @{
        NSFontAttributeName :
            [NSFont systemFontOfSize:13 weight:NSFontWeightRegular],
        NSForegroundColorAttributeName : self.theme.terminalForeground,
        NSParagraphStyleAttributeName : bodyStyle,
    };
    NSMutableParagraphStyle *codeStyle =
        [[NSMutableParagraphStyle alloc] init];
    codeStyle.lineSpacing = 3;
    codeStyle.paragraphSpacingBefore = 5;
    codeStyle.paragraphSpacing = 5;
    NSDictionary *code = @{
        NSFontAttributeName :
            [NSFont fontWithName:self.theme.fontName size:12] ?:
                [NSFont monospacedSystemFontOfSize:12
                                            weight:NSFontWeightRegular],
        NSForegroundColorAttributeName : self.theme.ansiColors[6],
        NSBackgroundColorAttributeName :
            [self.theme.terminalBackground colorWithAlphaComponent:0.9],
        NSParagraphStyleAttributeName : codeStyle,
    };
    BOOL assistant = [role isEqualToString:@"assistant"];
    NSDictionary *heading = @{
        NSFontAttributeName :
            [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName :
            assistant ? self.theme.ansiColors[2] : self.theme.ansiColors[6],
        NSKernAttributeName : @0.5,
    };
    [rendered appendAttributedString:[[NSAttributedString alloc]
        initWithString:assistant ? @"CLAUDE\n" : @"YOU\n"
            attributes:heading]];

    BOOL inCode = NO;
    NSString *fenceLanguage = @"";
    NSMutableArray<NSString *> *fenceLines = [NSMutableArray array];
    NSArray<NSString *> *lines =
        [content componentsSeparatedByString:@"\n"];
    for (NSUInteger index = 0; index < lines.count; index++) {
        NSString *line = lines[index];
        if ([line hasPrefix:@"```"]) {
            if (!inCode) {
                fenceLanguage = [[line substringFromIndex:3]
                    stringByTrimmingCharactersInSet:
                        NSCharacterSet.whitespaceAndNewlineCharacterSet];
                [fenceLines removeAllObjects];
                inCode = YES;
            } else {
                NSString *command = assistant
                    ? [self commandFromFenceLines:fenceLines
                                         language:fenceLanguage]
                    : nil;
                if (command.length > 0) {
                    [rendered appendAttributedString:[[NSAttributedString alloc]
                        initWithString:@"  " attributes:code]];
                    [self appendCommandButtonPlaceholder:command to:rendered];
                } else if (assistant &&
                           ([
                               fenceLanguage.lowercaseString
                               isEqualToString:@"diff"] ||
                            [fenceLanguage.lowercaseString
                               isEqualToString:@"patch"])) {
                    NSString *patch =
                        [[fenceLines componentsJoinedByString:@"\n"]
                            stringByTrimmingCharactersInSet:
                                NSCharacterSet.whitespaceAndNewlineCharacterSet];
                    if (patch.length > 0 && patch.length <= 100000) {
                        [rendered appendAttributedString:
                            [[NSAttributedString alloc]
                                initWithString:@"  " attributes:code]];
                        [self appendPatchButtonPlaceholder:patch to:rendered];
                    }
                }
                inCode = NO;
                fenceLanguage = @"";
                [fenceLines removeAllObjects];
                if (index + 1 < lines.count) {
                    [rendered appendAttributedString:
                        [[NSAttributedString alloc]
                            initWithString:@"\n" attributes:base]];
                }
            }
            continue;
        }
        if (inCode) [fenceLines addObject:line];
        NSString *output = line;
        if (!inCode) {
            output = [output stringByReplacingOccurrencesOfString:@"**"
                                                       withString:@""];
        }
        [rendered appendAttributedString:[[NSAttributedString alloc]
            initWithString:output attributes:inCode ? code : base]];
        BOOL nextClosesFence =
            inCode && index + 1 < lines.count &&
            [lines[index + 1] hasPrefix:@"```"];
        if (index + 1 < lines.count && !nextClosesFence) {
            [rendered appendAttributedString:[[NSAttributedString alloc]
                initWithString:@"\n" attributes:inCode ? code : base]];
        }
    }
}

- (NSString *)textContentFromMessageContent:(id)content {
    if ([content isKindOfClass:NSString.class]) return content;
    if (![content isKindOfClass:NSArray.class]) return @"";
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (id block in (NSArray *)content) {
        if (![block isKindOfClass:NSDictionary.class] ||
            ![block[@"type"] isEqualToString:@"text"] ||
            ![block[@"text"] isKindOfClass:NSString.class]) {
            continue;
        }
        [parts addObject:block[@"text"]];
    }
    return [parts componentsJoinedByString:@"\n"];
}

- (void)appendTerminalResult:(NSDictionary *)result
                           to:(NSMutableAttributedString *)rendered {
    NSDictionary *heading = @{
        NSFontAttributeName :
            [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName : self.theme.ansiColors[3],
        NSKernAttributeName : @0.5,
    };
    NSMutableParagraphStyle *codeStyle =
        [[NSMutableParagraphStyle alloc] init];
    codeStyle.lineSpacing = 2;
    codeStyle.paragraphSpacing = 3;
    NSDictionary *code = @{
        NSFontAttributeName :
            [NSFont fontWithName:self.theme.fontName size:11] ?:
                [NSFont monospacedSystemFontOfSize:11
                                            weight:NSFontWeightRegular],
        NSForegroundColorAttributeName : self.theme.terminalForeground,
        NSBackgroundColorAttributeName :
            [self.theme.terminalBackground colorWithAlphaComponent:0.9],
        NSParagraphStyleAttributeName : codeStyle,
    };
    NSDictionary *detail = @{
        NSFontAttributeName :
            [NSFont systemFontOfSize:10 weight:NSFontWeightRegular],
        NSForegroundColorAttributeName : self.theme.statusBarActiveForeground,
    };
    BOOL blocked = [result[@"blocked"] boolValue];
    NSString *command =
        [result[@"command"] isKindOfClass:NSString.class]
            ? result[@"command"]
            : @"";
    NSString *directory =
        [result[@"directory"] isKindOfClass:NSString.class]
            ? result[@"directory"]
            : @"";
    NSString *output =
        [result[@"output"] isKindOfClass:NSString.class]
            ? result[@"output"]
            : @"(no output)";
    NSNumber *exitCode =
        [result[@"exit_code"] isKindOfClass:NSNumber.class]
            ? result[@"exit_code"]
            : @(-1);
    NSNumber *duration =
        [result[@"duration"] isKindOfClass:NSNumber.class]
            ? result[@"duration"]
            : @0;
    [rendered appendAttributedString:[[NSAttributedString alloc]
        initWithString:blocked ? @"INSPECTION BLOCKED\n"
                               : @"TERMINAL INSPECTION\n"
            attributes:heading]];
    [rendered appendAttributedString:[[NSAttributedString alloc]
        initWithString:[NSString stringWithFormat:@"$ %@", command]
            attributes:code]];
    [rendered appendAttributedString:[[NSAttributedString alloc]
        initWithString:@"  " attributes:code]];
    [self appendCommandButtonPlaceholder:command to:rendered];
    [rendered appendAttributedString:[[NSAttributedString alloc]
        initWithString:[NSString stringWithFormat:@"\n%@", output]
            attributes:code]];
    NSString *footer = blocked
        ? [NSString stringWithFormat:@"\nNot run · %@", directory]
        : [NSString stringWithFormat:@"\nExit %@ · %.2fs · %@",
            exitCode, duration.doubleValue, directory];
    if ([result[@"timed_out"] boolValue]) {
        footer = [footer stringByAppendingString:@" · timed out"];
    }
    if ([result[@"truncated"] boolValue]) {
        footer = [footer stringByAppendingString:@" · truncated"];
    }
    [rendered appendAttributedString:[[NSAttributedString alloc]
        initWithString:footer attributes:detail]];
}

- (void)renderResponse {
    [self removeCommandButtons];
    [self.inlineCommandMarkers removeAllObjects];
    NSMutableAttributedString *rendered =
        [[NSMutableAttributedString alloc] init];
    NSDictionary *separator = @{
        NSFontAttributeName : [NSFont systemFontOfSize:7],
    };
    for (NSDictionary *message in self.conversationMessages) {
        NSString *role = [message[@"role"] isKindOfClass:NSString.class]
            ? message[@"role"]
            : @"assistant";
        id rawContent = message[@"content"];
        BOOL terminal = [role isEqualToString:@"terminal"] &&
            [rawContent isKindOfClass:NSDictionary.class];
        NSString *content = terminal
            ? @""
            : [self textContentFromMessageContent:rawContent];
        if (!terminal && content.length == 0) continue;
        if (rendered.length > 0) {
            [rendered appendAttributedString:[[NSAttributedString alloc]
                initWithString:@"\n\n" attributes:separator]];
        }
        if (terminal) {
            [self appendTerminalResult:rawContent to:rendered];
        } else {
            [self appendContent:content role:role to:rendered];
        }
    }
    if (self.response.length > 0) {
        if (rendered.length > 0) {
            [rendered appendAttributedString:[[NSAttributedString alloc]
                initWithString:@"\n\n" attributes:separator]];
        }
        [self appendContent:self.response role:@"assistant" to:rendered];
    }
    if (rendered.length == 0) {
        NSMutableParagraphStyle *style =
            [[NSMutableParagraphStyle alloc] init];
        style.lineSpacing = 3;
        NSDictionary *empty = @{
            NSFontAttributeName :
                [NSFont systemFontOfSize:13 weight:NSFontWeightRegular],
            NSForegroundColorAttributeName :
                self.theme.statusBarActiveForeground,
            NSParagraphStyleAttributeName : style,
        };
        [rendered appendAttributedString:[[NSAttributedString alloc]
            initWithString:
                @"Ask Claude to inspect what’s on screen, explain a command, "
                 "help write code, or plan your next step.\n\n"
                 "Your current directory and visible terminal output are "
                 "attached only when you send a message."
                attributes:empty]];
    }
    [self.responseTextView.textStorage setAttributedString:rendered];
    [self installInlineCommandButtons];
    [self.responseTextView scrollRangeToVisible:
        NSMakeRange(self.responseTextView.string.length, 0)];
}

+ (NSArray<NSString *> *)commandsFromMarkdown:(NSString *)markdown {
    if (markdown.length == 0) return @[];
    NSMutableArray<NSString *> *commands = [NSMutableArray array];
    NSSet<NSString *> *shellLanguages = [NSSet setWithArray:
        @[@"", @"sh", @"bash", @"zsh", @"shell", @"terminal", @"console"]];
    BOOL insideFence = NO;
    BOOL acceptedFence = NO;
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (NSString *line in [markdown componentsSeparatedByString:@"\n"]) {
        if ([line hasPrefix:@"```"]) {
            if (!insideFence) {
                NSString *language = [[line substringFromIndex:3]
                    stringByTrimmingCharactersInSet:
                        NSCharacterSet.whitespaceAndNewlineCharacterSet]
                    .lowercaseString;
                insideFence = YES;
                acceptedFence = [shellLanguages containsObject:language];
                [lines removeAllObjects];
            } else {
                if (acceptedFence) {
                    NSString *command = [[lines componentsJoinedByString:@"\n"]
                        stringByTrimmingCharactersInSet:
                            NSCharacterSet.whitespaceAndNewlineCharacterSet];
                    if (command.length > 0 && command.length <= 8000) {
                        NSMutableArray<NSString *> *cleanLines =
                            [NSMutableArray array];
                        for (NSString *commandLine in
                                [command componentsSeparatedByString:@"\n"]) {
                            [cleanLines addObject:
                                [commandLine hasPrefix:@"$ "]
                                    ? [commandLine substringFromIndex:2]
                                    : commandLine];
                        }
                        [commands addObject:
                            [cleanLines componentsJoinedByString:@"\n"]];
                        if (commands.count == 3) return commands;
                    }
                }
                insideFence = NO;
                acceptedFence = NO;
                [lines removeAllObjects];
            }
            continue;
        }
        if (insideFence && acceptedFence) [lines addObject:line];
    }
    return commands;
}

- (void)installInlineCommandButtons {
    NSMutableArray<NSButton *> *buttons = [NSMutableArray array];
    for (NSDictionary *marker in self.inlineCommandMarkers) {
        NSString *command =
            [marker[@"command"] isKindOfClass:NSString.class]
                ? marker[@"command"]
                : @"";
        if (command.length == 0) continue;

        BOOL patch = [marker[@"kind"] isEqualToString:@"patch"];
        ClaudeCommandButton *paste =
            [[ClaudeCommandButton alloc] initWithFrame:NSZeroRect];
        paste.title = patch ? @"Copy" : @"Paste";
        paste.bezelStyle = NSBezelStyleRounded;
        paste.controlSize = NSControlSizeMini;
        paste.alignment = NSTextAlignmentCenter;
        paste.font =
            [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold];
        paste.contentTintColor = self.theme.ansiColors[6];
        paste.target = self;
        paste.action = @selector(commandSelected:);
        paste.command = command;
        paste.actionKind = patch ? @"copy_patch" : @"paste";
        paste.toolTip = patch
            ? @"Copy this proposed patch"
            : [NSString stringWithFormat:
                @"Paste into the active terminal without running it:\n%@",
                command];
        [paste setAccessibilityLabel:
            patch ? @"Copy proposed patch" : @"Paste command into terminal"];
        [self.responseTextView addSubview:paste];
        [buttons addObject:paste];

        ClaudeCommandButton *run =
            [[ClaudeCommandButton alloc] initWithFrame:NSZeroRect];
        run.title = patch ? @"Apply…" : @"Run…";
        run.bezelStyle = NSBezelStyleRounded;
        run.controlSize = NSControlSizeMini;
        run.alignment = NSTextAlignmentCenter;
        run.font = [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold];
        run.contentTintColor = self.theme.ansiColors[2];
        run.target = self;
        run.action = @selector(commandSelected:);
        run.command = command;
        run.actionKind = patch ? @"apply_patch" : @"run";
        run.toolTip = patch
            ? @"Review this diff and create a permission-gated apply command"
            : [NSString stringWithFormat:
                @"Review permissions, target, and risk before running:\n%@",
                command];
        [run setAccessibilityLabel:
            patch ? @"Review and apply proposed patch"
                  : @"Review and run command"];
        [self.responseTextView addSubview:run];
        [buttons addObject:run];
    }
    self.commandButtons = buttons;
    [self positionInlineCommandButtons];
}

- (void)positionInlineCommandButtons {
    NSLayoutManager *layoutManager = self.responseTextView.layoutManager;
    NSTextContainer *textContainer = self.responseTextView.textContainer;
    if (layoutManager == nil || textContainer == nil) return;
    [layoutManager ensureLayoutForTextContainer:textContainer];

    NSUInteger count = MIN(self.inlineCommandMarkers.count,
                           self.commandButtons.count / 2);
    for (NSUInteger index = 0; index < count; index++) {
        NSDictionary *marker = self.inlineCommandMarkers[index];
        NSUInteger location = [marker[@"location"] unsignedIntegerValue];
        if (location >= self.responseTextView.string.length) continue;
        NSRange glyphRange = [layoutManager
            glyphRangeForCharacterRange:NSMakeRange(location, 1)
                  actualCharacterRange:NULL];
        NSRect markerRect = [layoutManager
            boundingRectForGlyphRange:glyphRange
                       inTextContainer:textContainer];
        NSPoint textOrigin = self.responseTextView.textContainerOrigin;
        markerRect.origin.x += textOrigin.x;
        markerRect.origin.y += textOrigin.y;
        CGFloat y = markerRect.origin.y +
            floor((markerRect.size.height - 20) / 2.0);
        NSButton *paste = self.commandButtons[index * 2];
        NSButton *run = self.commandButtons[index * 2 + 1];
        paste.frame = NSMakeRect(markerRect.origin.x, y, 58, 20);
        run.frame = NSMakeRect(markerRect.origin.x + 64, y, 62, 20);
    }
}

- (void)removeCommandButtons {
    for (NSButton *button in self.commandButtons) {
        [button removeFromSuperview];
    }
    self.commandButtons = @[];
    [self setNeedsLayout:YES];
}

- (void)commandSelected:(ClaudeCommandButton *)sender {
    NSString *command = sender.command;
    if (command.length > 0 &&
        [sender.actionKind isEqualToString:@"apply_patch"]) {
        [self.delegate claudeAssistantView:self
                     didRequestApplyPatch:command];
    } else if (command.length > 0 &&
               [sender.actionKind isEqualToString:@"copy_patch"]) {
        [NSPasteboard.generalPasteboard clearContents];
        [NSPasteboard.generalPasteboard writeObjects:@[command]];
    } else if (command.length > 0 &&
        [sender.actionKind isEqualToString:@"run"]) {
        [self.delegate claudeAssistantView:self
                     didRequestRunCommand:command];
    } else if (command.length > 0) {
        [self.delegate claudeAssistantView:self
                      didChooseRunCommand:command];
    }
}

- (void)submitFollowUp:(id)sender {
    (void)sender;
    NSString *prompt = [self.followUpField.string
        stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (prompt.length == 0 || !self.followUpField.editable) return;
    self.followUpField.string = @"";
    [self updateComposerPlaceholder];
    [self.delegate claudeAssistantView:self didSubmitFollowUp:prompt];
}

- (void)textDidChange:(NSNotification *)notification {
    if (notification.object == self.followUpField) {
        [self updateComposerPlaceholder];
    }
}

- (void)updateComposerPlaceholder {
    self.composerPlaceholder.hidden = self.followUpField.string.length > 0;
}

- (void)newConversationSelected:(id)sender {
    (void)sender;
    [self.delegate claudeAssistantViewDidRequestNewConversation:self];
}

- (void)settingsSelected:(id)sender {
    (void)sender;
    [self.delegate claudeAssistantViewDidRequestSettings:self];
}

@end
