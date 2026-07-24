#import "ClaudeAssistantView.h"

#import "TerminalTheme.h"

@interface ClaudeCommandButton : NSButton
@property(nonatomic, copy) NSString *command;
@end

@implementation ClaudeCommandButton
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
@property(nonatomic, strong) NSButton *closeButton;
@property(nonatomic, strong) NSButton *startConversationButton;
@property(nonatomic, strong) NSButton *settingsButton;
@property(nonatomic, strong) NSScrollView *responseScrollView;
@property(nonatomic, strong) NSTextView *responseTextView;
@property(nonatomic, strong) NSBox *composerBox;
@property(nonatomic, strong) NSScrollView *composerScrollView;
@property(nonatomic, strong) ClaudePromptTextView *followUpField;
@property(nonatomic, strong) NSTextField *composerPlaceholder;
@property(nonatomic, strong) NSTextField *contextLabel;
@property(nonatomic, strong) NSButton *sendButton;
@property(nonatomic, copy) NSArray<NSDictionary *> *conversationMessages;
@property(nonatomic, copy) NSString *response;
@property(nonatomic, copy) NSArray<NSButton *> *commandButtons;
@property(nonatomic) BOOL working;
@end

@implementation ClaudeAssistantView

- (instancetype)initWithFrame:(NSRect)frame theme:(TerminalTheme *)theme {
    self = [super initWithFrame:frame];
    if (self == nil) return nil;
    _theme = theme;
    _conversationMessages = @[];
    _response = @"";
    _commandButtons = @[];
    self.wantsLayer = YES;

    _titleLabel = [self labelWithFont:
        [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold]];
    _titleLabel.stringValue = @"AI Chat";
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

    _closeButton = [self headerButtonWithTitle:@""
                                       toolTip:@"Collapse AI chat"
                                         action:@selector(closeSelected:)];
    NSImage *hideSidebarImage =
        [NSImage imageWithSystemSymbolName:@"sidebar.right"
                  accessibilityDescription:@"Hide AI Chat"];
    hideSidebarImage = [hideSidebarImage imageWithSymbolConfiguration:
        [NSImageSymbolConfiguration configurationWithPointSize:14
                                                        weight:NSFontWeightMedium]];
    _closeButton.image = hideSidebarImage;
    _closeButton.imagePosition = NSImageOnly;
    [_closeButton setAccessibilityLabel:@"Hide AI Chat"];

    _startConversationButton =
        [self headerButtonWithTitle:@"New chat"
                           toolTip:@"Clear this tab’s AI context and start fresh"
                             action:@selector(newConversationSelected:)];
    _startConversationButton.font =
        [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];

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
        [theme.terminalBackground colorWithAlphaComponent:0.72];
    _composerBox.borderColor = theme.statusBarBorder;
    _composerBox.borderWidth = 1.0;
    _composerBox.cornerRadius = 10.0;
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

    _composerPlaceholder = [self labelWithFont:
        [NSFont systemFontOfSize:13 weight:NSFontWeightRegular]];
    _composerPlaceholder.stringValue =
        @"Ask about this terminal, plan, or build anything…";
    _composerPlaceholder.textColor = theme.statusBarForeground;
    _composerPlaceholder.lineBreakMode = NSLineBreakByTruncatingTail;
    [self addSubview:_composerPlaceholder];

    _contextLabel = [self labelWithFont:
        [NSFont systemFontOfSize:10 weight:NSFontWeightRegular]];
    _contextLabel.stringValue = @"⌁  Current terminal context attached";
    _contextLabel.textColor = theme.statusBarActiveForeground;
    _contextLabel.toolTip =
        @"Each message includes this tab’s current directory and visible "
         "terminal output.";
    [self addSubview:_contextLabel];

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
    [self.theme.statusBarBackground setFill];
    NSRectFill(self.bounds);
    [self.theme.statusBarBorder setFill];
    NSRectFill(NSMakeRect(0, 0, 1, self.bounds.size.height));
    NSRectFill(NSMakeRect(0, 51, self.bounds.size.width, 1));
}

- (void)layout {
    [super layout];
    const CGFloat padding = 14;
    const CGFloat headerHeight = 52;
    const CGFloat composerHeight = 112;
    CGFloat width = self.bounds.size.width;
    CGFloat height = self.bounds.size.height;

    self.titleLabel.frame = NSMakeRect(padding, 8, MAX(80, width - 190), 19);
    self.progress.frame = NSMakeRect(padding, 31, 14, 14);
    CGFloat statusX = self.working ? padding + 20 : padding;
    self.statusLabel.frame =
        NSMakeRect(statusX, 29, MAX(80, width - statusX - 14), 17);
    self.closeButton.frame = NSMakeRect(width - 38, 8, 26, 26);
    self.startConversationButton.frame =
        NSMakeRect(width - 116, 8, 76, 26);

    CGFloat commandHeight = 0;
    if (self.commandButtons.count > 0) {
        commandHeight = self.commandButtons.count * 36 + 4;
    }
    if (!self.settingsButton.hidden) commandHeight += 36;

    CGFloat composerY = height - padding - composerHeight;
    CGFloat commandsY = composerY - commandHeight - 8;
    self.responseScrollView.frame =
        NSMakeRect(padding,
                   headerHeight + 5,
                   MAX(40, width - padding * 2),
                   MAX(40, commandsY - headerHeight - 5));

    CGFloat buttonY = commandsY;
    for (NSButton *button in self.commandButtons) {
        button.frame =
            NSMakeRect(padding, buttonY, MAX(80, width - padding * 2), 30);
        buttonY += 36;
    }
    if (!self.settingsButton.hidden) {
        self.settingsButton.frame =
            NSMakeRect(padding, buttonY, MAX(80, width - padding * 2), 30);
    }

    self.composerBox.frame =
        NSMakeRect(padding, composerY, MAX(80, width - padding * 2),
                   composerHeight);
    self.composerScrollView.frame =
        NSMakeRect(padding + 10, composerY + 8,
                   MAX(40, width - padding * 2 - 20), 64);
    NSSize composerViewport = self.composerScrollView.contentSize;
    self.followUpField.frame =
        NSMakeRect(0, 0, composerViewport.width,
                   MAX(56, composerViewport.height));
    self.composerPlaceholder.frame =
        NSMakeRect(padding + 14, composerY + 12,
                   MAX(20, width - padding * 2 - 28), 20);
    self.contextLabel.frame =
        NSMakeRect(padding + 12, composerY + 82,
                   MAX(40, width - padding * 2 - 64), 16);
    self.sendButton.frame =
        NSMakeRect(width - padding - 40, composerY + 73, 30, 30);
}

- (void)beginWithModelName:(NSString *)modelName
                  messages:(NSArray<NSDictionary *> *)messages {
    self.conversationMessages = [messages copy] ?: @[];
    self.response = @"";
    self.statusLabel.stringValue =
        [NSString stringWithFormat:@"%@ · Working…", modelName];
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
    self.conversationMessages = @[];
    self.response = @"";
    self.statusLabel.stringValue =
        [NSString stringWithFormat:@"%@ · New chat", modelName];
    self.statusLabel.textColor = self.theme.statusBarActiveForeground;
    self.settingsButton.hidden = YES;
    self.followUpField.string = @"";
    self.followUpField.editable = YES;
    self.sendButton.enabled = YES;
    self.working = NO;
    [self.progress stopAnimation:nil];
    [self removeCommandButtons];
    [self updateComposerPlaceholder];
    [self renderResponse];
    [self setNeedsLayout:YES];
    [self focusComposer];
}

- (void)appendResponseText:(NSString *)text {
    if (text.length == 0) return;
    self.response = [self.response stringByAppendingString:text];
    self.statusLabel.stringValue = @"Claude · Streaming response…";
    [self renderResponse];
}

- (void)finish {
    [self.progress stopAnimation:nil];
    self.working = NO;
    self.statusLabel.stringValue = @"Claude · Ready";
    self.followUpField.editable = YES;
    self.sendButton.enabled = YES;
    [self installCommandButtons:
        [ClaudeAssistantView commandsFromMarkdown:self.response]];
    [self renderResponse];
    [self setNeedsLayout:YES];
    [self focusComposer];
}

- (void)showError:(NSString *)message
 settingsAvailable:(BOOL)settingsAvailable {
    [self.progress stopAnimation:nil];
    self.working = NO;
    self.response = message ?: @"Claude request failed.";
    self.statusLabel.stringValue = @"Claude · Request failed";
    self.statusLabel.textColor = self.theme.ansiColors[1];
    self.settingsButton.hidden = !settingsAvailable;
    self.followUpField.editable = YES;
    self.sendButton.enabled = YES;
    [self removeCommandButtons];
    [self renderResponse];
    [self setNeedsLayout:YES];
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

    __block BOOL inCode = NO;
    NSArray<NSString *> *lines =
        [content componentsSeparatedByString:@"\n"];
    for (NSUInteger index = 0; index < lines.count; index++) {
        NSString *line = lines[index];
        if ([line hasPrefix:@"```"]) {
            inCode = !inCode;
            continue;
        }
        NSString *output = line;
        if (!inCode) {
            output = [output stringByReplacingOccurrencesOfString:@"**"
                                                       withString:@""];
        }
        [rendered appendAttributedString:[[NSAttributedString alloc]
            initWithString:output attributes:inCode ? code : base]];
        if (index + 1 < lines.count) {
            [rendered appendAttributedString:[[NSAttributedString alloc]
                initWithString:@"\n" attributes:inCode ? code : base]];
        }
    }
}

- (void)renderResponse {
    NSMutableAttributedString *rendered =
        [[NSMutableAttributedString alloc] init];
    NSDictionary *separator = @{
        NSFontAttributeName : [NSFont systemFontOfSize:7],
    };
    for (NSDictionary *message in self.conversationMessages) {
        NSString *role = [message[@"role"] isKindOfClass:NSString.class]
            ? message[@"role"]
            : @"assistant";
        NSString *content =
            [message[@"content"] isKindOfClass:NSString.class]
                ? message[@"content"]
                : @"";
        if (content.length == 0) continue;
        if (rendered.length > 0) {
            [rendered appendAttributedString:[[NSAttributedString alloc]
                initWithString:@"\n\n" attributes:separator]];
        }
        [self appendContent:content role:role to:rendered];
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

- (void)installCommandButtons:(NSArray<NSString *> *)commands {
    [self removeCommandButtons];
    NSMutableArray<NSButton *> *buttons = [NSMutableArray array];
    for (NSUInteger index = 0; index < commands.count; index++) {
        ClaudeCommandButton *button =
            [[ClaudeCommandButton alloc] initWithFrame:NSZeroRect];
        button.title = commands.count == 1
            ? @"Paste command into terminal"
            : [NSString stringWithFormat:@"Paste command %lu into terminal",
                (unsigned long)index + 1];
        button.bezelStyle = NSBezelStyleRounded;
        button.controlSize = NSControlSizeSmall;
        button.alignment = NSTextAlignmentLeft;
        button.font =
            [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
        button.contentTintColor = self.theme.ansiColors[2];
        button.target = self;
        button.action = @selector(commandSelected:);
        button.command = commands[index];
        button.toolTip =
            @"Paste into the active terminal. Review it, then press Return.";
        [self addSubview:button];
        [buttons addObject:button];
    }
    self.commandButtons = buttons;
    [self setNeedsLayout:YES];
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
    if (command.length > 0) {
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

- (void)closeSelected:(id)sender {
    (void)sender;
    [self.delegate claudeAssistantViewDidRequestClose:self];
}

- (void)settingsSelected:(id)sender {
    (void)sender;
    [self.delegate claudeAssistantViewDidRequestSettings:self];
}

@end
