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
@property(nonatomic, strong) NSButton *settingsButton;
@property(nonatomic, strong) NSScrollView *responseScrollView;
@property(nonatomic, strong) NSTextView *responseTextView;
@property(nonatomic, copy) NSString *response;
@property(nonatomic, copy) NSArray<NSButton *> *commandButtons;
@end

@implementation ClaudeAssistantView

- (instancetype)initWithFrame:(NSRect)frame theme:(TerminalTheme *)theme {
    self = [super initWithFrame:frame];
    if (self == nil) return nil;
    _theme = theme;
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
        NSMakeRect(padding + 24, 10, self.bounds.size.width - 120, 20);
    self.closeButton.frame =
        NSMakeRect(self.bounds.size.width - 40, 7, 28, 26);
    self.statusLabel.frame =
        NSMakeRect(padding, 38, self.bounds.size.width - padding * 2, 18);

    CGFloat buttonHeight = self.commandButtons.count > 0 ||
        !self.settingsButton.hidden ? 38 : 0;
    CGFloat responseTop = headerHeight + 36;
    CGFloat responseBottom = padding + buttonHeight;
    self.responseScrollView.frame =
        NSMakeRect(padding,
                   responseTop,
                   self.bounds.size.width - padding * 2,
                   MAX(44, self.bounds.size.height -
                       responseTop - responseBottom));

    CGFloat x = padding;
    CGFloat y = self.bounds.size.height - padding - 28;
    for (NSButton *button in self.commandButtons) {
        button.frame = NSMakeRect(x, y, 124, 28);
        x += 132;
    }
    if (!self.settingsButton.hidden) {
        self.settingsButton.frame = NSMakeRect(x, y, 124, 28);
    }
}

- (void)beginWithModelName:(NSString *)modelName {
    self.response = @"";
    self.titleLabel.stringValue =
        [NSString stringWithFormat:@"Claude · %@", modelName];
    self.statusLabel.stringValue = @"Working…";
    self.statusLabel.textColor = self.theme.statusBarActiveForeground;
    self.settingsButton.hidden = YES;
    [self removeCommandButtons];
    [self.progress startAnimation:nil];
    [self renderResponse];
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
    [self installCommandButtons:
        [ClaudeAssistantView commandsFromMarkdown:self.response]];
    [self renderResponse];
}

- (void)showError:(NSString *)message
 settingsAvailable:(BOOL)settingsAvailable {
    [self.progress stopAnimation:nil];
    self.response = message ?: @"Claude request failed.";
    self.statusLabel.stringValue = @"Couldn’t complete the request";
    self.statusLabel.textColor = self.theme.ansiColors[1];
    self.settingsButton.hidden = !settingsAvailable;
    [self removeCommandButtons];
    [self renderResponse];
    [self setNeedsLayout:YES];
}

- (void)renderResponse {
    NSMutableAttributedString *rendered =
        [[NSMutableAttributedString alloc] init];
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

    __block BOOL inCode = NO;
    NSArray<NSString *> *lines =
        [self.response componentsSeparatedByString:@"\n"];
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

- (void)closeSelected:(id)sender {
    (void)sender;
    [self.delegate claudeAssistantViewDidRequestClose:self];
}

- (void)settingsSelected:(id)sender {
    (void)sender;
    [self.delegate claudeAssistantViewDidRequestSettings:self];
}

@end
