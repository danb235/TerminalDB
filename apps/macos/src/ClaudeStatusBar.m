#import "ClaudeStatusBar.h"

#import "ClaudeProfile.h"
#import "TerminalTheme.h"

#import <math.h>

static NSTimeInterval const ClaudeUsageRefreshInterval = 5.0 * 60.0;
static NSTimeInterval const ClaudeAccountRefreshInterval = 5.0 * 60.0;

static double ClaudeUsageClampedPercent(double percent) {
    if (!isfinite(percent)) return 0;
    return MIN(100.0, MAX(0.0, percent));
}

@interface ClaudeStatusBar ()
@property(nonatomic, copy, nullable) NSString *claudeExecutable;
@property(nonatomic, strong) ClaudeProfileManager *profileManager;
@property(nonatomic, strong) TerminalTheme *theme;
@property(nonatomic, strong, readwrite, nullable) ClaudeProfile *selectedProfile;
@property(nonatomic, strong) NSTextField *profileLabel;
@property(nonatomic, strong) NSTextField *directoryLabel;
@property(nonatomic, strong) NSTextField *modelLabel;
@property(nonatomic, strong) NSTextField *environmentLabel;
@property(nonatomic, strong) NSTextField *usageLabel;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, strong, nullable) NSDate *lastAccountRefresh;
@property(nonatomic, strong, nullable) NSDate *lastUsageRefreshAttempt;
@property(nonatomic, copy, nullable) NSString *usageRefreshError;
@property(nonatomic) BOOL accountRefreshInFlight;
@property(nonatomic) BOOL usageRefreshInFlight;
@property(nonatomic, readwrite) BOOL accountIsLoggedIn;
@property(nonatomic, readwrite) BOOL accountStatusKnown;
@property(nonatomic, strong, readwrite, nullable) NSView *usagePanelView;
@property(nonatomic, strong, nullable) NSTextField *usageWindowAccountLabel;
@property(nonatomic, strong, nullable) NSTextField *usageWindowUsageLabel;
@property(nonatomic, strong, nullable) NSTextField *usageWindowAccountsLabel;
@property(nonatomic, strong, nullable) NSPopUpButton *usageWindowProfilePopup;
@property(nonatomic, strong, nullable) NSButton *usageWindowSignInButton;
@property(nonatomic, strong, nullable) NSButton *usageWindowRemoveButton;
+ (nullable NSNumber *)nextResetTimestamp:(nullable NSNumber *)timestamp
                                   period:(NSTimeInterval)period
                                   rolled:(BOOL *)rolled;
@end

@implementation ClaudeStatusBar

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
    self.wantsLayer = YES;
    self.layer.backgroundColor = theme.statusBarBackground.CGColor;

    _profileLabel = [NSTextField labelWithString:@""];
    _profileLabel.textColor = theme.statusBarActiveForeground;
    _profileLabel.font =
        [NSFont fontWithName:theme.fontName size:10.5]
            ?: [NSFont monospacedSystemFontOfSize:10.5
                                           weight:NSFontWeightRegular];
    _profileLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _profileLabel.maximumNumberOfLines = 1;
    _profileLabel.selectable = NO;
    [self addSubview:_profileLabel];

    _directoryLabel = [NSTextField labelWithString:@"~"];
    _directoryLabel.font = _profileLabel.font;
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
    _environmentLabel.font =
        [NSFont fontWithName:theme.fontName size:9.5]
            ?: [NSFont monospacedSystemFontOfSize:9.5
                                           weight:NSFontWeightSemibold];
    _environmentLabel.textColor = theme.ansiColors[6];
    _environmentLabel.alignment = NSTextAlignmentCenter;
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

    [self updateProfileLabel];
    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(profilesDidChange:)
               name:ClaudeProfilesDidChangeNotification
             object:profileManager];
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

- (void)mouseDown:(NSEvent *)event {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Claude Code Status"];
    NSMenuItem *heading =
        [[NSMenuItem alloc] initWithTitle:@"Claude Code — Status & Usage"
                                   action:nil
                            keyEquivalent:@""];
    heading.enabled = NO;
    [menu addItem:heading];
    NSMenuItem *openUsage =
        [[NSMenuItem alloc] initWithTitle:@"Open Account & Usage…"
                                   action:@selector(showUsageWindow:)
                            keyEquivalent:@""];
    openUsage.target = self;
    [menu addItem:openUsage];

    NSString *usage = self.usageLabel.stringValue;
    if (usage.length > 0) {
        NSMenuItem *usageItem =
            [[NSMenuItem alloc] initWithTitle:usage
                                       action:nil
                                keyEquivalent:@""];
        usageItem.enabled = NO;
        [menu addItem:usageItem];
    }
    [menu addItem:NSMenuItem.separatorItem];

    for (ClaudeProfile *profile in self.profileManager.profiles) {
        NSString *title = [self displayTitleForProfile:profile];
        NSMenuItem *item =
            [[NSMenuItem alloc] initWithTitle:title
                                       action:@selector(selectProfileFromStatusMenu:)
                                keyEquivalent:@""];
        item.target = self;
        item.representedObject = profile.identifier;
        item.state = [profile.identifier
            isEqualToString:self.selectedProfile.identifier]
                ? NSControlStateValueOn
                : NSControlStateValueOff;
        [menu addItem:item];
    }
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *add = [[NSMenuItem alloc]
        initWithTitle:@"Add Claude Code Account…"
               action:@selector(addProfileFromStatusMenu:)
        keyEquivalent:@""];
    add.target = self;
    [menu addItem:add];
    if (self.selectedProfile != nil &&
        self.accountStatusKnown &&
        !self.accountIsLoggedIn) {
        NSMenuItem *signIn = [[NSMenuItem alloc]
            initWithTitle:[NSString stringWithFormat:@"Sign In to %@…",
                self.selectedProfile.label]
                   action:@selector(signInFromStatusMenu:)
            keyEquivalent:@""];
        signIn.target = self;
        [menu addItem:signIn];
    }
    NSMenuItem *refresh = [[NSMenuItem alloc]
        initWithTitle:@"Refresh Usage"
               action:@selector(refreshFromStatusMenu:)
        keyEquivalent:@""];
    refresh.target = self;
    [menu addItem:refresh];
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *separation = [[NSMenuItem alloc]
        initWithTitle:@"API chat key and model are managed separately"
               action:nil
        keyEquivalent:@""];
    separation.enabled = NO;
    [menu addItem:separation];

    [menu popUpMenuPositioningItem:nil
                        atLocation:[self convertPoint:event.locationInWindow
                                            fromView:nil]
                            inView:self];
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
    if (self.usagePanelView == nil) {
        NSView *content = [[NSView alloc]
            initWithFrame:NSMakeRect(0, 0, 920, 570)];
        content.wantsLayer = YES;
        content.layer.backgroundColor =
            self.theme.terminalBackground.CGColor;

        NSTextField *eyebrow = [self
            usageWindowLabel:@"CLAUDE CODE · ACTIVE FOR THIS TAB"
                         size:10
                       weight:NSFontWeightSemibold
                        color:self.theme.ansiColors[6]
                        frame:NSMakeRect(28, 530, 860, 18)];
        [content addSubview:eyebrow];
        NSTextField *title = [self
            usageWindowLabel:@"Account & usage"
                         size:23
                       weight:NSFontWeightSemibold
                        color:self.theme.terminalForeground
                        frame:NSMakeRect(26, 492, 860, 32)];
        [content addSubview:title];
        NSTextField *subtitle = [self
            usageWindowLabel:
                @"Subscription usage is per Claude Code account. AI chat can "
                 "use this subscription or a separately managed API key."
                         size:12
                       weight:NSFontWeightRegular
                        color:self.theme.statusBarActiveForeground
                        frame:NSMakeRect(28, 458, 860, 34)];
        [content addSubview:subtitle];

        NSBox *accountBox =
            [[NSBox alloc] initWithFrame:NSMakeRect(28, 342, 864, 104)];
        accountBox.boxType = NSBoxCustom;
        accountBox.borderColor = self.theme.statusBarBorder;
        accountBox.fillColor = self.theme.statusBarBackground;
        accountBox.cornerRadius = 7;
        accountBox.titlePosition = NSNoTitle;
        [content addSubview:accountBox];
        self.usageWindowAccountLabel = [self
            usageWindowLabel:@""
                         size:14
                       weight:NSFontWeightSemibold
                        color:self.theme.terminalForeground
                        frame:NSMakeRect(18, 18, 550, 68)];
        [accountBox.contentView
            addSubview:self.usageWindowAccountLabel];
        self.usageWindowProfilePopup = [[NSPopUpButton alloc]
            initWithFrame:NSMakeRect(582, 56, 260, 28)
                pullsDown:NO];
        self.usageWindowProfilePopup.target = self;
        self.usageWindowProfilePopup.action =
            @selector(selectProfileFromUsageWindow:);
        [accountBox.contentView
            addSubview:self.usageWindowProfilePopup];
        self.usageWindowSignInButton =
            [NSButton buttonWithTitle:@"Sign In…"
                               target:self
                               action:@selector(signInFromStatusMenu:)];
        self.usageWindowSignInButton.frame =
            NSMakeRect(582, 16, 122, 30);
        [accountBox.contentView
            addSubview:self.usageWindowSignInButton];
        self.usageWindowRemoveButton =
            [NSButton buttonWithTitle:@"Remove…"
                               target:self
                               action:@selector(removeProfileFromUsageWindow:)];
        self.usageWindowRemoveButton.frame =
            NSMakeRect(712, 16, 130, 30);
        self.usageWindowRemoveButton.contentTintColor =
            self.theme.ansiColors[1];
        [accountBox.contentView
            addSubview:self.usageWindowRemoveButton];

        NSBox *usageBox =
            [[NSBox alloc] initWithFrame:NSMakeRect(28, 220, 864, 106)];
        usageBox.boxType = NSBoxCustom;
        usageBox.borderColor = self.theme.statusBarBorder;
        usageBox.fillColor = self.theme.statusBarBackground;
        usageBox.cornerRadius = 7;
        usageBox.titlePosition = NSNoTitle;
        [content addSubview:usageBox];
        self.usageWindowUsageLabel = [self
            usageWindowLabel:@""
                         size:13
                       weight:NSFontWeightMedium
                        color:self.theme.terminalForeground
                        frame:NSMakeRect(18, 16, 824, 72)];
        self.usageWindowUsageLabel.font =
            [NSFont fontWithName:self.theme.fontName size:12.5]
                ?: [NSFont monospacedSystemFontOfSize:12.5
                                               weight:NSFontWeightMedium];
        [usageBox.contentView addSubview:self.usageWindowUsageLabel];

        NSTextField *accountsTitle = [self
            usageWindowLabel:@"ALL ACCOUNTS · NO LIMIT · ONE ACTIVE PER TAB"
                         size:10
                       weight:NSFontWeightSemibold
                        color:self.theme.statusBarForeground
                        frame:NSMakeRect(30, 186, 860, 18)];
        [content addSubview:accountsTitle];
        self.usageWindowAccountsLabel = [self
            usageWindowLabel:@""
                         size:11.5
                       weight:NSFontWeightRegular
                        color:self.theme.statusBarActiveForeground
                        frame:NSMakeRect(30, 92, 860, 88)];
        self.usageWindowAccountsLabel.font =
            [NSFont fontWithName:self.theme.fontName size:11]
                ?: [NSFont monospacedSystemFontOfSize:11
                                               weight:NSFontWeightRegular];
        [content addSubview:self.usageWindowAccountsLabel];

        NSButton *refresh = [NSButton buttonWithTitle:@"Refresh Usage"
                                               target:self
                                               action:@selector(refreshUsageWindow:)];
        refresh.frame = NSMakeRect(28, 32, 130, 32);
        [content addSubview:refresh];
        NSButton *add = [NSButton buttonWithTitle:@"Add Account…"
                                           target:self
                                           action:@selector(addProfileFromStatusMenu:)];
        add.frame = NSMakeRect(166, 32, 130, 32);
        [content addSubview:add];
        NSButton *done = [NSButton buttonWithTitle:@"Done"
                                            target:self
                                            action:@selector(dismissUsagePanel:)];
        done.frame = NSMakeRect(800, 32, 92, 32);
        [content addSubview:done];
        self.usagePanelView = content;
    }
    [self refreshUsageWindowContents];
    return self.usagePanelView;
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

- (void)refreshUsageWindow:(id)sender {
    (void)sender;
    [self refreshNow];
    [self refreshUsageWindowContents];
    __weak typeof(self) weakSelf = self;
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            [weakSelf refreshUsageWindowContents];
        });
}

- (void)refreshUsageWindowContents {
    if (self.usagePanelView == nil) return;
    NSString *account = self.selectedProfile != nil
        ? [self displayTitleForProfile:self.selectedProfile]
        : @"●  No Claude Code account selected";
    NSString *state = !self.accountStatusKnown
        ? @"Checking sign-in state…"
        : (self.accountIsLoggedIn
            ? @"SIGNED IN · usage applies to this terminal tab"
            : @"SIGN IN REQUIRED · choose the account from the AI menu");
    self.usageWindowAccountLabel.stringValue =
        [NSString stringWithFormat:@"%@\n%@", account, state];
    self.usageWindowAccountLabel.textColor =
        self.accountIsLoggedIn
            ? self.theme.terminalForeground : self.theme.ansiColors[3];

    NSString *usage = self.usageLabel.stringValue.length > 0
        ? self.usageLabel.stringValue : @"Usage unavailable";
    NSString *resetDetails = self.usageLabel.toolTip.length > 0
        ? self.usageLabel.toolTip : @"Reset timestamps are not available.";
    self.usageWindowUsageLabel.stringValue = [NSString stringWithFormat:
        @"%@\n%@", usage, resetDetails];

    NSMutableArray<NSString *> *accounts = [NSMutableArray array];
    [self.usageWindowProfilePopup removeAllItems];
    for (ClaudeProfile *profile in self.profileManager.profiles) {
        BOOL selected = [profile.identifier
            isEqualToString:self.selectedProfile.identifier];
        [self.usageWindowProfilePopup
            addItemWithTitle:[self displayTitleForProfile:profile]];
        self.usageWindowProfilePopup.lastItem.representedObject =
            profile.identifier;
        [accounts addObject:[NSString stringWithFormat:@"%@  %@",
            selected ? @"✓" : @" ",
            [self displayTitleForProfile:profile]]];
    }
    if (self.selectedProfile != nil) {
        for (NSMenuItem *item in
                self.usageWindowProfilePopup.itemArray) {
            if ([item.representedObject
                    isEqualToString:self.selectedProfile.identifier]) {
                [self.usageWindowProfilePopup selectItem:item];
                break;
            }
        }
    }
    self.usageWindowProfilePopup.enabled =
        self.profileManager.profiles.count > 0;
    self.usageWindowRemoveButton.enabled = self.selectedProfile != nil;
    self.usageWindowSignInButton.hidden =
        self.selectedProfile == nil ||
        !self.accountStatusKnown ||
        self.accountIsLoggedIn;
    self.usageWindowAccountsLabel.stringValue = accounts.count > 0
        ? [accounts componentsJoinedByString:@"\n"]
        : @"No accounts yet. Add an account to track subscription usage.";
}

- (void)selectProfileFromUsageWindow:(NSPopUpButton *)sender {
    NSString *identifier =
        [sender.selectedItem.representedObject
            isKindOfClass:NSString.class]
            ? sender.selectedItem.representedObject
            : nil;
    ClaudeProfile *profile =
        [self.profileManager profileWithIdentifier:identifier];
    if (profile != nil) {
        [self selectProfile:profile];
        [self.delegate claudeStatusBar:self didSelectProfile:profile];
    }
}

- (void)removeProfileFromUsageWindow:(id)sender {
    (void)sender;
    [self.delegate claudeStatusBarDidRequestRemoveProfile:self];
}

- (void)selectProfileFromStatusMenu:(NSMenuItem *)sender {
    ClaudeProfile *profile =
        [self.profileManager profileWithIdentifier:sender.representedObject];
    if (profile == nil) return;
    [self selectProfile:profile];
    [self.delegate claudeStatusBar:self didSelectProfile:profile];
}

- (void)addProfileFromStatusMenu:(id)sender {
    (void)sender;
    [self.delegate claudeStatusBarDidRequestAddProfile:self];
}

- (void)signInFromStatusMenu:(id)sender {
    (void)sender;
    if (self.selectedProfile != nil) {
        [self.delegate claudeStatusBar:self
               didRequestLoginProfile:self.selectedProfile];
    }
}

- (void)refreshFromStatusMenu:(id)sender {
    (void)sender;
    [self refreshNow];
}

- (void)layout {
    [super layout];
    CGFloat inset = 10;
    CGFloat gap = 8;
    CGFloat availableWidth = MAX(0, NSWidth(self.bounds) - inset * 2);
    CGFloat environmentWidth = 52;
    CGFloat usageWidth = MIN(availableWidth * 0.42,
                             MAX(200,
                                 self.usageLabel.intrinsicContentSize.width +
                                     20));
    CGFloat profileWidth = MIN(availableWidth * 0.24,
                               MAX(116,
                                   self.profileLabel.intrinsicContentSize.width +
                                       14));
    CGFloat modelWidth = self.modelLabel.hidden
        ? 0
        : MIN(availableWidth * 0.20,
              MAX(86, self.modelLabel.intrinsicContentSize.width + 12));
    NSUInteger visibleGaps = self.modelLabel.hidden ? 3 : 4;
    CGFloat directoryWidth = MAX(
        0,
        availableWidth - profileWidth - modelWidth - environmentWidth -
            usageWidth - gap * visibleGaps);

    // The working directory is the primary piece of session identity. On a
    // narrow window, reclaim space from model/profile/usage before allowing it
    // to disappear completely.
    CGFloat directoryTarget = MIN(120, availableWidth * 0.25);
    CGFloat shortage = MAX(0, directoryTarget - directoryWidth);
    if (shortage > 0 && modelWidth > 70) {
        CGFloat recovered = MIN(shortage, modelWidth - 70);
        modelWidth -= recovered;
        directoryWidth += recovered;
        shortage -= recovered;
    }
    if (shortage > 0 && usageWidth > 150) {
        CGFloat recovered = MIN(shortage, usageWidth - 150);
        usageWidth -= recovered;
        directoryWidth += recovered;
        shortage -= recovered;
    }
    if (shortage > 0 && profileWidth > 92) {
        CGFloat recovered = MIN(shortage, profileWidth - 92);
        profileWidth -= recovered;
        directoryWidth += recovered;
    }

    CGFloat x = inset;
    self.profileLabel.frame =
        NSMakeRect(x, 4, profileWidth, NSHeight(self.bounds) - 8);
    x += profileWidth + gap;
    self.directoryLabel.frame =
        NSMakeRect(x, 4, directoryWidth, NSHeight(self.bounds) - 8);
    x += directoryWidth + gap;
    if (!self.modelLabel.hidden) {
        self.modelLabel.frame =
            NSMakeRect(x, 4, modelWidth, NSHeight(self.bounds) - 8);
        x += modelWidth + gap;
    } else {
        self.modelLabel.frame = NSZeroRect;
    }
    self.environmentLabel.frame =
        NSMakeRect(x, 4, environmentWidth, NSHeight(self.bounds) - 8);
    self.usageLabel.frame =
        NSMakeRect(NSWidth(self.bounds) - inset - usageWidth, 4,
                   usageWidth, NSHeight(self.bounds) - 8);
}

- (void)startMonitoring {
    [self refreshAccountIfNeeded:YES];
    [self refreshUsage];
    [self refreshUsageIfNeeded:YES];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:5.0
                                                  target:self
                                                selector:@selector(timerFired:)
                                                userInfo:nil
                                                 repeats:YES];
}

- (void)refreshNow {
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
    [self refreshUsageIfNeeded:YES];
}

- (void)showEnvironment:(NSString *)environment
                   host:(NSString *)host
                 detail:(NSString *)detail {
    NSString *value = environment.uppercaseString.length > 0
        ? environment.uppercaseString : @"LOCAL";
    self.environmentLabel.stringValue = value;
    if ([value isEqualToString:@"PRODUCTION"]) {
        self.environmentLabel.textColor = self.theme.ansiColors[1];
    } else if ([value isEqualToString:@"STAGING"] ||
               [value isEqualToString:@"REMOTE"]) {
        self.environmentLabel.textColor = self.theme.ansiColors[3];
    } else {
        self.environmentLabel.textColor = self.theme.ansiColors[6];
    }
    self.environmentLabel.toolTip = [NSString stringWithFormat:
        @"%@%@%@",
        value,
        host.length > 0 ? [@" · " stringByAppendingString:host] : @"",
        detail.length > 0 ? [@" · " stringByAppendingString:detail] : @""];
    [self.environmentLabel setAccessibilityLabel:
        [NSString stringWithFormat:@"%@ environment", value.capitalizedString]];
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
}

- (NSString *)displayTitleForProfile:(ClaudeProfile *)profile {
    NSString *identity = profile.email.length > 0
        ? profile.email
        : @"Not signed in";
    NSString *plan = profile.subscriptionType.length > 0
        ? profile.subscriptionType.capitalizedString
        : @"";
    return plan.length > 0
        ? [NSString stringWithFormat:@"●  %@ · %@ · %@",
            profile.label, identity, plan]
        : [NSString stringWithFormat:@"●  %@ · %@",
            profile.label, identity];
}

- (void)updateProfileLabel {
    if (self.selectedProfile == nil) {
        self.profileLabel.stringValue = @"●  No Claude account";
        self.profileLabel.toolTip =
            @"Choose an account from the Claude menu.";
        return;
    }
    self.profileLabel.stringValue =
        [self displayTitleForProfile:self.selectedProfile];
    self.profileLabel.toolTip = [NSString stringWithFormat:
        @"Active in this tab\nChange accounts from the Claude menu"];
}

- (NSDictionary<NSString *, NSString *> *)environmentForProfile:
    (ClaudeProfile *)profile {
    NSMutableDictionary *environment =
        [NSProcessInfo.processInfo.environment mutableCopy];
    environment[@"CLAUDE_CONFIG_DIR"] = profile.configDirectory;
    environment[@"CLAUDE_SECURESTORAGE_CONFIG_DIR"] =
        profile.configDirectory;
    environment[@"TERMINALDB_CLAUDE_STATUS_FILE"] =
        profile.statusLineCachePath;
    return environment;
}

- (void)refreshAccountIfNeeded:(BOOL)force {
    ClaudeProfile *profile = self.selectedProfile;
    if (profile == nil) return;
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
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
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
        self.profileLabel.toolTip = @"Claude account status unavailable";
        return;
    }
    self.accountStatusKnown = YES;
    self.accountIsLoggedIn = [status[@"loggedIn"] boolValue];
    if (!self.accountIsLoggedIn) {
        self.profileLabel.toolTip =
            @"Not signed in. Use the Claude menu to sign in.";
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
    [self refreshUsageIfNeeded:self.lastUsageRefreshAttempt == nil];
}

- (void)refreshUsage {
    ClaudeProfile *profile = self.selectedProfile;
    if (profile == nil) {
        self.usageLabel.stringValue = @"Usage  Select or add an account";
        self.usageLabel.textColor = self.theme.statusBarForeground;
        return;
    }

    NSDictionary *status = nil;
    NSDate *sourceModifiedAt = nil;
    for (NSString *candidate in
            @[profile.statusCachePath, profile.statusLineCachePath]) {
        NSData *candidateData = [NSData dataWithContentsOfFile:candidate];
        NSDictionary *candidateStatus = candidateData.length > 0
            ? [NSJSONSerialization JSONObjectWithData:candidateData
                                               options:0
                                                 error:nil]
            : nil;
        NSDictionary *candidateLimits =
            [candidateStatus[@"rate_limits"]
                isKindOfClass:NSDictionary.class]
                ? candidateStatus[@"rate_limits"]
                : nil;
        if ([candidateLimits[@"five_hour"] isKindOfClass:NSDictionary.class] ||
            [candidateLimits[@"seven_day"] isKindOfClass:NSDictionary.class]) {
            NSDate *modifiedAt =
                [NSFileManager.defaultManager
                    attributesOfItemAtPath:candidate error:nil]
                    [NSFileModificationDate];
            if (status == nil ||
                (modifiedAt != nil &&
                 (sourceModifiedAt == nil ||
                  [modifiedAt compare:sourceModifiedAt] ==
                      NSOrderedDescending))) {
                status = candidateStatus;
                sourceModifiedAt = modifiedAt;
            }
        }
    }
    if (status == nil) {
        self.usageLabel.stringValue = self.usageRefreshInFlight
            ? @"Usage  Refreshing…"
            : (self.accountIsLoggedIn
                ? @"Usage  Unavailable"
                : @"Usage  Sign in required");
        self.usageLabel.textColor = self.theme.statusBarForeground;
        self.usageLabel.toolTip = self.usageRefreshError.length > 0
            ? self.usageRefreshError
            : @"Current Claude Code usage is not available yet.";
        return;
    }

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
        self.usageLabel.stringValue = @"Usage  Waiting for Claude response";
        self.usageLabel.textColor = self.theme.statusBarForeground;
        return;
    }

    NSMutableAttributedString *styled = [[NSMutableAttributedString alloc] init];
    NSDictionary *muted = @{
        NSFontAttributeName : self.usageLabel.font,
        NSForegroundColorAttributeName : self.theme.statusBarActiveForeground,
    };
    BOOL sourceIsStale =
        sourceModifiedAt != nil &&
        -sourceModifiedAt.timeIntervalSinceNow >
            ClaudeUsageRefreshInterval * 2.0;
    [styled appendAttributedString:[[NSAttributedString alloc]
        initWithString:sourceIsStale ? @"Usage cached  " : @"Usage  "
            attributes:muted]];
    if (fivePercent != nil) {
        [styled appendAttributedString:
            [self usageWindowSegment:@"5h"
                             percent:fivePercent.doubleValue
                              window:fiveHour]];
    }
    if (weekPercent != nil) {
        if (fivePercent != nil) {
            [styled appendAttributedString:[[NSAttributedString alloc]
                initWithString:@" · " attributes:muted]];
        }
        [styled appendAttributedString:
            [self usageWindowSegment:@"7d"
                             percent:weekPercent.doubleValue
                              window:sevenDay]];
    }
    if (fablePercent != nil) {
        if (fivePercent != nil || weekPercent != nil) {
            [styled appendAttributedString:[[NSAttributedString alloc]
                initWithString:@" · " attributes:muted]];
        }
        [styled appendAttributedString:[self usageSegment:@"F"
                                                 percent:fablePercent.doubleValue]];
    }
    self.usageLabel.attributedStringValue = styled;
    [self setNeedsLayout:YES];

    NSMutableArray<NSString *> *details = [NSMutableArray array];
    [self appendResetDescription:@"5-hour" window:fiveHour to:details];
    [self appendResetDescription:@"7-day" window:sevenDay to:details];
    [self appendResetDescription:@"Fable 5 weekly"
                          window:fableWeekly
                              to:details];
    NSDate *updated = sourceModifiedAt;
    if (updated != nil) {
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        formatter.timeStyle = NSDateFormatterShortStyle;
        formatter.dateStyle = NSDateFormatterNoStyle;
        [details addObject:[NSString stringWithFormat:@"Updated %@",
            [formatter stringFromDate:updated]]];
        if (sourceIsStale) {
            [details addObject:
                @"Cached usage is stale; TerminalDB is requesting a refresh."];
        }
    }
    if (self.usageRefreshError.length > 0) {
        [details addObject:self.usageRefreshError];
    }
    [details addObject:@"Refreshes every 5 minutes"];
    self.usageLabel.toolTip = [details componentsJoinedByString:@"\n"];
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
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *temporaryPath = [NSTemporaryDirectory()
            stringByAppendingPathComponent:[NSString stringWithFormat:
                @"terminaldb-claude-usage-%@.json",
                NSUUID.UUID.UUIDString]];
        [[NSFileManager defaultManager]
            createFileAtPath:temporaryPath
                    contents:nil
                  attributes:@{NSFilePosixPermissions : @0600}];
        NSFileHandle *output =
            [NSFileHandle fileHandleForWritingAtPath:temporaryPath];

        NSTask *task = [[NSTask alloc] init];
        task.executableURL = [NSURL fileURLWithPath:executable];
        task.arguments = @[
            @"-p", @"/usage",
            @"--output-format", @"json",
            @"--max-turns", @"1",
        ];
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
            while (task.running &&
                   [deadline timeIntervalSinceNow] > 0) {
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
            ? [NSData dataWithContentsOfFile:temporaryPath]
            : nil;
        [[NSFileManager defaultManager] removeItemAtPath:temporaryPath
                                                  error:nil];
        NSDictionary *envelope = data.length > 0
            ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil]
            : nil;
        NSString *result =
            [envelope[@"result"] isKindOfClass:NSString.class]
                ? envelope[@"result"] : nil;
        NSDictionary *normalized =
            [ClaudeStatusBar normalizedStatusFromUsageCommandResult:result];
        BOOL wroteCache = NO;
        if (normalized != nil) {
            NSData *normalizedData =
                [NSJSONSerialization dataWithJSONObject:normalized
                                                 options:0
                                                   error:nil];
            wroteCache =
                [normalizedData writeToFile:statusCachePath atomically:YES];
            if (wroteCache) {
                [NSFileManager.defaultManager
                    setAttributes:@{NSFilePosixPermissions : @0600}
                    ofItemAtPath:statusCachePath
                    error:nil];
            }
        }

        NSString *refreshError = nil;
        if (launchError != nil || !launched) {
            refreshError = @"Claude Code could not be launched to refresh usage.";
        } else if (timedOut) {
            refreshError =
                @"Claude Code usage refresh timed out; showing cached usage.";
        } else if (task.terminationStatus != 0 || !wroteCache) {
            refreshError =
                @"Claude Code did not return current usage; showing cached usage.";
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            ClaudeStatusBar *strongSelf = weakSelf;
            if (strongSelf == nil ||
                ![strongSelf.selectedProfile.identifier
                    isEqualToString:profileID]) {
                return;
            }
            strongSelf.usageRefreshInFlight = NO;
            strongSelf.usageRefreshError = refreshError;
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
    NSRegularExpression *expression = [NSRegularExpression
        regularExpressionWithPattern:
            @"([0-9]+(?:\\.[0-9]+)?)%\\s+used\\s*(?:·|-)\\s*"
             "resets\\s+(.+?)\\s+\\(([^)]+)\\)\\s*$"
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

        NSTextCheckingResult *match =
            [expression firstMatchInString:line
                                   options:0
                                     range:NSMakeRange(0, line.length)];
        if (match.numberOfRanges < 4) continue;
        double percent =
            [[line substringWithRange:[match rangeAtIndex:1]] doubleValue];
        NSString *dateText =
            [line substringWithRange:[match rangeAtIndex:2]];
        NSString *timeZoneName =
            [line substringWithRange:[match rangeAtIndex:3]];
        NSMutableDictionary *window = [@{
            @"used_percentage" :
                @(ClaudeUsageClampedPercent(percent)),
        } mutableCopy];
        NSNumber *reset = [self
            timestampFromUsageCommandDate:dateText
                             timeZoneName:timeZoneName];
        if (reset != nil) window[@"resets_at"] = reset;
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
        [self compactResetDateTimeFromTimestamp:fiveHourReset].length > 0 &&
        [self compactResetDateTimeFromTimestamp:sevenDayReset].length > 0 &&
        [self compactResetDateTimeFromTimestamp:pastReset] == nil &&
        [self compactDateTimeFromTimestamp:pastReset].length > 0 &&
        rolled &&
        [nextReset doubleValue] > [NSDate date].timeIntervalSince1970 &&
        [clamped[@"rate_limits"][@"five_hour"][@"used_percentage"]
            isEqual:@100] &&
        [clamped[@"rate_limits"][@"seven_day"][@"used_percentage"]
            isEqual:@0];
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

- (NSAttributedString *)usageWindowSegment:(NSString *)label
                                   percent:(double)percent
                                    window:(NSDictionary *)window {
    NSMutableAttributedString *segment =
        [[self usageSegment:label percent:percent] mutableCopy];
    NSNumber *timestamp = [window[@"resets_at"] isKindOfClass:NSNumber.class]
        ? window[@"resets_at"]
        : nil;
    NSTimeInterval period = [label isEqualToString:@"5h"]
        ? 5.0 * 60.0 * 60.0
        : 7.0 * 24.0 * 60.0 * 60.0;
    BOOL rolled = NO;
    timestamp = [ClaudeStatusBar nextResetTimestamp:timestamp
                                             period:period
                                             rolled:&rolled];
    NSString *resetDateTime =
        [ClaudeStatusBar compactResetDateTimeFromTimestamp:timestamp] ?: @"—";
    [segment appendAttributedString:[[NSAttributedString alloc]
        initWithString:[NSString stringWithFormat:@" %@ %@",
            rolled ? @"≈" : @"↻", resetDateTime]
            attributes:@{
                NSFontAttributeName : self.usageLabel.font,
                NSForegroundColorAttributeName :
                    self.theme.statusBarActiveForeground,
            }]];
    return segment;
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
