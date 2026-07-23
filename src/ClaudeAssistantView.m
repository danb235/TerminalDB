#import "ClaudeAssistantView.h"

#import "TerminalTheme.h"

@interface ClaudeCommandButton : NSButton
@property(nonatomic, copy) NSString *command;
@end

@implementation ClaudeCommandButton
@end

@interface ClaudeAssistantView ()
@property(nonatomic, strong) TerminalTheme *theme;
@property(nonatomic, strong) NSTextField *titleLabel;
@property(nonatomic, strong) NSTextField *statusLabel;
@property(nonatomic, strong) NSProgressIndicator *progress;
@property(nonatomic, strong) NSButton *closeButton;
@property(nonatomic, strong) NSButton *startConversationButton;
@property(nonatomic, strong) NSButton *settingsButton;
@property(nonatomic, strong) NSScrollView *responseScrollView;
@property(nonatomic, strong) NSTextView *responseTextView;
@property(nonatomic, strong) NSTextField *followUpField;
@property(nonatomic, strong) NSButton *sendButton;
@property(nonatomic, copy) NSArray<NSDictionary *> *conversationMessages;
@property(nonatomic, copy) NSString *response;
@property(nonatomic, copy) NSArray<NSButton *> *commandButtons;
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
        [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold]];
    _titleLabel.textColor = theme.terminalForeground;
    [self addSubview:_titleLabel];

    _statusLabel =
        [self labelWithFont:[NSFont systemFontOfSize:11]];
    _statusLabel.textColor = theme.statusBarActiveForeground;
    [self addSubview:_statusLabel];

    _progress = [[NSProgressIndicator alloc]
        initWithFrame:NSMakeRect(0, 0, 16, 16)];
    _progress.style = NSProgressIndicatorStyleSpinning;
    _progress.controlSize = NSControlSizeSmall;
    _progress.displayedWhenStopped = NO;
    [self addSubview:_progress];

    _closeButton = [[NSButton alloc] initWithFrame:NSZeroRect];
    _closeButton.title = @"×";
    _closeButton.bordered = NO;
    _closeButton.font = [NSFont systemFontOfSize:18
                                         weight:NSFontWeightRegular];
    _closeButton.contentTintColor = theme.statusBarActiveForeground;
    _closeButton.target = self;
    _closeButton.action = @selector(closeSelected:);
    _closeButton.toolTip = @"Dismiss";
    [self addSubview:_closeButton];

    _startConversationButton = [[NSButton alloc] initWithFrame:NSZeroRect];
    _startConversationButton.title = @"New conversation";
    _startConversationButton.bezelStyle = NSBezelStyleRounded;
    _startConversationButton.controlSize = NSControlSizeSmall;
    _startConversationButton.target = self;
    _startConversationButton.action = @selector(newConversationSelected:);
    _startConversationButton.toolTip =
        @"Clear this tab’s Claude context and start fresh.";
    [self addSubview:_startConversationButton];

    _settingsButton = [[NSButton alloc] initWithFrame:NSZeroRect];
    _settingsButton.title = @"Open Settings";
    _settingsButton.bezelStyle = NSBezelStyleRounded;
    _settingsButton.target = self;
    _settingsButton.action = @selector(settingsSelected:);
    _settingsButton.hidden = YES;
    [self addSubview:_settingsButton];

    _responseScrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _responseScrollView.hasVerticalScroller = YES;
    _responseScrollView.drawsBackground = NO;
    _responseScrollView.borderType = NSNoBorder;

    _responseTextView = [[NSTextView alloc] initWithFrame:NSZeroRect];
    _responseTextView.editable = NO;
    _responseTextView.selectable = YES;
    _responseTextView.drawsBackground = NO;
    _responseTextView.textContainerInset = NSMakeSize(4, 4);
    _responseTextView.textContainer.widthTracksTextView = YES;
    _responseTextView.horizontallyResizable = NO;
    _responseTextView.verticallyResizable = YES;
    _responseTextView.autoresizingMask = NSViewWidthSizable;
    _responseScrollView.documentView = _responseTextView;
    [self addSubview:_responseScrollView];

    _followUpField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    _followUpField.placeholderString =
        @"Ask a follow-up or refine the command…";
    _followUpField.font =
        [NSFont systemFontOfSize:12 weight:NSFontWeightRegular];
    _followUpField.target = self;
    _followUpField.action = @selector(submitFollowUp:);
    _followUpField.toolTip =
        @"This message continues the conversation in this terminal tab.";
    [self addSubview:_followUpField];

    _sendButton = [[NSButton alloc] initWithFrame:NSZeroRect];
    _sendButton.title = @"Send";
    _sendButton.bezelStyle = NSBezelStyleRounded;
    _sendButton.keyEquivalent = @"\r";
    _sendButton.target = self;
    _sendButton.action = @selector(submitFollowUp:);
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

- (BOOL)isFlipped {
    return YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSBezierPath *background =
        [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 0.5, 0.5)
                                       xRadius:12
                                       yRadius:12];
    [[self.theme.statusBarBackground colorWithAlphaComponent:0.97] setFill];
    [background fill];
    [self.theme.statusBarBorder setStroke];
    background.lineWidth = 1.0;
    [background stroke];
}

- (void)layout {
    [super layout];
    const CGFloat padding = 16;
    const CGFloat headerHeight = 24;
    self.progress.frame = NSMakeRect(padding, 13, 16, 16);
    self.titleLabel.frame =
        NSMakeRect(padding + 24, 10, self.bounds.size.width - 250, 20);
    self.startConversationButton.frame =
        NSMakeRect(self.bounds.size.width - 194, 7, 146, 26);
    self.closeButton.frame =
        NSMakeRect(self.bounds.size.width - 40, 7, 28, 26);
    self.statusLabel.frame =
        NSMakeRect(padding, 38, self.bounds.size.width - padding * 2, 18);

    CGFloat commandRowHeight = self.commandButtons.count > 0 ||
        !self.settingsButton.hidden ? 36 : 0;
    CGFloat composerHeight = 34;
    CGFloat responseTop = headerHeight + 36;
    CGFloat responseBottom =
        padding + composerHeight + commandRowHeight + 6;
    self.responseScrollView.frame =
        NSMakeRect(padding,
                   responseTop,
                   self.bounds.size.width - padding * 2,
                   MAX(44, self.bounds.size.height -
                       responseTop - responseBottom));

    CGFloat composerY = self.bounds.size.height - padding - 28;
    CGFloat sendWidth = 74;
    self.sendButton.frame =
        NSMakeRect(self.bounds.size.width - padding - sendWidth,
                   composerY,
                   sendWidth,
                   28);
    self.followUpField.frame =
        NSMakeRect(padding,
                   composerY,
                   self.bounds.size.width - padding * 3 - sendWidth,
                   28);

    CGFloat x = padding;
    CGFloat y = composerY - commandRowHeight;
    for (NSButton *button in self.commandButtons) {
        button.frame = NSMakeRect(x, y, 124, 28);
        x += 132;
    }
    if (!self.settingsButton.hidden) {
        self.settingsButton.frame = NSMakeRect(x, y, 124, 28);
    }
}

- (void)beginWithModelName:(NSString *)modelName
                  messages:(NSArray<NSDictionary *> *)messages {
    self.conversationMessages = [messages copy] ?: @[];
    self.response = @"";
    self.titleLabel.stringValue =
        [NSString stringWithFormat:@"Claude · %@", modelName];
    self.statusLabel.stringValue = @"Working…";
    self.statusLabel.textColor = self.theme.statusBarActiveForeground;
    self.settingsButton.hidden = YES;
    self.followUpField.enabled = NO;
    self.sendButton.enabled = NO;
    [self removeCommandButtons];
    [self.progress startAnimation:nil];
    [self renderResponse];
}

- (void)resetConversationWithModelName:(NSString *)modelName {
    self.conversationMessages = @[];
    self.response = @"";
    self.titleLabel.stringValue =
        [NSString stringWithFormat:@"Claude · %@", modelName];
    self.statusLabel.stringValue = @"New conversation";
    self.statusLabel.textColor = self.theme.statusBarActiveForeground;
    self.settingsButton.hidden = YES;
    self.followUpField.stringValue = @"";
    self.followUpField.enabled = YES;
    self.sendButton.enabled = YES;
    [self.progress stopAnimation:nil];
    [self removeCommandButtons];
    [self renderResponse];
    [self setNeedsLayout:YES];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.window makeFirstResponder:self.followUpField];
    });
}

- (void)appendResponseText:(NSString *)text {
    if (text.length == 0) return;
    self.response = [self.response stringByAppendingString:text];
    self.statusLabel.stringValue = @"Streaming response…";
    [self renderResponse];
}

- (void)finish {
    [self.progress stopAnimation:nil];
    self.statusLabel.stringValue = @"Review any command before running it.";
    self.followUpField.enabled = YES;
    self.sendButton.enabled = YES;
    [self installCommandButtons:
        [ClaudeAssistantView commandsFromMarkdown:self.response]];
    [self renderResponse];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.window makeFirstResponder:self.followUpField];
    });
}

- (void)showError:(NSString *)message
 settingsAvailable:(BOOL)settingsAvailable {
    [self.progress stopAnimation:nil];
    self.response = message ?: @"Claude request failed.";
    self.statusLabel.stringValue = @"Couldn’t complete the request";
    self.statusLabel.textColor = self.theme.ansiColors[1];
    self.settingsButton.hidden = !settingsAvailable;
    self.followUpField.enabled = YES;
    self.sendButton.enabled = YES;
    [self removeCommandButtons];
    [self renderResponse];
    [self setNeedsLayout:YES];
}

- (void)appendContent:(NSString *)content
                 role:(NSString *)role
                   to:(NSMutableAttributedString *)rendered {
    NSDictionary *base = @{
        NSFontAttributeName :
            [NSFont systemFontOfSize:13 weight:NSFontWeightRegular],
        NSForegroundColorAttributeName : self.theme.terminalForeground,
    };
    NSDictionary *code = @{
        NSFontAttributeName :
            [NSFont fontWithName:self.theme.fontName size:12.5] ?:
                [NSFont monospacedSystemFontOfSize:12.5
                                            weight:NSFontWeightRegular],
        NSForegroundColorAttributeName : self.theme.ansiColors[6],
        NSBackgroundColorAttributeName :
            [self.theme.terminalBackground colorWithAlphaComponent:0.9],
    };
    BOOL assistant = [role isEqualToString:@"assistant"];
    NSDictionary *heading = @{
        NSFontAttributeName :
            [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName :
            assistant ? self.theme.ansiColors[2] : self.theme.ansiColors[6],
    };
    [rendered appendAttributedString:[[NSAttributedString alloc]
        initWithString:assistant ? @"Claude\n" : @"You\n"
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
        NSFontAttributeName : [NSFont systemFontOfSize:6],
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
        NSDictionary *empty = @{
            NSFontAttributeName :
                [NSFont systemFontOfSize:13 weight:NSFontWeightRegular],
            NSForegroundColorAttributeName :
                self.theme.statusBarActiveForeground,
        };
        [rendered appendAttributedString:[[NSAttributedString alloc]
            initWithString:
                @"Ask Claude to help inspect the system, explain a command, "
                 "or refine a command before you run it."
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
            ? @"Run command"
            : [NSString stringWithFormat:@"Run command %lu",
                (unsigned long)index + 1];
        button.bezelStyle = NSBezelStyleRounded;
        button.target = self;
        button.action = @selector(commandSelected:);
        button.command = commands[index];
        button.toolTip =
            @"Insert this command at the prompt. Press Return to execute it.";
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
    NSString *prompt = [self.followUpField.stringValue
        stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (prompt.length == 0 || !self.followUpField.enabled) return;
    self.followUpField.stringValue = @"";
    [self.delegate claudeAssistantView:self didSubmitFollowUp:prompt];
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
