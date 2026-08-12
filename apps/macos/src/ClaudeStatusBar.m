#import "ClaudeStatusBar.h"

#import "ClaudeProfile.h"
#import "TerminalTheme.h"

#import <math.h>

static NSTimeInterval const ClaudeUsageRefreshInterval = 5.0 * 60.0;
static NSTimeInterval const ClaudeUsageFreshnessInterval = 10.0 * 60.0;
static NSTimeInterval const ClaudeAccountRefreshInterval = 5.0 * 60.0;

static dispatch_queue_t ClaudeUsageRefreshQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create(
            "com.terminaldb.app.claude-usage-refresh",
            DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}
static NSTimeInterval const ClaudeUsageForecastMinimumSpan = 15.0 * 60.0;
static NSTimeInterval const ClaudeUsageForecastLookback = 60.0 * 60.0;
static NSTimeInterval const ClaudeUsageHistoryRetention =
    8.0 * 24.0 * 60.0 * 60.0;
static NSUInteger const ClaudeUsageForecastMinimumSamples = 3;

static double ClaudeUsageClampedPercent(double percent) {
    if (!isfinite(percent)) return 0;
    return MIN(100.0, MAX(0.0, percent));
}

static BOOL ClaudeUsageViewContainsText(NSView *view, NSString *text) {
    NSString *value = nil;
    if ([view isKindOfClass:NSTextField.class]) {
        value = [(NSTextField *)view stringValue];
    } else if ([view isKindOfClass:NSButton.class]) {
        value = [(NSButton *)view title];
    }
    if ([value rangeOfString:text].location != NSNotFound) return YES;
    for (NSView *subview in view.subviews) {
        if (ClaudeUsageViewContainsText(subview, text)) return YES;
    }
    return NO;
}

static BOOL ClaudeUsageViewContainsNestedScrollView(NSView *view) {
    for (NSView *subview in view.subviews) {
        if ([subview isKindOfClass:NSScrollView.class] ||
            ClaudeUsageViewContainsNestedScrollView(subview)) {
            return YES;
        }
    }
    return NO;
}

@interface ClaudeStatusBar (UsagePanelLayout)
- (void)usagePanelDidResize;
@end

@interface ClaudeUsageDocumentView : NSView
@property(nonatomic, weak) ClaudeStatusBar *statusBar;
@end

@implementation ClaudeUsageDocumentView
- (BOOL)isFlipped { return YES; }
- (void)layout {
    [super layout];
    [self.statusBar usagePanelDidResize];
}
- (void)setFrameSize:(NSSize)newSize {
    for (NSView *subview in self.subviews) {
        if ([subview.identifier isEqualToString:@"TerminalDBUsageColumn"]) {
            newSize.width = MAX(newSize.width, NSWidth(subview.frame) + 48);
            break;
        }
    }
    [super setFrameSize:newSize];
    for (NSView *subview in self.subviews) {
        if (![subview.identifier isEqualToString:@"TerminalDBUsageColumn"]) {
            continue;
        }
        NSRect frame = subview.frame;
        frame.origin.x = floor((newSize.width - NSWidth(frame)) / 2.0);
        subview.frame = frame;
    }
}
@end

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
@property(nonatomic, strong, nullable) NSDate *lastUsageDashboardRefreshAttempt;
@property(nonatomic, copy, nullable) NSString *usageRefreshError;
@property(nonatomic) BOOL accountRefreshInFlight;
@property(nonatomic) BOOL usageRefreshInFlight;
@property(nonatomic, readwrite) BOOL accountIsLoggedIn;
@property(nonatomic, readwrite) BOOL accountStatusKnown;
@property(nonatomic, copy) NSArray<NSDictionary *> *currentUsageForecasts;
@property(nonatomic, strong, readwrite, nullable) NSView *usagePanelView;
@property(nonatomic, strong, nullable) ClaudeUsageDocumentView *usageWindowDocumentView;
@property(nonatomic) BOOL usageDashboardRefreshInFlight;
@property(nonatomic, copy) NSDictionary<NSString *, NSDictionary *> *usageDashboardResults;
@property(nonatomic) CGFloat usageDashboardViewportWidth;
@property(nonatomic) BOOL usageDashboardResizeScheduled;
+ (nullable NSNumber *)nextResetTimestamp:(nullable NSNumber *)timestamp
                                   period:(NSTimeInterval)period
                                   rolled:(BOOL *)rolled;
+ (nullable NSDictionary *)usageForecastForSamples:(NSArray *)samples
                                         windowKey:(NSString *)windowKey
                                     currentWindow:(NSDictionary *)currentWindow
                                               now:(NSTimeInterval)now;
+ (NSString *)compactDurationFromSeconds:(NSTimeInterval)seconds;
- (void)recordUsageSampleForStatus:(NSDictionary *)status
                  sourceModifiedAt:(nullable NSDate *)sourceModifiedAt
                           profile:(ClaudeProfile *)profile;
- (NSArray<NSDictionary *> *)usageHistoryForProfile:(ClaudeProfile *)profile;
- (NSArray<NSDictionary *> *)forecastsForStatus:(NSDictionary *)status
                                        history:(NSArray *)history
                                            now:(NSTimeInterval)now;
- (nullable NSDictionary *)usageStatusForProfile:(ClaudeProfile *)profile
                                 sourceModifiedAt:(NSDate *_Nullable *_Nullable)sourceModifiedAt;
- (NSDictionary *)usageDashboardEntryForProfile:(ClaudeProfile *)profile;
+ (nullable NSString *)refreshUsageCacheWithExecutable:(NSString *)executable
                                            environment:(NSDictionary *)environment
                                         statusCachePath:(NSString *)statusCachePath;
+ (NSDictionary *)accountRefreshResultWithExecutable:(NSString *)executable
                                          environment:(NSDictionary *)environment;
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
    _currentUsageForecasts = @[];
    _usageDashboardResults = @{};
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
    self.toolTip = @"Open Claude accounts and usage";
    [self setAccessibilityElement:YES];
    [self setAccessibilityRole:NSAccessibilityButtonRole];
    [self setAccessibilityLabel:@"Open Claude accounts and usage"];

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
    (void)event;
    [self showUsageWindow:nil];
}

- (nullable NSView *)hitTest:(NSPoint)point {
    return NSPointInRect(point, self.bounds) ? self : nil;
}

- (BOOL)accessibilityPerformPress {
    [self showUsageWindow:nil];
    return YES;
}

- (void)resetCursorRects {
    [super resetCursorRects];
    [self addCursorRect:self.bounds cursor:NSCursor.pointingHandCursor];
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
        ClaudeUsageDocumentView *content = [[ClaudeUsageDocumentView alloc]
            initWithFrame:NSMakeRect(0, 0, 920, 620)];
        content.statusBar = self;
        content.wantsLayer = YES;
        content.layer.backgroundColor =
            self.theme.terminalBackground.CGColor;
        content.autoresizingMask = NSViewWidthSizable;
        self.usageWindowDocumentView = content;
        self.usagePanelView = content;
    }
    [self refreshUsageWindowContents];
    return self.usagePanelView;
}

- (void)usagePanelDidResize {
    if (self.usagePanelView == nil || self.usageDashboardResizeScheduled) return;
    CGFloat width = NSWidth(self.usagePanelView.bounds);
    if (width <= 0 || fabs(width - self.usageDashboardViewportWidth) < 2.0) {
        return;
    }
    self.usageDashboardResizeScheduled = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        ClaudeStatusBar *strongSelf = weakSelf;
        if (strongSelf == nil) return;
        strongSelf.usageDashboardResizeScheduled = NO;
        [strongSelf refreshUsageWindowContents];
    });
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

- (void)refreshUsageDashboard {
    [self refreshUsageWindow:nil];
}

- (void)refreshUsageWindow:(id)sender {
    (void)sender;
    if (self.usageDashboardRefreshInFlight ||
        self.claudeExecutable.length == 0) {
        [self refreshUsageWindowContents];
        return;
    }
    NSArray<ClaudeProfile *> *profiles =
        [self.profileManager.profiles copy];
    if (profiles.count == 0) return;
    self.usageDashboardRefreshInFlight = YES;
    [self refreshUsageWindowContents];
    NSString *executable = self.claudeExecutable;
    NSMutableArray<NSDictionary *> *requests = [NSMutableArray array];
    for (ClaudeProfile *profile in profiles) {
        [requests addObject:@{
            @"profile" : profile,
            @"environment" : [self environmentForProfile:profile],
        }];
    }
    __weak typeof(self) weakSelf = self;
    dispatch_async(ClaudeUsageRefreshQueue(), ^{
        NSMutableDictionary<NSString *, NSDictionary *> *results =
            [NSMutableDictionary dictionary];
        for (NSDictionary *request in requests) {
            ClaudeProfile *profile = request[@"profile"];
            NSDictionary *environment = request[@"environment"];
            NSMutableDictionary *result = [[ClaudeStatusBar
                accountRefreshResultWithExecutable:executable
                                       environment:environment] mutableCopy];
            NSString *state = result[@"account_state"];
            if (![state isEqualToString:@"signed_out"]) {
                NSString *refreshError = [ClaudeStatusBar
                    refreshUsageCacheWithExecutable:executable
                                         environment:environment
                                      statusCachePath:profile.statusCachePath];
                if (refreshError.length > 0) {
                    result[@"refresh_error"] = refreshError;
                } else {
                    result[@"account_state"] = @"signed_in";
                    [result removeObjectForKey:@"status_error"];
                }
            }
            results[profile.identifier] = [result copy];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            ClaudeStatusBar *strongSelf = weakSelf;
            if (strongSelf == nil) return;
            strongSelf.usageDashboardRefreshInFlight = NO;
            strongSelf.usageDashboardResults = [results copy];
            NSString *selectedIdentifier =
                strongSelf.selectedProfile.identifier;
            NSDictionary *selectedResult = selectedIdentifier.length > 0
                ? strongSelf.usageDashboardResults[selectedIdentifier] : nil;
            NSString *selectedState = selectedResult[@"account_state"];
            if ([selectedState isEqualToString:@"signed_out"]) {
                strongSelf.accountStatusKnown = YES;
                strongSelf.accountIsLoggedIn = NO;
                strongSelf.usageRefreshError = @"Sign in to refresh this account’s usage.";
            } else if ([selectedState isEqualToString:@"signed_in"]) {
                strongSelf.accountStatusKnown = YES;
                strongSelf.accountIsLoggedIn = YES;
                strongSelf.usageRefreshError = selectedResult[@"refresh_error"];
            } else if (selectedResult != nil) {
                strongSelf.accountStatusKnown = NO;
                strongSelf.accountIsLoggedIn = NO;
                strongSelf.usageRefreshError = selectedResult[@"status_error"]
                    ?: selectedResult[@"refresh_error"];
            }
            [strongSelf refreshUsage];
            [strongSelf refreshUsageWindowContents];
        });
    });
}

- (void)refreshUsageWindowContents {
    ClaudeUsageDocumentView *document = self.usageWindowDocumentView;
    if (document == nil) return;
    for (NSView *subview in [document.subviews copy]) {
        [subview removeFromSuperview];
    }

    NSArray<ClaudeProfile *> *profiles = self.profileManager.profiles;
    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    NSDictionary *mostUrgent = nil;
    ClaudeProfile *urgentProfile = nil;
    for (ClaudeProfile *profile in profiles) {
        NSDictionary *entry = [self usageDashboardEntryForProfile:profile];
        [entries addObject:entry];
        for (NSDictionary *forecast in entry[@"forecasts"]) {
            if (![forecast[@"warning"] boolValue] ||
                [forecast[@"stale"] boolValue]) {
                continue;
            }
            if (mostUrgent == nil ||
                [forecast[@"eta_seconds"] doubleValue] <
                    [mostUrgent[@"eta_seconds"] doubleValue]) {
                mostUrgent = forecast;
                urgentProfile = profile;
            }
        }
    }

    CGFloat viewportWidth = MAX(800, NSWidth(document.bounds));
    self.usageDashboardViewportWidth = NSWidth(document.bounds);
    CGFloat columnWidth = MIN(1040, viewportWidth - 48);
    CGFloat columnX = floor((viewportWidth - columnWidth) / 2.0);
    CGFloat y = 34;
    NSTextField *eyebrow = [self
        usageWindowLabel:@"CLAUDE CODE SUBSCRIPTIONS"
                    size:10
                   weight:NSFontWeightSemibold
                    color:self.theme.ansiColors[6]
                    frame:NSMakeRect(columnX, y, columnWidth, 18)];
    eyebrow.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin;
    [document addSubview:eyebrow];
    y += 26;
    NSTextField *title = [self
        usageWindowLabel:@"Accounts & usage"
                    size:26
                   weight:NSFontWeightSemibold
                    color:self.theme.terminalForeground
                    frame:NSMakeRect(columnX, y, columnWidth, 34)];
    title.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin;
    [document addSubview:title];
    y += 40;
    NSTextField *subtitle = [self
        usageWindowLabel:
            @"Burn is the recent percentage of an allowance used per hour. "
             "Available pace is what remains divided by time until reset. "
             "TerminalDB warns only when current burn may reach a limit first."
                     size:12
                   weight:NSFontWeightRegular
                    color:self.theme.statusBarActiveForeground
                    frame:NSMakeRect(columnX, y, columnWidth, 38)];
    subtitle.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin;
    [document addSubview:subtitle];
    y += 48;

    NSString *configured = profiles.count == 1
        ? @"1 subscription configured"
        : [NSString stringWithFormat:@"%lu subscriptions configured",
            (unsigned long)profiles.count];
    NSTextField *summary = [self
        usageWindowLabel:[NSString stringWithFormat:
            @"%@ · one account can be active per terminal tab · metrics stay on this Mac",
            configured]
                    size:10.5
                   weight:NSFontWeightMedium
                    color:self.theme.statusBarActiveForeground
                    frame:NSMakeRect(columnX, y, columnWidth, 18)];
    summary.font = [NSFont fontWithName:self.theme.fontName size:10.5]
        ?: [NSFont monospacedSystemFontOfSize:10.5
                                       weight:NSFontWeightMedium];
    summary.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin;
    [document addSubview:summary];
    y += 30;

    if (mostUrgent != nil) {
        BOOL critical =
            [mostUrgent[@"severity"] isEqualToString:@"critical"];
        NSView *warning = [[NSView alloc]
            initWithFrame:NSMakeRect(columnX, y, columnWidth, 58)];
        warning.wantsLayer = YES;
        warning.layer.cornerRadius = 7;
        warning.layer.borderWidth = 1;
        warning.layer.borderColor = (critical
            ? self.theme.ansiColors[1] : self.theme.ansiColors[3]).CGColor;
        warning.layer.backgroundColor =
            self.theme.statusBarBackground.CGColor;
        warning.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin;
        NSTimeInterval eta = [mostUrgent[@"eta_seconds"] doubleValue];
        NSString *detail = eta <= 1.0
            ? [NSString stringWithFormat:@"%@ has reached its %@ allowance.",
                urgentProfile.label, mostUrgent[@"label"]]
            : [NSString stringWithFormat:
                @"%@ may reach its %@ allowance in %@ at the current burn rate.",
                urgentProfile.label, mostUrgent[@"label"],
                [ClaudeStatusBar compactDurationFromSeconds:eta]];
        NSTextField *warningLabel = [self
            usageWindowLabel:[@"⚠  " stringByAppendingString:detail]
                         size:12.5
                       weight:NSFontWeightSemibold
                        color:critical
                            ? self.theme.ansiColors[1]
                            : self.theme.ansiColors[3]
                        frame:NSMakeRect(18, 18, columnWidth - 36, 24)];
        warningLabel.selectable = NO;
        [warning addSubview:warningLabel];
        [document addSubview:warning];
        y += 72;
    }

    if (entries.count == 0) {
        NSView *empty = [[NSView alloc]
            initWithFrame:NSMakeRect(columnX, y, columnWidth, 150)];
        empty.wantsLayer = YES;
        empty.layer.cornerRadius = 8;
        empty.layer.borderWidth = 1;
        empty.layer.borderColor = self.theme.statusBarBorder.CGColor;
        empty.layer.backgroundColor = self.theme.statusBarBackground.CGColor;
        empty.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin;
        NSTextField *emptyTitle = [self
            usageWindowLabel:@"No Claude Code subscriptions yet"
                         size:17
                       weight:NSFontWeightSemibold
                        color:self.theme.terminalForeground
                        frame:NSMakeRect(22, 88, columnWidth - 44, 26)];
        NSTextField *emptyDetail = [self
            usageWindowLabel:
                @"Add an account to switch Claude subscriptions by terminal tab and track each allowance here."
                         size:12
                       weight:NSFontWeightRegular
                        color:self.theme.statusBarActiveForeground
                        frame:NSMakeRect(22, 43, columnWidth - 44, 38)];
        [empty addSubview:emptyTitle];
        [empty addSubview:emptyDetail];
        [document addSubview:empty];
        y += 164;
    }

    for (NSDictionary *entry in entries) {
        ClaudeProfile *profile = entry[@"profile"];
        NSArray<NSDictionary *> *forecasts = entry[@"forecasts"];
        BOOL signedOut = [entry[@"account_state"]
            isEqualToString:@"signed_out"];
        BOOL sourceStale = [entry[@"source_stale"] boolValue];
        NSString *refreshError = [entry[@"refresh_error"]
            isKindOfClass:NSString.class] ? entry[@"refresh_error"] : nil;
        NSString *statusError = [entry[@"status_error"]
            isKindOfClass:NSString.class] ? entry[@"status_error"] : nil;
        BOOL statusUnavailable = [entry[@"account_state"]
            isEqualToString:@"unknown"] && statusError.length > 0;
        BOOL active = [profile.identifier
            isEqualToString:self.selectedProfile.identifier];
        NSView *card = [[NSView alloc]
            initWithFrame:NSMakeRect(columnX, y, columnWidth, 204)];
        card.wantsLayer = YES;
        card.layer.cornerRadius = 8;
        card.layer.borderWidth = active ? 1.5 : 1;
        card.layer.borderColor = (active
            ? self.theme.ansiColors[6] : self.theme.statusBarBorder).CGColor;
        card.layer.backgroundColor = self.theme.statusBarBackground.CGColor;
        card.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin;

        NSString *plan = profile.subscriptionType.length > 0
            ? profile.subscriptionType.capitalizedString : @"Plan unknown";
        NSTextField *accountTitle = [self
            usageWindowLabel:profile.label
                         size:16
                       weight:NSFontWeightSemibold
                        color:self.theme.terminalForeground
                        frame:NSMakeRect(20, 164, columnWidth - 206, 24)];
        accountTitle.selectable = NO;
        [card addSubview:accountTitle];
        NSString *identity = profile.email.length > 0
            ? [NSString stringWithFormat:@"%@ · %@%@", profile.email, plan,
                signedOut ? @" · Sign-in required" : @""]
            : @"Not signed in";
        NSTextField *accountDetail = [self
            usageWindowLabel:identity
                         size:11.5
                       weight:NSFontWeightRegular
                        color:profile.email.length > 0 && !signedOut
                            ? self.theme.statusBarActiveForeground
                            : self.theme.ansiColors[3]
                        frame:NSMakeRect(20, 142, columnWidth - 206, 20)];
        accountDetail.selectable = NO;
        [card addSubview:accountDetail];

        NSDate *modifiedAt = [entry[@"modified_at"]
            isKindOfClass:NSDate.class] ? entry[@"modified_at"] : nil;
        NSString *freshness = statusUnavailable
            ? @"Account status unavailable · cached usage hidden"
            : (signedOut
            ? @"Signed out · cached usage hidden"
            : @"No usage snapshot yet");
        if (modifiedAt != nil && !statusUnavailable) {
            NSTimeInterval age = MAX(0, -modifiedAt.timeIntervalSinceNow);
            NSString *ageText = age < 60
                ? @"just now"
                : (age < 3600
                    ? [NSString stringWithFormat:@"%lum ago",
                        (unsigned long)floor(age / 60.0)]
                    : [NSString stringWithFormat:@"%luh ago",
                        (unsigned long)floor(age / 3600.0)]);
            if (signedOut) {
                freshness = [NSString stringWithFormat:
                    @"Signed out · %@ snapshot hidden", ageText];
            } else if (sourceStale) {
                freshness = [NSString stringWithFormat:
                    @"Last updated %@ · stale snapshot hidden", ageText];
            } else {
                freshness = refreshError.length > 0
                    ? [NSString stringWithFormat:
                        @"Updated %@ · refresh failed — %@", ageText,
                        refreshError]
                    : [NSString stringWithFormat:@"Updated %@", ageText];
            }
        }
        NSTextField *freshnessLabel = [self
            usageWindowLabel:freshness
                         size:10
                       weight:NSFontWeightMedium
                        color:self.theme.statusBarActiveForeground
                        frame:NSMakeRect(20, 118, columnWidth - 206, 18)];
        freshnessLabel.font = [NSFont fontWithName:self.theme.fontName size:10]
            ?: [NSFont monospacedSystemFontOfSize:10
                                           weight:NSFontWeightMedium];
        freshnessLabel.selectable = NO;
        [card addSubview:freshnessLabel];

        BOOL requiresSignIn = signedOut || profile.email.length == 0;
        NSButton *use = [NSButton
            buttonWithTitle:requiresSignIn ? @"Sign In…"
                : (active ? @"Active on This Tab" : @"Use on This Tab")
                     target:self
                     action:requiresSignIn
                        ? @selector(signInProfileFromUsageCard:)
                        : @selector(selectProfileFromUsageCard:)];
        use.frame = NSMakeRect(columnWidth - 166, 158, 146, 30);
        use.identifier = profile.identifier;
        use.enabled = requiresSignIn || !active;
        [card addSubview:use];
        NSButton *remove = [NSButton buttonWithTitle:@"Remove…"
                                              target:self
                                              action:@selector(removeProfileFromUsageCard:)];
        remove.frame = NSMakeRect(columnWidth - 166, 120, 146, 28);
        remove.identifier = profile.identifier;
        remove.contentTintColor = self.theme.ansiColors[1];
        [card addSubview:remove];

        if (forecasts.count == 0) {
            NSString *unavailableText = nil;
            if (signedOut) {
                unavailableText =
                    @"Usage unavailable while this account is signed out. Sign in to refresh its allowances.";
            } else if (sourceStale) {
                unavailableText = refreshError.length > 0
                    ? [NSString stringWithFormat:
                        @"Usage snapshot is too old to trust. %@", refreshError]
                    : @"Usage snapshot is too old to trust. Refresh this account to update its allowances.";
            } else if (refreshError.length > 0) {
                unavailableText = refreshError;
            } else if (statusError.length > 0) {
                unavailableText = statusError;
            } else {
                unavailableText =
                    @"Usage unavailable. Sign in or refresh after Claude Code reports the account’s allowances.";
            }
            NSTextField *unavailable = [self
                usageWindowLabel:unavailableText
                             size:11.5
                           weight:NSFontWeightRegular
                            color:(signedOut || sourceStale || refreshError.length > 0)
                                ? self.theme.ansiColors[3]
                                : self.theme.statusBarActiveForeground
                            frame:NSMakeRect(20, 35, columnWidth - 40, 58)];
            [card addSubview:unavailable];
        } else {
            NSBox *divider = [[NSBox alloc]
                initWithFrame:NSMakeRect(20, 107, columnWidth - 40, 1)];
            divider.boxType = NSBoxSeparator;
            [card addSubview:divider];
            NSArray<NSDictionary *> *columns = @[
                @{@"title" : @"ALLOWANCE", @"x" : @20, @"width" : @84},
                @{@"title" : @"USED", @"x" : @112, @"width" : @72},
                @{@"title" : @"BURN", @"x" : @198, @"width" : @102},
                @{@"title" : @"AVAILABLE PACE", @"x" : @310, @"width" : @124},
                @{@"title" : @"RESET", @"x" : @444, @"width" : @176},
                @{@"title" : @"FORECAST", @"x" : @632,
                  @"width" : @(MAX(100, columnWidth - 652))},
            ];
            for (NSDictionary *column in columns) {
                NSTextField *label = [self
                    usageWindowLabel:column[@"title"]
                                 size:9
                               weight:NSFontWeightSemibold
                                color:self.theme.statusBarActiveForeground
                                frame:NSMakeRect([column[@"x"] doubleValue], 87,
                                    [column[@"width"] doubleValue], 16)];
                label.font = [NSFont fontWithName:self.theme.fontName size:9]
                    ?: [NSFont monospacedSystemFontOfSize:9
                                                   weight:NSFontWeightSemibold];
                label.selectable = NO;
                [card addSubview:label];
            }
            for (NSUInteger index = 0; index < forecasts.count; index++) {
                NSDictionary *forecast = forecasts[index];
                CGFloat rowY = 62 - index * 25;
                double percent = [forecast[@"percent"] doubleValue];
                NSColor *percentColor = percent >= 80
                    ? self.theme.ansiColors[1]
                    : (percent >= 50
                        ? self.theme.ansiColors[3]
                        : self.theme.ansiColors[2]);
                NSString *burn = @"Collecting";
                NSString *available = @"—";
                if ([forecast[@"stale"] boolValue]) {
                    burn = @"Stale";
                } else if ([forecast[@"ready"] boolValue]) {
                    burn = [NSString stringWithFormat:@"+%.1f%%/hr",
                        [forecast[@"rate_per_hour"] doubleValue]];
                    if ([forecast[@"sustainable_rate_per_hour"]
                            isKindOfClass:NSNumber.class]) {
                        available = [NSString stringWithFormat:@"+%.1f%%/hr",
                            [forecast[@"sustainable_rate_per_hour"] doubleValue]];
                    }
                }
                NSString *reset = [ClaudeStatusBar
                    compactResetDateTimeFromTimestamp:forecast[@"reset_at"]]
                        ?: @"Unknown";
                NSString *risk = @"—";
                NSColor *riskColor = self.theme.statusBarActiveForeground;
                if ([forecast[@"warning"] boolValue] &&
                    ![forecast[@"stale"] boolValue]) {
                    NSTimeInterval eta = [forecast[@"eta_seconds"] doubleValue];
                    risk = eta <= 1.0 ? @"⚠ Reached"
                        : [NSString stringWithFormat:@"⚠ ~%@ left",
                            [ClaudeStatusBar compactDurationFromSeconds:eta]];
                    riskColor = [forecast[@"severity"] isEqualToString:@"critical"]
                        ? self.theme.ansiColors[1] : self.theme.ansiColors[3];
                }
                NSArray<NSDictionary *> *cells = @[
                    @{@"text" : forecast[@"detail_label"],
                      @"x" : @20, @"width" : @84,
                      @"color" : self.theme.terminalForeground},
                    @{@"text" : [NSString stringWithFormat:@"%.0f%%", percent],
                      @"x" : @112, @"width" : @72, @"color" : percentColor},
                    @{@"text" : burn, @"x" : @198, @"width" : @102,
                      @"color" : self.theme.terminalForeground},
                    @{@"text" : available, @"x" : @310, @"width" : @124,
                      @"color" : self.theme.terminalForeground},
                    @{@"text" : reset, @"x" : @444, @"width" : @176,
                      @"color" : self.theme.terminalForeground},
                    @{@"text" : risk, @"x" : @632,
                      @"width" : @(MAX(100, columnWidth - 652)),
                      @"color" : riskColor},
                ];
                for (NSDictionary *cell in cells) {
                    NSTextField *label = [self
                        usageWindowLabel:cell[@"text"]
                                     size:10.5
                                   weight:NSFontWeightMedium
                                    color:cell[@"color"]
                                    frame:NSMakeRect([cell[@"x"] doubleValue],
                                        rowY, [cell[@"width"] doubleValue], 18)];
                    label.font = [NSFont fontWithName:self.theme.fontName size:10.5]
                        ?: [NSFont monospacedSystemFontOfSize:10.5
                                                       weight:NSFontWeightMedium];
                    label.lineBreakMode = NSLineBreakByTruncatingTail;
                    label.maximumNumberOfLines = 1;
                    [card addSubview:label];
                }
            }
        }
        [document addSubview:card];
        y += 218;
    }

    NSButton *refresh = [NSButton
        buttonWithTitle:self.usageDashboardRefreshInFlight
            ? @"Refreshing All…" : @"Refresh All Usage"
                 target:self
                 action:@selector(refreshUsageWindow:)];
    refresh.frame = NSMakeRect(columnX, y, 150, 32);
    refresh.enabled = !self.usageDashboardRefreshInFlight &&
        profiles.count > 0 && self.claudeExecutable.length > 0;
    refresh.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin;
    [document addSubview:refresh];
    NSButton *add = [NSButton buttonWithTitle:@"Add Account…"
                                       target:self
                                       action:@selector(addProfileFromStatusMenu:)];
    add.frame = NSMakeRect(columnX + 160, y, 132, 32);
    add.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin;
    [document addSubview:add];
    NSButton *done = [NSButton buttonWithTitle:@"Done"
                                        target:self
                                        action:@selector(dismissUsagePanel:)];
    done.frame = NSMakeRect(columnX + columnWidth - 92, y, 92, 32);
    done.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin;
    [document addSubview:done];
    y += 58;
    NSArray<NSView *> *columnSubviews = [document.subviews copy];
    ClaudeUsageDocumentView *column = [[ClaudeUsageDocumentView alloc]
        initWithFrame:NSMakeRect(columnX, 0, columnWidth, y)];
    column.identifier = @"TerminalDBUsageColumn";
    column.autoresizingMask = NSViewNotSizable;
    for (NSView *subview in columnSubviews) {
        NSRect frame = subview.frame;
        frame.origin.x -= columnX;
        subview.frame = frame;
        [subview removeFromSuperview];
        [column addSubview:subview];
    }
    [document addSubview:column];
    document.frame = NSMakeRect(0, 0, viewportWidth, y);
}

- (void)selectProfileFromUsageCard:(NSButton *)sender {
    NSString *identifier = sender.identifier;
    ClaudeProfile *profile =
        [self.profileManager profileWithIdentifier:identifier];
    if (profile != nil) {
        [self selectProfile:profile];
        [self.delegate claudeStatusBar:self didSelectProfile:profile];
    }
}

- (void)signInProfileFromUsageCard:(NSButton *)sender {
    ClaudeProfile *profile =
        [self.profileManager profileWithIdentifier:sender.identifier];
    if (profile != nil) {
        [self.delegate claudeStatusBar:self didRequestLoginProfile:profile];
    }
}

- (void)removeProfileFromUsageCard:(NSButton *)sender {
    ClaudeProfile *profile =
        [self.profileManager profileWithIdentifier:sender.identifier];
    if (profile != nil) {
        [self.delegate claudeStatusBar:self didRequestRemoveProfile:profile];
    }
}

- (void)addProfileFromStatusMenu:(id)sender {
    (void)sender;
    [self.delegate claudeStatusBarDidRequestAddProfile:self];
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
    [self refreshUsageWindowContents];
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
    [self refreshUsageWindowContents];
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
    dispatch_async(ClaudeUsageRefreshQueue(), ^{
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
        NSMutableDictionary *results =
            [self.usageDashboardResults mutableCopy];
        results[profile.identifier] = @{
            @"account_state" : @"unknown",
            @"status_error" : @"Claude account status is unavailable.",
        };
        self.usageDashboardResults = results;
        self.profileLabel.toolTip = @"Claude account status unavailable";
        [self refreshUsage];
        [self refreshUsageWindowContents];
        return;
    }
    self.accountStatusKnown = YES;
    self.accountIsLoggedIn = [status[@"loggedIn"] boolValue];
    NSMutableDictionary *results =
        [self.usageDashboardResults mutableCopy];
    results[profile.identifier] = @{
        @"account_state" : self.accountIsLoggedIn
            ? @"signed_in" : @"signed_out",
    };
    self.usageDashboardResults = results;
    if (!self.accountIsLoggedIn) {
        self.profileLabel.toolTip =
            @"Not signed in. Use the Claude menu to sign in.";
        [self refreshUsage];
        [self refreshUsageWindowContents];
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
    [self refreshUsageWindowContents];
    [self refreshUsageIfNeeded:self.lastUsageRefreshAttempt == nil];
}

- (NSArray<NSDictionary *> *)usageHistoryForProfile:(ClaudeProfile *)profile {
    NSData *data = [NSData dataWithContentsOfFile:profile.usageHistoryPath];
    NSDictionary *document = data.length > 0
        ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil]
        : nil;
    NSArray *samples = [document[@"samples"] isKindOfClass:NSArray.class]
        ? document[@"samples"] : @[];
    NSMutableArray<NSDictionary *> *valid = [NSMutableArray array];
    for (id sample in samples) {
        if ([sample isKindOfClass:NSDictionary.class] &&
            [sample[@"recorded_at"] isKindOfClass:NSNumber.class] &&
            [sample[@"rate_limits"] isKindOfClass:NSDictionary.class]) {
            [valid addObject:sample];
        }
    }
    return valid;
}

- (void)recordUsageSampleForStatus:(NSDictionary *)status
                  sourceModifiedAt:(NSDate *)sourceModifiedAt
                           profile:(ClaudeProfile *)profile {
    NSDictionary *limits = [status[@"rate_limits"]
        isKindOfClass:NSDictionary.class] ? status[@"rate_limits"] : nil;
    if (limits == nil) return;

    NSMutableDictionary *recordedLimits = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"five_hour", @"seven_day", @"fable_five"]) {
        NSDictionary *window = [limits[key] isKindOfClass:NSDictionary.class]
            ? limits[key] : nil;
        NSNumber *percent = [window[@"used_percentage"]
            isKindOfClass:NSNumber.class] ? window[@"used_percentage"] : nil;
        if (percent == nil) continue;
        NSMutableDictionary *recordedWindow = [@{
            @"used_percentage" :
                @(ClaudeUsageClampedPercent(percent.doubleValue)),
        } mutableCopy];
        NSNumber *reset = [window[@"resets_at"] isKindOfClass:NSNumber.class]
            ? window[@"resets_at"] : nil;
        if (reset != nil) recordedWindow[@"resets_at"] = reset;
        recordedLimits[key] = recordedWindow;
    }
    if (recordedLimits.count == 0) return;

    NSDictionary *metadata = [status[@"terminaldb"]
        isKindOfClass:NSDictionary.class] ? status[@"terminaldb"] : nil;
    NSNumber *fetchedAt = [metadata[@"fetched_at"] isKindOfClass:NSNumber.class]
        ? metadata[@"fetched_at"] : nil;
    NSTimeInterval recordedAt = fetchedAt != nil
        ? fetchedAt.doubleValue
        : (sourceModifiedAt != nil
            ? sourceModifiedAt.timeIntervalSince1970
            : NSDate.date.timeIntervalSince1970);
    if (!isfinite(recordedAt) || recordedAt <= 0) return;

    NSDictionary *sample = @{
        @"recorded_at" : @(recordedAt),
        @"rate_limits" : recordedLimits,
    };
    NSTimeInterval cutoff = NSDate.date.timeIntervalSince1970 -
        ClaudeUsageHistoryRetention;
    NSMutableArray<NSDictionary *> *samples = [NSMutableArray array];
    for (NSDictionary *existing in [self usageHistoryForProfile:profile]) {
        NSNumber *timestamp = existing[@"recorded_at"];
        if (timestamp.doubleValue >= cutoff) [samples addObject:existing];
    }
    [samples sortUsingComparator:^NSComparisonResult(
        NSDictionary *left, NSDictionary *right) {
        return [left[@"recorded_at"] compare:right[@"recorded_at"]];
    }];
    NSDictionary *last = samples.lastObject;
    NSTimeInterval lastTime = [last[@"recorded_at"] doubleValue];
    if (last != nil && fabs(lastTime - recordedAt) < 1.0) {
        if ([last[@"rate_limits"] isEqual:recordedLimits]) return;
        [samples removeLastObject];
    }
    [samples addObject:sample];
    if (samples.count > 4096) {
        [samples removeObjectsInRange:
            NSMakeRange(0, samples.count - 4096)];
    }
    NSData *historyData = [NSJSONSerialization dataWithJSONObject:@{
        @"version" : @1,
        @"samples" : samples,
    } options:0 error:nil];
    if ([historyData writeToFile:profile.usageHistoryPath atomically:YES]) {
        [NSFileManager.defaultManager
            setAttributes:@{NSFilePosixPermissions : @0600}
            ofItemAtPath:profile.usageHistoryPath
            error:nil];
    }
}

+ (NSDictionary *)usageForecastForSamples:(NSArray *)samples
                                 windowKey:(NSString *)windowKey
                             currentWindow:(NSDictionary *)currentWindow
                                       now:(NSTimeInterval)now {
    NSNumber *currentValue = [currentWindow[@"used_percentage"]
        isKindOfClass:NSNumber.class]
        ? currentWindow[@"used_percentage"] : nil;
    if (currentValue == nil) return nil;
    double currentPercent =
        ClaudeUsageClampedPercent(currentValue.doubleValue);
    NSNumber *resetValue = [currentWindow[@"resets_at"]
        isKindOfClass:NSNumber.class] ? currentWindow[@"resets_at"] : nil;
    double currentReset = resetValue.doubleValue;

    NSMutableDictionary *result = [@{
        @"key" : windowKey,
        @"percent" : @(currentPercent),
        @"ready" : @NO,
        @"warning" : @NO,
        @"stale" : @NO,
    } mutableCopy];
    if (resetValue != nil) result[@"reset_at"] = resetValue;

    NSMutableArray<NSDictionary *> *points = [NSMutableArray array];
    for (NSDictionary *sample in samples) {
        NSNumber *timestamp = [sample[@"recorded_at"]
            isKindOfClass:NSNumber.class] ? sample[@"recorded_at"] : nil;
        NSDictionary *limits = [sample[@"rate_limits"]
            isKindOfClass:NSDictionary.class] ? sample[@"rate_limits"] : nil;
        NSDictionary *window = [limits[windowKey]
            isKindOfClass:NSDictionary.class] ? limits[windowKey] : nil;
        NSNumber *percent = [window[@"used_percentage"]
            isKindOfClass:NSNumber.class] ? window[@"used_percentage"] : nil;
        if (timestamp == nil || percent == nil ||
            timestamp.doubleValue < now - ClaudeUsageForecastLookback ||
            timestamp.doubleValue > now + 60.0) {
            continue;
        }
        NSNumber *sampleReset = [window[@"resets_at"]
            isKindOfClass:NSNumber.class] ? window[@"resets_at"] : nil;
        if (resetValue != nil &&
            (sampleReset == nil ||
             fabs(sampleReset.doubleValue - currentReset) > 120.0)) {
            continue;
        }
        [points addObject:@{
            @"time" : timestamp,
            @"percent" :
                @(ClaudeUsageClampedPercent(percent.doubleValue)),
        }];
    }
    [points sortUsingComparator:^NSComparisonResult(
        NSDictionary *left, NSDictionary *right) {
        return [left[@"time"] compare:right[@"time"]];
    }];

    NSUInteger cycleStart = 0;
    for (NSUInteger index = 1; index < points.count; index++) {
        if ([points[index][@"percent"] doubleValue] + 0.5 <
            [points[index - 1][@"percent"] doubleValue]) {
            cycleStart = index;
        }
    }
    if (cycleStart > 0) {
        [points removeObjectsInRange:NSMakeRange(0, cycleStart)];
    }
    if (points.count == 0) return result;

    NSTimeInterval latestTime = [points.lastObject[@"time"] doubleValue];
    result[@"sample_count"] = @(points.count);
    result[@"sample_span"] = @(
        latestTime - [points.firstObject[@"time"] doubleValue]);
    if (now - latestTime > ClaudeUsageRefreshInterval * 2.0) {
        result[@"stale"] = @YES;
        return result;
    }
    if (currentPercent >= 100.0) {
        result[@"ready"] = @YES;
        result[@"warning"] = @YES;
        result[@"severity"] = @"critical";
        result[@"eta_seconds"] = @0;
        result[@"projected_at"] = @(now);
        return result;
    }
    NSTimeInterval span = [result[@"sample_span"] doubleValue];
    if (points.count < ClaudeUsageForecastMinimumSamples ||
        span < ClaudeUsageForecastMinimumSpan) {
        return result;
    }

    double meanTime = 0;
    double meanPercent = 0;
    NSTimeInterval origin = [points.firstObject[@"time"] doubleValue];
    for (NSDictionary *point in points) {
        meanTime += ([point[@"time"] doubleValue] - origin) / 3600.0;
        meanPercent += [point[@"percent"] doubleValue];
    }
    meanTime /= points.count;
    meanPercent /= points.count;
    double covariance = 0;
    double variance = 0;
    for (NSDictionary *point in points) {
        double x = ([point[@"time"] doubleValue] - origin) / 3600.0;
        double y = [point[@"percent"] doubleValue];
        covariance += (x - meanTime) * (y - meanPercent);
        variance += (x - meanTime) * (x - meanTime);
    }
    double rate = variance > 0 ? covariance / variance : 0;
    double movement = [points.lastObject[@"percent"] doubleValue] -
        [points.firstObject[@"percent"] doubleValue];
    if (!isfinite(rate) || rate < 0 || movement < 0.5) rate = 0;
    result[@"ready"] = @YES;
    result[@"rate_per_hour"] = @(rate);

    double remaining = MAX(0, 100.0 - currentPercent);
    if (resetValue != nil && currentReset > now) {
        double hoursToReset = (currentReset - now) / 3600.0;
        double sustainableRate = hoursToReset > 0
            ? remaining / hoursToReset : 0;
        result[@"sustainable_rate_per_hour"] = @(sustainableRate);
        if (rate > 0) {
            NSTimeInterval eta = remaining / rate * 3600.0;
            NSTimeInterval projectedAt = now + eta;
            result[@"eta_seconds"] = @(eta);
            result[@"projected_at"] = @(projectedAt);
            if (sustainableRate > 0) {
                result[@"pace_multiple"] = @(rate / sustainableRate);
            }
            BOOL warning = projectedAt < currentReset - 60.0;
            result[@"warning"] = @(warning);
            if (warning) {
                result[@"severity"] = eta <= 30.0 * 60.0
                    ? @"critical" : @"warning";
            }
        }
    }
    return result;
}

- (NSArray<NSDictionary *> *)forecastsForStatus:(NSDictionary *)status
                                        history:(NSArray *)history
                                            now:(NSTimeInterval)now {
    NSDictionary *limits = [status[@"rate_limits"]
        isKindOfClass:NSDictionary.class] ? status[@"rate_limits"] : @{};
    NSArray<NSDictionary *> *definitions = @[
        @{@"key" : @"five_hour", @"label" : @"5h",
          @"detail_label" : @"5-HOUR"},
        @{@"key" : @"seven_day", @"label" : @"7d",
          @"detail_label" : @"7-DAY"},
        @{@"key" : @"fable_five", @"label" : @"Fable",
          @"detail_label" : @"FABLE"},
    ];
    NSMutableArray<NSDictionary *> *forecasts = [NSMutableArray array];
    for (NSDictionary *definition in definitions) {
        NSDictionary *window = [limits[definition[@"key"]]
            isKindOfClass:NSDictionary.class]
            ? limits[definition[@"key"]] : nil;
        if (window == nil) continue;
        NSDictionary *forecast = [ClaudeStatusBar
            usageForecastForSamples:history
                           windowKey:definition[@"key"]
                       currentWindow:window
                                 now:now];
        if (forecast == nil) continue;
        NSMutableDictionary *decorated = [forecast mutableCopy];
        decorated[@"label"] = definition[@"label"];
        decorated[@"detail_label"] = definition[@"detail_label"];
        [forecasts addObject:decorated];
    }
    return forecasts;
}

- (nullable NSDictionary *)usageStatusForProfile:(ClaudeProfile *)profile
                                 sourceModifiedAt:(NSDate **)sourceModifiedAt {
    NSDictionary *status = nil;
    NSDate *latestModifiedAt = nil;
    for (NSString *candidate in
            @[profile.statusCachePath, profile.statusLineCachePath]) {
        NSData *candidateData = [NSData dataWithContentsOfFile:candidate];
        NSDictionary *candidateStatus = candidateData.length > 0
            ? [NSJSONSerialization JSONObjectWithData:candidateData
                                               options:0
                                                 error:nil]
            : nil;
        NSDictionary *candidateLimits =
            [candidateStatus[@"rate_limits"] isKindOfClass:NSDictionary.class]
                ? candidateStatus[@"rate_limits"] : nil;
        if (![candidateLimits[@"five_hour"]
                isKindOfClass:NSDictionary.class] &&
            ![candidateLimits[@"seven_day"]
                isKindOfClass:NSDictionary.class] &&
            ![candidateLimits[@"fable_five"]
                isKindOfClass:NSDictionary.class]) {
            continue;
        }
        NSDate *modifiedAt = [NSFileManager.defaultManager
            attributesOfItemAtPath:candidate error:nil][NSFileModificationDate];
        if (status == nil ||
            (modifiedAt != nil &&
             (latestModifiedAt == nil ||
              [modifiedAt compare:latestModifiedAt] == NSOrderedDescending))) {
            status = candidateStatus;
            latestModifiedAt = modifiedAt;
        }
    }
    if (sourceModifiedAt != NULL) *sourceModifiedAt = latestModifiedAt;
    return status;
}

- (NSDictionary *)usageDashboardEntryForProfile:(ClaudeProfile *)profile {
    NSDate *modifiedAt = nil;
    NSDictionary *status = [self usageStatusForProfile:profile
                                      sourceModifiedAt:&modifiedAt];
    NSDictionary *refreshResult =
        self.usageDashboardResults[profile.identifier];
    NSString *accountState = [refreshResult[@"account_state"]
        isKindOfClass:NSString.class] ? refreshResult[@"account_state"] : @"unknown";
    NSString *refreshError = [refreshResult[@"refresh_error"]
        isKindOfClass:NSString.class] ? refreshResult[@"refresh_error"] : nil;
    NSString *statusError = [refreshResult[@"status_error"]
        isKindOfClass:NSString.class] ? refreshResult[@"status_error"] : nil;
    BOOL sourceStale = status != nil &&
        (modifiedAt == nil ||
         -modifiedAt.timeIntervalSinceNow > ClaudeUsageFreshnessInterval);
    BOOL signedOut = [accountState isEqualToString:@"signed_out"];
    BOOL accountCheckFailed = refreshResult != nil &&
        [accountState isEqualToString:@"unknown"] &&
        statusError.length > 0;
    BOOL suppressMetrics = status == nil || sourceStale || signedOut ||
        accountCheckFailed;
    NSArray<NSDictionary *> *forecasts = @[];
    if (!suppressMetrics) {
        [self recordUsageSampleForStatus:status
                        sourceModifiedAt:modifiedAt
                                 profile:profile];
        forecasts = [self forecastsForStatus:status
                                     history:[self usageHistoryForProfile:profile]
                                         now:NSDate.date.timeIntervalSince1970];
    }
    NSMutableDictionary *entry = [@{
        @"profile" : profile,
        @"forecasts" : forecasts,
        @"account_state" : accountState,
        @"source_stale" : @(sourceStale),
        @"suppress_metrics" : @(suppressMetrics),
    } mutableCopy];
    if (refreshError.length > 0) entry[@"refresh_error"] = refreshError;
    if (statusError.length > 0) entry[@"status_error"] = statusError;
    if (modifiedAt != nil) entry[@"modified_at"] = modifiedAt;
    return entry;
}

- (void)refreshUsage {
    ClaudeProfile *profile = self.selectedProfile;
    if (profile == nil) {
        self.currentUsageForecasts = @[];
        self.usageLabel.stringValue = @"Usage  Select or add an account";
        self.usageLabel.textColor = self.theme.statusBarForeground;
        return;
    }

    if (!self.accountStatusKnown) {
        self.currentUsageForecasts = @[];
        self.usageLabel.stringValue = self.accountRefreshInFlight
            ? @"Usage  Checking account…"
            : @"Usage  Account status unavailable";
        self.usageLabel.textColor = self.theme.statusBarForeground;
        self.usageLabel.toolTip = self.accountRefreshInFlight
            ? @"Checking whether this Claude account is signed in."
            : @"TerminalDB could not verify this Claude account, so cached percentages are hidden.";
        return;
    }

    NSDate *sourceModifiedAt = nil;
    NSDictionary *status = [self usageStatusForProfile:profile
                                      sourceModifiedAt:&sourceModifiedAt];
    BOOL signedOut = self.accountStatusKnown && !self.accountIsLoggedIn;
    BOOL sourceIsStale = sourceModifiedAt == nil ||
        -sourceModifiedAt.timeIntervalSinceNow > ClaudeUsageFreshnessInterval;
    if (signedOut) {
        self.currentUsageForecasts = @[];
        self.usageLabel.stringValue = @"Usage  Sign in required";
        self.usageLabel.textColor = self.theme.statusBarForeground;
        self.usageLabel.toolTip =
            @"Sign in to this Claude account to refresh its usage. Cached percentages are hidden.";
        return;
    }
    if (status != nil && sourceIsStale) {
        self.currentUsageForecasts = @[];
        self.usageLabel.stringValue = self.usageRefreshInFlight
            ? @"Usage  Refreshing…" : @"Usage  Refresh required";
        self.usageLabel.textColor = self.theme.statusBarForeground;
        self.usageLabel.toolTip = self.usageRefreshError.length > 0
            ? [NSString stringWithFormat:
                @"%@\nThe last usage snapshot is too old to trust, so cached percentages are hidden.",
                self.usageRefreshError]
            : @"The last usage snapshot is too old to trust, so cached percentages are hidden.";
        return;
    }
    if (status == nil) {
        self.currentUsageForecasts = @[];
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

    [self recordUsageSampleForStatus:status
                    sourceModifiedAt:sourceModifiedAt
                             profile:profile];
    NSArray<NSDictionary *> *history = [self usageHistoryForProfile:profile];
    self.currentUsageForecasts = [self forecastsForStatus:status
                                                  history:history
                                                      now:NSDate.date.timeIntervalSince1970];

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
        self.currentUsageForecasts = @[];
        self.usageLabel.stringValue = @"Usage  Waiting for Claude response";
        self.usageLabel.textColor = self.theme.statusBarForeground;
        return;
    }

    NSMutableAttributedString *styled = [[NSMutableAttributedString alloc] init];
    NSDictionary *muted = @{
        NSFontAttributeName : self.usageLabel.font,
        NSForegroundColorAttributeName : self.theme.statusBarActiveForeground,
    };
    [styled appendAttributedString:[[NSAttributedString alloc]
        initWithString:@"Usage  "
            attributes:muted]];
    if (fivePercent != nil) {
        [styled appendAttributedString:
            [self usageSegment:@"5h" percent:fivePercent.doubleValue]];
    }
    if (weekPercent != nil) {
        if (fivePercent != nil) {
            [styled appendAttributedString:[[NSAttributedString alloc]
                initWithString:@" · " attributes:muted]];
        }
        [styled appendAttributedString:
            [self usageSegment:@"7d" percent:weekPercent.doubleValue]];
    }
    if (fablePercent != nil) {
        if (fivePercent != nil || weekPercent != nil) {
            [styled appendAttributedString:[[NSAttributedString alloc]
                initWithString:@" · " attributes:muted]];
        }
        [styled appendAttributedString:[self usageSegment:@"Fable"
                                                 percent:fablePercent.doubleValue]];
    }
    NSDictionary *urgent = nil;
    for (NSDictionary *forecast in self.currentUsageForecasts) {
        if (![forecast[@"warning"] boolValue] ||
            [forecast[@"stale"] boolValue]) {
            continue;
        }
        if (urgent == nil ||
            [forecast[@"eta_seconds"] doubleValue] <
                [urgent[@"eta_seconds"] doubleValue]) {
            urgent = forecast;
        }
    }
    if (urgent != nil) {
        [styled appendAttributedString:[[NSAttributedString alloc]
            initWithString:@" · " attributes:muted]];
        BOOL critical = [urgent[@"severity"] isEqualToString:@"critical"];
        NSTimeInterval eta = [urgent[@"eta_seconds"] doubleValue];
        NSString *forecastText = eta <= 1.0
            ? [NSString stringWithFormat:@"⚠ %@ limit reached",
                urgent[@"label"]]
            : [NSString stringWithFormat:@"⚠ %@ ~%@",
                urgent[@"label"],
                [ClaudeStatusBar compactDurationFromSeconds:eta]];
        [styled appendAttributedString:[[NSAttributedString alloc]
            initWithString:forecastText
                attributes:@{
                    NSFontAttributeName : self.usageLabel.font,
                    NSForegroundColorAttributeName : critical
                        ? self.theme.ansiColors[1]
                        : self.theme.ansiColors[3],
                }]];
    }
    self.usageLabel.attributedStringValue = styled;
    [self setNeedsLayout:YES];

    NSMutableArray<NSString *> *details = [NSMutableArray array];
    [self appendResetDescription:@"5-hour" window:fiveHour to:details];
    [self appendResetDescription:@"7-day" window:sevenDay to:details];
    [self appendResetDescription:@"Fable 5 weekly"
                          window:fableWeekly
                              to:details];
    for (NSDictionary *forecast in self.currentUsageForecasts) {
        if (![forecast[@"warning"] boolValue] ||
            [forecast[@"stale"] boolValue]) {
            continue;
        }
        NSTimeInterval eta = [forecast[@"eta_seconds"] doubleValue];
        double rate = [forecast[@"rate_per_hour"] doubleValue];
        NSString *projected = [ClaudeStatusBar
            compactDateTimeFromTimestamp:forecast[@"projected_at"]];
        [details addObject:eta <= 1.0
            ? [NSString stringWithFormat:@"%@ allowance is exhausted",
                forecast[@"label"]]
            : [NSString stringWithFormat:
                @"%@ pace is +%.1f%%/hr; limit estimated in %@%@",
                forecast[@"label"], rate,
                [ClaudeStatusBar compactDurationFromSeconds:eta],
                projected.length > 0
                    ? [NSString stringWithFormat:@" (%@)", projected] : @""]];
    }
    NSDate *updated = sourceModifiedAt;
    if (updated != nil) {
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        formatter.timeStyle = NSDateFormatterShortStyle;
        formatter.dateStyle = NSDateFormatterNoStyle;
        [details addObject:[NSString stringWithFormat:@"Updated %@",
            [formatter stringFromDate:updated]]];
    }
    if (self.usageRefreshError.length > 0) {
        [details addObject:self.usageRefreshError];
    }
    [details addObject:@"Refreshes every 5 minutes"];
    self.usageLabel.toolTip = [details componentsJoinedByString:@"\n"];
}

+ (NSDictionary *)accountRefreshResultWithExecutable:(NSString *)executable
                                          environment:(NSDictionary *)environment {
    NSString *temporaryPath = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[NSString stringWithFormat:
            @"terminaldb-claude-auth-%@.json", NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager
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
    BOOL timedOut = NO;
    if (launched) {
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10.0];
        while (task.running && [deadline timeIntervalSinceNow] > 0) {
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
        ? [NSData dataWithContentsOfFile:temporaryPath] : nil;
    [NSFileManager.defaultManager removeItemAtPath:temporaryPath error:nil];
    NSDictionary *status = data.length > 0
        ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil]
        : nil;
    if (launchError != nil || !launched) {
        return @{
            @"account_state" : @"unknown",
            @"status_error" : @"Claude Code could not be launched to check sign-in status.",
        };
    }
    if (timedOut) {
        return @{
            @"account_state" : @"unknown",
            @"status_error" : @"Claude account status check timed out.",
        };
    }
    if (![status isKindOfClass:NSDictionary.class]) {
        return @{
            @"account_state" : @"unknown",
            @"status_error" : @"Claude account status could not be read.",
        };
    }
    return @{
        @"account_state" : [status[@"loggedIn"] boolValue]
            ? @"signed_in" : @"signed_out",
    };
}

+ (nullable NSString *)refreshUsageCacheWithExecutable:(NSString *)executable
                                            environment:(NSDictionary *)environment
                                         statusCachePath:(NSString *)statusCachePath {
    NSString *temporaryPath = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[NSString stringWithFormat:
            @"terminaldb-claude-usage-%@.json", NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager
        createFileAtPath:temporaryPath
                contents:nil
              attributes:@{NSFilePosixPermissions : @0600}];
    NSFileHandle *output =
        [NSFileHandle fileHandleForWritingAtPath:temporaryPath];

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:executable];
    task.arguments = @[
        @"-p", @"/usage", @"--output-format", @"json", @"--max-turns", @"1",
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
        while (task.running && [deadline timeIntervalSinceNow] > 0) {
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
        ? [NSData dataWithContentsOfFile:temporaryPath] : nil;
    [NSFileManager.defaultManager removeItemAtPath:temporaryPath error:nil];
    NSDictionary *envelope = data.length > 0
        ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSString *result = [envelope[@"result"] isKindOfClass:NSString.class]
        ? envelope[@"result"] : nil;
    NSDictionary *normalized =
        [ClaudeStatusBar normalizedStatusFromUsageCommandResult:result];
    BOOL wroteCache = NO;
    if (normalized != nil) {
        NSData *normalizedData = [NSJSONSerialization
            dataWithJSONObject:normalized options:0 error:nil];
        wroteCache = [normalizedData writeToFile:statusCachePath atomically:YES];
        if (wroteCache) {
            [NSFileManager.defaultManager
                setAttributes:@{NSFilePosixPermissions : @0600}
                ofItemAtPath:statusCachePath
                error:nil];
        }
    }
    if (launchError != nil || !launched) {
        return @"Claude Code could not be launched to refresh usage.";
    }
    if (timedOut) {
        return @"Claude Code usage refresh timed out.";
    }
    if (task.terminationStatus != 0 || !wroteCache) {
        return @"Claude Code did not return current usage.";
    }
    return nil;
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
    dispatch_async(ClaudeUsageRefreshQueue(), ^{
        NSString *refreshError = [ClaudeStatusBar
            refreshUsageCacheWithExecutable:executable
                                 environment:environment
                              statusCachePath:statusCachePath];
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
    NSRegularExpression *percentExpression = [NSRegularExpression
        regularExpressionWithPattern:
            @"([0-9]+(?:\\.[0-9]+)?)%\\s+used"
                             options:NSRegularExpressionCaseInsensitive
                               error:nil];
    NSRegularExpression *resetExpression = [NSRegularExpression
        regularExpressionWithPattern:
            @"(?:·|-)\\s*resets\\s+(.+?)\\s+\\(([^)]+)\\)\\s*$"
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

        NSTextCheckingResult *percentMatch =
            [percentExpression firstMatchInString:line
                                          options:0
                                            range:NSMakeRange(0, line.length)];
        if (percentMatch.numberOfRanges < 2) continue;
        double percent =
            [[line substringWithRange:[percentMatch rangeAtIndex:1]] doubleValue];
        NSMutableDictionary *window = [@{
            @"used_percentage" :
                @(ClaudeUsageClampedPercent(percent)),
        } mutableCopy];
        NSTextCheckingResult *resetMatch =
            [resetExpression firstMatchInString:line
                                        options:0
                                          range:NSMakeRange(0, line.length)];
        if (resetMatch.numberOfRanges >= 3) {
            NSString *dateText =
                [line substringWithRange:[resetMatch rangeAtIndex:1]];
            NSString *timeZoneName =
                [line substringWithRange:[resetMatch rangeAtIndex:2]];
            NSNumber *reset = [self
                timestampFromUsageCommandDate:dateText
                                 timeZoneName:timeZoneName];
            if (reset != nil) window[@"resets_at"] = reset;
        }
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
    NSDictionary *zeroSessionStatus =
        [self normalizedStatusFromUsageCommandResult:
            @"Current session: 0% used\n"
             "Current week (all models): 20% used · resets Dec 31 at 2pm "
             "(America/Los_Angeles)\n"
             "Current week (Fable): 14% used · resets Dec 31 at 1:59pm "
             "(America/Los_Angeles)"];
    NSDictionary *zeroSession =
        zeroSessionStatus[@"rate_limits"][@"five_hour"];
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
    NSString *fixtureRoot = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[NSString stringWithFormat:
            @"terminaldb-usage-summary-%@", NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtPath:fixtureRoot
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
    ClaudeProfile *fixtureProfile = [[ClaudeProfile alloc] init];
    [fixtureProfile setValue:@"usage-summary" forKey:@"identifier"];
    [fixtureProfile setValue:@"Usage Summary" forKey:@"label"];
    [fixtureProfile setValue:@"first@example.com" forKey:@"email"];
    [fixtureProfile setValue:@"Max" forKey:@"subscriptionType"];
    [fixtureProfile setValue:fixtureRoot forKey:@"profileDirectory"];
    NSData *fixtureData = [NSJSONSerialization
        dataWithJSONObject:normalized options:0 error:nil];
    [fixtureData writeToFile:fixtureProfile.statusCachePath atomically:YES];
    ClaudeProfile *secondProfile = [[ClaudeProfile alloc] init];
    [secondProfile setValue:@"usage-second" forKey:@"identifier"];
    [secondProfile setValue:@"Second Subscription" forKey:@"label"];
    [secondProfile setValue:@"second@example.com" forKey:@"email"];
    [secondProfile setValue:@"Team" forKey:@"subscriptionType"];
    [secondProfile setValue:[fixtureRoot stringByAppendingPathComponent:@"second"]
                      forKey:@"profileDirectory"];
    ClaudeProfileManager *fixtureManager =
        [ClaudeProfileManager managerForTestingAtRoot:
            [fixtureRoot stringByAppendingPathComponent:@"manager"]];
    [fixtureManager setValue:@[fixtureProfile, secondProfile] forKey:@"profiles"];
    [fixtureManager setValue:fixtureProfile forKey:@"lastSelectedProfile"];
    ClaudeStatusBar *fixtureBar = [[ClaudeStatusBar alloc]
        initWithFrame:NSMakeRect(0, 0, 720, 28)
        claudeExecutable:@""
        profileManager:fixtureManager
        selectedProfile:fixtureProfile
        theme:[TerminalTheme preferredTheme]];
    [fixtureBar setValue:@YES forKey:@"accountStatusKnown"];
    [fixtureBar setValue:@YES forKey:@"accountIsLoggedIn"];
    [fixtureBar refreshUsage];
    NSString *compactSummary = fixtureBar.usageLabel.stringValue;
    BOOL showsEveryWindow =
        [compactSummary containsString:@"5h 12%"] &&
        [compactSummary containsString:@"7d 34%"] &&
        [compactSummary containsString:@"Fable 56%"] &&
        ![compactSummary containsString:@"⚠"];

    NSTimeInterval forecastNow = NSDate.date.timeIntervalSince1970;
    NSNumber *forecastReset = @(forecastNow + 2.0 * 60.0 * 60.0);
    NSArray *fastHistory = @[
        @{@"recorded_at" : @(forecastNow - 20.0 * 60.0),
          @"rate_limits" : @{@"five_hour" : @{
              @"used_percentage" : @20, @"resets_at" : forecastReset}}},
        @{@"recorded_at" : @(forecastNow - 10.0 * 60.0),
          @"rate_limits" : @{@"five_hour" : @{
              @"used_percentage" : @30, @"resets_at" : forecastReset}}},
        @{@"recorded_at" : @(forecastNow),
          @"rate_limits" : @{@"five_hour" : @{
              @"used_percentage" : @40, @"resets_at" : forecastReset}}},
    ];
    NSDictionary *fastForecast = [self
        usageForecastForSamples:fastHistory
                       windowKey:@"five_hour"
                   currentWindow:@{@"used_percentage" : @40,
                                   @"resets_at" : forecastReset}
                             now:forecastNow];
    NSArray *safeHistory = @[
        @{@"recorded_at" : @(forecastNow - 20.0 * 60.0),
          @"rate_limits" : @{@"five_hour" : @{
              @"used_percentage" : @20, @"resets_at" : forecastReset}}},
        @{@"recorded_at" : @(forecastNow - 10.0 * 60.0),
          @"rate_limits" : @{@"five_hour" : @{
              @"used_percentage" : @21, @"resets_at" : forecastReset}}},
        @{@"recorded_at" : @(forecastNow),
          @"rate_limits" : @{@"five_hour" : @{
              @"used_percentage" : @22, @"resets_at" : forecastReset}}},
    ];
    NSDictionary *safeForecast = [self
        usageForecastForSamples:safeHistory
                       windowKey:@"five_hour"
                   currentWindow:@{@"used_percentage" : @22,
                                   @"resets_at" : forecastReset}
                             now:forecastNow];
    NSDictionary *learningForecast = [self
        usageForecastForSamples:[fastHistory subarrayWithRange:NSMakeRange(1, 2)]
                       windowKey:@"five_hour"
                   currentWindow:@{@"used_percentage" : @40,
                                   @"resets_at" : forecastReset}
                             now:forecastNow];
    NSDictionary *resetChangedForecast = [self
        usageForecastForSamples:fastHistory
                       windowKey:@"five_hour"
                   currentWindow:@{
                       @"used_percentage" : @3,
                       @"resets_at" : @(forecastReset.doubleValue + 3600.0),
                   }
                             now:forecastNow];
    NSDictionary *exhaustedForecast = [self
        usageForecastForSamples:@[
            @{@"recorded_at" : @(forecastNow),
              @"rate_limits" : @{@"five_hour" : @{
                  @"used_percentage" : @100,
                  @"resets_at" : forecastReset}}},
        ]
                       windowKey:@"five_hour"
                   currentWindow:@{@"used_percentage" : @100,
                                   @"resets_at" : forecastReset}
                             now:forecastNow];
    NSDictionary *staleForecast = [self
        usageForecastForSamples:@[
            @{@"recorded_at" : @(forecastNow - 40.0 * 60.0),
              @"rate_limits" : @{@"five_hour" : @{
                  @"used_percentage" : @20,
                  @"resets_at" : forecastReset}}},
            @{@"recorded_at" : @(forecastNow - 30.0 * 60.0),
              @"rate_limits" : @{@"five_hour" : @{
                  @"used_percentage" : @30,
                  @"resets_at" : forecastReset}}},
            @{@"recorded_at" : @(forecastNow - 20.0 * 60.0),
              @"rate_limits" : @{@"five_hour" : @{
                  @"used_percentage" : @40,
                  @"resets_at" : forecastReset}}},
        ]
                       windowKey:@"five_hour"
                   currentWindow:@{@"used_percentage" : @40,
                                   @"resets_at" : forecastReset}
                             now:forecastNow];

    NSNumber *fixtureFetchedAt = normalized[@"terminaldb"][@"fetched_at"];
    NSMutableArray *riskSamples = [NSMutableArray array];
    for (NSUInteger index = 0; index < 3; index++) {
        [riskSamples addObject:@{
            @"recorded_at" : @(fixtureFetchedAt.doubleValue -
                (2 - index) * 10.0 * 60.0),
            @"rate_limits" : @{
                @"five_hour" : @{
                    @"used_percentage" : @12,
                    @"resets_at" : fiveHourReset,
                },
                @"seven_day" : @{
                    @"used_percentage" : @34,
                    @"resets_at" : sevenDayReset,
                },
                @"fable_five" : @{
                    @"used_percentage" : @([@[@40, @48, @56][index]
                        doubleValue]),
                    @"resets_at" : limits[@"fable_five"][@"resets_at"],
                },
            },
        }];
    }
    NSData *riskData = [NSJSONSerialization dataWithJSONObject:@{
        @"version" : @1, @"samples" : riskSamples,
    } options:0 error:nil];
    [riskData writeToFile:fixtureProfile.usageHistoryPath atomically:YES];
    [NSFileManager.defaultManager
        setAttributes:@{NSFilePosixPermissions : @0600}
        ofItemAtPath:fixtureProfile.usageHistoryPath
        error:nil];
    [fixtureBar refreshUsage];
    BOOL showsRiskOnlyWhenForecasted =
        [fixtureBar.usageLabel.stringValue containsString:@"⚠ Fable"];
    NSView *dashboard = [fixtureBar prepareUsagePanel];
    BOOL dashboardShowsAllAccounts =
        ClaudeUsageViewContainsText(dashboard, @"2 subscriptions configured") &&
        ClaudeUsageViewContainsText(dashboard, @"Usage Summary") &&
        ClaudeUsageViewContainsText(dashboard, @"Second Subscription") &&
        ClaudeUsageViewContainsText(dashboard, @"BURN") &&
        ClaudeUsageViewContainsText(dashboard, @"AVAILABLE PACE") &&
        ClaudeUsageViewContainsText(dashboard, @"RESET") &&
        ClaudeUsageViewContainsText(dashboard, @"Use on This Tab");
    BOOL dashboardUsesHostScroller =
        NSHeight(dashboard.frame) > 620 &&
        !ClaudeUsageViewContainsNestedScrollView(dashboard);
    [NSFileManager.defaultManager setAttributes:@{
        NSFileModificationDate :
            [NSDate dateWithTimeIntervalSinceNow:
                -(ClaudeUsageFreshnessInterval + 60.0)],
    } ofItemAtPath:fixtureProfile.statusCachePath error:nil];
    [fixtureBar refreshUsage];
    NSView *staleDashboard = [fixtureBar prepareUsagePanel];
    BOOL hidesStaleUsage =
        [fixtureBar.usageLabel.stringValue isEqualToString:
            @"Usage  Refresh required"] &&
        ClaudeUsageViewContainsText(staleDashboard,
            @"stale snapshot hidden") &&
        ClaudeUsageViewContainsText(staleDashboard,
            @"too old to trust");
    [fixtureBar setValue:@{
        fixtureProfile.identifier : @{
            @"account_state" : @"signed_out",
        },
    } forKey:@"usageDashboardResults"];
    [fixtureBar setValue:@YES forKey:@"accountStatusKnown"];
    [fixtureBar setValue:@NO forKey:@"accountIsLoggedIn"];
    [fixtureBar refreshUsage];
    NSView *signedOutDashboard = [fixtureBar prepareUsagePanel];
    BOOL hidesSignedOutUsage =
        [fixtureBar.usageLabel.stringValue isEqualToString:
            @"Usage  Sign in required"] &&
        ClaudeUsageViewContainsText(signedOutDashboard,
            @"Signed out") &&
        ClaudeUsageViewContainsText(signedOutDashboard,
            @"Sign In…");
    NSNumber *historyPermissions = [NSFileManager.defaultManager
        attributesOfItemAtPath:fixtureProfile.usageHistoryPath error:nil]
        [NSFilePosixPermissions];
    [NSFileManager.defaultManager removeItemAtPath:fixtureRoot error:nil];
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
        [zeroSession[@"used_percentage"] isEqual:@0] &&
        zeroSession[@"resets_at"] == nil &&
        [self compactResetDateTimeFromTimestamp:fiveHourReset].length > 0 &&
        [self compactResetDateTimeFromTimestamp:sevenDayReset].length > 0 &&
        [self compactResetDateTimeFromTimestamp:pastReset] == nil &&
        [self compactDateTimeFromTimestamp:pastReset].length > 0 &&
        rolled &&
        [nextReset doubleValue] > [NSDate date].timeIntervalSince1970 &&
        [clamped[@"rate_limits"][@"five_hour"][@"used_percentage"]
            isEqual:@100] &&
        [clamped[@"rate_limits"][@"seven_day"][@"used_percentage"]
            isEqual:@0] &&
        showsEveryWindow &&
        [fastForecast[@"ready"] boolValue] &&
        [fastForecast[@"warning"] boolValue] &&
        [fastForecast[@"rate_per_hour"] doubleValue] > 55.0 &&
        [safeForecast[@"ready"] boolValue] &&
        ![safeForecast[@"warning"] boolValue] &&
        ![learningForecast[@"ready"] boolValue] &&
        ![resetChangedForecast[@"ready"] boolValue] &&
        ![resetChangedForecast[@"warning"] boolValue] &&
        [exhaustedForecast[@"warning"] boolValue] &&
        [exhaustedForecast[@"severity"] isEqualToString:@"critical"] &&
        [staleForecast[@"stale"] boolValue] &&
        showsRiskOnlyWhenForecasted &&
        dashboardShowsAllAccounts &&
        dashboardUsesHostScroller &&
        hidesStaleUsage &&
        hidesSignedOutUsage &&
        historyPermissions.unsignedIntegerValue == 0600;
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

+ (NSString *)compactDurationFromSeconds:(NSTimeInterval)seconds {
    if (!isfinite(seconds) || seconds <= 60.0) return @"now";
    NSInteger totalMinutes = MAX(1, (NSInteger)llround(seconds / 60.0));
    if (totalMinutes < 60) {
        NSInteger rounded = MAX(1, (NSInteger)llround(totalMinutes / 5.0) * 5);
        return [NSString stringWithFormat:@"%ldm", (long)rounded];
    }
    NSInteger hours = totalMinutes / 60;
    NSInteger minutes = totalMinutes % 60;
    minutes = (NSInteger)llround(minutes / 5.0) * 5;
    if (minutes >= 60) {
        hours += 1;
        minutes = 0;
    }
    return minutes > 0
        ? [NSString stringWithFormat:@"%ldh %ldm",
            (long)hours, (long)minutes]
        : [NSString stringWithFormat:@"%ldh", (long)hours];
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
